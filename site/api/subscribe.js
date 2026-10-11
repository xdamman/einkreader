// The email digest of a profile's shared highlights (see api/digest.js).
//   POST { name, email, tz }        — subscribe: stored unconfirmed (the
//                                     address encrypted, with the reader's
//                                     time zone), and a confirmation link
//                                     is emailed
//   GET  ?a=confirm&name&id&t       — the confirmation link
//   GET  ?a=unsubscribe&name&id&t   — the digest's unsubscribe link
//   POST ?a=unsubscribe&…           — one-click unsubscribe from mail apps
//                                     (List-Unsubscribe-Post)
// Storage and signed links: lib/subscribers.js.
import { DIGEST_FROM, sendEmail } from '../lib/email.js';
import { loadRegistry, pubkeyOf } from '../lib/registry.js';
import { actionUrl, checkToken, encryptEmail, loadSubscribers,
  saveSubscribers, subscriberId, validTimeZone } from '../lib/subscribers.js';

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const esc = (value) => String(value ?? '')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;');

const notice = (res, status, title, body, name) => res
    .status(status)
    .setHeader('Content-Type', 'text/html; charset=utf-8')
    .setHeader('Cache-Control', 'no-store')
    .send(`<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title></head>
<body style="font-family:Georgia,serif;color:#111;background:#fff;
  text-align:center;padding:80px 20px;line-height:1.6">
<h1 style="font-size:24px">${esc(title)}</h1><p>${body}</p>
${name ? `<p style="margin-top:18px"><a href="/${esc(name)}"
  style="color:#111">← back to the page</a></p>` : ''}
</body></html>`);

async function link(req, res) {
  const { a, name, id, t } = { ...req.query };
  const profile = String(name ?? '').toLowerCase();
  const sid = String(id ?? '');
  if (!['confirm', 'unsubscribe'].includes(a) ||
      !checkToken(a, profile, sid, t)) {
    return notice(res, 400, 'This link is not valid',
        'It may have been cut off. Try copying the whole link.');
  }
  const data = await loadSubscribers(profile);
  if (a === 'confirm') {
    const entry = data.subscribers.find((s) => s.id === sid);
    if (!entry) {
      return notice(res, 404, 'Nothing to confirm',
          'This address is not on the list anymore. Subscribe again from the page.',
          profile);
    }
    if (!entry.confirmed) {
      entry.confirmed = true;
      await saveSubscribers(profile, data);
    }
    return notice(res, 200, "You're subscribed",
        'A digest arrives on Saturday mornings, only in weeks with new highlights.',
        profile);
  }
  const before = data.subscribers.length;
  data.subscribers = data.subscribers.filter((s) => s.id !== sid);
  if (data.subscribers.length !== before) await saveSubscribers(profile, data);
  if (req.method === 'POST') return res.status(200).json({ ok: true });
  return notice(res, 200, 'Unsubscribed',
      "You won't get these digests anymore.", profile);
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.query?.a) return link(req, res);
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });

  const { name, email, tz } = req.body ?? {};
  const profile = String(name ?? '').toLowerCase();
  const address = String(email ?? '').trim().toLowerCase();
  if (!EMAIL.test(address) || address.length > 254) {
    return res.status(400).json({ error: 'invalid email' });
  }
  const registry = await loadRegistry();
  if (!pubkeyOf(registry[profile])) {
    return res.status(404).json({ error: 'unknown profile' });
  }

  const data = await loadSubscribers(profile);
  const id = subscriberId(address);
  const existing = data.subscribers.find((s) => s.id === id);
  if (existing?.confirmed) {
    // Subscribing again from another place moves the delivery time there.
    if (tz && validTimeZone(tz) !== existing.tz) {
      existing.tz = validTimeZone(tz);
      await saveSubscribers(profile, data);
    }
    return res.status(200).json({ ok: true });
  }
  if (!existing) {
    if (data.subscribers.length >= 5000) {
      return res.status(429).json({ error: 'list full' });
    }
    data.subscribers.push({
      id,
      enc: encryptEmail(address),
      tz: validTimeZone(tz),
      at: Date.now(),
      confirmed: false,
      lastSentAt: 0,
    });
    await saveSubscribers(profile, data);
  }
  // (Re)send the confirmation: nothing is mailed to an address until its
  // owner says yes.
  const confirmUrl = actionUrl('confirm', profile, id);
  await sendEmail({
    from: `einkreader <${DIGEST_FROM}>`,
    to: address,
    subject: `Confirm your subscription to ${profile}'s highlights`,
    text: `Someone (hopefully you) asked to get a Saturday digest of ` +
        `${profile}'s highlights from einkreader.app.\n\n` +
        `Confirm: ${confirmUrl}\n\n` +
        `Didn't ask for this? Ignore this email and nothing will be sent.`,
    html: `<div style="font-family:Georgia,serif;color:#111;line-height:1.6;max-width:30em">
      <p>Someone (hopefully you) asked to get a Saturday digest of
      <b>${esc(profile)}</b>'s highlights from einkreader.app.</p>
      <p><a href="${esc(confirmUrl)}" style="display:inline-block;background:#111;color:#fff;
        padding:10px 20px;border-radius:20px;text-decoration:none">Confirm subscription</a></p>
      <p style="color:#666;font-size:14px">Didn't ask for this? Ignore this email and
      nothing will be sent.</p></div>`,
  });
  return res.status(200).json({ ok: true, confirm: true });
}
