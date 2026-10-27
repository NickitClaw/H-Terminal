import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { SettingsStore } from './HostRepository';

export class PreferencesStore implements SettingsStore {
  private preferences: preferences.Preferences;
  private key: string;

  private constructor(store: preferences.Preferences, key: string) {
    this.preferences = store;
    this.key = key;
  }

  static async open(context: common.Context, name: string, key: string = 'document'): Promise<PreferencesStore> {
    const store = await preferences.getPreferences(context, { name: name });
    return new PreferencesStore(store, key);
  }

  async read(): Promise<string> { return await this.preferences.get(this.key, '') as string; }
  async write(value: string): Promise<void> {
    await this.preferences.put(this.key, value);
    await this.preferences.flush();
  }
}
