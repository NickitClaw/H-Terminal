import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { HostKeyInfo, ConnectionState, SessionSnapshot } from '../model/SessionModel';
import { TerminalView } from '../terminal/TerminalView';
import { XtermBackend } from '../terminal/XtermBackend';
import { SessionController } from '../terminal/SessionController';
import { InputRouter, ModifierSnapshot } from '../input/InputRouter';
import { KeyDefinition, KeyboardLayoutMode } from '../input/KeyboardModel';
import { PasteRequestContext } from '../input/PasteRequestContext';
import { KeyContact } from '../input/KeyboardInteraction';
import { LaptopKeyboard } from '../components/LaptopKeyboard';
import { LayoutPreference, PostureEngine, PostureSnapshot } from '../posture/PostureEngine';
import { LayoutCoordinator, LayoutResult } from '../posture/LayoutCoordinator';
import { ByteCodec } from '../util/ByteCodec';
import { AppLifecycle } from '../lifecycle/AppLifecycle';
import { NetworkMonitor } from '../lifecycle/NetworkMonitor';
import { HostProfile, HostRepository, UserPreferences, AuthMethod } from '../storage/HostRepository';
import { PreferencesStore } from '../storage/PreferencesStore';
import { CredentialVault, EncryptedCredential } from '../storage/CredentialVault';
import { HuksCredentialCipher } from '../storage/HuksCredentialCipher';
import native, { NativeEvent, NativeAuthPrompt } from 'libentry.so';
import { picker, fileIo } from '@kit.CoreFileKit';
import { SessionWorkspace, SessionTab } from '../terminal/SessionWorkspace';

@Entry
@Component
struct Index {
  @State private snapshot: SessionSnapshot = new SessionSnapshot();
  @State private host: string = '127.0.0.1';
  @State private portText: string = '2222';
  @State private username: string = '';
  @State private password: string = '';
  @State private hostName: string = '';
  @State private hostId: string = '';
  @State private hosts: HostProfile[] = [];
  @State private showHosts: boolean = false;
  @State private showCredentials: boolean = false;
  @State private settingsReady: boolean = false;
  @State private authMethod: AuthMethod = 'password';
  @State private autoReconnect: boolean = false;
  @State private credentialId: string = '';
  @State private credentials: EncryptedCredential[] = [];
  @State private importingKey: boolean = false;
  @State private importStatus: string = '选择文件…';
  @State private forgettingTrust: boolean = false;
  @State private preparingConnection: boolean = false;
  @State private authChallenge: NativeEvent | null = null;
  @State private authAnswers: string[] = [];
  @State private identity: HostKeyInfo = new HostKeyInfo();
  @State private tabs: SessionTab[] = [];
  @State private activeTabId: string = '';
  @State private showConnect: boolean = true;
  @State private showPasteAuthorization: boolean = false;
  @State private showKeyboard: boolean = true;
  @State private imeMode: boolean = false;
  @State private keyboardMode: KeyboardLayoutMode = KeyboardLayoutMode.COMPACT;
  @State private symbolLayer: boolean = false;
  @State private modifiers: ModifierSnapshot = new ModifierSnapshot();
  @State private posture: PostureSnapshot = new PostureSnapshot();
  @State private rootWidth: number = 0;
  @State private rootHeight: number = 0;
  @State private rootGlobalY: number = 0;
  @State private showTerminalTools: boolean = false;
  @State private fontSize: number = 15;
  @State private searchText: string = '';
  private backend: XtermBackend = new XtermBackend();
  private session: SessionController = new SessionController(this.backend);
  private postureEngine: PostureEngine = new PostureEngine();
  private fitTimer: number = -1;
  private pendingPaste: PasteRequestContext | null = null;
  private windowGeometryRequest: number = 0;
  private networkMonitor: NetworkMonitor = new NetworkMonitor();
  private repository: HostRepository | null = null;
  private vault: CredentialVault | null = null;
  private authTarget: SessionController | null = null;
  private authEpoch: number = 0;
  private connectRequest: number = 0;
  private workspace: SessionWorkspace | null = null;
  private pageActive: boolean = false;
  private pageGeneration: number = 0;
  private healthTimer: number = -1;
  private lifecycleListener: (foreground: boolean) => void = (foreground: boolean): void => {
    this.cancelPasteRequest();
    if (!foreground) {
      ++this.connectRequest;
      this.preparingConnection = false;
      this.password = '';
      this.clearAuthentication();
    }
    this.workspace?.setForeground(foreground);
  };

  aboutToAppear(): void {
    this.pageActive = true;
    ++this.pageGeneration;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const workspace = new SessionWorkspace(this.getUIContext().getHostContext()?.filesDir ?? '');
    this.workspace = workspace;
    workspace.onAdded = (tab: SessionTab): void => { this.attachTab(tab); };
    workspace.onChanged = (): void => { this.refreshTabs(); };
    workspace.create();
    this.healthTimer = setInterval((): void => { this.workspace?.checkIdleConnections(); }, 30000);
    this.postureEngine.onChanged = (snapshot: PostureSnapshot): void => {
      this.posture = snapshot;
    };
    this.loadSettings();
    AppLifecycle.subscribe(this.lifecycleListener);
    this.networkMonitor.onChanged = (available: boolean): void => { this.workspace?.setNetworkAvailable(available); };
    this.networkMonitor.start();
    this.postureEngine.start();
    this.updateWindowGeometry();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    ++this.pageGeneration;
    ++this.connectRequest;
    this.clearAuthentication();
    AppLifecycle.unsubscribe(this.lifecycleListener);
    this.networkMonitor.stop();
    this.password = '';
    this.cancelPasteRequest();
    this.postureEngine.stop();
    this.workspace?.dispose();
    this.workspace = null;
    if (this.healthTimer >= 0) clearInterval(this.healthTimer);
    this.healthTimer = -1;
    if (this.fitTimer >= 0) {
      clearTimeout(this.fitTimer);
    }
  }

  private attachTab(tab: SessionTab): void {
    tab.backend.setFontSize(this.fontSize);
    const session = tab.session;
    session.onReconnectRequested = (): void => {
      if (this.workspace?.active()?.id !== tab.id || !this.pageActive) { session.cancelReconnect(); return; }
      this.applyProfile(tab.profile);
      this.connect(true);
    };
    session.onSnapshot = (snapshot: SessionSnapshot): void => {
      tab.snapshot = snapshot;
      this.refreshTabs();
    };
    session.onHostIdentity = (info: HostKeyInfo): void => {
      tab.identity = info;
      if (this.activeTabId === tab.id) this.identity = info;
    };
    session.onHostKey = (info: HostKeyInfo): void => {
      if (this.workspace?.active()?.id === tab.id) this.showHostKeyDialog(info);
      else session.disconnect();
    };
    session.onAuthChallenge = (event: NativeEvent): void => {
      if (this.workspace?.active()?.id !== tab.id) { session.disconnect(); return; }
      this.authTarget = session;
      this.authEpoch = session.getConnectionEpoch();
      this.authChallenge = event;
      this.authAnswers = (event.prompts ?? []).map((_prompt: NativeAuthPrompt): string => '');
    };
    session.onCopy = (text: string): void => { if (this.activeTabId === tab.id) this.copyText(text); };
    session.onPasteRequest = (): void => { if (this.activeTabId === tab.id) this.requestPasteAuthorization(); };
    session.onAction = (action: string): void => { if (this.activeTabId === tab.id) this.handleAction(action); };
    session.onToast = (message: string): void => { this.showToast(message); };
    session.input.onModifiersChanged = (modifiers: ModifierSnapshot): void => {
      if (this.activeTabId === tab.id) this.modifiers = modifiers;
    };
  }

  private refreshTabs(): void {
    this.tabs = this.workspace?.list() ?? [];
    const active = this.workspace?.active();
    if (active === null || active === undefined) return;
    if (this.activeTabId !== active.id) {
      this.activeTabId = active.id;
      this.session = active.session;
      this.backend = active.backend;
      this.applyProfile(active.profile);
      this.imeMode = active.imeMode;
      this.symbolLayer = active.symbols;
      this.identity = active.identity;
      this.showConnect = active.snapshot.state !== ConnectionState.OPEN;
    }
    this.snapshot = active.snapshot;
    this.modifiers = active.session.input.getModifiers();
    if (!this.snapshot.inputEnabled) this.cancelPasteRequest();
    if (this.snapshot.state !== ConnectionState.AUTHENTICATING && this.authTarget === active.session) this.clearAuthentication();
    if (this.snapshot.state === ConnectionState.OPEN) this.showConnect = false;
    else if (this.snapshot.state === ConnectionState.FAILED) this.showConnect = true;
  }

  private currentProfile(): HostProfile {
    const profile = new HostProfile();
    profile.id = this.hostId; profile.name = this.hostName; profile.host = this.host;
    profile.port = Number(this.portText); profile.username = this.username;
    profile.authMethod = this.authMethod; profile.credentialId = this.credentialId;
    profile.autoReconnect = this.autoReconnect;
    return profile;
  }

  private applyProfile(profile: HostProfile): void {
    this.hostId = profile.id; this.hostName = profile.name;
    this.host = profile.host || '127.0.0.1'; this.portText = profile.port.toString();
    this.username = profile.username; this.authMethod = profile.authMethod; this.credentialId = profile.credentialId;
    this.autoReconnect = profile.autoReconnect;
    this.password = '';
  }

  private leaveTab(): void {
    this.showTerminalTools = false;
    this.searchText = '';
    const active = this.workspace?.active();
    if (active) { active.profile = this.currentProfile(); active.imeMode = this.imeMode; active.symbols = this.symbolLayer; }
    ++this.connectRequest;
    this.preparingConnection = false;
    this.password = '';
    this.cancelPasteRequest();
    this.clearAuthentication();
  }

  private newTab(): void {
    if (this.tabs.length >= 4) { this.showToast('最多打开四个会话标签'); return; }
    this.leaveTab();
    this.workspace?.create();
  }

  private selectTab(id: string): void {
    if (id === this.activeTabId) return;
    this.leaveTab();
    this.workspace?.select(id);
  }

  private closeTab(id: string): void {
    const workspace = this.workspace, generation = this.pageGeneration;
    AlertDialog.show({ title: '关闭会话', message: '关闭此标签并丢弃尚未发送的输入？',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '关闭会话', action: (): void => {
        if (!this.pageActive || generation !== this.pageGeneration || workspace !== this.workspace) return;
        if (id === this.activeTabId) this.leaveTab();
        this.workspace?.close(id);
        if (this.tabs.length === 0) this.workspace?.create();
      } } });
  }

  private updateWindowGeometry(): void {
    const request = ++this.windowGeometryRequest;
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.postureEngine.updateWindowGeometry(0, -1, false, false);
      return;
    }
    window.getLastWindow(context)
      .then((currentWindow: window.Window): void => {
        if (request !== this.windowGeometryRequest) {
          return;
        }
        const rect = currentWindow.getGlobalRect();
        const properties = currentWindow.getWindowProperties();
        const fullScreen = currentWindow.getWindowStatus() === window.WindowStatusType.FULL_SCREEN;
        this.postureEngine.updateWindowGeometry(rect.top ?? 0, properties.displayId ?? -1, fullScreen, true);
      })
      .catch((): void => {
        if (request === this.windowGeometryRequest) {
          this.postureEngine.updateWindowGeometry(0, -1, false, false);
        }
      });
  }

  private currentLayout(): LayoutResult {
    return LayoutCoordinator.compute(this.rootWidth, this.rootHeight, this.rootGlobalY, this.posture,
      this.showKeyboard, this.imeMode);
  }

  private requestPasteAuthorization(): void {
    if (this.snapshot.inputEnabled) {
      this.pendingPaste = new PasteRequestContext(this.session.getSessionId(),
        this.session.getConnectionEpoch(), this.session.input.getInputEpoch());
      this.showPasteAuthorization = true;
    }
  }

  private handleAction(action: string): void {
    if (action === 'symbols') {
      this.symbolLayer = !this.symbolLayer;
    } else if (action === 'ime') {
      this.imeMode = !this.imeMode;
      this.session.setImeMode(this.imeMode);
    } else if (action === 'paste') {
      this.requestPasteAuthorization();
    } else if (action === 'copy') {
      this.backend.send({ type: 'copy' });
    }
  }

  private cycleLayout(): void {
    if (this.posture.preference === LayoutPreference.AUTO) {
      this.postureEngine.setPreference(LayoutPreference.LAPTOP);
    } else if (this.posture.preference === LayoutPreference.LAPTOP) {
      this.postureEngine.setPreference(LayoutPreference.NORMAL);
    } else {
      this.postureEngine.setPreference(LayoutPreference.AUTO);
    }
    this.savePreferences();
  }

  private async loadSettings(): Promise<void> {
    const generation = this.pageGeneration;
    const context = this.getUIContext().getHostContext();
    if (context === undefined) return;
    try {
      const repository = new HostRepository(await PreferencesStore.open(context, 'hterminal-settings'));
      await repository.load();
      if (!this.pageActive || generation !== this.pageGeneration) return;
      this.repository = repository;
      this.hosts = repository.list();
      const saved = repository.preferences();
      this.keyboardMode = saved.keyboardMode === 'full' ? KeyboardLayoutMode.FULL : KeyboardLayoutMode.COMPACT;
      this.showKeyboard = saved.showKeyboard;
      this.fontSize = saved.fontSize;
      this.tabs.forEach((tab: SessionTab): void => { tab.backend.setFontSize(this.fontSize); });
      this.postureEngine.setPreference(saved.layout === 'laptop' ? LayoutPreference.LAPTOP :
        saved.layout === 'normal' ? LayoutPreference.NORMAL : LayoutPreference.AUTO);
      this.settingsReady = true;
      try {
        const vault = new CredentialVault(await PreferencesStore.open(context, 'hterminal-credentials'), new HuksCredentialCipher());
        await vault.load();
        if (!this.pageActive || generation !== this.pageGeneration) return;
        this.vault = vault;
        this.credentials = vault.list();
      } catch (_error) { this.showToast('无法读取受保护凭据'); }
    } catch (_error) { this.showToast('无法读取主机配置，原有配置不会被覆盖'); }
  }

  private savePreferences(): void {
    if (!this.settingsReady || this.repository === null) return;
    const saved = new UserPreferences();
    saved.keyboardMode = this.keyboardMode;
    saved.layout = this.posture.preference;
    saved.showKeyboard = this.showKeyboard;
    saved.fontSize = this.fontSize;
    this.repository.savePreferences(saved).catch((): void => { this.showToast('偏好保存失败'); });
  }

  private async saveHost(): Promise<void> {
    if (this.repository === null) return;
    const tabId = this.activeTabId, generation = this.pageGeneration;
    const profile = new HostProfile();
    profile.id = this.hostId;
    profile.name = this.hostName;
    profile.host = this.host;
    profile.port = Number(this.portText);
    profile.username = this.username;
    profile.authMethod = this.authMethod;
    profile.credentialId = this.credentialId;
    profile.autoReconnect = this.autoReconnect;
    try {
      const id = await this.repository.saveHost(profile);
      if (!this.pageActive || generation !== this.pageGeneration) return;
      this.hosts = this.repository.list();
      if (tabId === this.activeTabId && JSON.stringify(this.currentProfile()) === JSON.stringify(profile)) this.hostId = id;
      this.showToast('主机已保存');
    } catch (_error) { this.showToast('保存失败，请检查主机配置和存储状态'); }
  }

  private useHost(profile: HostProfile): void {
    if (this.snapshot.state === ConnectionState.OPEN) {
      if (this.tabs.length >= 4) { this.showToast('请先关闭一个标签'); return; }
      this.newTab();
    }
    this.hostId = profile.id;
    this.hostName = profile.name;
    this.host = profile.host;
    this.portText = profile.port.toString();
    this.username = profile.username;
    this.authMethod = profile.authMethod;
    this.credentialId = profile.credentialId;
    this.autoReconnect = profile.autoReconnect;
    this.password = '';
    const active = this.workspace?.active();
    if (active) active.profile = profile;
    this.showHosts = false;
    this.showConnect = true;
  }

  private deleteHost(profile: HostProfile): void {
    AlertDialog.show({ title: '删除主机配置', message: `删除 ${profile.name}？已信任的指纹保留。`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => {
        this.repository?.deleteHost(profile.id).then((): void => {
          this.hosts = this.repository?.list() ?? [];
          if (this.hostId === profile.id) this.hostId = '';
        }).catch((): void => { this.showToast('删除主机配置失败'); });
      } }
    });
  }

  private async connect(automatic: boolean = false, confirmed: boolean = false): Promise<void> {
    if (this.forgettingTrust) return;
    if (!automatic) {
      this.session.cancelReconnect();
      if (!confirmed && this.session.getConnectionEpoch() > 0) {
        const target = this.session, epoch = target.getConnectionEpoch(), request = ++this.connectRequest;
        AlertDialog.show({ title: '重新连接将重置终端',
          message: '新连接会重置本地屏幕与终端模式，不恢复旧 Shell，也不会重放旧命令。可先返回查看断线前输出；远端工作区可通过 tmux 恢复。',
          primaryButton: { value: '返回查看', action: (): void => {} },
          secondaryButton: { value: '重置终端并连接', action: (): void => {
            if (this.pageActive && request === this.connectRequest && target === this.session && epoch === target.getConnectionEpoch()) this.connect(false, true);
          } } });
        return;
      }
    }
    const port = Number(this.portText);
    const request = ++this.connectRequest;
    const session = this.session;
    const epoch = session.getConnectionEpoch();
    const host = this.host, username = this.username, password = this.password, method = this.authMethod;
    this.preparingConnection = true;
    const tab = this.workspace?.active();
    if (tab) { tab.profile = this.currentProfile(); tab.identity = new HostKeyInfo(); }
    this.identity = new HostKeyInfo();
    let bytes = new Uint8Array(0);
    try {
      if (method.startsWith('publickey')) {
        if (this.vault === null || this.credentialId.length === 0) { this.showToast('请先导入并选择 Ed25519 私钥'); return; }
        bytes = await this.vault.read(this.credentialId);
      }
      if (request !== this.connectRequest || session.getConnectionEpoch() !== epoch) return;
      session.setAutoReconnect(this.autoReconnect);
      const started = session.connect(host, port, username, password, method,
        bytes.length > 0 ? ByteCodec.decodeText(ByteCodec.encodeBytes(bytes)) : '', automatic);
      if (started) {
        this.imeMode = false;
        this.cancelPasteRequest();
      }
    } catch (_error) { session.cancelReconnect(); this.showToast('凭据无法解锁，请检查密钥和设备状态'); }
    finally {
      bytes.fill(0);
      if (request === this.connectRequest) { this.preparingConnection = false; this.password = ''; }
    }
  }

  private cancelConnectionForm(): void {
    ++this.connectRequest;
    this.preparingConnection = false;
    this.password = '';
    this.session.cancelReconnect();
    if ([ConnectionState.CONNECTING, ConnectionState.VERIFYING_HOST, ConnectionState.AUTHENTICATING].includes(this.snapshot.state)) {
      this.session.disconnect();
    }
    this.showConnect = false;
  }

  private async importKey(): Promise<void> {
    if (this.vault === null || this.importingKey) return;
    this.importingKey = true;
    this.importStatus = '选择文件…';
    const passphrase = this.password;
    this.password = '';
    const generation = this.pageGeneration;
    const tabId = this.activeTabId, name = this.hostName || 'Ed25519 私钥';
    let data = new Uint8Array(0);
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) return;
      const selected = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 1 });
      if (selected.length === 0 || !this.pageActive || generation !== this.pageGeneration || tabId !== this.activeTabId) return;
      this.importStatus = '验证私钥…';
      const file = fileIo.openSync(selected[0], fileIo.OpenMode.READ_ONLY);
      try {
        const size = fileIo.statSync(file.fd).size;
        if (size <= 0 || size > 65536) throw new Error('密钥文件大小不受支持');
        const buffer = new ArrayBuffer(size);
        data = new Uint8Array(buffer);
        const count = fileIo.readSync(file.fd, buffer);
        if (count !== size) throw new Error('读取密钥失败');
      } finally { fileIo.closeSync(file); }
      const info = await native.inspectPrivateKey(ByteCodec.decodeText(ByteCodec.encodeBytes(data)), passphrase);
      if (!this.pageActive || generation !== this.pageGeneration || tabId !== this.activeTabId) return;
      this.importStatus = '加密保存…';
      const id = await this.vault.save(name, data, info);
      if (!this.pageActive || generation !== this.pageGeneration) return;
      if (tabId === this.activeTabId) this.credentialId = id;
      this.credentials = this.vault.list();
      this.showToast('私钥已验证并加密保存；连接时仍需提供原文件口令');
    } catch (error) {
      console.error(`Key import failed phase=${this.importStatus} code=${(error as BusinessError).code ?? 0}`);
      this.showToast('导入失败：请选择有效的 Ed25519 私钥并填写正确口令');
    }
    finally { data.fill(0); this.importingKey = false; }
  }

  private clearAuthentication(): void {
    this.authAnswers.fill('');
    this.authAnswers = [];
    this.authChallenge = null;
    this.authTarget = null;
  }

  private submitAuthentication(): void {
    const target = this.authTarget, challenge = this.authChallenge;
    if (target === null || challenge === null || target.getConnectionEpoch() !== this.authEpoch) {
      this.clearAuthentication(); return;
    }
    try { target.answerAuthentication(challenge.requestId ?? 0, this.authAnswers); }
    catch (_error) { target.disconnect(); this.showToast('无法提交认证回答，请重新连接'); }
    finally { this.clearAuthentication(); }
  }

  private deleteCredential(credential: EncryptedCredential): void {
    if (this.credentialInUse(credential.id)) {
      this.showToast('请先断开使用此凭据的会话，并更新主机配置'); return;
    }
    const generation = this.pageGeneration, vault = this.vault;
    AlertDialog.show({ title: '删除凭据', message: `删除 ${credential.name} 的本地加密副本及保护密钥？原文件保留。`,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除凭据', action: (): void => {
        if (!this.pageActive || generation !== this.pageGeneration || vault !== this.vault) return;
        if (this.credentialInUse(credential.id)) { this.showToast('请先断开使用此凭据的会话，并更新主机配置'); return; }
        vault?.remove(credential.id).then((): void => {
          if (!this.pageActive || generation !== this.pageGeneration || vault !== this.vault) return;
          this.credentials = vault?.list() ?? [];
          if (this.credentialId === credential.id) this.credentialId = '';
        }).catch((): void => { this.showToast('凭据删除失败，请重试'); });
      } } });
  }

  private credentialInUse(id: string): boolean {
    return this.hosts.some((host: HostProfile): boolean => host.credentialId === id &&
      host.authMethod.startsWith('publickey')) || this.tabs.some((tab: SessionTab): boolean =>
      tab.profile.credentialId === id && (tab.snapshot.retrying || [ConnectionState.CONNECTING, ConnectionState.VERIFYING_HOST,
        ConnectionState.AUTHENTICATING, ConnectionState.OPEN].includes(tab.snapshot.state))) || this.preparingConnection;
  }

  private async showTrustRecord(): Promise<void> {
    const host = this.host.trim(), port = Number(this.portText);
    const filesDir = this.getUIContext().getHostContext()?.filesDir ?? '';
    if (this.forgettingTrust || this.preparingConnection || this.tabs.some((tab: SessionTab): boolean =>
      tab.session.isConnectedTo(host, port))) {
      this.showToast('请先断开此主机的所有连接'); return;
    }
    this.forgettingTrust = true;
    try {
      const known = await native.inspectKnownHost(filesDir, host, port);
      AlertDialog.show({ title: '已信任的主机指纹',
        message: `${host}:${port}\n${known.fingerprint}\n\n清除后，下次连接必须重新核实服务器指纹。`,
        autoCancel: true, cancel: (): void => { this.forgettingTrust = false; },
        primaryButton: { value: '返回', action: (): void => { this.forgettingTrust = false; } },
        secondaryButton: { value: '清除此指纹', action: (): void => {
          native.forgetKnownHost(filesDir, host, port, known.fingerprint).then((): void => {
            this.showToast('指纹记录已清除，请重新核实后连接');
            this.identity = new HostKeyInfo();
          }).catch((): void => { this.showToast('指纹记录已变化或无法清除'); })
            .finally((): void => { this.forgettingTrust = false; });
        } }
      });
    } catch (_error) { this.forgettingTrust = false; this.showToast('没有可用的指纹记录'); }
  }

  private showHostKeyDialog(info: HostKeyInfo): void {
    const session = this.session;
    const epoch = session.getConnectionEpoch();
    AlertDialog.show({
      title: '验证主机密钥',
      message: `${info.host}:${info.port}\n${info.keyType}\n${info.fingerprint}\n\n仅在确认指纹与服务器一致时继续。`,
      autoCancel: false,
      primaryButton: {
        value: '拒绝',
        action: (): void => {
          if (session.getConnectionEpoch() === epoch) session.trust(false);
        }
      },
      secondaryButton: {
        value: '信任并继续',
        action: (): void => {
          if (session.getConnectionEpoch() === epoch) session.trust(true);
        }
      }
    });
  }

  private copyText(text: string): void {
    if (text.length === 0) {
      this.showToast('当前没有选择文本');
      return;
    }
    pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text))
      .then((): void => {
        this.showToast('已复制');
      })
      .catch((error: BusinessError): void => {
        this.showToast(`复制失败：${error.message}`);
      });
  }

  private cancelPasteRequest(): void {
    this.pendingPaste = null;
    this.showPasteAuthorization = false;
  }

  private isPasteContextCurrent(request: PasteRequestContext): boolean {
    return this.snapshot.inputEnabled && this.pendingPaste === request &&
      request.sessionId === this.session.getSessionId() &&
      request.connectionEpoch === this.session.getConnectionEpoch() &&
      request.inputEpoch === this.session.input.getInputEpoch();
  }

  private submitPaste(text: string, request: PasteRequestContext): void {
    if (this.isPasteContextCurrent(request)) {
      this.cancelPasteRequest();
      this.session.paste(text, request.sessionId, request.connectionEpoch, request.inputEpoch);
    }
  }

  private readPasteboard(): void {
    const request = this.pendingPaste;
    if (request === null || !this.isPasteContextCurrent(request)) {
      return;
    }
    pasteboard.getSystemPasteboard().getData()
      .then((data: pasteboard.PasteData): void => {
        if (!this.isPasteContextCurrent(request)) {
          return;
        }
        const text = data.getPrimaryText();
        if (text.length === 0) {
          this.showToast('剪贴板没有文本');
          return;
        }
        const bytes = ByteCodec.byteLength(text);
        if (bytes > 1024 * 1024) {
          this.showToast('粘贴内容超过 1MiB，已拒绝');
          return;
        }
        if (text.includes('\r') || text.includes('\n') || bytes > 4096) {
          const preview = text.length > 160 ? `${text.substring(0, 160)}…` : text;
          AlertDialog.show({
            title: '确认粘贴',
            message: `${bytes} 字节，可能包含多行命令。\n\n${preview}`,
            autoCancel: true,
            cancel: (): void => {
              if (this.pendingPaste === request) {
                this.cancelPasteRequest();
              }
            },
            primaryButton: {
              value: '取消',
              action: (): void => {
                if (this.pendingPaste === request) {
                  this.cancelPasteRequest();
                }
              }
            },
            secondaryButton: {
              value: '粘贴',
              action: (): void => {
                this.submitPaste(text, request);
              }
            }
          });
        } else {
          this.submitPaste(text, request);
        }
      })
      .catch((error: BusinessError): void => {
        if (this.isPasteContextCurrent(request)) {
          this.cancelPasteRequest();
          this.showToast(`无法读取剪贴板：${error.message}`);
        }
      });
  }

  private showToast(message: string): void {
    if (!this.pageActive) return;
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  @Builder
  private topBar() {
    Row() {
      Text('H-Terminal')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#E5EDF5')
      Text(this.snapshot.suspended ? '输入已暂停' : this.snapshot.checking ? '检查连接' : this.snapshot.state)
        .fontSize(11)
        .fontColor(this.snapshot.inputEnabled ? '#63E6BE' : '#9AA9B8')
        .margin({ left: 8 })
      Text(this.posture.message)
        .fontSize(10)
        .fontColor('#7F8D9B')
        .margin({ left: 8 })
        .maxLines(1)
      Blank()
      Button('主机')
        .fontSize(11)
        .height(28)
        .enabled(this.settingsReady)
        .onClick((): void => { this.showHosts = true; })
      Button('凭据').fontSize(11).height(28).onClick((): void => { this.showCredentials = true; })
      Button('终端').id('terminal-tools').fontSize(11).height(28).onClick((): void => {
        this.session.setImeMode(false); this.imeMode = false; this.cancelPasteRequest(); this.showTerminalTools = true;
      })
      if (this.snapshot.retrying) {
        Button('停止重连').id('stop-reconnect').fontSize(11).height(28)
          .onClick((): void => { this.session.cancelReconnect(); })
      }
      if (this.identity.fingerprint.length > 0) {
        Button('指纹').fontSize(11).height(28).onClick((): void => {
          AlertDialog.show({ title: '主机指纹',
            message: `${this.identity.host}:${this.identity.port}\n${this.identity.keyType}\n${this.identity.fingerprint}`,
            confirm: { value: '关闭', action: (): void => {} } });
        })
      }
      if (this.snapshot.pasting) {
        Button('停止粘贴')
          .fontSize(11)
          .height(28)
          .onClick((): void => { this.session.stopPaste(false); })
      }
      Button(this.imeMode ? '英文' : '中文')
        .fontSize(11)
        .height(28)
        .margin({ left: 4 })
        .onClick((): void => {
          this.handleAction('ime');
        })
      Button('布局')
        .fontSize(11)
        .height(28)
        .margin({ left: 4 })
        .onClick((): void => {
          this.cycleLayout();
        })
      Button(this.keyboardMode === KeyboardLayoutMode.FULL ? '紧凑' : '完整')
        .fontSize(11)
        .height(28)
        .margin({ left: 4 })
        .onClick((): void => {
          this.keyboardMode = this.keyboardMode === KeyboardLayoutMode.FULL
            ? KeyboardLayoutMode.COMPACT : KeyboardLayoutMode.FULL;
          this.symbolLayer = false;
          this.savePreferences();
        })
      Button(this.showKeyboard ? '隐藏键盘' : '显示键盘')
        .fontSize(11)
        .height(28)
        .margin({ left: 4 })
        .onClick((): void => {
          this.showKeyboard = !this.showKeyboard;
          this.savePreferences();
          if (!this.showKeyboard && this.imeMode) {
            this.imeMode = false;
            this.session.setImeMode(false);
          }
        })
      Button(this.snapshot.state === ConnectionState.OPEN ? '断开' : '连接')
        .fontSize(11)
        .height(28)
        .margin({ left: 4 })
        .onClick((): void => {
          if (this.snapshot.state === ConnectionState.OPEN) {
            this.session.disconnect();
            this.showConnect = true;
          } else {
            this.showConnect = true;
          }
        })
    }
    .width('100%')
    .height(38)
    .padding({ left: 8, right: 4 })
    .backgroundColor('#17212C')
  }

  @Builder
  private pasteAuthorizationOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Text('允许读取一次剪贴板内容')
          .fontSize(16)
          .fontColor('#E5EDF5')
          .margin({ bottom: 16 })
        Row() {
          PasteButton()
            .onClick((_event: ClickEvent, result: PasteButtonOnClickResult): void => {
              this.showPasteAuthorization = false;
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.readPasteboard();
              } else {
                this.cancelPasteRequest();
                this.showToast('未获得剪贴板授权');
              }
            })
        }
        .margin({ bottom: 12 })
        Button('取消')
          .onClick((): void => {
            this.cancelPasteRequest();
          })
      }
      .width('80%')
      .constraintSize({ maxWidth: 360 })
      .padding(20)
      .borderRadius(12)
      .backgroundColor('#1C2835')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#990B1016')
  }

  @Builder
  private connectOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Scroll() {
      Column() {
        Text('连接 SSH 服务器')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E5EDF5')
          .margin({ bottom: 14 })
        TextInput({ placeholder: '主机地址', text: this.host })
          .id('host-address')
          .height(42)
          .margin({ bottom: 8 })
          .onChange((value: string): void => {
            this.host = value;
          })
        Row() {
          TextInput({ placeholder: '端口', text: this.portText })
            .id('host-port')
            .type(InputType.Number)
            .layoutWeight(1)
            .height(42)
            .onChange((value: string): void => {
              this.portText = value;
            })
          TextInput({ placeholder: '用户名', text: this.username })
            .id('host-username')
            .layoutWeight(2)
            .height(42)
            .margin({ left: 8 })
            .onChange((value: string): void => {
              this.username = value;
            })
        }
        .width('100%')
        .margin({ bottom: 8 })
        TextInput({ placeholder: '密码（仅本次连接使用）', text: this.password })
          .id('auth-secret')
          .type(InputType.Password)
          .height(42)
          .margin({ bottom: 12 })
          .onChange((value: string): void => {
            this.password = value;
          })
        Select([{ value: '密码' }, { value: 'Ed25519 私钥' }, { value: '交互式认证' },
          { value: '密码 + 交互式认证' }, { value: '私钥 + 交互式认证' }])
          .id('auth-method')
          .value(this.authMethod === 'password' ? '密码' : this.authMethod === 'publickey' ? 'Ed25519 私钥' :
            this.authMethod === 'keyboard-interactive' ? '交互式认证' :
            this.authMethod === 'password+keyboard-interactive' ? '密码 + 交互式认证' : '私钥 + 交互式认证')
          .selected(['password', 'publickey', 'keyboard-interactive', 'password+keyboard-interactive',
            'publickey+keyboard-interactive'].indexOf(this.authMethod))
          .onSelect((index: number): void => {
            const methods: AuthMethod[] = ['password', 'publickey', 'keyboard-interactive',
              'password+keyboard-interactive', 'publickey+keyboard-interactive'];
            this.authMethod = methods[index];
            this.password = '';
          })
        if (this.authMethod.startsWith('publickey')) {
          Text('密码框用于私钥文件口令；导入文件由设备密钥加密保护。').fontSize(11).fontColor('#9AA9B8')
          Select(this.credentials.map((item: EncryptedCredential): SelectOption => ({ value: item.name })))
            .id('credential-select')
            .value(this.credentials.find((item: EncryptedCredential): boolean => item.id === this.credentialId)?.name ?? '选择凭据')
            .selected(this.credentials.findIndex((item: EncryptedCredential): boolean => item.id === this.credentialId))
            .onSelect((index: number): void => {
              if (index >= 0 && index < this.credentials.length) this.credentialId = this.credentials[index].id;
            })
          Button(this.importingKey ? this.importStatus : '导入 Ed25519 私钥')
            .id('credential-import')
            .enabled(!this.importingKey && this.vault !== null).onClick((): void => { this.importKey(); })
        }
        TextInput({ placeholder: '主机名称（可选）', text: this.hostName })
          .id('profile-name').maxLength(64)
          .height(36)
          .margin({ bottom: 8 })
          .onChange((value: string): void => { this.hostName = value; })
        Row({ space: 12 }) {
          Text('断线自动重连').fontSize(13).fontColor('#E5EDF5')
          Toggle({ type: ToggleType.Switch, isOn: this.autoReconnect }).id('auto-reconnect')
            .onChange((enabled: boolean): void => { this.autoReconnect = enabled; this.session.setAutoReconnect(enabled); })
        }.margin({ bottom: 8 })
        if (this.autoReconnect) {
          Text('只重试网络故障，最多 5 次。新连接重置屏幕，需重新认证，不重放命令。').fontSize(11).fontColor('#9AA9B8')
        }
        Button('保存主机')
          .id('save-host')
          .height(32)
          .enabled(this.settingsReady)
          .margin({ bottom: 8 })
          .onClick((): void => { this.saveHost(); })
        Button(this.forgettingTrust ? '正在处理指纹…' : '信任记录')
          .id('trust-record')
          .height(30).enabled(!this.forgettingTrust).onClick((): void => { this.showTrustRecord(); })
        Text(this.snapshot.terminalReady || this.snapshot.state === ConnectionState.FAILED
          ? this.snapshot.message : '正在初始化终端…')
          .fontSize(12)
          .fontColor('#9AA9B8')
          .maxLines(3)
          .margin({ bottom: 12 })
        Row() {
          Button(this.snapshot.state === ConnectionState.CONNECTING ||
            this.snapshot.state === ConnectionState.VERIFYING_HOST ||
            this.snapshot.state === ConnectionState.AUTHENTICATING ? '取消' : '关闭')
            .id('connect-close')
            .layoutWeight(1)
            .onClick((): void => {
              this.cancelConnectionForm();
            })
          Button(!this.snapshot.terminalReady && this.snapshot.state === ConnectionState.FAILED
            ? '重新加载终端' : '连接')
            .id('connect-submit')
            .layoutWeight(1)
            .margin({ left: 10 })
            .enabled(!this.preparingConnection && !this.forgettingTrust &&
              (this.snapshot.terminalReady || this.snapshot.state === ConnectionState.FAILED))
            .onClick((): void => {
              if (!this.snapshot.terminalReady) {
                this.password = '';
                this.imeMode = false;
                this.cancelPasteRequest();
                this.session.recoverTerminal();
              } else {
                this.connect();
              }
            })
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: 520 })
      .padding(20)
      .borderRadius(12)
      .backgroundColor('#1C2835')
      }.id('connect-form').width('88%')
        .constraintSize({ maxWidth: 520, maxHeight: Math.max(180, this.rootHeight - 24) })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#990B1016')
  }

  build() {
    Column() {
      this.topBar()
      this.tabBar()
      Stack() {
        ForEach(this.tabs, (tab: SessionTab) => {
          TerminalView({
          backend: tab.backend,
          onBridgeMessage: (json: string): void => {
            tab.session.handleTerminalMessage(json);
          },
          onFailure: (message: string): void => {
            tab.session.handleRendererFailure(message);
          }
        })
          .id(`terminal-${tab.id}`)
          .width(this.currentLayout().terminalWidth)
          .height(this.currentLayout().terminalHeight)
          .onAreaChange((_oldValue: Area, _newValue: Area): void => {
            if (this.activeTabId !== tab.id) return;
            if (this.fitTimer >= 0) {
              clearTimeout(this.fitTimer);
            }
            this.fitTimer = setTimeout((): void => {
              if (this.activeTabId === tab.id) tab.backend.fit();
            }, 100);
          })
          .position({ x: 0, y: 0 })
          .visibility(this.activeTabId === tab.id ? Visibility.Visible : Visibility.Hidden)
        }, (tab: SessionTab): string => tab.id)
        if (this.currentLayout().keyboardHeight > 0) {
          LaptopKeyboard({
            mode: this.keyboardMode,
            symbols: this.symbolLayer,
            inputEnabled: this.snapshot.inputEnabled,
            modifiers: this.modifiers,
            onKey: (definition: KeyDefinition): void => {
              this.session.routeKey(definition);
            },
            onPress: (definition: KeyDefinition, pointer: number): KeyContact | null => {
              return this.session.keyboard.press(definition, pointer);
            }
          })
            .width(this.currentLayout().keyboardWidth)
            .height(this.currentLayout().keyboardHeight)
            .position({ x: 0, y: this.currentLayout().keyboardY })
        }
        if (this.showPasteAuthorization) {
          this.pasteAuthorizationOverlay()
        }
        if (this.showConnect) {
          this.connectOverlay()
        }
        if (this.showHosts) {
          this.hostsOverlay()
        }
        if (this.showCredentials) {
          this.credentialsOverlay()
        }
        if (this.showTerminalTools) {
          this.terminalToolsOverlay()
        }
        if (this.authChallenge !== null) {
          this.authenticationOverlay()
        }
      }
      .layoutWeight(1)
      .width('100%')
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        this.rootWidth = Number(newValue.width);
        this.rootHeight = Number(newValue.height);
        this.rootGlobalY = Number(newValue.globalPosition.y);
        this.postureEngine.notifyWindowChanged();
        this.updateWindowGeometry();
        if (this.fitTimer >= 0) {
          clearTimeout(this.fitTimer);
        }
        this.fitTimer = setTimeout((): void => {
          this.backend.fit();
        }, 100);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1016')
  }

  @Builder
  private tabBar() {
    Scroll() {
      Row() {
        ForEach(this.tabs, (tab: SessionTab) => {
          Button() {
            Text(`${tab.profile.name || tab.profile.host || '新会话'} · ${tab.snapshot.suspended ? '暂停' :
              tab.snapshot.checking ? '检查连接' : tab.snapshot.state}`)
              .fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width(150).height(28).backgroundColor(this.activeTabId === tab.id ? '#376F65' : '#263442')
            .id(`tab-${tab.id}`)
            .accessibilityText(`切换 ${tab.id}`).onClick((): void => { this.selectTab(tab.id); })
          Button('×').width(26).height(28).margin({ left: 2, right: 6 })
            .id(`close-${tab.id}`)
            .accessibilityText(`关闭 ${tab.id}`).onClick((): void => { this.closeTab(tab.id); })
        }, (tab: SessionTab): string => `${tab.id}-${tab.snapshot.state}-${tab.snapshot.suspended}-${tab.snapshot.checking}-${tab.profile.name}-${tab.profile.host}`)
        Button('+').width(32).height(28).accessibilityText('新建会话')
          .id('new-session')
          .onClick((): void => { this.newTab(); })
      }.padding({ left: 4, right: 4 })
    }.width('100%').height(34).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      .backgroundColor('#111821')
  }

  @Builder
  private hostsOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Text('已存主机').fontSize(20).fontColor('#E5EDF5').margin({ bottom: 12 })
        Scroll() {
          Column() {
            ForEach(this.hosts, (profile: HostProfile) => {
              Row() {
                Button(`${profile.name} · ${profile.host}:${profile.port}`)
                  .id(`host-${profile.id}`)
                  .layoutWeight(1)
                  .onClick((): void => { this.useHost(profile); })
                Button('删除').id(`delete-${profile.id}`).margin({ left: 8 }).onClick((): void => { this.deleteHost(profile); })
              }.width('100%').margin({ bottom: 8 })
            }, (profile: HostProfile): string => `${profile.id}-${profile.name}-${profile.host}-${profile.port}`)
          }.width('100%')
        }.constraintSize({ maxHeight: 260 }).width('100%')
        Row() {
          Button('新建主机').onClick((): void => { this.useHost(new HostProfile()); })
          Button('返回').margin({ left: 10 }).onClick((): void => { this.showHosts = false; })
        }.margin({ top: 12 })
      }.padding(20).width('88%').constraintSize({ maxWidth: 560 }).backgroundColor('#1C2835').borderRadius(12)
    }.width('100%').height('100%').backgroundColor('#990B1016')
  }

  @Builder
  private terminalToolsOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Scroll() {
        Column({ space: 12 }) {
          Text('终端工具').fontSize(20).fontColor('#E5EDF5')
          Row({ space: 12 }) {
            Button('A−').id('font-smaller').enabled(this.fontSize > 10).onClick((): void => { this.changeFontSize(-1); })
            Text(`字号 ${this.fontSize}`).id('font-value').fontColor('#E5EDF5')
            Button('A+').id('font-larger').enabled(this.fontSize < 28).onClick((): void => { this.changeFontSize(1); })
          }
          TextInput({ placeholder: '搜索当前会话输出', text: this.searchText }).id('terminal-search')
            .maxLength(256).onChange((value: string): void => { this.searchText = value; })
          Row({ space: 12 }) {
            Button('上一个').id('search-previous').enabled(!this.snapshot.selecting)
              .onClick((): void => { this.backend.search(this.searchText, true); })
            Button('下一个').id('search-next').enabled(!this.snapshot.selecting)
              .onClick((): void => { this.backend.search(this.searchText, false); })
            Button('复制选区').onClick((): void => { this.backend.send({ type: 'copy' }); })
          }
          Button(this.snapshot.selecting ? '返回实时终端' : '本地选择（快照）').id('local-selection')
            .onClick((): void => { this.session.setLocalSelection(!this.snapshot.selecting); this.showTerminalTools = false; })
          Text('本地选择显示最近输出的只读快照；返回实时终端后继续输入。').fontSize(12).fontColor('#9AA9B8')
          Button('tmux 使用示例').onClick((): void => {
            AlertDialog.show({ title: '断线后恢复工作区',
              message: '在服务器运行 tmux new -As work。Ctrl+B 后按 D 可离开；重新连接后再次运行同一命令即可恢复。示例仅复制，由你决定是否执行。',
              primaryButton: { value: '关闭', action: (): void => {} },
              secondaryButton: { value: '复制示例', action: (): void => { this.copyText('tmux new -As work'); } } });
          })
          Button('诊断信息').id('session-diagnostics').onClick((): void => {
            const report = this.session.diagnostics();
            AlertDialog.show({ title: '会话诊断', message: report,
              primaryButton: { value: '关闭诊断', action: (): void => {} },
              secondaryButton: { value: '复制诊断', action: (): void => { this.copyText(report); } } });
          })
          Button('关闭工具').id('terminal-tools-close').onClick((): void => { this.showTerminalTools = false; })
        }.padding(20).width('100%').backgroundColor('#1C2835').borderRadius(12)
      }.width('88%').constraintSize({ maxWidth: 560, maxHeight: Math.max(180, this.rootHeight - 24) })
    }.width('100%').height('100%').backgroundColor('#990B1016')
  }

  private changeFontSize(delta: number): void {
    this.fontSize = Math.max(10, Math.min(28, this.fontSize + delta));
    this.tabs.forEach((tab: SessionTab): void => { tab.backend.setFontSize(this.fontSize); });
    this.savePreferences();
  }

  @Builder
  private authenticationOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Scroll() {
      Column() {
        Text(this.authChallenge?.title || '服务器认证').fontSize(20).fontColor('#E5EDF5')
        Text(this.authChallenge?.instruction ?? '').fontSize(12).fontColor('#9AA9B8').margin({ bottom: 8 })
        Scroll() {
          Column() {
            ForEach(this.authChallenge?.prompts ?? [], (prompt: NativeAuthPrompt, index: number) => {
              Text(prompt.text).fontSize(13).fontColor('#E5EDF5')
              TextInput({ text: this.authAnswers[index], placeholder: '认证回答' })
                .id(`auth-answer-${index}`)
                .type(prompt.echo ? InputType.Normal : InputType.Password)
                .height(40).margin({ bottom: 8 })
                .maxLength(4096)
                .onChange((value: string): void => { this.authAnswers[index] = value; })
            }, (_prompt: NativeAuthPrompt, index: number): string => `${this.authChallenge?.requestId}-${index}`)
          }
        }.constraintSize({ maxHeight: Math.max(60, this.rootHeight - 150) }).width('100%')
        Row() {
          Button('取消认证').id('auth-cancel').onClick((): void => { this.authTarget?.disconnect(); this.clearAuthentication(); })
          Button('提交回答').id('auth-submit').margin({ left: 12 }).onClick((): void => { this.submitAuthentication(); })
        }
      }.padding(20).width('100%').borderRadius(12).backgroundColor('#1C2835')
      }.width('88%').constraintSize({ maxWidth: 520, maxHeight: Math.max(180, this.rootHeight - 24) })
    }.width('100%').height('100%').backgroundColor('#990B1016')
  }

  @Builder
  private credentialsOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Text('受保护的导入凭据').fontSize(20).fontColor('#E5EDF5')
        Text('本地副本使用设备密钥加密；SSH 原私钥仍属于可导入文件。')
          .fontSize(11).fontColor('#9AA9B8').margin({ bottom: 10 })
        Scroll() {
          Column() {
            ForEach(this.credentials, (credential: EncryptedCredential) => {
              Column() {
                Text(credential.name).fontSize(15).fontColor('#E5EDF5')
                Text(credential.fingerprint).fontSize(11).fontColor('#9AA9B8')
                Row() {
                  Button('复制公钥').onClick((): void => { this.copyText(credential.publicKey); })
                  Button('删除凭据').id(`credential-delete-${credential.id}`).margin({ left: 8 })
                    .onClick((): void => { this.deleteCredential(credential); })
                }.margin({ top: 6 })
              }.padding(10).width('100%')
            }, (credential: EncryptedCredential): string => credential.id)
          }.width('100%')
        }.constraintSize({ maxHeight: 260 }).width('100%')
        Button('返回').onClick((): void => { this.showCredentials = false; })
      }.width('88%').constraintSize({ maxWidth: 580 }).padding(20).backgroundColor('#1C2835').borderRadius(12)
    }.width('100%').height('100%').backgroundColor('#990B1016')
  }
}
