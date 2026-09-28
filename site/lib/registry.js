// Username registry for name@einkreader.app NIP-05 addresses.
// Stored in Vercel Blob, one blob per name (see saveEntry).
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex } from '@noble/hashes/utils';
import { del, list, put } from '@vercel/blob';

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

// Storage: one blob per change, `registry/<name>/<timestamp>.json`, holding
// that name's entry. Blobs are never overwritten: an overwritten blob can be
// served stale for up to a minute, which made a read-modify-write of a
// single registry file drop or resurrect entries. list() reflects writes
// and deletes immediately, and a new path is always read fresh.
const PREFIX = 'registry/';
// The original single-file registry, migrated on first read.
const LEGACY_PATH = 'nostr-registry.json';

async function listEntryBlobs() {
  const blobs = [];
  let cursor;
  do {
    const page = await list({ prefix: PREFIX, cursor });
    blobs.push(...page.blobs);
    cursor = page.hasMore ? page.cursor : undefined;
  } while (cursor);
  return blobs;
}

/// name → its blobs, newest first.
function groupByName(blobs) {
  const byName = {};
  for (const blob of blobs) {
    const [, name, file] = blob.pathname.split('/');
    if (!name || !file) continue;
    (byName[name] ??= []).push({ blob, at: Number(file.split('.')[0]) || 0 });
  }
  for (const list of Object.values(byName)) list.sort((a, b) => b.at - a.at);
  return byName;
}

async function migrateLegacy() {
  const { blobs } = await list({ prefix: LEGACY_PATH });
  const legacy = blobs.find((b) => b.pathname === LEGACY_PATH);
  if (!legacy) return;
  const res = await fetch(`${legacy.url}?v=${Date.now()}`, { cache: 'no-store' });
  if (!res.ok) return;
  const registry = await res.json();
  for (const [name, entry] of Object.entries(registry)) {
    await saveEntry(name, entry);
  }
}

export async function loadRegistry() {
  let blobs = await listEntryBlobs();
  if (blobs.length === 0) {
    await migrateLegacy();
    blobs = await listEntryBlobs();
  }
  const byName = groupByName(blobs);
  const registry = {};
  await Promise.all(Object.entries(byName).map(async ([name, versions]) => {
    const res = await fetch(versions[0].blob.url, { cache: 'no-store' });
    if (res.ok) registry[name] = await res.json();
  }));
  return registry;
}

/// Writes [name]'s entry as a new blob, then drops its older versions.
export async function saveEntry(name, entry) {
  await put(`${PREFIX}${name}/${Date.now()}.json`, JSON.stringify(entry), {
    access: 'public',
    addRandomSuffix: false,
    contentType: 'application/json',
  });
  const versions = groupByName(
      await listEntryBlobs().then((all) =>
          all.filter((b) => b.pathname.startsWith(`${PREFIX}${name}/`))))[name] ?? [];
  const old = versions.slice(1).map((v) => v.blob.url);
  if (old.length) await del(old);
}

/// Removes [name] entirely (all versions).
export async function deleteEntry(name) {
  const own = (await listEntryBlobs())
      .filter((b) => b.pathname.startsWith(`${PREFIX}${name}/`));
  if (own.length) await del(own.map((b) => b.url));
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
