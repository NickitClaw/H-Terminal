import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { CredentialCipher, SealedData } from './CredentialVault';
import { ByteCodec } from '../util/ByteCodec';
import { BusinessError } from '@kit.BasicServicesKit';

class CredentialCryptoError extends Error {
  code: number;
  constructor(code: number) { super('凭据解锁或完整性检查失败'); this.code = code; }
}

export class HuksCredentialCipher implements CredentialCipher {
  newId(): string { return util.generateRandomUUID(true); }
  private alias(id: string): string { return `hterminal-import-${id}`; }

  async seal(id: string, plaintext: Uint8Array, aad: string): Promise<SealedData> {
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT }
    ];
    await huks.generateKeyItem(this.alias(id), { properties: properties });
    const nonce = cryptoFramework.createRandom().generateRandomSync(12).data;
    try {
      const cipher = await this.operate(id, plaintext, nonce, aad, true);
      const sealed = new SealedData();
      sealed.nonce = ByteCodec.encodeBytes(nonce); sealed.ciphertext = ByteCodec.encodeBytes(cipher);
      return sealed;
    } catch (_error) {
      await this.remove(id);
      throw new Error('设备无法保护此凭据');
    }
  }

  async open(id: string, sealed: SealedData, aad: string): Promise<Uint8Array> {
    return this.operate(id, ByteCodec.decodeBytes(sealed.ciphertext), ByteCodec.decodeBytes(sealed.nonce), aad, false);
  }

  async remove(id: string): Promise<void> {
    try { await huks.deleteKeyItem(this.alias(id), { properties: [] }); }
    catch (error) {
      // HUKS reports a missing entity as an error, including after a prior
      // deletion or device-key loss. The requested cleanup is already done.
      if ((error as BusinessError).code !== 12000011) throw error as Error;
    }
  }

  private async operate(id: string, data: Uint8Array, nonce: Uint8Array, aad: string, encrypt: boolean): Promise<Uint8Array> {
    if (nonce.length !== 12 || (!encrypt && data.length < 16)) throw new Error('凭据密文无效');
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: encrypt ?
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT : huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
      { tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: ByteCodec.decodeBytes(ByteCodec.encodeText(aad)) }
    ];
    if (!encrypt) properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: data.slice(data.length - 16) });
    const input = encrypt ? data : data.subarray(0, data.length - 16);
    const handle = await huks.initSession(this.alias(id), { properties: properties });
    const parts: Uint8Array[] = [];
    try {
      for (let offset = 0; offset < input.length; offset += 4096) {
        const result = await huks.updateSession(handle.handle,
          { properties: properties, inData: input.subarray(offset, Math.min(offset + 4096, input.length)) });
        if (result?.outData) parts.push(result.outData);
      }
      const final = await huks.finishSession(handle.handle, { properties: properties, inData: new Uint8Array(0) });
      if (final?.outData) parts.push(final.outData);
      let total = 0;
      parts.forEach((part: Uint8Array): void => { total += part.length; });
      const output = new Uint8Array(total);
      let offset = 0;
      parts.forEach((part: Uint8Array): void => { output.set(part, offset); offset += part.length; part.fill(0); });
      return output;
    } catch (error) {
      parts.forEach((part: Uint8Array): void => { part.fill(0); });
      try { await huks.abortSession(handle.handle, { properties: [] }); } catch (_ignored) {}
      throw new CredentialCryptoError((error as BusinessError).code ?? 0);
    }
  }
}
