// Resend inbound webhook: an email sent to username@einkreader.app becomes
// a reading-feed item — but ONLY when the sender matches the username's
// whitelisted address. Attachments: images are stored and referenced inline;
// PDF and EPUB attachments are converted to text and appended.
import { put } from '@vercel/blob';
import {
  bareAddress,
  buildItem,
  emailToMarkdown,
  epubToMarkdown,
  pdfToMarkdown,
  usernameFromRecipients,
  verifySvixSignature,
} from '../lib/inbound.js';
import { loadRegistry, pubkeyOf, senderOf } from '../lib/registry.js';

export const config = { api: { bodyParser: false } };

async function rawBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

const MAX_ATTACHMENT = 15 * 1024 * 1024;

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).end();
  const payload = await rawBody(req);

  const secret = process.env.RESEND_WEBHOOK_SECRET;
  if (secret && !verifySvixSignature(secret, req.headers, payload)) {
    return res.status(401).json({ error: 'bad signature' });
  }
  if (!secret && process.env.NODE_ENV === 'production') {
    // Refuse to run open in production: unsigned posts could forge senders.
    return res.status(503).json({ error: 'webhook secret not configured' });
  }

  let body;
  try {
    body = JSON.parse(payload);
  } catch {
    return res.status(400).json({ error: 'invalid JSON' });
  }
  const email = body?.data ?? body;

  const username = usernameFromRecipients(email?.to);
  // Always 200 for drops: Resend must not retry mail we chose to ignore.
  if (!username) return res.status(200).json({ dropped: 'no recipient' });

  const registry = await loadRegistry();
  const entry = registry[username];
  if (!entry) return res.status(200).json({ dropped: 'unknown user' });
  const allowed = senderOf(entry);
  const from = bareAddress(email?.from);
  if (!allowed || !from || from !== allowed) {
    return res.status(200).json({ dropped: 'sender not whitelisted' });
  }
  const pubkey = pubkeyOf(entry);

  // The webhook is a notification only: the body and attachment contents
  // live behind Resend's API.
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) return res.status(503).json({ error: 'api key missing' });
  const emailId = email?.email_id;
  if (!emailId) return res.status(200).json({ dropped: 'no email id' });
  const fullResponse = await fetch(
      `https://api.resend.com/emails/receiving/${emailId}`,
      { headers: { Authorization: `Bearer ${apiKey}` } });
  if (!fullResponse.ok) {
    // Let Resend retry: the email may not be readable yet.
    return res.status(500).json({ error: 'could not fetch email' });
  }
  const full = await fullResponse.json();

  const markdown = emailToMarkdown({ html: full?.html, text: full?.text });
  const attachmentsMarkdown = [];
  for (const meta of email?.attachments ?? []) {
    try {
      const detail = await (await fetch(
          `https://api.resend.com/emails/receiving/${emailId}` +
              `/attachments/${meta.id}`,
          { headers: { Authorization: `Bearer ${apiKey}` } })).json();
      if (!detail?.download_url ||
          (detail.size ?? 0) > MAX_ATTACHMENT) {
        continue;
      }
      const buffer =
          Buffer.from(await (await fetch(detail.download_url)).arrayBuffer());
      if (buffer.length === 0) continue;
      const type = (meta.content_type ?? '').toLowerCase();
      const filename = meta.filename ?? 'attachment';
      if (type.startsWith('image/')) {
        const stored = await put(`inbox/${pubkey}/${filename}`, buffer, {
          access: 'public',
          contentType: type,
        });
        attachmentsMarkdown.push(`![${filename}](${stored.url})`);
      } else if (type === 'application/pdf' || /\.pdf$/i.test(filename)) {
        const text = await pdfToMarkdown(buffer);
        if (text) attachmentsMarkdown.push(`## ${filename}\n\n${text}`);
      } else if (
        type === 'application/epub+zip' ||
        /\.epub$/i.test(filename)
      ) {
        const text = await epubToMarkdown(buffer);
        if (text) attachmentsMarkdown.push(`## ${filename}\n\n${text}`);
      }
    } catch {
      // A bad attachment never blocks the email itself.
    }
  }

  const item = buildItem({
    subject: full?.subject ?? email?.subject,
    from,
    markdown,
    attachmentsMarkdown,
  });
  await put(
    `inbox/${pubkey}/${Date.now()}.json`,
    JSON.stringify(item),
    { access: 'public', contentType: 'application/json' },
  );
  return res.status(200).json({ ok: true });
}
