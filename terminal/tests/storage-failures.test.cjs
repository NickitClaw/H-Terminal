const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader } = require('./support/harness.cjs');
const flushTasks = () => new Promise(resolve => setImmediate(resolve));

function fixture() {
  let cached = '', persisted = '', failFlush;
  const raw = {
    async get(_key, fallback) { return cached || fallback; },
    async put(_key, value) { cached = value; },
    async flush() {
      if (failFlush) { const error = failFlush; failFlush = null; throw error; }
      persisted = cached;
    }
  };
  const load = createEtsLoader({ kits: { '@kit.ArkData': { preferences: { getPreferences: async () => raw } } } });
  const { PreferencesStore } = load('entry/src/main/ets/storage/PreferencesStore.ets');
  const { CredentialVault } = load('entry/src/main/ets/storage/CredentialVault.ets');
  const keys = new Set(); let nextId = 0;
  // Cipher behavior is isolated here; the device probe exercises real HUKS.
  const cipher = {
    newId: () => 'fixture-' + ++nextId,
    async seal(id) { keys.add(id); return { nonce: 'A'.repeat(16), ciphertext: 'A'.repeat(32) }; },
    async open(id) { if (!keys.has(id)) throw new Error('missing alias'); return new Uint8Array([1, 2, 3]); },
    async remove(id) { keys.delete(id); }
  };
  return { raw, cipher, keys, CredentialVault, open: () => PreferencesStore.open({}, 'isolated-fixture'),
    failNextFlush(error = new Error('flush failed')) { failFlush = error; },
    get cached() { return cached; }, get persisted() { return persisted; } };
}
const info = { publicKey: 'ssh-ed25519 fixture', fingerprint: 'SHA256:fixture' };

test('a failed flush restores the cache seen by newly opened preference stores', async () => {
  const f = fixture(), store = await f.open(); await store.write('committed');
  const error = new Error('disk full'); f.failNextFlush(error);
  await assert.rejects(store.write('uncommitted'), value => value === error);
  assert.equal(await (await f.open()).read(), 'committed');
  await f.raw.flush(); assert.equal(f.persisted, 'committed');
  await store.write('retry'); assert.equal(f.persisted, 'retry');
});

test('a failed credential save cannot leave a cached record whose HUKS alias was removed', async () => {
  const f = fixture(), vault = new f.CredentialVault(await f.open(), f.cipher); await vault.load();
  f.failNextFlush(); await assert.rejects(vault.save('fixture', new Uint8Array([1, 2, 3]), info));
  assert.equal(f.keys.size, 0);
  const restarted = new f.CredentialVault(await f.open(), f.cipher); await restarted.load();
  assert.equal(restarted.list().length, 0);
});

test('failed credential deletion preserves the cached record and its decryption key', async () => {
  const f = fixture(), vault = new f.CredentialVault(await f.open(), f.cipher); await vault.load();
  const id = await vault.save('fixture', new Uint8Array([1, 2, 3]), info);
  f.failNextFlush(); await assert.rejects(vault.remove(id));
  const restarted = new f.CredentialVault(await f.open(), f.cipher); await restarted.load();
  assert.equal(restarted.list().length, 1); assert.equal(f.keys.has(id), true);
  assert.deepEqual([...await restarted.read(id)], [1, 2, 3]);
});

test('rollback cannot overwrite a later successful concurrent write', async () => {
  const f = fixture(), store = await f.open(); await store.write('committed');
  const originalFlush = f.raw.flush;
  let rejectFirst, entered;
  const started = new Promise(resolve => { entered = resolve; });
  let first = true;
  f.raw.flush = async () => {
    if (first) { first = false; entered(); await new Promise((_resolve, reject) => { rejectFirst = reject; }); }
    else await originalFlush();
  };
  const a = store.write('first'); const failed = assert.rejects(a);
  await started;
  const b = store.write('second'); await flushTasks();
  rejectFirst(new Error('first flush failed'));
  await failed; await b;
  assert.equal(await store.read(), 'second'); assert.equal(f.persisted, 'second');
});

test('failed cache rollback prevents later reads or writes from exposing or persisting the failed value', async () => {
  const f = fixture(), store = await f.open(); await store.write('committed');
  const originalPut = f.raw.put; let calls = 0;
  f.raw.put = async (...args) => {
    if (++calls > 1) throw new Error('cache unavailable');
    await originalPut(...args);
  };
  const error = new Error('flush failed'); f.failNextFlush(error);
  await assert.rejects(store.write('uncommitted'), value => value === error);
  await assert.rejects(store.read()); await assert.rejects(store.write('later'));
  assert.equal(calls, 2); assert.equal(f.persisted, 'committed');
});

test('deleting an already missing HUKS alias succeeds while other HUKS errors remain failures', async () => {
  let failure; const deleted = [];
  const load = createEtsLoader({ kits: { '@kit.UniversalKeystoreKit': { huks: {
    async deleteKeyItem(alias) { deleted.push(alias); if (failure) throw failure; }
  } } } });
  const { HuksCredentialCipher } = load('entry/src/main/ets/storage/HuksCredentialCipher.ets');
  const cipher = new HuksCredentialCipher();
  failure = { code: 12000011 }; await cipher.remove('missing');
  for (const code of [201, 12000004, 12000005, 12000012]) {
    failure = { code }; await assert.rejects(cipher.remove('locked'), error => error === failure);
  }
  failure = null; await cipher.remove('present');
  assert.ok(deleted.every(alias => alias.startsWith('hterminal-import-')));
});
