import { connection } from '@kit.NetworkKit';

export class NetworkMonitor {
  onChanged: (available: boolean) => void = (_available: boolean): void => {};
  private monitor: connection.NetConnection | null = null;
  private generation: number = 0;
  private netId: number = -1;

  start(): void {
    const generation = ++this.generation;
    try {
      const monitor = connection.createNetConnection();
      this.monitor = monitor;
      monitor.on('netAvailable', (handle: connection.NetHandle): void => {
        if (generation !== this.generation) return;
        if (this.netId >= 0 && this.netId !== handle.netId) this.onChanged(false);
        this.netId = handle.netId;
        this.onChanged(true);
      });
      monitor.on('netLost', (handle: connection.NetHandle): void => {
        if (generation === this.generation && this.netId === handle.netId) {
          this.netId = -1;
          this.onChanged(false);
        }
      });
      monitor.on('netUnavailable', (): void => {
        if (generation === this.generation) { this.netId = -1; this.onChanged(false); }
      });
      monitor.register((): void => {});
    } catch (_error) {
      // Foreground checks remain mandatory if platform monitoring is unavailable.
      this.monitor = null;
    }
  }

  stop(): void {
    ++this.generation;
    try { this.monitor?.unregister((): void => {}); } catch (_error) {}
    this.monitor = null;
    this.netId = -1;
  }
}
