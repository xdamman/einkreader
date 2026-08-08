// Public profile pages, blog-simple (one column of type, no chrome):
//   /:name           — the stream, grouped by story
//   /:name/s/:sid    — one story: every shared quote from it
//   /:name/q/:qid    — quote permalink → 302 to its story page, anchored
// Story titles link to the LOCAL story permalink; the source domain under
// them links to the original. Quotes render as blockquotes with the
// reader's commentary after each; a quote without a comment stands alone.
import { queryRelays } from '../lib/relay.js';
import { groupStories, storyForQuote } from '../lib/profile_render.js';
import { loadRegistry, pubkeyOf } from '../lib/registry.js';

const esc = (value) => String(value ?? '')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;');

const page = (title, body, { name, displayName, feedTitle }) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<link rel="alternate" type="application/rss+xml"
  title="${esc(feedTitle)}" href="/${esc(name)}/feed.xml">
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family: Georgia, 'Times New Roman', serif; color:#111;
         background:#fff; line-height:1.65; }
  .wrap { max-width:34em; margin:0 auto; padding:44px 22px 72px; }
  a { color:#111; }
  .masthead { text-align:center; padding-bottom:16px;
              border-bottom:3px solid #111; margin-bottom:8px; }
  .masthead .who { font-size:26px; font-weight:700; }
  .masthead .who a { text-decoration:none; }
  .masthead .bio { font-size:14px; color:#444; margin-top:2px; }
  .masthead .links { font-size:13px; margin-top:6px; }
  .masthead .links a { margin:0 7px; }
  .crumb { font-size:12px; letter-spacing:.09em; text-transform:uppercase;
           margin:18px 0 2px; }
  .crumb a { color:#666; text-decoration:none; }
  .story { margin:30px 0; }
  .story h2 { font-size:21px; line-height:1.3; margin-bottom:1px; }
  .story h2 a { text-decoration:none; }
  .story h2 a:hover { text-decoration:underline; }
  .story .meta { font-size:12px; letter-spacing:.09em;
                 text-transform:uppercase; color:#888; margin-bottom:10px; }
  .story .meta a { color:#888; }
  blockquote { border-left:3px solid #111; padding:2px 0 2px 14px;
               margin:14px 0 8px; font-size:17px; font-style:italic;
               color:#333; }
  blockquote .q-perma { float:right; font-style:normal; font-size:14px;
                        margin-left:10px; }
  blockquote .q-perma a { color:#bbb; text-decoration:none; }
  blockquote .q-perma a:hover { color:#111; }
  .say { font-size:16px; margin:8px 0 0; }
  .dots { text-align:center; color:#999; letter-spacing:.6em;
          margin:26px 0 0 .6em; }
  :target { background:#f0f0f0; transition: background 1.2s; }
  .subscribe { border-top:1px solid #ddd; margin-top:44px; padding-top:22px;
               text-align:center; }
  .subscribe .lead { font-size:16px; margin-bottom:12px; }
  .chan { display:inline-block; font-size:14px; margin:4px 6px;
          padding:7px 16px; border:1.5px solid #111; border-radius:18px;
          background:#fff; font-family:inherit; cursor:pointer; }
  dialog { border:2px solid #111; border-radius:10px; padding:22px;
           max-width:26em; width:90%; font-family:inherit; }
  dialog::backdrop { background:rgba(0,0,0,.45); }
  dialog h3 { font-size:18px; margin-bottom:8px; }
  dialog p { font-size:14.5px; margin-bottom:10px; }
  dialog .row { display:flex; gap:8px; }
  dialog input[type=email] { flex:1; font:inherit; font-size:14px;
    padding:8px 10px; border:1.5px solid #111; border-radius:6px; }
  dialog code { font-family:monospace; font-size:13px; background:#f2f2f2;
                padding:2px 6px; word-break:break-all; }
  dialog .go { font-size:14px; padding:8px 16px; border:2px solid #111;
               border-radius:18px; background:#111; color:#fff;
               font-family:inherit; cursor:pointer; }
  dialog .close { position:absolute; top:10px; right:14px; border:0;
                  background:none; font-size:18px; cursor:pointer; }
  dialog ul { padding-left:20px; font-size:14px; }
  dialog li { margin-bottom:4px; }
  .empty { margin-top:30px; font-style:italic; color:#555;
           text-align:center; }
  footer { margin-top:40px; font-size:12.5px; color:#777;
           text-align:center; }
</style></head><body><div class="wrap">${body}
<footer>Shared with <a href="https://einkreader.app">einkreader</a> —
the RSS reader made for your e-ink device.</footer>
</div>
<script>
  // Channel modals + device-aware Nostr client recommendations.
  for (const btn of document.querySelectorAll('[data-modal]')) {
    btn.addEventListener('click', () => {
      document.getElementById(btn.dataset.modal).showModal();
    });
  }
  for (const btn of document.querySelectorAll('dialog .close')) {
    btn.addEventListener('click', () => btn.closest('dialog').close());
  }
  const ua = navigator.userAgent;
  const rec = /Android/i.test(ua)
      ? [['Amethyst', 'https://play.google.com/store/apps/details?id=com.vitorpamplona.amethyst'],
         ['Primal', 'https://primal.net/downloads']]
      : /iPhone|iPad/i.test(ua)
          ? [['Damus', 'https://damus.io'], ['Primal', 'https://primal.net/downloads']]
          : [['Primal (web)', 'https://primal.net'], ['Coracle', 'https://coracle.social']];
  const recList = document.getElementById('nostr-recs');
  if (recList) {
    recList.innerHTML = rec.map(([n, u]) =>
        '<li><a href="' + u + '" rel="noopener">' + n + '</a></li>').join('');
  }
  const copyBtn = document.getElementById('copy-rss');
  if (copyBtn) copyBtn.addEventListener('click', async () => {
    await navigator.clipboard.writeText(
        document.getElementById('rss-url').textContent);
    copyBtn.textContent = '✓ copied';
  });
  const form = document.getElementById('email-form');
  if (form) form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const out = document.getElementById('email-status');
    out.textContent = 'Subscribing…';
    const res = await fetch('/api/subscribe', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: form.dataset.profile,
        email: form.elements.email.value,
      }),
    });
    out.textContent = res.ok
        ? "You're on the list — a weekly digest, only when there's something new."
        : 'That didn\\u2019t work — check the address and try again.';
    if (res.ok) form.elements.email.value = '';
  });
</script>
</body></html>`;

function storyHtml(name, group, { headingLink = true } = {}) {
  const quotes = group.quotes.map((quote) => {
    const anchor = `q-${String(quote.id ?? '').slice(0, 12)}`;
    return `
      <blockquote id="${anchor}"><span class="q-perma"><a
        href="/${esc(name)}/q/${String(quote.id ?? '').slice(0, 12)}"
        title="Permalink to this quote">#</a></span>${esc(quote.text)}</blockquote>
      ${quote.comment ? `<p class="say">${esc(quote.comment)}</p>` : ''}`;
  }).join('\n');
  const date = group.latest
      ? new Date(group.latest * 1000).toISOString().slice(0, 10)
      : '';
  const title = headingLink
      ? `<a href="/${esc(name)}/s/${group.id}">${esc(group.title)}</a>`
      : esc(group.title);
  const source = group.url
      ? `<a href="${esc(group.url)}" rel="nofollow noopener">${esc(group.domain ?? 'original')}</a>`
      : (group.domain ? esc(group.domain) : '');
  return `<article class="story">
    <h2>${title}</h2>
    <div class="meta">${source}${source && date ? ' · ' : ''}${date}</div>
    ${quotes}
  </article>`;
}

function subscribeHtml(name, displayName) {
  const first = esc(displayName.split(' ')[0] || displayName);
  return `<div class="subscribe">
    <p class="lead">Subscribe to ${first}'s feed</p>
    <button class="chan" data-modal="m-email">By email</button>
    <button class="chan" data-modal="m-rss">RSS</button>
    <button class="chan" data-modal="m-nostr">Nostr</button>
    <button class="chan" data-modal="m-app">einkreader app</button>

    <dialog id="m-email"><button class="close">✕</button>
      <h3>By email</h3>
      <p>A weekly digest of ${first}'s new highlights and comments — only
      when there's something new.</p>
      <form id="email-form" data-profile="${esc(name)}"><div class="row">
        <input type="email" name="email" required
            placeholder="you@example.com">
        <button class="go">Subscribe</button>
      </div></form>
      <p id="email-status" style="margin-top:8px"></p>
    </dialog>

    <dialog id="m-rss"><button class="close">✕</button>
      <h3>RSS</h3>
      <p>Add this feed to any RSS reader:</p>
      <p><code id="rss-url">https://einkreader.app/${esc(name)}/feed.xml</code>
      <button class="chan" id="copy-rss" style="margin-left:6px">copy</button></p>
    </dialog>

    <dialog id="m-nostr"><button class="close">✕</button>
      <h3>Nostr</h3>
      <p>Follow <code>${esc(name)}@einkreader.app</code> from any Nostr
      client — search for the address and follow.</p>
      <p>Good clients for this device:</p>
      <ul id="nostr-recs"></ul>
    </dialog>

    <dialog id="m-app"><button class="close">✕</button>
      <h3>einkreader app</h3>
      <p>Follow ${first} inside einkreader — highlights land in your
      reading feed, offline like everything else.</p>
      <p><a href="https://einkreader.app">Get einkreader →</a></p>
    </dialog>
  </div>`;
}

export default async function handler(req, res) {
  const name = String(req.query.name ?? '').toLowerCase();
  const registry = await loadRegistry();
  const pubkey = pubkeyOf(registry[name]);
  if (!pubkey) {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.setHeader('Cache-Control', 'public, s-maxage=60');
    return res.status(404).send(`<!doctype html><meta charset="utf-8">
      <title>Not found</title><body style="font-family:Georgia,serif;
      text-align:center;padding-top:80px"><h1>@${esc(name)}</h1>
      <p>No such reader here (yet).</p></body>`);
  }

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
  const groups = groupStories(events);

  // Quote permalink: redirect to its story page, anchored — one canonical
  // page per story, every quote addressable.
  const qid = String(req.query.qid ?? '').toLowerCase();
  if (qid) {
    const group = storyForQuote(groups, qid);
    if (group) {
      res.setHeader('Cache-Control', 'public, s-maxage=300');
      return res
          .redirect(302, `/${name}/s/${group.id}#q-${qid.slice(0, 12)}`);
    }
    // Not on the relays yet (maybe still in the outbox) — the stream is
    // the gentlest landing.
    return res.redirect(302, `/${name}`);
  }

  const sid = String(req.query.sid ?? '').toLowerCase();
  const links = (meta.website ? [meta.website] : []);
  const masthead = `<div class="masthead">
    <div class="who"><a href="/${esc(name)}">${esc(displayName)}</a></div>
    ${meta.about ? `<div class="bio">${esc(meta.about)}</div>` : ''}
    ${links.length ? `<div class="links">${links.map((l) =>
        `<a href="${esc(l)}" rel="nofollow noopener">${esc(l).replace(/^https?:\/\//, '')}</a>`)
        .join('')}</div>` : ''}
  </div>`;
  const opts = {
    name,
    displayName,
    feedTitle: `${displayName} — highlights`,
  };
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'public, s-maxage=300');

  if (sid) {
    const group = groups.find((g) => g.id === sid);
    if (!group) {
      return res.status(404).send(page(`${displayName} — einkreader`,
          `${masthead}<p class="empty">This story isn't here (yet) — it may
           still be on its way to the relays.</p>
           <p style="text-align:center;margin-top:14px">
           <a href="/${esc(name)}">← all highlights</a></p>
           ${subscribeHtml(name, displayName)}`, opts));
    }
    return res.status(200).send(page(
        `${group.title} — ${displayName}`,
        `${masthead}
         <div class="crumb"><a href="/${esc(name)}">← ${esc(displayName)}</a></div>
         ${storyHtml(name, group, { headingLink: false })}
         ${subscribeHtml(name, displayName)}`,
        opts));
  }

  const stream = groups.length
      ? groups.map((g) => storyHtml(name, g))
          .join('\n<div class="dots">· · ·</div>\n')
      : '<p class="empty">No shared highlights yet.</p>';
  return res.status(200).send(page(`${displayName} — einkreader`,
      `${masthead}${stream}${subscribeHtml(name, displayName)}`, opts));
}
