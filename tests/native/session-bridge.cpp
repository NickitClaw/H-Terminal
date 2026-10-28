// Test-only stdio adapter for the actual Session implementation. It is never
// linked into the HAP. The caller must start its own isolated SSH fixture.
#include "session.h"
#include <openssl/evp.h>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <mutex>
#include <sstream>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
using namespace hterminal;

class BridgeSink final : public NativeEventSink {
public:
    std::shared_ptr<Session> session;
    std::mutex output;
    FILE *trace = nullptr;
    bool Emit(std::unique_ptr<NativeEvent> event) override {
        if (trace && event->type != NativeEventType::Output) {
            fprintf(trace, "%d %s\n", static_cast<int>(event->type), event->state.c_str()); fflush(trace);
        }
        if (event->type == NativeEventType::HostKey) {
            printf("T request\n"); fflush(stdout);
            session->TrustDecision(true);
            printf("T accepted\n"); fflush(stdout); return true;
        }
        if (event->type == NativeEventType::AuthChallenge) {
            session->AnswerAuthentication(event->requestId, std::vector<std::string>(event->prompts.size(), "review")); // Fixture PAM only.
            return true;
        }
        std::lock_guard<std::mutex> lock(output);
        if (event->type == NativeEventType::Output) {
            printf("O %llu %zu %s\n", static_cast<unsigned long long>(event->seq), event->byteLength, event->data.c_str());
        } else if (event->type == NativeEventType::State) printf("S %s\n", event->state.c_str());
        else if (event->type == NativeEventType::Error) printf("E %s\n", event->message.c_str());
        fflush(stdout);
        return true;
    }
};

int main(int argc, char **argv) {
    if (argc != 6 || std::string(argv[2]) != "10.0.2.2") return 2;
    int socket = ::socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<uint16_t>(std::strtoul(argv[5], nullptr, 10)));
    inet_pton(AF_INET, "10.0.2.2", &address.sin_addr);
    if (socket < 0 || connect(socket, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) return 3;
    if (dup2(socket, STDIN_FILENO) < 0 || dup2(socket, STDOUT_FILENO) < 0) return 4;
    close(socket);
    std::ios::sync_with_stdio(false);
    std::cin.tie(nullptr);
    auto options = std::make_unique<NativeConnectOptions>();
    options->sessionId = "compat"; options->connectionEpoch = 1; options->terminalGeneration = 1;
    options->filesDir = argv[1]; options->host = argv[2]; options->port = std::strtoul(argv[3], nullptr, 10);
    options->username = "review"; options->authMethod = argc > 4 ? argv[4] : "publickey";
    options->cols = 120; options->rows = 40;
    std::ifstream input(std::string(argv[1]) + "/identity");
    options->privateKey.assign(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
    BridgeSink sink; sink.trace = fopen((std::string(argv[1]) + "/bridge.trace").c_str(), "w");
    sink.session = std::make_shared<Session>(std::move(options), sink); sink.session->Start();
    std::string line; uint64_t event = 0;
    while (std::getline(std::cin, line)) {
        if (line.size() > 100000) break;
        std::istringstream fields(line); char kind = 0; fields >> kind;
        if (kind == 'C') break;
        if (kind == 'A') {
            uint64_t seq = 0; size_t bytes = 0; fields >> seq >> bytes;
            if (fields) sink.session->Acknowledge(1, seq, bytes);
        } else if (kind == 'R') {
            int cols = 0, rows = 0; fields >> cols >> rows;
            if (fields && cols > 0 && rows > 0 && cols <= 1000 && rows <= 1000) sink.session->Resize(cols, rows);
        } else if (kind == 'I') {
            std::string encoded; fields >> encoded;
            if (encoded.empty() || encoded.size() % 4 != 0 || encoded.size() > 87384) continue;
            std::vector<uint8_t> bytes(encoded.size() / 4 * 3);
            int count = EVP_DecodeBlock(bytes.data(), reinterpret_cast<const unsigned char *>(encoded.data()), encoded.size());
            if (count < 0) continue;
            if (encoded.back() == '=') --count;
            if (encoded.size() >= 2 && encoded[encoded.size() - 2] == '=') --count;
            bytes.resize(static_cast<size_t>(count));
            if (!sink.session->WriteInput(1, "test-" + std::to_string(++event), std::move(bytes))) {
                std::lock_guard<std::mutex> lock(sink.output); printf("E fixture input rejected\n"); fflush(stdout);
            }
        }
    }
    sink.session->RequestClose(); sink.session->Stop();
    if (sink.trace) fclose(sink.trace);
    return 0;
}
