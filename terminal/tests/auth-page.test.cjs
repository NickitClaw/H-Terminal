const test = require('node:test');
const assert = require('node:assert/strict');
const { loadPageMethods, ByteCodec } = require('./support/harness.cjs');
const flush = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve, reject; const promise = new Promise((r, j) => { resolve = r; reject = j; }); return { promise, resolve, reject }; };

function fixture() {
  const picked = deferred(), inspected = deferred(), saved = deferred(), reads = deferred();
  const calls = { saves: [], connects: [], dialogs: [], removed: [], toasts: [], buffers: [], canceled: 0 };
  const Page = loadPageMethods(['importKey', 'connect', 'clearAuthentication', 'submitAuthentication', 'deleteCredential', 'cancelConnectionForm', 'closeTab', 'credentialInUse', 'useHost', 'currentProfile', 'stopReconnect'], {
    ByteCodec, ConnectionState: { CONNECTING: 'CONNECTING', VERIFYING_HOST: 'VERIFYING_HOST', AUTHENTICATING: 'AUTHENTICATING', OPEN: 'OPEN' },
    HostProfile: class {},
    native: { inspectPrivateKey: () => inspected.promise },
    picker: { DocumentViewPicker: class { select() { return picked.promise; } } },
    fileIo: { OpenMode: { READ_ONLY: 0 }, openSync: () => ({ fd: 1 }), statSync: () => ({ size: 8 }),
      readSync(_fd, buffer) { new Uint8Array(buffer).fill(65); calls.buffers.push(buffer); return 8; }, closeSync() {} },
    HostKeyInfo: class {}, AlertDialog: { show: dialog => calls.dialogs.push(dialog) }
  });
  const page = Object.assign(new Page(), { pageActive: true, pageGeneration: 1, activeTabId: 'one', hostName: 'first',
    importingKey: false, password: 'original-passphrase', credentialId: '', host: 'host.test', portText: '22', username: 'review',
    authMethod: 'publickey', connectRequest: 0, hosts: [], tabs: [], preparingConnection: false,
    authAnswers: [], authTarget: null, authChallenge: null, snapshot: { state: 'IDLE' } });
  page.vault = { async save(...args) { calls.saves.push(args); return saved.promise; }, list: () => [{ id: 'saved' }],
    read: () => reads.promise, async remove(id) { calls.removed.push(id); } };
  page.session = { getConnectionEpoch: () => 0, cancelReconnect() { calls.canceled++; }, setAutoReconnect() {},
    connect: (...args) => { calls.connects.push(args); return true; } };
  page.getUIContext = () => ({ getHostContext: () => ({}) });
  page.showToast = text => calls.toasts.push(text);
  page.cancelPasteRequest = () => {};
  return { page, picked, inspected, saved, reads, calls };
}

test('file picker cancellation clears only the captured secret and allows another import', async () => {
  const f = fixture(); const pending = f.page.importKey();
  assert.equal(f.page.password, '');
  f.page.password = 'new-form-secret'; f.picked.resolve([]); await pending;
  assert.equal(f.page.password, 'new-form-secret');
  assert.equal(f.page.importingKey, false);
  assert.equal(f.calls.saves.length, 0);
});

test('switching tabs during private key inspection discards the result and wipes bytes', async () => {
  const f = fixture(); const pending = f.page.importKey();
  f.picked.resolve(['fixture']); await flush();
  f.page.activeTabId = 'two'; f.inspected.resolve({ publicKey: 'fixture' }); await pending;
  assert.equal(f.calls.saves.length, 0);
  assert.equal(f.page.credentialId, '');
  assert.deepEqual([...new Uint8Array(f.calls.buffers[0])], Array(8).fill(0));
});

test('a completed vault save cannot select a credential in another tab', async () => {
  const f = fixture(); const pending = f.page.importKey();
  f.picked.resolve(['fixture']); f.inspected.resolve({ publicKey: 'fixture' }); await flush();
  assert.equal(f.calls.saves.length, 1);
  f.page.activeTabId = 'two'; f.saved.resolve('saved'); await pending;
  assert.equal(f.page.credentialId, '');
  assert.deepEqual(f.page.credentials, [{ id: 'saved' }]);
  assert.deepEqual([...new Uint8Array(f.calls.buffers[0])], Array(8).fill(0));
});

test('late vault unlock after cancellation never connects and always wipes plaintext', async () => {
  const f = fixture(); f.page.credentialId = 'key'; const pending = f.page.connect();
  f.page.connectRequest++; const bytes = new Uint8Array([1, 2, 3]); f.reads.resolve(bytes); await pending;
  assert.equal(f.calls.connects.length, 0); assert.deepEqual([...bytes], [0, 0, 0]);
});

test('stale MFA challenge cannot answer a newer connection and wipes form answers', () => {
  const f = fixture(); const answers = ['secret'];
  f.page.authAnswers = answers; f.page.authEpoch = 1;
  f.page.authTarget = { getConnectionEpoch: () => 2, answerAuthentication: () => assert.fail('stale answer') };
  f.page.authChallenge = { requestId: 7 }; f.page.submitAuthentication();
  assert.deepEqual(answers, ['']); assert.equal(f.page.authTarget, null); assert.equal(f.page.authChallenge, null);
});

test('credential deletion is blocked by saved hosts and active tabs, but permits an unused credential', async () => {
  const f = fixture(); const credential = { id: 'key', name: 'fixture' };
  f.page.hosts = [{ credentialId: 'key', authMethod: 'publickey' }]; f.page.deleteCredential(credential);
  assert.equal(f.calls.dialogs.length, 0);
  f.page.hosts = []; f.page.tabs = [{ profile: { credentialId: 'key' }, snapshot: { state: 'AUTHENTICATING' } }];
  f.page.deleteCredential(credential); assert.equal(f.calls.dialogs.length, 0);
  f.page.tabs = []; f.page.deleteCredential(credential);
  await f.calls.dialogs[0].secondaryButton.action(); await flush();
  assert.deepEqual(f.calls.removed, ['key']);
});

test('cancelling asynchronous credential unlock releases the busy form and rejects the late completion', async () => {
  const f = fixture(); f.page.credentialId = 'key'; f.page.snapshot = { state: 'IDLE' };
  const pending = f.page.connect(); assert.equal(f.page.preparingConnection, true);
  f.page.cancelConnectionForm(); assert.equal(f.page.preparingConnection, false); assert.equal(f.page.password, '');
  const bytes = new Uint8Array([1, 2, 3]); f.reads.resolve(bytes); await pending;
  assert.equal(f.calls.connects.length, 0); assert.equal(f.page.preparingConnection, false);
  assert.deepEqual([...bytes], [0, 0, 0]);
});

test('closing an inactive tab preserves the active authentication form and input context', () => {
  const f = fixture(); const closed = []; let leaves = 0;
  f.page.tabs = [{ id: 'one' }, { id: 'two' }];
  f.page.workspace = { close: id => { closed.push(id); f.page.tabs = f.page.tabs.filter(t => t.id !== id); }, create: () => assert.fail('active tab remains') };
  f.page.leaveTab = () => { leaves++; };
  f.page.authChallenge = { requestId: 1 }; f.page.authAnswers = ['answer'];
  f.page.closeTab('two'); f.calls.dialogs[0].secondaryButton.action();
  assert.deepEqual(closed, ['two']); assert.equal(leaves, 0);
  assert.deepEqual(f.page.authAnswers, ['answer']); assert.equal(f.page.authChallenge.requestId, 1);
});

test('a deletion confirmation rechecks references acquired while the dialog was open', async () => {
  const f = fixture(); const credential = { id: 'key', name: 'fixture' };
  f.page.deleteCredential(credential); assert.equal(f.calls.dialogs.length, 1);
  f.page.tabs = [{ profile: { credentialId: 'key' }, snapshot: { state: 'FAILED', retrying: true } }];
  f.calls.dialogs[0].secondaryButton.action(); await flush(); assert.deepEqual(f.calls.removed, []);
});

test('loading another saved host cancels an outstanding private key unlock', async () => {
  const f = fixture(); f.page.credentialId = 'first-key';
  const pending = f.page.connect();
  f.page.useHost({ id: 'other', name: 'other', host: 'other.test', port: 2222,
    username: 'other-user', authMethod: 'password', credentialId: '', autoReconnect: false });
  const bytes = new Uint8Array([1, 2, 3]); f.reads.resolve(bytes); await pending;
  assert.equal(f.calls.connects.length, 0, 'old unlock must not connect after loading a different host');
  assert.equal(f.page.host, 'other.test'); assert.equal(f.page.preparingConnection, false);
  assert.deepEqual([...bytes], [0, 0, 0]);
});

test('editing the form during unlock rejects the old intent and preserves the new secret', async () => {
  const f = fixture(); f.page.credentialId = 'first-key';
  const pending = f.page.connect();
  f.page.host = 'edited.test'; f.page.password = 'new-form-secret';
  const bytes = new Uint8Array([1, 2, 3]); f.reads.resolve(bytes); await pending;
  assert.equal(f.calls.connects.length, 0, 'old parameters must not be used after editing');
  assert.equal(f.page.password, 'new-form-secret'); assert.equal(f.page.preparingConnection, false);
  assert.deepEqual([...bytes], [0, 0, 0]);
});

test('stopping reconnect also cancels an in-flight private key unlock', async () => {
  const f = fixture(); f.page.credentialId = 'key';
  const pending = f.page.connect(true);
  assert.equal(f.page.preparingConnection, true);
  f.page.stopReconnect();
  assert.equal(f.page.preparingConnection, false);
  const bytes = new Uint8Array([1, 2, 3]); f.reads.resolve(bytes); await pending;
  assert.equal(f.calls.connects.length, 0);
  assert.deepEqual([...bytes], [0, 0, 0]);
});

test('a canceled unlock failure cannot cancel a newer retry or clear its new secret', async () => {
  const f = fixture(); f.page.credentialId = 'key';
  const pending = f.page.connect(true); f.page.stopReconnect();
  f.page.password = 'new-secret';
  f.reads.reject(new Error('late unlock failure')); await pending;
  assert.equal(f.calls.canceled, 1);
  assert.equal(f.calls.toasts.length, 0);
  assert.equal(f.page.password, 'new-secret');
});

test('an automatic retry without an available credential leaves no retry in progress', async () => {
  const f = fixture(); await f.page.connect(true);
  assert.equal(f.calls.connects.length, 0);
  assert.equal(f.calls.canceled, 1);
  assert.equal(f.page.preparingConnection, false);
});
