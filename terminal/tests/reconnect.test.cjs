const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader } = require('./support/harness.cjs');
const { ReconnectPolicy } = createEtsLoader()('entry/src/main/ets/lifecycle/ReconnectPolicy.ets');

test('auto reconnect defaults off and only schedules at most five network retries', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const policy = new ReconnectPolicy(() => .5); const scheduled = []; let retries = 0;
  policy.onRetry = () => { retries++; };
  policy.onScheduled = (attempt, delay) => scheduled.push([attempt, delay]);
  policy.failed('network'); t.mock.timers.tick(100000); assert.equal(retries, 0);
  policy.configure(true);
  for (const reason of ['authentication', 'hostkey', 'protocol', 'renderer', 'closed']) {
    policy.failed(reason); t.mock.timers.tick(100000); assert.equal(retries, 0);
  }
  for (const delay of [1000, 2000, 4000, 8000, 16000]) {
    policy.failed('network'); t.mock.timers.tick(delay - 1); assert.equal(retries, scheduled.length - 1);
    t.mock.timers.tick(1);
  }
  policy.failed('network'); t.mock.timers.tick(100000); assert.equal(retries, 5);
  assert.deepEqual(scheduled.map(x => x[1]), [1000, 2000, 4000, 8000, 16000]);
});

test('network/background/tab suspension invalidates timers and resumes one pending retry', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const policy = new ReconnectPolicy(() => .5); let retries = 0;
  policy.configure(true); policy.onRetry = () => { retries++; };
  policy.failed('network'); t.mock.timers.tick(500); policy.setAvailable(false);
  t.mock.timers.tick(10000); assert.equal(retries, 0); assert.equal(policy.count(), 0);
  policy.setAvailable(true); t.mock.timers.tick(1000); assert.equal(retries, 1);
  policy.failed('network'); policy.stop(); t.mock.timers.tick(100000); assert.equal(retries, 1);
});

test('disabling or a non-network failure cancels pending retry and carries no credentials', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const policy = new ReconnectPolicy(() => 0); policy.configure(true); let retries = 0;
  policy.onRetry = () => { retries++; };
  policy.failed('network'); policy.failed('authentication'); t.mock.timers.tick(100000); assert.equal(retries, 0);
  policy.failed('network'); policy.configure(false); t.mock.timers.tick(100000); assert.equal(retries, 0);
  assert.equal(policy.pending(), false);
});
