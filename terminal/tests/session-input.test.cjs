const test = require('node:test');
const assert = require('node:assert/strict');
const { createEtsLoader, createTerminalHarness } = require('./support/harness.cjs');

function fixture(automatic = false) {
  let emit, connection, snapshot;
  const writes = [], resets = [], answers = [];
  const native = {
    initialize(callback) { emit = callback; }, dispose() {}, closeSession() {}, resize() {}, acknowledgeOutput() {},
    connect(options) { connection = { ...options }; },
    resetInput(...args) { resets.push(args); },
    answerAuthentication(_id, _epoch, requestId, values) { answers.push({ requestId, values: values.slice(), raw: values }); },
    writeInput(request) {
      writes.push({ ...request });
      if (automatic && request.pastePhase) queueMicrotask(() => emit({ ...connection, type: 'inputConsumed',
        inputEpoch: request.inputEpoch, eventId: request.eventId, byteLength: Buffer.from(request.data, 'base64').length }));
      return true;
    }
  };
  const load = createEtsLoader({ native });
  const { XtermBackend } = load('entry/src/main/ets/terminal/XtermBackend.ets');
  const { SessionController } = load('entry/src/main/ets/terminal/SessionController.ets');
  const backend = new XtermBackend(), session = new SessionController(backend);
  const web = createTerminalHarness(message => session.handleTerminalMessage(JSON.stringify(message)));
  backend.setSender(message => web.receive(message));
  session.onSnapshot = value => { snapshot = value; };
  session.initialize('/isolated'); backend.markWebReady();
  session.connect('localhost', 22227, 'review', 'review');
  emit({ ...connection, type: 'state', state: 'OPEN' });
  web.terminal.modes.bracketedPasteMode = true;
  return { session, web, writes, resets, answers, get snapshot() { return snapshot; },
    emit(event) { emit({ ...connection, ...event }); },
    paste(text) { session.paste(text, session.getSessionId(), session.getConnectionEpoch(), session.input.getInputEpoch()); }
  };
}

test('real terminal script and controller stream a paste only as native consumption advances', async () => {
  const f = fixture(true);
  try {
    const text = '你好🙂'.repeat(10000);
    f.paste(text);
    assert.equal(f.writes.length, 1);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.snapshot.pasting, false);
    assert.equal(Buffer.concat(f.writes.map(value => Buffer.from(value.data, 'base64'))).toString(),
      '\x1b[200~' + text + '\x1b[201~');
    assert.equal(f.writes.filter(value => value.pastePhase === 'start').length, 1);
    assert.equal(f.writes.filter(value => value.pastePhase === 'end').length, 1);
  } finally { f.session.dispose(); }
});

test('Ctrl+C stops pending paste immediately and stale consumed/reset events cannot resume it', () => {
  const f = fixture();
  try {
    f.paste('你'.repeat(10000));
    const start = f.writes[0];
    f.emit({ type: 'inputConsumed', inputEpoch: start.inputEpoch, eventId: start.eventId, byteLength: 6 });
    assert.equal(f.writes.length, 2);
    const body = f.writes[1];
    f.session.routeKey({ kind: 'modifier', id: 'ctrl' });
    f.session.routeKey({ kind: 'key', id: 'c' });
    assert.equal(f.resets.at(-1)[3], true);
    assert.equal(f.snapshot.pasting, false);
    assert.equal(f.snapshot.inputEnabled, false);
    f.emit({ type: 'inputConsumed', inputEpoch: body.inputEpoch, eventId: body.eventId,
      byteLength: Buffer.from(body.data, 'base64').length });
    f.emit({ type: 'inputReset', inputEpoch: body.inputEpoch });
    assert.equal(f.writes.length, 2);
    assert.equal(f.snapshot.inputEnabled, false);
    f.emit({ type: 'inputReset', inputEpoch: f.resets.at(-1)[2] });
    assert.equal(f.snapshot.inputEnabled, true);
  } finally { f.session.dispose(); }
});

test('peer closure clears the paste state before publishing its final snapshot', () => {
  const f = fixture();
  try {
    f.paste('unfinished');
    assert.equal(f.snapshot.pasting, true);
    f.emit({ type: 'state', state: 'CLOSED' });
    assert.equal(f.snapshot.pasting, false);
    assert.equal(f.snapshot.inputEnabled, false);
  } finally { f.session.dispose(); }
});

test('authentication sends an isolated plain array to NAPI and erases the temporary copy', () => {
  const f = fixture();
  try {
    f.emit({ type: 'state', state: 'AUTHENTICATING' });
    const observed = new Proxy(['synthetic-response'], {});
    f.session.answerAuthentication(7, observed);
    assert.notEqual(f.answers[0].raw, observed);
    assert.deepEqual(f.answers[0].values, ['synthetic-response']);
    assert.deepEqual(f.answers[0].raw, ['']);
  } finally { f.session.dispose(); }
});

test('clipboard LF and CRLF become single terminal returns with and without bracketed paste', async () => {
  for (const bracketed of [false, true]) {
    const f = fixture(true);
    try {
      f.web.terminal.modes.bracketedPasteMode = bracketed;
      f.paste('first\nsecond\r\nthird\rfourth你好');
      await new Promise(resolve => setImmediate(resolve));
      const expected = 'first\rsecond\rthird\rfourth你好';
      assert.equal(f.snapshot.pasting, false);
      assert.equal(Buffer.concat(f.writes.map(value => Buffer.from(value.data, 'base64'))).toString(),
        bracketed ? '\x1b[200~' + expected + '\x1b[201~' : expected);
    } finally { f.session.dispose(); }
  }
});

test('malformed UTF-8 paste messages cannot create an empty data chunk or jam later input', () => {
  for (const bytes of [Buffer.alloc(5000, 0x80), Buffer.from([0xc0, 0xaf]), Buffer.from([0xed, 0xa0, 0x80]),
    Buffer.from([0xf4, 0x90, 0x80, 0x80]), Buffer.from([0xe2, 0x82])]) {
    const f = fixture();
    try {
      f.session.handleTerminalMessage(JSON.stringify({ type: 'paste', sessionId: f.session.getSessionId(),
        connectionEpoch: f.session.getConnectionEpoch(), terminalGeneration: 1, inputEpoch: f.session.input.getInputEpoch(),
        eventId: 'invalid-utf8', bracketed: true, data: bytes.toString('base64') }));
      assert.equal(f.snapshot.pasting, false); assert.equal(f.writes.length, 0);
      f.session.routeKey({ kind: 'key', id: 'Enter' });
      assert.equal(Buffer.from(f.writes[0].data, 'base64').toString(), '\r');
    } finally { f.session.dispose(); }
  }
});

test('UTF-8 paste validation preserves BOM, NUL and multibyte characters byte for byte', async () => {
  const f = fixture(true);
  try {
    const text = '\uFEFFzero\0界🙂'; f.paste(text); await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.snapshot.pasting, false);
    assert.equal(Buffer.concat(f.writes.map(value => Buffer.from(value.data, 'base64'))).toString(), '\x1b[200~' + text + '\x1b[201~');
  } finally { f.session.dispose(); }
});

test('changing IME during a pending input reset supersedes its request and eventually resumes input', () => {
  for (const enabled of [false, true]) {
    const f = fixture();
    try {
      f.session.stopPaste(false);
      const oldReset = f.resets.at(-1);
      assert.equal(f.snapshot.inputEnabled, false);
      f.session.setImeMode(enabled);
      assert.equal(f.resets.length, 2, 'the new input epoch needs a matching native reset');
      const currentReset = f.resets.at(-1);
      assert.ok(currentReset[2] > oldReset[2]);
      f.emit({ type: 'inputReset', inputEpoch: oldReset[2] });
      assert.equal(f.snapshot.inputEnabled, false);
      f.emit({ type: 'inputReset', inputEpoch: currentReset[2] });
      assert.equal(f.snapshot.inputEnabled, true);
      assert.equal(f.web.textarea.readOnly, !enabled);
      f.session.routeKey({ kind: 'key', id: 'Enter' });
      assert.equal(Buffer.from(f.writes.at(-1).data, 'base64').toString(), '\r');
    } finally { f.session.dispose(); }
  }
});

test('a healthy IME transition resets the old native input epoch before accepting new keys', () => {
  const f = fixture();
  try {
    const oldEpoch = f.session.input.getInputEpoch();
    f.session.setImeMode(true);
    assert.equal(f.resets.length, 1);
    const currentEpoch = f.resets[0][2];
    assert.ok(currentEpoch > oldEpoch); assert.equal(f.snapshot.inputEnabled, false);
    f.session.routeKey({ kind: 'key', id: 'Enter' }); assert.equal(f.writes.length, 0);
    f.emit({ type: 'inputReset', inputEpoch: currentEpoch });
    f.session.routeKey({ kind: 'key', id: 'Enter' });
    assert.equal(f.writes.length, 1); assert.equal(f.writes[0].inputEpoch, currentEpoch);
  } finally { f.session.dispose(); }
});
