const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');
const identity = { sessionId: 'one', connectionEpoch: 1, terminalGeneration: 1 };
function fixture() { const f = createTerminalHarness(); f.receive({ type: 'init', ...identity, inputEpoch: 1 }); return f; }

test('font updates keep the existing terminal, validate bounds and survive reconfigure', () => {
  const f = fixture(), original = f.terminal;
  assert.equal(f.receive({ type: 'appearance', ...identity, fontSize: 20 }), true);
  assert.equal(f.terminal, original); assert.equal(original.options.fontSize, 20);
  assert.equal(f.receive({ type: 'appearance', ...identity, fontSize: 29 }), false);
  assert.equal(f.receive({ type: 'appearance', ...identity, connectionEpoch: 0, fontSize: 18 }), false);
  const { XtermBackend } = createEtsLoader()('entry/src/main/ets/terminal/XtermBackend.ets');
  const backend = new XtermBackend(); const messages = [];
  backend.setSender(message => messages.push(message)); backend.markWebReady();
  backend.configure('one', 1, 1, 1); backend.setFontSize(22); backend.configure('one', 2, 1, 2);
  assert.equal(messages.at(-1).fontSize, 22);
});

test('search is scoped, literal and bounded; it never emits terminal input', () => {
  const f = fixture();
  assert.equal(f.receive({ type: 'search', ...identity, query: 'fixture', backward: true }), true);
  assert.equal(f.messages.at(-1).matched, true);
  assert.equal(f.searches[0].options.regex, false);
  assert.equal(f.receive({ type: 'search', ...identity, query: 'x'.repeat(257) }), false);
  assert.equal(f.receive({ type: 'search', ...identity, sessionId: 'other', query: 'fixture' }), false);
  assert.equal(f.messages.filter(m => m.type === 'input').length, 0);
});

test('local selection freezes plain text and blocks terminal/mouse input until explicitly exited', () => {
  const f = fixture();
  assert.equal(f.receive({ type: 'selection', ...identity, selecting: true }), true);
  assert.equal(f.selectionHost.hidden, false);
  assert.equal(f.selectionHost.textContent, 'fixture <script>你好🙂</script>');
  f.terminal.dataHandler('\x1b[M!!'); f.terminal.binaryHandler('mouse');
  assert.equal(f.receive({ type: 'key', ...identity, inputEpoch: 1, eventId: 'stale-key', key: 'Enter' }), false);
  f.receive({ type: 'copy', ...identity });
  assert.equal(Buffer.from(f.messages.at(-1).data, 'base64').toString(), 'fixture <script>你好🙂</script>');
  assert.equal(f.messages.filter(m => m.type === 'input').length, 0);
  f.receive({ type: 'selection', ...identity, selecting: false });
  assert.equal(f.selectionHost.hidden, true); assert.equal(f.selectionHost.textContent, '');
  f.terminal.dataHandler('a'); assert.equal(f.messages.at(-1).type, 'input');
});

test('font preferences accept valid old/new documents and reject malformed sizes', async () => {
  const { HostRepository } = createEtsLoader()('entry/src/main/ets/storage/HostRepository.ets');
  for (const [size, expected] of [[undefined, 15], [24, 24], [-1, 15], [72, 15], ['18', 15]]) {
    const repo = new HostRepository({ read: async () => JSON.stringify({ version: 1, hosts: [], preferences: { fontSize: size } }) });
    await repo.load(); assert.equal(repo.preferences().fontSize, expected);
  }
});
