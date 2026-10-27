const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');

function fixture() {
  let emit;
  const calls = { initialize: 0, dispose: 0, write: [], ack: [], close: [], connect: [] };
  const native = {
    initialize(callback) { calls.initialize++; emit = callback; }, dispose() { calls.dispose++; },
    connect(options) { calls.connect.push({ ...options }); }, closeSession(...args) { calls.close.push(args); },
    resetInput(id, epoch, inputEpoch) { queueMicrotask(() => emit({ type: 'inputReset', sessionId: id, connectionEpoch: epoch, inputEpoch })); },
    writeInput(request) { calls.write.push({ ...request }); return true; },
    resize() {}, acknowledgeOutput(request) { calls.ack.push(request); }
  };
  const load = createEtsLoader({ native });
  const { SessionWorkspace } = load('entry/src/main/ets/terminal/SessionWorkspace.ets');
  const workspace = new SessionWorkspace('/isolated');
  const pages = new Map();
  workspace.onAdded = tab => {
    tab.session.onSnapshot = snapshot => { tab.snapshot = snapshot; };
    const page = createTerminalHarness(message => tab.session.handleTerminalMessage(JSON.stringify(message)));
    pages.set(tab.id, page);
    tab.backend.setSender(message => page.receive(message)); tab.backend.markWebReady();
  };
  return { workspace, calls, pages, emit: event => emit(event),
    open(tab) {
      assert.equal(tab.session.connect('localhost', 22227, 'review', 'review'), true);
      emit({ ...calls.connect.at(-1), type: 'state', state: 'OPEN' });
    }
  };
}

test('tabs retain independent terminals, pause hidden output and share one native callback', async () => {
  const f = fixture();
  try {
    const first = f.workspace.create(); f.open(first);
    const original = f.pages.get(first.id).terminal;
    const second = f.workspace.create(); f.open(second);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.calls.initialize, 1);
    assert.equal(first.snapshot.inputEnabled, false);
    f.emit({ type: 'output', sessionId: first.id, connectionEpoch: 1, terminalGeneration: 1, seq: 1, byteLength: 1, data: 'QQ==' });
    assert.equal(f.pages.get(first.id).writes.length, 0);
    assert.equal(f.calls.ack.length, 0);
    f.workspace.select(first.id);
    assert.equal(f.pages.get(first.id).terminal, original);
    assert.equal(Buffer.concat(f.pages.get(first.id).writes).toString(), 'A');
    assert.equal(f.calls.ack[0].sessionId, first.id);
    first.session.routeKey({ kind: 'key', id: 'Enter' });
    assert.equal(f.calls.write.at(-1).sessionId, first.id);
    f.workspace.close(first.id);
    assert.equal(f.workspace.active().id, second.id);
    assert.equal(f.calls.dispose, 0);
    f.emit({ type: 'state', sessionId: first.id, connectionEpoch: 1, state: 'FAILED' });
    assert.equal(second.snapshot.state, 'OPEN');
  } finally { f.workspace.dispose(); }
  assert.equal(f.calls.dispose, 1);
});

test('four-tab limit and closing a tab preserve other sessions and reject stale epochs', () => {
  const f = fixture();
  try {
    for (let i = 0; i < 4; i++) f.workspace.create();
    assert.equal(f.workspace.create(), null);
    const active = f.workspace.active(); f.open(active);
    f.emit({ type: 'state', sessionId: active.id, connectionEpoch: 0, state: 'FAILED' });
    assert.equal(active.snapshot.state, 'OPEN');
    const closedId = f.workspace.list()[0].id;
    f.workspace.close(closedId);
    assert.ok(f.workspace.create());
    assert.equal(f.workspace.list().some(tab => tab.id === closedId), false);
  } finally { f.workspace.dispose(); }
});

test('hidden output stays bounded by native unacknowledged credit', () => {
  const f = fixture();
  try {
    const tab = f.workspace.create(); f.open(tab);
    f.workspace.create();
    const frame = { type: 'output', sessionId: tab.id, connectionEpoch: 1, terminalGeneration: 1,
      byteLength: 32768, data: Buffer.alloc(32768).toString('base64') };
    for (let seq = 1; seq <= 8; seq++) assert.equal(tab.backend.send({ ...frame, seq }), true);
    assert.equal(tab.backend.send({ ...frame, seq: 9 }), false);
  } finally { f.workspace.dispose(); }
});
