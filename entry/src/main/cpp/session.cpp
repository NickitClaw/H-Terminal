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
#include <utility>

namespace hterminal {
namespace {

constexpr size_t kOutputFrameLimit = 32 * 1024;
constexpr size_t kOutputHighWater = 256 * 1024;
constexpr size_t kOutputLowWater = 64 * 1024;
constexpr size_t kOutputHardLimit = 1024 * 1024;
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

Session::Session(std::unique_ptr<NativeConnectOptions> options, NativeEventSink &sink)
    : options_(std::move(options)), sink_(sink), cols_(options_->cols), rows_(options_->rows) {}

Session::~Session() {
    Stop();
    SecureClear(options_->password);
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

bool Session::WriteInput(uint64_t inputEpoch, const std::string &eventId, std::vector<uint8_t> data) {
    if (data.empty() || data.size() > kInputQueueLimit || !IsOpenForInput()) {
        return false;
    }
    try {
        std::lock_guard<std::mutex> lock(commandMutex_);
        if (!IsOpenForInput() || queuedInputBytes_ > kInputQueueLimit - data.size()) {
            return false;
        }
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
        commands_.push_back(std::move(command));
        queuedInputBytes_ += commands_.back().data.size();
        return true;
    } catch (...) {
        return false;
    }
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

void Session::EmitError(const std::string &message) {
    auto event = std::make_unique<NativeEvent>();
    event->type = NativeEventType::Error;
    event->sessionId = options_->sessionId;
    event->connectionEpoch = options_->connectionEpoch;
    event->terminalGeneration = options_->terminalGeneration;
    event->message = message;
    sink_.Emit(std::move(event));
}

void Session::Fail(const std::string &message) {
    if (failed_ || remoteClosed_ || closeRequested_.load(std::memory_order_acquire)) {
        return;
    }
    failed_ = true;
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
        Fail(message);
    }
}

bool Session::CreateTransport() {
    std::call_once(g_sshInitFlag, []() { g_sshInitResult = ssh_init(); });
    if (g_sshInitResult != SSH_OK) {
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
    stage_ = Stage::Finished;
    if (failed_) {
        state_.store(PublicState::Failed, std::memory_order_release);
        EmitError(failureMessage_.empty() ? "SSH session failed" : failureMessage_);
        SetState(PublicState::Failed, "FAILED");
    } else {
        SetState(PublicState::Closed, "CLOSED");
    }
}

void Session::Advance() {
    if (stage_ != Stage::Connect && stage_ != Stage::Finished && session_ != nullptr &&
        !ssh_is_connected(session_) && !remoteEof_) {
        Fail("SSH transport disconnected");
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
        Fail(handshakeDeadlineStarted_ ? "SSH handshake failed" : "SSH connection failed");
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
    int result = ssh_userauth_password(session_, nullptr, options_->password.c_str());
    if (result == SSH_AUTH_AGAIN) {
        CheckDeadline("password authentication timed out");
        return;
    }
    if (result == SSH_AUTH_SUCCESS) {
        CheckDeadline("password authentication timed out");
        if (failed_) {
            return;
        }
        SecureClear(options_->password);
        channel_ = ssh_channel_new(session_);
        if (channel_ == nullptr) {
            Fail("could not allocate SSH channel");
            return;
        }
        ChangeStage(Stage::OpenChannel, kChannelTimeout);
        return;
    }
    if (result == SSH_AUTH_PARTIAL) {
        Fail("server requires an additional authentication method");
    } else if (result == SSH_AUTH_DENIED) {
        Fail("password authentication was rejected");
    } else {
        Fail("password authentication failed");
    }
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
    if (event_ != nullptr) {
        int result = ssh_event_dopoll(event_, static_cast<int>(kPollInterval.count()));
        if (result == SSH_ERROR && !closeRequested_.load(std::memory_order_acquire)) {
            Fail("SSH network polling failed");
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
        Fail("socket polling failed");
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
        InputChunk &input = inputQueue_.front();
        if (!hasInputEpoch_.load(std::memory_order_acquire) ||
            input.inputEpoch != latestInputEpoch_.load(std::memory_order_acquire)) {
            DiscardInput(input);
            inputQueue_.pop_front();
            continue;
        }
        size_t remaining = input.data.size() - input.offset;
        if (remaining == 0) {
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
            Fail("SSH channel input write failed");
            return;
        }
        size_t written = static_cast<size_t>(result);
        size_t availableCredit = 0;
        input.offset += written;
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
        outputOutstanding_ > kOutputHardLimit - length) {
        Fail("output frame or receive budget overflow");
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
    if (!sink_.Emit(std::move(event))) {
        Fail("output event delivery failed");
        return false;
    }
    return true;
}

void Session::ReadOutputStream(int stream, size_t &available) {
    size_t length = std::min(available, kOutputFrameLimit);
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
    for (int stream = 0; stream < 2; ++stream) {
        int result = ssh_channel_poll(channel_, stream);
        if (result == SSH_EOF) {
            remoteEof_ = true;
            acceptingInput_.store(false, std::memory_order_release);
            continue;
        }
        if (result < 0) {
            Fail("SSH channel polling failed");
            return;
        }
        available[stream] = static_cast<size_t>(result);
    }
    size_t buffered = available[0] + available[1];
    if (outputOutstanding_ > kOutputHardLimit || buffered > kOutputHardLimit - outputOutstanding_) {
        Fail("receive queue and in-flight output exceeded 1 MiB");
        return;
    }
    size_t total = outputOutstanding_ + buffered;
    if (outputPaused_) {
        if (outputOutstanding_ <= kOutputLowWater) {
            outputPaused_ = false;
        }
    } else if (total >= kOutputHighWater) {
        outputPaused_ = true;
    }
    if (remoteEof_ && buffered == 0) {
        HandleRemoteClosed();
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
    total = outputOutstanding_ + available[0] + available[1];
    if (total >= kOutputHighWater) {
        outputPaused_ = true;
    }
    if (!outputPaused_ && available[1] > 0 && unackedFrames_.size() < kMaxUnackedFrames) {
        ReadOutputStream(1, available[1]);
        if (failed_) {
            return;
        }
    }
    total = outputOutstanding_ + available[0] + available[1];
    if (total >= kOutputHighWater) {
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
    if (failed_ || remoteClosed_ || remoteEof_) {
        return;
    }
    ProcessResize();
    if (failed_) {
        return;
    }
    ProcessInput();
}

} // namespace hterminal
