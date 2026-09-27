// Username registry for name@einkreader.app NIP-05 addresses.
// Stored as one JSON blob { name: pubkeyHex } in Vercel Blob.
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex } from '@noble/hashes/utils';
import { list, put } from '@vercel/blob';

// Mirrors the app's client-side rule: 5–20 chars, lowercase letters,
// digits and underscore only.
export const NAME_RULE = /^[a-z0-9_]{5,20}$/;

// einkreader's official Nostr account
// (npub1dq33rr42kfeqss8kjpd0l4tn20ppq9fgu5j28c08vlsqjazr8t5qltl4h7), verified
// as the domain's root identity: NIP-05 "_@einkreader.app", shown by
// clients as just "einkreader.app". "_" can never be registered (NAME_RULE
// needs 5+ characters), so it can't collide with a username.
export const OFFICIAL_NIP05 = {
  _: '6823118eaab2720840f6905affd57353c2101528e524a3e1e767e00974433ae8',
};

export const RESERVED = new Set([
  'admin', 'root', 'einkreader', 'support', 'help', 'info', 'contact',
  'www', 'mail', 'postmaster', 'abuse', 'security', 'nostr', 'reader',
  // Site pages whose paths would otherwise match a username.
  'brand', 'branding', 'privacy', 'opensource',
]);

const BLOB_PATH = 'nostr-registry.json';

export async function loadRegistry() {
  // Exact-pathname match: list() is prefix-based and would also return a
  // stray suffixed blob (e.g. from a manual CLI upload).
  const { blobs } = await list({ prefix: BLOB_PATH });
  const blob = blobs.find((b) => b.pathname === BLOB_PATH);
  if (!blob) return {};
  // The blob CDN caches files (a month by default): read past it, or a
  // fresh registration stays invisible and the next save could overwrite
  // it from a stale copy.
  const res = await fetch(`${blob.url}?v=${Date.now()}`, { cache: 'no-store' });
  if (!res.ok) return {};
  return await res.json();
}

export async function saveRegistry(registry) {
  await put(BLOB_PATH, JSON.stringify(registry, null, 2), {
    access: 'public',
    addRandomSuffix: false,
    allowOverwrite: true,
    contentType: 'application/json',
    cacheControlMaxAge: 60,
  });
}

// NIP-01 event id: sha256 of the canonical serialization.
export function eventId(event) {
  const serialized = JSON.stringify([
    0, event.pubkey, event.created_at, event.kind, event.tags, event.content,
  ]);
  return bytesToHex(sha256(new TextEncoder().encode(serialized)));
}

// Proof of key ownership: a fresh kind-27235 event naming the username,
// signed by the claiming pubkey. Returns an error string, or null when valid.
export function verifyAuthEvent(event, { name, nowSeconds, maxAgeSeconds = 600 }) {
  if (!event || typeof event !== 'object') return 'missing auth event';
  if (event.kind !== 27235) return 'wrong auth event kind';
  if (event.content !== name) return 'auth event does not name this username';
  const now = nowSeconds ?? Math.floor(Date.now() / 1000);
  if (Math.abs(now - event.created_at) > maxAgeSeconds) {
    return 'auth event expired';
  }
  if (eventId(event) !== event.id) return 'bad event id';
  let ok = false;
  try {
    ok = schnorr.verify(event.sig, event.id, event.pubkey);
  } catch {
    ok = false;
  }
  return ok ? null : 'bad signature';
}

// Registry values are objects { pubkey, senders? } where senders are the
// email addresses allowed to mail content to name@einkreader.app (older
// entries have a single `sender`; the oldest are bare pubkey strings).
// pubkeyOf / sendersOf read every shape.
export function pubkeyOf(entry) {
  return typeof entry === 'string' ? entry : entry?.pubkey;
}

export function sendersOf(entry) {
  if (typeof entry !== 'object' || entry == null) return [];
  const list = Array.isArray(entry.senders) ? entry.senders : [];
  return [...new Set([...list, ...(entry.sender ? [entry.sender] : [])])]
    .map((s) => String(s).toLowerCase());
}

const EMAIL_RULE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/// Normalizes the senders a registration carries (an array `senders`, or
/// the older single `sender`). Returns null when any address is invalid.
export function normalizeSenders({ senders, sender }) {
  const raw = Array.isArray(senders) ? senders : sender != null ? [sender] : [];
  const out = [];
  for (const s of raw) {
    if (typeof s !== 'string' || !EMAIL_RULE.test(s.trim())) return null;
    out.push(s.trim().toLowerCase());
  }
  return [...new Set(out)].slice(0, 50);
}

// Applies a registration to the registry object (pure; no I/O).
// Returns { status, body }. A pubkey re-registering replaces its old name;
// re-registering the same name updates the allowed senders ([senders]
// undefined keeps them as they are).
export function applyRegistration(registry, { name, pubkey, senders }) {
  const existing = pubkeyOf(registry[name]);
  if (existing && existing !== pubkey) {
    return { status: 409, body: { error: 'Username is taken' } };
  }
  for (const [otherName, entry] of Object.entries(registry)) {
    if (pubkeyOf(entry) === pubkey && otherName !== name) {
      delete registry[otherName];
    }
  }
  const keep = senders === undefined ? sendersOf(registry[name]) : senders;
  registry[name] = {
    pubkey,
    ...(keep.length ? { senders: keep } : {}),
  };
  return { status: 200, body: { ok: true, nip05: `${name}@einkreader.app` } };
}

// The registry entry (name + value) owned by [pubkey], if any.
export function entryForPubkey(registry, pubkey) {
  for (const [name, entry] of Object.entries(registry)) {
    if (pubkeyOf(entry) === pubkey) return { name, entry };
  }
  return null;
}
