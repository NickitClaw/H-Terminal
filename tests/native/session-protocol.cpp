#include "session.h"
#include <openssl/evp.h>
#include <cstdio>
#include <cstdlib>

using namespace hterminal;
using Clock = std::chrono::steady_clock;
extern "C" int __real_ssh_channel_write(ssh_channel channel, const void *data, uint32_t count);
extern "C" int __wrap_ssh_channel_write(ssh_channel channel, const void *data, uint32_t count) {
    return __real_ssh_channel_write(channel, data, std::min<uint32_t>(1, count));
}

struct Sink final : NativeEventSink {
    std::shared_ptr<Session> session;
    std::mutex mutex;
    std::string output, failure;
    size_t startConsumed = 0;
    bool reset = false, probe = false, blocked = false;
    bool paste = false;
    std::string body = "你后续不应发送";
    bool cancelStart = false;
    bool cancelEnd = false;
    bool supersedeReset = false;
    size_t bodyConsumed = 0;
    bool Emit(std::unique_ptr<NativeEvent> event) override {
        if (event->type == NativeEventType::HostKey) { session->TrustDecision(true); return true; }
        if (event->type == NativeEventType::State && event->state == "OPEN") {
            if (paste) {
                session->WriteInput(1, "start", {27, '[', '2', '0', '0', '~'}, InputKind::PasteStart, "paste");
                blocked = !session->WriteInput(1, "interleaved", {'X'});
            } else session->Probe(42);
        }
        if (paste && event->type == NativeEventType::InputConsumed && event->eventId == "start") {
            startConsumed += event->byteLength;
            if (cancelStart && startConsumed == 3) session->ResetInput(2, true);
            if (startConsumed == 6) {
                session->WriteInput(1, "body", {body.begin(), body.end()}, InputKind::PasteData, "paste");
            }
        }
        if (paste && event->type == NativeEventType::InputConsumed && event->eventId == "body") {
            bodyConsumed += event->byteLength;
            if (cancelEnd) {
                if (bodyConsumed == body.size()) {
                    session->WriteInput(1, "end", {27, '[', '2', '0', '1', '~'}, InputKind::PasteEnd, "paste");
                }
            } else {
                session->ResetInput(2, !supersedeReset);
                if (supersedeReset) session->ResetInput(3, true);
                session->ResetInput(2, true); // Duplicate cancellation must not duplicate Ctrl+C.
                session->ResetInput(1, true); // Stale input epoch must not block future input.
            }
        }
        if (cancelEnd && event->type == NativeEventType::InputConsumed && event->eventId == "end") {
            session->ResetInput(2, true);
        }
        if (event->type == NativeEventType::InputReset) {
            const uint64_t expectedEpoch = supersedeReset ? 3 : 2;
            reset = event->inputEpoch == expectedEpoch;
            session->WriteInput(expectedEpoch, "after-reset", {'Z'});
        }
        if (event->type == NativeEventType::Probe) {
            probe = event->requestId == 42;
            session->WriteInput(1, "after-probe", {'N'});
        }
        std::lock_guard<std::mutex> lock(mutex);
        if (event->type == NativeEventType::Output) {
            std::vector<unsigned char> bytes(event->data.size() / 4 * 3);
            int n = EVP_DecodeBlock(bytes.data(), reinterpret_cast<const unsigned char *>(event->data.data()),
                static_cast<int>(event->data.size()));
            if (n < 0) return false;
            output.append(reinterpret_cast<const char *>(bytes.data()), event->byteLength);
            session->Acknowledge(event->terminalGeneration, event->seq, event->byteLength);
        } else if (event->type == NativeEventType::Error) failure = event->message;
        return true;
    }
};

bool Run(const char *dir, const char *host, uint32_t port, const std::string &user, bool paste, int boundary = 0) {
    Sink sink;
    sink.paste = paste;
    sink.cancelStart = boundary == 1;
    sink.cancelEnd = boundary == 2;
    sink.supersedeReset = boundary == 4;
    if (boundary == 3) sink.body = "🙂后续不应发送";
    auto options = std::make_unique<NativeConnectOptions>();
    options->sessionId = "protocol"; options->connectionEpoch = 1; options->terminalGeneration = 1;
    options->filesDir = dir; options->host = host; options->port = port;
    options->username = user; options->password = "review"; options->cols = 80; options->rows = 24;
    sink.session = std::make_shared<Session>(std::move(options), sink);
    sink.session->Start();
    bool timeout = user == "probe-timeout", ok = false;
    const std::string expected = "fixture> " + (paste ? std::string("\x1b[200~") +
        (boundary == 1 ? "" : boundary == 2 ? sink.body : boundary == 3 ? "🙂" : "你") + "\x1b[201~\x03Z" : "N");
    auto deadline = Clock::now() + std::chrono::seconds(15);
    while (Clock::now() < deadline) {
        {
            std::lock_guard<std::mutex> lock(sink.mutex);
            if (!sink.failure.empty()) { ok = timeout && sink.failure.find("check timed out") != std::string::npos; break; }
            if (!timeout && sink.output.size() >= expected.size()) { ok = sink.output == expected; break; }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    sink.session->RequestClose(); sink.session->Stop();
    ok = ok && (timeout ? !sink.probe : paste ? sink.reset && sink.blocked : sink.probe);
    printf("%s: %s boundary=%d %s\n", ok ? "PASS" : "FAIL", paste ? "partial UTF-8 paste cancellation and Ctrl+C" : user.c_str(),
        boundary, sink.failure.c_str());
    return ok;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    uint32_t port = static_cast<uint32_t>(std::strtoul(argv[3], nullptr, 10));
    bool a = Run(argv[1], argv[2], port, "review", false);
    bool b = Run(argv[1], argv[2], port, "probe-reject", false);
    bool c = Run(argv[1], argv[2], port, "probe-timeout", false);
    bool d = Run(argv[1], argv[2], port, "review", true);
    bool e = Run(argv[1], argv[2], port, "review", true, 1);
    bool f = Run(argv[1], argv[2], port, "review", true, 2);
    bool g = Run(argv[1], argv[2], port, "review", true, 3);
    bool h = Run(argv[1], argv[2], port, "review", true, 4);
    return a && b && c && d && e && f && g && h ? 0 : 1;
}
