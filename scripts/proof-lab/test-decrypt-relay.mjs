// Offline controls only: synthetic keys and tokens never leave a private temp
// directory. No relay, network connection or GitHub credential is used.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, writeFileSync, existsSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {generateKeyPairSync, randomBytes, createCipheriv, publicEncrypt, createHash, constants} from 'node:crypto';

const script = join(dirname(fileURLToPath(import.meta.url)), 'decrypt-relay.mjs');
const sourceHead = 'a'.repeat(40);
const pair = generateKeyPairSync('rsa', {modulusLength:3072});
const fingerprint = createHash('sha256').update(pair.publicKey.export({type:'spki', format:'der'})).digest('hex');
function invoke(change = {}, {tamper = false, source = sourceHead} = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'rightclick-relay-expiry-'));
  try {
    const keyPath = join(directory, 'synthetic-key.pem');
    writeFileSync(keyPath, pair.privateKey.export({type:'pkcs8', format:'pem'}), {mode:0o600});
    const connection = {schemaVersion:1, sourceHead, expiresAt:new Date(Date.now()+60_000).toISOString(),
      writerOrigin:'https://fixture-writer.trycloudflare.com', observerOrigin:'https://fixture-observer.trycloudflare.com',
      writerPrincipal:'fixture-writer', observerPrincipal:'fixture-observer',
      writerToken:randomBytes(32).toString('base64'), observerToken:randomBytes(32).toString('base64'), controlToken:randomBytes(32).toString('base64'), ...change};
    const aesKey = randomBytes(32), nonce = randomBytes(12), aad = 'RIGHTCLICK-WINDOWS-RELAY-v1';
    const cipher = createCipheriv('aes-256-gcm', aesKey, nonce); cipher.setAAD(Buffer.from(aad));
    const ciphertext = Buffer.concat([cipher.update(JSON.stringify(connection)), cipher.final()]);
    if (tamper) ciphertext[0] ^= 1;
    const envelope = {schemaVersion:'1', algorithm:'RSA-OAEP-SHA256+AES-256-GCM', aad,
      publicKeyDER_SHA256:fingerprint,
      wrappedKey:publicEncrypt({key:pair.publicKey, padding:constants.RSA_PKCS1_OAEP_PADDING, oaepHash:'sha256'}, aesKey).toString('base64'),
      nonce:nonce.toString('base64'), tag:cipher.getAuthTag().toString('base64'), ciphertext:ciphertext.toString('base64')};
    aesKey.fill(0);
    const envelopePath = join(directory, 'encrypted.json'), output = join(directory, 'output');
    writeFileSync(envelopePath, JSON.stringify(envelope), {mode:0o600});
    const result = spawnSync(process.execPath, [script, envelopePath, keyPath, output, source], {encoding:'utf8'});
    // Retain only success booleans, never command output or synthetic secrets.
    return {accepted:result.status === 0, credentialsWritten:existsSync(join(output, 'writer.token')),
      referencesWritten:existsSync(join(output, 'references.json'))};
  } finally { rmSync(directory, {recursive:true, force:true}); }
}
test('finite future authenticated expiry allows private references', () => {
  assert.deepEqual(invoke(), {accepted:true, credentialsWritten:true, referencesWritten:true});
});
for (const [label, expiresAt] of [['malformed', 'not-a-time'], ['missing', undefined], ['null', null], ['numeric', 12345], ['expired', '2000-01-01T00:00:00.000Z']]) {
  test(`${label} expiry cannot grant relay authority`, () => {
    assert.deepEqual(invoke({expiresAt}), {accepted:false, credentialsWritten:false, referencesWritten:false});
  });
}
test('source commit mismatch cannot release credentials', () => {
  assert.deepEqual(invoke({}, {source:'b'.repeat(40)}), {accepted:false, credentialsWritten:false, referencesWritten:false});
});
test('authenticated ciphertext mismatch cannot release credentials', () => {
  assert.deepEqual(invoke({}, {tamper:true}), {accepted:false, credentialsWritten:false, referencesWritten:false});
});
