// DELETE /api/account — deletes an einkreader account: frees the username
// (name@einkreader.app stops resolving and receiving mail) and deletes
// everything stored for that key on our servers (inbox items and their
// attachments). Authorized like the inbox: a fresh kind-27235 event signed
// by the account's key, content "delete-account", in the Authorization
// header ("Nostr <base64 event JSON>"). Required by Play's account-deletion
// policy; the web page is /delete-account.
import { del, list } from '@vercel/blob';
import {
  entryForPubkey,
  loadRegistry,
  saveRegistry,
  verifyAuthEvent,
} from '../lib/registry.js';

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
  if (verifyAuthEvent(event, { name: 'delete-account' }) != null) return null;
  return event.pubkey;
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization');
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'DELETE') {
    return res.status(405).json({ error: 'DELETE only' });
  }
  const pubkey = authedPubkey(req);
  if (!pubkey) return res.status(401).json({ error: 'unauthorized' });

  const registry = await loadRegistry();
  const own = entryForPubkey(registry, pubkey);
  if (own) {
    delete registry[own.name];
    await saveRegistry(registry);
  }
  let removed = 0;
  let cursor;
  do {
    const page = await list({ prefix: `inbox/${pubkey}/`, cursor });
    if (page.blobs.length) {
      await del(page.blobs.map((b) => b.url));
      removed += page.blobs.length;
    }
    cursor = page.hasMore ? page.cursor : undefined;
  } while (cursor);
  return res.status(200).json({
    deleted: true,
    username: own?.name ?? null,
    inboxItems: removed,
  });
}
