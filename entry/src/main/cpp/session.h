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
    void TrustDecision(bool accepted);
    bool WriteInput(uint64_t inputEpoch, const std::string &eventId, std::vector<uint8_t> data);
    void Resize(int cols, int rows);
    void Acknowledge(uint64_t terminalGeneration, uint64_t seq, size_t byteLength);

    const std::string &Id() const;
    uint64_t Epoch() const;
    bool IsActive() const;

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
    };

    struct Command {
        CommandType type = CommandType::Close;
        bool accepted = false;
        int cols = 0;
        int rows = 0;
        uint64_t seq = 0;
        size_t byteLength = 0;
        uint64_t inputEpoch = 0;
        std::string eventId;
        std::vector<uint8_t> data;
    };

    struct InputChunk {
        uint64_t inputEpoch = 0;
        std::string eventId;
        size_t offset = 0;
        std::vector<uint8_t> data;
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
    void DiscardInput(InputChunk &input);
    void ClearInput();
    void ProcessResize();
    void PollOutput();
    void ReadOutputStream(int stream, size_t &available);
    bool EmitOutput(const uint8_t *data, size_t length);
    void HandleRemoteClosed();

    bool SetState(PublicState state, const char *name);
    void EmitError(const std::string &message);
    void Fail(const std::string &message);
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
};

} // namespace hterminal

#endif
