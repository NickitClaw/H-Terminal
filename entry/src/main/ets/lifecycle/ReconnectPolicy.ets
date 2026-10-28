// No host names, commands, keys or passwords are held by this scheduler.
export class ReconnectPolicy {
  onRetry: () => void = (): void => {};
  onScheduled: (attempt: number, delay: number) => void = (_attempt: number, _delay: number): void => {};
  private enabled: boolean = false;
  private available: boolean = true;
  private wanted: boolean = false;
  private attempts: number = 0;
  private timer: number = -1;
  private generation: number = 0;
  private random: () => number;
  constructor(random: () => number = (): number => Math.random()) { this.random = random; }
  configure(enabled: boolean): void { this.enabled = enabled; if (!enabled) this.stop(); }
  pending(): boolean { return this.wanted; }
  count(): number { return this.attempts; }
  setAvailable(available: boolean): void {
    if (available === this.available) return;
    this.available = available;
    if (!available) this.cancelTimer(); else this.schedule();
  }
  failed(code: string): void {
    if (!this.enabled || code !== 'network') { this.stop(); return; }
    if (this.attempts >= 5) { this.cancelTimer(); this.wanted = false; return; }
    this.wanted = true;
    this.schedule();
  }
  stop(): void { this.cancelTimer(); this.wanted = false; this.attempts = 0; }
  private cancelTimer(): void {
    ++this.generation;
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
  }
  private schedule(): void {
    if (!this.enabled || !this.available || !this.wanted || this.timer >= 0 || this.attempts >= 5) return;
    const delay = Math.round(1000 * Math.pow(2, this.attempts) * (0.8 + this.random() * 0.4));
    const generation = ++this.generation;
    this.timer = setTimeout((): void => {
      if (generation !== this.generation || !this.available || !this.wanted) return;
      this.timer = -1;
      this.wanted = false;
      ++this.attempts;
      this.onRetry();
    }, delay);
    this.onScheduled(this.attempts + 1, delay);
  }
}
