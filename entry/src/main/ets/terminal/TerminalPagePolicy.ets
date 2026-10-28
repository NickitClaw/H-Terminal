// Keep the JavaScript proxy attached exclusively to the bundled terminal.
export class TerminalPagePolicy {
  static isDocument(url: string): boolean {
    return /^resource:\/\/?rawfile\/terminal\/index\.html$/i.test(url);
  }
  static isAsset(url: string): boolean {
    return /^resource:\/\/?rawfile\/terminal\/(terminal\.(js|css)|vendor\/(xterm\.(js|css)|addon-(fit|search)\.js))$/i.test(url);
  }
  static allows(url: string, mainFrame: boolean): boolean {
    return TerminalPagePolicy.isDocument(url) || (!mainFrame && TerminalPagePolicy.isAsset(url));
  }
}
