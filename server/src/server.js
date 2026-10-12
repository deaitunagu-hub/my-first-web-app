// HTTP (registration) + WebSocket (presence & WebRTC signaling) server.
//
// The server never sees audio or video: media flows peer-to-peer over
// DTLS-SRTP (or through TURN, which only relays the already-encrypted
// packets). This process only knows who is in the group and relays
// SDP/ICE blobs between authenticated members who are in the call.

import http from 'node:http';
import crypto from 'node:crypto';
import { WebSocketServer } from 'ws';
import {
  ChallengeBook,
  authMessage,
  deviceIdFor,
  isValidPublicKey,
  registerMessage,
  verifySignature,
} from './auth.js';
import { MAX_MEMBERS, StoreError } from './store.js';
import { buildIceServers } from './turn.js';

const MAX_BODY_BYTES = 16 * 1024;
const MAX_WS_MESSAGE_BYTES = 64 * 1024;
const AUTH_TIMEOUT_MS = 10 * 1000;
const HEARTBEAT_MS = 25 * 1000;
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const RATE_LIMIT_MAX = 30;

class RateLimiter {
  constructor({ windowMs = RATE_LIMIT_WINDOW_MS, max = RATE_LIMIT_MAX, now = () => Date.now() } = {}) {
    this.windowMs = windowMs;
    this.max = max;
    this.now = now;
    this.hits = new Map();
  }

  allow(key) {
    const t = this.now();
    const list = (this.hits.get(key) ?? []).filter((ts) => t - ts < this.windowMs);
    if (list.length >= this.max) {
      this.hits.set(key, list);
      return false;
    }
    list.push(t);
    this.hits.set(key, list);
    if (this.hits.size > 10_000) this.hits.clear();
    return true;
  }
}

function sendJson(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(data),
    'cache-control': 'no-store',
  });
  res.end(data);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new StoreError('payload_too_large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {});
      } catch {
        reject(new StoreError('invalid_json'));
      }
    });
    req.on('error', reject);
  });
}

function clientIp(req) {
  // Trust only the immediate peer unless explicitly told the proxy sets X-Forwarded-For.
  return req.socket.remoteAddress ?? 'unknown';
}

const ERROR_STATUS = {
  invalid_json: 400,
  payload_too_large: 413,
  invalid_name: 400,
  invalid_public_key: 400,
  invalid_signature: 401,
  invalid_nonce: 401,
  invalid_setup_token: 403,
  setup_disabled: 403,
  group_exists: 409,
  no_group: 404,
  invalid_invite: 403,
  group_full: 409,
  already_member: 409,
  forbidden: 403,
  not_found: 404,
  rate_limited: 429,
};

export function createApp({ store, config, apns = null, logger = console, now = () => Date.now() }) {
  const challenges = new ChallengeBook({ now });
  const limiter = new RateLimiter({ now });
  const sockets = new Map(); // deviceId -> ws
  const call = { id: null, seq: 0, participants: new Map() }; // deviceId -> { seq, name }

  // ---------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------

  async function handleHttp(req, res) {
    const url = new URL(req.url, 'http://localhost');
    try {
      if (req.method === 'GET' && url.pathname === '/v1/health') {
        return sendJson(res, 200, { ok: true, hasGroup: store.hasGroup() });
      }
      if (req.method !== 'POST') return sendJson(res, 404, { error: 'not_found' });

      if (!limiter.allow(clientIp(req))) throw new StoreError('rate_limited');

      if (url.pathname === '/v1/challenge') {
        const { nonce, expiresAt } = challenges.issue();
        return sendJson(res, 200, { nonce, expiresAt });
      }

      const body = await readJsonBody(req);

      if (url.pathname === '/v1/group') {
        return sendJson(res, 201, await createGroup(body));
      }
      if (url.pathname === '/v1/join') {
        return sendJson(res, 201, await joinGroup(body));
      }
      return sendJson(res, 404, { error: 'not_found' });
    } catch (err) {
      if (err instanceof StoreError) {
        return sendJson(res, ERROR_STATUS[err.code] ?? 400, { error: err.code });
      }
      logger.error('[http] unexpected error', err);
      return sendJson(res, 500, { error: 'internal' });
    }
  }

  function verifyRegistration(body) {
    const { nonce, publicKey, signature } = body;
    if (!isValidPublicKey(publicKey)) throw new StoreError('invalid_public_key');
    if (!challenges.consume(nonce)) throw new StoreError('invalid_nonce');
    if (!verifySignature(publicKey, registerMessage(nonce, publicKey), signature)) {
      throw new StoreError('invalid_signature');
    }
  }

  async function createGroup(body) {
    if (!config.setupToken) throw new StoreError('setup_disabled');
    if (store.hasGroup()) throw new StoreError('group_exists');
    const given = typeof body.setupToken === 'string' ? body.setupToken : '';
    const a = Buffer.from(given);
    const b = Buffer.from(config.setupToken);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
      throw new StoreError('invalid_setup_token');
    }
    verifyRegistration(body);
    const member = await store.createGroup({
      name: body.groupName,
      ownerPublicKey: body.publicKey,
      ownerName: body.deviceName,
    });
    logger.info('[group] created');
    return { self: member, group: { name: store.group.name }, members: store.members() };
  }

  async function joinGroup(body) {
    verifyRegistration(body);
    const member = await store.redeemInvite(body.inviteToken, {
      publicKey: body.publicKey,
      name: body.deviceName,
    });
    logger.info('[group] member joined');
    broadcast({ type: 'members.updated', members: store.members() });
    return { self: member, group: { name: store.group.name }, members: store.members() };
  }

  // ---------------------------------------------------------------------
  // WebSocket
  // ---------------------------------------------------------------------

  function send(ws, msg) {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
  }

  function broadcast(msg, { except } = {}) {
    for (const [deviceId, ws] of sockets) {
      if (deviceId !== except) send(ws, msg);
    }
  }

  function callState() {
    return {
      type: 'call.state',
      callId: call.id,
      participants: [...call.participants.entries()]
        .map(([deviceId, p]) => ({ deviceId, name: p.name, seq: p.seq }))
        .sort((a, b) => a.seq - b.seq),
    };
  }

  function leaveCall(deviceId) {
    if (!call.participants.delete(deviceId)) return;
    if (call.participants.size === 0) call.id = null;
    broadcast(callState());
  }

  async function joinCall(deviceId, member) {
    if (call.participants.has(deviceId)) {
      broadcast(callState());
      return;
    }
    if (call.participants.size >= MAX_MEMBERS) throw new StoreError('call_full');
    const wasEmpty = call.participants.size === 0;
    if (wasEmpty) call.id = crypto.randomUUID();
    call.participants.set(deviceId, { seq: ++call.seq, name: member.name });
    broadcast(callState());
    if (wasEmpty) ring(deviceId, member.name);
  }

  function ring(callerDeviceId, callerName) {
    if (!apns) return;
    const callId = call.id;
    for (const m of store.state.members) {
      if (m.deviceId === callerDeviceId || !m.voipToken) continue;
      apns
        .sendVoip(m.voipToken, { callId, callerName, groupName: store.group.name })
        .then((r) => {
          if (r.status !== 200) logger.warn(`[apns] push failed status=${r.status} body=${r.body}`);
        });
    }
  }

  function dropSocket(deviceId, ws, code, reason) {
    if (sockets.get(deviceId) === ws) sockets.delete(deviceId);
    leaveCall(deviceId);
    try {
      ws.close(code, reason);
    } catch {
      /* ignore */
    }
  }

  async function handleAuthenticated(ws, member, msg) {
    const deviceId = member.deviceId;
    switch (msg.type) {
      case 'ping':
        return send(ws, { type: 'pong' });

      case 'push.register': {
        const token = typeof msg.voipToken === 'string' && /^[0-9a-f]{1,512}$/i.test(msg.voipToken) ? msg.voipToken : null;
        if (!token) throw new StoreError('invalid_token');
        await store.setVoipToken(deviceId, token);
        return send(ws, { type: 'push.registered' });
      }

      case 'invite.create': {
        const { token, expiresAt } = await store.createInvite(deviceId);
        const url = `${config.inviteScheme}://join?server=${encodeURIComponent(config.publicUrl)}&token=${token}`;
        return send(ws, { type: 'invite.created', token, expiresAt, url });
      }

      case 'invite.revoke':
        if (!store.isOwner(deviceId)) throw new StoreError('forbidden');
        await store.revokeInvites();
        return send(ws, { type: 'invite.revoked' });

      case 'member.remove': {
        const target = typeof msg.deviceId === 'string' ? msg.deviceId : '';
        const selfLeave = target === deviceId;
        if (!selfLeave && !store.isOwner(deviceId)) throw new StoreError('forbidden');
        await store.removeMember(target);
        const victim = sockets.get(target);
        if (victim) {
          send(victim, { type: 'error', code: 'removed' });
          dropSocket(target, victim, 4001, 'removed');
        }
        broadcast({ type: 'members.updated', members: store.members() });
        return;
      }

      case 'call.join':
        return joinCall(deviceId, member);

      case 'call.leave':
        return leaveCall(deviceId);

      case 'signal': {
        const to = typeof msg.to === 'string' ? msg.to : '';
        if (!call.participants.has(deviceId) || !call.participants.has(to) || to === deviceId) {
          throw new StoreError('not_in_call');
        }
        if (!msg.payload || typeof msg.payload !== 'object') throw new StoreError('invalid_payload');
        const target = sockets.get(to);
        if (target) send(target, { type: 'signal', from: deviceId, payload: msg.payload });
        return;
      }

      default:
        throw new StoreError('unknown_type');
    }
  }

  function attachAuthenticated(ws, member) {
    const deviceId = member.deviceId;
    const previous = sockets.get(deviceId);
    if (previous && previous !== ws) {
      send(previous, { type: 'error', code: 'replaced' });
      dropSocket(deviceId, previous, 4000, 'replaced');
    }
    sockets.set(deviceId, ws);
    ws.isAlive = true;
    ws.on('pong', () => {
      ws.isAlive = true;
    });

    send(ws, {
      type: 'welcome',
      self: store.publicMember(member),
      group: { name: store.group.name, maxMembers: MAX_MEMBERS },
      members: store.members(),
      call: callState(),
      iceServers: buildIceServers({
        stunUrls: config.stunUrls,
        turnUrls: config.turnUrls,
        turnSecret: config.turnSecret,
        deviceId,
        now,
      }),
    });

    ws.on('message', async (data, isBinary) => {
      if (isBinary || data.length > MAX_WS_MESSAGE_BYTES) return dropSocket(deviceId, ws, 1009, 'too_large');
      let msg;
      try {
        msg = JSON.parse(data.toString('utf8'));
      } catch {
        return send(ws, { type: 'error', code: 'invalid_json' });
      }
      if (!msg || typeof msg.type !== 'string') return send(ws, { type: 'error', code: 'invalid_message' });
      // The member may have been removed while connected.
      if (!store.findMember(deviceId)) return dropSocket(deviceId, ws, 4001, 'removed');
      try {
        await handleAuthenticated(ws, store.findMember(deviceId), msg);
      } catch (err) {
        if (err instanceof StoreError) {
          send(ws, { type: 'error', code: err.code, inReplyTo: msg.type });
        } else {
          logger.error('[ws] unexpected error', err);
          send(ws, { type: 'error', code: 'internal', inReplyTo: msg.type });
        }
      }
    });

    ws.on('close', () => {
      if (sockets.get(deviceId) === ws) sockets.delete(deviceId);
      leaveCall(deviceId);
    });
  }

  function handleConnection(ws, req) {
    if (!limiter.allow(clientIp(req))) {
      ws.close(1013, 'rate_limited');
      return;
    }
    const { nonce } = challenges.issue();
    send(ws, { type: 'challenge', nonce });

    const timer = setTimeout(() => ws.close(4003, 'auth_timeout'), AUTH_TIMEOUT_MS);

    ws.once('message', (data, isBinary) => {
      clearTimeout(timer);
      let msg;
      try {
        msg = isBinary ? null : JSON.parse(data.toString('utf8'));
      } catch {
        msg = null;
      }
      if (!msg || msg.type !== 'auth' || !isValidPublicKey(msg.publicKey)) {
        send(ws, { type: 'error', code: 'unauthorized' });
        return ws.close(4003, 'unauthorized');
      }
      const member = store.findMember(deviceIdFor(msg.publicKey));
      const ok =
        member !== null &&
        challenges.consume(nonce) &&
        verifySignature(msg.publicKey, authMessage(nonce, msg.publicKey), msg.signature);
      if (!ok) {
        send(ws, { type: 'error', code: 'unauthorized' });
        return ws.close(4003, 'unauthorized');
      }
      attachAuthenticated(ws, member);
    });
  }

  // ---------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------

  const httpServer = http.createServer(handleHttp);
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_WS_MESSAGE_BYTES });
  wss.on('connection', handleConnection);

  httpServer.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname !== '/v1/ws') {
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  });

  const heartbeat = setInterval(() => {
    for (const [deviceId, ws] of sockets) {
      if (ws.isAlive === false) {
        dropSocket(deviceId, ws, 4004, 'heartbeat');
        continue;
      }
      ws.isAlive = false;
      ws.ping();
    }
  }, HEARTBEAT_MS);
  heartbeat.unref();

  function listen(port, host) {
    return new Promise((resolve) => httpServer.listen(port, host, () => resolve(httpServer.address())));
  }

  function close() {
    clearInterval(heartbeat);
    for (const ws of wss.clients) ws.terminate();
    return new Promise((resolve) => httpServer.close(() => resolve()));
  }

  return { httpServer, wss, listen, close, _call: call, _sockets: sockets };
}
