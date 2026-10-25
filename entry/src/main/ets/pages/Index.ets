import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { HostKeyInfo, ConnectionState, SessionSnapshot } from '../model/SessionModel';
import { TerminalView } from '../terminal/TerminalView';
import { XtermBackend } from '../terminal/XtermBackend';
import { SessionController } from '../terminal/SessionController';
import { InputRouter, ModifierSnapshot } from '../input/InputRouter';
import { KeyDefinition, KeyboardLayoutMode } from '../input/KeyboardModel';
import { LaptopKeyboard } from '../components/LaptopKeyboard';
import { LayoutPreference, PostureEngine, PostureSnapshot } from '../posture/PostureEngine';
import { LayoutCoordinator, LayoutResult } from '../posture/LayoutCoordinator';
import { ByteCodec } from '../util/ByteCodec';

@Entry
@Component
struct Index {
  @State private snapshot: SessionSnapshot = new SessionSnapshot();
  @State private host: string = '127.0.0.1';
  @State private portText: string = '2222';
  @State private username: string = '';
  @State private password: string = '';
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
  private backend: XtermBackend = new XtermBackend();
  private session: SessionController = new SessionController(this.backend);
  private postureEngine: PostureEngine = new PostureEngine();
  private fitTimer: number = -1;
  private pasteSessionId: string = '';
  private pasteConnectionEpoch: number = 0;
  private pasteInputEpoch: number = 0;
  private windowGeometryRequest: number = 0;

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.session.onSnapshot = (snapshot: SessionSnapshot): void => {
      this.snapshot = snapshot;
      if (snapshot.state === ConnectionState.OPEN) {
        this.showConnect = false;
      } else if (snapshot.state === ConnectionState.FAILED) {
        this.showConnect = true;
      }
    };
    this.session.onHostKey = (info: HostKeyInfo): void => {
      this.showHostKeyDialog(info);
    };
    this.session.onCopy = (text: string): void => {
      this.copyText(text);
    };
    this.session.onPasteRequest = (): void => {
      this.requestPasteAuthorization();
    };
    this.session.onAction = (action: string): void => {
      this.handleAction(action);
    };
    this.session.onToast = (message: string): void => {
      this.showToast(message);
    };
    this.session.input.onModifiersChanged = (modifiers: ModifierSnapshot): void => {
      this.modifiers = modifiers;
    };
    this.postureEngine.onChanged = (snapshot: PostureSnapshot): void => {
      this.posture = snapshot;
    };
    this.session.initialize(this.getUIContext().getHostContext()?.filesDir ?? '');
    this.postureEngine.start();
    this.updateWindowGeometry();
  }

  aboutToDisappear(): void {
    this.password = '';
    this.showPasteAuthorization = false;
    this.postureEngine.stop();
    this.session.dispose();
    if (this.fitTimer >= 0) {
      clearTimeout(this.fitTimer);
    }
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
      this.pasteSessionId = this.session.getSessionId();
      this.pasteConnectionEpoch = this.session.getConnectionEpoch();
      this.pasteInputEpoch = this.session.input.getInputEpoch();
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
  }

  private connect(): void {
    const port = Number(this.portText);
    try {
      const started = this.session.connect(this.host, port, this.username, this.password);
      if (started) {
        this.imeMode = false;
        this.showPasteAuthorization = false;
      }
    } finally {
      this.password = '';
    }
  }

  private showHostKeyDialog(info: HostKeyInfo): void {
    AlertDialog.show({
      title: '验证主机密钥',
      message: `${info.host}:${info.port}\n${info.keyType}\n${info.fingerprint}\n\n仅在确认指纹与服务器一致时继续。`,
      autoCancel: false,
      primaryButton: {
        value: '拒绝',
        action: (): void => {
          this.session.trust(false);
        }
      },
      secondaryButton: {
        value: '信任并继续',
        action: (): void => {
          this.session.trust(true);
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

  private isPasteContextCurrent(): boolean {
    return this.snapshot.inputEnabled && this.pasteSessionId === this.session.getSessionId() &&
      this.pasteConnectionEpoch === this.session.getConnectionEpoch() &&
      this.pasteInputEpoch === this.session.input.getInputEpoch();
  }

  private readPasteboard(): void {
    if (!this.isPasteContextCurrent()) {
      return;
    }
    pasteboard.getSystemPasteboard().getData()
      .then((data: pasteboard.PasteData): void => {
        if (!this.isPasteContextCurrent()) {
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
            primaryButton: {
              value: '取消',
              action: (): void => {}
            },
            secondaryButton: {
              value: '粘贴',
              action: (): void => {
                this.session.paste(text, this.pasteSessionId, this.pasteConnectionEpoch, this.pasteInputEpoch);
              }
            }
          });
        } else {
          this.session.paste(text, this.pasteSessionId, this.pasteConnectionEpoch, this.pasteInputEpoch);
        }
      })
      .catch((error: BusinessError): void => {
        this.showToast(`无法读取剪贴板：${error.message}`);
      });
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  @Builder
  private topBar() {
    Row() {
      Text('H-Terminal')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#E5EDF5')
      Text(this.snapshot.state)
        .fontSize(11)
        .fontColor(this.snapshot.state === ConnectionState.OPEN ? '#63E6BE' : '#9AA9B8')
        .margin({ left: 8 })
      Text(this.posture.message)
        .fontSize(10)
        .fontColor('#7F8D9B')
        .margin({ left: 8 })
        .maxLines(1)
      Blank()
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
        })
      Button(this.showKeyboard ? '隐藏键盘' : '显示键盘')
        .fontSize(11)
        .height(28)
        .margin({ left: 4 })
        .onClick((): void => {
          this.showKeyboard = !this.showKeyboard;
          if (!this.showKeyboard && this.imeMode) {
            this.imeMode = false;
            this.session.setImeMode(false);
          }
        })
      Button(this.snapshot.inputEnabled ? '断开' : '连接')
        .fontSize(11)
        .height(28)
        .margin({ left: 4 })
        .onClick((): void => {
          if (this.snapshot.inputEnabled) {
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
                this.showToast('未获得剪贴板授权');
              }
            })
        }
        .margin({ bottom: 12 })
        Button('取消')
          .onClick((): void => {
            this.showPasteAuthorization = false;
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
      Column() {
        Text('连接 SSH 服务器')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E5EDF5')
          .margin({ bottom: 14 })
        TextInput({ placeholder: '主机地址', text: this.host })
          .height(42)
          .margin({ bottom: 8 })
          .onChange((value: string): void => {
            this.host = value;
          })
        Row() {
          TextInput({ placeholder: '端口', text: this.portText })
            .type(InputType.Number)
            .layoutWeight(1)
            .height(42)
            .onChange((value: string): void => {
              this.portText = value;
            })
          TextInput({ placeholder: '用户名', text: this.username })
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
          .type(InputType.Password)
          .height(42)
          .margin({ bottom: 12 })
          .onChange((value: string): void => {
            this.password = value;
          })
        Text(this.snapshot.terminalReady ? this.snapshot.message : '正在初始化终端…')
          .fontSize(12)
          .fontColor('#9AA9B8')
          .maxLines(3)
          .margin({ bottom: 12 })
        Row() {
          Button(this.snapshot.state === ConnectionState.CONNECTING ||
            this.snapshot.state === ConnectionState.VERIFYING_HOST ||
            this.snapshot.state === ConnectionState.AUTHENTICATING ? '取消' : '关闭')
            .layoutWeight(1)
            .onClick((): void => {
              if (this.snapshot.state === ConnectionState.CONNECTING ||
                this.snapshot.state === ConnectionState.VERIFYING_HOST ||
                this.snapshot.state === ConnectionState.AUTHENTICATING) {
                this.session.disconnect();
              }
              this.showConnect = false;
            })
          Button('连接')
            .layoutWeight(1)
            .margin({ left: 10 })
            .enabled(this.snapshot.terminalReady)
            .onClick((): void => {
              this.connect();
            })
        }
        .width('100%')
      }
      .width('88%')
      .constraintSize({ maxWidth: 520 })
      .padding(20)
      .borderRadius(12)
      .backgroundColor('#1C2835')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#990B1016')
  }

  build() {
    Column() {
      this.topBar()
      Stack() {
        TerminalView({
          backend: this.backend,
          onBridgeMessage: (json: string): void => {
            this.session.handleTerminalMessage(json);
          },
          onFailure: (message: string): void => {
            this.session.handleRendererFailure(message);
          }
        })
          .width(this.currentLayout().terminalWidth)
          .height(this.currentLayout().terminalHeight)
          .onAreaChange((_oldValue: Area, _newValue: Area): void => {
            if (this.fitTimer >= 0) {
              clearTimeout(this.fitTimer);
            }
            this.fitTimer = setTimeout((): void => {
              this.backend.fit();
            }, 100);
          })
          .position({ x: 0, y: 0 })
        if (this.currentLayout().keyboardHeight > 0) {
          LaptopKeyboard({
            mode: this.keyboardMode,
            symbols: this.symbolLayer,
            inputEnabled: this.snapshot.inputEnabled,
            modifiers: this.modifiers,
            onKey: (definition: KeyDefinition): void => {
              this.session.routeKey(definition);
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
}
