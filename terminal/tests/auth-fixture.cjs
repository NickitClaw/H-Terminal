const { Server, utils } = require('ssh2');
const { generateKeyPairSync } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const directory = process.argv[3];
const identity = utils.generateKeyPairSync('ed25519');
const encrypted = utils.generateKeyPairSync('ed25519', { passphrase: 'key-passphrase', cipher: 'aes256-ctr' });
fs.writeFileSync(path.join(directory, 'identity'), identity.private, { mode: 0o600 });
fs.writeFileSync(path.join(directory, 'encrypted-identity'), encrypted.private, { mode: 0o600 });
const raw = Buffer.from(encrypted.private.split('\n').filter(line => line && !line.startsWith('-----')).join(''), 'base64');
let cursor = 15;
for (let i = 0; i < 2; i++) cursor += 4 + raw.readUInt32BE(cursor);
const kdfLength = raw.readUInt32BE(cursor);
raw.writeUInt32BE(0xffffffff, cursor + 4 + kdfLength - 4);
const costly = '-----BEGIN OPENSSH PRIVATE KEY-----\n' + raw.toString('base64').match(/.{1,70}/g).join('\n') +
  '\n-----END OPENSSH PRIVATE KEY-----\n';
fs.writeFileSync(path.join(directory, 'cost-identity'), costly, { mode: 0o600 });
const allowed = [utils.parseKey(identity.private), utils.parseKey(encrypted.private, 'key-passphrase')];
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs1', format: 'pem' }, publicKeyEncoding: { type: 'pkcs1', format: 'pem' } });
new Server({ hostKeys: [privateKey] }, (client) => {
  let primary = false;
  client.on('error', () => {});
  client.on('authentication', (request) => {
    console.log('AUTH ' + request.method);
    const combo = request.username.includes('combo');
    if (request.method === 'password' && request.password === 'review') {
      if (combo) { primary = true; request.reject(['keyboard-interactive'], true); }
      else request.accept();
    } else if (request.method === 'publickey') {
      const key = allowed.find(key => key.getPublicSSH().equals(request.key.data));
      if (!key || (request.signature && key.verify(request.blob, request.signature, request.hashAlgo) !== true)) {
        request.reject(['publickey']); return;
      }
      if (!request.signature) request.accept();
      else if (combo) { primary = true; request.reject(['keyboard-interactive'], true); }
      else request.accept();
    } else if (request.method === 'keyboard-interactive' && (!combo || primary)) {
      request.prompt([{ prompt: 'User code', echo: true }, { prompt: 'One time code', echo: false }],
        'Fixture MFA', 'Synthetic test values only', answers => {
          console.log('ROUND1 valid=' + (answers[0] === 'review' && answers[1] === '123456'));
          if (answers[0] !== 'review' || answers[1] !== '123456') { request.reject(); return; }
          request.prompt([{ prompt: 'Second code', echo: false }], answers => {
            console.log('ROUND2 valid=' + (answers[0] === '654321'));
            answers[0] === '654321' ? request.accept() : request.reject();
          });
        });
    } else request.reject(['password', 'publickey', 'keyboard-interactive']);
  });
  client.on('ready', () => client.on('session', accept => {
    const session = accept();
    for (const name of ['pty', 'window-change']) session.on(name, accept => accept?.());
    session.on('shell', accept => { const stream = accept(); stream.on('error', () => {}); stream.write('AUTH_OK\r\n'); });
  }));
}).listen(Number(process.argv[2]), '127.0.0.1', () => console.log('READY'));
