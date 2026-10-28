export type AuthMethod = 'password' | 'publickey' | 'keyboard-interactive' |
  'password+keyboard-interactive' | 'publickey+keyboard-interactive';

export class HostProfile {
  autoReconnect: boolean = false;
  id: string = '';
  name: string = '';
  host: string = '';
  port: number = 22;
  username: string = '';
  authMethod: AuthMethod = 'password';
  credentialId: string = '';
}

export class UserPreferences {
  fontSize: number = 15;
  keyboardMode: string = 'compact';
  layout: string = 'auto';
  showKeyboard: boolean = true;
}

class SettingsDocument {
  version: number = 1;
  hosts: HostProfile[] = [];
  preferences: UserPreferences = new UserPreferences();
}

export interface SettingsStore {
  read(): Promise<string>;
  write(value: string): Promise<void>;
}

export class HostRepository {
  private store: SettingsStore;
  private document: SettingsDocument = new SettingsDocument();
  private loaded: boolean = false;
  private queue: Promise<void> = Promise.resolve();
  private counter: number = 0;

  constructor(store: SettingsStore) { this.store = store; }

  async load(): Promise<void> {
    const text = await this.store.read();
    if (text.length > 256 * 1024) throw new Error('主机配置文件过大');
    if (text.length > 0) {
      const parsed = JSON.parse(text) as SettingsDocument;
      if (parsed.version !== 1 || !Array.isArray(parsed.hosts) || parsed.hosts.length > 128) {
        throw new Error('主机配置版本或格式不受支持');
      }
      const ids: string[] = [];
      const clean = new SettingsDocument();
      for (let host of parsed.hosts) {
        const profile = HostRepository.cleanHost(host);
        if (profile.id.length === 0 || ids.includes(profile.id)) throw new Error('主机配置标识重复');
        ids.push(profile.id);
        clean.hosts.push(profile);
      }
      clean.preferences = HostRepository.cleanPreferences(parsed.preferences);
      this.document = clean;
    }
    this.loaded = true;
  }

  list(): HostProfile[] { return this.document.hosts.map((item: HostProfile): HostProfile => HostRepository.cleanHost(item)); }
  preferences(): UserPreferences { return HostRepository.cleanPreferences(this.document.preferences); }

  saveHost(host: HostProfile): Promise<string> {
    const profile = HostRepository.cleanHost(host);
    return this.mutate((): void => {
      if (profile.id.length === 0) {
        do { profile.id = `host-${Date.now()}-${++this.counter}`; }
        while (this.document.hosts.some((item: HostProfile): boolean => item.id === profile.id));
      }
      const index = this.document.hosts.findIndex((item: HostProfile): boolean => item.id === profile.id);
      if (index >= 0) this.document.hosts[index] = profile;
      else {
        if (this.document.hosts.length >= 128) throw new Error('最多保存 128 个主机');
        this.document.hosts.push(profile);
      }
    }).then((): string => profile.id);
  }

  deleteHost(id: string): Promise<void> {
    return this.mutate((): void => {
      this.document.hosts = this.document.hosts.filter((host: HostProfile): boolean => host.id !== id);
    });
  }

  savePreferences(preferences: UserPreferences): Promise<void> {
    const clean = HostRepository.cleanPreferences(preferences);
    return this.mutate((): void => { this.document.preferences = clean; });
  }

  private mutate(change: () => void): Promise<void> {
    const result = this.queue.catch((): void => {}).then(async (): Promise<void> => {
      if (!this.loaded) throw new Error('配置尚未加载，不能覆盖现有数据');
      const previous = JSON.stringify(this.document);
      try {
        change();
        await this.store.write(JSON.stringify(this.document));
      } catch (_error) {
        this.document = JSON.parse(previous) as SettingsDocument;
        throw new Error('主机配置保存失败');
      }
    });
    this.queue = result;
    return result;
  }

  private static cleanHost(source: HostProfile): HostProfile {
    if (source === null || source === undefined || typeof source.host !== 'string' ||
      typeof source.username !== 'string' || typeof source.name !== 'string' || typeof source.id !== 'string' ||
      !Number.isInteger(source.port) || source.port < 1 || source.port > 65535 ||
      source.host.trim().length === 0 || source.host.length > 1024 || source.username.trim().length === 0 ||
      source.username.length > 256 || source.name.length > 64 || source.id.length > 80 || !/^[a-zA-Z0-9_-]*$/.test(source.id) ||
      !['password', 'publickey', 'keyboard-interactive', 'password+keyboard-interactive',
        'publickey+keyboard-interactive'].includes(source.authMethod) ||
      typeof source.credentialId !== 'string' || !/^[a-zA-Z0-9_-]{0,80}$/.test(source.credentialId) ||
      /[\x00-\x1f\x7f]/.test(source.host + source.username + source.name)) throw new Error('请检查主机配置');
    const clean = new HostProfile();
    clean.id = source.id;
    clean.host = source.host.trim();
    clean.port = source.port;
    clean.username = source.username.trim();
    clean.name = source.name.trim() || `${clean.username}@${clean.host}`.substring(0, 64);
    clean.authMethod = source.authMethod;
    clean.credentialId = source.credentialId;
    clean.autoReconnect = source.autoReconnect === true;
    return clean;
  }

  private static cleanPreferences(source: UserPreferences): UserPreferences {
    const clean = new UserPreferences();
    if (source !== null && source !== undefined) {
      if (Number.isInteger(source.fontSize) && source.fontSize >= 10 && source.fontSize <= 28) clean.fontSize = source.fontSize;
      clean.keyboardMode = source.keyboardMode === 'full' ? 'full' : 'compact';
      clean.layout = ['auto', 'laptop', 'normal'].includes(source.layout) ? source.layout : 'auto';
      clean.showKeyboard = source.showKeyboard !== false;
    }
    return clean;
  }
}
