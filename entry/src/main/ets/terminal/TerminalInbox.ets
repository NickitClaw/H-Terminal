// Only terminal messages pass through this inbox. SSH credentials and native
// APIs are never exposed to the Web JavaScript proxy.
export class TerminalInbox {
  private messages: string[] = [];
  private characters: number = 0;
  enqueue(message: string): boolean {
    if (message.length > 1500000 || this.messages.length >= 64 || this.characters + message.length > 2 * 1024 * 1024) return false;
    this.messages.push(message);
    this.characters += message.length;
    return true;
  }
  take(): string {
    const message = this.messages.shift() ?? '';
    this.characters -= message.length;
    return message;
  }
  pending(): boolean { return this.messages.length > 0; }
  clear(): void { this.messages = []; this.characters = 0; }
}
