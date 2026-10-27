#include "session_registry.h"

#include <exception>

namespace hterminal {

class SessionRegistry::EventGate final : public NativeEventSink {
public:
    explicit EventGate(std::shared_ptr<NativeEventSink> sink) : sink_(std::move(sink)) {}
    void Disable() { enabled_.store(false, std::memory_order_release); }
    bool Emit(std::unique_ptr<NativeEvent> event) override {
        return enabled_.load(std::memory_order_acquire) && sink_->Emit(std::move(event));
    }
private:
    std::shared_ptr<NativeEventSink> sink_;
    std::atomic<bool> enabled_{true};
};

SessionRegistry::SessionRegistry() : reaper_([this]() { Reap(); }) {}

SessionRegistry::~SessionRegistry() {
    CloseAll();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
    }
    changed_.notify_one();
    // Only native module teardown waits. NAPI close/dispose never join.
    reaper_.join();
}

void SessionRegistry::Retire(Entry &entry) {
    // Caller holds mutex_. Fixed slots make retirement allocation-free.
    entry.gate->Disable();
    entry.session->RequestClose();
    for (auto &slot : retiring_) {
        if (!slot) {
            slot = std::move(entry.session);
            ++retiringCount_;
            changed_.notify_one();
            return;
        }
    }
    std::terminate(); // Connect enforces active + retiring <= retiring_.size().
}

bool SessionRegistry::Connect(std::unique_ptr<NativeConnectOptions> options,
                              std::shared_ptr<NativeEventSink> sink, std::string &error) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto previous = sessions_.find(options->sessionId);
    if (previous != sessions_.end()) {
        if (options->connectionEpoch <= previous->second.session->Epoch()) {
            error = "connectionEpoch must increase when reconnecting a session";
            return false;
        }
        Retire(previous->second);
        sessions_.erase(previous);
    }
    for (auto it = sessions_.begin(); it != sessions_.end();) {
        if (!it->second.session->IsActive()) {
            Retire(it->second);
            it = sessions_.erase(it);
        } else {
            ++it;
        }
    }
    if (stopping_ || sessions_.size() + retiringCount_ >= retiring_.size()) {
        error = "the four-worker limit has been reached; wait for closing sessions and retry";
        return false;
    }
    try {
        auto gate = std::make_shared<EventGate>(std::move(sink));
        auto session = std::make_shared<Session>(std::move(options), gate);
        auto inserted = sessions_.emplace(session->Id(), Entry{session, gate});
        try {
            session->Start();
        } catch (...) {
            // Thread construction failed: no worker exists to wait for.
            sessions_.erase(inserted.first);
            throw;
        }
    } catch (...) {
        error = "could not start the native SSH worker";
        return false;
    }
    return true;
}

std::shared_ptr<Session> SessionRegistry::Find(const std::string &id, uint64_t epoch) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = sessions_.find(id);
    return found != sessions_.end() && found->second.session->Epoch() == epoch ? found->second.session : nullptr;
}

void SessionRegistry::Close(const std::string &id, uint64_t epoch) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto found = sessions_.find(id);
    if (found != sessions_.end() && found->second.session->Epoch() == epoch) {
        Retire(found->second);
        sessions_.erase(found);
    }
}

void SessionRegistry::CloseAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto &entry : sessions_) {
        Retire(entry.second);
    }
    sessions_.clear();
}

void SessionRegistry::Reap() {
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
        changed_.wait(lock, [this]() { return stopping_ || retiringCount_ > 0; });
        if (retiringCount_ == 0 && stopping_) {
            return;
        }
        for (auto &slot : retiring_) {
            if (!slot) {
                continue;
            }
            auto session = slot;
            lock.unlock();
            session->Stop();
            // Drop the final owner on this reaper, never the Session worker.
            lock.lock();
            slot.reset();
            --retiringCount_;
        }
    }
}

} // namespace hterminal
