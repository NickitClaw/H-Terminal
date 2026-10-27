import { NativeKeyInfo } from 'libentry.so';
import { SettingsStore } from './HostRepository';

export class EncryptedCredential {
  id: string = '';
  name: string = '';
  publicKey: string = '';
  fingerprint: string = '';
  nonce: string = '';
  ciphertext: string = '';
}

class VaultDocument { version: number = 1; credentials: EncryptedCredential[] = []; }

export class SealedData { nonce: string = ''; ciphertext: string = ''; }

export interface CredentialCipher {
  seal(id: string, plaintext: Uint8Array, aad: string): Promise<SealedData>;
  open(id: string, sealed: SealedData, aad: string): Promise<Uint8Array>;
  remove(id: string): Promise<void>;
  newId(): string;
}

export class CredentialVault {
  private document: VaultDocument = new VaultDocument();
  private store: SettingsStore;
  private cipher: CredentialCipher;
  private loaded: boolean = false;
  private queue: Promise<void> = Promise.resolve();

  constructor(store: SettingsStore, cipher: CredentialCipher) { this.store = store; this.cipher = cipher; }

  async load(): Promise<void> {
    const data = await this.store.read();
    if (data.length > 2 * 1024 * 1024) throw new Error('凭据存储过大');
    if (data.length > 0) {
      const parsed = JSON.parse(data) as VaultDocument;
      if (parsed.version !== 1 || !Array.isArray(parsed.credentials) || parsed.credentials.length > 16) {
        throw new Error('凭据存储版本不受支持');
      }
      const seen: string[] = [];
      const clean = new VaultDocument();
      for (let item of parsed.credentials) {
        if (!item || typeof item.id !== 'string' || !/^[a-zA-Z0-9_-]{1,80}$/.test(item.id) || seen.includes(item.id) ||
          typeof item.name !== 'string' || item.name.length > 64 || typeof item.publicKey !== 'string' ||
          !item.publicKey.startsWith('ssh-ed25519 ') || item.publicKey.length > 1024 ||
          typeof item.fingerprint !== 'string' || !item.fingerprint.startsWith('SHA256:') || item.fingerprint.length > 80 ||
          typeof item.nonce !== 'string' || item.nonce.length !== 16 || typeof item.ciphertext !== 'string' ||
          item.ciphertext.length > 90000 || item.ciphertext.length < 24) throw new Error('凭据存储格式错误');
        seen.push(item.id);
        const copy = new EncryptedCredential();
        copy.id = item.id; copy.name = item.name; copy.publicKey = item.publicKey; copy.fingerprint = item.fingerprint;
        copy.nonce = item.nonce; copy.ciphertext = item.ciphertext;
        clean.credentials.push(copy);
      }
      this.document = clean;
    }
    this.loaded = true;
  }

  list(): EncryptedCredential[] {
    return this.document.credentials.map((item: EncryptedCredential): EncryptedCredential => {
      const copy = new EncryptedCredential();
      copy.id = item.id; copy.name = item.name; copy.publicKey = item.publicKey; copy.fingerprint = item.fingerprint;
      return copy;
    });
  }

  save(name: string, plaintext: Uint8Array, info: NativeKeyInfo): Promise<string> {
    const id = this.cipher.newId();
    const result = this.queue.catch((): void => {}).then(async (): Promise<void> => {
      if (!this.loaded || this.document.credentials.length >= 16 || plaintext.length > 65536) throw new Error('无法保存凭据');
      const item = new EncryptedCredential();
      item.id = id; item.name = name.substring(0, 64); item.publicKey = info.publicKey; item.fingerprint = info.fingerprint;
      const encrypted = await this.cipher.seal(id, plaintext, CredentialVault.aad(item));
      item.nonce = encrypted.nonce; item.ciphertext = encrypted.ciphertext;
      const document = new VaultDocument();
      document.credentials = this.document.credentials.concat([item]);
      try { await this.store.write(JSON.stringify(document)); }
      catch (_error) { await this.cipher.remove(id); throw new Error('凭据保存失败'); }
      this.document = document;
    });
    this.queue = result;
    return result.then((): string => id);
  }

  async read(id: string): Promise<Uint8Array> {
    await this.queue.catch((): void => {});
    if (!this.loaded) throw new Error('凭据尚未加载');
    const item = this.document.credentials.find((value: EncryptedCredential): boolean => value.id === id);
    if (item === undefined) throw new Error('凭据不存在');
    const sealed = new SealedData(); sealed.nonce = item.nonce; sealed.ciphertext = item.ciphertext;
    return this.cipher.open(id, sealed, CredentialVault.aad(item));
  }

  remove(id: string): Promise<void> {
    const result = this.queue.catch((): void => {}).then(async (): Promise<void> => {
      if (!this.loaded) throw new Error('凭据尚未加载');
      const document = new VaultDocument();
      document.credentials = this.document.credentials.filter((item: EncryptedCredential): boolean => item.id !== id);
      await this.store.write(JSON.stringify(document));
      this.document = document;
      await this.cipher.remove(id);
    });
    this.queue = result;
    return result;
  }

  private static aad(item: EncryptedCredential): string { return `${item.id}|${item.publicKey}|${item.fingerprint}`; }
}
