// Server-side cache of each registered author's public Nostr events
// (profile metadata, kind 0, and shared highlights, kind 9802), so profile
// pages, feeds and digests render without waiting on relays.
//
// One Blob per author: profiles/<pubkey>.json = { events, syncedAt }.
// It is fed three ways:
//   - /api/profile-event: signed events pushed by the listener
//     (infra/profile-listener), which follows every registered author on
//     the relays and forwards anything new within seconds;
//   - a relay query when the cache is missing or stale (older than
//     STALE_MS), in the background for a stale one;
//   - nothing else: events are public and self-authenticating, so the
//     cache never holds anything a relay wouldn't serve.
// Cached pages carry the cache tag `profile-<name>`; a change invalidates
// that tag, so only that author's pages are regenerated.
import { list, put } from '@vercel/blob';
import { schnorr } from '@noble/curves/secp256k1';
import { queryRelays } from './relay.js';
import { eventId } from './registry.js';

export const KINDS = [0, 9802];
export const STALE_MS = 15 * 60 * 1000;
const MAX_EVENTS = 1000;

export const tagFor = (name) => `profile-${name}`;

const pathFor = (pubkey) => `profiles/${pubkey}.json`;

/// The cached { events, syncedAt } for [pubkey], or null.
export async function readCache(pubkey) {
  try {
    const { blobs } = await list({ prefix: pathFor(pubkey), limit: 1 });
    const blob = blobs.find((b) => b.pathname === pathFor(pubkey));
    if (!blob) return null;
    const res = await fetch(`${blob.url}?v=${Date.parse(blob.uploadedAt) || 0}`,
        { cache: 'no-store' });
    return res.ok ? await res.json() : null;
  } catch {
    return null;
  }
}

async function writeCache(pubkey, cache) {
  await put(pathFor(pubkey), JSON.stringify(cache), {
    access: 'public',
    contentType: 'application/json',
    addRandomSuffix: false,
    allowOverwrite: true,
    cacheControlMaxAge: 60,
  });
}

/// True for a well-formed event of a cached kind, correctly signed by
/// [pubkey].
export function validEvent(event, pubkey) {
  if (!event || typeof event !== 'object') return false;
  if (event.pubkey !== pubkey || !KINDS.includes(event.kind)) return false;
  if (typeof event.content !== 'string' || !Array.isArray(event.tags)) {
    return false;
  }
  try {
    return eventId(event) === event.id &&
        schnorr.verify(event.sig, event.id, event.pubkey);
  } catch {
    return false;
  }
}

/// Merges [incoming] into [events]: deduplicated by id, only the newest
/// kind-0 profile kept, newest first, capped. Returns { events, added }.
export function mergeEvents(events, incoming) {
  const byId = new Map(events.map((e) => [e.id, e]));
  let added = 0;
  for (const event of incoming) {
    if (!byId.has(event.id)) {
      byId.set(event.id, event);
      added++;
    }
  }
  const all = [...byId.values()];
  const profiles = all.filter((e) => e.kind === 0)
      .sort((a, b) => b.created_at - a.created_at);
  const kept = all
      .filter((e) => e.kind !== 0 || e === profiles[0])
      .sort((a, b) => b.created_at - a.created_at)
      .slice(0, MAX_EVENTS);
  return { events: kept, added };
}

/// Adds already-validated [incoming] events to the author's cache. Returns
/// how many were new.
export async function addEvents(pubkey, incoming) {
  const cache = (await readCache(pubkey)) ?? { events: [], syncedAt: 0 };
  const { events, added } = mergeEvents(cache.events, incoming);
  if (added) await writeCache(pubkey, { ...cache, events });
  return added;
}

/// Asks the relays for the author's events and merges them in. Returns the
/// updated cache and how many events were new.
export async function refreshFromRelays(pubkey, cached) {
  const fetched = await queryRelays(
      { kinds: KINDS, authors: [pubkey], limit: 500 });
  const valid = fetched.filter((e) => validEvent(e, pubkey));
  const base = cached ?? (await readCache(pubkey)) ?? { events: [] };
  const { events, added } = mergeEvents(base.events, valid);
  const cache = { events, syncedAt: Date.now() };
  await writeCache(pubkey, cache);
  return { cache, added };
}

/// The author's events for rendering: from the cache when there is one
/// (refreshed in the background via [background] when stale — pass Vercel's
/// waitUntil), else straight from the relays.
export async function eventsFor(pubkey, { background, onRefreshed } = {}) {
  const cached = await readCache(pubkey);
  if (!cached) return (await refreshFromRelays(pubkey, null)).cache.events;
  if (Date.now() - (cached.syncedAt ?? 0) > STALE_MS && background) {
    background(refreshFromRelays(pubkey, cached)
        .then(async ({ added }) => {
          if (added && onRefreshed) await onRefreshed();
        })
        .catch(() => {}));
  }
  return cached.events;
}

/// The newest kind-0 profile metadata in [events] (parsed), or {}, with
/// `links`: the website first, then the other links the app publishes as
/// "r" tags (e.g. an x.com profile).
export function profileMeta(events) {
  const event = events.filter((e) => e.kind === 0)
      .sort((a, b) => b.created_at - a.created_at)[0];
  let meta = {};
  try {
    meta = JSON.parse(event?.content ?? '{}') ?? {};
  } catch {}
  const links = [meta.website,
    ...(event?.tags ?? []).filter((t) => t[0] === 'r').map((t) => t[1])]
      .filter((l) => typeof l === 'string' && /^https?:\/\/\S+$/i.test(l));
  return { ...meta, links: [...new Set(links)] };
}

/// Edge caching for a profile's pages: served from Vercel's CDN for an hour
/// (stale copies for up to a week while one regenerates), tagged so a new
/// event regenerates just this author's pages.
export async function cacheProfileResponse(res, name) {
  res.setHeader('Cache-Control',
      'public, s-maxage=3600, stale-while-revalidate=604800');
  try {
    const { addCacheTag } = await import('@vercel/functions');
    await addCacheTag(tagFor(name));
  } catch {}
}

/// Marks [name]'s cached pages stale so the next visit regenerates them.
export async function invalidateProfile(name) {
  try {
    const { invalidateByTag } = await import('@vercel/functions');
    await invalidateByTag(tagFor(name));
  } catch {}
}

/// Runs [promise] after the response is sent (Vercel's waitUntil).
export async function background(promise) {
  try {
    const { waitUntil } = await import('@vercel/functions');
    waitUntil(promise);
  } catch {
    await promise;
  }
}
