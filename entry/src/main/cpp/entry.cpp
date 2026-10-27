#include "session_registry.h"

#include <napi/native_api.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace hterminal {
namespace {

constexpr uint64_t kMaxSafeInteger = 9007199254740991ULL;
constexpr size_t kMaxInputBytes = 64 * 1024;

void DispatchEvent(napi_env env, napi_value callback, void *context, void *data);

class Manager final {
    class GenerationSink final : public NativeEventSink {
    public:
        GenerationSink(Manager &manager, uint64_t generation) : manager_(manager), generation_(generation) {}
        bool Emit(std::unique_ptr<NativeEvent> event) override {
            return manager_.Emit(generation_, std::move(event));
        }
    private:
        Manager &manager_;
        uint64_t generation_;
    };
public:
    static Manager &Instance() {
        static Manager manager;
        return manager;
    }

    bool Initialize(napi_env env, napi_value callback, std::string &error) {
        std::lock_guard<std::mutex> operationLock(operationMutex_);
        napi_value resourceName = nullptr;
        if (napi_create_string_utf8(env, "H-Terminal Native SSH", NAPI_AUTO_LENGTH, &resourceName) != napi_ok) {
            error = "could not name the native event callback";
            return false;
        }
        napi_threadsafe_function newCallback = nullptr;
        napi_status status = napi_create_threadsafe_function(env, callback, nullptr, resourceName, 0, 1,
            nullptr, nullptr, this, DispatchEvent, &newCallback);
        if (status != napi_ok) {
            error = "could not create the native event callback";
            return false;
        }
        if (cleanupEnv_ != env) {
            if (cleanupEnv_ != nullptr) {
                napi_remove_env_cleanup_hook(cleanupEnv_, &Manager::EnvironmentCleanup, this);
            }
            status = napi_add_env_cleanup_hook(env, &Manager::EnvironmentCleanup, this);
            if (status != napi_ok) {
                napi_release_threadsafe_function(newCallback, napi_tsfn_abort);
                error = "could not register native environment cleanup";
                return false;
            }
            cleanupEnv_ = env;
        }
        registry_.CloseAll();
        napi_threadsafe_function oldCallback = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            disposed_ = false;
            ++callbackGeneration_;
            oldCallback = callback_;
            callback_ = newCallback;
        }
        if (oldCallback != nullptr) {
            napi_release_threadsafe_function(oldCallback, napi_tsfn_abort);
        }
        return true;
    }

    void Dispose() {
        std::lock_guard<std::mutex> operationLock(operationMutex_);
        napi_threadsafe_function oldCallback = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            disposed_ = true;
            ++callbackGeneration_;
            oldCallback = callback_;
            callback_ = nullptr;
        }
        registry_.CloseAll();
        if (oldCallback != nullptr) {
            napi_release_threadsafe_function(oldCallback, napi_tsfn_abort);
        }
    }

    bool Connect(std::unique_ptr<NativeConnectOptions> options, std::string &error) {
        std::lock_guard<std::mutex> operationLock(operationMutex_);
        uint64_t generation;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (disposed_ || callback_ == nullptr) {
                error = "native SSH is not initialized";
                return false;
            }
            generation = callbackGeneration_;
        }
        return registry_.Connect(std::move(options), std::make_shared<GenerationSink>(*this, generation), error);
    }

    std::shared_ptr<Session> Find(const std::string &sessionId, uint64_t connectionEpoch) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (disposed_) {
            return nullptr;
        }
        return registry_.Find(sessionId, connectionEpoch);
    }

    void Close(const std::string &sessionId, uint64_t connectionEpoch) {
        std::lock_guard<std::mutex> operationLock(operationMutex_);
        registry_.Close(sessionId, connectionEpoch);
    }

    bool Emit(uint64_t generation, std::unique_ptr<NativeEvent> event) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (disposed_ || callback_ == nullptr || generation != callbackGeneration_) {
            return false;
        }
        napi_status status = napi_call_threadsafe_function(callback_, event.get(), napi_tsfn_nonblocking);
        if (status != napi_ok) {
            return false;
        }
        event.release();
        return true;
    }

private:
    static void EnvironmentCleanup(void *data) {
        auto *manager = static_cast<Manager *>(data);
        manager->Dispose();
        std::lock_guard<std::mutex> lock(manager->operationMutex_);
        manager->cleanupEnv_ = nullptr;
    }

    std::mutex operationMutex_;
    std::mutex mutex_;
    napi_threadsafe_function callback_ = nullptr;
    napi_env cleanupEnv_ = nullptr;
    bool disposed_ = true;
    uint64_t callbackGeneration_ = 0;
    // Declared last so workers are joined before their event sink is destroyed.
    SessionRegistry registry_;
};

bool SetString(napi_env env, napi_value object, const char *name, const std::string &value) {
    napi_value string = nullptr;
    return napi_create_string_utf8(env, value.c_str(), value.size(), &string) == napi_ok &&
        napi_set_named_property(env, object, name, string) == napi_ok;
}

bool SetNumber(napi_env env, napi_value object, const char *name, uint64_t value) {
    napi_value number = nullptr;
    return napi_create_double(env, static_cast<double>(value), &number) == napi_ok &&
        napi_set_named_property(env, object, name, number) == napi_ok;
}

void DispatchEvent(napi_env env, napi_value callback, void *context, void *data) {
    (void)context;
    std::unique_ptr<NativeEvent> event(static_cast<NativeEvent *>(data));
    if (env == nullptr || callback == nullptr) {
        return;
    }
    napi_handle_scope scope = nullptr;
    if (napi_open_handle_scope(env, &scope) != napi_ok) {
        return;
    }
    napi_value object = nullptr;
    napi_value undefined = nullptr;
    bool ok = napi_create_object(env, &object) == napi_ok &&
        napi_get_undefined(env, &undefined) == napi_ok;
    if (ok) {
        switch (event->type) {
            case NativeEventType::State:
                ok = SetString(env, object, "type", "state") &&
                    SetString(env, object, "state", event->state);
                break;
            case NativeEventType::HostKey:
            case NativeEventType::HostIdentity:
                ok = SetString(env, object, "type", event->type == NativeEventType::HostKey ? "hostKey" : "hostIdentity") &&
                    SetString(env, object, "host", event->host) &&
                    SetNumber(env, object, "port", event->port) &&
                    SetString(env, object, "keyType", event->keyType) &&
                    SetString(env, object, "fingerprint", event->fingerprint);
                break;
            case NativeEventType::Output:
                ok = SetString(env, object, "type", "output") &&
                    SetNumber(env, object, "seq", event->seq) &&
                    SetNumber(env, object, "byteLength", event->byteLength) &&
                    SetString(env, object, "data", event->data);
                break;
            case NativeEventType::Error:
                ok = SetString(env, object, "type", "error") &&
                    SetString(env, object, "message", event->message);
                break;
            case NativeEventType::InputCredit:
                ok = SetString(env, object, "type", "inputCredit") &&
                    SetNumber(env, object, "byteLength", event->byteLength) &&
                    SetNumber(env, object, "inputEpoch", event->inputEpoch) &&
                    SetString(env, object, "eventId", event->eventId);
                break;
            case NativeEventType::InputConsumed:
                ok = SetString(env, object, "type", "inputConsumed") &&
                    SetNumber(env, object, "byteLength", event->byteLength) &&
                    SetNumber(env, object, "inputEpoch", event->inputEpoch) &&
                    SetString(env, object, "eventId", event->eventId);
                break;
            case NativeEventType::Probe:
                ok = SetString(env, object, "type", "probe") &&
                    SetNumber(env, object, "requestId", event->requestId);
                break;
            case NativeEventType::InputReset:
                ok = SetString(env, object, "type", "inputReset") &&
                    SetNumber(env, object, "inputEpoch", event->inputEpoch);
                break;
            case NativeEventType::AuthChallenge: {
                napi_value prompts = nullptr;
                ok = SetString(env, object, "type", "authChallenge") &&
                    SetNumber(env, object, "requestId", event->requestId) &&
                    SetString(env, object, "title", event->title) && SetString(env, object, "instruction", event->instruction) &&
                    napi_create_array_with_length(env, event->prompts.size(), &prompts) == napi_ok;
                for (size_t i = 0; ok && i < event->prompts.size(); ++i) {
                    napi_value prompt = nullptr, echo = nullptr;
                    ok = napi_create_object(env, &prompt) == napi_ok &&
                        SetString(env, prompt, "text", event->prompts[i].text) &&
                        napi_get_boolean(env, event->prompts[i].echo, &echo) == napi_ok &&
                        napi_set_named_property(env, prompt, "echo", echo) == napi_ok &&
                        napi_set_element(env, prompts, static_cast<uint32_t>(i), prompt) == napi_ok;
                }
                ok = ok && napi_set_named_property(env, object, "prompts", prompts) == napi_ok;
                break;
            }
        }
        ok = ok && SetString(env, object, "sessionId", event->sessionId) &&
            SetNumber(env, object, "connectionEpoch", event->connectionEpoch) &&
            SetNumber(env, object, "terminalGeneration", event->terminalGeneration);
    }
    if (ok) {
        napi_value result = nullptr;
        napi_call_function(env, undefined, callback, 1, &object, &result);
    }
    napi_close_handle_scope(env, scope);
}

napi_value Undefined(napi_env env) {
    napi_value value = nullptr;
    napi_get_undefined(env, &value);
    return value;
}

bool Arguments(napi_env env, napi_callback_info info, size_t expected, std::vector<napi_value> &args) {
    size_t argc = expected;
    args.resize(expected);
    return napi_get_cb_info(env, info, &argc, args.data(), nullptr, nullptr) == napi_ok && argc >= expected;
}

bool ReadString(napi_env env, napi_value value, std::string &result, size_t maximum) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > maximum) {
        return false;
    }
    std::vector<char> buffer(length + 1, 0);
    size_t copied = 0;
    napi_status status = napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied);
    if (status == napi_ok) {
        result.assign(buffer.data(), copied);
    }
    volatile char *sensitive = buffer.data();
    for (size_t i = 0; i < buffer.size(); ++i) {
        sensitive[i] = 0;
    }
    return status == napi_ok;
}

bool ReadNumber(napi_env env, napi_value value, uint64_t &result) {
    double number = 0;
    if (napi_get_value_double(env, value, &number) != napi_ok || !std::isfinite(number) || number < 0 ||
        number > static_cast<double>(kMaxSafeInteger) || std::floor(number) != number) {
        return false;
    }
    result = static_cast<uint64_t>(number);
    return true;
}

bool ReadProperty(napi_env env, napi_value object, const char *name, napi_value &value) {
    return napi_get_named_property(env, object, name, &value) == napi_ok;
}

bool StringProperty(napi_env env, napi_value object, const char *name, std::string &value, size_t maximum) {
    napi_value property = nullptr;
    return ReadProperty(env, object, name, property) && ReadString(env, property, value, maximum);
}

bool NumberProperty(napi_env env, napi_value object, const char *name, uint64_t &value) {
    napi_value property = nullptr;
    return ReadProperty(env, object, name, property) && ReadNumber(env, property, value);
}

bool OptionalStringProperty(napi_env env, napi_value object, const char *name, std::string &value, size_t maximum) {
    napi_value property = nullptr;
    napi_valuetype type = napi_undefined;
    return ReadProperty(env, object, name, property) && napi_typeof(env, property, &type) == napi_ok &&
        (type == napi_undefined || ReadString(env, property, value, maximum));
}

bool ContainsNul(const std::string &value) {
    return value.find('\0') != std::string::npos;
}

std::unique_ptr<NativeConnectOptions> ParseConnectOptions(napi_env env, napi_value value) {
    auto options = std::make_unique<NativeConnectOptions>();
    uint64_t port = 0;
    uint64_t cols = 0;
    uint64_t rows = 0;
    bool ok = StringProperty(env, value, "sessionId", options->sessionId, 128) &&
        NumberProperty(env, value, "connectionEpoch", options->connectionEpoch) &&
        NumberProperty(env, value, "terminalGeneration", options->terminalGeneration) &&
        StringProperty(env, value, "filesDir", options->filesDir, 4096) &&
        StringProperty(env, value, "host", options->host, 1024) &&
        NumberProperty(env, value, "port", port) &&
        StringProperty(env, value, "username", options->username, 1024) &&
        StringProperty(env, value, "password", options->password, kMaxInputBytes) &&
        OptionalStringProperty(env, value, "authMethod", options->authMethod, 48) &&
        OptionalStringProperty(env, value, "privateKey", options->privateKey, kMaxInputBytes) &&
        NumberProperty(env, value, "cols", cols) && NumberProperty(env, value, "rows", rows);
    if (!ok || options->sessionId.empty() || options->filesDir.empty() || options->filesDir[0] != '/' ||
        options->host.empty() || options->username.empty() || port == 0 || port > 65535 || cols == 0 ||
        rows == 0 || cols > 65535 || rows > 65535 || ContainsNul(options->filesDir) || ContainsNul(options->host) ||
        ContainsNul(options->username) || ContainsNul(options->password) || ContainsNul(options->privateKey)) {
        return nullptr;
    }
    if (options->authMethod != "password" && options->authMethod != "publickey" &&
        options->authMethod != "keyboard-interactive" && options->authMethod != "password+keyboard-interactive" &&
        options->authMethod != "publickey+keyboard-interactive") return nullptr;
    options->port = static_cast<uint32_t>(port);
    options->cols = static_cast<int>(cols);
    options->rows = static_cast<int>(rows);
    return options;
}

napi_value Initialize(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    if (!Arguments(env, info, 1, args)) {
        napi_throw_error(env, "H-Terminal", "initialize requires one callback");
        return Undefined(env);
    }
    std::string error;
    if (!Manager::Instance().Initialize(env, args[0], error)) {
        napi_throw_error(env, "H-Terminal", error.c_str());
    }
    return Undefined(env);
}

napi_value Connect(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    if (!Arguments(env, info, 1, args)) {
        napi_throw_error(env, "H-Terminal", "connect requires options");
        return Undefined(env);
    }
    auto options = ParseConnectOptions(env, args[0]);
    if (options == nullptr) {
        napi_throw_error(env, "H-Terminal", "invalid native SSH connection options");
        return Undefined(env);
    }
    std::string error;
    if (!Manager::Instance().Connect(std::move(options), error)) {
        napi_throw_error(env, "H-Terminal", error.c_str());
    }
    return Undefined(env);
}

napi_value TrustDecision(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    uint64_t epoch = 0;
    bool accepted = false;
    std::string sessionId;
    if (!Arguments(env, info, 3, args) || !ReadString(env, args[0], sessionId, 128) || sessionId.empty() ||
        !ReadNumber(env, args[1], epoch) || napi_get_value_bool(env, args[2], &accepted) != napi_ok) {
        napi_throw_error(env, "H-Terminal", "invalid trust decision");
        return Undefined(env);
    }
    auto session = Manager::Instance().Find(sessionId, epoch);
    if (session != nullptr) {
        session->TrustDecision(accepted);
    }
    return Undefined(env);
}

napi_value ProbeSession(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    std::string id;
    uint64_t epoch = 0, request = 0;
    if (!Arguments(env, info, 3, args) || !ReadString(env, args[0], id, 128) || id.empty() ||
        !ReadNumber(env, args[1], epoch) || !ReadNumber(env, args[2], request) || request == 0) {
        napi_throw_error(env, "H-Terminal", "invalid connection check");
        return Undefined(env);
    }
    auto session = Manager::Instance().Find(id, epoch);
    if (session) session->Probe(request);
    return Undefined(env);
}

napi_value ResetInput(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    std::string id;
    uint64_t epoch = 0, inputEpoch = 0;
    bool sendControl = false;
    if (!Arguments(env, info, 4, args) || !ReadString(env, args[0], id, 128) || id.empty() ||
        !ReadNumber(env, args[1], epoch) || !ReadNumber(env, args[2], inputEpoch) ||
        napi_get_value_bool(env, args[3], &sendControl) != napi_ok) {
        napi_throw_error(env, "H-Terminal", "invalid input cancellation");
        return Undefined(env);
    }
    auto session = Manager::Instance().Find(id, epoch);
    if (session) session->ResetInput(inputEpoch, sendControl);
    return Undefined(env);
}

napi_value AnswerAuthentication(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    std::string id;
    uint64_t epoch = 0, request = 0;
    uint32_t count = 0;
    bool array = false;
    if (!Arguments(env, info, 4, args) || !ReadString(env, args[0], id, 128) || id.empty() ||
        !ReadNumber(env, args[1], epoch) || !ReadNumber(env, args[2], request) || request == 0 ||
        napi_is_array(env, args[3], &array) != napi_ok || !array ||
        napi_get_array_length(env, args[3], &count) != napi_ok || count > 16) {
        napi_throw_error(env, "H-Terminal", "invalid authentication response"); return Undefined(env);
    }
    std::vector<std::string> answers(count);
    for (uint32_t i = 0; i < count; ++i) {
        napi_value value = nullptr;
        if (napi_get_element(env, args[3], i, &value) != napi_ok || !ReadString(env, value, answers[i], 4096) ||
            ContainsNul(answers[i])) {
            for (auto &answer : answers) SecureClear(answer);
            napi_throw_error(env, "H-Terminal", "invalid authentication answer"); return Undefined(env);
        }
    }
    auto session = Manager::Instance().Find(id, epoch);
    if (session) session->AnswerAuthentication(request, std::move(answers));
    else for (auto &answer : answers) SecureClear(answer);
    return Undefined(env);
}

struct KeyInspection {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string key, passphrase, publicKey, fingerprint;
    bool success = false;
    int operation = 0;
    std::string filesDir, host, expectedFingerprint;
    uint32_t port = 0;
    ~KeyInspection() { SecureClear(key); SecureClear(passphrase); }
};

napi_value QueueKeyInspection(napi_env env, std::unique_ptr<KeyInspection> task) {
    napi_value promise = nullptr, name = nullptr;
    if (napi_create_promise(env, &task->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "Inspect SSH identity", NAPI_AUTO_LENGTH, &name) != napi_ok) {
        napi_throw_error(env, "H-Terminal", "could not prepare key operation"); return Undefined(env);
    }
    auto execute = [](napi_env, void *data) {
        auto *task = static_cast<KeyInspection *>(data);
        ssh_key key = nullptr;
        char *pub = nullptr, *fingerprint = nullptr;
        unsigned char *hash = nullptr;
        size_t length = 0;
        try {
        if (task->operation > 0) {
            TrustedHostKey known;
            task->success = AccessTrustedHostKey(task->filesDir, task->host, task->port, task->expectedFingerprint,
                task->operation == 2, known);
            task->publicKey = known.publicKey;
            task->fingerprint = known.fingerprint;
        } else if (SupportedPrivateKeyContainer(task->key) && EnsureSshInitialized() &&
            ssh_pki_import_privkey_base64(task->key.c_str(), task->passphrase.c_str(),
            nullptr, nullptr, &key) == SSH_OK && key && ssh_key_type(key) == SSH_KEYTYPE_ED25519 &&
            ssh_pki_export_pubkey_base64(key, &pub) == SSH_OK &&
            ssh_get_publickey_hash(key, SSH_PUBLICKEY_HASH_SHA256, &hash, &length) == SSH_OK) {
            fingerprint = ssh_get_fingerprint_hash(SSH_PUBLICKEY_HASH_SHA256, hash, length);
            if (pub && fingerprint) {
                task->publicKey = std::string("ssh-ed25519 ") + pub;
                task->fingerprint = fingerprint;
                task->success = true;
            }
        }
        } catch (...) { task->success = false; }
        if (key) ssh_key_free(key);
        if (pub) ssh_string_free_char(pub);
        if (fingerprint) ssh_string_free_char(fingerprint);
        if (hash) ssh_clean_pubkey_hash(&hash);
        SecureClear(task->key); SecureClear(task->passphrase);
    };
    auto complete = [](napi_env env, napi_status status, void *data) {
        std::unique_ptr<KeyInspection> task(static_cast<KeyInspection *>(data));
        if (env == nullptr) return;
        napi_value value = nullptr;
        if (status == napi_ok && task->success && napi_create_object(env, &value) == napi_ok &&
            SetString(env, value, "publicKey", task->publicKey) && SetString(env, value, "fingerprint", task->fingerprint)) {
            napi_resolve_deferred(env, task->deferred, value);
        } else {
            napi_value message = nullptr;
            napi_create_string_utf8(env, "Key operation failed: invalid key, passphrase or trusted fingerprint", NAPI_AUTO_LENGTH, &message);
            napi_create_error(env, nullptr, message, &value);
            napi_reject_deferred(env, task->deferred, value);
        }
        napi_delete_async_work(env, task->work);
    };
    if (napi_create_async_work(env, nullptr, name, execute, complete, task.get(), &task->work) != napi_ok ||
        napi_queue_async_work(env, task->work) != napi_ok) {
        if (task->work) napi_delete_async_work(env, task->work);
        napi_throw_error(env, "H-Terminal", "could not inspect private key"); return Undefined(env);
    }
    task.release();
    return promise;
}

napi_value InspectPrivateKey(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    auto task = std::make_unique<KeyInspection>();
    if (!Arguments(env, info, 2, args) || !ReadString(env, args[0], task->key, kMaxInputBytes) ||
        !ReadString(env, args[1], task->passphrase, 4096) || ContainsNul(task->key) || ContainsNul(task->passphrase)) {
        napi_throw_error(env, "H-Terminal", "invalid private key input"); return Undefined(env);
    }
    return QueueKeyInspection(env, std::move(task));
}

template<bool Remove> napi_value TrustedHostKeyOperation(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    auto task = std::make_unique<KeyInspection>();
    uint64_t port = 0;
    if (!Arguments(env, info, Remove ? 4 : 3, args) || !ReadString(env, args[0], task->filesDir, 4096) ||
        task->filesDir.empty() || task->filesDir[0] != '/' || !ReadString(env, args[1], task->host, 1024) ||
        task->host.empty() || !ReadNumber(env, args[2], port) || port == 0 || port > 65535 ||
        (Remove && (!ReadString(env, args[3], task->expectedFingerprint, 128) || task->expectedFingerprint.empty())) ||
        ContainsNul(task->filesDir) || ContainsNul(task->host)) {
        napi_throw_error(env, "H-Terminal", "invalid trusted-host operation"); return Undefined(env);
    }
    task->port = static_cast<uint32_t>(port);
    task->operation = Remove ? 2 : 1;
    return QueueKeyInspection(env, std::move(task));
}

enum class Base64InputResult {
    Success,
    Invalid,
    TooLarge,
};

int Base64InputValue(unsigned char value) {
    if (value >= 'A' && value <= 'Z') {
        return value - 'A';
    }
    if (value >= 'a' && value <= 'z') {
        return value - 'a' + 26;
    }
    if (value >= '0' && value <= '9') {
        return value - '0' + 52;
    }
    if (value == '+') {
        return 62;
    }
    if (value == '/') {
        return 63;
    }
    return -1;
}

Base64InputResult DecodeBase64Input(const std::string &text, std::vector<uint8_t> &output) {
    if (text.size() % 4 != 0) {
        return Base64InputResult::Invalid;
    }
    output.reserve((text.size() / 4) * 3);
    for (size_t offset = 0; offset < text.size(); offset += 4) {
        bool last = offset + 4 == text.size();
        int padding = text[offset + 3] == '=' ? (text[offset + 2] == '=' ? 2 : 1) : 0;
        if ((text[offset + 2] == '=' && text[offset + 3] != '=') || (padding != 0 && !last) ||
            text[offset] == '=' || text[offset + 1] == '=') {
            return Base64InputResult::Invalid;
        }
        uint32_t values[4] = {0, 0, 0, 0};
        for (size_t index = 0; index < 4; ++index) {
            char value = text[offset + index];
            if (index >= static_cast<size_t>(4 - padding)) {
                if (value != '=') {
                    return Base64InputResult::Invalid;
                }
                continue;
            }
            int decoded = Base64InputValue(static_cast<unsigned char>(value));
            if (decoded < 0) {
                return Base64InputResult::Invalid;
            }
            values[index] = static_cast<uint32_t>(decoded);
        }
        if ((padding == 1 && (values[2] & 0x03U) != 0) || (padding == 2 && (values[1] & 0x0fU) != 0)) {
            return Base64InputResult::Invalid;
        }
        size_t byteCount = 3 - static_cast<size_t>(padding);
        if (output.size() > kMaxInputBytes - byteCount) {
            return Base64InputResult::TooLarge;
        }
        uint32_t packed = (values[0] << 18) | (values[1] << 12) | (values[2] << 6) | values[3];
        output.push_back(static_cast<uint8_t>((packed >> 16) & 0xff));
        if (padding < 2) {
            output.push_back(static_cast<uint8_t>((packed >> 8) & 0xff));
        }
        if (padding == 0) {
            output.push_back(static_cast<uint8_t>(packed & 0xff));
        }
    }
    return Base64InputResult::Success;
}

napi_value WriteInput(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    if (!Arguments(env, info, 1, args)) {
        napi_throw_error(env, "H-Terminal", "writeInput requires a request");
        return Undefined(env);
    }
    std::string sessionId;
    std::string eventId;
    std::string data;
    uint64_t epoch = 0;
    uint64_t inputEpoch = 0;
    bool valid = StringProperty(env, args[0], "sessionId", sessionId, 128) && !sessionId.empty() &&
        NumberProperty(env, args[0], "connectionEpoch", epoch) &&
        NumberProperty(env, args[0], "inputEpoch", inputEpoch) &&
        StringProperty(env, args[0], "eventId", eventId, 128) && !eventId.empty();
    napi_value dataValue = nullptr;
    size_t dataLength = 0;
    valid = valid && ReadProperty(env, args[0], "data", dataValue) &&
        napi_get_value_string_utf8(env, dataValue, nullptr, 0, &dataLength) == napi_ok;
    if (!valid) {
        napi_throw_error(env, "H-Terminal", "invalid native input request");
        return Undefined(env);
    }
    constexpr size_t maxEncodedLength = ((kMaxInputBytes + 2) / 3) * 4;
    if (dataLength > maxEncodedLength) {
        napi_throw_error(env, "H-Terminal", "base64 terminal input is invalid or exceeds 64 KiB decoded");
        return Undefined(env);
    }
    if (dataLength > 0 && !ReadString(env, dataValue, data, maxEncodedLength)) {
        napi_throw_error(env, "H-Terminal", "invalid base64 terminal input");
        return Undefined(env);
    }
    std::vector<uint8_t> bytes;
    Base64InputResult decoded = DecodeBase64Input(data, bytes);
    SecureClear(data);
    if (decoded == Base64InputResult::Invalid) {
        napi_throw_error(env, "H-Terminal", "invalid base64 terminal input");
        return Undefined(env);
    }
    if (decoded == Base64InputResult::TooLarge) {
        napi_throw_error(env, "H-Terminal", "decoded terminal input exceeds 64 KiB");
        return Undefined(env);
    }
    std::string phase, pasteId;
    InputKind kind = InputKind::Normal;
    if (StringProperty(env, args[0], "pastePhase", phase, 16) && !phase.empty()) {
        if (!StringProperty(env, args[0], "pasteId", pasteId, 128) || pasteId.empty()) {
            napi_throw_error(env, "H-Terminal", "invalid paste transaction");
            return Undefined(env);
        }
        if (phase == "start") kind = InputKind::PasteStart;
        else if (phase == "data") kind = InputKind::PasteData;
        else if (phase == "end") kind = InputKind::PasteEnd;
        else { napi_throw_error(env, "H-Terminal", "invalid paste phase"); return Undefined(env); }
    }
    bool accepted = false;
    auto session = Manager::Instance().Find(sessionId, epoch);
    if (session != nullptr) {
        accepted = session->WriteInput(inputEpoch, eventId, std::move(bytes), kind, pasteId);
    }
    napi_value result = nullptr;
    napi_get_boolean(env, accepted, &result);
    return result;
}

napi_value Resize(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    std::string sessionId;
    uint64_t epoch = 0;
    uint64_t cols = 0;
    uint64_t rows = 0;
    if (!Arguments(env, info, 4, args) || !ReadString(env, args[0], sessionId, 128) || sessionId.empty() ||
        !ReadNumber(env, args[1], epoch) || !ReadNumber(env, args[2], cols) || !ReadNumber(env, args[3], rows) ||
        cols > 65535 || rows > 65535) {
        napi_throw_error(env, "H-Terminal", "invalid terminal resize");
        return Undefined(env);
    }
    auto session = Manager::Instance().Find(sessionId, epoch);
    if (session != nullptr) {
        session->Resize(static_cast<int>(cols), static_cast<int>(rows));
    }
    return Undefined(env);
}

napi_value AcknowledgeOutput(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    if (!Arguments(env, info, 1, args)) {
        napi_throw_error(env, "H-Terminal", "acknowledgeOutput requires a request");
        return Undefined(env);
    }
    std::string sessionId;
    uint64_t epoch = 0;
    uint64_t generation = 0;
    uint64_t seq = 0;
    uint64_t byteLength = 0;
    bool valid = StringProperty(env, args[0], "sessionId", sessionId, 128) && !sessionId.empty() &&
        NumberProperty(env, args[0], "connectionEpoch", epoch) &&
        NumberProperty(env, args[0], "terminalGeneration", generation) && NumberProperty(env, args[0], "seq", seq) &&
        NumberProperty(env, args[0], "byteLength", byteLength) && byteLength <= std::numeric_limits<size_t>::max();
    if (!valid) {
        napi_throw_error(env, "H-Terminal", "invalid output acknowledgement");
        return Undefined(env);
    }
    auto session = Manager::Instance().Find(sessionId, epoch);
    if (session != nullptr) {
        session->Acknowledge(generation, seq, static_cast<size_t>(byteLength));
    }
    return Undefined(env);
}

napi_value CloseSession(napi_env env, napi_callback_info info) {
    std::vector<napi_value> args;
    std::string sessionId;
    uint64_t epoch = 0;
    if (!Arguments(env, info, 2, args) || !ReadString(env, args[0], sessionId, 128) || sessionId.empty() ||
        !ReadNumber(env, args[1], epoch)) {
        napi_throw_error(env, "H-Terminal", "invalid session close request");
        return Undefined(env);
    }
    Manager::Instance().Close(sessionId, epoch);
    return Undefined(env);
}

napi_value Dispose(napi_env env, napi_callback_info info) {
    (void)info;
    Manager::Instance().Dispose();
    return Undefined(env);
}

template <napi_value (*Function)(napi_env, napi_callback_info)>
napi_value Safely(napi_env env, napi_callback_info info) {
    try {
        return Function(env, info);
    } catch (...) {
        napi_throw_error(env, "H-Terminal", "native operation failed");
        return Undefined(env);
    }
}

napi_value Register(napi_env env, napi_value exports) {
    const napi_property_descriptor properties[] = {
        {"initialize", nullptr, Safely<Initialize>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"connect", nullptr, Safely<Connect>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"trustDecision", nullptr, Safely<TrustDecision>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeSession", nullptr, Safely<ProbeSession>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resetInput", nullptr, Safely<ResetInput>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"answerAuthentication", nullptr, Safely<AnswerAuthentication>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"inspectPrivateKey", nullptr, Safely<InspectPrivateKey>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"inspectKnownHost", nullptr, Safely<TrustedHostKeyOperation<false>>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"forgetKnownHost", nullptr, Safely<TrustedHostKeyOperation<true>>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeInput", nullptr, Safely<WriteInput>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resize", nullptr, Safely<Resize>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"acknowledgeOutput", nullptr, Safely<AcknowledgeOutput>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeSession", nullptr, Safely<CloseSession>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"dispose", nullptr, Safely<Dispose>, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

} // namespace
} // namespace hterminal

NAPI_MODULE(entry, hterminal::Register)
