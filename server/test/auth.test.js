import test from 'node:test';
import assert from 'node:assert/strict';
import {
  ChallengeBook,
  authMessage,
  deviceIdFor,
  generateDeviceKeyPair,
  isValidPublicKey,
  verifySignature,
} from '../src/auth.js';

test('signature round trip', () => {
  const kp = generateDeviceKeyPair();
  assert.ok(isValidPublicKey(kp.publicKey));
  const msg = authMessage('nonce', kp.publicKey);
  assert.equal(verifySignature(kp.publicKey, msg, kp.sign(msg)), true);
  assert.equal(verifySignature(kp.publicKey, msg + 'x', kp.sign(msg)), false);
  const other = generateDeviceKeyPair();
  assert.equal(verifySignature(other.publicKey, msg, kp.sign(msg)), false);
});

test('rejects malformed keys and signatures', () => {
  assert.equal(isValidPublicKey('not base64 at all!!'), false);
  assert.equal(isValidPublicKey(Buffer.alloc(31).toString('base64')), false);
  assert.equal(isValidPublicKey(undefined), false);
  const kp = generateDeviceKeyPair();
  assert.equal(verifySignature(kp.publicKey, 'm', 'AAAA'), false);
  assert.equal(verifySignature(kp.publicKey, 'm', undefined), false);
});

test('device id is stable and derived from the key', () => {
  const kp = generateDeviceKeyPair();
  assert.equal(deviceIdFor(kp.publicKey), deviceIdFor(kp.publicKey));
  assert.match(deviceIdFor(kp.publicKey), /^[0-9a-f]{32}$/);
  assert.notEqual(deviceIdFor(kp.publicKey), deviceIdFor(generateDeviceKeyPair().publicKey));
});

test('challenges are single use and expire', () => {
  let t = 1000;
  const book = new ChallengeBook({ ttlMs: 100, now: () => t });
  const { nonce } = book.issue();
  assert.equal(book.consume('bogus'), false);
  assert.equal(book.consume(nonce), true);
  assert.equal(book.consume(nonce), false, 'second use must fail');
  const { nonce: late } = book.issue();
  t += 101;
  assert.equal(book.consume(late), false, 'expired nonce must fail');
});
