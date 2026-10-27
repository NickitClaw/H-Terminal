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
  authMethod?: string;
  privateKey?: string;
}

export interface NativeInputRequest {
  sessionId: string;
  connectionEpoch: number;
  inputEpoch: number;
  eventId: string;
  data: string;
  pastePhase?: string;
  pasteId?: string;
}

export interface NativeAck {
  sessionId: string;
  connectionEpoch: number;
  terminalGeneration: number;
  seq: number;
  byteLength: number;
}

export interface NativeEvent {
  type: 'state' | 'hostKey' | 'hostIdentity' | 'output' | 'error' | 'inputCredit' | 'inputConsumed' | 'probe' |
    'inputReset' | 'authChallenge';
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
  requestId?: number;
  title?: string;
  instruction?: string;
  prompts?: NativeAuthPrompt[];
}

export interface NativeAuthPrompt { text: string; echo: boolean; }
export interface NativeKeyInfo { publicKey: string; fingerprint: string; }

export const initialize: (callback: (event: NativeEvent) => void) => void;
export const connect: (options: NativeConnectOptions) => void;
export const trustDecision: (sessionId: string, connectionEpoch: number, accepted: boolean) => void;
export const writeInput: (request: NativeInputRequest) => boolean;
export const resize: (sessionId: string, connectionEpoch: number, cols: number, rows: number) => void;
export const acknowledgeOutput: (request: NativeAck) => void;
export const closeSession: (sessionId: string, connectionEpoch: number) => void;
export const dispose: () => void;
export const probeSession: (sessionId: string, connectionEpoch: number, requestId: number) => void;
export const resetInput: (sessionId: string, connectionEpoch: number, inputEpoch: number, sendControl: boolean) => void;
export const answerAuthentication: (sessionId: string, connectionEpoch: number, requestId: number, answers: string[]) => void;
export const inspectPrivateKey: (privateKey: string, passphrase: string) => Promise<NativeKeyInfo>;
export const inspectKnownHost: (filesDir: string, host: string, port: number) => Promise<NativeKeyInfo>;
export const forgetKnownHost: (filesDir: string, host: string, port: number, expectedFingerprint: string) => Promise<NativeKeyInfo>;
