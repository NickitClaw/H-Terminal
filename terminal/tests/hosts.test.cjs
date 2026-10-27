const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader } = require('./support/harness.cjs');
const { HostRepository, HostProfile, UserPreferences } = createEtsLoader()('entry/src/main/ets/storage/HostRepository.ets');
function host() { return Object.assign(new HostProfile(), { host: 'example.test', username: 'review', port: 22 }); }

test('hosts and preferences survive restart without serializing credentials or unknown fields', async () => {
  let data = '';
  const store = { async read() { return data; }, async write(text) { data = text; } };
  const repo = new HostRepository(store); await repo.load();
  await repo.saveHost({ ...host(), password: 'must-not-persist', privateKey: 'must-not-persist' });
  const saved = repo.list()[0];
  await repo.saveHost({ ...saved, name: 'renamed', port: 2200 });
  await repo.savePreferences(Object.assign(new UserPreferences(), { keyboardMode: 'full', layout: 'laptop' }));
  assert.equal(data.includes('must-not-persist'), false);
  const restarted = new HostRepository(store); await restarted.load();
  assert.equal(restarted.list().length, 1);
  assert.equal(restarted.list()[0].port, 2200);
  assert.equal(restarted.preferences().layout, 'laptop');
  await restarted.deleteHost(saved.id);
  assert.equal(JSON.parse(data).hosts.length, 0);
});

test('concurrent writes serialize and failed persistence rolls back without poisoning later saves', async () => {
  let fail = true, data = '';
  const repo = new HostRepository({ async read() { return ''; }, async write(text) {
    if (fail) { fail = false; throw new Error('disk unavailable'); } data = text;
  } });
  await repo.load();
  await assert.rejects(repo.saveHost(host()));
  assert.equal(repo.list().length, 0);
  await Promise.all([repo.saveHost(host()), repo.saveHost(host())]);
  assert.equal(JSON.parse(data).hosts.length, 2);
});

test('corrupt or future settings cannot be silently overwritten', async () => {
  const repo = new HostRepository({ async read() { return '{"version":99,"hosts":[]}'; },
    async write() { assert.fail('must preserve the unrecognized data'); } });
  await assert.rejects(repo.load());
  await assert.rejects(repo.saveHost(host()));
});
