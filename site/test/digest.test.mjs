// Email digest rendering, signed subscribe links, and the server-side
// event cache's merge/validation rules.
import assert from 'node:assert/strict';
import { schnorr } from '@noble/curves/secp256k1';
import { bytesToHex } from '@noble/hashes/utils';
import { buildDigest, highlightsSince } from '../lib/digest.js';
import { mergeEvents, validEvent } from '../lib/profile_cache.js';
import { eventId } from '../lib/registry.js';
import { actionUrl, checkToken, linkToken } from '../lib/subscribers.js';

const key = 'test-secret';
const sk = schnorr.utils.randomPrivateKey();
const pubkey = bytesToHex(schnorr.getPublicKey(sk));
const sign = (fields) => {
  const event = { pubkey, tags: [], content: '', ...fields };
  event.id = eventId(event);
  event.sig = bytesToHex(schnorr.sign(event.id, sk));
  return event;
};

const h1 = sign({ kind: 9802, created_at: 1000, content: 'First <quote>',
  tags: [['r', 'https://example.com/a'], ['title', 'Story A'],
    ['comment', 'So true']] });
const h2 = sign({ kind: 9802, created_at: 2000, content: 'Second quote',
  tags: [['r', 'https://example.com/b'], ['title', 'Story B']] });
const old = sign({ kind: 9802, created_at: 10, content: 'Old',
  tags: [['title', 'Old story']] });

// Digest: only the period's highlights, grouped by story, escaped.
const events = highlightsSince([h1, h2, old], 500);
assert.equal(events.length, 2);
const digest = buildDigest({ name: 'xavier', displayName: 'Xavier',
  events, unsubscribeUrl: 'https://einkreader.app/u?x=1' });
assert.equal(digest.subject, 'Xavier: 2 new highlights from "Story B" and 1 more');
assert.match(digest.html, /First &lt;quote&gt;/);
assert.match(digest.html, /So true/);
assert.match(digest.html, /https:\/\/einkreader.app\/u\?x=1/);
assert.doesNotMatch(digest.html, /Old/);
assert.match(digest.text, /> Second quote/);
assert.match(buildDigest({ name: 'x', displayName: 'X', events: [h1],
  unsubscribeUrl: 'u', test: true }).subject, /^\[Test\] X: 1 new highlight /);

// Signed links: bound to purpose, profile and address.
const token = linkToken('confirm', 'xavier', 'a@b.co', key);
assert.ok(checkToken('confirm', 'xavier', 'a@b.co', token, key));
assert.ok(!checkToken('unsubscribe', 'xavier', 'a@b.co', token, key));
assert.ok(!checkToken('confirm', 'xavier', 'c@b.co', token, key));
assert.ok(!checkToken('confirm', 'xavier', 'a@b.co', 'nope', key));
assert.match(actionUrl('unsubscribe', 'xavier', 'a@b.co', key),
    /^https:\/\/einkreader\.app\/api\/subscribe\?a=unsubscribe&name=xavier&email=a%40b\.co&t=[0-9a-f]{32}$/);

// Event cache: signed events of the cached kinds by the author only.
assert.ok(validEvent(h1, pubkey));
assert.ok(!validEvent({ ...h1, content: 'tampered' }, pubkey));
assert.ok(!validEvent(h1, 'f'.repeat(64)));
assert.ok(!validEvent(sign({ kind: 1, created_at: 5 }), pubkey));

// Merge: dedup by id, newest profile only, newest first.
const p1 = sign({ kind: 0, created_at: 100, content: '{"name":"Old"}' });
const p2 = sign({ kind: 0, created_at: 200, content: '{"name":"New"}' });
const merged = mergeEvents([h1, p1], [h1, h2, p2]);
assert.equal(merged.added, 2);
assert.deepEqual(merged.events.map((e) => e.id), [h2.id, h1.id, p2.id]);

console.log('digest tests passed');
