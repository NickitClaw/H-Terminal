const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createEtsLoader } = require('./support/harness.cjs');
const { CredentialVault } = createEtsLoader()('entry/src/main/ets/storage/CredentialVault.ets');

function fixture() {
  let data = '';
  const keys = new Map();
  const cipher = {
    newId: () => crypto.randomUUID(),
    async seal(id, bytes, aad) {
      const key = crypto.randomBytes(32), nonce = crypto.randomBytes(12);
      keys.set(id, key);
      const enc = crypto.createCipheriv('aes-256-gcm', key, nonce); enc.setAAD(Buffer.from(aad));
      return { nonce: nonce.toString('base64'),
        ciphertext: Buffer.concat([enc.update(bytes), enc.final(), enc.getAuthTag()]).toString('base64') };
    },
    async open(id, sealed, aad) {
      const raw = Buffer.from(sealed.ciphertext, 'base64');
      const dec = crypto.createDecipheriv('aes-256-gcm', keys.get(id), Buffer.from(sealed.nonce, 'base64'));
      dec.setAAD(Buffer.from(aad)); dec.setAuthTag(raw.subarray(-16));
      return new Uint8Array(Buffer.concat([dec.update(raw.subarray(0, -16)), dec.final()]));
    },
    async remove(id) { keys.delete(id); }
  };
  const store = { async read() { return data; }, async write(text) { data = text; } };
  return { store, cipher, keys, get data() { return data; }, set data(value) { data = value; } };
}
const info = { publicKey: 'ssh-ed25519 fixture', fingerprint: 'SHA256:fixture' };

test('vault restarts, exposes only public metadata and deletes protected credentials', async () => {
  const f = fixture(); const vault = new CredentialVault(f.store, f.cipher); await vault.load();
  const id = await vault.save('key', new Uint8Array(Buffer.from('private fixture material')), info);
  assert.equal(f.data.includes('private fixture material'), false);
  assert.equal(vault.list()[0].ciphertext, '');
  const restarted = new CredentialVault(f.store, f.cipher); await restarted.load();
  assert.equal(Buffer.from(await restarted.read(id)).toString(), 'private fixture material');
  await restarted.remove(id);
  assert.equal(f.keys.size, 0);
  await assert.rejects(restarted.read(id));
});

test('tampered ciphertext and swapped identity metadata fail authentication', async () => {
  const f = fixture(); const vault = new CredentialVault(f.store, f.cipher); await vault.load();
  const id = await vault.save('key', new Uint8Array([1, 2, 3]), info);
  const doc = JSON.parse(f.data); doc.credentials[0].fingerprint = 'SHA256:changed'; f.data = JSON.stringify(doc);
  const restarted = new CredentialVault(f.store, f.cipher); await restarted.load();
  await assert.rejects(restarted.read(id));
});

test('failed vault persistence removes the newly generated HUKS alias and permits retry', async () => {
  const f = fixture(); const original = f.store.write; let fail = true;
  f.store.write = async text => { if (fail) { fail = false; throw new Error('disk full'); } await original(text); };
  const vault = new CredentialVault(f.store, f.cipher); await vault.load();
  await assert.rejects(vault.save('fixture', new Uint8Array([1, 2]), info));
  assert.equal(f.keys.size, 0); assert.equal(vault.list().length, 0);
  const id = await vault.save('retry', new Uint8Array([3]), info);
  assert.deepEqual([...await vault.read(id)], [3]);
});

test('failed deletion persistence preserves the old protected credential', async () => {
  const f = fixture(); const vault = new CredentialVault(f.store, f.cipher); await vault.load();
  const id = await vault.save('fixture', new Uint8Array([1, 2]), info);
  f.store.write = async () => { throw new Error('disk unavailable'); };
  await assert.rejects(vault.remove(id));
  assert.equal(f.keys.size, 1); assert.equal(vault.list().length, 1);
  assert.deepEqual([...await vault.read(id)], [1, 2]);
});

test('unrecognized vault data is never overwritten by save or delete', async () => {
  const f = fixture(); f.data = '{"version":99,"credentials":[]}';
  f.store.write = () => assert.fail('must preserve unrecognized storage');
  const vault = new CredentialVault(f.store, f.cipher);
  await assert.rejects(vault.load()); await assert.rejects(vault.save('fixture', new Uint8Array([1]), info));
  await assert.rejects(vault.remove('missing')); assert.equal(f.keys.size, 0);
});
