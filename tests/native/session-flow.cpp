#include "session.h"
#include <openssl/evp.h>

#include <cstdio>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace hterminal;
using Clock = std::chrono::steady_clock;

struct PendingAck {
    uint64_t generation;
    uint64_t seq;
    size_t bytes;
    Clock::time_point due;
};

class FlowSink final : public NativeEventSink {
public:
    std::shared_ptr<Session> session;
    std::mutex mutex;
    std::deque<PendingAck> acks;
    Clock::time_point openedAt{};
    std::string output;
    std::string failure;
    size_t controlConsumed = 0;
    int ackDelayMs = 0;
    bool opened = false;

    bool Emit(std::unique_ptr<NativeEvent> event) override {
        if (event->type == NativeEventType::HostKey) {
            session->TrustDecision(true); // Only the isolated local fixture is used.
            return true;
        }
        if (event->type == NativeEventType::State && event->state == "OPEN") {
            {
                std::lock_guard<std::mutex> lock(mutex);
                opened = true;
                openedAt = Clock::now();
            }
            const std::string command = "burst\r";
            return session->WriteInput(1, "burst", {command.begin(), command.end()});
        }
        std::lock_guard<std::mutex> lock(mutex);
        if (event->type == NativeEventType::Error) {
            failure = event->message;
        } else if (event->type == NativeEventType::Output) {
            std::vector<unsigned char> decoded(event->data.size() / 4 * 3);
            int length = EVP_DecodeBlock(decoded.data(),
                reinterpret_cast<const unsigned char *>(event->data.data()), static_cast<int>(event->data.size()));
            if (length < 0 || event->byteLength > static_cast<size_t>(length)) {
                failure = "invalid output encoding";
                return false;
            }
            output.append(reinterpret_cast<const char *>(decoded.data()), event->byteLength);
            acks.push_back({event->terminalGeneration, event->seq, event->byteLength,
                Clock::now() + std::chrono::milliseconds(ackDelayMs)});
        } else if (event->type == NativeEventType::InputConsumed && event->eventId == "control") {
            controlConsumed += event->byteLength;
        }
        return true;
    }
};

static bool RunCase(const char *filesDir, const char *host, unsigned int port, int delayMs, int pauseMs) {
    FlowSink sink;
    sink.ackDelayMs = delayMs;
    auto options = std::make_unique<NativeConnectOptions>();
    options->sessionId = "flow-test";
    options->connectionEpoch = 1;
    options->terminalGeneration = 1;
    options->filesDir = filesDir;
    options->host = host;
    options->port = port;
    options->username = "review";
    options->password = "review";
    options->cols = 80;
    options->rows = 24;
    sink.session = std::make_shared<Session>(std::move(options), sink);
    std::string expected = "READY\r\n" + std::string(4 * 1024 * 1024, 'X') + "\r\nEND\r\n";
    const std::string control = "control\r";
    if (pauseMs > 0) {
        expected += "\r\nCONTROL\r\n";
    }
    sink.session->Start();
    bool sentControl = false;
    bool checkedPause = pauseMs == 0;
    bool passed = false;
    auto deadline = Clock::now() + std::chrono::seconds(20);
    while (Clock::now() < deadline) {
        std::deque<PendingAck> due;
        bool sendControl = false;
        {
            std::lock_guard<std::mutex> lock(sink.mutex);
            if (!sink.failure.empty()) {
                break;
            }
            auto now = Clock::now();
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - sink.openedAt).count();
            if (pauseMs > 0 && sink.opened && elapsed >= pauseMs / 2 && !checkedPause) {
                checkedPause = true;
                if (!sink.session->IsActive() || sink.output.empty() || sink.output.size() > 256 * 1024 ||
                    sink.controlConsumed != control.size()) {
                    sink.failure = "paused consumer lost boundedness, connectivity, or input progress";
                    break;
                }
            }
            if (pauseMs > 0 && sink.opened && elapsed >= 500 && !sentControl) {
                sentControl = true;
                sendControl = true;
            }
            if (sink.opened && elapsed >= pauseMs) {
                while (!sink.acks.empty() && sink.acks.front().due <= now) {
                    due.push_back(sink.acks.front());
                    sink.acks.pop_front();
                }
            }
            if (sink.output.size() >= expected.size()) {
                passed = checkedPause && sink.output == expected &&
                    (pauseMs == 0 || sink.controlConsumed == control.size());
                break;
            }
        }
        if (sendControl && !sink.session->WriteInput(1, "control", {control.begin(), control.end()})) {
            std::lock_guard<std::mutex> lock(sink.mutex);
            sink.failure = "control input was rejected while output was paused";
            break;
        }
        for (const auto &ack : due) {
            sink.session->Acknowledge(ack.generation, ack.seq, ack.bytes);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    sink.session->RequestClose();
    sink.session->Stop();
    printf("%s: ACK delay=%dms pause=%dms output=%zu/%zu control=%zu %s\n",
        passed ? "PASS" : "FAIL", delayMs, pauseMs, sink.output.size(), expected.size(),
        sink.controlConsumed, sink.failure.c_str());
    return passed;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: session-flow <isolated-files-dir> <fixture-host> <fixture-port>\n");
        return 2;
    }
    unsigned int port = static_cast<unsigned int>(std::strtoul(argv[3], nullptr, 10));
    bool immediate = RunCase(argv[1], argv[2], port, 0, 0);
    bool delayed = RunCase(argv[1], argv[2], port, 100, 0);
    bool paused = RunCase(argv[1], argv[2], port, 0, 2000);
    return immediate && delayed && paused ? 0 : 1;
}
