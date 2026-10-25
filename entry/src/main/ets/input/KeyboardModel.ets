export type KeyKind = 'text' | 'key' | 'modifier' | 'action';

export class KeyDefinition {
  id: string;
  label: string;
  kind: KeyKind;
  output: string;
  shiftOutput: string;
  width: number;
  subLabel: string;

  constructor(id: string, label: string, kind: KeyKind, output: string = '', shiftOutput: string = '',
    width: number = 1, subLabel: string = '') {
    this.id = id;
    this.label = label;
    this.kind = kind;
    this.output = output;
    this.shiftOutput = shiftOutput;
    this.width = width;
    this.subLabel = subLabel;
  }
}

export class KeyboardRow {
  keys: KeyDefinition[];
  weight: number;

  constructor(keys: KeyDefinition[], weight: number = 1) {
    this.keys = keys;
    this.weight = weight;
  }
}

export enum KeyboardLayoutMode {
  FULL = 'full',
  COMPACT = 'compact'
}

function textKey(id: string, label: string, output: string, shifted: string, width: number = 1,
  subLabel: string = ''): KeyDefinition {
  return new KeyDefinition(id, label, 'text', output, shifted, width, subLabel);
}

function specialKey(id: string, label: string, width: number = 1): KeyDefinition {
  return new KeyDefinition(id, label, 'key', '', '', width);
}

function modifierKey(id: string, label: string, width: number = 1): KeyDefinition {
  return new KeyDefinition(id, label, 'modifier', '', '', width);
}

function actionKey(id: string, label: string, width: number = 1): KeyDefinition {
  return new KeyDefinition(id, label, 'action', '', '', width);
}

function letters(value: string): KeyDefinition[] {
  return value.split('').map((letter: string): KeyDefinition =>
    textKey(letter.toLowerCase(), letter, letter.toLowerCase(), letter));
}

function digits(): KeyDefinition[] {
  const labels: string[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
  const shifted: string[] = ['!', '@', '#', '$', '%', '^', '&', '*', '(', ')'];
  return labels.map((label: string, index: number): KeyDefinition =>
    textKey(label, label, label, shifted[index], 1, shifted[index]));
}

function functionKeys(): KeyDefinition[] {
  const keys: KeyDefinition[] = [];
  for (let index = 1; index <= 12; index++) {
    keys.push(specialKey(`F${index}`, `F${index}`));
  }
  return keys;
}

function bottomRow(compact: boolean): KeyboardRow {
  return new KeyboardRow([
    modifierKey('ctrl', 'Ctrl', 1.2),
    modifierKey('fn', 'Fn'),
    actionKey(compact ? 'symbols' : 'symbols', compact ? 'Sym' : 'Sym'),
    actionKey('ime', '中/英', 1.2),
    modifierKey('alt', 'Alt', 1.2),
    textKey('space', 'Space', ' ', ' ', 4.2),
    modifierKey('altgr', 'AltGr', 1.2),
    specialKey('ArrowLeft', '←'),
    specialKey('ArrowDown', '↓'),
    specialKey('ArrowRight', '→')
  ]);
}

function symbolRows(): KeyboardRow[] {
  return [
    new KeyboardRow([
      specialKey('Escape', 'Esc'),
      textKey('backtick', '`', '`', '~', 1, '~'),
      textKey('minus', '-', '-', '_', 1, '_'),
      textKey('equal', '=', '=', '+', 1, '+'),
      textKey('leftBracket', '[', '[', '{', 1, '{'),
      textKey('rightBracket', ']', ']', '}', 1, '}'),
      textKey('backslash', '\\', '\\', '|', 1, '|'),
      specialKey('Delete', 'Del')
    ], 0.85),
    new KeyboardRow([
      specialKey('Tab', 'Tab', 1.4),
      textKey('exclamation', '!', '!', '!'),
      textKey('at', '@', '@', '@'),
      textKey('hash', '#', '#', '#'),
      textKey('dollar', '$', '$', '$'),
      textKey('percent', '%', '%', '%'),
      textKey('caret', '^', '^', '^'),
      textKey('ampersand', '&', '&', '&'),
      textKey('asterisk', '*', '*', '*'),
      textKey('leftParen', '(', '(', '('),
      textKey('rightParen', ')', ')', ')')
    ]),
    new KeyboardRow([
      modifierKey('caps', 'Caps', 1.5),
      textKey('semicolon', ';', ';', ':', 1, ':'),
      textKey('quote', '\'', '\'', '"', 1, '"'),
      textKey('comma', ',', ',', '<', 1, '<'),
      textKey('dot', '.', '.', '>', 1, '>'),
      textKey('slash', '/', '/', '?', 1, '?'),
      specialKey('Home', 'Home'),
      specialKey('End', 'End'),
      specialKey('Enter', 'Enter', 1.4)
    ]),
    new KeyboardRow([
      modifierKey('shift', 'Shift', 1.8),
      specialKey('PageUp', 'PgUp'),
      specialKey('PageDown', 'PgDn'),
      specialKey('Insert', 'Ins'),
      specialKey('Backspace', 'Backspace', 1.6),
      specialKey('ArrowUp', '↑')
    ]),
    bottomRow(true)
  ];
}

function compactRows(): KeyboardRow[] {
  return [
    new KeyboardRow([specialKey('Escape', 'Esc', 1.2), ...digits(), specialKey('Backspace', 'Backspace', 1.8)], 0.9),
    new KeyboardRow([specialKey('Tab', 'Tab', 1.5), ...letters('QWERTYUIOP')]),
    new KeyboardRow([modifierKey('caps', 'Caps', 1.7), ...letters('ASDFGHJKL'), specialKey('Enter', 'Enter', 1.8)]),
    new KeyboardRow([modifierKey('shift', 'Shift', 2), ...letters('ZXCVBNM'), specialKey('ArrowUp', '↑')]),
    bottomRow(true)
  ];
}

function fullRows(): KeyboardRow[] {
  return [
    new KeyboardRow([specialKey('Escape', 'Esc'), ...functionKeys(), specialKey('Delete', 'Del')], 0.75),
    new KeyboardRow([
      textKey('backtick', '`', '`', '~', 1, '~'),
      ...digits(),
      textKey('minus', '-', '-', '_', 1, '_'),
      textKey('equal', '=', '=', '+', 1, '+'),
      specialKey('Backspace', 'Backspace', 2)
    ], 0.95),
    new KeyboardRow([
      specialKey('Tab', 'Tab', 1.5),
      ...letters('QWERTYUIOP'),
      textKey('leftBracket', '[', '[', '{', 1, '{'),
      textKey('rightBracket', ']', ']', '}', 1, '}'),
      textKey('backslash', '\\', '\\', '|', 1.5, '|')
    ]),
    new KeyboardRow([
      modifierKey('caps', 'Caps', 1.8),
      ...letters('ASDFGHJKL'),
      textKey('semicolon', ';', ';', ':', 1, ':'),
      textKey('quote', '\'', '\'', '"', 1, '"'),
      specialKey('Enter', 'Enter', 2.2)
    ]),
    new KeyboardRow([
      modifierKey('shift', 'Shift', 2.2),
      ...letters('ZXCVBNM'),
      textKey('comma', ',', ',', '<', 1, '<'),
      textKey('dot', '.', '.', '>', 1, '>'),
      textKey('slash', '/', '/', '?', 1, '?'),
      modifierKey('shift', 'Shift', 1.8),
      specialKey('ArrowUp', '↑')
    ]),
    new KeyboardRow([
      modifierKey('ctrl', 'Ctrl', 1.2),
      modifierKey('fn', 'Fn'),
      actionKey('ime', '中/英', 1.2),
      modifierKey('alt', 'Alt', 1.2),
      textKey('space', 'Space', ' ', ' ', 5),
      modifierKey('altgr', 'AltGr', 1.2),
      modifierKey('ctrl', 'Ctrl', 1.2),
      specialKey('ArrowLeft', '←'),
      specialKey('ArrowDown', '↓'),
      specialKey('ArrowRight', '→')
    ])
  ];
}

export class KeyboardModel {
  static rows(mode: KeyboardLayoutMode, symbols: boolean): KeyboardRow[] {
    if (symbols) {
      return symbolRows();
    }
    return mode === KeyboardLayoutMode.FULL ? fullRows() : compactRows();
  }
}
