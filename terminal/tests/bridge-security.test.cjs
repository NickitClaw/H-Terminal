const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');
function fixture() {
  let emit, options; const calls = { resize: [], ack: [], input: [] };
  const native = { initialize: cb => { emit = cb; }, dispose() {}, closeSession() {},
    connect(value) { options = { ...value }; },
    resize(...args) { assert.ok(Number.isSafeInteger(args[2]) && Number.isSafeInteger(args[3])); calls.resize.push(args); },
    acknowledgeOutput(value) { assert.ok(Number.isSafeInteger(value.seq) && Number.isSafeInteger(value.byteLength)); calls.ack.push(value); },
    writeInput(value) { calls.input.push(value); return true; } };
  const load = createEtsLoader({ native }); const { SessionController } = load('entry/src/main/ets/terminal/SessionController.ets');
  const { XtermBackend } = load('entry/src/main/ets/terminal/XtermBackend.ets');
  const backend = new XtermBackend(), controller = new SessionController(backend);
  const web = createTerminalHarness(message => controller.handleTerminalMessage(JSON.stringify(message)));
  backend.setSender(message => web.receive(message)); controller.initialize('/isolated'); backend.markWebReady();
  controller.connect('fixture.test', 22, 'review', 'secret'); emit({ ...options, type: 'state', state: 'OPEN' });
  calls.resize.length = 0;
  const identity = { sessionId: 'session-1', connectionEpoch: 1, terminalGeneration: 1 };
  return { controller, calls, identity };
}

test('bridge rejects primitive roots, oversize JSON and malformed metadata without throwing', () => {
  const f = fixture();
  try {
    for (const raw of ['null', 'true', '42', '"primitive"', '[]', '{}', '{', ' '.repeat(1500001)]) {
      assert.doesNotThrow(() => f.controller.handleTerminalMessage(raw));
    }
    for (const eventId of [1, {}, [], 'x'.repeat(129), '']) {
      f.controller.handleTerminalMessage(JSON.stringify({ ...f.identity, type: 'input', inputEpoch: f.controller.input.getInputEpoch(), eventId, data: 'QQ==' }));
    }
    assert.equal(f.calls.input.length, 0);
  } finally { f.controller.dispose(); }
});

test('resize and ACK require bounded integer numbers and never coerce strings or objects', () => {
  const f = fixture();
  try {
    for (const value of ['80', 'bad', {}, [], 1.2, -1, 0, 1001, 1e300]) {
      assert.doesNotThrow(() => f.controller.handleTerminalMessage(JSON.stringify({ ...f.identity, type: 'resize', cols: value, rows: 24 })));
    }
    for (const [seq, byteLength] of [['1', 4], [1, '4'], [{}, 2], [1.2, 4], [1, 0], [1, 32769], [Number.MAX_VALUE, 4]]) {
      assert.doesNotThrow(() => f.controller.handleTerminalMessage(JSON.stringify({ ...f.identity, type: 'ack', seq, byteLength })));
    }
    assert.equal(f.calls.resize.length, 0); assert.equal(f.calls.ack.length, 0);
    assert.equal(f.controller.getSnapshot().state, 'OPEN');
  } finally { f.controller.dispose(); }
});

test('the advertised full 1MiB paste boundary works without regular-expression stack exhaustion', () => {
  const web = createTerminalHarness(); const identity = { sessionId: 'one', connectionEpoch: 1, terminalGeneration: 1 };
  web.receive({ type: 'init', ...identity, inputEpoch: 1 });
  const data = Buffer.alloc(1024 * 1024, 'A').toString('base64');
  assert.equal(web.receive({ type: 'paste', ...identity, inputEpoch: 1, eventId: 'large', data }), true);
  assert.equal(web.messages.at(-1).type, 'paste');
  assert.equal(Buffer.from(web.messages.at(-1).data, 'base64').length, 1024 * 1024);
  assert.equal(web.receive({ type: 'paste', ...identity, inputEpoch: 1, eventId: 'too-large', data: data + 'AAAA' }), false);
});

test('only the bundled document may own the proxy; resource paths cannot escape the allowlist', () => {
  const { TerminalPagePolicy: policy } = createEtsLoader()('entry/src/main/ets/terminal/TerminalPagePolicy.ets');
  assert.equal(policy.allows('resource://RAWFILE/terminal/index.html', true), true);
  assert.equal(policy.allows('resource:/RAWFILE/terminal/vendor/xterm.js', false), true);
  for (const url of ['https://example.test', 'http://example.test', 'file:///data/private',
    'data:text/html,test', 'javascript:alert(1)', 'about:blank', 'resource://RAWFILE/other.html',
    'resource://RAWFILE/terminal/../other.html', 'resource://RAWFILE/terminal/%2e%2e/other.html',
    'resource://RAWFILE/terminal/index.html?other', 'resource://RAWFILE/terminal/index.html#other']) {
    assert.equal(policy.allows(url, true), false, url);
    assert.equal(policy.allows(url, false), false, url);
  }
  assert.equal(policy.allows('resource://RAWFILE/terminal/terminal.js', true), false);
});

test('2,000 deterministic malformed envelopes cannot crash or invoke privileged native methods', () => {
  const f = fixture();
  let seed = 0x547e2;
  const random = n => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % n; };
  const values = [null, false, true, -1, 0, 1, 1.2, Number.MAX_VALUE, '', 'value', [], {}, { nested: true }];
  const kinds = ['input', 'paste', 'resize', 'ack', 'ready', 'error', 'copy', 'pasteRequest', 'connect', 'readFile', 'inspectPrivateKey'];
  try {
    for (let i = 0; i < 2000; i++) {
      const message = { ...f.identity, type: kinds[random(kinds.length)] };
      for (const field of ['cols', 'rows', 'seq', 'byteLength', 'eventId', 'inputEpoch', 'data', 'fatal', 'protocolVersion']) {
        message[field] = values[random(values.length)];
      }
      message.fatal = false;
      assert.doesNotThrow(() => f.controller.handleTerminalMessage(JSON.stringify(message)));
    }
    assert.equal(f.calls.input.length, 0);
  } finally { f.controller.dispose(); }
});

test('diagnostic projection contains counters without profiles, private input or authentication data', () => {
  const f = fixture();
  try {
    const report = f.controller.diagnostics();
    assert.doesNotThrow(() => JSON.parse(report));
    for (const secret of ['secret', 'fixture.test', 'privateKey', 'password', 'username']) assert.equal(report.includes(secret), false);
  } finally { f.controller.dispose(); }
});
