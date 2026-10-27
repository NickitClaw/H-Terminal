const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader } = require('./support/harness.cjs');
const { PasteTransaction } = createEtsLoader()('entry/src/main/ets/input/PasteTransaction.ets');

test('paste sends one UTF-8 boundary aligned part at a time and one bracket pair', () => {
  const source = '你好🙂'.repeat(10000);
  const tx = new PasteTransaction('one', 1, 2, 'paste', new Uint8Array(Buffer.from(source)), true);
  const chunks = [], phases = [];
  while (!tx.done()) {
    const part = tx.next();
    assert.notEqual(part, null);
    assert.equal(tx.next(), null);
    const bytes = Buffer.from(part.data, 'base64');
    phases.push(part.pastePhase); chunks.push(bytes);
    assert.ok(bytes.length <= 4096);
    if (part.pastePhase === 'data') assert.equal(Buffer.from(bytes.toString()).equals(bytes), true);
    assert.equal(tx.consume('stale', bytes.length), false);
    if (bytes.length > 1) {
      assert.equal(tx.consume(part.eventId, 1), true);
      assert.equal(tx.next(), null);
      tx.consume(part.eventId, bytes.length - 1);
    } else tx.consume(part.eventId, bytes.length);
  }
  assert.equal(phases.filter(p => p === 'start').length, 1);
  assert.equal(phases.filter(p => p === 'end').length, 1);
  assert.equal(Buffer.concat(chunks).toString(), '\x1b[200~' + source + '\x1b[201~');
});

test('empty unbracketed boundaries consume a completion event and cancellation wipes source', () => {
  const bytes = new Uint8Array(Buffer.from('secret'));
  const tx = new PasteTransaction('one', 1, 2, 'paste', bytes, false);
  const part = tx.next();
  assert.equal(part.data, '');
  assert.equal(tx.next(), null);
  tx.consume(part.eventId, 0);
  assert.equal(tx.next().pastePhase, 'data');
  tx.clear();
  assert.equal(bytes.every(value => value === 0), true);
  assert.equal(tx.next(), null);
});
