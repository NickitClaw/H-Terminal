const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');

function fixture() {
  const calls = { connect: [], close: [], write: [], reload: 0 };
  let onNativeEvent;
  const native = {
    initialize(callback) { onNativeEvent = callback; },
    connect(options) { calls.connect.push({ ...options }); },
    closeSession(...args) { calls.close.push(args); },
    writeInput(request) { calls.write.push(request); return true; },
    resize() {}, acknowledgeOutput() {}
  };
  const load = createEtsLoader({ native });
  const { XtermBackend } = load('entry/src/main/ets/terminal/XtermBackend.ets');
  const { SessionController } = load('entry/src/main/ets/terminal/SessionController.ets');
  const { SessionSnapshot } = load('entry/src/main/ets/model/SessionModel.ets');
  const backend = new XtermBackend();
  const controller = new SessionController(backend);
  let snapshot = new SessionSnapshot();
  controller.onSnapshot = (value) => { snapshot = value; };
  const web = createTerminalHarness((message) => controller.handleTerminalMessage(JSON.stringify(message)));
  backend.setSender((message) => web.receive(message));
  backend.setReloader(() => { calls.reload++; });
  controller.initialize('/isolated-fixture');
  return {
    calls, controller, backend, web, emitNative: (event) => onNativeEvent(event),
    get snapshot() { return snapshot; },
    open() {
      assert.equal(controller.connect('127.0.0.1', 22224, 'review', 'review'), true);
      const options = calls.connect.at(-1);
      onNativeEvent({ type: 'state', state: 'OPEN', ...options });
      assert.equal(snapshot.inputEnabled, true);
    }
  };
}

test('renderer reload waits for its generation and measured size before reconnecting', () => {
  const f = fixture();
  f.controller.handleTerminalMessage(JSON.stringify({ type: 'ready' }));
  assert.equal(f.snapshot.terminalReady, false);
  f.backend.markWebReady();
  assert.equal(f.snapshot.terminalReady, true);
  f.open();
  const oldReady = f.web.messages.filter((message) => message.type === 'ready').at(-1);
  f.controller.handleRendererFailure('renderer exited');
  assert.equal(f.snapshot.state, 'FAILED');
  assert.equal(f.snapshot.terminalReady, false);
  assert.equal(f.calls.close.length, 1);
  f.controller.handleTerminalMessage(JSON.stringify(oldReady));
  assert.equal(f.snapshot.terminalReady, false);
  assert.equal(f.controller.recoverTerminal(), true);
  assert.equal(f.calls.reload, 1);
  assert.equal(f.snapshot.inputEnabled, false);
  assert.equal(f.controller.connect('127.0.0.1', 22224, 'review', 'review'), false);
  f.controller.handleTerminalMessage(JSON.stringify(oldReady));
  assert.equal(f.snapshot.terminalReady, false);
  // Equivalent to the new Web page's onPageEnd: queued init reaches the page,
  // which measures its terminal and returns an identity-scoped ready event.
  f.backend.markWebReady();
  assert.equal(f.snapshot.terminalReady, true);
  assert.equal(f.snapshot.message, '终端已重新加载，请连接');
  f.open();
  const newOptions = f.calls.connect.at(-1);
  assert.equal(newOptions.terminalGeneration, oldReady.terminalGeneration + 1);
  assert.equal(newOptions.connectionEpoch, oldReady.connectionEpoch + 1);
  assert.equal(newOptions.cols, 80);
  assert.equal(newOptions.rows, 24);
  f.controller.handleTerminalMessage(JSON.stringify({
    ...oldReady, type: 'input', inputEpoch: 1, eventId: 'late-input', data: 'WA=='
  }));
  f.controller.handleTerminalMessage(JSON.stringify({ ...oldReady, type: 'ready' }));
  assert.equal(f.calls.write.length, 0);
  assert.equal(f.snapshot.inputEnabled, true);
});

test('reload failure can be retried without restarting the app', () => {
  const f = fixture();
  f.backend.markWebReady();
  f.controller.handleRendererFailure('renderer exited');
  f.backend.setReloader(() => { throw new Error('refresh failed'); });
  assert.equal(f.controller.recoverTerminal(), false);
  assert.equal(f.snapshot.state, 'FAILED');
  assert.equal(f.snapshot.terminalReady, false);
  f.backend.setReloader(() => { f.calls.reload++; });
  assert.equal(f.controller.recoverTerminal(), true);
  f.backend.markWebReady();
  assert.equal(f.snapshot.terminalReady, true);
  f.open();
});

test('healthy terminal cannot be reset through the failure recovery action', () => {
  const f = fixture();
  f.backend.markWebReady();
  f.open();
  assert.equal(f.controller.recoverTerminal(), false);
  assert.equal(f.calls.reload, 0);
  assert.equal(f.calls.close.length, 0);
  assert.equal(f.snapshot.inputEnabled, true);
});

test('identity-scoped ready still needs valid terminal measurements', () => {
  const f = fixture();
  const identity = { sessionId: 'session-1', connectionEpoch: 0, terminalGeneration: 1 };
  f.controller.handleTerminalMessage(JSON.stringify({ type: 'ready', ...identity }));
  assert.equal(f.snapshot.terminalReady, false);
  f.controller.handleTerminalMessage(JSON.stringify({ type: 'resize', ...identity, cols: 0, rows: 0 }));
  assert.equal(f.snapshot.terminalReady, false);
  f.controller.handleTerminalMessage(JSON.stringify({ type: 'resize', ...identity, cols: 80, rows: 24 }));
  assert.equal(f.snapshot.terminalReady, true);
});

test('reconnect waits for the old write and fresh identity readiness before accepting keys', () => {
  const f = fixture();
  f.backend.markWebReady();
  f.open();
  const oldReady = f.web.messages.filter((message) => message.type === 'ready').at(-1);
  let finishWrite;
  f.web.terminal.write = (_bytes, callback) => { finishWrite = callback; };
  f.emitNative({ ...f.calls.connect.at(-1), type: 'output', seq: 1, byteLength: 1, data: 'WA==' });
  assert.equal(typeof finishWrite, 'function');
  f.controller.disconnect();
  assert.equal(f.controller.connect('127.0.0.1', 22224, 'review', 'review'), true);
  const options = f.calls.connect.at(-1);
  assert.equal(options.cols, 80);
  f.emitNative({ ...options, type: 'state', state: 'OPEN' });
  assert.equal(f.snapshot.terminalReady, false);
  assert.equal(f.snapshot.inputEnabled, false);
  f.controller.handleTerminalMessage(JSON.stringify(oldReady));
  f.controller.handleTerminalMessage(JSON.stringify({ ...oldReady, type: 'resize', cols: 80, rows: 24 }));
  assert.equal(f.snapshot.inputEnabled, false);
  const key = { kind: 'key', id: 'ArrowUp' };
  f.controller.routeKey(key);
  assert.equal(f.calls.write.length, 0);
  finishWrite();
  assert.equal(f.snapshot.terminalReady, true);
  assert.equal(f.snapshot.inputEnabled, true);
  f.controller.routeKey(key);
  assert.equal(f.calls.write.length, 1);
  assert.equal(f.calls.write[0].connectionEpoch, options.connectionEpoch);
  assert.equal(Buffer.from(f.calls.write[0].data, 'base64').toString(), '\x1b[A');
});
