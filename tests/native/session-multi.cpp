#include "session_registry.h"
#include <openssl/evp.h>
#include <cstdio>
#include <cstdlib>

using namespace hterminal;
using Clock = std::chrono::steady_clock;
struct Sink final : NativeEventSink {
    SessionRegistry &registry;
    std::mutex mutex;
    std::unordered_map<std::string, std::string> output;
    bool failed = false;
    explicit Sink(SessionRegistry &value) : registry(value) {}
    bool Emit(std::unique_ptr<NativeEvent> event) override {
        auto session = registry.Find(event->sessionId, event->connectionEpoch);
        if (!session) return false;
        if (event->type == NativeEventType::HostKey) session->TrustDecision(true);
        if (event->type == NativeEventType::State && event->state == "OPEN") {
            session->WriteInput(1, "initial", {static_cast<uint8_t>(event->sessionId.back())});
        }
        if (event->type == NativeEventType::Output) {
            std::vector<unsigned char> bytes(event->data.size() / 4 * 3);
            EVP_DecodeBlock(bytes.data(), reinterpret_cast<const unsigned char *>(event->data.data()),
                static_cast<int>(event->data.size()));
            {
                std::lock_guard<std::mutex> lock(mutex);
                output[event->sessionId + "/" + std::to_string(event->connectionEpoch)].append(
                    reinterpret_cast<const char *>(bytes.data()), event->byteLength);
            }
            session->Acknowledge(event->terminalGeneration, event->seq, event->byteLength);
        }
        if (event->type == NativeEventType::Error) { std::lock_guard<std::mutex> lock(mutex); failed = true; }
        return true;
    }
    bool Wait(const std::string &id, uint64_t epoch, const std::string &expected) {
        auto deadline = Clock::now() + std::chrono::seconds(5);
        while (Clock::now() < deadline) {
            { std::lock_guard<std::mutex> lock(mutex);
              if (failed) return false;
              if (output[id + "/" + std::to_string(epoch)] == expected) return true; }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        return false;
    }
};

std::unique_ptr<NativeConnectOptions> Options(const char *dir, const char *host, uint32_t port, int id, uint64_t epoch) {
    auto options = std::make_unique<NativeConnectOptions>();
    options->sessionId = "multi-" + std::to_string(id); options->connectionEpoch = epoch; options->terminalGeneration = 1;
    options->filesDir = dir; options->host = host; options->port = port;
    options->username = "review"; options->password = "review"; options->cols = 80; options->rows = 24;
    return options;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    uint32_t port = static_cast<uint32_t>(std::strtoul(argv[3], nullptr, 10));
    SessionRegistry registry;
    auto sink = std::make_shared<Sink>(registry);
    std::string error;
    bool ok = true;
    for (int id = 1; id <= 4; ++id) ok &= registry.Connect(Options(argv[1], argv[2], port, id, 1), sink, error);
    for (int id = 1; id <= 4; ++id) ok &= sink->Wait("multi-" + std::to_string(id), 1, "fixture> " + std::to_string(id));
    registry.Close("multi-2", 1);
    for (int id : {1, 3, 4}) {
        auto session = registry.Find("multi-" + std::to_string(id), 1);
        ok &= session && session->WriteInput(1, "after-close", {'Z'});
        ok &= sink->Wait("multi-" + std::to_string(id), 1, "fixture> " + std::to_string(id) + "Z");
    }
    auto deadline = Clock::now() + std::chrono::seconds(2);
    bool reconnected = false;
    do {
        reconnected = registry.Connect(Options(argv[1], argv[2], port, 2, 2), sink, error);
        if (!reconnected) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    } while (!reconnected && Clock::now() < deadline);
    ok &= reconnected && sink->Wait("multi-2", 2, "fixture> 2");
    registry.Close("multi-2", 1);
    ok &= registry.Find("multi-2", 2) != nullptr;
    registry.CloseAll();
    printf("%s: four concurrent SSH sessions, per-session input/output and close/reconnect isolation\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
