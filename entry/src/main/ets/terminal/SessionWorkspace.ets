import { SessionController } from './SessionController';
import { XtermBackend } from './XtermBackend';
import { SessionSnapshot, HostKeyInfo } from '../model/SessionModel';
import { HostProfile } from '../storage/HostRepository';

export class SessionTab {
  readonly id: string;
  readonly backend: XtermBackend;
  readonly session: SessionController;
  snapshot: SessionSnapshot = new SessionSnapshot();
  identity: HostKeyInfo = new HostKeyInfo();
  profile: HostProfile = new HostProfile();
  imeMode: boolean = false;
  symbols: boolean = false;

  constructor(id: string) {
    this.id = id;
    this.backend = new XtermBackend();
    this.session = new SessionController(this.backend, id);
  }
}

export class SessionWorkspace {
  onAdded: (tab: SessionTab) => void = (_tab: SessionTab): void => {};
  onChanged: () => void = (): void => {};
  private tabs: SessionTab[] = [];
  private activeId: string = '';
  private nextId: number = 0;
  private filesDir: string;
  private foreground: boolean = true;
  private network: boolean = true;

  constructor(filesDir: string) { this.filesDir = filesDir; }
  list(): SessionTab[] { return this.tabs.slice(); }
  active(): SessionTab | null { return this.tabs.find((tab: SessionTab): boolean => tab.id === this.activeId) ?? null; }

  create(): SessionTab | null {
    if (this.tabs.length >= 4) return null;
    const previous = this.active();
    const tab = new SessionTab(`session-${++this.nextId}`);
    this.tabs.push(tab);
    this.activeId = tab.id;
    previous?.session.setSelected(false);
    this.onAdded(tab);
    tab.session.initialize(this.filesDir);
    tab.session.setForeground(this.foreground);
    if (!this.network) tab.session.setNetworkAvailable(false);
    this.onChanged();
    return tab;
  }

  select(id: string): void {
    const tab = this.tabs.find((item: SessionTab): boolean => item.id === id);
    if (tab === undefined || id === this.activeId) return;
    const previous = this.active();
    this.activeId = id;
    previous?.session.setSelected(false);
    tab.session.setSelected(true);
    this.onChanged();
  }

  close(id: string): void {
    const tab = this.tabs.find((item: SessionTab): boolean => item.id === id);
    if (tab === undefined) return;
    this.tabs = this.tabs.filter((item: SessionTab): boolean => item.id !== id);
    tab.session.dispose();
    tab.backend.markWebNotReady();
    if (id === this.activeId) {
      this.activeId = this.tabs.length > 0 ? this.tabs[0].id : '';
      this.active()?.session.setSelected(true);
    }
    this.onChanged();
  }

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
    this.tabs.forEach((tab: SessionTab): void => tab.session.setForeground(foreground));
  }
  setNetworkAvailable(available: boolean): void {
    this.network = available;
    this.tabs.forEach((tab: SessionTab): void => tab.session.setNetworkAvailable(available));
  }
  checkIdleConnections(): void {
    this.tabs.forEach((tab: SessionTab): void => tab.session.checkIdleConnection());
  }
  dispose(): void {
    this.onChanged = (): void => {};
    this.tabs.forEach((tab: SessionTab): void => tab.session.dispose());
    this.tabs = [];
    this.activeId = '';
  }
}
