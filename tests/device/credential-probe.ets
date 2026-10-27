import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import native from 'libentry.so';
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
    phase = 'credential deletion';
    await vault.remove(id);
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
