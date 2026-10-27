const { generateKeyPairSync } = require('node:crypto');
const { Server } = require('ssh2');

const { privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs1', format: 'pem' },
  publicKeyEncoding: { type: 'pkcs1', format: 'pem' }
});
const payload = Buffer.alloc(4 * 1024 * 1024, 'X');
const server = new Server({ hostKeys: [privateKey] }, (client) => {
  client.on('error', () => {});
  client.on('authentication', (request) => {
    if (request.method === 'password' && request.username === 'review' && request.password === 'review') {
      request.accept();
    } else {
      request.reject(['password']);
    }
  });
  client.on('ready', () => client.on('session', (accept) => {
    const session = accept();
    session.on('pty', (acceptPty) => acceptPty?.());
    session.on('window-change', (acceptResize) => acceptResize?.());
    session.on('shell', (acceptShell) => {
      const stream = acceptShell();
      stream.on('error', () => {});
      stream.write('READY\r\n');
      let input = '';
      stream.on('data', (bytes) => {
        input += bytes.toString();
        let boundary;
        while ((boundary = input.indexOf('\r')) !== -1) {
          const command = input.slice(0, boundary);
          input = input.slice(boundary + 1);
          if (['close', 'late-tail', 'stderr-close', 'disconnect'].includes(command)) {
            const output = command === 'stderr-close' ? stream.stderr : stream;
            output.write(Buffer.alloc(512 * 1024, command === 'stderr-close' ? 'E' : 'X'));
            output.write('\r\nEND\r\n');
            if (command === 'disconnect') {
              // No channel EOF: the client must retain valid buffered bytes
              // while still reporting the transport failure.
              setTimeout(() => client.end(), 50);
            } else {
              stream.exit(0);
              stream.on('finish', () => { stream.close(); client.end(); });
              stream.end();
            }
          } else if (command === 'burst') {
            stream.write(payload);
            stream.write('\r\nEND\r\n');
          } else if (command === 'control') {
            stream.write('\r\nCONTROL\r\n');
          }
        }
      });
    });
  }));
});
server.listen(Number(process.argv[2] || 22224), '127.0.0.1', () => console.log('READY'));
