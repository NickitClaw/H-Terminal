#include "session_registry.h"

#include <netdb.h>
#include <atomic>
#include <cstdio>

using namespace hterminal;
using Clock = std::chrono::steady_clock;
static std::atomic<int> resolving{0};

// Deterministic fault injection into the real libssh call, without changing
// application code or relying on the host's resolver/network timing.
extern "C" int getaddrinfo(const char *, const char *, const struct addrinfo *, struct addrinfo **) {
    ++resolving;
    std::this_thread::sleep_for(std::chrono::seconds(2));
    return EAI_AGAIN;
}

struct Sink final : NativeEventSink {
    std::atomic<int> finalEvents{0};
    bool Emit(std::unique_ptr<NativeEvent> event) override {
        if (event->type == NativeEventType::Error ||
            (event->type == NativeEventType::State && (event->state == "CLOSED" || event->state == "FAILED"))) {
            ++finalEvents;
        }
        return true;
    }
};

static std::unique_ptr<NativeConnectOptions> Options(const char *filesDir, uint64_t epoch) {
    auto options = std::make_unique<NativeConnectOptions>();
    options->sessionId = "cancel";
    options->connectionEpoch = epoch;
    options->terminalGeneration = 1;
    options->filesDir = filesDir;
    options->host = "slow-resolver.invalid";
    options->port = 22224;
    options->username = "review";
    options->password = "review";
    options->cols = 80;
    options->rows = 24;
    return options;
}

static bool WaitForResolver(int expected) {
    auto deadline = Clock::now() + std::chrono::seconds(1);
    while (resolving < expected && Clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return resolving >= expected;
}

template<typename Action> static bool Prompt(const char *name, Action action) {
    auto start = Clock::now();
    bool ok = action();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
    printf("%s: %s elapsed=%lldms\n", ok && elapsed < 100 ? "PASS" : "FAIL", name,
        static_cast<long long>(elapsed));
    return ok && elapsed < 100;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    SessionRegistry registry;
    auto sink = std::make_shared<Sink>();
    std::string error;
    if (!registry.Connect(Options(argv[1], 1), sink, error) || !WaitForResolver(1)) return 1;
    std::weak_ptr<Session> first = registry.Find("cancel", 1);
    bool ok = Prompt("cancel during 2s DNS", [&]() {
        registry.Close("cancel", 1);
        return !registry.Find("cancel", 1) && !first.expired();
    });
    ok &= Prompt("connect while old DNS is retiring", [&]() {
        return registry.Connect(Options(argv[1], 2), sink, error);
    });
    if (!WaitForResolver(2)) return 1;
    registry.Close("cancel", 1);
    if (!registry.Find("cancel", 2)) return 1;
    std::weak_ptr<Session> second = registry.Find("cancel", 2);
    ok &= Prompt("replace worker during 2s DNS", [&]() {
        return registry.Connect(Options(argv[1], 3), sink, error);
    });
    if (!WaitForResolver(3)) return 1;
    std::weak_ptr<Session> third = registry.Find("cancel", 3);
    ok &= Prompt("dispose during 2s DNS", [&]() {
        registry.CloseAll();
        return !registry.Find("cancel", 3);
    });
    if (!registry.Connect(Options(argv[1], 1), sink, error) || !WaitForResolver(4)) return 1;
    ok &= Prompt("active plus retiring workers stay bounded", [&]() {
        return !registry.Connect(Options(argv[1], 2), sink, error);
    });
    auto deadline = Clock::now() + std::chrono::seconds(5);
    while ((!first.expired() || !second.expired() || !third.expired()) && Clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    bool reclaimed = first.expired() && second.expired() && third.expired() && sink->finalEvents == 0;
    printf("%s: retired workers joined, freed and callbacks isolated\n", reclaimed ? "PASS" : "FAIL");
    ok &= reclaimed;
    // An environment can restart epochs at 1 after disposal. The previous
    // workers must neither occupy the active map nor retain its callbacks.
    ok &= registry.Connect(Options(argv[1], 1), sink, error);
    registry.CloseAll();
    return ok ? 0 : 1;
}
