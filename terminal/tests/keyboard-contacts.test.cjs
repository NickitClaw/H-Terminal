const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader } = require('./support/harness.cjs');
function fixture() {
  const load = createEtsLoader();
  const { InputRouter } = load('entry/src/main/ets/input/InputRouter.ets');
  const { KeyboardInteraction } = load('entry/src/main/ets/input/KeyboardInteraction.ets');
  const input = new InputRouter(); input.beginSession('one', 1);
  const events = []; let enabled = true;
  const keyboard = new KeyboardInteraction(input, key => { const routed = input.route(key); if (routed) events.push(routed); }, () => enabled);
  return { input, events, keyboard, disable() { enabled = false; keyboard.cancelAll(); } };
}
const key = id => ({ id, kind: ['ctrl', 'shift', 'alt', 'fn'].includes(id) ? 'modifier' : id.length === 1 ? 'text' : 'key', output: id, shiftOutput: id.toUpperCase() });

test('held modifiers combine across pointers without sticking after release', () => {
  const f = fixture();
  const ctrl = f.keyboard.press(key('ctrl'), 1), shift = f.keyboard.press(key('shift'), 2);
  f.keyboard.press(key('ArrowLeft'), 3).release();
  assert.equal(f.events[0].ctrl, true); assert.equal(f.events[0].shift, true);
  ctrl.release(); shift.release();
  f.keyboard.press(key('a'), 4).release();
  assert.equal(f.events[1].text, 'a'); assert.equal(f.events[1].ctrl, false);
  assert.equal(f.input.getModifiers().shift, false);
});

test('a modifier tap preserves sticky behavior; cancelled contacts cannot toggle it', () => {
  const f = fixture(); f.keyboard.press(key('ctrl'), 1).release();
  assert.equal(f.input.getModifiers().ctrl, true);
  f.keyboard.press(key('c'), 2).release(); assert.equal(f.events[0].ctrl, true);
  assert.equal(f.input.getModifiers().ctrl, false);
  f.keyboard.press(key('ctrl'), 1).release(true);
  assert.equal(f.input.getModifiers().ctrl, false);
});

test('Backspace repeats after its delay and release/cancel/epoch change stop every timer', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const f = fixture(); const contact = f.keyboard.press(key('Backspace'), 1);
  assert.equal(f.events.length, 1);
  t.mock.timers.tick(399); assert.equal(f.events.length, 1);
  t.mock.timers.tick(1); assert.equal(f.events.length, 2);
  t.mock.timers.tick(60); assert.equal(f.events.length, 3);
  contact.release(); t.mock.timers.tick(1000); assert.equal(f.events.length, 3);
  f.keyboard.press(key('ArrowLeft'), 2); f.input.invalidate();
  t.mock.timers.tick(1000); assert.equal(f.events.length, 4);
  const stale = f.keyboard.press(key('ctrl'), 3); f.input.beginSession('two', 2); stale.release();
  assert.equal(f.input.getModifiers().ctrl, false);
});

test('Enter, actions and modifiers never repeat, and disabled input cancels held keys', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] }); const f = fixture();
  f.keyboard.press(key('Enter'), 1); f.keyboard.press(key('ctrl'), 2);
  t.mock.timers.tick(10000); assert.equal(f.events.length, 1);
  f.disable(); t.mock.timers.tick(10000); assert.equal(f.input.getModifiers().ctrl, false);
  assert.equal(f.keyboard.press(key('a'), 3), null);
});

test('1,200 mixed contacts across input generations have unique targets and no leaked modifiers', () => {
  const f = fixture(); let pointer = 0;
  for (let i = 0; i < 1200; i++) {
    const modifier = f.keyboard.press(key(i % 2 ? 'ctrl' : 'shift'), ++pointer);
    const letter = f.keyboard.press(key('a'), ++pointer); letter.release();
    if (i % 7 === 0) f.input.beginSession('tab-' + i, i + 2);
    modifier.release(i % 3 === 0);
    assert.equal(f.input.getModifiers().ctrl || f.input.getModifiers().shift, false);
  }
  assert.equal(f.events.length, 1200);
  assert.equal(new Set(f.events.map(e => e.eventId)).size, 1200);
  for (let i = 1; i < f.events.length; i++) assert.ok(f.events[i].connectionEpoch >= f.events[i - 1].connectionEpoch);
});

test('touch cancellation releases every pointer and a previously locked modifier', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] }); const f = fixture();
  f.keyboard.press(key('ctrl'), 1).release(); f.keyboard.press(key('ctrl'), 2).release();
  assert.equal(f.input.getModifiers().ctrl, true);
  const arrow = f.keyboard.press(key('ArrowLeft'), 3);
  arrow.release(true); t.mock.timers.tick(10000);
  assert.equal(f.events.length, 1); assert.equal(f.input.getModifiers().ctrl, false);
  f.keyboard.press(key('a'), 4).release(); assert.equal(f.events.at(-1).text, 'a');
});
