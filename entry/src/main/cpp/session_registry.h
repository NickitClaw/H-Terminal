#ifndef H_TERMINAL_SESSION_REGISTRY_H
#define H_TERMINAL_SESSION_REGISTRY_H

#include "session.h"

#include <array>
#include <condition_variable>
#include <unordered_map>

namespace hterminal {

// Own every worker until it has been joined, including cancelled DNS lookups.
// Active and retiring sessions share the same four-worker resource limit.
class SessionRegistry final {
public:
    SessionRegistry();
    ~SessionRegistry();
    bool Connect(std::unique_ptr<NativeConnectOptions> options, std::shared_ptr<NativeEventSink> sink,
                 std::string &error);
    std::shared_ptr<Session> Find(const std::string &id, uint64_t epoch);
    void Close(const std::string &id, uint64_t epoch);
    void CloseAll();

private:
    class EventGate;
    struct Entry {
        std::shared_ptr<Session> session;
        std::shared_ptr<EventGate> gate;
    };

    void Retire(Entry &entry);
    void Reap();

    std::mutex mutex_;
    std::condition_variable changed_;
    std::unordered_map<std::string, Entry> sessions_;
    std::array<std::shared_ptr<Session>, 4> retiring_{};
    size_t retiringCount_ = 0;
    bool stopping_ = false;
    std::thread reaper_;
};

} // namespace hterminal
#endif
