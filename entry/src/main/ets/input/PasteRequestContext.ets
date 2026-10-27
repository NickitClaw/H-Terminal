export class PasteRequestContext {
  readonly sessionId: string;
  readonly connectionEpoch: number;
  readonly inputEpoch: number;

  constructor(sessionId: string, connectionEpoch: number, inputEpoch: number) {
    this.sessionId = sessionId;
    this.connectionEpoch = connectionEpoch;
    this.inputEpoch = inputEpoch;
  }
}
