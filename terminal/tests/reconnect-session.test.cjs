const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');
function fixture() {
  let emit; const calls = { connect: [], writes: [], close: [], answers: [] }; let credit = false;
  const native = { initialize: callback => { emit = callback; }, dispose() {}, resize() {}, acknowledgeOutput() {},
    connect: options => calls.connect.push({ ...options }), closeSession: (...args) => calls.close.push(args),
    writeInput: request => { if (!credit) return false; calls.writes.push(request); return true; },
    answerAuthentication: (...args) => calls.answers.push(args), resetInput() {} };
  const load = createEtsLoader({ native }); const { SessionController } = load('entry/src/main/ets/terminal/SessionController.ets');
  const { XtermBackend } = load('entry/src/main/ets/terminal/XtermBackend.ets');
  const backend = new XtermBackend(), session = new SessionController(backend);
  const web = createTerminalHarness(message => session.handleTerminalMessage(JSON.stringify(message)));
  backend.setSender(message => web.receive(message)); session.initialize('/isolated'); backend.markWebReady();
  session.connect('fixture.test', 22, 'review', 'must-never-be-retained');
  emit({ ...calls.connect[0], type: 'state', state: 'OPEN' });
  session.onReconnectRequested = () => session.connect('fixture.test', 22, 'review', '', 'password', '', true);
  return { session, calls, emit, credit: () => { credit = true; } };
}

test('a real controller retry uses a fresh connection epoch, requests credentials and never replays queued input', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] }); const f = fixture();
  try {
    f.session.setAutoReconnect(true);
    f.session.routeKey({ kind: 'key', id: 'Enter' }); assert.equal(f.calls.writes.length, 0);
    f.emit({ ...f.calls.connect[0], type: 'error', code: 'network', message: 'connection reset' });
    assert.equal(f.session.getSnapshot().retrying, true);
    t.mock.timers.tick(1200);
    assert.equal(f.calls.connect.length, 2);
    assert.equal(f.calls.connect[1].password, ''); assert.equal(f.calls.connect[1].privateKey, '');
    assert.equal(f.calls.connect[1].promptForSecret, true); assert.equal(f.calls.connect[1].connectionEpoch, 2);
    f.emit({ ...f.calls.connect[0], type: 'state', state: 'OPEN' });
    assert.notEqual(f.session.getSnapshot().state, 'OPEN');
    f.emit({ ...f.calls.connect[1], type: 'state', state: 'OPEN' }); f.credit();
    f.emit({ ...f.calls.connect[1], type: 'inputCredit' }); assert.equal(f.calls.writes.length, 0);
    f.session.routeKey({ kind: 'key', id: 'Enter' });
    assert.equal(f.calls.writes.length, 1); assert.equal(f.calls.writes[0].connectionEpoch, 2);
  } finally { f.session.dispose(); }
});

test('real controllers do not retry authentication/host trust failures or user disconnect', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  for (const code of ['authentication', 'hostkey', 'protocol']) {
    const f = fixture();
    try {
      f.session.setAutoReconnect(true); f.emit({ ...f.calls.connect[0], type: 'error', code, message: code });
      t.mock.timers.tick(100000); assert.equal(f.calls.connect.length, 1);
    } finally { f.session.dispose(); }
  }
  const f = fixture();
  try {
    f.session.setAutoReconnect(true); f.emit({ ...f.calls.connect[0], type: 'error', code: 'network' });
    f.session.disconnect(); t.mock.timers.tick(100000); assert.equal(f.calls.connect.length, 1);
  } finally { f.session.dispose(); }
});

test('stopping while an asynchronous retry is preparing clears the retry indicator', t => {
  t.mock.timers.enable({ apis: ['setTimeout'] }); const f = fixture();
  try {
    f.session.onReconnectRequested = () => {}; // A vault read is still pending.
    f.session.setAutoReconnect(true);
    f.emit({ ...f.calls.connect[0], type: 'error', code: 'network' });
    t.mock.timers.tick(1200);
    f.session.cancelReconnect();
    assert.equal(f.session.getSnapshot().retrying, false);
    assert.equal(f.calls.connect.length, 1);
  } finally { f.session.dispose(); }
});
