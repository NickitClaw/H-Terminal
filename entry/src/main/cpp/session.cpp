#include "session.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <poll.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <openssl/evp.h>
#include <string_view>
#include <utility>

namespace hterminal {
namespace {

constexpr size_t kOutputFrameLimit = 32 * 1024;
constexpr size_t kOutputHighWater = 256 * 1024;
constexpr size_t kOutputLowWater = 64 * 1024;
// libssh 0.12.2 channels.c grants 64 * 32768 bytes and accounts for both
// channel streams before replenishing that window. Bytes already granted to
// the peer may still arrive while the renderer is paused. Reserve that window
// separately from bytes handed to the renderer but not yet acknowledged.
constexpr size_t kSshReceiveWindow = 2 * 1024 * 1024;
constexpr size_t kOutputHardLimit = kSshReceiveWindow + kOutputHighWater;
constexpr size_t kInputQueueLimit = 64 * 1024;
constexpr size_t kMaxUnackedFrames = 4096;
constexpr size_t kMaxRememberedEventIds = 4096;
constexpr uint64_t kMaxSafeInteger = 9007199254740991ULL;
constexpr auto kPollInterval = std::chrono::milliseconds(10);
constexpr auto kConnectTimeout = std::chrono::seconds(15);
constexpr auto kHandshakeTimeout = std::chrono::seconds(15);
constexpr auto kTrustTimeout = std::chrono::seconds(120);
constexpr auto kAuthenticationTimeout = std::chrono::seconds(30);
constexpr auto kChannelTimeout = std::chrono::seconds(15);

std::mutex g_knownHostsMutex;
std::once_flag g_sshInitFlag;
int g_sshInitResult = SSH_ERROR;

void UpdatePeak(std::atomic<uint64_t> &peak, uint64_t value) {
    uint64_t previous = peak.load(std::memory_order_relaxed);
    while (previous < value && !peak.compare_exchange_weak(previous, value, std::memory_order_relaxed)) {}
}

void SecureClear(std::vector<uint8_t> &value) {
    volatile uint8_t *data = value.empty() ? nullptr : value.data();
    for (size_t i = 0; i < value.size(); ++i) {
        data[i] = 0;
    }
    value.clear();
}

std::string Base64(const uint8_t *data, size_t length) {
    static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    result.reserve(((length + 2) / 3) * 4);
    for (size_t offset = 0; offset < length; offset += 3) {
        const size_t remaining = length - offset;
        const uint32_t a = data[offset];
        const uint32_t b = remaining > 1 ? data[offset + 1] : 0;
        const uint32_t c = remaining > 2 ? data[offset + 2] : 0;
        const uint32_t value = (a << 16) | (b << 8) | c;
        result.push_back(alphabet[(value >> 18) & 0x3f]);
        result.push_back(alphabet[(value >> 12) & 0x3f]);
        result.push_back(remaining > 1 ? alphabet[(value >> 6) & 0x3f] : '=');
        result.push_back(remaining > 2 ? alphabet[value & 0x3f] : '=');
    }
    return result;
}

} // namespace

bool EnsureSshInitialized() {
    std::call_once(g_sshInitFlag, []() { g_sshInitResult = ssh_init(); });
    return g_sshInitResult == SSH_OK;
}

SessionMetrics Session::Metrics() const {
    SessionMetrics metrics;
    metrics.outputBytes = outputBytes_.load(); metrics.inputBytes = inputBytes_.load();
    metrics.outputFrames = outputFrames_.load(); metrics.acknowledgedFrames = acknowledgedFrames_.load();
    metrics.unackedBytes = unackedBytes_.load(); metrics.peakUnackedBytes = peakUnackedBytes_.load();
    metrics.peakInputBytes = peakInputBytes_.load(); metrics.peakReceiveBytes = peakReceiveBytes_.load();
    metrics.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - createdAt_).count();
    std::lock_guard<std::mutex> lock(commandMutex_);
    metrics.queuedInputBytes = queuedInputBytes_;
    return metrics;
}

bool SupportedPrivateKeyContainer(const std::string &key) {
    // Bound work before libssh enters bcrypt_pbkdf. The container is user
    // supplied and its round count must not monopolize a worker indefinitely.
    constexpr char header[] = "-----BEGIN OPENSSH PRIVATE KEY-----";
    constexpr char footer[] = "-----END OPENSSH PRIVATE KEY-----";
    if (key.size() > 65536 || key.compare(0, sizeof(header) - 1, header) != 0) return false;
    size_t end = key.find(footer, sizeof(header) - 1);
    if (end == std::string::npos) return false;
    struct Encoded {
        std::string value;
        ~Encoded() { SecureClear(value); }
    } encoded;
    for (size_t i = sizeof(header) - 1; i < end; ++i) {
        unsigned char c = key[i];
        if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '+' || c == '/' || c == '=')) return false;
        encoded.value.push_back(static_cast<char>(c));
    }
    if (encoded.value.empty() || encoded.value.size() % 4 != 0) return false;
    struct Decoded {
        std::vector<unsigned char> value;
        ~Decoded() { volatile unsigned char *p = value.data(); for (size_t i = 0; i < value.size(); ++i) p[i] = 0; }
    } decoded;
    decoded.value.resize(encoded.value.size() / 4 * 3);
    int count = EVP_DecodeBlock(decoded.value.data(), reinterpret_cast<const unsigned char *>(encoded.value.data()),
        static_cast<int>(encoded.value.size()));
    if (count < 0) return false;
    constexpr char magic[] = "openssh-key-v1";
    if (decoded.value.size() < sizeof(magic) || memcmp(decoded.value.data(), magic, sizeof(magic)) != 0) return false;
    size_t offset = sizeof(magic);
    auto readInteger = [&](uint32_t &value) {
        if (offset + 4 > decoded.value.size()) return false;
        const unsigned char *p = decoded.value.data() + offset;
        value = (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
            (static_cast<uint32_t>(p[2]) << 8) | p[3];
        offset += 4;
        return true;
    };
    auto readString = [&](std::string_view &value) {
        uint32_t size = 0;
        if (!readInteger(size) || size > decoded.value.size() - offset) return false;
        value = std::string_view(reinterpret_cast<const char *>(decoded.value.data() + offset), size);
        offset += size;
        return true;
    };
    std::string_view cipher, kdf, options;
    uint32_t keys = 0;
    if (!readString(cipher) || cipher.size() > 64 || !readString(kdf) || !readString(options) ||
        !readInteger(keys) || keys != 1) return false;
    if (cipher == "none") return kdf == "none" && options.empty();
    if (kdf != "bcrypt" || options.size() < 8 || options.size() > 72) return false;
    const auto *p = reinterpret_cast<const unsigned char *>(options.data());
    uint32_t salt = (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
        (static_cast<uint32_t>(p[2]) << 8) | p[3];
    if (salt < 16 || salt > 64 || options.size() != salt + 8) return false;
    p += salt + 4;
    uint32_t rounds = (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
        (static_cast<uint32_t>(p[2]) << 8) | p[3];
    return rounds > 0 && rounds <= 1024;
}

bool AccessTrustedHostKey(const std::string &filesDir, const std::string &host, uint32_t port,
                         const std::string &expectedFingerprint, bool remove, TrustedHostKey &result) {
    if (!EnsureSshInitialized()) return false;
    std::lock_guard<std::mutex> lock(g_knownHostsMutex);
    const std::string file = filesDir + "/known_hosts";
    struct Descriptor {
        int value;
        ~Descriptor() { if (value >= 0) close(value); }
    } input{open(file.c_str(), O_RDONLY | O_NOFOLLOW)};
    struct stat status{};
    if (input.value < 0 || fstat(input.value, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size > 1024 * 1024) return false;
    std::string contents(static_cast<size_t>(status.st_size), '\0');
    size_t offset = 0;
    while (offset < contents.size()) {
        ssize_t count = read(input.value, &contents[offset], contents.size() - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        offset += static_cast<size_t>(count);
    }
    const std::string target = port == 22 ? host : "[" + host + "]:" + std::to_string(port);
    bool found = false;
    bool sharedRecord = false;
    std::string kept;
    for (size_t begin = 0; begin < contents.size();) {
        size_t end = contents.find('\n', begin);
        if (end == std::string::npos) end = contents.size();
        const std::string line = contents.substr(begin, end - begin);
        ssh_knownhosts_entry *entry = nullptr;
        bool erase = false;
        if (!line.empty() && ssh_known_hosts_parse_line(target.c_str(), line.c_str(), &entry) == SSH_OK && entry) {
            unsigned char *hash = nullptr;
            size_t length = 0;
            char *fingerprint = nullptr, *publicKey = nullptr;
            if (ssh_get_publickey_hash(entry->publickey, SSH_PUBLICKEY_HASH_SHA256, &hash, &length) == SSH_OK) {
                fingerprint = ssh_get_fingerprint_hash(SSH_PUBLICKEY_HASH_SHA256, hash, length);
            }
            if (fingerprint && (!remove || expectedFingerprint == fingerprint)) {
                if (ssh_pki_export_pubkey_base64(entry->publickey, &publicKey) == SSH_OK && publicKey) {
                    result.publicKey = std::string(ssh_key_type_to_char(ssh_key_type(entry->publickey))) + " " + publicKey;
                    result.fingerprint = fingerprint;
                    found = true;
                    const std::string names = line.substr(0, line.find_first_of(" \t"));
                    // Never erase a shared alias/wildcard line on behalf of one host.
                    erase = remove && names.find(',') == std::string::npos && names.find('*') == std::string::npos &&
                        names.find('?') == std::string::npos;
                    if (remove && !erase) sharedRecord = true;
                }
            }
            if (hash) ssh_clean_pubkey_hash(&hash);
            if (fingerprint) ssh_string_free_char(fingerprint);
            if (publicKey) ssh_string_free_char(publicKey);
        }
        if (entry) ssh_knownhosts_entry_free(entry);
        if (!erase) { kept += line; kept += '\n'; }
        begin = end + 1;
        if (found && !remove) return true;
    }
    if (!found || !remove || sharedRecord) return false;
    std::string temporary = file + ".XXXXXX";
    std::vector<char> path(temporary.begin(), temporary.end()); path.push_back('\0');
    Descriptor output{mkstemp(path.data())};
    if (output.value < 0) return false;
    offset = 0;
    bool ok = true;
    while (offset < kept.size()) {
        ssize_t count = write(output.value, kept.data() + offset, kept.size() - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = false; break; }
        offset += static_cast<size_t>(count);
    }
    ok = ok && fsync(output.value) == 0 && rename(path.data(), file.c_str()) == 0;
    if (!ok) unlink(path.data());
    return ok;
}

Session::Session(std::unique_ptr<NativeConnectOptions> options, NativeEventSink &sink)
    : options_(std::move(options)), sink_(sink), cols_(options_->cols), rows_(options_->rows) {}

Session::Session(std::unique_ptr<NativeConnectOptions> options, std::shared_ptr<NativeEventSink> sink)
    : options_(std::move(options)), ownedSink_(std::move(sink)), sink_(*ownedSink_),
      cols_(options_->cols), rows_(options_->rows) {}

Session::~Session() {
    Stop();
    SecureClear(options_->password);
}

void Session::AnswerAuthentication(uint64_t requestId, std::vector<std::string> answers) {
    if (requestId != challengeId_.load() || closeRequested_.load() || answerQueued_.exchange(true)) {
        for (auto &answer : answers) SecureClear(answer);
        return;
    }
    Command command;
    command.type = CommandType::AuthAnswer;
    command.seq = requestId;
    command.answers = std::move(answers);
    std::lock_guard<std::mutex> lock(commandMutex_);
    commands_.push_back(std::move(command));
}

const std::string &Session::Id() const {
    return options_->sessionId;
}

uint64_t Session::Epoch() const {
    return options_->connectionEpoch;
}

bool Session::IsActive() const {
    PublicState state = state_.load(std::memory_order_acquire);
    return state != PublicState::Closed && state != PublicState::Failed;
}

bool Session::IsOpenForInput() const {
    return state_.load(std::memory_order_acquire) == PublicState::Open &&
        acceptingInput_.load(std::memory_order_acquire) && !closeRequested_.load(std::memory_order_acquire);
}

void Session::Start() {
    worker_ = std::thread([self = shared_from_this()]() { self->Run(); });
}

void Session::Stop() {
    std::lock_guard<std::mutex> lock(stopMutex_);
    if (worker_.joinable()) {
        if (worker_.get_id() == std::this_thread::get_id()) {
            return;
        }
        worker_.join();
    }
}

void Session::RequestClose() {
    acceptingInput_.store(false, std::memory_order_release);
    closeRequested_.store(true, std::memory_order_release);
}

void Session::Probe(uint64_t requestId) {
    if (requestId == 0 || !IsActive() || closeRequested_.load()) return;
    acceptingInput_.store(false, std::memory_order_release);
    Command command;
    command.type = CommandType::Probe;
    command.seq = requestId;
    std::lock_guard<std::mutex> lock(commandMutex_);
    commands_.push_back(std::move(command));
}

void Session::TrustDecision(bool accepted) {
    if (!trustPending_.load(std::memory_order_acquire) || closeRequested_.load(std::memory_order_acquire)) {
        return;
    }
    bool expected = false;
    if (!trustQueued_.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        return;
    }
    Command command;
    command.type = CommandType::Trust;
    command.accepted = accepted;
    try {
        std::lock_guard<std::mutex> lock(commandMutex_);
        commands_.push_back(std::move(command));
    } catch (...) {
        trustQueued_.store(false, std::memory_order_release);
    }
}

bool Session::WriteInput(uint64_t inputEpoch, const std::string &eventId, std::vector<uint8_t> data,
                         InputKind kind, const std::string &pasteId) {
    if ((data.empty() && kind != InputKind::PasteStart && kind != InputKind::PasteEnd) ||
        data.size() > kInputQueueLimit || !IsOpenForInput() || inputResetPending_.load()) {
        return false;
    }
    try {
        std::lock_guard<std::mutex> lock(commandMutex_);
        if (!IsOpenForInput() || inputResetPending_.load() || queuedInputBytes_ > kInputQueueLimit - data.size()) {
            return false;
        }
        const std::vector<uint8_t> start{27, '[', '2', '0', '0', '~'};
        const std::vector<uint8_t> end{27, '[', '2', '0', '1', '~'};
        if (kind == InputKind::Normal && !acceptedPasteId_.empty()) return false;
        if (kind == InputKind::PasteStart && (!acceptedPasteId_.empty() || pasteId.empty() ||
            (!data.empty() && data != start))) return false;
        if ((kind == InputKind::PasteData || kind == InputKind::PasteEnd) &&
            (pasteId.empty() || pasteId != acceptedPasteId_)) return false;
        if (kind == InputKind::PasteEnd && data != (acceptedPasteBrackets_ ? end : std::vector<uint8_t>{})) return false;
        if (hasInputEpoch_.load(std::memory_order_acquire) && inputEpoch < latestInputEpoch_.load(std::memory_order_acquire)) {
            return false;
        }
        if (!hasInputEpoch_.load(std::memory_order_acquire) || inputEpoch > latestInputEpoch_.load(std::memory_order_acquire)) {
            latestInputEpoch_.store(inputEpoch, std::memory_order_release);
            hasInputEpoch_.store(true, std::memory_order_release);
            seenEventIds_.clear();
            eventIdOrder_.clear();
        }
        if (seenEventIds_.find(eventId) != seenEventIds_.end()) {
            return false;
        }
        if (eventIdOrder_.size() == kMaxRememberedEventIds) {
            seenEventIds_.erase(eventIdOrder_.front());
            eventIdOrder_.pop_front();
        }
        seenEventIds_.insert(eventId);
        eventIdOrder_.push_back(eventId);
        Command command;
        command.type = CommandType::Input;
        command.inputEpoch = inputEpoch;
        command.eventId = eventId;
        command.data = std::move(data);
        command.kind = kind;
        commands_.push_back(std::move(command));
        queuedInputBytes_ += commands_.back().data.size();
        UpdatePeak(peakInputBytes_, queuedInputBytes_);
        if (kind == InputKind::PasteStart) {
            acceptedPasteId_ = pasteId;
            acceptedPasteBrackets_ = !commands_.back().data.empty();
        }
        return true;
    } catch (...) {
        return false;
    }
}

void Session::ResetInput(uint64_t epoch, bool sendControl) {
    if (!IsActive() || closeRequested_.load()) return;
    Command command;
    command.type = CommandType::ResetInput;
    command.inputEpoch = epoch;
    command.accepted = sendControl;
    std::lock_guard<std::mutex> lock(commandMutex_);
    if (epoch <= lastResetEpoch_ || (hasInputEpoch_.load() && epoch <= latestInputEpoch_.load())) return;
    commands_.push_back(std::move(command));
    lastResetEpoch_ = epoch;
    inputResetPending_.store(true, std::memory_order_release);
}

void Session::Resize(int cols, int rows) {
    if (cols <= 0 || rows <= 0 || cols > 65535 || rows > 65535) {
        EmitError("terminal resize dimensions must be positive");
        return;
    }
    if (!IsActive() || closeRequested_.load(std::memory_order_acquire)) {
        return;
    }
    Command command;
    command.type = CommandType::Resize;
    command.cols = cols;
    command.rows = rows;
    try {
        std::lock_guard<std::mutex> lock(commandMutex_);
        commands_.push_back(std::move(command));
    } catch (...) {
        EmitError("could not queue terminal resize");
    }
}

void Session::Acknowledge(uint64_t terminalGeneration, uint64_t seq, size_t byteLength) {
    if (terminalGeneration != options_->terminalGeneration || !IsActive()) {
        return;
    }
    Command command;
    command.type = CommandType::Acknowledge;
    command.seq = seq;
    command.byteLength = byteLength;
    try {
        std::lock_guard<std::mutex> lock(commandMutex_);
        commands_.push_back(std::move(command));
    } catch (...) {
        EmitError("could not queue output acknowledgement");
    }
}

bool Session::SetState(PublicState state, const char *name) {
    state_.store(state, std::memory_order_release);
    acceptingInput_.store(state == PublicState::Open && !closeRequested_.load(std::memory_order_acquire),
        std::memory_order_release);
    auto event = std::make_unique<NativeEvent>();
    event->type = NativeEventType::State;
    event->sessionId = options_->sessionId;
    event->connectionEpoch = options_->connectionEpoch;
    event->terminalGeneration = options_->terminalGeneration;
    event->state = name;
    return sink_.Emit(std::move(event));
}

void Session::EmitError(const std::string &message, const std::string &code) {
    auto event = std::make_unique<NativeEvent>();
    event->type = NativeEventType::Error;
    event->sessionId = options_->sessionId;
    event->connectionEpoch = options_->connectionEpoch;
    event->terminalGeneration = options_->terminalGeneration;
    event->message = message;
    event->code = code;
    sink_.Emit(std::move(event));
}

void Session::Fail(const std::string &message, const std::string &code) {
    if (failed_ || remoteClosed_ || closeRequested_.load(std::memory_order_acquire)) {
        return;
    }
    failed_ = true;
    failureKind_ = !code.empty() ? code :
        (stage_ == Stage::VerifyHost || stage_ == Stage::WaitTrust) ? "hostkey" :
        (stage_ == Stage::Authenticate || stage_ == Stage::WaitAuth) ? "authentication" : "protocol";
    failureMessage_ = message;
    acceptingInput_.store(false, std::memory_order_release);
    trustPending_.store(false, std::memory_order_release);
}

void Session::ChangeStage(Stage stage, std::chrono::steady_clock::duration timeout) {
    stage_ = stage;
    deadline_ = std::chrono::steady_clock::now() + timeout;
}

void Session::CheckDeadline(const char *message) {
    if (std::chrono::steady_clock::now() >= deadline_) {
        Fail(message, stage_ == Stage::Connect ? "network" : "");
    }
}

bool Session::CreateTransport() {
    if (!EnsureSshInitialized()) {
        Fail("SSH library initialization failed");
        return false;
    }
    session_ = ssh_new();
    if (session_ == nullptr) {
        Fail("could not allocate SSH transport");
        return false;
    }
    const std::string knownHosts = options_->filesDir + "/known_hosts";
    unsigned int port = options_->port;
    long timeout = 15;
    int strictHostChecking = 1;
    int noDelay = 1;
    bool processConfig = false;
    static constexpr char kHostKeys[] =
        "ssh-ed25519,ecdsa-sha2-nistp521,ecdsa-sha2-nistp384,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256";
    static constexpr char kCiphers[] =
        "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr";
    static constexpr char kMacs[] =
        "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512";
    bool ok = ssh_options_set(session_, SSH_OPTIONS_HOST, options_->host.c_str()) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_PORT, &port) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_USER, options_->username.c_str()) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_KNOWNHOSTS, knownHosts.c_str()) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_GLOBAL_KNOWNHOSTS, knownHosts.c_str()) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_STRICTHOSTKEYCHECK, &strictHostChecking) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_PROCESS_CONFIG, &processConfig) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_TIMEOUT, &timeout) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_NODELAY, &noDelay) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_HOSTKEYS, kHostKeys) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_CIPHERS_C_S, kCiphers) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_CIPHERS_S_C, kCiphers) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_HMAC_C_S, kMacs) == SSH_OK &&
        ssh_options_set(session_, SSH_OPTIONS_HMAC_S_C, kMacs) == SSH_OK;
    if (!ok) {
        Fail("could not configure SSH transport");
        return false;
    }
    ssh_set_blocking(session_, 0);
    return true;
}

void Session::DestroyTransport() {
    if (privateKey_ != nullptr) { ssh_key_free(privateKey_); privateKey_ = nullptr; }
    if (event_ != nullptr) {
        if (session_ != nullptr) {
            ssh_event_remove_session(event_, session_);
        }
        ssh_event_free(event_);
        event_ = nullptr;
    }
    if (channel_ != nullptr) {
        if (ssh_channel_is_open(channel_)) {
            ssh_channel_send_eof(channel_);
        }
        ssh_channel_close(channel_);
        ssh_channel_free(channel_);
        channel_ = nullptr;
    }
    if (session_ != nullptr) {
        if (ssh_is_connected(session_)) {
            ssh_disconnect(session_);
        }
        ssh_free(session_);
        session_ = nullptr;
    }
}

void Session::Run() {
    try {
        if (!SetState(PublicState::Idle, "IDLE")) {
            Fail("native event delivery failed");
        }
        if (!failed_ && CreateTransport()) {
            if (!SetState(PublicState::Connecting, "CONNECTING")) {
                Fail("native event delivery failed");
            }
            ChangeStage(Stage::Connect, kConnectTimeout);
            handshakeDeadlineStarted_ = false;
        }
        while (!failed_ && !remoteClosed_ && !closeRequested_.load(std::memory_order_acquire)) {
            DrainCommands();
            if (failed_ || remoteClosed_ || closeRequested_.load(std::memory_order_acquire)) {
                break;
            }
            Advance();
            if (!failed_ && !remoteClosed_ && !closeRequested_.load(std::memory_order_acquire)) {
                WaitForNetwork();
            }
        }
    } catch (const std::bad_alloc &) {
        Fail("native session resource exhaustion");
    } catch (...) {
        Fail("native session failure");
    }
    acceptingInput_.store(false, std::memory_order_release);
    trustPending_.store(false, std::memory_order_release);
    ClearInput();
    DestroyTransport();
    SecureClear(options_->password);
    SecureClear(options_->privateKey);
    stage_ = Stage::Finished;
    if (failed_) {
        state_.store(PublicState::Failed, std::memory_order_release);
        EmitError(failureMessage_.empty() ? "SSH session failed" : failureMessage_, failureKind_);
        SetState(PublicState::Failed, "FAILED");
    } else {
        SetState(PublicState::Closed, "CLOSED");
    }
}

void Session::Advance() {
    if (stage_ != Stage::Connect && stage_ != Stage::Finished && stage_ != Stage::Open && session_ != nullptr &&
        !ssh_is_connected(session_) && !remoteEof_) {
        Fail("SSH transport disconnected", "network");
        return;
    }
    switch (stage_) {
        case Stage::Connect:
            AdvanceConnect();
            break;
        case Stage::VerifyHost:
            AdvanceVerifyHost();
            break;
        case Stage::WaitTrust:
            CheckDeadline("host key confirmation timed out");
            break;
        case Stage::Authenticate:
            AdvanceAuthenticate();
            break;
        case Stage::WaitAuth:
            CheckDeadline("authentication prompt timed out");
            break;
        case Stage::OpenChannel:
            AdvanceOpenChannel();
            break;
        case Stage::RequestPty:
            AdvanceRequestPty();
            break;
        case Stage::RequestShell:
            AdvanceRequestShell();
            break;
        case Stage::Open:
            AdvanceOpen();
            break;
        case Stage::Finished:
            break;
    }
}

void Session::AdvanceConnect() {
    if (!handshakeDeadlineStarted_ && ssh_is_connected(session_)) {
        deadline_ = std::chrono::steady_clock::now() + kHandshakeTimeout;
        handshakeDeadlineStarted_ = true;
    }
    int result = ssh_connect(session_);
    if (result == SSH_AGAIN) {
        CheckDeadline(handshakeDeadlineStarted_ ? "SSH handshake timed out" : "SSH connection timed out");
        return;
    }
    if (result != SSH_OK) {
        Fail(handshakeDeadlineStarted_ ? "SSH handshake failed" : "SSH connection failed",
            handshakeDeadlineStarted_ ? "protocol" : "network");
        return;
    }
    CheckDeadline(handshakeDeadlineStarted_ ? "SSH handshake timed out" : "SSH connection timed out");
    if (failed_) {
        return;
    }
    event_ = ssh_event_new();
    if (event_ == nullptr || ssh_event_add_session(event_, session_) != SSH_OK) {
        Fail("could not initialize SSH polling");
        return;
    }
    if (!SetState(PublicState::VerifyingHost, "VERIFYING_HOST")) {
        Fail("native event delivery failed");
        return;
    }
    ChangeStage(Stage::VerifyHost, std::chrono::seconds(0));
}

void Session::BeginAuthentication() {
    trustPending_.store(false, std::memory_order_release);
    if (!SetState(PublicState::Authenticating, "AUTHENTICATING")) {
        Fail("native event delivery failed");
        return;
    }
    ChangeStage(Stage::Authenticate, kAuthenticationTimeout);
}

bool Session::DescribeHostKey(std::string &keyType, std::string &fingerprint) {
    ssh_key key = nullptr;
    unsigned char *hash = nullptr;
    size_t hashLength = 0;
    char *formatted = nullptr;
    if (ssh_get_server_publickey(session_, &key) != SSH_OK || key == nullptr) {
        return false;
    }
    const char *type = ssh_key_type_to_char(ssh_key_type(key));
    bool ok = type != nullptr &&
        ssh_get_publickey_hash(key, SSH_PUBLICKEY_HASH_SHA256, &hash, &hashLength) == SSH_OK && hash != nullptr;
    if (ok) {
        formatted = ssh_get_fingerprint_hash(SSH_PUBLICKEY_HASH_SHA256, hash, hashLength);
        ok = formatted != nullptr;
    }
    if (ok) {
        keyType = type;
        fingerprint = formatted;
    }
    if (formatted != nullptr) {
        ssh_string_free_char(formatted);
    }
    if (hash != nullptr) {
        ssh_clean_pubkey_hash(&hash);
    }
    ssh_key_free(key);
    return ok;
}

void Session::AdvanceVerifyHost() {
    ssh_known_hosts_e known;
    {
        std::lock_guard<std::mutex> lock(g_knownHostsMutex);
        known = ssh_session_is_known_server(session_);
    }
    if (known == SSH_KNOWN_HOSTS_OK) {
        auto identity = std::make_unique<NativeEvent>();
        identity->type = NativeEventType::HostIdentity;
        identity->sessionId = options_->sessionId;
        identity->connectionEpoch = options_->connectionEpoch;
        identity->host = options_->host;
        identity->port = options_->port;
        if (!DescribeHostKey(identity->keyType, identity->fingerprint) || !sink_.Emit(std::move(identity))) {
            Fail("could not report verified host identity");
            return;
        }
        BeginAuthentication();
        return;
    }
    if (known == SSH_KNOWN_HOSTS_CHANGED || known == SSH_KNOWN_HOSTS_OTHER) {
        Fail("host key does not match the trusted known_hosts entry");
        return;
    }
    if (known != SSH_KNOWN_HOSTS_UNKNOWN && known != SSH_KNOWN_HOSTS_NOT_FOUND) {
        Fail("could not validate the host key");
        return;
    }
    auto event = std::make_unique<NativeEvent>();
    event->type = NativeEventType::HostKey;
    event->sessionId = options_->sessionId;
    event->connectionEpoch = options_->connectionEpoch;
    event->terminalGeneration = options_->terminalGeneration;
    event->host = options_->host;
    event->port = options_->port;
    if (!DescribeHostKey(event->keyType, event->fingerprint)) {
        Fail("could not calculate the host key fingerprint");
        return;
    }
    trustQueued_.store(false, std::memory_order_release);
    trustPending_.store(true, std::memory_order_release);
    ChangeStage(Stage::WaitTrust, kTrustTimeout);
    if (!sink_.Emit(std::move(event))) {
        trustPending_.store(false, std::memory_order_release);
        Fail("native event delivery failed");
    }
}

void Session::AcceptHostKey() {
    ssh_known_hosts_e known;
    {
        std::lock_guard<std::mutex> lock(g_knownHostsMutex);
        known = ssh_session_is_known_server(session_);
        if ((known == SSH_KNOWN_HOSTS_UNKNOWN || known == SSH_KNOWN_HOSTS_NOT_FOUND) &&
            ssh_session_update_known_hosts(session_) == SSH_OK) {
            known = ssh_session_is_known_server(session_);
        }
    }
    if (known != SSH_KNOWN_HOSTS_OK) {
        Fail("could not persist and verify the accepted host key");
        return;
    }
    BeginAuthentication();
}

void Session::AdvanceAuthenticate() {
    const bool interactive = authStep_ > 0 || options_->authMethod == "keyboard-interactive";
    int result;
    if (interactive) {
        result = ssh_userauth_kbdint(session_, nullptr, nullptr);
    } else if (options_->authMethod.find("publickey") == 0) {
        if (privateKey_ == nullptr) {
            if (!SupportedPrivateKeyContainer(options_->privateKey)) {
                Fail("unsupported OpenSSH private key container or excessive KDF cost"); return;
            }
            int imported = ssh_pki_import_privkey_base64(options_->privateKey.c_str(), options_->password.c_str(),
                nullptr, nullptr, &privateKey_);
            if (imported != SSH_OK && options_->promptForSecret && options_->password.empty() && !localSecretAsked_) {
                if (privateKey_) { ssh_key_free(privateKey_); privateKey_ = nullptr; }
                RequestLocalSecret("私钥文件口令"); return;
            }
            SecureClear(options_->privateKey);
            SecureClear(options_->password);
            if (imported != SSH_OK || privateKey_ == nullptr || ssh_key_type(privateKey_) != SSH_KEYTYPE_ED25519) {
                Fail("invalid Ed25519 private key or passphrase");
                return;
            }
        }
        result = ssh_userauth_publickey(session_, nullptr, privateKey_);
    } else {
        if (options_->promptForSecret && options_->password.empty() && !localSecretAsked_) {
            RequestLocalSecret("本次连接密码"); return;
        }
        result = ssh_userauth_password(session_, nullptr, options_->password.c_str());
    }
    if (result == SSH_AUTH_INFO && interactive) { RequestAuthenticationAnswers(); return; }
    if (result == SSH_AUTH_AGAIN) {
        CheckDeadline("SSH authentication timed out");
        return;
    }
    if (result == SSH_AUTH_SUCCESS) {
        CheckDeadline("SSH authentication timed out");
        if (failed_) {
            return;
        }
        SecureClear(options_->password);
        if (privateKey_) { ssh_key_free(privateKey_); privateKey_ = nullptr; }
        channel_ = ssh_channel_new(session_);
        if (channel_ == nullptr) {
            Fail("could not allocate SSH channel");
            return;
        }
        ChangeStage(Stage::OpenChannel, kChannelTimeout);
        return;
    }
    if (result == SSH_AUTH_PARTIAL) {
        if (privateKey_) { ssh_key_free(privateKey_); privateKey_ = nullptr; }
        if (authStep_ == 0 && options_->authMethod.find("+keyboard-interactive") != std::string::npos) {
            SecureClear(options_->password);
            authStep_ = 1;
            ChangeStage(Stage::Authenticate, kAuthenticationTimeout);
        } else Fail("server requires an additional authentication method");
    } else if (result == SSH_AUTH_DENIED) {
        Fail("SSH authentication was rejected");
    } else {
        Fail("SSH authentication failed");
    }
}

void Session::RequestLocalSecret(const char *prompt) {
    localSecretAsked_ = true;
    localSecretPending_ = true;
    promptCount_ = 1;
    answerQueued_.store(false);
    auto event = std::make_unique<NativeEvent>();
    event->type = NativeEventType::AuthChallenge;
    event->sessionId = options_->sessionId;
    event->connectionEpoch = options_->connectionEpoch;
    event->terminalGeneration = options_->terminalGeneration;
    event->requestId = ++challengeId_;
    event->title = "H-Terminal 重新认证";
    event->instruction = "新连接需要重新认证；本次回答不会保存。旧命令不会重放。";
    event->prompts.push_back({prompt, false});
    ChangeStage(Stage::WaitAuth, kTrustTimeout);
    if (!sink_.Emit(std::move(event))) Fail("native event delivery failed");
}

void Session::RequestAuthenticationAnswers() {
    int count = ssh_userauth_kbdint_getnprompts(session_);
    if (count < 0 || count > 16 || ++authRounds_ > 32) { Fail("authentication prompt limit exceeded"); return; }
    auto event = std::make_unique<NativeEvent>();
    event->type = NativeEventType::AuthChallenge;
    event->sessionId = options_->sessionId;
    event->connectionEpoch = options_->connectionEpoch;
    event->requestId = ++challengeId_;
    const char *title = ssh_userauth_kbdint_getname(session_);
    const char *instruction = ssh_userauth_kbdint_getinstruction(session_);
    if ((title && strnlen(title, 4097) > 4096) || (instruction && strnlen(instruction, 4097) > 4096)) {
        Fail("authentication prompt too large"); return;
    }
    event->title = title ? title : "";
    event->instruction = instruction ? instruction : "";
    for (int i = 0; i < count; ++i) {
        char echo = 0;
        const char *prompt = ssh_userauth_kbdint_getprompt(session_, static_cast<unsigned int>(i), &echo);
        if (prompt == nullptr || strnlen(prompt, 4097) > 4096) { Fail("invalid authentication prompt"); return; }
        event->prompts.push_back({prompt, echo != 0});
    }
    promptCount_ = static_cast<size_t>(count);
    answerQueued_.store(false);
    ChangeStage(Stage::WaitAuth, kTrustTimeout);
    if (!sink_.Emit(std::move(event))) Fail("native event delivery failed");
}

void Session::AdvanceOpenChannel() {
    int result = ssh_channel_open_session(channel_);
    if (result == SSH_AGAIN) {
        CheckDeadline("SSH channel open timed out");
        return;
    }
    if (result != SSH_OK) {
        Fail("could not open SSH channel");
        return;
    }
    CheckDeadline("SSH channel open timed out");
    if (failed_) {
        return;
    }
    ptyRequestCols_ = cols_;
    ptyRequestRows_ = rows_;
    ChangeStage(Stage::RequestPty, kChannelTimeout);
}

void Session::AdvanceRequestPty() {
    int result = ssh_channel_request_pty_size(channel_, "xterm-256color", ptyRequestCols_, ptyRequestRows_);
    if (result == SSH_AGAIN) {
        CheckDeadline("PTY request timed out");
        return;
    }
    if (result != SSH_OK) {
        Fail("server rejected the xterm-256color PTY request");
        return;
    }
    CheckDeadline("PTY request timed out");
    if (failed_) {
        return;
    }
    appliedCols_ = ptyRequestCols_;
    appliedRows_ = ptyRequestRows_;
    ChangeStage(Stage::RequestShell, kChannelTimeout);
}

void Session::AdvanceRequestShell() {
    int result = ssh_channel_request_shell(channel_);
    if (result == SSH_AGAIN) {
        CheckDeadline("shell request timed out");
        return;
    }
    if (result != SSH_OK) {
        Fail("server rejected the shell request");
        return;
    }
    CheckDeadline("shell request timed out");
    if (failed_) {
        return;
    }
    if (!SetState(PublicState::Open, "OPEN")) {
        Fail("native event delivery failed");
        return;
    }
    ChangeStage(Stage::Open, std::chrono::seconds(0));
}

void Session::WaitForNetwork() {
    if (stage_ == Stage::Finished) {
        return;
    }
    if (transportError_) {
        std::this_thread::sleep_for(kPollInterval);
        return;
    }
    if (event_ != nullptr) {
        int result = ssh_event_dopoll(event_, static_cast<int>(kPollInterval.count()));
        if (result == SSH_ERROR && !closeRequested_.load(std::memory_order_acquire)) {
            if (stage_ == Stage::Open) {
                transportError_ = true;
                acceptingInput_.store(false, std::memory_order_release);
            } else {
                Fail("SSH network polling failed", "network");
            }
        }
        return;
    }
    socket_t fd = session_ == nullptr ? -1 : ssh_get_fd(session_);
    if (fd < 0) {
        std::this_thread::sleep_for(kPollInterval);
        return;
    }
    pollfd descriptor{};
    descriptor.fd = fd;
    descriptor.events = POLLIN;
    int result = poll(&descriptor, 1, static_cast<int>(kPollInterval.count()));
    if (result < 0 && errno != EINTR) {
        Fail("socket polling failed", "network");
    }
}

void Session::DrainCommands() {
    std::deque<Command> pending;
    {
        std::lock_guard<std::mutex> lock(commandMutex_);
        pending.swap(commands_);
    }
    for (auto &command : pending) {
        if (command.type == CommandType::Input) {
            InputChunk input;
            input.inputEpoch = command.inputEpoch;
            input.eventId = command.eventId;
            input.data = std::move(command.data);
            input.kind = command.kind;
            inputQueue_.push_back(std::move(input));
        } else {
            ApplyCommand(command);
        }
        if (failed_ || remoteClosed_ || closeRequested_.load(std::memory_order_acquire)) {
            break;
        }
    }
    for (auto &command : pending) {
        if (command.type == CommandType::Input && !command.data.empty()) {
            InputChunk input;
            input.data = std::move(command.data);
            DiscardInput(input);
        }
    }
}

void Session::ApplyCommand(Command &command) {
    switch (command.type) {
        case CommandType::Close:
            RequestClose();
            break;
        case CommandType::Trust:
            trustPending_.store(false, std::memory_order_release);
            trustQueued_.store(false, std::memory_order_release);
            if (stage_ == Stage::WaitTrust) {
                if (std::chrono::steady_clock::now() >= deadline_) {
                    Fail("host key confirmation timed out");
                } else if (command.accepted) {
                    AcceptHostKey();
                } else {
                    Fail("host key was rejected");
                }
            }
            break;
        case CommandType::Resize:
            cols_ = command.cols;
            rows_ = command.rows;
            break;
        case CommandType::Acknowledge:
            ApplyAcknowledge(command.seq, command.byteLength);
            break;
        case CommandType::Input:
            break;
        case CommandType::Probe:
            pendingProbeId_ = command.seq;
            break;
        case CommandType::ResetInput:
            ApplyInputReset(command.inputEpoch, command.accepted);
            break;
        case CommandType::AuthAnswer:
            if (stage_ == Stage::WaitAuth && command.seq == challengeId_.load() && command.answers.size() == promptCount_) {
                CheckDeadline("authentication prompt timed out");
                if (!failed_ && localSecretPending_) {
                    options_->password = std::move(command.answers[0]);
                    localSecretPending_ = false;
                    ChangeStage(Stage::Authenticate, kAuthenticationTimeout);
                    break;
                }
                for (size_t i = 0; !failed_ && i < command.answers.size(); ++i) {
                    if (ssh_userauth_kbdint_setanswer(session_, static_cast<unsigned int>(i), command.answers[i].c_str()) < 0) {
                        Fail("could not submit authentication response");
                    }
                }
                if (!failed_) ChangeStage(Stage::Authenticate, kAuthenticationTimeout);
            }
            break;
    }
}

void Session::ApplyAcknowledge(uint64_t seq, size_t byteLength) {
    auto found = std::find_if(unackedFrames_.begin(), unackedFrames_.end(),
        [seq](const UnackedFrame &frame) { return frame.seq == seq; });
    if (seq == 0 || byteLength == 0 || byteLength > kOutputFrameLimit || found == unackedFrames_.end() ||
        found->byteLength != byteLength) {
        EmitError("invalid, duplicate, or out-of-range output acknowledgement");
        return;
    }
    if (outputOutstanding_ < byteLength) {
        Fail("output acknowledgement accounting underflow");
        return;
    }
    outputOutstanding_ -= byteLength;
    unackedBytes_.store(outputOutstanding_);
    ++acknowledgedFrames_;
    unackedFrames_.erase(found);
}

void Session::DiscardInput(InputChunk &input) {
    size_t remaining = input.data.size() - input.offset;
    {
        std::lock_guard<std::mutex> lock(commandMutex_);
        queuedInputBytes_ = remaining > queuedInputBytes_ ? 0 : queuedInputBytes_ - remaining;
    }
    SecureClear(input.data);
}

void Session::ClearInput() {
    std::lock_guard<std::mutex> lock(commandMutex_);
    for (auto &command : commands_) {
        if (command.type == CommandType::Input) {
            SecureClear(command.data);
        }
    }
    commands_.clear();
    for (auto &input : inputQueue_) {
        SecureClear(input.data);
    }
    inputQueue_.clear();
    queuedInputBytes_ = 0;
    seenEventIds_.clear();
    eventIdOrder_.clear();
    acceptedPasteId_.clear();
    acceptedPasteBrackets_ = false;
    pasteOpened_ = false;
}

void Session::ApplyInputReset(uint64_t epoch, bool sendControl) {
    if (hasInputEpoch_.load() && epoch < latestInputEpoch_.load()) return;
    if (inputResetApplied_) {
        if (!inputQueue_.empty() && inputQueue_.back().kind == InputKind::Reset) inputQueue_.pop_back();
        InputChunk control;
        control.inputEpoch = epoch;
        control.eventId = "reset-control";
        if (sendControl) {
            control.data = {3};
            inputQueue_.push_back(std::move(control));
            std::lock_guard<std::mutex> lock(commandMutex_);
            ++queuedInputBytes_;
        }
        InputChunk marker;
        marker.kind = InputKind::Reset;
        marker.eventId = "reset-control";
        inputQueue_.push_back(std::move(marker));
        for (auto &input : inputQueue_) input.inputEpoch = epoch;
        latestInputEpoch_.store(epoch);
        return;
    }
    std::deque<InputChunk> completion;
    bool closeBracket = pasteOpened_;
    if (!inputQueue_.empty() && inputQueue_.front().offset > 0) {
        InputChunk &current = inputQueue_.front();
        size_t end = current.offset;
        if (current.kind == InputKind::PasteStart || current.kind == InputKind::PasteEnd) {
            end = current.data.size();
            closeBracket = current.kind == InputKind::PasteStart;
        } else {
            while (end < current.data.size() && (current.data[end] & 0xc0) == 0x80) ++end;
        }
        if (end > current.offset) {
            InputChunk suffix;
            suffix.inputEpoch = epoch;
            suffix.eventId = "reset-suffix";
            suffix.data.assign(current.data.begin() + current.offset, current.data.begin() + end);
            completion.push_back(std::move(suffix));
        }
    }
    for (auto &input : inputQueue_) DiscardInput(input);
    inputQueue_.clear();
    auto append = [&](std::vector<uint8_t> bytes, InputKind kind) {
        InputChunk input;
        input.inputEpoch = epoch;
        input.eventId = "reset-control";
        input.kind = kind;
        input.data = std::move(bytes);
        completion.push_back(std::move(input));
    };
    if (closeBracket) append({27, '[', '2', '0', '1', '~'}, InputKind::Normal);
    if (sendControl) append({3}, InputKind::Normal);
    append({}, InputKind::Reset);
    {
        std::lock_guard<std::mutex> lock(commandMutex_);
        latestInputEpoch_.store(epoch);
        hasInputEpoch_.store(true);
        seenEventIds_.clear();
        eventIdOrder_.clear();
        acceptedPasteId_.clear();
        acceptedPasteBrackets_ = false;
        for (const auto &input : completion) queuedInputBytes_ += input.data.size();
        UpdatePeak(peakInputBytes_, queuedInputBytes_);
    }
    pasteOpened_ = false;
    inputResetApplied_ = true;
    inputQueue_.swap(completion);
}

void Session::ProcessInput() {
    if (!IsOpenForInput()) {
        return;
    }
    auto emitInputEvent = [this](NativeEventType type, const InputChunk &input, size_t byteLength) {
        auto event = std::make_unique<NativeEvent>();
        event->type = type;
        event->sessionId = options_->sessionId;
        event->connectionEpoch = options_->connectionEpoch;
        event->terminalGeneration = options_->terminalGeneration;
        event->inputEpoch = input.inputEpoch;
        event->eventId = input.eventId;
        event->byteLength = byteLength;
        return sink_.Emit(std::move(event));
    };
    size_t writes = 0;
    while (!inputQueue_.empty() && writes < 16 && !resizeActive_ && IsOpenForInput()) {
        if (inputResetPending_.load() && !inputResetApplied_) break;
        InputChunk &input = inputQueue_.front();
        if (!hasInputEpoch_.load(std::memory_order_acquire) ||
            input.inputEpoch != latestInputEpoch_.load(std::memory_order_acquire)) {
            DiscardInput(input);
            inputQueue_.pop_front();
            continue;
        }
        size_t remaining = input.data.size() - input.offset;
        if (remaining == 0) {
            if (input.kind == InputKind::Reset) {
                inputResetApplied_ = false;
                inputResetPending_.store(false, std::memory_order_release);
                emitInputEvent(NativeEventType::InputReset, input, 0);
            } else {
                if (input.kind == InputKind::PasteEnd) {
                    std::lock_guard<std::mutex> lock(commandMutex_);
                    acceptedPasteId_.clear();
                }
                emitInputEvent(NativeEventType::InputConsumed, input, 0);
            }
            SecureClear(input.data);
            inputQueue_.pop_front();
            continue;
        }
        if ((ssh_get_status(session_) & SSH_WRITE_PENDING) != 0) {
            break;
        }
        int result = ssh_channel_write(channel_, input.data.data() + input.offset,
            static_cast<uint32_t>(remaining));
        if (result == SSH_AGAIN || result == 0) {
            break;
        }
        if (result < 0 || static_cast<size_t>(result) > remaining) {
            Fail("SSH channel input write failed", "network");
            return;
        }
        size_t written = static_cast<size_t>(result);
        inputBytes_.fetch_add(written);
        size_t availableCredit = 0;
        input.offset += written;
        if (input.offset == input.data.size()) {
            if (input.kind == InputKind::PasteStart) pasteOpened_ = !input.data.empty();
            if (input.kind == InputKind::PasteEnd) {
                pasteOpened_ = false;
                std::lock_guard<std::mutex> lock(commandMutex_);
                acceptedPasteId_.clear();
            }
        }
        {
            std::lock_guard<std::mutex> lock(commandMutex_);
            if (written > queuedInputBytes_) {
                Fail("terminal input accounting underflow");
                return;
            }
            queuedInputBytes_ -= written;
            availableCredit = kInputQueueLimit - queuedInputBytes_;
        }
        if (!emitInputEvent(NativeEventType::InputConsumed, input, written) ||
            !emitInputEvent(NativeEventType::InputCredit, input, availableCredit)) {
            Fail("native event delivery failed");
            return;
        }
        ++writes;
        if (input.offset == input.data.size()) {
            SecureClear(input.data);
            inputQueue_.pop_front();
        }
    }
}

void Session::ProcessResize() {
    if (resizeActive_) {
        int result = ssh_channel_change_pty_size(channel_, resizeCols_, resizeRows_);
        if (result == SSH_AGAIN) {
            return;
        }
        if (result != SSH_OK) {
            Fail("terminal resize request failed");
            return;
        }
        appliedCols_ = resizeCols_;
        appliedRows_ = resizeRows_;
        resizeActive_ = false;
    }
    if (!resizeActive_ && (cols_ != appliedCols_ || rows_ != appliedRows_)) {
        resizeCols_ = cols_;
        resizeRows_ = rows_;
        resizeActive_ = true;
    }
}

bool Session::EmitOutput(const uint8_t *data, size_t length) {
    if (length == 0 || length > kOutputFrameLimit || nextSeq_ == 0 || nextSeq_ > kMaxSafeInteger ||
        outputOutstanding_ > kOutputHighWater - length) {
        Fail("output frame or in-flight budget overflow");
        return false;
    }
    uint64_t seq = nextSeq_++;
    auto event = std::make_unique<NativeEvent>();
    event->type = NativeEventType::Output;
    event->sessionId = options_->sessionId;
    event->connectionEpoch = options_->connectionEpoch;
    event->terminalGeneration = options_->terminalGeneration;
    event->seq = seq;
    event->byteLength = length;
    event->data = Base64(data, length);
    unackedFrames_.push_back(UnackedFrame{seq, length});
    outputOutstanding_ += length;
    outputBytes_.fetch_add(length);
    ++outputFrames_;
    unackedBytes_.store(outputOutstanding_);
    UpdatePeak(peakUnackedBytes_, outputOutstanding_);
    if (!sink_.Emit(std::move(event))) {
        Fail("output event delivery failed");
        return false;
    }
    return true;
}

void Session::ReadOutputStream(int stream, size_t &available) {
    size_t credit = kOutputHighWater - outputOutstanding_;
    size_t length = std::min({available, kOutputFrameLimit, credit});
    if (length == 0) {
        return;
    }
    std::vector<uint8_t> buffer(length);
    int result = ssh_channel_read_nonblocking(channel_, buffer.data(), static_cast<uint32_t>(length), stream);
    if (result == SSH_AGAIN || result == 0) {
        return;
    }
    if (result == SSH_EOF) {
        remoteEof_ = true;
        acceptingInput_.store(false, std::memory_order_release);
        return;
    }
    if (result < 0 || static_cast<size_t>(result) > length) {
        Fail("SSH channel output read failed");
        return;
    }
    size_t count = static_cast<size_t>(result);
    available = count > available ? 0 : available - count;
    EmitOutput(buffer.data(), count);
}

void Session::PollOutput() {
    size_t available[2] = {0, 0};
    auto pollStreams = [this, &available]() {
        for (int stream = 0; stream < 2; ++stream) {
            int result = ssh_channel_poll(channel_, stream);
            available[stream] = result > 0 ? static_cast<size_t>(result) : 0;
            if (result == SSH_EOF) {
                remoteEof_ = true;
                acceptingInput_.store(false, std::memory_order_release);
            } else if (result < 0) {
                transportError_ = true;
                acceptingInput_.store(false, std::memory_order_release);
            }
        }
    };
    pollStreams();
    if (remoteEof_ || transportError_ || ssh_channel_is_closed(channel_)) {
        // Polling stderr may process packets that append stdout after its
        // first sample. Recheck both buffers once the terminal status is known.
        pollStreams();
    }
    size_t buffered = available[0] + available[1];
    UpdatePeak(peakReceiveBytes_, buffered + outputOutstanding_);
    if (outputOutstanding_ > kOutputHardLimit || buffered > kOutputHardLimit - outputOutstanding_) {
        Fail("receive queue and in-flight output exceeded the receive budget");
        return;
    }
    if (outputPaused_) {
        if (outputOutstanding_ <= kOutputLowWater) {
            outputPaused_ = false;
        }
    } else if (outputOutstanding_ >= kOutputHighWater) {
        outputPaused_ = true;
    }
    if (remoteEof_ && buffered == 0) {
        HandleRemoteClosed();
        return;
    }
    if (transportError_ && buffered == 0) {
        Fail("SSH transport disconnected after output drained", "network");
        return;
    }
    if (ssh_channel_is_closed(channel_) && buffered == 0) {
        HandleRemoteClosed();
        return;
    }
    if (outputPaused_ || unackedFrames_.size() >= kMaxUnackedFrames) {
        return;
    }
    if (available[0] > 0) {
        ReadOutputStream(0, available[0]);
        if (failed_) {
            return;
        }
    }
    if (outputOutstanding_ >= kOutputHighWater) {
        outputPaused_ = true;
    }
    if (!outputPaused_ && available[1] > 0 && unackedFrames_.size() < kMaxUnackedFrames) {
        ReadOutputStream(1, available[1]);
        if (failed_) {
            return;
        }
    }
    if (outputOutstanding_ >= kOutputHighWater) {
        outputPaused_ = true;
    }
}

void Session::HandleRemoteClosed() {
    if (remoteClosed_) {
        return;
    }
    acceptingInput_.store(false, std::memory_order_release);
    remoteClosed_ = true;
    stage_ = Stage::Finished;
}

void Session::AdvanceOpen() {
    PollOutput();
    if (failed_ || remoteClosed_ || remoteEof_ || transportError_) {
        return;
    }
    if (activeProbeId_ != 0) {
        ProcessProbe();
        return;
    }
    ProcessResize();
    if (failed_) {
        return;
    }
    if (pendingProbeId_ != 0 && !resizeActive_) {
        ProcessProbe();
        return;
    }
    ProcessInput();
}

void Session::ProcessProbe() {
    if (activeProbeId_ == 0) {
        activeProbeId_ = pendingProbeId_;
        pendingProbeId_ = 0;
        probeDeadline_ = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    }
    if (std::chrono::steady_clock::now() >= probeDeadline_) {
        Fail("SSH connection check timed out", "network");
        return;
    }
    // A channel request with want-reply proves the remote endpoint responded.
    // Both success and an explicit rejection are healthy responses. This does
    // not execute a command or write to the shell's input stream.
    int result = ssh_channel_request_env(channel_, "HTERMINAL_CONNECTION_CHECK", "");
    if (result == SSH_AGAIN) return;
    if (result != SSH_OK && ssh_get_error_code(session_) != SSH_REQUEST_DENIED) {
        Fail("SSH connection check failed", "network");
        return;
    }
    auto event = std::make_unique<NativeEvent>();
    event->type = NativeEventType::Probe;
    event->sessionId = options_->sessionId;
    event->connectionEpoch = options_->connectionEpoch;
    event->requestId = activeProbeId_;
    activeProbeId_ = 0;
    acceptingInput_.store(pendingProbeId_ == 0 && !closeRequested_.load(), std::memory_order_release);
    if (!sink_.Emit(std::move(event))) {
        Fail("native event delivery failed");
    }
}

} // namespace hterminal
