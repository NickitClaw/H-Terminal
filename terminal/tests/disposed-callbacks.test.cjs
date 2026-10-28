const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');

test('disposed controllers cannot trust, close or write to a new workspace reusing the same session identity', () => {
  let emit; const calls = { close: [], trust: [], input: [], connect: [] };
  const native = { initialize: callback => { emit = callback; }, dispose() {}, resize() {}, acknowledgeOutput() {},
    connect: options => calls.connect.push({ ...options }), closeSession: (...args) => calls.close.push(args),
    trustDecision: (...args) => calls.trust.push(args), writeInput: value => { calls.input.push(value); return true; } };
  const load = createEtsLoader({ native }); const { XtermBackend } = load('entry/src/main/ets/terminal/XtermBackend.ets');
  const { SessionController } = load('entry/src/main/ets/terminal/SessionController.ets');
  const create = () => {
    const backend = new XtermBackend(), session = new SessionController(backend);
    const page = createTerminalHarness(message => session.handleTerminalMessage(JSON.stringify(message)));
    backend.setSender(message => page.receive(message)); session.initialize('/isolated'); backend.markWebReady();
    session.connect('fixture.test', 22, 'review', 'review');
    emit({ ...calls.connect.at(-1), type: 'state', state: 'OPEN' }); return session;
  };
  const old = create(); old.getSnapshot().state = 'VERIFYING_HOST'; old.dispose();
  const current = create(); const closes = calls.close.length;
  try {
    old.trust(true); old.disconnect(); old.handleRendererFailure('late renderer callback');
    old.handleTerminalMessage(JSON.stringify({ type: 'error', fatal: true, sessionId: 'session-1', connectionEpoch: 1, terminalGeneration: 1 }));
    assert.equal(calls.close.length, closes); assert.equal(calls.trust.length, 0); assert.equal(calls.input.length, 0);
    assert.equal(current.getSnapshot().state, 'OPEN');
  } finally { current.dispose(); }
});
