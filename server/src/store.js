// Persistent state for the one and only group.
//
// Design rules (these are the whole point of the app):
//   * Exactly one group can ever exist on a server.
//   * At most MAX_MEMBERS devices belong to it.
//   * A device gets in only by redeeming a single-use, short-lived invite that
//     was created by the group's owner. Nothing else adds a member.
//   * Invite tokens are stored hashed, so a copy of the data file cannot be
//     used to join.

import { promises as fs } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { deviceIdFor, isValidPublicKey } from './auth.js';

export const MAX_MEMBERS = 5;
export const INVITE_TTL_MS = 10 * 60 * 1000;
export const MAX_NAME_LENGTH = 20;

const INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I
const INVITE_LENGTH = 16; // 16 * 5 bits = 80 bits of entropy

export class StoreError extends Error {
  constructor(code, message) {
    super(message ?? code);
    this.code = code;
  }
}

export function sanitizeName(name) {
  if (typeof name !== 'string') throw new StoreError('invalid_name');
  const cleaned = name.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  if (cleaned.length === 0 || [...cleaned].length > MAX_NAME_LENGTH) {
    throw new StoreError('invalid_name');
  }
  return cleaned;
}

export function normalizeInviteToken(token) {
  if (typeof token !== 'string') return null;
  const cleaned = token.toUpperCase().replace(/[^A-Z2-9]/g, '');
  return cleaned.length === INVITE_LENGTH ? cleaned : null;
}

function generateInviteToken() {
  const bytes = crypto.randomBytes(INVITE_LENGTH);
  let out = '';
  for (const b of bytes) out += INVITE_ALPHABET[b % INVITE_ALPHABET.length];
  return out;
}

function hashToken(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}

function emptyState() {
  return { version: 1, group: null, members: [], invites: [] };
}

export class GroupStore {
  constructor(filePath, { now = () => Date.now() } = {}) {
    this.filePath = filePath;
    this.now = now;
    this.state = emptyState();
    this.writeChain = Promise.resolve();
  }

  async load() {
    try {
      const raw = await fs.readFile(this.filePath, 'utf8');
      const parsed = JSON.parse(raw);
      this.state = { ...emptyState(), ...parsed };
    } catch (err) {
      if (err.code !== 'ENOENT') throw err;
      this.state = emptyState();
    }
    return this;
  }

  save() {
    const snapshot = JSON.stringify(this.state, null, 2);
    this.writeChain = this.writeChain.then(async () => {
      await fs.mkdir(path.dirname(this.filePath), { recursive: true });
      const tmp = `${this.filePath}.${process.pid}.tmp`;
      await fs.writeFile(tmp, snapshot, { mode: 0o600 });
      await fs.rename(tmp, this.filePath);
    });
    return this.writeChain;
  }

  // ---- group -------------------------------------------------------------

  hasGroup() {
    return this.state.group !== null;
  }

  get group() {
    return this.state.group;
  }

  isOwner(deviceId) {
    return this.state.group?.ownerDeviceId === deviceId;
  }

  async createGroup({ name, ownerPublicKey, ownerName }) {
    if (this.hasGroup()) throw new StoreError('group_exists');
    if (!isValidPublicKey(ownerPublicKey)) throw new StoreError('invalid_public_key');
    const groupName = sanitizeName(name);
    const memberName = sanitizeName(ownerName);
    const deviceId = deviceIdFor(ownerPublicKey);
    const createdAt = this.now();
    this.state.group = { name: groupName, ownerDeviceId: deviceId, createdAt };
    this.state.members = [{ deviceId, name: memberName, publicKey: ownerPublicKey, createdAt }];
    this.state.invites = [];
    await this.save();
    return this.publicMember(this.state.members[0]);
  }

  // ---- members -----------------------------------------------------------

  members() {
    return this.state.members.map((m) => this.publicMember(m));
  }

  publicMember(m) {
    return {
      deviceId: m.deviceId,
      name: m.name,
      isOwner: this.isOwner(m.deviceId),
      createdAt: m.createdAt,
    };
  }

  findMember(deviceId) {
    return this.state.members.find((m) => m.deviceId === deviceId) ?? null;
  }

  findMemberByPublicKey(publicKey) {
    if (!isValidPublicKey(publicKey)) return null;
    return this.findMember(deviceIdFor(publicKey));
  }

  async removeMember(deviceId) {
    if (this.isOwner(deviceId)) throw new StoreError('cannot_remove_owner');
    const before = this.state.members.length;
    this.state.members = this.state.members.filter((m) => m.deviceId !== deviceId);
    if (this.state.members.length === before) throw new StoreError('not_found');
    await this.save();
  }

  async setVoipToken(deviceId, token) {
    const member = this.findMember(deviceId);
    if (!member) throw new StoreError('not_found');
    member.voipToken = token ?? undefined;
    await this.save();
  }

  // ---- invites -----------------------------------------------------------

  pruneInvites() {
    const t = this.now();
    this.state.invites = this.state.invites.filter((i) => i.expiresAt > t);
  }

  async createInvite(byDeviceId) {
    if (!this.hasGroup()) throw new StoreError('no_group');
    if (!this.isOwner(byDeviceId)) throw new StoreError('forbidden');
    this.pruneInvites();
    if (this.state.members.length >= MAX_MEMBERS) throw new StoreError('group_full');
    // Only one live invite at a time keeps the attack surface tiny.
    this.state.invites = [];
    const token = generateInviteToken();
    const expiresAt = this.now() + INVITE_TTL_MS;
    this.state.invites.push({ tokenHash: hashToken(token), createdBy: byDeviceId, expiresAt });
    await this.save();
    return { token, expiresAt };
  }

  async revokeInvites() {
    this.state.invites = [];
    await this.save();
  }

  async redeemInvite(rawToken, { publicKey, name }) {
    if (!this.hasGroup()) throw new StoreError('no_group');
    this.pruneInvites();
    const token = normalizeInviteToken(rawToken);
    if (!token) throw new StoreError('invalid_invite');
    const wanted = Buffer.from(hashToken(token), 'hex');
    const idx = this.state.invites.findIndex((i) =>
      crypto.timingSafeEqual(Buffer.from(i.tokenHash, 'hex'), wanted),
    );
    if (idx === -1) throw new StoreError('invalid_invite');
    if (!isValidPublicKey(publicKey)) throw new StoreError('invalid_public_key');
    const memberName = sanitizeName(name);
    if (this.state.members.length >= MAX_MEMBERS) {
      this.state.invites.splice(idx, 1);
      await this.save();
      throw new StoreError('group_full');
    }
    const deviceId = deviceIdFor(publicKey);
    if (this.findMember(deviceId)) throw new StoreError('already_member');
    // Single use: burn the invite before adding the member.
    this.state.invites.splice(idx, 1);
    const member = { deviceId, name: memberName, publicKey, createdAt: this.now() };
    this.state.members.push(member);
    await this.save();
    return this.publicMember(member);
  }
}
