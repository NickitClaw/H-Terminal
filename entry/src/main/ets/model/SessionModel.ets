export enum ConnectionState {
  IDLE = 'IDLE',
  CONNECTING = 'CONNECTING',
  VERIFYING_HOST = 'VERIFYING_HOST',
  AUTHENTICATING = 'AUTHENTICATING',
  OPEN = 'OPEN',
  CLOSED = 'CLOSED',
  FAILED = 'FAILED'
}

export class HostKeyInfo {
  host: string = '';
  port: number = 0;
  keyType: string = '';
  fingerprint: string = '';
}

export class TerminalSize {
  cols: number = 0;
  rows: number = 0;
}

export class SessionSnapshot {
  retrying: boolean = false;
  selecting: boolean = false;
  state: ConnectionState = ConnectionState.IDLE;
  message: string = '尚未连接';
  terminalReady: boolean = false;
  inputEnabled: boolean = false;
  suspended: boolean = false;
  checking: boolean = false;
  pasting: boolean = false;
}
