const { generateKeyPairSync } = require('node:crypto');
const { Server } = require('ssh2');
const { privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048, privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
  publicKeyEncoding: { type: 'pkcs1', format: 'pem' }
});
let sequence = 0;
new Server({ hostKeys: [privateKey] }, (client) => {
  const id = ++sequence;
  let username = '';
  client.on('error', () => {});
  client.on('authentication', (request) => {
    username = request.username;
    if (request.method === 'password' && ['review', 'probe-reject', 'probe-timeout'].includes(username) &&
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
      if (session._channel) {
        const remote = session._channel.outgoing.id;
        if (username === 'probe-reject') client._protocol.channelFailure(remote);
        else if (username !== 'probe-timeout') client._protocol.channelSuccess(remote);
      } else if (username === 'probe-reject') reject?.();
      else if (username !== 'probe-timeout') accept?.();
    });
    session.on('shell', (accept) => {
      const stream = accept();
      stream.on('error', () => {});
      stream.write('fixture> ');
      console.log(`OPEN ${id}`);
      stream.on('data', (bytes) => {
        // Only artificial local test input. Authentication secrets are never logged.
        console.log(`INPUT ${id} ${bytes.toString('base64')}`);
        stream.write(bytes);
      });
    });
  }));
  client.on('close', () => console.log(`CLOSED ${id}`));
}).listen(Number(process.argv[2]), '127.0.0.1', () => console.log('READY'));
