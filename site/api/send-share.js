// POST /api/send-share { to, subject, text }
// One-tap email shares (Email plugin): sends from the user's own
// name@einkreader.app address via Resend, Reply-To their whitelisted
// personal address. Auth: signed kind-27235 event with content "send-share".
import { entryForPubkey, loadRegistry, senderOf, verifyAuthEvent }
  from '../lib/registry.js';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });

  const header = req.headers.authorization ?? '';
  if (!header.startsWith('Nostr ')) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  let event;
  try {
    event = JSON.parse(
        Buffer.from(header.slice(6), 'base64').toString('utf8'));
  } catch {
    return res.status(401).json({ error: 'bad auth event' });
  }
  const invalid = verifyAuthEvent(event, { name: 'send-share' });
  if (invalid) return res.status(401).json({ error: invalid });

  const registry = await loadRegistry();
  const owner = entryForPubkey(registry, event.pubkey);
  if (!owner) return res.status(403).json({ error: 'no username registered' });

  const { to, subject, text } = req.body ?? {};
  if (typeof to !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) {
    return res.status(400).json({ error: 'invalid recipient' });
  }
  if (typeof text !== 'string' || !text.trim() || text.length > 20000) {
    return res.status(400).json({ error: 'invalid body' });
  }

  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) return res.status(503).json({ error: 'sending not configured' });
  const replyTo = senderOf(owner.entry);
  const send = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: `${owner.name}@einkreader.app`,
      to,
      subject: String(subject ?? 'A read worth sharing').slice(0, 200),
      text,
      ...(replyTo ? { reply_to: replyTo } : {}),
    }),
  });
  if (!send.ok) {
    return res
        .status(502)
        .json({ error: `send failed (${send.status})` });
  }
  return res.status(200).json({ ok: true });
}
