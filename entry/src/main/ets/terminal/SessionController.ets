import native, { NativeAck, NativeConnectOptions, NativeEvent, NativeInputRequest } from 'libentry.so';
import { BusinessError } from '@kit.BasicServicesKit';
import { HostKeyInfo, ConnectionState, SessionSnapshot, TerminalSize } from '../model/SessionModel';
import { InputRouter } from '../input/InputRouter';
import { KeyDefinition } from '../input/KeyboardModel';
import { ByteCodec } from '../util/ByteCodec';
import { PasteTransaction } from '../input/PasteTransaction';
import { NativeRuntime } from './NativeRuntime';
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
  onHostIdentity: (info: HostKeyInfo) => void = (_info: HostKeyInfo): void => {};
  onAuthChallenge: (event: NativeEvent) => void = (_event: NativeEvent): void => {};
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
  private foreground: boolean = true;
  private networkAvailable: boolean = true;
  private checking: boolean = false;
  private probeCounter: number = 0;
  private probeTimer: number = -1;
  private pasteTransaction: PasteTransaction | null = null;
  private inputResetPending: boolean = false;
  private selected: boolean = true;
  private connectedHost: string = '';
  private connectedPort: number = 0;
  private lastActivity: number = Date.now();

  constructor(backend: XtermBackend, sessionId: string = 'session-1') {
    this.backend = backend;
    this.sessionId = sessionId;
  }

  getSessionId(): string {
    return this.sessionId;
  }

  getConnectionEpoch(): number {
    return this.connectionEpoch;
  }

  getSnapshot(): SessionSnapshot { return this.snapshot; }
  isConnectedTo(host: string, port: number): boolean {
    return this.attemptActive && this.connectedHost.toLowerCase() === host.trim().toLowerCase() && this.connectedPort === port;
  }

  checkIdleConnection(now: number = Date.now()): void {
    if (this.foreground && this.networkAvailable && !this.checking && this.pasteTransaction === null &&
      this.snapshot.state === ConnectionState.OPEN && now - this.lastActivity >= 30000) this.checkConnection();
  }

  initialize(filesDir: string): void {
    if (this.initialized) {
      return;
    }
    this.filesDir = filesDir;
    this.initialized = true;
    NativeRuntime.attach(this.sessionId, (event: NativeEvent): void => {
      this.handleNativeEvent(event);
    });
    this.backend.configure(this.sessionId, this.connectionEpoch, this.terminalGeneration, this.input.getInputEpoch());
  }

  connect(host: string, port: number, username: string, password: string,
    authMethod: string = 'password', privateKey: string = ''): boolean {
    if (!this.initialized) return false;
    if (!this.foreground || !this.networkAvailable || !this.selected) {
      this.onToast('请返回前台并确认网络可用');
      return false;
    }
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
    if (normalizedHost.length === 0 || normalizedUser.length === 0 || !Number.isInteger(port) || port < 1 || port > 65535) {
      this.onToast('请检查主机、端口和用户名');
      return false;
    }
    const initialCols = this.terminalSize.cols;
    const initialRows = this.terminalSize.rows;
    this.clearPendingInputs();
    this.connectionEpoch++;
    this.input.beginSession(this.sessionId, this.connectionEpoch);
    // A new identity may wait for the previous xterm.write callback before
    // recreating the terminal. Native OPEN alone must not enable input.
    this.terminalInitialized = false;
    this.snapshot.terminalReady = false;
    this.snapshot.inputEnabled = false;
    this.terminalSize = new TerminalSize();
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
      cols: initialCols,
      rows: initialRows,
      authMethod: authMethod,
      privateKey: privateKey
    };
    this.attemptActive = true;
    this.connectedHost = normalizedHost;
    this.connectedPort = port;
    this.publish(ConnectionState.CONNECTING, '正在连接');
    try {
      native.connect(options);
      return true;
    } catch (error) {
      this.markFailed(`无法启动连接：${(error as BusinessError).message}`);
      return false;
    } finally {
      options.password = '';
      options.privateKey = '';
    }
  }

  disconnect(): void {
    this.clearProbe();
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

  answerAuthentication(requestId: number, answers: string[]): void {
    if (!this.attemptActive || !this.foreground || this.snapshot.state !== ConnectionState.AUTHENTICATING) return;
    // ArkUI state arrays can be proxy objects. Pass a plain array across NAPI.
    const copy: string[] = [];
    for (let i = 0; i < answers.length; i++) copy.push(answers[i]);
    try { native.answerAuthentication(this.sessionId, this.connectionEpoch, requestId, copy); }
    finally { copy.fill(''); }
  }

  routeKey(definition: KeyDefinition): void {
    if (!this.snapshot.inputEnabled) {
      return;
    }
    const routed = this.input.route(definition);
    if (routed === null) {
      return;
    }
    if (this.pasteTransaction !== null && routed.kind !== 'action') {
      if (routed.kind === 'key' && routed.ctrl && !routed.alt && routed.key.toLowerCase() === 'c') {
        this.stopPaste(true);
      } else {
        this.onToast('请先停止或等待粘贴完成');
      }
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
    if (this.pasteTransaction !== null) this.stopPaste(false);
    else this.invalidateInput();
    this.backend.focus(enabled);
  }

  setForeground(foreground: boolean): void {
    if (this.foreground === foreground) return;
    this.foreground = foreground;
    this.backend.setOutputPaused(!foreground || !this.selected);
    this.pauseInputs();
    if (foreground && this.networkAvailable) this.checkConnection();
  }

  setNetworkAvailable(available: boolean): void {
    if (this.networkAvailable === available) return;
    this.networkAvailable = available;
    this.pauseInputs();
    if (available && this.foreground) this.checkConnection();
  }

  setSelected(selected: boolean): void {
    if (this.selected === selected) return;
    this.selected = selected;
    this.backend.setOutputPaused(!selected || !this.foreground);
    if (!selected) {
      if (this.attemptActive && this.snapshot.state !== ConnectionState.OPEN) {
        this.disconnect();
        return;
      }
      this.stopPaste(false);
      this.backend.focus(false);
    } else {
      this.backend.fit();
    }
    this.publish(this.snapshot.state, this.snapshot.message);
  }

  private pauseInputs(): void {
    this.clearProbe();
    this.stopPaste(false);
    this.backend.focus(false);
    if (this.attemptActive && this.snapshot.state !== ConnectionState.OPEN) {
      this.disconnect();
    } else {
      this.publish(this.snapshot.state, this.foreground ? '等待网络连接检查' : '已暂停输入');
    }
  }

  private checkConnection(): void {
    if (!this.attemptActive || this.snapshot.state !== ConnectionState.OPEN) return;
    this.checking = true;
    const request = ++this.probeCounter;
    this.publish(ConnectionState.OPEN, '正在检查连接');
    this.probeTimer = setTimeout((): void => {
      if (this.checking && request === this.probeCounter) {
        native.closeSession(this.sessionId, this.connectionEpoch);
        this.markFailed('连接检查超时，请手动重连');
      }
    }, 10000);
    try {
      native.probeSession(this.sessionId, this.connectionEpoch, request);
    } catch (_error) {
      native.closeSession(this.sessionId, this.connectionEpoch);
      this.markFailed('无法检查连接，请手动重连');
    }
  }

  private clearProbe(): void {
    if (this.probeTimer >= 0) clearTimeout(this.probeTimer);
    this.probeTimer = -1;
    this.checking = false;
    this.probeCounter++;
  }

  stopPaste(sendControl: boolean = false): void {
    this.clearPendingInputs();
    this.invalidateInput();
    if (this.attemptActive && this.snapshot.state === ConnectionState.OPEN) {
      this.inputResetPending = true;
      this.publish(ConnectionState.OPEN, '正在停止未发送输入');
      try {
        native.resetInput(this.sessionId, this.connectionEpoch, this.input.getInputEpoch(), sendControl);
      } catch (_error) {
        native.closeSession(this.sessionId, this.connectionEpoch);
        this.markFailed('无法停止输入，请手动重连');
      }
    }
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
    } else if (message.type === 'paste') {
      if (!this.snapshot.inputEnabled || message.inputEpoch !== this.input.getInputEpoch() ||
        this.pasteTransaction !== null || (message.eventId ?? '').length === 0) return;
      try {
        const bytes = ByteCodec.decodeBytes(message.data ?? '');
        if (bytes.length > 1024 * 1024) return;
        this.pasteTransaction = new PasteTransaction(this.sessionId, this.connectionEpoch,
          this.input.getInputEpoch(), message.eventId ?? '', bytes, message.bracketed === true);
        this.publish(this.snapshot.state, '正在粘贴，可随时停止');
        this.advancePaste();
      } catch (_error) { this.onToast('粘贴编码无效'); }
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
    this.clearProbe();
    this.attemptActive = false;
    this.clearPendingInputs();
    this.input.invalidate();
    if (this.initialized) {
      if (this.connectionEpoch > 0) native.closeSession(this.sessionId, this.connectionEpoch);
      NativeRuntime.detach(this.sessionId);
      this.initialized = false;
    }
  }

  private handleNativeEvent(event: NativeEvent): void {
    if (!this.attemptActive || event.sessionId !== this.sessionId || event.connectionEpoch !== this.connectionEpoch) {
      return;
    }
    if (event.type === 'probe') {
      if (this.checking && this.foreground && this.networkAvailable && event.requestId === this.probeCounter) {
        this.clearProbe();
        this.lastActivity = Date.now();
        this.publish(ConnectionState.OPEN, '连接已确认');
        this.flushInputs();
      }
      return;
    }
    if (event.type === 'inputCredit') {
      this.flushInputs();
      return;
    }
    if (event.type === 'inputConsumed') {
      this.lastActivity = Date.now();
      if (event.inputEpoch === this.input.getInputEpoch() && this.pasteTransaction !== null &&
        this.pasteTransaction.consume(event.eventId ?? '', event.byteLength ?? -1)) this.advancePaste();
      return;
    }
    if (event.type === 'inputReset') {
      if (event.inputEpoch === this.input.getInputEpoch()) {
        this.inputResetPending = false;
        this.publish(this.snapshot.state, this.checking ? '正在检查连接' : '未发送输入已停止');
      }
      return;
    }
    if (event.type === 'output') {
      this.lastActivity = Date.now();
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
    if (event.type === 'authChallenge') {
      if (!this.foreground) { this.disconnect(); return; }
      this.publish(ConnectionState.AUTHENTICATING, '等待认证回答');
      this.onAuthChallenge(event);
      return;
    }
    if (event.type === 'hostKey' || event.type === 'hostIdentity') {
      const info = new HostKeyInfo();
      info.host = event.host ?? '';
      info.port = event.port ?? 0;
      info.keyType = event.keyType ?? '';
      info.fingerprint = event.fingerprint ?? '';
      this.onHostIdentity(info);
      if (event.type === 'hostKey') {
        this.publish(ConnectionState.VERIFYING_HOST, '请核实主机密钥');
        this.onHostKey(info);
      }
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
      if (state === ConnectionState.CLOSED || state === ConnectionState.FAILED) {
        this.attemptActive = false;
        this.clearProbe();
        this.clearPendingInputs();
        this.invalidateInput();
      }
      this.publish(state, event.message ?? state);
      if (state === ConnectionState.OPEN && this.terminalSize.cols > 0 && this.terminalSize.rows > 0) {
        native.resize(this.sessionId, this.connectionEpoch, this.terminalSize.cols, this.terminalSize.rows);
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
    ready.suspended = !this.foreground || !this.networkAvailable;
    ready.checking = this.checking;
    ready.pasting = this.pasteTransaction !== null;
    ready.inputEnabled = ready.state === ConnectionState.OPEN && !ready.suspended && !ready.checking &&
      !this.inputResetPending && this.selected;
    this.rendererRecovering = false;
    this.snapshot = ready;
    this.onSnapshot(ready);
  }

  private enqueueInput(message: TerminalMessage): void {
    if (!this.snapshot.inputEnabled || message.inputEpoch !== this.input.getInputEpoch() ||
      (message.eventId ?? '').length === 0) {
      return;
    }
    this.lastActivity = Date.now();
    try {
      const encoded = message.data ?? '';
      if (encoded.length > 1400000) {
        this.onToast('输入超过大小限制，内容未发送');
        return;
      }
      const bytes = ByteCodec.decodeBytes(encoded);
      if (this.pasteTransaction !== null) {
        if (bytes.length === 1 && bytes[0] === 3) this.stopPaste(true);
        else this.onToast('请先停止或等待粘贴完成');
        return;
      }
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
    this.inputResetPending = false;
    this.pasteTransaction?.clear();
    this.pasteTransaction = null;
    this.pendingInputs = [];
    this.pendingInputBytes = 0;
  }

  private advancePaste(): void {
    if (this.pasteTransaction === null) return;
    if (this.pasteTransaction.done()) {
      this.pasteTransaction.clear();
      this.pasteTransaction = null;
      this.publish(this.snapshot.state, '粘贴完成');
      return;
    }
    const next = this.pasteTransaction.next();
    if (next !== null) {
      const length = ByteCodec.decodeBytes(next.data).length;
      this.pendingInputs.push(new PendingInput(next, length));
      this.pendingInputBytes += length;
      this.flushInputs();
    }
  }

  private invalidateInput(): void {
    this.input.invalidate();
    this.backend.configure(this.sessionId, this.connectionEpoch, this.terminalGeneration, this.input.getInputEpoch());
  }

  private failRenderer(message: string): void {
    this.clearProbe();
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
    this.clearProbe();
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
    next.suspended = !this.foreground || !this.networkAvailable;
    next.checking = this.checking;
    next.pasting = this.pasteTransaction !== null;
    next.inputEnabled = state === ConnectionState.OPEN && next.terminalReady && !next.suspended && !next.checking &&
      !this.inputResetPending && this.selected;
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
