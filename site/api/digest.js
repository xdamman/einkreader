// The email digest of shared highlights.
//   GET  (Vercel cron, hourly) — each confirmed subscriber for whom it is
//        now Saturday 7:xx in their own time zone gets the highlights
//        shared since their last digest (or in the past week), if any.
//   POST { name, to } — a test digest of the last week (or the latest
//        highlights when the week was quiet) to one address only.
// Both require `Authorization: Bearer $CRON_SECRET` (Vercel's cron sends it).
import { buildDigest, highlightsSince } from '../lib/digest.js';
import { DIGEST_FROM, sendEmail } from '../lib/email.js';
import { profileMeta, refreshFromRelays } from '../lib/profile_cache.js';
import { loadRegistry, pubkeyOf } from '../lib/registry.js';
import { actionUrl, decryptEmail, digestDue, loadSubscribers,
  profilesWithSubscribers, saveSubscribers, subscriberId }
  from '../lib/subscribers.js';

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
  const unsubscribeUrl = actionUrl('unsubscribe', name, subscriberId(to));
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
  const date = new Date();
  for (const name of await profilesWithSubscribers()) {
    const pubkey = pubkeyOf(registry[name]);
    if (!pubkey) continue;
    const data = await loadSubscribers(name);
    const due = data.subscribers.filter((s) => s.confirmed && digestDue(s, date));
    if (!due.length) continue;
    const all = await eventsOf(pubkey);
    const displayName = profileMeta(all).name || name;
    let sent = 0;
    let quiet = 0;
    for (const subscriber of due) {
      const since = Math.floor((subscriber.lastSentAt || 0) / 1000) ||
          now - WEEK;
      const events = highlightsSince(all, since);
      // Marked as handled either way: a quiet week sends nothing, and the
      // next one counts from here.
      const previous = subscriber.lastSentAt;
      subscriber.lastSentAt = date.getTime();
      if (!events.length) {
        quiet++;
        continue;
      }
      try {
        await sendEmail(message({ name, displayName, events,
          to: decryptEmail(subscriber.enc) }));
        sent++;
      } catch (e) {
        // Not sent: next Saturday's digest covers this week too.
        subscriber.lastSentAt = previous;
        console.error(`digest ${name}: ${e.message}`);
      }
    }
    await saveSubscribers(name, data);
    report[name] = `${sent} sent, ${quiet} with nothing new, ` +
        `${due.length - sent - quiet} failed`;
  }
  return res.status(200).json({ ok: true, report });
}
