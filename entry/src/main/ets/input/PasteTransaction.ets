import { NativeInputRequest } from 'libentry.so';
import { ByteCodec } from '../util/ByteCodec';

export class PasteTransaction {
  private bytes: Uint8Array;
  private offset: number = 0;
  private phase: string = 'start';
  private part: number = 0;
  private awaiting: NativeInputRequest | null = null;
  private remaining: number = 0;
  readonly id: string;
  private sessionId: string;
  private connectionEpoch: number;
  private inputEpoch: number;
  private bracketed: boolean;

  constructor(sessionId: string, connectionEpoch: number, inputEpoch: number, id: string,
    bytes: Uint8Array, bracketed: boolean) {
    ByteCodec.validateUtf8(bytes);
    this.sessionId = sessionId;
    this.connectionEpoch = connectionEpoch;
    this.inputEpoch = inputEpoch;
    this.id = id;
    this.bytes = bytes;
    this.bracketed = bracketed;
  }

  next(): NativeInputRequest | null {
    if (this.awaiting !== null || this.phase === 'done') return null;
    let bytes = new Uint8Array(0);
    const phase = this.phase;
    if (phase === 'start') {
      bytes = ByteCodec.decodeBytes(this.bracketed ? 'G1syMDB+' : '');
      this.phase = this.bytes.length > 0 ? 'data' : 'end';
    } else if (phase === 'data') {
      let end = Math.min(this.offset + 4096, this.bytes.length);
      while (end < this.bytes.length && end > this.offset && (this.bytes[end] & 0xC0) === 0x80) end--;
      bytes = this.bytes.subarray(this.offset, end);
      this.offset = end;
      if (end === this.bytes.length) this.phase = 'end';
    } else {
      bytes = ByteCodec.decodeBytes(this.bracketed ? 'G1syMDF+' : '');
      this.phase = 'done';
    }
    this.part++;
    const request: NativeInputRequest = {
      sessionId: this.sessionId, connectionEpoch: this.connectionEpoch, inputEpoch: this.inputEpoch,
      eventId: `${this.id}-${this.part}`, data: ByteCodec.encodeBytes(bytes), pasteId: this.id, pastePhase: phase
    };
    this.awaiting = request;
    this.remaining = bytes.length;
    return request;
  }

  consume(eventId: string, bytes: number): boolean {
    if (this.awaiting === null || this.awaiting.eventId !== eventId || bytes < 0 || bytes > this.remaining) return false;
    this.remaining -= bytes;
    if (this.remaining === 0) this.awaiting = null;
    return true;
  }

  done(): boolean { return this.phase === 'done' && this.awaiting === null; }

  clear(): void {
    this.bytes.fill(0);
    this.bytes = new Uint8Array(0);
    this.awaiting = null;
    this.phase = 'done';
  }
}
