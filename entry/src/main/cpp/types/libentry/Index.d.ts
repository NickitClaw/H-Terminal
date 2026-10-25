export interface NativeConnectOptions {
  sessionId: string;
  connectionEpoch: number;
  terminalGeneration: number;
  filesDir: string;
  host: string;
  port: number;
  username: string;
  password: string;
  cols: number;
  rows: number;
}

export interface NativeInputRequest {
  sessionId: string;
  connectionEpoch: number;
  inputEpoch: number;
  eventId: string;
  data: string;
}

export interface NativeAck {
  sessionId: string;
  connectionEpoch: number;
  terminalGeneration: number;
  seq: number;
  byteLength: number;
}

export interface NativeEvent {
  type: 'state' | 'hostKey' | 'output' | 'error' | 'inputCredit' | 'inputConsumed';
  sessionId: string;
  connectionEpoch: number;
  terminalGeneration?: number;
  state?: string;
  seq?: number;
  byteLength?: number;
  data?: string;
  message?: string;
  host?: string;
  port?: number;
  keyType?: string;
  fingerprint?: string;
  inputEpoch?: number;
  eventId?: string;
}

export const initialize: (callback: (event: NativeEvent) => void) => void;
export const connect: (options: NativeConnectOptions) => void;
export const trustDecision: (sessionId: string, connectionEpoch: number, accepted: boolean) => void;
export const writeInput: (request: NativeInputRequest) => boolean;
export const resize: (sessionId: string, connectionEpoch: number, cols: number, rows: number) => void;
export const acknowledgeOutput: (request: NativeAck) => void;
export const closeSession: (sessionId: string, connectionEpoch: number) => void;
export const dispose: () => void;
