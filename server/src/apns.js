// Minimal APNs VoIP push sender (HTTP/2 + ES256 JWT) with no dependencies.
//
// A VoIP push is the only way to make the callee's iPhone ring while the app
// is not running. The payload carries nothing sensitive: just a call id and
// the caller's display name.

import crypto from 'node:crypto';
import http2 from 'node:http2';
import { readFileSync } from 'node:fs';

const TOKEN_LIFETIME_MS = 50 * 60 * 1000;

function base64url(input) {
  return Buffer.from(input).toString('base64url');
}

export class ApnsClient {
  constructor({ privateKeyPem, keyId, teamId, bundleId, environment = 'production', logger = console }) {
    if (!privateKeyPem || !keyId || !teamId || !bundleId) {
      throw new Error('ApnsClient requires privateKeyPem, keyId, teamId and bundleId');
    }
    this.privateKey = crypto.createPrivateKey(privateKeyPem);
    this.keyId = keyId;
    this.teamId = teamId;
    this.bundleId = bundleId;
    this.host =
      environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    this.logger = logger;
    this.cachedToken = null;
    this.cachedTokenAt = 0;
  }

  providerToken() {
    const now = Date.now();
    if (this.cachedToken && now - this.cachedTokenAt < TOKEN_LIFETIME_MS) return this.cachedToken;
    const header = base64url(JSON.stringify({ alg: 'ES256', kid: this.keyId }));
    const claims = base64url(JSON.stringify({ iss: this.teamId, iat: Math.floor(now / 1000) }));
    const signature = crypto
      .sign('sha256', Buffer.from(`${header}.${claims}`), { key: this.privateKey, dsaEncoding: 'ieee-p1363' })
      .toString('base64url');
    this.cachedToken = `${header}.${claims}.${signature}`;
    this.cachedTokenAt = now;
    return this.cachedToken;
  }

  /** Sends one VoIP push. Resolves to { status, body }. Never throws on APNs errors. */
  sendVoip(deviceToken, payload) {
    return new Promise((resolve) => {
      let client;
      try {
        client = http2.connect(this.host);
      } catch (err) {
        resolve({ status: 0, body: String(err) });
        return;
      }
      const body = JSON.stringify(payload);
      const req = client.request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${this.providerToken()}`,
        'apns-topic': `${this.bundleId}.voip`,
        'apns-push-type': 'voip',
        'apns-priority': '10',
        'apns-expiration': '0',
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      });
      let status = 0;
      let chunks = '';
      req.on('response', (headers) => {
        status = headers[':status'];
      });
      req.on('data', (c) => {
        chunks += c;
      });
      req.on('end', () => {
        client.close();
        resolve({ status, body: chunks });
      });
      req.on('error', (err) => {
        client.close();
        resolve({ status: 0, body: String(err) });
      });
      req.end(body);
    });
  }
}

export function createApnsFromEnv(env, logger = console) {
  const { APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID } = env;
  if (!APNS_KEY_PATH || !APNS_KEY_ID || !APNS_TEAM_ID || !APNS_BUNDLE_ID) {
    logger.warn('[apns] not configured: devices will only ring while the app is open');
    return null;
  }
  return new ApnsClient({
    privateKeyPem: readFileSync(APNS_KEY_PATH, 'utf8'),
    keyId: APNS_KEY_ID,
    teamId: APNS_TEAM_ID,
    bundleId: APNS_BUNDLE_ID,
    environment: env.APNS_ENV === 'sandbox' ? 'sandbox' : 'production',
    logger,
  });
}
