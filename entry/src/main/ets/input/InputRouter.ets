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
  onInvalidated: () => void = (): void => {};
  private held: Map<number, string> = new Map<number, string>();
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
    this.held.forEach((name: string): void => {
      if (name === 'ctrl') result.ctrl = true;
      else if (name === 'alt' || name === 'altgr') result.alt = true;
      else if (name === 'shift') result.shift = true;
      else if (name === 'fn') result.fn = true;
    });
    return result;
  }

  holdModifier(pointer: number, id: string): void {
    this.held.set(pointer, id);
    this.emitModifiers();
  }

  releaseModifier(pointer: number): void {
    if (this.held.delete(pointer)) this.emitModifiers();
  }

  clearStickyModifiers(): void {
    this.modifiers.ctrl = false; this.modifiers.alt = false; this.modifiers.shift = false; this.modifiers.fn = false;
    this.ctrlLocked = false; this.altLocked = false; this.shiftLocked = false; this.fnLocked = false;
    this.lastModifier = '';
    this.emitModifiers();
  }

  beginSession(sessionId: string, connectionEpoch: number): void {
    this.sessionId = sessionId;
    this.connectionEpoch = connectionEpoch;
    this.invalidate();
  }

  invalidate(): void {
    this.inputEpoch++;
    this.onInvalidated();
    this.held.clear();
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
    const effective = this.getModifiers();
    routed.ctrl = effective.ctrl;
    routed.alt = effective.alt;
    routed.shift = effective.shift;

    if (definition.kind === 'action') {
      routed.kind = 'action';
      routed.action = definition.id;
      this.afterKey();
      return routed;
    }
    if (routed.ctrl && routed.shift && !routed.alt &&
      (definition.id.toLowerCase() === 'c' || definition.id.toLowerCase() === 'v')) {
      routed.kind = 'action';
      routed.action = definition.id.toLowerCase() === 'c' ? 'copy' : 'paste';
      this.afterKey();
      return routed;
    }
    if (effective.fn) {
      const mapped = InputRouter.mapFn(definition.id);
      if (mapped.length > 0) {
        routed.kind = 'key';
        routed.key = mapped;
        this.afterKey();
        return routed;
      }
    }
    if (definition.kind === 'key') {
      routed.kind = 'key';
      routed.key = definition.id;
    } else {
      const text = this.resolveText(definition, effective);
      if (routed.ctrl || routed.alt) {
        routed.kind = 'key';
        routed.key = text;
      } else {
        routed.kind = 'text';
        routed.text = text;
      }
      // Shift/Caps have already selected the printable character. Keeping
      // Shift here would apply it twice (notably Alt+Caps+Shift+A).
      routed.shift = false;
    }
    this.afterKey();
    return routed;
  }

  private resolveText(definition: KeyDefinition, effective: ModifierSnapshot): string {
    const isLetter = definition.output.length === 1 && definition.output >= 'a' && definition.output <= 'z';
    const shifted = isLetter ? (effective.shift !== effective.caps) : effective.shift;
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
