import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import native, { NativeConnectOptions, NativeInputRequest } from 'libentry.so';
import { CredentialVault } from '../../storage/CredentialVault';
import { HuksCredentialCipher } from '../../storage/HuksCredentialCipher';
import { PreferencesStore } from '../../storage/PreferencesStore';
import { ByteCodec } from '../../util/ByteCodec';
import { BusinessError } from '@kit.BasicServicesKit';

// Copied into a temporary debug build by verify-device-storage.py. It is never
// included in the normal HAP. Only disposable generated test identities are used.
export async function verifyDeviceStorage(context: common.Context): Promise<void> {
  const marker = '__HT_PROBE_MARKER__';
  const key: string = __HT_PROBE_KEY__;
  const encryptedKey: string = __HT_PROBE_ENCRYPTED_KEY__;
  const store = await PreferencesStore.open(context, 'hterminal-device-storage-probe');
  await store.write('');
  const cipher = new HuksCredentialCipher();
  const vault = new CredentialVault(store, cipher);
  await vault.load();
  let id = '';
  let plaintext = new Uint8Array(0);
  let phase = 'inspection';
  try {
    const expectRejection = (operation: () => void): void => {
      let rejected = false;
      try { operation(); } catch (_error) { rejected = true; }
      if (!rejected) throw new Error('invalid input accepted');
    };
    phase = 'UTF-8 paste validation';
    ByteCodec.validateUtf8(new Uint8Array(0));
    ByteCodec.validateUtf8(ByteCodec.decodeBytes(ByteCodec.encodeText('\uFEFFzero\0界🙂')));
    for (const invalid of [new Uint8Array(5000).fill(0x80), new Uint8Array([0xc0, 0xaf]),
      new Uint8Array([0xed, 0xa0, 0x80]), new Uint8Array([0xf4, 0x90, 0x80, 0x80]), new Uint8Array([0xe2, 0x82])]) {
      expectRejection((): void => { ByteCodec.validateUtf8(invalid); });
    }
    phase = 'inspection';
    expectRejection((): void => { native.getSessionMetrics('probe-missing', Number.NaN); });
    expectRejection((): void => { native.resize('probe-missing', 1, Number.NaN, 24); });
    expectRejection((): void => { native.answerAuthentication('probe-missing', 1, 1, new Array<string>(17).fill('fixture')); });
    const input: NativeInputRequest = { sessionId: 'probe-missing', connectionEpoch: 1,
      inputEpoch: 1, eventId: 'probe', data: 'QR==' };
    expectRejection((): void => { native.writeInput(input); });
    input.data = 'QQ==';
    const malformedPhase = JSON.parse(JSON.stringify(input).replace('"data":"QQ=="', '"data":"QQ==","pastePhase":0')) as NativeInputRequest;
    expectRejection((): void => { native.writeInput(malformedPhase); });
    const options: NativeConnectOptions = { sessionId: 'probe-missing', connectionEpoch: 1, terminalGeneration: 1,
      filesDir: context.filesDir, host: '10.0.2.2', port: Number.NaN, username: 'review', password: '', cols: 80, rows: 24 };
    expectRejection((): void => { native.connect(options); });
    const info = await native.inspectPrivateKey(key, '');
    const encryptedInfo = await native.inspectPrivateKey(encryptedKey, 'fixture-passphrase');
    if (!info.publicKey.startsWith('ssh-ed25519 ') || !encryptedInfo.fingerprint.startsWith('SHA256:')) {
      throw new Error('inspection failed');
    }
    let rejected = false;
    try { await native.inspectPrivateKey(encryptedKey, 'wrong'); } catch (_error) { rejected = true; }
    if (!rejected) throw new Error('wrong passphrase accepted');
    plaintext = ByteCodec.decodeBytes(ByteCodec.encodeText(key));
    phase = 'HUKS encryption';
    id = await vault.save('Disposable device probe', plaintext, info);
    const stored = await store.read();
    if (stored.includes('PRIVATE KEY')) throw new Error('plaintext persisted');
    const restarted = new CredentialVault(store, cipher);
    await restarted.load();
    phase = 'HUKS decryption';
    const decoded = await restarted.read(id);
    phase = 'roundtrip validation';
    if (ByteCodec.encodeBytes(decoded) !== ByteCodec.encodeBytes(plaintext)) throw new Error('roundtrip failed');
    decoded.fill(0);
    // Bind metadata to the authentication tag; no unauthenticated plaintext
    // may be returned after tampering.
    await store.write(stored.replace(info.fingerprint, 'SHA256:tampered'));
    phase = 'tamper validation';
    const tampered = new CredentialVault(store, cipher);
    await tampered.load();
    rejected = false;
    try { const unsafe = await tampered.read(id); unsafe.fill(0); } catch (_error) { rejected = true; }
    if (!rejected) throw new Error('tampered metadata accepted');
    phase = 'credential deletion after key loss';
    await cipher.remove(id);
    await vault.remove(id);
    await cipher.remove(id);
    id = '';
    const empty = new CredentialVault(store, cipher);
    await empty.load();
    if (empty.list().length !== 0) throw new Error('credential deletion failed');
    hilog.info(0x0000, 'HTDeviceProbe', '%{public}s PASS', marker);
  } catch (error) {
    hilog.error(0x0000, 'HTDeviceProbe', '%{public}s FAIL phase=%{public}s code=%{public}d', marker, phase,
      (error as BusinessError).code ?? 0);
  } finally {
    plaintext.fill(0);
    if (id.length > 0) { try { await vault.remove(id); } catch (_error) {} }
    await store.write('');
  }
}
