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
// Date.parse returns NaN for absent/malformed input; NaN <= now is false.
// Authority requires an explicit typed ISO timestamp and a finite future bound.
const components = typeof connection.expiresAt === 'string' &&
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$/.exec(connection.expiresAt);
let expiry = NaN;
if (components) {
  const [year, month, day, hour, minute, second] = components.slice(1).map(Number);
  const days = new Date(Date.UTC(year, month, 0)).getUTCDate();
  // JavaScript otherwise normalizes February 30/April 31 into a later day.
  if (year >= 1 && month >= 1 && month <= 12 && day >= 1 && day <= days &&
      hour <= 23 && minute <= 59 && second <= 59) expiry = Date.parse(connection.expiresAt);
}
if (!Number.isFinite(expiry) || expiry <= Date.now()) throw new Error('Relay authority expiry is invalid or expired');
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
