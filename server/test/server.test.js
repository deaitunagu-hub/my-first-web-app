import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import WebSocket from 'ws';
import { GroupStore } from '../src/store.js';
import { createApp } from '../src/server.js';
import { authMessage, generateDeviceKeyPair, registerMessage } from '../src/auth.js';

const quiet = { info() {}, warn() {}, error: console.error };

async function startServer({ apns = null } = {}) {
  const dir = await mkdtemp(path.join(tmpdir(), 'kidscall-srv-'));
  const store = await new GroupStore(path.join(dir, 'group.json')).load();
  const config = {
    setupToken: 'setup-secret',
    publicUrl: 'https://call.example.test',
    inviteScheme: 'kidscall',
    stunUrls: ['stun:turn.example.test:3478'],
    turnUrls: ['turn:turn.example.test:3478?transport=udp'],
    turnSecret: 'turn-secret',
  };
  const app = createApp({ store, config, apns, logger: quiet });
  const address = await app.listen(0, '127.0.0.1');
  const base = `http://127.0.0.1:${address.port}`;
  return { app, store, base };
}

async function post(base, pathname, body) {
  const res = await fetch(base + pathname, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
}

async function challenge(base) {
  return (await post(base, '/v1/challenge', {})).body.nonce;
}

async function createGroup(base, kp, extra = {}) {
  const nonce = await challenge(base);
  return post(base, '/v1/group', {
    setupToken: 'setup-secret',
    groupName: 'family',
    deviceName: 'mom',
    nonce,
    publicKey: kp.publicKey,
    signature: kp.sign(registerMessage(nonce, kp.publicKey)),
    ...extra,
  });
}

async function join(base, kp, inviteToken, name = 'kid') {
  const nonce = await challenge(base);
  return post(base, '/v1/join', {
    inviteToken,
    deviceName: name,
    nonce,
    publicKey: kp.publicKey,
    signature: kp.sign(registerMessage(nonce, kp.publicKey)),
  });
}

/** Tiny test client with a message queue. */
class Client {
  constructor(base, kp) {
    this.kp = kp;
    this.ws = new WebSocket(base.replace('http', 'ws') + '/v1/ws');
    this.queue = [];
    this.waiters = [];
    this.closed = new Promise((resolve) => this.ws.on('close', (code) => resolve(code)));
    this.ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      const w = this.waiters.shift();
      if (w) w(msg);
      else this.queue.push(msg);
    });
  }

  next(timeoutMs = 2000) {
    if (this.queue.length) return Promise.resolve(this.queue.shift());
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timeout waiting for message')), timeoutMs);
      this.waiters.push((m) => {
        clearTimeout(timer);
        resolve(m);
      });
    });
  }

  async until(type) {
    for (;;) {
      const m = await this.next();
      if (m.type === type) return m;
    }
  }

  send(msg) {
    this.ws.send(JSON.stringify(msg));
  }

  async connectAndAuth({ tamper = false } = {}) {
    await new Promise((resolve) => this.ws.on('open', resolve));
    const ch = await this.next();
    assert.equal(ch.type, 'challenge');
    const msg = authMessage(tamper ? 'wrong' : ch.nonce, this.kp.publicKey);
    this.send({ type: 'auth', publicKey: this.kp.publicKey, signature: this.kp.sign(msg) });
    return this.next();
  }

  close() {
    this.ws.close();
  }
}

test('full flow: create group, invite, join, cap at 5, signaling, removal', async (t) => {
  const pushes = [];
  const apns = {
    sendVoip: async (token, payload) => {
      pushes.push({ token, payload });
      return { status: 200, body: '' };
    },
  };
  const { app, store, base } = await startServer({ apns });
  t.after(() => app.close());

  const owner = generateDeviceKeyPair();

  // Wrong setup token is rejected and does not create anything.
  const bad = await createGroup(base, owner, { setupToken: 'nope' });
  assert.equal(bad.status, 403);
  assert.equal(store.hasGroup(), false);

  // Bad signature is rejected.
  const badSig = await createGroup(base, owner, { signature: generateDeviceKeyPair().sign('x') });
  assert.equal(badSig.status, 401);

  const created = await createGroup(base, owner);
  assert.equal(created.status, 201);
  assert.equal(created.body.self.isOwner, true);

  // Second group impossible.
  const again = await createGroup(base, generateDeviceKeyPair());
  assert.equal(again.status, 409);

  // Unregistered device cannot open a socket.
  const stranger = new Client(base, generateDeviceKeyPair());
  const strangerReply = await stranger.connectAndAuth();
  assert.equal(strangerReply.type, 'error');
  assert.equal(strangerReply.code, 'unauthorized');
  assert.equal(await stranger.closed, 4003);

  // Registered device with a bad signature is rejected too.
  const forged = new Client(base, owner);
  assert.equal((await forged.connectAndAuth({ tamper: true })).code, 'unauthorized');
  await forged.closed;

  // Owner connects.
  const ownerClient = new Client(base, owner);
  const welcome = await ownerClient.connectAndAuth();
  assert.equal(welcome.type, 'welcome');
  assert.equal(welcome.self.isOwner, true);
  assert.equal(welcome.group.maxMembers, 5);
  assert.equal(welcome.iceServers.length, 2);
  assert.match(welcome.iceServers[1].username, /^\d+:[0-9a-f]{32}$/);

  ownerClient.send({ type: 'push.register', voipToken: 'abcdef0123' });
  assert.equal((await ownerClient.next()).type, 'push.registered');

  // Invite + join four more devices.
  const kids = [];
  for (let i = 0; i < 4; i++) {
    ownerClient.send({ type: 'invite.create' });
    const inv = await ownerClient.until('invite.created');
    assert.match(inv.url, /^kidscall:\/\/join\?server=https%3A%2F%2Fcall\.example\.test&token=[A-Z2-9]{16}$/);
    const kp = generateDeviceKeyPair();
    const res = await join(base, kp, inv.token, `kid${i}`);
    assert.equal(res.status, 201, JSON.stringify(res.body));
    kids.push(kp);
    const upd = await ownerClient.until('members.updated');
    assert.equal(upd.members.length, i + 2);
  }
  assert.equal(store.members().length, 5);

  // Sixth device: invite creation refuses, and a stale token would not work anyway.
  ownerClient.send({ type: 'invite.create' });
  const full = await ownerClient.until('error');
  assert.equal(full.code, 'group_full');

  // A kid cannot create invites.
  const kidClient = new Client(base, kids[0]);
  assert.equal((await kidClient.connectAndAuth()).type, 'welcome');
  kidClient.send({ type: 'invite.create' });
  assert.equal((await kidClient.until('error')).code, 'forbidden');

  // Calls: owner joins -> ring pushes go to members with tokens (none yet except owner itself).
  ownerClient.send({ type: 'call.join' });
  let state = await ownerClient.until('call.state');
  assert.equal(state.participants.length, 1);
  assert.ok(state.callId);
  assert.equal(pushes.length, 0, 'caller must not be pushed');

  kidClient.send({ type: 'push.register', voipToken: 'ffff' });
  await kidClient.until('push.registered');

  // Signal from someone not in the call is rejected.
  kidClient.send({ type: 'signal', to: welcome.self.deviceId, payload: { type: 'offer', sdp: 'x' } });
  assert.equal((await kidClient.until('error')).code, 'not_in_call');

  kidClient.send({ type: 'call.join' });
  state = await kidClient.until('call.state');
  assert.equal(state.participants.length, 2);
  assert.ok(state.participants[0].seq < state.participants[1].seq);
  await ownerClient.until('call.state');

  // Signaling is relayed verbatim between participants.
  kidClient.send({ type: 'signal', to: welcome.self.deviceId, payload: { type: 'offer', sdp: 'v=0' } });
  const relayed = await ownerClient.until('signal');
  assert.deepEqual(relayed.payload, { type: 'offer', sdp: 'v=0' });
  assert.equal(relayed.from, store.members()[1].deviceId);

  // Leaving and rejoining an empty call rings the kid (who now has a token).
  ownerClient.send({ type: 'call.leave' });
  kidClient.send({ type: 'call.leave' });
  await ownerClient.until('call.state');
  await kidClient.until('call.state');
  ownerClient.send({ type: 'call.join' });
  await ownerClient.until('call.state');
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].token, 'ffff');
  assert.equal(pushes[0].payload.callerName, 'mom');

  // Kid cannot remove others; owner can. Removed device's socket is closed.
  const kidId = store.members()[1].deviceId;
  kidClient.send({ type: 'member.remove', deviceId: welcome.self.deviceId });
  assert.equal((await kidClient.until('error')).code, 'forbidden');
  ownerClient.send({ type: 'member.remove', deviceId: kidId });
  assert.equal((await kidClient.until('error')).code, 'removed');
  assert.equal(await kidClient.closed, 4001);
  assert.equal(store.members().length, 4);

  // Removed device can no longer authenticate.
  const ghost = new Client(base, kids[0]);
  assert.equal((await ghost.connectAndAuth()).code, 'unauthorized');
  await ghost.closed;

  // Disconnect drops the participant from the call.
  ownerClient.close();
  await ownerClient.closed;
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(app._call.participants.size, 0);
  assert.equal(app._call.id, null);
});

test('registration is disabled when SETUP_TOKEN is unset', async (t) => {
  const dir = await mkdtemp(path.join(tmpdir(), 'kidscall-srv-'));
  const store = await new GroupStore(path.join(dir, 'group.json')).load();
  const app = createApp({ store, config: { setupToken: null, publicUrl: 'x', inviteScheme: 'kidscall', stunUrls: [], turnUrls: [] }, logger: quiet });
  const address = await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  const base = `http://127.0.0.1:${address.port}`;
  const res = await createGroup(base, generateDeviceKeyPair());
  assert.equal(res.status, 403);
  assert.equal(res.body.error, 'setup_disabled');
  const joinRes = await join(base, generateDeviceKeyPair(), 'AAAAAAAAAAAAAAAA');
  assert.equal(joinRes.status, 404);
  assert.equal(joinRes.body.error, 'no_group');
});

test('second connection from the same device replaces the first', async (t) => {
  const { app, base } = await startServer();
  t.after(() => app.close());
  const owner = generateDeviceKeyPair();
  assert.equal((await createGroup(base, owner)).status, 201);
  const a = new Client(base, owner);
  assert.equal((await a.connectAndAuth()).type, 'welcome');
  const b = new Client(base, owner);
  assert.equal((await b.connectAndAuth()).type, 'welcome');
  assert.equal((await a.until('error')).code, 'replaced');
  assert.equal(await a.closed, 4000);
  b.close();
});
