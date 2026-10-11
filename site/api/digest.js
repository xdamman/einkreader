// The email digest of shared highlights.
//   GET  (Vercel cron, weekly) — every profile with confirmed subscribers
//        and new highlights since its last digest gets one sent.
//   POST { name, to } — a test digest of the last week (or the latest
//        highlights when the week was quiet) to one address only.
// Both require `Authorization: Bearer $CRON_SECRET` (Vercel's cron sends it).
import { buildDigest, highlightsSince } from '../lib/digest.js';
import { DIGEST_FROM, sendEmail } from '../lib/email.js';
import { profileMeta, refreshFromRelays } from '../lib/profile_cache.js';
import { loadRegistry, pubkeyOf } from '../lib/registry.js';
import { actionUrl, loadSubscribers, profilesWithSubscribers,
  saveSubscribers } from '../lib/subscribers.js';

const WEEK = 7 * 24 * 3600;

function authorized(req) {
  const secret = process.env.CRON_SECRET;
  return Boolean(secret) &&
      req.headers.authorization === `Bearer ${secret}`;
}

async function eventsOf(pubkey) {
  // Fresh from the relays: a digest must not miss the latest shares.
  return (await refreshFromRelays(pubkey)).cache.events;
}

function message({ name, displayName, events, to, test }) {
  const unsubscribeUrl = actionUrl('unsubscribe', name, to);
  const digest = buildDigest(
      { name, displayName, events, unsubscribeUrl, test });
  return {
    from: `${displayName} via einkreader <${DIGEST_FROM}>`,
    to,
    subject: digest.subject,
    html: digest.html,
    text: digest.text,
    headers: {
      'List-Unsubscribe': `<${unsubscribeUrl}>`,
      'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
    },
  };
}

export default async function handler(req, res) {
  if (!authorized(req)) return res.status(401).json({ error: 'unauthorized' });
  const registry = await loadRegistry();
  const now = Math.floor(Date.now() / 1000);

  if (req.method === 'POST') {
    const name = String(req.body?.name ?? '').toLowerCase();
    const to = String(req.body?.to ?? '').trim().toLowerCase();
    const pubkey = pubkeyOf(registry[name]);
    if (!pubkey) return res.status(404).json({ error: 'unknown profile' });
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) {
      return res.status(400).json({ error: 'invalid recipient' });
    }
    const all = await eventsOf(pubkey);
    let events = highlightsSince(all, now - WEEK);
    // A quiet week still makes a useful test: the latest highlights.
    if (!events.length) {
      events = all.filter((e) => e.kind === 9802).slice(0, 10);
    }
    if (!events.length) return res.status(409).json({ error: 'no highlights' });
    const displayName = profileMeta(all).name || name;
    await sendEmail(message({ name, displayName, events, to, test: true }));
    return res.status(200).json({ ok: true, highlights: events.length });
  }

  if (req.method !== 'GET') return res.status(405).json({ error: 'GET/POST' });
  const report = {};
  for (const name of await profilesWithSubscribers()) {
    const pubkey = pubkeyOf(registry[name]);
    if (!pubkey) continue;
    const data = await loadSubscribers(name);
    const recipients = data.subscribers.filter((s) => s.confirmed);
    if (!recipients.length) continue;
    const all = await eventsOf(pubkey);
    const events = highlightsSince(all, data.lastSentAt || now - WEEK);
    if (!events.length) {
      report[name] = 'nothing new';
      continue;
    }
    const displayName = profileMeta(all).name || name;
    let sent = 0;
    for (const { email } of recipients) {
      try {
        await sendEmail(message({ name, displayName, events, to: email }));
        sent++;
      } catch (e) {
        console.error(`digest ${name}: ${e.message}`);
      }
    }
    await saveSubscribers(name, { ...data, lastSentAt: now });
    report[name] = `${sent}/${recipients.length} sent, ${events.length} highlights`;
  }
  return res.status(200).json({ ok: true, report });
}
