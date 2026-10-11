// Email digest subscribers, per profile, in Vercel Blob:
//   subscribers/<name>/<random>.json →
//     { subscribers: [{ id, enc, tz, at, confirmed, lastSentAt }] }
// - enc: the address, NIP-44 encrypted to the server's own Nostr key
//   (SERVER_NSEC): the stored file is useless without that key.
// - id: a keyed hash of the address (SUBSCRIBERS_SECRET), to find an entry
//   without decrypting every one; confirm/unsubscribe links carry it, never
//   the address.
// - tz: the subscriber's IANA time zone, so the digest arrives Saturday
//   7:00 their time.
// The random suffix keeps the file at an address nobody can guess. Older
// copies (a guessable subscribers/<name>.json, plain-text addresses) are
// converted on load.
//
// Subscribing is double opt-in: an address only receives digests once its
// owner clicks the confirmation link. Links carry an HMAC of
// purpose|name|id, so they need no stored tokens.
import { createHmac, timingSafeEqual } from 'node:crypto';
import { del, list, put } from '@vercel/blob';
import { hexToBytes } from '@noble/hashes/utils';
import * as nip19 from 'nostr-tools/nip19';
import * as nip44 from 'nostr-tools/nip44';
import { getPublicKey } from 'nostr-tools/pure';

const prefixFor = (name) => `subscribers/${name}/`;
const legacyPath = (name) => `subscribers/${name}.json`;

const env = (key) => {
  const value = process.env[key];
  if (!value) throw new Error(`${key} is not set`);
  return value;
};

/// The NIP-44 key the server encrypts addresses with: a conversation with
/// itself, so only SERVER_NSEC can open them. [nsec] is bech32 or hex.
export function storageKey(nsec = env('SERVER_NSEC')) {
  const sk = nsec.startsWith('nsec1')
      ? nip19.decode(nsec).data
      : hexToBytes(nsec);
  return nip44.getConversationKey(sk, getPublicKey(sk));
}

export const encryptEmail = (email, key = storageKey()) =>
  nip44.encrypt(email, key);
export const decryptEmail = (enc, key = storageKey()) =>
  nip44.decrypt(enc, key);

/// Stable lookup id for an address (keyed hash, not reversible).
export function subscriberId(email, secret = env('SUBSCRIBERS_SECRET')) {
  return createHmac('sha256', secret)
      .update(`id|${email.trim().toLowerCase()}`)
      .digest('hex')
      .slice(0, 24);
}

/// The time zone as given, when the runtime knows it; else UTC.
export function validTimeZone(tz) {
  try {
    if (typeof tz === 'string' && tz.length < 64) {
      new Intl.DateTimeFormat('en-US', { timeZone: tz });
      return tz;
    }
  } catch {}
  return 'UTC';
}

/// True when it's Saturday, 7:xx in [tz] at [now] and this subscriber
/// hasn't had a digest in the last 6 days.
export function digestDue(subscriber, now = new Date()) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
    timeZone: validTimeZone(subscriber.tz),
    weekday: 'short',
    hour: 'numeric',
    hourCycle: 'h23',
  }).formatToParts(now).map((p) => [p.type, p.value]));
  const sixDays = 6 * 24 * 3600 * 1000;
  return parts.weekday === 'Sat' && Number(parts.hour) === 7 &&
      (!subscriber.lastSentAt || now - subscriber.lastSentAt > sixDays);
}

const fetchJson = async (blob) => {
  const res = await fetch(`${blob.url}?v=${Date.parse(blob.uploadedAt) || 0}`,
      { cache: 'no-store' });
  return res.ok ? res.json() : null;
};

/// Encrypts any plain-text entry (written before encryption existed).
function upgrade(data) {
  let changed = false;
  const subscribers = (data.subscribers ?? []).map((s) => {
    if (!s.email) return s;
    changed = true;
    const { email, ...rest } = s;
    return {
      ...rest,
      id: subscriberId(email),
      enc: encryptEmail(email),
      tz: validTimeZone(s.tz),
      // Before per-subscriber dates, the list had one.
      lastSentAt: s.lastSentAt ?? data.lastSentAt ?? 0,
    };
  });
  return { changed, data: { subscribers } };
}

/// { subscribers } for [name] (empty when nobody subscribed).
export async function loadSubscribers(name) {
  const { blobs } = await list({ prefix: prefixFor(name) });
  const newest = blobs.sort((a, b) =>
      Date.parse(b.uploadedAt) - Date.parse(a.uploadedAt))[0];
  let raw = newest ? await fetchJson(newest) : null;
  if (!raw) {
    const legacy = (await list({ prefix: legacyPath(name) })).blobs
        .find((b) => b.pathname === legacyPath(name));
    // Signed up before confirmation existed: they asked for it.
    if (legacy) {
      raw = { subscribers: ((await fetchJson(legacy)) ?? [])
          .map((s) => ({ ...s, confirmed: true })) };
    }
  }
  if (!raw) return { subscribers: [] };
  const { changed, data } = upgrade(raw);
  if (changed || !newest) await saveSubscribers(name, data);
  return data;
}

/// Replaces [name]'s list, then removes every older copy (and the legacy
/// guessable file).
export async function saveSubscribers(name, data) {
  const saved = await put(`${prefixFor(name)}list.json`, JSON.stringify({
    subscribers: data.subscribers,
  }), {
    access: 'public',
    contentType: 'application/json',
    addRandomSuffix: true,
    cacheControlMaxAge: 60,
  });
  const { blobs } = await list({ prefix: prefixFor(name) });
  const stale = blobs.filter((b) => b.url !== saved.url).map((b) => b.url);
  const legacy = (await list({ prefix: legacyPath(name) })).blobs
      .filter((b) => b.pathname === legacyPath(name)).map((b) => b.url);
  if (stale.length || legacy.length) await del([...stale, ...legacy]);
}

/// Every profile name with a subscriber list.
export async function profilesWithSubscribers() {
  const names = new Set();
  let cursor;
  do {
    const page = await list({ prefix: 'subscribers/', cursor });
    for (const blob of page.blobs) {
      const m = /^subscribers\/([a-z0-9_]+)(\/|\.json$)/.exec(blob.pathname);
      if (m) names.add(m[1]);
    }
    cursor = page.hasMore ? page.cursor : undefined;
  } while (cursor);
  return [...names].sort();
}

/// Signature for a confirm/unsubscribe link about subscriber [id].
export function linkToken(purpose, name, id,
    secret = env('SUBSCRIBERS_SECRET')) {
  return createHmac('sha256', secret)
      .update(`${purpose}|${name}|${id}`)
      .digest('hex')
      .slice(0, 32);
}

export function checkToken(purpose, name, id, token, secret) {
  const expected = Buffer.from(linkToken(purpose, name, id, secret));
  const given = Buffer.from(String(token ?? ''));
  return given.length === expected.length && timingSafeEqual(given, expected);
}

/// https://einkreader.app/api/subscribe?a=<purpose>&… — a signed link.
export function actionUrl(purpose, name, id, secret) {
  const params = new URLSearchParams({
    a: purpose, name, id, t: linkToken(purpose, name, id, secret),
  });
  return `https://einkreader.app/api/subscribe?${params}`;
}
