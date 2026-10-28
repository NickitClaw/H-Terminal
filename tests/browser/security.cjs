// Execute the shipped page and real pinned xterm/addons, without platform stubs.
const { chromium } = require('../../terminal/node_modules/playwright-core');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const report = process.env.HT_REPORT_DIR || path.join(root, '.runtime/browser-security');
fs.mkdirSync(report, { recursive: true });
(async () => {
  const localChrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  const browser = await chromium.launch({ headless: true, executablePath: process.env.HT_CHROME || (fs.existsSync(localChrome) ? localChrome : undefined) });
  const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
  const messages = [], requests = [], errors = [];
  const identity = { sessionId: 'security-fixture', connectionEpoch: 1, terminalGeneration: 1 };
  try {
    page.on('pageerror', error => errors.push(error.message));
    page.on('request', request => { if (/^https?:/.test(request.url())) requests.push(request.url()); });
    await page.route(/^https?:/, route => route.abort());
    await page.exposeFunction('__fixturePost', value => messages.push(JSON.parse(value)));
    await page.addInitScript(() => {
      window.HTerminalBridge = { postMessage: value => window.__fixturePost(value) };
      window.__clipboardWrites = 0;
      Object.defineProperty(navigator, 'clipboard', { configurable: true,
        value: { writeText: async () => { window.__clipboardWrites++; } } });
      let implementation;
      Object.defineProperty(window, 'Terminal', { configurable: true,
        get: () => implementation,
        set: Original => { implementation = class extends Original { constructor(options) { super(options); window.__fixtureTerminal = this; } }; } });
    });
    await page.goto(pathToFileURL(path.join(root, 'entry/src/main/resources/rawfile/terminal/index.html')).href);
    const receive = message => page.evaluate(message => window.HTerminal.receive(JSON.stringify(message)), { ...identity, ...message });
    assert.equal(await receive({ type: 'init', inputEpoch: 1, fontSize: 15, scrollback: 5000 }), true);
    const payload = Buffer.from('<script>window.__remoteExecuted=true</script>\r\n' +
      '\x1b]0;<img src=https://invalid.example/title onerror=alert(1)>\x07' +
      '\x1b]52;c;' + Buffer.from('must-not-copy').toString('base64') + '\x07' +
      '\x1b]8;;javascript:window.__remoteExecuted=true\x1b\\CLICK\x1b]8;;\x1b\\\r\n' +
      '\x1b]8;;file:///data/private\x1b\\FILE\x1b]8;;\x1b\\\r\n' +
      '\x1b]8;;https://invalid.example/terminal\x1b\\HTTPS\x1b]8;;\x1b\\\r\n');
    assert.equal(await receive({ type: 'output', seq: 1, byteLength: payload.length, data: payload.toString('base64') }), true);
    for (let i = 0; i < 100 && !messages.some(m => m.type === 'ack' && m.seq === 1); i++) await new Promise(resolve => setTimeout(resolve, 20));
    assert.ok(messages.some(m => m.type === 'ack' && m.seq === 1), 'parser did not acknowledge hostile OSC/text');
    assert.equal(await page.title(), 'H-Terminal');
    assert.equal(await page.evaluate(() => window.__remoteExecuted), undefined);
    assert.equal(await page.evaluate(() => window.__clipboardWrites), 0);
    assert.equal(messages.some(m => m.type === 'copy' || m.type === 'pasteRequest'), false);
    const prevented = await page.evaluate(() => {
      let prevented = false, stopped = false;
      window.__fixtureTerminal.options.linkHandler.activate({ preventDefault() { prevented = true; }, stopPropagation() { stopped = true; } }, 'https://invalid.example/terminal');
      return prevented && stopped;
    });
    assert.equal(prevented, true);
    for (const malformed of ['null', '[]', 'true', '{', JSON.stringify({ type: 'output', ...identity, seq: '2', byteLength: 4, data: 'QQ==' })]) {
      assert.equal(await page.evaluate(value => window.HTerminal.receive(value), malformed), false);
    }
    assert.equal(await receive({ type: 'search', query: '(a+)+$' }), true);
    assert.equal(await receive({ type: 'search', query: 'x'.repeat(257) }), false);
    assert.equal(await receive({ type: 'selection', selecting: true }), true);
    const snapshot = await page.locator('#local-selection').textContent();
    assert.ok(snapshot.includes('<script>window.__remoteExecuted=true</script>'));
    assert.equal(await page.evaluate(() => window.__remoteExecuted), undefined);
    assert.equal(await receive({ type: 'key', inputEpoch: 1, eventId: 'blocked', key: 'Enter' }), false);
    assert.equal(await receive({ type: 'selection', selecting: false }), true);
    assert.deepEqual(requests, []); assert.deepEqual(errors, []);
    await page.screenshot({ path: path.join(report, 'hostile-output.png') });
    fs.writeFileSync(path.join(report, 'result.json'), JSON.stringify({ passed: true, browser: browser.version(),
      assertions: ['hostile text/OSC/title/link', 'OSC52 denied', 'offline requests', 'malformed envelopes', 'literal search', 'plain read-only snapshot'] }, null, 2));
    console.log('PASS: shipped xterm page rejects malicious OSC/navigation/clipboard and malformed messages; no network requests or script execution');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
