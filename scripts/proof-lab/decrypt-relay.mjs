// Operator helper: standard Node cryptography, no credential output.
import {readFileSync, writeFileSync, mkdirSync, chmodSync, statSync} from 'node:fs';
import {join} from 'node:path';
import {constants, createPrivateKey, createPublicKey, createHash, privateDecrypt, createDecipheriv} from 'node:crypto';

const [envelopePath, keyPath, outputDirectory, expectedSourceHead] = process.argv.slice(2);
if (!envelopePath || !keyPath || !outputDirectory || !/^[0-9a-f]{40}$/.test(expectedSourceHead || '')) {
  throw new Error('Usage: node decrypt-relay.mjs encrypted.json private-key.pem private-output-directory expected-source-commit');
}
if ((statSync(keyPath).mode & 0o077) !== 0) throw new Error('Operator private key must be private to its owner');
const envelope = JSON.parse(readFileSync(envelopePath, 'utf8'));
if (Number(envelope.schemaVersion) !== 1 || envelope.algorithm !== 'RSA-OAEP-SHA256+AES-256-GCM' ||
    envelope.aad !== 'RIGHTCLICK-WINDOWS-RELAY-v1') throw new Error('Unsupported encrypted relay envelope');
const key = createPrivateKey(readFileSync(keyPath));
const der = createPublicKey(key).export({type:'spki', format:'der'});
if (createHash('sha256').update(der).digest('hex') !== envelope.publicKeyDER_SHA256) throw new Error('Operator key fingerprint mismatch');
const decode = field => Buffer.from(envelope[field], 'base64');
const aesKey = privateDecrypt({key, padding:constants.RSA_PKCS1_OAEP_PADDING, oaepHash:'sha256'}, decode('wrappedKey'));
if (aesKey.length !== 32 || decode('nonce').length !== 12 || decode('tag').length !== 16) throw new Error('Invalid authenticated encryption parameters');
const cipher = createDecipheriv('aes-256-gcm', aesKey, decode('nonce'));
cipher.setAAD(Buffer.from(envelope.aad));
cipher.setAuthTag(decode('tag'));
const plaintext = Buffer.concat([cipher.update(decode('ciphertext')), cipher.final()]);
aesKey.fill(0);
const connection = JSON.parse(plaintext.toString('utf8'));
plaintext.fill(0);
if (connection.sourceHead !== expectedSourceHead) throw new Error('Relay source commit differs from the reviewed run');
if (Date.parse(connection.expiresAt) <= Date.now()) throw new Error('Relay authority has expired');
for (const field of ['writerOrigin', 'observerOrigin']) {
  const origin = new URL(connection[field]);
  if (origin.protocol !== 'https:' || !/^[a-z0-9-]+\.trycloudflare\.com$/.test(origin.hostname) ||
      origin.origin !== connection[field]) throw new Error('Relay must use an exact official quick-tunnel TLS origin');
}
for (const field of ['writerToken', 'observerToken', 'controlToken']) {
  if (typeof connection[field] !== 'string' || Buffer.from(connection[field], 'base64').length !== 32) throw new Error('Invalid scoped credential');
}
mkdirSync(outputDirectory, {recursive:true, mode:0o700});
chmodSync(outputDirectory, 0o700);
const references = {};
for (const [scope, field] of [['writer','writerToken'], ['observer','observerToken'], ['operator','controlToken']]) {
  const path = join(outputDirectory, scope + '.token');
  writeFileSync(path, connection[field], {mode:0o600});
  chmodSync(path, 0o600);
  references[scope] = path;
}
const privatePath = join(outputDirectory, 'connection.json');
writeFileSync(privatePath, JSON.stringify(connection, null, 2), {mode:0o600});
chmodSync(privatePath, 0o600);
const publicMetadata = {schemaVersion:1, sourceHead:connection.sourceHead, expiresAt:connection.expiresAt,
  writerOrigin:connection.writerOrigin, observerOrigin:connection.observerOrigin,
  writerPrincipal:connection.writerPrincipal, observerPrincipal:connection.observerPrincipal,
  credentialReferences:references, privateConnectionReference:privatePath};
writeFileSync(join(outputDirectory, 'references.json'), JSON.stringify(publicMetadata, null, 2), {mode:0o600});
console.log(JSON.stringify(publicMetadata, null, 2));
