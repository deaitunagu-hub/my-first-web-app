import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { GroupStore, INVITE_TTL_MS, MAX_MEMBERS, normalizeInviteToken } from '../src/store.js';
import { generateDeviceKeyPair } from '../src/auth.js';

async function freshStore(clock) {
  const dir = await mkdtemp(path.join(tmpdir(), 'kidscall-'));
  const file = path.join(dir, 'group.json');
  return { store: await new GroupStore(file, clock).load(), file };
}

test('only one group can ever be created', async () => {
  const { store } = await freshStore();
  const owner = generateDeviceKeyPair();
  const member = await store.createGroup({ name: 'family', ownerPublicKey: owner.publicKey, ownerName: 'mom' });
  assert.equal(member.isOwner, true);
  await assert.rejects(
    store.createGroup({ name: 'x', ownerPublicKey: generateDeviceKeyPair().publicKey, ownerName: 'y' }),
    { code: 'group_exists' },
  );
});

test('invites are owner-only, single-use, expiring and capped at five members', async () => {
  let t = 1_000_000;
  const { store } = await freshStore({ now: () => t });
  const owner = generateDeviceKeyPair();
  const ownerMember = await store.createGroup({ name: 'family', ownerPublicKey: owner.publicKey, ownerName: 'mom' });

  // Non-member / non-owner cannot invite.
  await assert.rejects(store.createInvite('nobody'), { code: 'forbidden' });

  const { token } = await store.createInvite(ownerMember.deviceId);
  assert.equal(token.length, 16);
  assert.match(token, /^[A-HJ-NP-Z2-9]+$/);

  // Wrong token.
  await assert.rejects(store.redeemInvite('AAAAAAAAAAAAAAAA', { publicKey: generateDeviceKeyPair().publicKey, name: 'x' }), {
    code: 'invalid_invite',
  });

  // Redeem once; second use fails.
  const kid = generateDeviceKeyPair();
  const kidMember = await store.redeemInvite(token.toLowerCase(), { publicKey: kid.publicKey, name: 'kid' });
  assert.equal(kidMember.isOwner, false);
  await assert.rejects(store.redeemInvite(token, { publicKey: generateDeviceKeyPair().publicKey, name: 'x' }), {
    code: 'invalid_invite',
  });

  // Non-owner member cannot invite either.
  await assert.rejects(store.createInvite(kidMember.deviceId), { code: 'forbidden' });

  // Expired invite.
  const { token: expiring } = await store.createInvite(ownerMember.deviceId);
  t += INVITE_TTL_MS + 1;
  await assert.rejects(store.redeemInvite(expiring, { publicKey: generateDeviceKeyPair().publicKey, name: 'x' }), {
    code: 'invalid_invite',
  });

  // Fill up to MAX_MEMBERS.
  while (store.members().length < MAX_MEMBERS) {
    const { token: tk } = await store.createInvite(ownerMember.deviceId);
    await store.redeemInvite(tk, { publicKey: generateDeviceKeyPair().publicKey, name: 'm' });
  }
  assert.equal(store.members().length, 5);
  await assert.rejects(store.createInvite(ownerMember.deviceId), { code: 'group_full' });

  // Remove one, invite again works; owner cannot be removed.
  await assert.rejects(store.removeMember(ownerMember.deviceId), { code: 'cannot_remove_owner' });
  await store.removeMember(kidMember.deviceId);
  assert.equal(store.members().length, 4);
  const { token: again } = await store.createInvite(ownerMember.deviceId);
  await assert.rejects(store.redeemInvite(again, { publicKey: owner.publicKey, name: 'dup' }), { code: 'already_member' });
});

test('invite tokens are stored hashed and state survives reload', async () => {
  const { store, file } = await freshStore();
  const owner = generateDeviceKeyPair();
  const ownerMember = await store.createGroup({ name: 'family', ownerPublicKey: owner.publicKey, ownerName: 'mom' });
  const { token } = await store.createInvite(ownerMember.deviceId);
  const raw = await readFile(file, 'utf8');
  assert.ok(!raw.includes(token), 'plain invite token must not be persisted');

  const reloaded = await new GroupStore(file).load();
  assert.equal(reloaded.group.name, 'family');
  assert.equal(reloaded.members().length, 1);
  const kid = generateDeviceKeyPair();
  await reloaded.redeemInvite(token, { publicKey: kid.publicKey, name: 'kid' });
  assert.equal(reloaded.members().length, 2);
});

test('names are sanitized', async () => {
  const { store } = await freshStore();
  await assert.rejects(store.createGroup({ name: '   ', ownerPublicKey: generateDeviceKeyPair().publicKey, ownerName: 'a' }), {
    code: 'invalid_name',
  });
  await assert.rejects(
    store.createGroup({ name: 'x'.repeat(21), ownerPublicKey: generateDeviceKeyPair().publicKey, ownerName: 'a' }),
    { code: 'invalid_name' },
  );
  assert.equal(normalizeInviteToken('abcd-efgh-jklm-npqr'), 'ABCDEFGHJKLMNPQR');
  assert.equal(normalizeInviteToken('short'), null);
});
