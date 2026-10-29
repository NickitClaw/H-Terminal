import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { SettingsStore } from './HostRepository';

export class PreferencesStore implements SettingsStore {
  private preferences: preferences.Preferences;
  private key: string;
  private writes: Promise<void> = Promise.resolve();
  private cacheUsable: boolean = true;

  private constructor(store: preferences.Preferences, key: string) {
    this.preferences = store;
    this.key = key;
  }

  static async open(context: common.Context, name: string, key: string = 'document'): Promise<PreferencesStore> {
    const store = await preferences.getPreferences(context, { name: name });
    return new PreferencesStore(store, key);
  }

  async read(): Promise<string> {
    await this.writes.catch((): void => {});
    this.requireUsableCache();
    return await this.preferences.get(this.key, '') as string;
  }

  write(value: string): Promise<void> {
    const operation = this.writes.catch((): void => {}).then(async (): Promise<void> => {
      this.requireUsableCache();
      const previous = await this.preferences.get(this.key, '');
      try {
        await this.preferences.put(this.key, value);
        await this.preferences.flush();
      } catch (error) {
        // put changes the shared Preferences cache before flush reaches disk.
        // Restore it before callers roll back metadata or delete a draft key.
        try { await this.preferences.put(this.key, previous); }
        catch (_rollbackError) { this.cacheUsable = false; }
        throw error as Error;
      }
    });
    this.writes = operation;
    return operation;
  }

  private requireUsableCache(): void {
    if (!this.cacheUsable) throw new Error('偏好缓存回滚失败，请重新启动应用');
  }
}
