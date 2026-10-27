export interface TerminalMessage {
  type: string;
  sessionId?: string;
  connectionEpoch?: number;
  terminalGeneration?: number;
  inputEpoch?: number;
  eventId?: string;
  seq?: number;
  byteLength?: number;
  data?: string;
  binary?: boolean;
  key?: string;
  ctrl?: boolean;
  alt?: boolean;
  shift?: boolean;
  cols?: number;
  rows?: number;
  fontSize?: number;
  scrollback?: number;
  ime?: boolean;
  code?: string;
  fatal?: boolean;
  source?: string;
  bracketed?: boolean;
}

export interface TerminalBackend {
  configure(sessionId: string, connectionEpoch: number, terminalGeneration: number, inputEpoch: number): boolean;
  send(message: TerminalMessage): boolean;
  sendKey(key: string, ctrl: boolean, alt: boolean, shift: boolean, eventId: string): boolean;
  sendText(text: string, eventId: string): boolean;
  sendPaste(text: string, eventId: string): boolean;
  focus(ime: boolean): boolean;
  fit(): boolean;
  clear(): boolean;
  reload(): boolean;
}
