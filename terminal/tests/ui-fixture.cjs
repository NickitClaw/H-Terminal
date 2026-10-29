const { generateKeyPairSync } = require('node:crypto');
const { Server } = require('ssh2');
const { privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048, privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
  publicKeyEncoding: { type: 'pkcs1', format: 'pem' }
});
let sequence = 0;
let dropped = false;
new Server({ hostKeys: [privateKey] }, (client) => {
  const id = ++sequence;
  let username = '';
  client.on('error', () => {});
  client.on('authentication', (request) => {
    username = request.username;
    if (request.method === 'password' && ['review', 'soak', 'probe-reject', 'probe-timeout', 'probe-delay'].includes(username) &&
      request.password === 'review') request.accept();
    else request.reject(['password']);
  });
  client.on('request', (accept) => accept?.());
  client.on('ready', () => client.on('session', (accept) => {
    const session = accept();
    for (const name of ['pty', 'window-change']) session.on(name, (accept) => accept?.());
    session.on('env', (accept, reject) => {
      // ssh2's public accept/reject callbacks intentionally ignore env after
      // shell startup. Emit the protocol response directly in this pinned
      // fixture to model SSH servers that accept/reject a post-shell probe.
      const reply = () => {
        if (session._channel) {
          const remote = session._channel.outgoing.id;
          if (username === 'probe-reject') client._protocol.channelFailure(remote);
          else if (username !== 'probe-timeout') client._protocol.channelSuccess(remote);
        } else if (username === 'probe-reject') reject?.();
        else if (username !== 'probe-timeout') accept?.();
      };
      if (username === 'probe-delay') {
        const cancel = () => clearTimeout(timer);
        const timer = setTimeout(() => { client.off('close', cancel); reply(); }, 3000);
        client.once('close', cancel);
      } else reply();
    });
    session.on('shell', (accept) => {
      const stream = accept();
      let pumping = false, timer, chunk = 0;
      const pump = () => {
        if (!pumping || stream.destroyed) return;
        const line = `HT_STREAM ${id} ${String(++chunk).padStart(10, '0')} ${'X'.repeat(80)}\r\n`;
        const data = line.repeat(Math.floor(32768 / Buffer.byteLength(line)));
        if (stream.write(data)) timer = setTimeout(pump, 256);
        else stream.once('drain', () => { timer = setTimeout(pump, 256); });
      };
      if (username === 'soak') { pumping = true; timer = setTimeout(pump, 300); }
      stream.on('close', () => { pumping = false; clearTimeout(timer); });
      stream.on('error', () => {});
      stream.write('fixture> ');
      console.log(`OPEN ${id}`);
      if (process.env.HT_UI_SCENARIO === 'reconnect' && !dropped) {
        dropped = true;
        setTimeout(() => client.end(), 1500);
      }
      stream.on('data', (bytes) => {
        // Only artificial local test input. Authentication secrets are never logged.
        console.log(`INPUT ${id} ${bytes.toString('base64')}`);
        if (username === 'soak') {
          console.log(`TIMING ${id} ${Date.now()} ${bytes.toString('base64')}`);
          if (bytes.includes(3)) { pumping = false; clearTimeout(timer); console.log(`STOP ${id} ${Date.now()}`); }
          if (bytes.equals(Buffer.from('r')) && !pumping) { pumping = true; timer = setTimeout(pump, 256); }
        }
        if (process.env.HT_UI_SCENARIO === 'reconnect' && bytes.equals(Buffer.from([4]))) {
          setTimeout(() => client.end(), 100);
        }
        stream.write(bytes);
      });
    });
  }));
  client.on('close', () => console.log(`CLOSED ${id}`));
}).listen(Number(process.argv[2]), '127.0.0.1', () => console.log('READY'));
