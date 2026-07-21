// Run with: npm test (inside site/). Covers the pure logic: name rules,
// signature verification round-trip, and registration conflicts/renames.
import assert from 'node:assert/strict';
import { schnorr } from '@noble/curves/secp256k1';
import { bytesToHex } from '@noble/hashes/utils';
import {
  NAME_RULE,
  RESERVED,
  applyRegistration,
  eventId,
  verifyAuthEvent,
} from '../lib/registry.js';

// -- name rules ------------------------------------------------------------
assert.ok(NAME_RULE.test('xavier'));
assert.ok(NAME_RULE.test('x_1234'));
assert.ok(!NAME_RULE.test('xavi'), 'under 5 chars rejected');
assert.ok(!NAME_RULE.test('Xavier'), 'uppercase rejected');
assert.ok(!NAME_RULE.test('xa vier'), 'space rejected');
assert.ok(!NAME_RULE.test('xavier!'), 'punctuation rejected');
assert.ok(!NAME_RULE.test('a'.repeat(21)), 'over 20 chars rejected');
assert.ok(RESERVED.has('einkreader'));

// -- auth event round-trip -------------------------------------------------
const secret = bytesToHex(schnorr.utils.randomPrivateKey());
const pubkey = bytesToHex(schnorr.getPublicKey(secret));
const now = Math.floor(Date.now() / 1000);

function signed(name, { kind = 27235, createdAt = now } = {}) {
  const event = {
    pubkey,
    created_at: createdAt,
    kind,
    tags: [],
    content: name,
  };
  event.id = eventId(event);
  event.sig = bytesToHex(schnorr.sign(event.id, secret));
  return event;
}

assert.equal(verifyAuthEvent(signed('xavier'), { name: 'xavier' }), null);
assert.match(
  verifyAuthEvent(signed('other'), { name: 'xavier' }) ?? '',
  /does not name/);
assert.match(
  verifyAuthEvent(signed('xavier', { createdAt: now - 3600 }),
      { name: 'xavier' }) ?? '',
  /expired/);
assert.match(
  verifyAuthEvent(signed('xavier', { kind: 1 }), { name: 'xavier' }) ?? '',
  /kind/);
const tampered = signed('xavier');
tampered.content = 'mallory';
assert.match(verifyAuthEvent(tampered, { name: 'mallory' }) ?? '', /bad event id/);
const badSig = signed('xavier');
badSig.sig = badSig.sig.replace(/^../, badSig.sig.startsWith('00') ? '11' : '00');
assert.match(verifyAuthEvent(badSig, { name: 'xavier' }) ?? '', /signature/);

// -- registration ----------------------------------------------------------
const registry = {};
assert.equal(
  applyRegistration(registry, { name: 'xavier', pubkey: 'a'.repeat(64) })
      .status,
  200);
// Same name, same key: idempotent.
assert.equal(
  applyRegistration(registry, { name: 'xavier', pubkey: 'a'.repeat(64) })
      .status,
  200);
// Same name, other key: conflict.
assert.equal(
  applyRegistration(registry, { name: 'xavier', pubkey: 'b'.repeat(64) })
      .status,
  409);
// Rename replaces the old entry for that key.
const rename =
    applyRegistration(registry, { name: 'xdamman', pubkey: 'a'.repeat(64) });
assert.equal(rename.status, 200);
assert.equal(rename.body.nip05, 'xdamman@einkreader.app');
assert.equal(registry.xavier, undefined, 'old name released on rename');
assert.equal(registry.xdamman, 'a'.repeat(64));

console.log('registry tests passed');
