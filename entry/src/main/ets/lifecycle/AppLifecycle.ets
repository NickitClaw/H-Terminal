export class AppLifecycle {
  private static foreground: boolean = true;
  private static listeners: ((foreground: boolean) => void)[] = [];

  static subscribe(listener: (foreground: boolean) => void): void {
    AppLifecycle.listeners.push(listener);
    listener(AppLifecycle.foreground);
  }

  static unsubscribe(listener: (foreground: boolean) => void): void {
    AppLifecycle.listeners = AppLifecycle.listeners.filter((item: (foreground: boolean) => void): boolean =>
      item !== listener);
  }

  static setForeground(foreground: boolean): void {
    AppLifecycle.foreground = foreground;
    AppLifecycle.listeners.forEach((listener: (foreground: boolean) => void): void => listener(foreground));
  }
}
