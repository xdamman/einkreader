// The app's mailbox: GET lists pending email items for the authenticated
// pubkey, DELETE acknowledges (removes) processed ones. Auth is a signed,
// fresh kind-27235 event with content "inbox" in the Authorization header
// ("Nostr <base64 event JSON>"), same proof-of-key as registration.
import { del, list } from '@vercel/blob';
import { verifyAuthEvent } from '../lib/registry.js';

function authedPubkey(req) {
  const header = req.headers.authorization ?? '';
  if (!header.startsWith('Nostr ')) return null;
  let event;
  try {
    event = JSON.parse(
        Buffer.from(header.slice(6), 'base64').toString('utf8'));
  } catch {
    return null;
  }
  if (verifyAuthEvent(event, { name: 'inbox' }) != null) return null;
  return event.pubkey;
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  if (req.method === 'OPTIONS') return res.status(204).end();

  const pubkey = authedPubkey(req);
  if (!pubkey) return res.status(401).json({ error: 'unauthorized' });
  const prefix = `inbox/${pubkey}/`;

  if (req.method === 'GET') {
    const { blobs } = await list({ prefix });
    const items = blobs
      .filter((blob) => blob.pathname.endsWith('.json'))
      .map((blob) => ({ id: blob.pathname, url: blob.url }));
    return res.status(200).json({ items });
  }

  if (req.method === 'DELETE') {
    const ids = Array.isArray(req.body?.ids) ? req.body.ids : [];
    // Only this pubkey's own items can be acknowledged.
    const own = ids.filter(
        (id) => typeof id === 'string' && id.startsWith(prefix));
    if (own.length) await del(own);
    return res.status(200).json({ deleted: own.length });
  }

  return res.status(405).json({ error: 'GET or DELETE' });
}
