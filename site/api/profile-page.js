// Public profile page: einkreader.app/<username> — the user's metadata and
// their shared highlights (kind 9802) with comments, rendered server-side.
import { queryRelays } from '../lib/relay.js';
import { loadRegistry, pubkeyOf } from '../lib/registry.js';

const esc = (value) => String(value ?? '')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;');

const page = (title, body) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family: Georgia, serif; color:#111; background:#fff;
         line-height:1.6; }
  .wrap { max-width:720px; margin:0 auto; padding:48px 24px; }
  a { color:#111; }
  header { text-align:center; padding-bottom:28px;
           border-bottom:1px solid #ddd; }
  .avatar { width:96px; height:96px; border-radius:50%;
            object-fit:cover; border:1.5px solid #111; }
  h1 { font-size:30px; margin-top:14px; }
  .nip05 { font-family:monospace; font-size:14px; color:#444;
           margin-top:4px; }
  .about { margin-top:12px; font-size:16px; color:#333; }
  .links { margin-top:10px; font-size:14px; }
  .links a { margin:0 8px; }
  h2 { font-size:20px; margin:36px 0 8px; }
  .hl { border-left:3px solid #111; padding:2px 0 2px 14px;
        margin:22px 0; }
  .hl blockquote { font-size:17px; }
  .hl .comment { margin-top:8px; font-style:italic; font-size:15px;
                 color:#333; }
  .hl .meta { margin-top:8px; font-size:13px; color:#666; }
  .empty { margin-top:24px; font-style:italic; color:#555; }
  footer { margin-top:56px; padding-top:20px; border-top:1px solid #ddd;
           font-size:13px; color:#666; text-align:center; }
</style></head><body><div class="wrap">${body}
<footer>Shared with <a href="https://einkreader.app">einkreader</a> —
a calm, offline-first reader for e-ink.</footer>
</div></body></html>`;

export default async function handler(req, res) {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  const name = String(req.query.name ?? '').toLowerCase();
  const registry = await loadRegistry();
  const pubkey = pubkeyOf(registry[name]);
  if (!pubkey) {
    res.setHeader('Cache-Control', 'public, s-maxage=60');
    return res.status(404).send(page('Not found — einkreader',
        `<header><h1>@${esc(name)}</h1>
         <p class="about">No such reader here (yet).</p></header>`));
  }

  const events = await queryRelays(
      { kinds: [0, 9802], authors: [pubkey], limit: 60 });
  const metaEvent = events
      .filter((e) => e.kind === 0)
      .sort((a, b) => (b.created_at ?? 0) - (a.created_at ?? 0))[0];
  let meta = {};
  try {
    meta = JSON.parse(metaEvent?.content ?? '{}');
  } catch {}
  const highlights = events
      .filter((e) => e.kind === 9802)
      .sort((a, b) => (b.created_at ?? 0) - (a.created_at ?? 0));

  const tag = (event, key) =>
      (event.tags ?? []).find((t) => t?.[0] === key)?.[1];

  const links = (meta.website ? [meta.website] : []);
  const highlightHtml = highlights.map((event) => {
    const url = tag(event, 'r');
    const title = tag(event, 'title');
    const comment = tag(event, 'comment');
    const date = event.created_at
        ? new Date(event.created_at * 1000).toISOString().slice(0, 10)
        : '';
    const source = url
        ? `<a href="${esc(url)}" rel="nofollow">${esc(title ?? url)}</a>`
        : esc(title ?? '');
    return `<div class="hl">
      <blockquote>“${esc(event.content)}”</blockquote>
      ${comment ? `<div class="comment">${esc(comment)}</div>` : ''}
      <div class="meta">${source}${source && date ? ' · ' : ''}${date}</div>
    </div>`;
  }).join('\n');

  const displayName = meta.name || name;
  res.setHeader('Cache-Control', 'public, s-maxage=300');
  return res.status(200).send(page(`${displayName} — einkreader`, `
    <header>
      ${meta.picture
          ? `<img class="avatar" src="${esc(meta.picture)}" alt="">` : ''}
      <h1>${esc(displayName)}</h1>
      <div class="nip05">${esc(name)}@einkreader.app</div>
      ${meta.about ? `<p class="about">${esc(meta.about)}</p>` : ''}
      ${links.length ? `<p class="links">${links.map((l) =>
          `<a href="${esc(l)}" rel="nofollow">${esc(l)}</a>`).join('')}</p>`
          : ''}
    </header>
    <h2>Highlights</h2>
    ${highlightHtml ||
        '<p class="empty">No shared highlights yet.</p>'}
  `));
}
