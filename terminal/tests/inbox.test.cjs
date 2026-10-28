const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');
const { TerminalInbox } = createEtsLoader()('entry/src/main/ets/terminal/TerminalInbox.ets');

test('inbox preserves ordering and refuses overflow without silently discarding accepted messages', () => {
  const inbox = new TerminalInbox();
  for (let i = 0; i < 64; i++) assert.equal(inbox.enqueue(String(i)), true);
  assert.equal(inbox.enqueue('overflow'), false);
  for (let i = 0; i < 64; i++) assert.equal(inbox.take(), String(i));
  assert.equal(inbox.pending(), false); assert.equal(inbox.take(), '');
  assert.equal(inbox.enqueue('x'.repeat(1500000)), true);
  assert.equal(inbox.enqueue('y'.repeat(600000)), false);
  inbox.clear(); assert.equal(inbox.enqueue('new-page'), true); assert.equal(inbox.take(), 'new-page');
});

test('constant-source drain processes bounded batches through the actual page receiver', () => {
  const web = createTerminalHarness(); const inbox = new TerminalInbox();
  const identity = { sessionId: 'one', connectionEpoch: 1, terminalGeneration: 1 };
  inbox.enqueue(JSON.stringify({ type: 'init', ...identity, inputEpoch: 1 }));
  for (let seq = 1; seq <= 16; seq++) inbox.enqueue(JSON.stringify({ type: 'output', ...identity, seq, byteLength: 1, data: 'QQ==' }));
  web.setInbox(() => inbox.take());
  assert.equal(web.drain(), 8); assert.equal(inbox.pending(), true);
  assert.equal(web.drain(), 8); assert.equal(web.drain(), 1); assert.equal(web.drain(), 0);
  assert.equal(Buffer.concat(web.writes).toString(), 'A'.repeat(16));
  assert.equal(web.messages.filter(m => m.type === 'ack').length, 16);
});
