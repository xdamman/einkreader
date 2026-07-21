// Username registry for name@einkreader.app NIP-05 addresses.
// Stored as one JSON blob { name: pubkeyHex } in Vercel Blob.
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex } from '@noble/hashes/utils';
import { list, put } from '@vercel/blob';

// Mirrors the app's client-side rule: 5–20 chars, lowercase letters,
// digits and underscore only.
export const NAME_RULE = /^[a-z0-9_]{5,20}$/;

export const RESERVED = new Set([
  'admin', 'root', 'einkreader', 'support', 'help', 'info', 'contact',
  'www', 'mail', 'postmaster', 'abuse', 'security', 'nostr', 'reader',
]);

const BLOB_PATH = 'nostr-registry.json';

export async function loadRegistry() {
  // Exact-pathname match: list() is prefix-based and would also return a
  // stray suffixed blob (e.g. from a manual CLI upload).
  const { blobs } = await list({ prefix: BLOB_PATH });
  const blob = blobs.find((b) => b.pathname === BLOB_PATH);
  if (!blob) return {};
  const res = await fetch(blob.url, { cache: 'no-store' });
  if (!res.ok) return {};
  return await res.json();
}

export async function saveRegistry(registry) {
  await put(BLOB_PATH, JSON.stringify(registry, null, 2), {
    access: 'public',
    addRandomSuffix: false,
    allowOverwrite: true,
    contentType: 'application/json',
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

// Applies a registration to the registry object (pure; no I/O).
// Returns { status, body }. A pubkey re-registering replaces its old name.
export function applyRegistration(registry, { name, pubkey }) {
  const existing = registry[name];
  if (existing && existing !== pubkey) {
    return { status: 409, body: { error: 'Username is taken' } };
  }
  for (const [otherName, otherKey] of Object.entries(registry)) {
    if (otherKey === pubkey && otherName !== name) delete registry[otherName];
  }
  registry[name] = pubkey;
  return { status: 200, body: { ok: true, nip05: `${name}@einkreader.app` } };
}
