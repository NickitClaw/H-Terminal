import { KeyDefinition } from './KeyboardModel';

export class ModifierSnapshot {
  ctrl: boolean = false;
  alt: boolean = false;
  shift: boolean = false;
  fn: boolean = false;
  caps: boolean = false;
}

export class RoutedInput {
  kind: 'key' | 'text' | 'action' = 'key';
  sessionId: string = '';
  connectionEpoch: number = 0;
  inputEpoch: number = 0;
  eventId: string = '';
  key: string = '';
  text: string = '';
  action: string = '';
  ctrl: boolean = false;
  alt: boolean = false;
  shift: boolean = false;
}

export class InputRouter {
  onModifiersChanged: (modifiers: ModifierSnapshot) => void = (_modifiers: ModifierSnapshot): void => {};
  private sessionId: string = '';
  private connectionEpoch: number = 0;
  private inputEpoch: number = 1;
  private eventCounter: number = 0;
  private modifiers: ModifierSnapshot = new ModifierSnapshot();
  private ctrlLocked: boolean = false;
  private altLocked: boolean = false;
  private shiftLocked: boolean = false;
  private fnLocked: boolean = false;
  private lastModifier: string = '';
  private lastModifierTime: number = 0;

  getInputEpoch(): number {
    return this.inputEpoch;
  }

  getModifiers(): ModifierSnapshot {
    const result = new ModifierSnapshot();
    result.ctrl = this.modifiers.ctrl;
    result.alt = this.modifiers.alt;
    result.shift = this.modifiers.shift;
    result.fn = this.modifiers.fn;
    result.caps = this.modifiers.caps;
    return result;
  }

  beginSession(sessionId: string, connectionEpoch: number): void {
    this.sessionId = sessionId;
    this.connectionEpoch = connectionEpoch;
    this.invalidate();
  }

  invalidate(): void {
    this.inputEpoch++;
    this.modifiers = new ModifierSnapshot();
    this.ctrlLocked = false;
    this.altLocked = false;
    this.shiftLocked = false;
    this.fnLocked = false;
    this.lastModifier = '';
    this.emitModifiers();
  }

  route(definition: KeyDefinition): RoutedInput | null {
    if (definition.kind === 'modifier') {
      this.toggleModifier(definition.id);
      return null;
    }
    if (this.sessionId.length === 0) {
      return null;
    }
    const routed = new RoutedInput();
    routed.sessionId = this.sessionId;
    routed.connectionEpoch = this.connectionEpoch;
    routed.inputEpoch = this.inputEpoch;
    this.eventCounter++;
    routed.eventId = `${this.inputEpoch}-${this.eventCounter}`;
    routed.ctrl = this.modifiers.ctrl;
    routed.alt = this.modifiers.alt;
    routed.shift = this.modifiers.shift;

    if (definition.kind === 'action') {
      routed.kind = 'action';
      routed.action = definition.id;
      this.afterKey();
      return routed;
    }
    if (routed.ctrl && routed.shift && (definition.id.toLowerCase() === 'c' || definition.id.toLowerCase() === 'v')) {
      routed.kind = 'action';
      routed.action = definition.id.toLowerCase() === 'c' ? 'copy' : 'paste';
      this.afterKey();
      return routed;
    }
    if (this.modifiers.fn) {
      const mapped = InputRouter.mapFn(definition.id);
      if (mapped.length > 0) {
        routed.kind = 'key';
        routed.key = mapped;
        this.afterKey();
        return routed;
      }
    }
    if (definition.kind === 'key' || routed.ctrl || routed.alt) {
      routed.kind = 'key';
      routed.key = definition.kind === 'key' ? definition.id : definition.output;
    } else {
      routed.kind = 'text';
      routed.text = this.resolveText(definition);
      routed.shift = false;
    }
    this.afterKey();
    return routed;
  }

  private resolveText(definition: KeyDefinition): string {
    const isLetter = definition.output.length === 1 && definition.output >= 'a' && definition.output <= 'z';
    const shifted = isLetter ? (this.modifiers.shift !== this.modifiers.caps) : this.modifiers.shift;
    return shifted && definition.shiftOutput.length > 0 ? definition.shiftOutput : definition.output;
  }

  private static mapFn(id: string): string {
    if (id >= '1' && id <= '9') {
      return `F${Number(id)}`;
    }
    if (id === '0') {
      return 'F10';
    }
    if (id === '-' || id === 'minus') {
      return 'F11';
    }
    if (id === '=' || id === 'equal') {
      return 'F12';
    }
    if (id === 'ArrowLeft') {
      return 'Home';
    }
    if (id === 'ArrowRight') {
      return 'End';
    }
    if (id === 'ArrowUp') {
      return 'PageUp';
    }
    if (id === 'ArrowDown') {
      return 'PageDown';
    }
    if (id === 'Backspace') {
      return 'Delete';
    }
    if (id === 'Delete') {
      return 'Insert';
    }
    return '';
  }

  private toggleModifier(id: string): void {
    if (id === 'caps') {
      this.modifiers.caps = !this.modifiers.caps;
      this.emitModifiers();
      return;
    }
    const name = id === 'altgr' ? 'alt' : id;
    const now = Date.now();
    const doubleTap = this.lastModifier === id && now - this.lastModifierTime <= 300;
    this.lastModifier = id;
    this.lastModifierTime = now;
    if (name === 'ctrl') {
      const result = this.nextModifierState(this.modifiers.ctrl, this.ctrlLocked, doubleTap);
      this.modifiers.ctrl = result[0];
      this.ctrlLocked = result[1];
    } else if (name === 'alt') {
      const result = this.nextModifierState(this.modifiers.alt, this.altLocked, doubleTap);
      this.modifiers.alt = result[0];
      this.altLocked = result[1];
    } else if (name === 'shift') {
      const result = this.nextModifierState(this.modifiers.shift, this.shiftLocked, doubleTap);
      this.modifiers.shift = result[0];
      this.shiftLocked = result[1];
    } else if (name === 'fn') {
      const result = this.nextModifierState(this.modifiers.fn, this.fnLocked, doubleTap);
      this.modifiers.fn = result[0];
      this.fnLocked = result[1];
    }
    this.emitModifiers();
  }

  private nextModifierState(active: boolean, locked: boolean, doubleTap: boolean): boolean[] {
    if (doubleTap) {
      return [true, true];
    }
    if (active) {
      return [false, false];
    }
    return [true, locked];
  }

  private afterKey(): void {
    if (!this.ctrlLocked) {
      this.modifiers.ctrl = false;
    }
    if (!this.altLocked) {
      this.modifiers.alt = false;
    }
    if (!this.shiftLocked) {
      this.modifiers.shift = false;
    }
    if (!this.fnLocked) {
      this.modifiers.fn = false;
    }
    this.lastModifier = '';
    this.emitModifiers();
  }

  private emitModifiers(): void {
    this.onModifiersChanged(this.getModifiers());
  }
}
