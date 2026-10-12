// ICE server configuration handed to each authenticated device.
//
// TURN credentials use the coturn "REST API" scheme: a short-lived username
// and an HMAC-SHA1 password derived from a secret shared only between this
// server and coturn. The app never holds a long-lived TURN password.

import crypto from 'node:crypto';

const DEFAULT_TTL_SEC = 12 * 60 * 60;

export function buildIceServers({ stunUrls = [], turnUrls = [], turnSecret, deviceId, ttlSec = DEFAULT_TTL_SEC, now = () => Date.now() }) {
  const servers = [];
  if (stunUrls.length > 0) servers.push({ urls: stunUrls });
  if (turnUrls.length > 0 && turnSecret) {
    const expiry = Math.floor(now() / 1000) + ttlSec;
    const username = `${expiry}:${deviceId}`;
    const credential = crypto.createHmac('sha1', turnSecret).update(username).digest('base64');
    servers.push({ urls: turnUrls, username, credential });
  }
  return servers;
}

export function parseUrlList(value) {
  if (!value) return [];
  return value
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}
