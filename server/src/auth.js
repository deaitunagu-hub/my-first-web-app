// Device authentication helpers.
//
// Every device owns an Ed25519 key pair that never leaves the phone's
// Keychain. The server only stores the public key. Registration and every
// WebSocket connection require a fresh signature over a server nonce, so a
// stolen signaling transcript cannot be replayed.

import crypto from 'node:crypto';

export const SIGN_PREFIX = Object.freeze({
  register: 'kidscall-register|',
  auth: 'kidscall-auth|',
});

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const NONCE_TTL_MS = 2 * 60 * 1000;
const MAX_PENDING_NONCES = 10_000;

export function decodePublicKey(publicKeyBase64) {
  if (typeof publicKeyBase64 !== 'string') return null;
  let raw;
  try {
    raw = Buffer.from(publicKeyBase64, 'base64');
  } catch {
    return null;
  }
  if (raw.length !== 32) return null;
  try {
    return crypto.createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, raw]),
      format: 'der',
      type: 'spki',
    });
  } catch {
    return null;
  }
}

export function isValidPublicKey(publicKeyBase64) {
  return decodePublicKey(publicKeyBase64) !== null;
}

export function deviceIdFor(publicKeyBase64) {
  const raw = Buffer.from(publicKeyBase64, 'base64');
  return crypto.createHash('sha256').update(raw).digest('hex').slice(0, 32);
}

export function verifySignature(publicKeyBase64, message, signatureBase64) {
  const key = decodePublicKey(publicKeyBase64);
  if (!key || typeof signatureBase64 !== 'string') return false;
  let sig;
  try {
    sig = Buffer.from(signatureBase64, 'base64');
  } catch {
    return false;
  }
  if (sig.length !== 64) return false;
  try {
    return crypto.verify(null, Buffer.from(message, 'utf8'), key, sig);
  } catch {
    return false;
  }
}

export function registerMessage(nonce, publicKeyBase64) {
  return `${SIGN_PREFIX.register}${nonce}|${publicKeyBase64}`;
}

export function authMessage(nonce, publicKeyBase64) {
  return `${SIGN_PREFIX.auth}${nonce}|${publicKeyBase64}`;
}

export function newNonce() {
  return crypto.randomBytes(32).toString('base64url');
}

/** Single-use nonces with a short lifetime. */
export class ChallengeBook {
  constructor({ ttlMs = NONCE_TTL_MS, now = () => Date.now() } = {}) {
    this.ttlMs = ttlMs;
    this.now = now;
    this.pending = new Map();
  }

  issue() {
    this.prune();
    if (this.pending.size >= MAX_PENDING_NONCES) {
      const oldest = this.pending.keys().next().value;
      this.pending.delete(oldest);
    }
    const nonce = newNonce();
    this.pending.set(nonce, this.now() + this.ttlMs);
    return { nonce, expiresAt: this.pending.get(nonce) };
  }

  consume(nonce) {
    if (typeof nonce !== 'string') return false;
    const expiresAt = this.pending.get(nonce);
    if (expiresAt === undefined) return false;
    this.pending.delete(nonce);
    return expiresAt > this.now();
  }

  prune() {
    const t = this.now();
    for (const [nonce, expiresAt] of this.pending) {
      if (expiresAt <= t) this.pending.delete(nonce);
    }
  }
}

/** Test/CLI helper: create an Ed25519 key pair in the same encoding the app uses. */
export function generateDeviceKeyPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  return {
    publicKey: spki.subarray(ED25519_SPKI_PREFIX.length).toString('base64'),
    sign(message) {
      return crypto.sign(null, Buffer.from(message, 'utf8'), privateKey).toString('base64');
    },
  };
}
