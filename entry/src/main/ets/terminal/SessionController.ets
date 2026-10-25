import native, { NativeAck, NativeConnectOptions, NativeEvent, NativeInputRequest } from 'libentry.so';
import { BusinessError } from '@kit.BasicServicesKit';
import { HostKeyInfo, ConnectionState, SessionSnapshot, TerminalSize } from '../model/SessionModel';
import { InputRouter } from '../input/InputRouter';
import { KeyDefinition } from '../input/KeyboardModel';
import { ByteCodec } from '../util/ByteCodec';
import { TerminalMessage } from './TerminalBackend';
import { XtermBackend } from './XtermBackend';

class PendingInput {
  request: NativeInputRequest;
  byteLength: number;

  constructor(request: NativeInputRequest, byteLength: number) {
    this.request = request;
    this.byteLength = byteLength;
  }
}

export class SessionController {
  onSnapshot: (snapshot: SessionSnapshot) => void = (_snapshot: SessionSnapshot): void => {};
  onHostKey: (info: HostKeyInfo) => void = (_info: HostKeyInfo): void => {};
  onCopy: (text: string) => void = (_text: string): void => {};
  onPasteRequest: () => void = (): void => {};
  onAction: (action: string) => void = (_action: string): void => {};
  onToast: (message: string) => void = (_message: string): void => {};
  readonly input: InputRouter = new InputRouter();
  private backend: XtermBackend;
  private snapshot: SessionSnapshot = new SessionSnapshot();
  private sessionId: string = 'session-1';
  private connectionEpoch: number = 0;
  private terminalGeneration: number = 1;
  private filesDir: string = '';
  private terminalSize: TerminalSize = new TerminalSize();
  private initialized: boolean = false;
  private pasteCounter: number = 0;
  private pendingInputs: PendingInput[] = [];
  private pendingInputBytes: number = 0;
  private attemptActive: boolean = false;
  private rendererFailed: boolean = false;
  private terminalInitialized: boolean = false;
  private rendererRecovering: boolean = false;

  constructor(backend: XtermBackend) {
    this.backend = backend;
  }

  getSessionId(): string {
    return this.sessionId;
  }

  getConnectionEpoch(): number {
    return this.connectionEpoch;
  }

  initialize(filesDir: string): void {
    if (this.initialized) {
      return;
    }
    this.filesDir = filesDir;
    this.initialized = true;
    native.initialize((event: NativeEvent): void => {
      this.handleNativeEvent(event);
    });
    this.backend.configure(this.sessionId, this.connectionEpoch, this.terminalGeneration, this.input.getInputEpoch());
  }

  connect(host: string, port: number, username: string, password: string): boolean {
    if (!this.snapshot.terminalReady || this.terminalSize.cols <= 0 || this.terminalSize.rows <= 0) {
      this.onToast('终端尺寸尚未就绪');
      return false;
    }
    if (this.snapshot.state !== ConnectionState.IDLE && this.snapshot.state !== ConnectionState.CLOSED &&
      this.snapshot.state !== ConnectionState.FAILED) {
      this.onToast('请先断开当前连接');
      return false;
    }
    const normalizedHost = host.trim();
    const normalizedUser = username.trim();
    if (normalizedHost.length === 0 || normalizedUser.length === 0 || !Number.isFinite(port) || port < 1 || port > 65535) {
      this.onToast('请检查主机、端口和用户名');
      return false;
    }
    this.clearPendingInputs();
    this.connectionEpoch++;
    this.input.beginSession(this.sessionId, this.connectionEpoch);
    this.backend.clear();
    this.backend.configure(this.sessionId, this.connectionEpoch, this.terminalGeneration, this.input.getInputEpoch());
    const options: NativeConnectOptions = {
      sessionId: this.sessionId,
      connectionEpoch: this.connectionEpoch,
      terminalGeneration: this.terminalGeneration,
      filesDir: this.filesDir,
      host: normalizedHost,
      port: port,
      username: normalizedUser,
      password: password,
      cols: this.terminalSize.cols,
      rows: this.terminalSize.rows
    };
    this.attemptActive = true;
    this.publish(ConnectionState.CONNECTING, '正在连接');
    try {
      native.connect(options);
      return true;
    } catch (error) {
      this.markFailed(`无法启动连接：${(error as BusinessError).message}`);
      return false;
    } finally {
      options.password = '';
    }
  }

  disconnect(): void {
    this.attemptActive = false;
    if (this.connectionEpoch > 0) {
      native.closeSession(this.sessionId, this.connectionEpoch);
    }
    this.clearPendingInputs();
    this.invalidateInput();
    this.publish(ConnectionState.CLOSED, '已断开');
  }

  trust(accepted: boolean): void {
    if (this.snapshot.state !== ConnectionState.VERIFYING_HOST) {
      return;
    }
    native.trustDecision(this.sessionId, this.connectionEpoch, accepted);
    if (!accepted) {
      this.attemptActive = false;
      this.publish(ConnectionState.CLOSED, '已拒绝主机密钥');
    }
  }

  routeKey(definition: KeyDefinition): void {
    if (!this.snapshot.inputEnabled) {
      return;
    }
    const routed = this.input.route(definition);
    if (routed === null) {
      return;
    }
    if (routed.kind === 'action') {
      this.onAction(routed.action);
      return;
    }
    const accepted = routed.kind === 'key'
      ? this.backend.sendKey(routed.key, routed.ctrl, routed.alt, routed.shift, routed.eventId)
      : this.backend.sendText(routed.text, routed.eventId);
    if (!accepted) {
      this.failRenderer('终端输入通道不可用');
    }
  }

  paste(text: string, expectedSessionId: string, expectedConnectionEpoch: number, expectedInputEpoch: number): void {
    if (!this.snapshot.inputEnabled || expectedSessionId !== this.sessionId ||
      expectedConnectionEpoch !== this.connectionEpoch || expectedInputEpoch !== this.input.getInputEpoch()) {
      return;
    }
    const byteLength = ByteCodec.byteLength(text);
    if (byteLength > 1024 * 1024) {
      this.onToast('粘贴内容超过 1MiB，已拒绝');
      return;
    }
    this.pasteCounter++;
    const eventId = `${this.input.getInputEpoch()}-paste-${this.pasteCounter}`;
    if (!this.backend.sendPaste(text, eventId)) {
      this.failRenderer('终端粘贴通道不可用');
    }
  }

  setImeMode(enabled: boolean): void {
    this.invalidateInput();
    this.backend.focus(enabled);
  }

  handleRendererFailure(message: string): void {
    this.failRenderer(message);
  }

  recoverTerminal(): boolean {
    if (!this.rendererFailed) {
      return false;
    }
    this.backend.markWebNotReady();
    this.terminalGeneration++;
    this.terminalSize = new TerminalSize();
    this.rendererFailed = false;
    this.terminalInitialized = false;
    this.rendererRecovering = true;
    this.snapshot.terminalReady = false;
    this.clearPendingInputs();
    this.invalidateInput();
    this.publish(ConnectionState.IDLE, '正在重新加载终端');
    if (!this.backend.reload()) {
      this.failRenderer('终端重新加载失败，请重试');
      return false;
    }
    return true;
  }

  handleTerminalMessage(json: string): void {
    let message: TerminalMessage;
    try {
      message = JSON.parse(json) as TerminalMessage;
    } catch (_error) {
      return;
    }
    if (this.rendererFailed) {
      return;
    }
    if (message.type === 'ready') {
      if (!this.isCurrentTerminalMessage(message)) {
        return;
      }
      this.terminalInitialized = true;
      this.publishTerminalReady();
      this.backend.fit();
      return;
    }
    if (message.type === 'resize') {
      if (!this.isCurrentTerminalMessage(message)) {
        return;
      }
      const cols = Math.floor(message.cols ?? 0);
      const rows = Math.floor(message.rows ?? 0);
      if (cols <= 0 || rows <= 0 || cols > 1000 || rows > 1000) {
        return;
      }
      const changed = cols !== this.terminalSize.cols || rows !== this.terminalSize.rows;
      this.terminalSize.cols = cols;
      this.terminalSize.rows = rows;
      if (changed && this.snapshot.state === ConnectionState.OPEN) {
        native.resize(this.sessionId, this.connectionEpoch, cols, rows);
      }
      this.publishTerminalReady();
      return;
    }
    if (message.type === 'error') {
      if (message.sessionId !== undefined && !this.isCurrentTerminalMessage(message)) {
        return;
      }
      if (message.fatal === true) {
        this.failRenderer(`终端错误：${message.code ?? '未知'}`);
      } else {
        this.onToast(`终端错误：${message.code ?? '未知'}`);
      }
      return;
    }
    if (!this.isCurrentTerminalMessage(message)) {
      return;
    }
    if (message.type === 'input') {
      this.enqueueInput(message);
    } else if (message.type === 'ack') {
      const ack: NativeAck = {
        sessionId: this.sessionId,
        connectionEpoch: this.connectionEpoch,
        terminalGeneration: this.terminalGeneration,
        seq: message.seq ?? -1,
        byteLength: message.byteLength ?? -1
      };
      if (ack.seq >= 0 && ack.byteLength >= 0) {
        native.acknowledgeOutput(ack);
      }
    } else if (message.type === 'copy') {
      try {
        this.onCopy(ByteCodec.decodeText(message.data ?? ''));
      } catch (_error) {
        this.onToast('无法复制当前选择');
      }
    } else if (message.type === 'pasteRequest') {
      this.onPasteRequest();
    }
  }

  dispose(): void {
    this.attemptActive = false;
    this.clearPendingInputs();
    this.input.invalidate();
    if (this.initialized) {
      native.dispose();
      this.initialized = false;
    }
  }

  private handleNativeEvent(event: NativeEvent): void {
    if (!this.attemptActive || event.sessionId !== this.sessionId || event.connectionEpoch !== this.connectionEpoch) {
      return;
    }
    if (event.type === 'inputCredit') {
      this.flushInputs();
      return;
    }
    if (event.type === 'inputConsumed') {
      return;
    }
    if (event.type === 'output') {
      if (event.terminalGeneration !== this.terminalGeneration || (event.byteLength ?? 0) > 32768) {
        return;
      }
      const accepted = this.backend.send({
        type: 'output',
        sessionId: event.sessionId,
        connectionEpoch: event.connectionEpoch,
        terminalGeneration: event.terminalGeneration,
        seq: event.seq,
        byteLength: event.byteLength,
        data: event.data
      });
      if (!accepted) {
        this.failRenderer('终端输出通道不可用');
      }
      return;
    }
    if (event.type === 'hostKey') {
      const info = new HostKeyInfo();
      info.host = event.host ?? '';
      info.port = event.port ?? 0;
      info.keyType = event.keyType ?? '';
      info.fingerprint = event.fingerprint ?? '';
      this.publish(ConnectionState.VERIFYING_HOST, '请核实主机密钥');
      this.onHostKey(info);
      return;
    }
    if (event.type === 'error') {
      this.markFailed(event.message ?? '连接失败');
      return;
    }
    if (event.type === 'state') {
      const state = this.parseState(event.state ?? '');
      if (state === null || state === ConnectionState.IDLE) {
        return;
      }
      this.publish(state, event.message ?? state);
      if (state === ConnectionState.OPEN && this.terminalSize.cols > 0 && this.terminalSize.rows > 0) {
        native.resize(this.sessionId, this.connectionEpoch, this.terminalSize.cols, this.terminalSize.rows);
      }
      if (state === ConnectionState.CLOSED || state === ConnectionState.FAILED) {
        this.attemptActive = false;
        this.clearPendingInputs();
        this.invalidateInput();
      }
    }
  }

  private isCurrentTerminalMessage(message: TerminalMessage): boolean {
    return message.sessionId === this.sessionId && message.connectionEpoch === this.connectionEpoch &&
      message.terminalGeneration === this.terminalGeneration;
  }

  private publishTerminalReady(): void {
    if (this.snapshot.terminalReady || !this.terminalInitialized || this.rendererFailed ||
      this.terminalSize.cols <= 0 || this.terminalSize.rows <= 0) {
      return;
    }
    const ready = new SessionSnapshot();
    ready.state = this.snapshot.state;
    ready.message = this.rendererRecovering ? '终端已重新加载，请连接' : this.snapshot.message;
    ready.terminalReady = true;
    ready.inputEnabled = ready.state === ConnectionState.OPEN;
    this.rendererRecovering = false;
    this.snapshot = ready;
    this.onSnapshot(ready);
  }

  private enqueueInput(message: TerminalMessage): void {
    if (!this.snapshot.inputEnabled || message.inputEpoch !== this.input.getInputEpoch() ||
      (message.eventId ?? '').length === 0) {
      return;
    }
    try {
      const encoded = message.data ?? '';
      if (encoded.length > 1400000) {
        this.onToast('输入超过大小限制，内容未发送');
        return;
      }
      const bytes = ByteCodec.decodeBytes(encoded);
      if (bytes.length > 1024 * 1024 + 12 || this.pendingInputBytes + bytes.length > 1024 * 1024 + 65536) {
        this.onToast('输入队列已满，内容未发送');
        return;
      }
      if (bytes.length === 0) {
        return;
      }
      const chunkSize = 16384;
      for (let offset = 0; offset < bytes.length; offset += chunkSize) {
        const chunk = bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length));
        const request: NativeInputRequest = {
          sessionId: this.sessionId,
          connectionEpoch: this.connectionEpoch,
          inputEpoch: message.inputEpoch ?? -1,
          eventId: `${message.eventId}-${offset}`,
          data: ByteCodec.encodeBytes(chunk)
        };
        this.pendingInputs.push(new PendingInput(request, chunk.length));
        this.pendingInputBytes += chunk.length;
      }
      this.flushInputs();
    } catch (_error) {
      this.onToast('输入编码无效，内容未发送');
    }
  }

  private flushInputs(): void {
    while (this.pendingInputs.length > 0 && this.snapshot.inputEnabled) {
      const next = this.pendingInputs[0];
      let accepted = false;
      try {
        accepted = native.writeInput(next.request);
      } catch (_error) {
        accepted = false;
      }
      if (!accepted) {
        return;
      }
      this.pendingInputs.shift();
      this.pendingInputBytes -= next.byteLength;
    }
  }

  private clearPendingInputs(): void {
    this.pendingInputs = [];
    this.pendingInputBytes = 0;
  }

  private invalidateInput(): void {
    this.input.invalidate();
    this.backend.configure(this.sessionId, this.connectionEpoch, this.terminalGeneration, this.input.getInputEpoch());
  }

  private failRenderer(message: string): void {
    this.attemptActive = false;
    if (this.connectionEpoch > 0) {
      native.closeSession(this.sessionId, this.connectionEpoch);
    }
    this.rendererFailed = true;
    this.terminalInitialized = false;
    this.rendererRecovering = false;
    this.backend.markWebNotReady();
    this.snapshot.terminalReady = false;
    this.clearPendingInputs();
    this.invalidateInput();
    this.publish(ConnectionState.FAILED, message);
  }

  private markFailed(message: string): void {
    this.attemptActive = false;
    this.clearPendingInputs();
    this.invalidateInput();
    this.publish(ConnectionState.FAILED, message);
  }

  private publish(state: ConnectionState, message: string): void {
    const next = new SessionSnapshot();
    next.state = state;
    next.message = message;
    next.terminalReady = this.snapshot.terminalReady;
    next.inputEnabled = state === ConnectionState.OPEN && next.terminalReady;
    this.snapshot = next;
    this.onSnapshot(next);
  }

  private parseState(value: string): ConnectionState | null {
    switch (value) {
      case ConnectionState.IDLE:
        return ConnectionState.IDLE;
      case ConnectionState.CONNECTING:
        return ConnectionState.CONNECTING;
      case ConnectionState.VERIFYING_HOST:
        return ConnectionState.VERIFYING_HOST;
      case ConnectionState.AUTHENTICATING:
        return ConnectionState.AUTHENTICATING;
      case ConnectionState.OPEN:
        return ConnectionState.OPEN;
      case ConnectionState.CLOSED:
        return ConnectionState.CLOSED;
      case ConnectionState.FAILED:
        return ConnectionState.FAILED;
      default:
        return null;
    }
  }
}
