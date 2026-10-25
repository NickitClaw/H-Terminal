const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');

const load = createEtsLoader();
const { InputRouter } = load('entry/src/main/ets/input/InputRouter.ets');
const { KeyboardModel, KeyboardLayoutMode } = load('entry/src/main/ets/input/KeyboardModel.ets');
const keys = KeyboardModel.rows(KeyboardLayoutMode.FULL, false).flatMap((row) => row.keys);
const key = (id) => keys.find((definition) => definition.id === id);
const identity = { sessionId: 'session-1', connectionEpoch: 1, terminalGeneration: 1 };

function route(modifiers, id) {
  const router = new InputRouter();
  router.beginSession('session-1', 1);
  for (const modifier of modifiers) router.route(key(modifier));
  return router.route(key(id));
}

for (const [modifiers, id, expected] of [
  [['alt', 'shift'], '1', '\x1b!'],
  [['alt', 'caps'], 'a', '\x1bA'],
  [['alt', 'caps', 'shift'], 'a', '\x1ba'],
  [['ctrl', 'shift'], 'slash', '\x7f'],
  [['ctrl', 'shift'], '6', '\x1e'],
  [['ctrl'], 'c', '\x03'],
  [['shift'], '1', '!'],
  [['ctrl', 'alt', 'shift'], 'v', '\x1b\x16']
]) {
  test(`${modifiers.join('+')}+${id} encodes the resolved character`, () => {
    const routed = route(modifiers, id);
    const web = createTerminalHarness();
    web.receive({ type: 'init', ...identity, inputEpoch: routed.inputEpoch });
    assert.equal(web.receive({
      type: routed.kind, ...identity, inputEpoch: routed.inputEpoch, eventId: routed.eventId,
      key: routed.key, ctrl: routed.ctrl, alt: routed.alt, shift: routed.shift,
      data: Buffer.from(routed.text).toString('base64')
    }), true);
    const input = web.messages.find((message) => message.type === 'input');
    assert.equal(Buffer.from(input.data, 'base64').toString(), expected);
  });
}

test('special keys keep Shift, and Ctrl+Shift+C/V remain local actions', () => {
  assert.equal(route(['shift'], 'Tab').shift, true);
  assert.equal(route(['ctrl', 'shift'], 'c').action, 'copy');
  assert.equal(route(['ctrl', 'shift'], 'v').action, 'paste');
  const routed = route(['ctrl', 'shift'], 'ArrowLeft');
  assert.equal(routed.key, 'ArrowLeft');
  assert.equal(routed.ctrl, true);
  assert.equal(routed.shift, true);
});
