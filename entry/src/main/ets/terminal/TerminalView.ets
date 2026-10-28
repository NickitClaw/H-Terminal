import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { TerminalMessage } from './TerminalBackend';
import { XtermBackend } from './XtermBackend';
import { TerminalPagePolicy } from './TerminalPagePolicy';
import { TerminalInbox } from './TerminalInbox';

class TerminalBridgeProxy {
  private handler: (json: string) => void;
  private inbox: TerminalInbox;

  constructor(handler: (json: string) => void, inbox: TerminalInbox) {
    this.handler = handler;
    this.inbox = inbox;
  }

  postMessage(json: string): void {
    this.handler(json);
  }

  takeMessage(): string { return this.inbox.take(); }
}

@Component
export struct TerminalView {
  backend: XtermBackend = new XtermBackend();
  onBridgeMessage: (json: string) => void = (_json: string): void => {};
  onFailure: (message: string) => void = (_message: string): void => {};
  private webController: webview.WebviewController = new webview.WebviewController();
  private inbox: TerminalInbox = new TerminalInbox();
  private draining: boolean = false;
  private inboxEpoch: number = -1;
  private proxy: TerminalBridgeProxy = new TerminalBridgeProxy((json: string): void => {
    this.onBridgeMessage(json);
  }, this.inbox);

  aboutToAppear(): void {
    this.backend.setReloader((): void => {
      this.inbox.clear(); this.draining = false; this.inboxEpoch = this.backend.getBridgeEpoch();
      this.webController.refresh();
    });
    this.backend.setSender((message: TerminalMessage): void => {
      const bridgeEpoch = this.backend.getBridgeEpoch();
      if (bridgeEpoch !== this.inboxEpoch) {
        this.inbox.clear(); this.draining = false; this.inboxEpoch = bridgeEpoch;
      }
      if (!this.inbox.enqueue(JSON.stringify(message))) {
        this.inbox.clear(); this.onFailure('终端消息队列已满'); return;
      }
      this.drainInbox();
    });
  }

  private drainInbox(): void {
    if (this.draining || !this.inbox.pending()) return;
    const epoch = this.inboxEpoch;
    this.draining = true;
    // Keep the evaluated source constant. Per-frame payloads are structured
    // strings pulled through the proxy, so ArkWeb does not compile/cache a
    // different script for every output frame.
    this.webController.runJavaScript('window.HTerminal.drain()')
      .then((result: string): void => {
        if (epoch === this.backend.getBridgeEpoch() && this.inbox.pending() && !(Number(result) > 0)) {
          this.inbox.clear(); this.onFailure('终端消息通道未消费数据');
        }
      })
      .catch((error: BusinessError): void => {
        if (epoch === this.backend.getBridgeEpoch()) {
          this.inbox.clear(); this.onFailure(error.message);
        }
      })
      .finally((): void => {
        if (epoch === this.inboxEpoch) {
          this.draining = false;
          if (this.inbox.pending()) this.drainInbox();
        }
      });
  }

  aboutToDisappear(): void {
    this.backend.markWebNotReady();
    this.inbox.clear(); this.draining = false; this.inboxEpoch = this.backend.getBridgeEpoch();
  }

  build() {
    Web({
      src: $rawfile('terminal/index.html'),
      controller: this.webController
    })
      .javaScriptProxy({
        object: this.proxy,
        name: 'HTerminalBridge',
        methodList: ['postMessage', 'takeMessage'],
        controller: this.webController
      })
      .onPageEnd((event): void => {
        if (TerminalPagePolicy.isDocument(event.url)) this.backend.markWebReady();
      })
      .onLoadIntercept((event): boolean => {
        const url = event.data.getRequestUrl();
        return !TerminalPagePolicy.allows(url, event.data.isMainFrame());
      })
      .onErrorReceive((): void => {
        this.backend.markWebNotReady();
        this.onFailure('终端页面加载失败');
      })
      .onRenderExited((): void => {
        this.backend.markWebNotReady();
        this.onFailure('终端渲染进程已退出');
      })
      .domStorageAccess(true)
      .onlineImageAccess(false)
      .width('100%')
      .height('100%')
  }
}
