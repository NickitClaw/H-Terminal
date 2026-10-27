const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');

function fixture() {
  let emit, snapshot, connection;
  const probes = [], writes = [], closes = [];
  const native = {
    initialize(callback) { emit = callback; }, connect(options) { connection = { ...options }; },
    probeSession(...args) { probes.push(args); }, closeSession(...args) { closes.push(args); },
    resetInput(_id, _epoch, inputEpoch) { emit({ ...connection, type: 'inputReset', inputEpoch }); },
    writeInput(request) { writes.push(request); return true; },
    resize() {}, acknowledgeOutput() {}, dispose() {}
  };
  const load = createEtsLoader({ native });
  const { XtermBackend } = load('entry/src/main/ets/terminal/XtermBackend.ets');
  const { SessionController } = load('entry/src/main/ets/terminal/SessionController.ets');
  const backend = new XtermBackend(), session = new SessionController(backend);
  const web = createTerminalHarness(message => session.handleTerminalMessage(JSON.stringify(message)));
  backend.setSender(message => web.receive(message));
  session.onSnapshot = value => { snapshot = value; };
  session.initialize('/isolated'); backend.markWebReady();
  assert.equal(session.connect('localhost', 22, 'review', 'review'), true);
  emit({ ...connection, type: 'state', state: 'OPEN' });
  return { session, probes, writes, closes, get snapshot() { return snapshot; },
    respond(requestId) { emit({ ...connection, type: 'probe', requestId }); } };
}

test('foreground restoration needs a current server response before input resumes', () => {
  const f = fixture();
  try {
    f.session.setForeground(false);
    assert.equal(f.snapshot.inputEnabled, false);
    f.session.routeKey({ kind: 'key', id: 'Enter' });
    assert.equal(f.writes.length, 0);
    f.session.setForeground(true);
    assert.equal(f.snapshot.checking, true);
    const request = f.probes.at(-1)[2];
    f.respond(request - 1);
    assert.equal(f.snapshot.inputEnabled, false);
    f.respond(request);
    assert.equal(f.snapshot.inputEnabled, true);
    f.session.routeKey({ kind: 'key', id: 'Enter' });
    assert.equal(f.writes.length, 1);
  } finally { f.session.dispose(); }
});

test('network loss and another background transition invalidate an outstanding check', () => {
  const f = fixture();
  try {
    f.session.setNetworkAvailable(false);
    assert.equal(f.snapshot.inputEnabled, false);
    f.session.setNetworkAvailable(true);
    const first = f.probes.at(-1)[2];
    f.session.setForeground(false);
    f.respond(first);
    assert.equal(f.snapshot.inputEnabled, false);
    f.session.setForeground(true);
    const second = f.probes.at(-1)[2];
    assert.notEqual(first, second);
    f.respond(first); assert.equal(f.snapshot.inputEnabled, false);
    f.respond(second); assert.equal(f.snapshot.inputEnabled, true);
  } finally { f.session.dispose(); }
});

test('duplicate initial availability is harmless and an idle connection is checked without a network event', () => {
  const f = fixture();
  try {
    f.session.setNetworkAvailable(true);
    assert.equal(f.probes.length, 0);
    assert.equal(f.snapshot.inputEnabled, true);
    f.session.checkIdleConnection(Date.now() + 31000);
    assert.equal(f.snapshot.checking, true);
    f.respond(f.probes.at(-1)[2]);
    assert.equal(f.snapshot.inputEnabled, true);
    f.session.checkIdleConnection();
    assert.equal(f.probes.length, 1);
  } finally { f.session.dispose(); }
});

test('idle checks do not interrupt an in-progress paste', () => {
  const f = fixture();
  try {
    f.session.paste('still sending', f.session.getSessionId(), f.session.getConnectionEpoch(), f.session.input.getInputEpoch());
    assert.equal(f.snapshot.pasting, true);
    f.session.checkIdleConnection(Date.now() + 31000);
    assert.equal(f.probes.length, 0);
  } finally { f.session.dispose(); }
});
