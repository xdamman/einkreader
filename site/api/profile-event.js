// POST /api/profile-event — a public Nostr event (or an array of them)
// from a registered author: added to the server's event cache, and the
// author's cached pages regenerated. Fed by infra/profile-listener, which
// follows every registered author on the relays. No secret needed: events
// are signed, only registered authors' profile (kind 0) and highlight
// (kind 9802) events are accepted, and they are public anyway.
import { addEvents, invalidateProfile, validEvent }
  from '../lib/profile_cache.js';
import { entryForPubkey, loadRegistry } from '../lib/registry.js';

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  const body = req.body;
  const events = (Array.isArray(body) ? body : [body]).slice(0, 200);
  const registry = await loadRegistry();
  const byAuthor = new Map();
  for (const event of events) {
    const owner = entryForPubkey(registry, event?.pubkey);
    if (!owner || !validEvent(event, event.pubkey)) {
      continue;
    }
    const list = byAuthor.get(owner.name) ?? { pubkey: event.pubkey, events: [] };
    list.events.push(event);
    byAuthor.set(owner.name, list);
  }
  const added = {};
  for (const [name, { pubkey, events: own }] of byAuthor) {
    added[name] = await addEvents(pubkey, own);
    if (added[name]) {
      await invalidateProfile(name);
      // Warm the stream page so the next visitor gets the new version.
      await fetch(`https://einkreader.app/${name}`).catch(() => {});
    }
  }
  return res.status(200).json({ ok: true, added });
}
