import native, { NativeEvent } from 'libentry.so';

export class NativeRuntime {
  private static listeners: Map<string, (event: NativeEvent) => void> = new Map();

  static attach(id: string, handler: (event: NativeEvent) => void): void {
    if (NativeRuntime.listeners.has(id)) throw new Error('Duplicate session identity');
    if (NativeRuntime.listeners.size === 0) {
      native.initialize((event: NativeEvent): void => {
        NativeRuntime.listeners.get(event.sessionId)?.(event);
      });
    }
    NativeRuntime.listeners.set(id, handler);
  }

  static detach(id: string): void {
    NativeRuntime.listeners.delete(id);
    if (NativeRuntime.listeners.size === 0) native.dispose();
  }
}
