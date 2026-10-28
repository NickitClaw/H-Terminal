#include "session.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>

using namespace hterminal;
struct AuthSink final : NativeEventSink {
    std::shared_ptr<Session> session;
    std::atomic<bool> opened{false}, failed{false};
    size_t rounds = 0;
    size_t localRounds = 0;
    std::string localAnswer = "review";
    bool cancel = false, wrongAnswer = false, promptsValid = true;
    bool Emit(std::unique_ptr<NativeEvent> event) override {
        if (event->type == NativeEventType::HostKey) session->TrustDecision(true);
        if (event->type == NativeEventType::AuthChallenge) {
            if (event->title == "H-Terminal 重新认证") {
                ++localRounds;
                promptsValid = promptsValid && event->prompts.size() == 1 && !event->prompts[0].echo;
                if (cancel) session->RequestClose();
                else session->AnswerAuthentication(event->requestId, {localAnswer});
                return true;
            }
            ++rounds;
            if (rounds == 1) promptsValid = event->prompts.size() == 2 && event->prompts[0].echo && !event->prompts[1].echo;
            else promptsValid = promptsValid && event->prompts.size() == 1 && !event->prompts[0].echo;
            if (cancel) session->RequestClose();
            else {
                session->AnswerAuthentication(event->requestId + 1, {"stale"});
                session->AnswerAuthentication(event->requestId,
                    wrongAnswer ? std::vector<std::string>{"wrong", "wrong"} : rounds == 1 ?
                    std::vector<std::string>{"review", "123456"} : std::vector<std::string>{"654321"});
            }
        }
        if (event->type == NativeEventType::State && event->state == "OPEN") opened = true;
        if (event->type == NativeEventType::Error) failed = true;
        return true;
    }
};

bool Run(const char *dir, const char *host, uint32_t port, const std::string &method, const std::string &file,
         const std::string &password, bool reject = false, bool cancel = false, bool prompt = false,
         const std::string &answer = "") {
    AuthSink sink; sink.cancel = cancel; sink.wrongAnswer = reject && method == "keyboard-interactive";
    sink.localAnswer = !answer.empty() ? answer : file == "encrypted-identity" ? "key-passphrase" : "review";
    auto options = std::make_unique<NativeConnectOptions>();
    options->sessionId = "auth"; options->connectionEpoch = 1; options->terminalGeneration = 1;
    options->filesDir = dir; options->host = host; options->port = port;
    options->username = method.find('+') != std::string::npos ? "combo" : "review";
    options->password = password; options->authMethod = method; options->cols = 80; options->rows = 24;
    options->promptForSecret = prompt;
    if (!file.empty()) {
        std::ifstream input(std::string(dir) + "/" + file);
        options->privateKey.assign(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
    }
    sink.session = std::make_shared<Session>(std::move(options), sink);
    sink.session->Start();
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    while (!sink.opened && !sink.failed && sink.session->IsActive() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    sink.session->RequestClose(); sink.session->Stop();
    bool interactive = method.find("keyboard-interactive") != std::string::npos;
    bool ok = reject ? sink.failed.load() && !sink.opened.load() :
        cancel ? !sink.opened.load() && sink.rounds + sink.localRounds == 1 : sink.opened.load();
    if (interactive && !reject && !cancel) ok = ok && sink.rounds == 2 && sink.promptsValid;
    if (prompt && !cancel && !reject) ok = ok && sink.localRounds == 1 && sink.promptsValid;
    printf("%s: %s %s %s rounds=%zu\n", ok ? "PASS" : "FAIL", method.c_str(), file.c_str(),
        reject ? "reject" : cancel ? "cancel" : "authenticate", sink.rounds);
    return ok;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    uint32_t port = static_cast<uint32_t>(std::strtoul(argv[3], nullptr, 10));
    bool ok = Run(argv[1], argv[2], port, "password", "", "review");
    ok &= Run(argv[1], argv[2], port, "publickey", "identity", "");
    ok &= Run(argv[1], argv[2], port, "publickey", "encrypted-identity", "key-passphrase");
    ok &= Run(argv[1], argv[2], port, "publickey", "encrypted-identity", "wrong", true);
    {
        std::ifstream input(std::string(argv[1]) + "/cost-identity");
        std::string costly{std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
        bool bounded = !SupportedPrivateKeyContainer(costly);
        SecureClear(costly);
        if (!bounded) { printf("FAIL: excessive KDF cost accepted\n"); ok = false; }
        else ok &= Run(argv[1], argv[2], port, "publickey", "cost-identity", "key-passphrase", true);
    }
    ok &= Run(argv[1], argv[2], port, "keyboard-interactive", "", "");
    ok &= Run(argv[1], argv[2], port, "password+keyboard-interactive", "", "review");
    ok &= Run(argv[1], argv[2], port, "publickey+keyboard-interactive", "identity", "");
    ok &= Run(argv[1], argv[2], port, "keyboard-interactive", "", "", true);
    ok &= Run(argv[1], argv[2], port, "keyboard-interactive", "", "", false, true);
    ok &= Run(argv[1], argv[2], port, "password", "", "", false, false, true);
    ok &= Run(argv[1], argv[2], port, "publickey", "encrypted-identity", "", false, false, true);
    ok &= Run(argv[1], argv[2], port, "password+keyboard-interactive", "", "", false, false, true);
    ok &= Run(argv[1], argv[2], port, "publickey+keyboard-interactive", "encrypted-identity", "", false, false, true);
    ok &= Run(argv[1], argv[2], port, "password", "", "", true, false, true, "wrong");
    ok &= Run(argv[1], argv[2], port, "password", "", "", false, true, true);
    TrustedHostKey known, checked;
    bool trust = AccessTrustedHostKey(argv[1], argv[2], port, "", false, known);
    trust = trust && !AccessTrustedHostKey(argv[1], argv[2], port, "SHA256:stale", true, checked);
    {
        std::ofstream output(std::string(argv[1]) + "/known_hosts", std::ios::app);
        output << "other.test " << known.publicKey << "\n";
    }
    trust = trust && AccessTrustedHostKey(argv[1], argv[2], port, known.fingerprint, true, checked);
    trust = trust && !AccessTrustedHostKey(argv[1], argv[2], port, "", false, checked);
    trust = trust && AccessTrustedHostKey(argv[1], "other.test", 22, "", false, checked);
    {
        std::ofstream output(std::string(argv[1]) + "/known_hosts", std::ios::app);
        output << "one.test,two.test " << known.publicKey << "\n";
    }
    trust = trust && !AccessTrustedHostKey(argv[1], "one.test", 22, known.fingerprint, true, checked);
    trust = trust && AccessTrustedHostKey(argv[1], "two.test", 22, "", false, checked);
    printf("%s: trusted fingerprint comparison, atomic removal and other-host preservation\n", trust ? "PASS" : "FAIL");
    ok &= trust;
    return ok ? 0 : 1;
}
