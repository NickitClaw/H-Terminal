import { InputRouter } from './InputRouter';
import { KeyDefinition } from './KeyboardModel';

class ActiveContact {
  pointer: number;
  definition: KeyDefinition;
  epoch: number;
  used: boolean = false;
  timer: number = -1;
  constructor(pointer: number, definition: KeyDefinition, epoch: number) {
    this.pointer = pointer; this.definition = definition; this.epoch = epoch;
  }
}

// A contact captures its original session and input epoch. A late touch-up
// cannot toggle a modifier or send a key into another tab/connection.
export class KeyContact {
  private owner: KeyboardInteraction;
  private contact: ActiveContact;
  constructor(owner: KeyboardInteraction, contact: ActiveContact) { this.owner = owner; this.contact = contact; }
  release(cancelled: boolean = false): void { this.owner.release(this.contact, cancelled); }
}

export class KeyboardInteraction {
  private contacts: ActiveContact[] = [];
  private input: InputRouter;
  private deliver: (key: KeyDefinition) => void;
  private enabled: () => boolean;
  constructor(input: InputRouter, deliver: (key: KeyDefinition) => void, enabled: () => boolean) {
    this.input = input; this.deliver = deliver; this.enabled = enabled;
    input.onInvalidated = (): void => { this.cancelAll(); };
  }

  press(key: KeyDefinition, pointer: number): KeyContact | null {
    if (!this.enabled() || this.contacts.some((item: ActiveContact): boolean => item.pointer === pointer)) return null;
    const contact = new ActiveContact(pointer, key, this.input.getInputEpoch());
    this.contacts.push(contact);
    if (key.kind === 'modifier' && key.id !== 'caps') {
      this.input.holdModifier(pointer, key.id);
    } else {
      this.contacts.forEach((item: ActiveContact): void => { if (item.definition.kind === 'modifier') item.used = true; });
      this.deliver(key);
      if (['Backspace', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(key.id)) {
        contact.timer = setTimeout((): void => { this.repeat(contact); }, 400);
      }
    }
    return new KeyContact(this, contact);
  }

  release(contact: ActiveContact, cancelled: boolean): void {
    if (!this.contacts.includes(contact)) return;
    this.contacts = this.contacts.filter((item: ActiveContact): boolean => item !== contact);
    if (contact.timer >= 0) clearTimeout(contact.timer);
    this.input.releaseModifier(contact.pointer);
    if (cancelled) { this.cancelAll(); return; }
    if (!cancelled && contact.epoch === this.input.getInputEpoch() && this.enabled() &&
      contact.definition.kind === 'modifier' && contact.definition.id !== 'caps' && !contact.used) {
      this.deliver(contact.definition);
    }
  }

  cancelAll(): void {
    const contacts = this.contacts;
    this.contacts = [];
    contacts.forEach((item: ActiveContact): void => {
      if (item.timer >= 0) clearTimeout(item.timer);
      this.input.releaseModifier(item.pointer);
    });
    this.input.clearStickyModifiers();
  }

  private repeat(contact: ActiveContact): void {
    if (!this.contacts.includes(contact)) return;
    if (!this.enabled() || contact.epoch !== this.input.getInputEpoch()) { this.release(contact, true); return; }
    this.deliver(contact.definition);
    if (this.contacts.includes(contact)) contact.timer = setTimeout((): void => { this.repeat(contact); }, 60);
  }
}
