const { chromium } = require('../../terminal/node_modules/playwright-core');
const { spawn } = require('node:child_process');
const net = require('node:net');
const { createInterface } = require('node:readline');
const { pathToFileURL } = require('node:url');
const path = require('node:path');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const report = process.env.HT_REPORT_DIR;
const identity = { sessionId: 'compat', connectionEpoch: 1, terminalGeneration: 1 };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const mfa = process.env.HT_OPENSSH_MFA === '1';
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.HT_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' });
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  let child, transport, raw = '', failure = '', opened = false, sequence = 0, delivered = Promise.resolve();
  const errors = [], states = [], unexpectedRequests = [];
  const write = line => { if (transport && !transport.destroyed) transport.write(line + '\n'); };
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  server.unref();
  const sendBytes = bytes => write('I ' + Buffer.from(bytes).toString('base64'));
  const receive = message => page.evaluate(message => window.HTerminal.receive(JSON.stringify(message)), { ...identity, ...message });
  const text = value => receive({ type: 'text', inputEpoch: 1, eventId: 'browser-' + ++sequence, data: Buffer.from(value).toString('base64') });
  const key = (value, ctrl = false) => receive({ type: 'key', inputEpoch: 1, eventId: 'browser-' + ++sequence, key: value, ctrl });
  const screen = () => page.evaluate(() => {
    const buffer = window.__fixtureTerminal.buffer.active;
    return Array.from({ length: buffer.length }, (_, i) => buffer.getLine(i).translateToString(true)).join('\n');
  });
  async function wait(predicate, label, timeout = 15000) {
    const end = Date.now() + timeout;
    while (Date.now() < end) {
      if (failure) throw new Error(failure);
      if (await predicate()) return;
      await delay(40);
    }
    throw new Error('timeout: ' + label);
  }
  const python = source => text("python3 -c \"import base64; exec(base64.b64decode('" + Buffer.from(source).toString('base64') + "'))\"\r");
  try {
    page.on('pageerror', error => errors.push(error.message));
    page.on('request', request => { if (/^https?:/.test(request.url())) unexpectedRequests.push(request.url()); });
    await page.route(/^https?:/, route => route.abort());
    await page.exposeFunction('__fixturePost', json => {
      const message = JSON.parse(json);
      if (message.type === 'ack') write(`A ${message.seq} ${message.byteLength}`);
      if (message.type === 'resize') write(`R ${message.cols} ${message.rows}`);
      if (message.type === 'input') sendBytes(Buffer.from(message.data, 'base64'));
      if (message.type === 'paste') {
        const bytes = Buffer.from(message.data, 'base64');
        sendBytes(message.bracketed ? Buffer.concat([Buffer.from('\x1b[200~'), bytes, Buffer.from('\x1b[201~')]) : bytes);
      }
      if (message.type === 'error' && message.fatal) failure = message.code;
    });
    await page.addInitScript(() => {
      window.HTerminalBridge = { postMessage: json => window.__fixturePost(json) };
      let implementation;
      Object.defineProperty(window, 'Terminal', {
        configurable: true,
        get: () => implementation,
        set: Original => { implementation = class extends Original { constructor(options) { super(options); window.__fixtureTerminal = this; } }; }
      });
    });
    await page.goto(pathToFileURL(path.join(root, 'entry/src/main/resources/rawfile/terminal/index.html')).href);
    assert.equal(await receive({ type: 'init', inputEpoch: 1, fontSize: 15, scrollback: 5000 }), true);
    child = spawn(process.env.HT_HDC, ['shell', `${process.env.HT_DEVICE_DIR}/session-bridge ${process.env.HT_DEVICE_DIR} 10.0.2.2 ${process.env.HT_OPENSSH_PORT} ${mfa ? 'publickey+keyboard-interactive' : 'publickey'} ${server.address().port}`], { stdio: ['ignore', 'pipe', 'pipe'] });
    child.on('error', error => { failure = error.message; });
    child.on('exit', code => { if (code && !failure) failure = 'native bridge exited ' + code; });
    child.stderr.on('data', bytes => { fs.appendFileSync(path.join(report, 'bridge-stderr.log'), bytes); });
    server.on('connection', socket => {
      if (transport) { socket.destroy(); return; }
      transport = socket;
      socket.on('error', error => { failure = error.message; });
      createInterface({ input: socket }).on('line', line => {
      if (!line.startsWith('O ')) fs.appendFileSync(path.join(report, 'bridge-events.log'), line + '\n');
      const output = /^O (\d+) (\d+) (\S+)$/.exec(line.trim());
      if (output) {
        const frame = { type: 'output', seq: Number(output[1]), byteLength: Number(output[2]), data: output[3] };
        raw = (raw + Buffer.from(frame.data, 'base64').toString()).slice(-2 * 1024 * 1024);
        delivered = delivered.then(() => receive(frame)).catch(error => { failure = error.message; });
      } else if (line.startsWith('S ')) {
        states.push(line.trim()); if (line.trim() === 'S OPEN') opened = true;
      } else if (line.startsWith('E ')) failure = line.trim();
    });
    });
    await wait(() => opened, 'OpenSSH authentication');
    await text("stty -echo; printf '\\nHT_READY\\n'\r");
    await wait(() => raw.includes('HT_READY\r\n'), 'PTY shell');
    if (mfa) {
      console.log('PASS: actual OpenSSH publickey + PAM keyboard-interactive partial authentication');
      return;
    }
    await receive({ type: 'fit' });
    await delay(150);
    const dimensions = await page.evaluate(() => ({ cols: window.__fixtureTerminal.cols, rows: window.__fixtureTerminal.rows }));
    await text("printf 'HT_SIZE '; stty size\r");
    await wait(() => raw.includes(`HT_SIZE ${dimensions.rows} ${dimensions.cols}\r\n`), 'measured PTY resize');
    await text("printf '\\033[38;2;10;20;30m你好🙂\\033[0m\\n'\r");
    await wait(async () => (await screen()).includes('你好🙂'), 'CJK/emoji/true color');
    const keyReader = `import os,sys,tty,termios\nold=termios.tcgetattr(0)\ntry:\n tty.setraw(0)\n sys.stdout.write('\\x1b[?1h\\r\\nHT_KEY_READY\\r\\n');sys.stdout.flush()\n value=b''\n while len(value)<3:value+=os.read(0,3-len(value))\nfinally:termios.tcsetattr(0,termios.TCSANOW,old)\nprint('\\r\\nHT_KEY_'+value.hex(),flush=True)\n`;
    await python(keyReader);
    await wait(async () => raw.includes('HT_KEY_READY\r\n') && await page.evaluate(() => window.__fixtureTerminal.modes.applicationCursorKeysMode), 'DECCKM');
    await key('ArrowUp');
    await wait(() => raw.includes('HT_KEY_1b4f41'), 'application cursor bytes');
    const paste = '你好🙂\nsecond line';
    const expectedPaste = Buffer.from('\x1b[200~' + paste + '\x1b[201~');
    await python(`import os,sys,tty,termios\nold=termios.tcgetattr(0)\ntry:\n tty.setraw(0)\n sys.stdout.write('\\x1b[?2004h\\r\\nHT_PASTE_READY\\r\\n');sys.stdout.flush()\n value=b''\n while len(value)<${expectedPaste.length}:value+=os.read(0,${expectedPaste.length}-len(value))\nfinally:termios.tcsetattr(0,termios.TCSANOW,old)\nprint('\\r\\nHT_PASTE_'+value.hex(),flush=True)\n`);
    await wait(async () => raw.includes('HT_PASTE_READY\r\n') && await page.evaluate(() => window.__fixtureTerminal.modes.bracketedPasteMode), 'bracketed paste mode');
    await receive({ type: 'paste', inputEpoch: 1, eventId: 'paste-fixture', data: Buffer.from(paste).toString('base64') });
    await wait(() => raw.includes('HT_PASTE_' + expectedPaste.toString('hex')), 'single bracket boundary pair');
    console.log('PASS: Native SSH + real xterm PTY, resize, UTF-8, DECCKM and bracketed paste');

    await text("vim -Nu NONE -i NONE -n -c 'set paste' /tmp/ht-config\r");
    await wait(() => page.evaluate(() => window.__fixtureTerminal.buffer.active.type === 'alternate'), 'vim alternate screen');
    await delay(150);
    await page.screenshot({ path: path.join(report, 'vim.png') });
    const document = Array.from({ length: 20 }, (_, i) => `line ${i + 1}: 你好🙂`).join('\n') + '\n';
    await key('i'); await text(document.slice(0, -1)); await key('Escape'); await text(':wq\r');
    await wait(() => page.evaluate(() => window.__fixtureTerminal.buffer.active.type === 'normal'), 'vim exit');
    const hash = crypto.createHash('sha256').update(document).digest('hex');
    await text("sha256sum /tmp/ht-config\r");
    await wait(() => raw.includes(hash), 'vim saved 20 exact UTF-8 lines');
    console.log('PASS: vim edit/save/exit with 20 UTF-8 lines and exact SHA-256');

    await text('tmux -L hterminal new-session -s work\r');
    await wait(() => page.evaluate(() => window.__fixtureTerminal.buffer.active.type === 'alternate'), 'tmux attach');
    await text("printf '\\nHT_TMUX\\n'\r");
    await wait(() => raw.includes('HT_TMUX\r\n'), 'tmux shell input');
    await page.screenshot({ path: path.join(report, 'tmux.png') });
    await key('b', true); await text('d');
    await wait(() => page.evaluate(() => window.__fixtureTerminal.buffer.active.type === 'normal'), 'tmux detach');
    await text('tmux -L hterminal attach-session -t work\r');
    await wait(async () => await page.evaluate(() => window.__fixtureTerminal.buffer.active.type === 'alternate') && (await screen()).includes('HT_TMUX'), 'tmux retained workspace');
    await page.setViewportSize({ width: 960, height: 600 }); await receive({ type: 'fit' }); await delay(150);
    await key('b', true); await text('d');
    await wait(() => page.evaluate(() => window.__fixtureTerminal.buffer.active.type === 'normal'), 'tmux second detach');
    console.log('PASS: tmux detach/reattach, retained output and resize');

    await text('htop -d 10\r');
    await wait(async () => await page.evaluate(() => window.__fixtureTerminal.buffer.active.type === 'alternate') && /Tasks:|Mem|CPU/.test(await screen()), 'htop full screen');
    await page.screenshot({ path: path.join(report, 'htop.png') });
    await text('q'); await wait(() => page.evaluate(() => window.__fixtureTerminal.buffer.active.type === 'normal'), 'htop quit');
    await text("printf '\\nHT_SEARCH_FIXTURE\\n'\r"); await wait(() => raw.includes('HT_SEARCH_FIXTURE\r\n'), 'search fixture');
    await receive({ type: 'search', query: 'HT_SEARCH_FIXTURE' });
    assert.equal(await page.evaluate(() => window.__fixtureTerminal.getSelection()), 'HT_SEARCH_FIXTURE');
    const original = await page.evaluate(() => { window.__originalTerminal = window.__fixtureTerminal; return true; });
    await receive({ type: 'appearance', fontSize: 20 });
    assert.equal(await page.evaluate(() => window.__originalTerminal === window.__fixtureTerminal), original);
    await receive({ type: 'selection', selecting: true });
    assert.ok((await page.locator('#local-selection').textContent()).includes('HT_SEARCH_FIXTURE'));
    assert.equal(await receive({ type: 'key', inputEpoch: 1, eventId: 'blocked', key: 'Enter' }), false);
    await receive({ type: 'selection', selecting: false });
    assert.deepEqual(errors, []); assert.deepEqual(unexpectedRequests, []);
    console.log('PASS: htop, real SearchAddon, font preserves terminal, read-only selection and offline resources');
  } catch (error) {
    await page.screenshot({ path: path.join(report, 'failure.png') }).catch(() => {});
    fs.writeFileSync(path.join(report, 'failure-screen.txt'), await screen().catch(() => 'unavailable'));
    throw error;
  } finally {
    fs.writeFileSync(path.join(report, mfa ? 'mfa-states.json' : 'states.json'), JSON.stringify({ states, browserErrors: errors, browser: browser.version() }, null, 2));
    if (child) { write('C'); transport?.end(); await Promise.race([new Promise(resolve => child.once('exit', resolve)), delay(3000)]); if (child.exitCode === null) child.kill(); }
    transport?.destroy(); server.close();
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
