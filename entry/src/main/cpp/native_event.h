#ifndef H_TERMINAL_NATIVE_EVENT_H
#define H_TERMINAL_NATIVE_EVENT_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace hterminal {

inline void SecureClear(std::string &value) {
    volatile char *data = value.empty() ? nullptr : &value[0];
    for (size_t i = 0; i < value.size(); ++i) {
        data[i] = 0;
    }
    value.clear();
}

struct NativeConnectOptions {
    std::string sessionId;
    uint64_t connectionEpoch = 0;
    uint64_t terminalGeneration = 0;
    std::string filesDir;
    std::string host;
    uint32_t port = 0;
    std::string username;
    std::string password;
    int cols = 0;
    int rows = 0;

    NativeConnectOptions() = default;
    NativeConnectOptions(const NativeConnectOptions &) = delete;
    NativeConnectOptions &operator=(const NativeConnectOptions &) = delete;
    ~NativeConnectOptions() {
        SecureClear(password);
    }
};

enum class NativeEventType {
    State,
    HostKey,
    Output,
    Error,
    InputCredit,
    InputConsumed,
};

struct NativeEvent {
    NativeEventType type = NativeEventType::Error;
    std::string sessionId;
    uint64_t connectionEpoch = 0;
    uint64_t terminalGeneration = 0;
    std::string state;
    uint64_t seq = 0;
    size_t byteLength = 0;
    std::string data;
    std::string message;
    std::string host;
    uint32_t port = 0;
    std::string keyType;
    std::string fingerprint;
    uint64_t inputEpoch = 0;
    std::string eventId;
};

class NativeEventSink {
public:
    virtual ~NativeEventSink() = default;
    virtual bool Emit(std::unique_ptr<NativeEvent> event) = 0;
};

} // namespace hterminal

#endif
