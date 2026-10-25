import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { TerminalMessage } from './TerminalBackend';
import { XtermBackend } from './XtermBackend';

class TerminalBridgeProxy {
  private handler: (json: string) => void;

  constructor(handler: (json: string) => void) {
    this.handler = handler;
  }

  postMessage(json: string): void {
    this.handler(json);
  }
}

@Component
export struct TerminalView {
  backend: XtermBackend = new XtermBackend();
  onBridgeMessage: (json: string) => void = (_json: string): void => {};
  onFailure: (message: string) => void = (_message: string): void => {};
  private webController: webview.WebviewController = new webview.WebviewController();
  private proxy: TerminalBridgeProxy = new TerminalBridgeProxy((json: string): void => {
    this.onBridgeMessage(json);
  });

  aboutToAppear(): void {
    this.backend.setSender((message: TerminalMessage): void => {
      const payload = JSON.stringify(JSON.stringify(message));
      this.webController.runJavaScript(`window.HTerminal.receive(${payload})`)
        .catch((error: BusinessError): void => {
          this.onFailure(error.message);
        });
    });
  }

  aboutToDisappear(): void {
    this.backend.markWebNotReady();
  }

  build() {
    Web({
      src: $rawfile('terminal/index.html'),
      controller: this.webController
    })
      .javaScriptProxy({
        object: this.proxy,
        name: 'HTerminalBridge',
        methodList: ['postMessage'],
        controller: this.webController
      })
      .onPageEnd((): void => {
        this.backend.markWebReady();
      })
      .onLoadIntercept((event): boolean => {
        const url = event.data.getRequestUrl();
        return url.startsWith('http://') || url.startsWith('https://');
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
