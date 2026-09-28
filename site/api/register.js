// POST /api/register { name, pubkey, event }
// Claims name@einkreader.app for a Nostr pubkey. Ownership is proven by a
// fresh kind-27235 event naming the username, signed by that key.
import {
  NAME_RULE,
  RESERVED,
  applyRegistration,
  loadRegistry,
  normalizeSenders,
  deleteEntry,
  saveEntry,
  verifyAuthEvent,
} from '../lib/registry.js';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'POST only' });
  }

  const { name, pubkey, event } = req.body ?? {};
  // Allowed senders ride along: `senders` (list) or the older `sender`.
  // Neither present = keep what the registry already has.
  const hasSenders = req.body?.senders != null || req.body?.sender != null;
  const senders = hasSenders ? normalizeSenders(req.body) : undefined;
  if (senders === null) {
    return res.status(400).json({ error: 'Invalid sender email' });
  }
  if (typeof name !== 'string' || !NAME_RULE.test(name)) {
    return res.status(400).json({
      error: 'Username must be 5–20 characters: a–z, 0–9 and _ only',
    });
  }
  if (RESERVED.has(name)) {
    return res.status(400).json({ error: 'This username is reserved' });
  }
  if (typeof pubkey !== 'string' || !/^[0-9a-f]{64}$/.test(pubkey)) {
    return res.status(400).json({ error: 'Invalid pubkey' });
  }
  if (event?.pubkey !== pubkey) {
    return res.status(401).json({ error: 'Auth event pubkey mismatch' });
  }
  const invalid = verifyAuthEvent(event, { name });
  if (invalid) return res.status(401).json({ error: invalid });

  const registry = await loadRegistry();
  const before = new Set(Object.keys(registry));
  const { status, body } =
      applyRegistration(registry, { name, pubkey, senders });
  if (status === 200) {
    // Persist only what this registration changed: its own name, and any
    // previous name of the same key it replaced.
    await saveEntry(name, registry[name]);
    for (const old of before) {
      if (!(old in registry)) await deleteEntry(old);
    }
  }
  return res.status(status).json(body);
}
