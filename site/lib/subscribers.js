// Email digest subscribers, per profile, in Vercel Blob:
//   subscribers/<name>/<random>.json →
//     { subscribers: [{ email, at, confirmed }], lastSentAt }
// The random suffix keeps the (public-access) file at an address nobody can
// guess: listing it needs the store's token. The first version lived at the
// guessable subscribers/<name>.json; load() moves it.
//
// Subscribing is double opt-in: an address only receives digests once its
// owner clicks the confirmation link. Links carry an HMAC of
// purpose|name|email (SUBSCRIBERS_SECRET), so they need no stored tokens.
import { createHmac, timingSafeEqual } from 'node:crypto';
import { del, list, put } from '@vercel/blob';

const prefixFor = (name) => `subscribers/${name}/`;
const legacyPath = (name) => `subscribers/${name}.json`;

const fetchJson = async (blob) => {
  const res = await fetch(`${blob.url}?v=${Date.parse(blob.uploadedAt) || 0}`,
      { cache: 'no-store' });
  return res.ok ? res.json() : null;
};

/// { subscribers, lastSentAt } for [name] (empty when nobody subscribed).
export async function loadSubscribers(name) {
  const { blobs } = await list({ prefix: prefixFor(name) });
  const newest = blobs.sort((a, b) =>
      Date.parse(b.uploadedAt) - Date.parse(a.uploadedAt))[0];
  if (newest) {
    const data = await fetchJson(newest);
    if (data) return { subscribers: [], lastSentAt: 0, ...data };
  }
  const legacy = (await list({ prefix: legacyPath(name) })).blobs
      .find((b) => b.pathname === legacyPath(name));
  if (legacy) {
    // Signed up before confirmation existed: they asked for it.
    const old = (await fetchJson(legacy)) ?? [];
    const data = {
      subscribers: old.map((s) => ({ ...s, confirmed: true })),
      lastSentAt: 0,
    };
    await saveSubscribers(name, data);
    return data;
  }
  return { subscribers: [], lastSentAt: 0 };
}

/// Replaces [name]'s list, then removes every older copy (and the legacy
/// guessable file).
export async function saveSubscribers(name, data) {
  const saved = await put(`${prefixFor(name)}list.json`, JSON.stringify(data), {
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

const secret = () => {
  const value = process.env.SUBSCRIBERS_SECRET;
  if (!value) throw new Error('SUBSCRIBERS_SECRET is not set');
  return value;
};

/// Signature for a confirm/unsubscribe link.
export function linkToken(purpose, name, email, key = secret()) {
  return createHmac('sha256', key)
      .update(`${purpose}|${name}|${email}`)
      .digest('hex')
      .slice(0, 32);
}

export function checkToken(purpose, name, email, token, key = secret()) {
  const expected = Buffer.from(linkToken(purpose, name, email, key));
  const given = Buffer.from(String(token ?? ''));
  return given.length === expected.length && timingSafeEqual(given, expected);
}

/// https://einkreader.app/api/subscribe?a=<purpose>&… — a signed link.
export function actionUrl(purpose, name, email, key) {
  const params = new URLSearchParams({
    a: purpose, name, email, t: linkToken(purpose, name, email, key),
  });
  return `https://einkreader.app/api/subscribe?${params}`;
}
