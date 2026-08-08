// RSS feed of a profile's shared highlights: /:name/feed.xml
// One item per story (the same grouping as the page), quotes + comments in
// the description, linking to the local story permalink.
import { queryRelays } from '../lib/relay.js';
import { groupStories } from '../lib/profile_render.js';
import { loadRegistry, pubkeyOf } from '../lib/registry.js';

const esc = (value) => String(value ?? '')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;');

export default async function handler(req, res) {
  const name = String(req.query.name ?? '').toLowerCase();
  const registry = await loadRegistry();
  const pubkey = pubkeyOf(registry[name]);
  if (!pubkey) return res.status(404).send('not found');

  const events = await queryRelays(
      { kinds: [0, 9802], authors: [pubkey], limit: 100 });
  const metaEvent = events
      .filter((e) => e.kind === 0)
      .sort((a, b) => (b.created_at ?? 0) - (a.created_at ?? 0))[0];
  let meta = {};
  try {
    meta = JSON.parse(metaEvent?.content ?? '{}');
  } catch {}
  const displayName = meta.name || name;
  const base = `https://einkreader.app/${name}`;

  const items = groupStories(events).slice(0, 30).map((group) => {
    const description = group.quotes.map((quote) =>
        `<blockquote>${esc(quote.text)}</blockquote>` +
        (quote.comment ? `<p>${esc(quote.comment)}</p>` : '')).join('');
    const source = group.url
        ? `<p>From <a href="${esc(group.url)}">${esc(group.domain ?? group.url)}</a></p>`
        : '';
    return `  <item>
    <title>${esc(group.title)}</title>
    <link>${base}/s/${group.id}</link>
    <guid isPermaLink="true">${base}/s/${group.id}</guid>
    <pubDate>${new Date(group.latest * 1000).toUTCString()}</pubDate>
    <description>${esc(description + source)}</description>
  </item>`;
  }).join('\n');

  res.setHeader('Content-Type', 'application/rss+xml; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=600');
  return res.status(200).send(`<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
  <title>${esc(displayName)} — highlights</title>
  <link>${base}</link>
  <description>Highlights and comments shared by ${esc(displayName)} with einkreader</description>
${items}
</channel>
</rss>`);
}
