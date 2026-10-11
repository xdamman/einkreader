// Email digest rendering, signed subscribe links, and the server-side
// event cache's merge/validation rules.
import assert from 'node:assert/strict';
import { schnorr } from '@noble/curves/secp256k1';
import { bytesToHex } from '@noble/hashes/utils';
import { buildDigest, highlightsSince } from '../lib/digest.js';
import { mergeEvents, profileMeta, validEvent } from '../lib/profile_cache.js';
import { eventId } from '../lib/registry.js';
import { actionUrl, checkToken, decryptEmail, digestDue, encryptEmail,
  linkToken, storageKey, subscriberId, validTimeZone }
  from '../lib/subscribers.js';

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
assert.match(digest.html, /Shared January 1, 1970/);
assert.match(buildDigest({ name: 'x', displayName: 'X', about: 'Dad & reader', events: [h1], unsubscribeUrl: 'u' }).html, /Dad &amp; reader/);
assert.match(digest.html, /https:\/\/einkreader.app\/u\?x=1/);
assert.doesNotMatch(digest.html, /Old/);
assert.match(digest.text, /> Second quote/);
assert.match(buildDigest({ name: 'x', displayName: 'X', events: [h1],
  unsubscribeUrl: 'u', test: true }).subject, /^\[Test\] X: 1 new highlight /);

// Signed links: bound to purpose, profile and subscriber id; they never
// carry the address.
const id = subscriberId('A@b.co ', key);
assert.equal(id, subscriberId('a@b.co', key));
assert.match(id, /^[0-9a-f]{24}$/);
const token = linkToken('confirm', 'xavier', id, key);
assert.ok(checkToken('confirm', 'xavier', id, token, key));
assert.ok(!checkToken('unsubscribe', 'xavier', id, token, key));
assert.ok(!checkToken('confirm', 'xavier', subscriberId('c@b.co', key), token, key));
assert.ok(!checkToken('confirm', 'xavier', id, 'nope', key));
const url = actionUrl('unsubscribe', 'xavier', id, key);
assert.match(url, /^https:\/\/einkreader\.app\/api\/subscribe\?a=unsubscribe&name=xavier&id=[0-9a-f]{24}&t=[0-9a-f]{32}$/);
assert.doesNotMatch(url, /b\.co/);

// Addresses are stored encrypted to the server's key: only it decrypts.
const serverKey = storageKey(bytesToHex(schnorr.utils.randomPrivateKey()));
const otherKey = storageKey(bytesToHex(schnorr.utils.randomPrivateKey()));
const enc = encryptEmail('reader@example.com', serverKey);
assert.doesNotMatch(enc, /reader|example/);
assert.equal(decryptEmail(enc, serverKey), 'reader@example.com');
assert.throws(() => decryptEmail(enc, otherKey));

// Saturday 7:xx in the subscriber's own time zone, at most once a week.
const sat7Brussels = new Date('2026-10-17T05:30:00Z'); // 07:30 CEST
assert.ok(digestDue({ tz: 'Europe/Brussels' }, sat7Brussels));
assert.ok(!digestDue({ tz: 'America/New_York' }, sat7Brussels)); // 01:30
assert.ok(digestDue({ tz: 'America/New_York' },
    new Date('2026-10-17T11:10:00Z'))); // 07:10 EDT
assert.ok(!digestDue({ tz: 'Europe/Brussels' },
    new Date('2026-10-16T05:30:00Z'))); // Friday
assert.ok(!digestDue({ tz: 'Europe/Brussels',
  lastSentAt: sat7Brussels.getTime() - 3600 * 1000 }, sat7Brussels));
assert.equal(validTimeZone('Not/AZone'), 'UTC');
assert.equal(validTimeZone('Asia/Kolkata'), 'Asia/Kolkata');

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

// Profile links: the website, then the other links published as "r" tags.
const meta = profileMeta([{ kind: 0, created_at: 1, tags: [
  ['r', 'https://x.com/xdamman'], ['r', 'javascript:alert(1)'],
  ['r', 'https://xavierdamman.com']],
content: JSON.stringify({ name: 'Xavier', website: 'https://xavierdamman.com' }) }]);
assert.deepEqual(meta.links, ['https://xavierdamman.com', 'https://x.com/xdamman']);
assert.deepEqual(profileMeta([]).links, []);

console.log('digest tests passed');
