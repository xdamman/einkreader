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

/// Groups highlight events into stories: one entry per quoted article, its
/// shared quotes together (newest share first inside newest story first).
/// Returns [{ id, url, title, domain, latest, quotes: [{id, text, comment,
/// created_at}] }].
export function groupStories(events) {
  const groups = new Map();
  const sorted = [...events]
      .filter((e) => e.kind === 9802)
      .sort((a, b) => (b.created_at ?? 0) - (a.created_at ?? 0));
  for (const event of sorted) {
    const url = tag(event, 'r') ?? null;
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
        quotes: [],
      });
    }
    const group = groups.get(id);
    group.latest = Math.max(group.latest, event.created_at ?? 0);
    group.quotes.push({
      id: event.id,
      text: event.content ?? '',
      comment: tag(event, 'comment') ?? null,
      created_at: event.created_at ?? 0,
    });
  }
  return [...groups.values()].sort((a, b) => b.latest - a.latest);
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
