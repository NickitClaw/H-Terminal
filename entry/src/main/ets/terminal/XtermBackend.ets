import { ByteCodec } from '../util/ByteCodec';
import { TerminalBackend, TerminalMessage } from './TerminalBackend';

export type TerminalMessageSender = (message: TerminalMessage) => void;

export class XtermBackend implements TerminalBackend {
  private sender: TerminalMessageSender | null = null;
  private reloader: (() => void) | null = null;
  private bridgeEpoch: number = 0;
  private webReady: boolean = false;
  private pending: TerminalMessage[] = [];
  private sessionId: string = '';
  private connectionEpoch: number = 0;
  private terminalGeneration: number = 1;
  private inputEpoch: number = 1;

  setSender(sender: TerminalMessageSender): void {
    this.sender = sender;
  }

  setReloader(reloader: () => void): void {
    this.reloader = reloader;
  }

  getBridgeEpoch(): number {
    return this.bridgeEpoch;
  }

  markWebReady(): void {
    this.webReady = true;
    const pending = this.pending;
    this.pending = [];
    for (let i = 0; i < pending.length; i++) {
      this.send(pending[i]);
    }
  }

  markWebNotReady(): void {
    this.bridgeEpoch++;
    this.webReady = false;
    this.pending = [];
  }

  reload(): boolean {
    if (this.reloader === null) {
      return false;
    }
    try {
      this.reloader();
      return true;
    } catch (_error) {
      return false;
    }
  }

  configure(sessionId: string, connectionEpoch: number, terminalGeneration: number, inputEpoch: number): boolean {
    this.sessionId = sessionId;
    this.connectionEpoch = connectionEpoch;
    this.terminalGeneration = terminalGeneration;
    this.inputEpoch = inputEpoch;
    return this.send({
      type: 'init',
      sessionId: sessionId,
      connectionEpoch: connectionEpoch,
      terminalGeneration: terminalGeneration,
      inputEpoch: inputEpoch,
      fontSize: 15,
      scrollback: 5000
    });
  }

  send(message: TerminalMessage): boolean {
    if (!this.webReady || this.sender === null) {
      if (message.type === 'output' || message.type === 'key' || message.type === 'text' || message.type === 'paste') {
        return false;
      }
      if (message.type === 'init') {
        this.pending = this.pending.filter((item: TerminalMessage): boolean => item.type !== 'init');
      }
      this.pending.push(message);
      if (this.pending.length > 16) {
        this.pending.shift();
      }
      return true;
    }
    this.sender(message);
    return true;
  }

  sendKey(key: string, ctrl: boolean, alt: boolean, shift: boolean, eventId: string): boolean {
    return this.send({
      type: 'key',
      sessionId: this.sessionId,
      connectionEpoch: this.connectionEpoch,
      terminalGeneration: this.terminalGeneration,
      inputEpoch: this.inputEpoch,
      eventId: eventId,
      key: key,
      ctrl: ctrl,
      alt: alt,
      shift: shift
    });
  }

  sendText(text: string, eventId: string): boolean {
    return this.send({
      type: 'text',
      sessionId: this.sessionId,
      connectionEpoch: this.connectionEpoch,
      terminalGeneration: this.terminalGeneration,
      inputEpoch: this.inputEpoch,
      eventId: eventId,
      data: ByteCodec.encodeText(text)
    });
  }

  sendPaste(text: string, eventId: string): boolean {
    return this.send({
      type: 'paste',
      sessionId: this.sessionId,
      connectionEpoch: this.connectionEpoch,
      terminalGeneration: this.terminalGeneration,
      inputEpoch: this.inputEpoch,
      eventId: eventId,
      data: ByteCodec.encodeText(text)
    });
  }

  focus(ime: boolean): boolean {
    return this.send({ type: 'focus', ime: ime });
  }

  fit(): boolean {
    return this.send({ type: 'fit' });
  }

  clear(): boolean {
    return this.send({ type: 'clear' });
  }
}
