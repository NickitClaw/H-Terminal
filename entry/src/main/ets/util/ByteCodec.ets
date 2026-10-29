import { util } from '@kit.ArkTS';

export class ByteCodec {
  private static base64: util.Base64Helper = new util.Base64Helper();
  private static encoder: util.TextEncoder = new util.TextEncoder('utf-8');
  private static decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  static encodeText(text: string): string {
    return ByteCodec.base64.encodeToStringSync(ByteCodec.encoder.encodeInto(text));
  }

  static encodeBytes(bytes: Uint8Array): string {
    return ByteCodec.base64.encodeToStringSync(bytes);
  }

  static decodeBytes(data: string): Uint8Array {
    return ByteCodec.base64.decodeSync(data);
  }

  static decodeText(data: string): string {
    return ByteCodec.decoder.decodeToString(ByteCodec.decodeBytes(data));
  }

  static byteLength(text: string): number {
    return ByteCodec.encoder.encodeInto(text).length;
  }

  static validateUtf8(bytes: Uint8Array): void {
    if (bytes.length === 0) return;
    util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
  }
}
