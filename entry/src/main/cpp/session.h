#ifndef H_TERMINAL_SESSION_H
#define H_TERMINAL_SESSION_H

#include "native_event.h"

#include <libssh/libssh.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

namespace hterminal {

bool EnsureSshInitialized();
bool SupportedPrivateKeyContainer(const std::string &key);
struct TrustedHostKey { std::string publicKey; std::string fingerprint; };
struct SessionMetrics {
    uint64_t outputBytes = 0, inputBytes = 0, outputFrames = 0, acknowledgedFrames = 0;
    uint64_t unackedBytes = 0, peakUnackedBytes = 0, peakInputBytes = 0, peakReceiveBytes = 0;
    uint64_t queuedInputBytes = 0, elapsedMs = 0;
};
bool AccessTrustedHostKey(const std::string &filesDir, const std::string &host, uint32_t port,
                         const std::string &expectedFingerprint, bool remove, TrustedHostKey &result);

class Session final : public std::enable_shared_from_this<Session> {
public:
    Session(std::unique_ptr<NativeConnectOptions> options, NativeEventSink &sink);
    Session(std::unique_ptr<NativeConnectOptions> options, std::shared_ptr<NativeEventSink> sink);
    ~Session();

    Session(const Session &) = delete;
    Session &operator=(const Session &) = delete;

    void Start();
    void Stop();
    void RequestClose();
    void Probe(uint64_t requestId);
    void TrustDecision(bool accepted);
    void AnswerAuthentication(uint64_t requestId, std::vector<std::string> answers);
    bool WriteInput(uint64_t inputEpoch, const std::string &eventId, std::vector<uint8_t> data,
                    InputKind kind = InputKind::Normal, const std::string &pasteId = "");
    void ResetInput(uint64_t inputEpoch, bool sendControl);
    void Resize(int cols, int rows);
    void Acknowledge(uint64_t terminalGeneration, uint64_t seq, size_t byteLength);

    const std::string &Id() const;
    uint64_t Epoch() const;
    bool IsActive() const;
    SessionMetrics Metrics() const;

private:
    enum class PublicState {
        Idle,
        Connecting,
        VerifyingHost,
        Authenticating,
        Open,
        Closed,
        Failed,
    };

    enum class Stage {
        Connect,
        VerifyHost,
        WaitTrust,
        Authenticate,
        WaitAuth,
        OpenChannel,
        RequestPty,
        RequestShell,
        Open,
        Finished,
    };

    enum class CommandType {
        Close,
        Trust,
        Resize,
        Acknowledge,
        Input,
        Probe,
        ResetInput,
        AuthAnswer,
    };

    struct Command {
        Command() = default;
        Command(Command &&) = default;
        Command &operator=(Command &&) = default;
        Command(const Command &) = delete;
        ~Command() { for (auto &answer : answers) SecureClear(answer); }
        CommandType type = CommandType::Close;
        bool accepted = false;
        int cols = 0;
        int rows = 0;
        uint64_t seq = 0;
        size_t byteLength = 0;
        uint64_t inputEpoch = 0;
        std::string eventId;
        std::vector<uint8_t> data;
        InputKind kind = InputKind::Normal;
        std::vector<std::string> answers;
    };

    struct InputChunk {
        uint64_t inputEpoch = 0;
        std::string eventId;
        size_t offset = 0;
        std::vector<uint8_t> data;
        InputKind kind = InputKind::Normal;
    };

    struct UnackedFrame {
        uint64_t seq = 0;
        size_t byteLength = 0;
    };

    void Run();
    bool CreateTransport();
    void DestroyTransport();
    void Advance();
    void AdvanceConnect();
    void AdvanceVerifyHost();
    void AdvanceAuthenticate();
    void RequestAuthenticationAnswers();
    void RequestLocalSecret(const char *prompt);
    void AdvanceOpenChannel();
    void AdvanceRequestPty();
    void AdvanceRequestShell();
    void AdvanceOpen();
    void WaitForNetwork();
    void CheckDeadline(const char *message);
    void ChangeStage(Stage stage, std::chrono::steady_clock::duration timeout);
    void BeginAuthentication();
    bool DescribeHostKey(std::string &keyType, std::string &fingerprint);
    void AcceptHostKey();

    void DrainCommands();
    void ApplyCommand(Command &command);
    void ApplyAcknowledge(uint64_t seq, size_t byteLength);
    void ProcessInput();
    void ApplyInputReset(uint64_t epoch, bool sendControl);
    void DiscardInput(InputChunk &input);
    void ClearInput();
    void ProcessResize();
    void ProcessProbe();
    void PollOutput();
    void ReadOutputStream(int stream, size_t &available);
    bool EmitOutput(const uint8_t *data, size_t length);
    void HandleRemoteClosed();

    bool SetState(PublicState state, const char *name);
    void EmitError(const std::string &message, const std::string &code = "protocol");
    void Fail(const std::string &message, const std::string &code = "");
    bool IsOpenForInput() const;

    std::unique_ptr<NativeConnectOptions> options_;
    std::shared_ptr<NativeEventSink> ownedSink_;
    NativeEventSink &sink_;
    std::atomic<PublicState> state_{PublicState::Idle};
    std::atomic<bool> closeRequested_{false};
    std::atomic<bool> acceptingInput_{false};
    std::atomic<bool> trustPending_{false};
    std::atomic<bool> trustQueued_{false};
    std::atomic<bool> hasInputEpoch_{false};
    std::atomic<bool> inputResetPending_{false};
    bool inputResetApplied_ = false;
    uint64_t lastResetEpoch_ = 0;
    std::string acceptedPasteId_;
    bool acceptedPasteBrackets_ = false;
    bool pasteOpened_ = false;
    std::atomic<uint64_t> latestInputEpoch_{0};

    mutable std::mutex commandMutex_;
    std::deque<Command> commands_;
    size_t queuedInputBytes_ = 0;
    std::unordered_set<std::string> seenEventIds_;
    std::deque<std::string> eventIdOrder_;

    std::mutex stopMutex_;
    std::thread worker_;

    ssh_session session_ = nullptr;
    ssh_channel channel_ = nullptr;
    ssh_event event_ = nullptr;
    ssh_key privateKey_ = nullptr;
    size_t authStep_ = 0;
    size_t authRounds_ = 0;
    std::atomic<uint64_t> challengeId_{0};
    std::atomic<bool> answerQueued_{false};
    size_t promptCount_ = 0;
    bool localSecretPending_ = false;
    bool localSecretAsked_ = false;
    std::string failureKind_ = "protocol";
    const std::chrono::steady_clock::time_point createdAt_ = std::chrono::steady_clock::now();
    std::atomic<uint64_t> outputBytes_{0}, inputBytes_{0}, outputFrames_{0}, acknowledgedFrames_{0};
    std::atomic<uint64_t> unackedBytes_{0}, peakUnackedBytes_{0}, peakInputBytes_{0}, peakReceiveBytes_{0};
    Stage stage_ = Stage::Connect;
    std::chrono::steady_clock::time_point deadline_{};
    bool handshakeDeadlineStarted_ = false;
    bool failed_ = false;
    bool remoteClosed_ = false;
    std::string failureMessage_;

    int cols_ = 0;
    int rows_ = 0;
    int ptyRequestCols_ = 0;
    int ptyRequestRows_ = 0;
    int appliedCols_ = 0;
    int appliedRows_ = 0;
    bool resizeActive_ = false;
    int resizeCols_ = 0;
    int resizeRows_ = 0;

    std::deque<InputChunk> inputQueue_;
    std::deque<UnackedFrame> unackedFrames_;
    size_t outputOutstanding_ = 0;
    bool outputPaused_ = false;
    uint64_t nextSeq_ = 1;
    bool remoteEof_ = false;
    bool transportError_ = false;
    uint64_t pendingProbeId_ = 0;
    uint64_t activeProbeId_ = 0;
    std::chrono::steady_clock::time_point probeDeadline_{};
};

} // namespace hterminal

#endif
