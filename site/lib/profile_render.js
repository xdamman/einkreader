// Pure helpers for the public profile pages: grouping kind-9802 highlight
// events by the story they quote, and the ids the permalinks use.
import { createHash } from 'node:crypto';

const tag = (event, key) =>
    (event.tags ?? []).find((t) => t?.[0] === key)?.[1];

/// Stable short id for a story, derived from its URL (falling back to the
/// title for url-less quotes) — what /:name/s/:id addresses.
export function storyId(url, title) {
  return createHash('sha256')
      .update(url || title || 'untitled')
      .digest('hex')
      .slice(0, 8);
}

/// Kinds a profile page shows: highlights (NIP-84) and comments on a web
/// page (NIP-22, kind 1111) — the note written when sharing several
/// highlights of one article together.
export const STORY_KINDS = [9802, 1111];

/// Groups highlight events into stories: one entry per quoted article, its
/// shared quotes together (newest share first inside newest story first),
/// with the newest note about the article as a whole, if any.
/// Returns [{ id, url, title, domain, latest, note, quotes: [{id, text,
/// comment, created_at}] }].
export function groupStories(events) {
  const groups = new Map();
  const sorted = [...events]
      .filter((e) => STORY_KINDS.includes(e.kind))
      .sort((a, b) => (b.created_at ?? 0) - (a.created_at ?? 0));
  for (const event of sorted) {
    const url = tag(event, 'r') ?? tag(event, 'I') ?? null;
    const title = tag(event, 'title') ?? url ?? 'Untitled';
    const id = storyId(url, title);
    if (!groups.has(id)) {
      let domain = null;
      try {
        domain = url ? new URL(url).hostname.replace(/^www\./, '') : null;
      } catch {}
      groups.set(id, {
        id, url, title, domain,
        latest: event.created_at ?? 0,
        note: null,
        quotes: [],
      });
    }
    const group = groups.get(id);
    group.latest = Math.max(group.latest, event.created_at ?? 0);
    if (event.kind === 1111) {
      // Newest first: the first note seen is the current one.
      group.note ??= (event.content ?? '').trim() || null;
      continue;
    }
    group.quotes.push({
      id: event.id,
      text: event.content ?? '',
      comment: tag(event, 'comment') ?? null,
      created_at: event.created_at ?? 0,
    });
  }
  return [...groups.values()]
      .filter((g) => g.quotes.length || g.note)
      .sort((a, b) => b.latest - a.latest);
}

/// { year, month } (UTC, month 1-12) a story belongs to: when it was last
/// shared.
export function monthOf(group) {
  const d = new Date((group.latest ?? 0) * 1000);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1 };
}

const key = ({ year, month }) => year * 12 + (month - 1);

/// Every month with stories, newest first: [{ year, month, groups }].
export function byMonth(groups) {
  const months = new Map();
  for (const group of groups) {
    const m = monthOf(group);
    const k = key(m);
    if (!months.has(k)) months.set(k, { ...m, groups: [] });
    months.get(k).groups.push(group);
  }
  return [...months.entries()].sort((a, b) => b[0] - a[0]).map((e) => e[1]);
}

/// "October 2026".
export function monthName({ year, month }) {
  return new Date(Date.UTC(year, month - 1, 1)).toLocaleDateString('en-US',
      { month: 'long', year: 'numeric', timeZone: 'UTC' });
}

/// The story group containing the event whose id starts with [qid].
export function storyForQuote(groups, qid) {
  const prefix = qid.toLowerCase();
  for (const group of groups) {
    if (group.quotes.some((q) => String(q.id ?? '').startsWith(prefix))) {
      return group;
    }
  }
  return null;
}
