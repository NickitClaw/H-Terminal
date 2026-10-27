const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, loadPageMethods, ByteCodec } = require('./support/harness.cjs');

function fixture() {
  const reads = [], pastes = [], dialogs = [];
  const { PasteRequestContext } = createEtsLoader()('entry/src/main/ets/input/PasteRequestContext.ets');
  const Page = loadPageMethods(['requestPasteAuthorization', 'cancelPasteRequest',
    'isPasteContextCurrent', 'submitPaste', 'readPasteboard'], {
    ByteCodec, PasteRequestContext,
    pasteboard: { getSystemPasteboard: () => ({ getData: () => new Promise((resolve) => reads.push(resolve)) }) },
    AlertDialog: { show: (dialog) => dialogs.push(dialog) }
  });
  const page = new Page();
  let epoch = 1;
  page.pendingPaste = null;
  page.snapshot = { inputEnabled: true };
  page.showToast = () => {};
  page.session = {
    getSessionId: () => 'session-1', getConnectionEpoch: () => epoch,
    input: { getInputEpoch: () => epoch },
    paste: (...args) => pastes.push(args)
  };
  return { page, reads, pastes, dialogs, reconnect() { epoch++; } };
}
const flush = () => new Promise((resolve) => setImmediate(resolve));

test('old clipboard completion cannot target a newly authorized connection', async () => {
  const f = fixture();
  f.page.requestPasteAuthorization(); f.page.readPasteboard();
  f.reconnect(); f.page.requestPasteAuthorization();
  f.reads[0]({ getPrimaryText: () => 'old host text' }); await flush();
  assert.equal(f.pastes.length, 0);
  f.page.readPasteboard(); f.reads[1]({ getPrimaryText: () => 'new host text' }); await flush();
  assert.deepEqual(f.pastes, [['new host text', 'session-1', 2, 2]]);
});

test('new authorization supersedes a read even on the same connection', async () => {
  const f = fixture();
  f.page.requestPasteAuthorization(); f.page.readPasteboard();
  f.page.requestPasteAuthorization();
  f.reads[0]({ getPrimaryText: () => 'superseded' }); await flush();
  assert.equal(f.pastes.length, 0);
});

test('confirmation captures its original request and cannot be reused', async () => {
  const f = fixture();
  f.page.requestPasteAuthorization(); f.page.readPasteboard();
  f.reads[0]({ getPrimaryText: () => 'line one\nline two' }); await flush();
  const oldDialog = f.dialogs[0];
  f.reconnect(); f.page.requestPasteAuthorization();
  oldDialog.secondaryButton.action(); oldDialog.cancel();
  assert.equal(f.pastes.length, 0);
  assert.notEqual(f.page.pendingPaste, null);
  f.page.readPasteboard(); f.reads[1]({ getPrimaryText: () => 'safe\ntext' }); await flush();
  f.dialogs[1].secondaryButton.action(); f.dialogs[1].secondaryButton.action();
  assert.equal(f.pastes.length, 1);
  assert.equal(f.pastes[0][2], 2);
});

test('cancellation invalidates an outstanding clipboard read', async () => {
  const f = fixture();
  f.page.requestPasteAuthorization(); f.page.readPasteboard(); f.page.cancelPasteRequest();
  f.reads[0]({ getPrimaryText: () => 'cancelled' }); await flush();
  assert.equal(f.pastes.length, 0);
});
