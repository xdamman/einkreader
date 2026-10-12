// Public profile pages, blog-simple (one column of type, no chrome):
//   /:name           — the latest stories, under a header per month
//   /:name/2026/9    — one month
//   /:name/2025      — a year: its months, linked
//   /:name/s/:sid    — one story: every shared quote from it
//   /:name/q/:qid    — quote permalink → 302 to its story page, anchored
// Story titles link to the LOCAL story permalink; the source domain under
// them links to the original. Quotes render as blockquotes with the
// reader's commentary after each; a quote without a comment stands alone.
import { byMonth, groupStories, monthName, storyForQuote }
  from '../lib/profile_render.js';
import { background, cacheProfileResponse, eventsFor, invalidateProfile,
  profileMeta } from '../lib/profile_cache.js';
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
  html { scroll-behavior:smooth; }
  .masthead .sub { display:inline-block; margin-top:12px; font-size:14px;
                   padding:5px 16px; border:1.5px solid #111;
                   border-radius:16px; text-decoration:none; }
  .month { font-size:13px; letter-spacing:.12em; text-transform:uppercase;
           font-weight:700; margin:38px 0 -12px; padding-bottom:6px;
           border-bottom:1px solid #111; }
  .month a { text-decoration:none; }
  .pager { display:flex; justify-content:space-between; gap:12px;
           margin-top:34px; font-size:15px; }
  .pager a { text-decoration:none; }
  .months { list-style:none; margin-top:24px; font-size:18px; }
  .months a { text-decoration:none; }
  .months li { display:flex; justify-content:space-between;
               align-items:baseline;
               border-bottom:1px solid #ddd; padding:10px 2px; }
  .months .n { color:#888; font-size:14px; }
  .story .note { font-size:16px; margin:8px 0 4px; }
  .date { font-size:12px; letter-spacing:.09em; text-transform:uppercase;
            color:#888; margin-bottom:2px; }
  .more { margin:26px 0 0; font-size:16px; }
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
  /* Buttons and links stay black: browsers (iOS) tint them blue. */
  button { color:#111; -webkit-tap-highlight-color:transparent; }
  .chan { display:inline-block; font-size:15px; margin:4px 6px;
          padding:7px 16px; border:1.5px solid #111; border-radius:18px;
          background:#fff; color:#111; font-family:inherit; cursor:pointer; }
  :focus { outline:none; }
  :focus-visible { outline:2px solid #111; outline-offset:2px; }
  /* margin:auto centers the dialog (the reset above removed it). */
  dialog { margin:auto; border:2px solid #111; border-radius:12px;
           padding:26px 22px 22px; max-width:26em; width:calc(100% - 32px);
           font-family:inherit; color:#111; background:#fff;
           text-align:left; }
  dialog::backdrop { background:rgba(0,0,0,.45); }
  dialog h3 { font-size:18px; margin-bottom:8px; }
  dialog p { font-size:14.5px; margin-bottom:10px; }
  dialog .row { display:flex; gap:8px; flex-wrap:wrap; }
  /* 16px or more: iOS zooms into smaller inputs on focus. */
  dialog input[type=email] { flex:1 1 12em; min-width:0; font:inherit;
    font-size:16px; padding:9px 12px; border:1.5px solid #111;
    border-radius:8px; color:#111; background:#fff; }
  dialog input[type=email]:focus { outline:none; border-width:2px; }
  dialog code { font-family:monospace; font-size:13px; background:#f2f2f2;
                padding:2px 6px; word-break:break-all; }
  dialog .go { flex:0 0 auto; font-size:16px; padding:9px 18px;
               border:2px solid #111; border-radius:20px; background:#111;
               color:#fff; font-family:inherit; cursor:pointer; }
  dialog .close { position:absolute; top:8px; right:10px; border:0;
                  background:none; font-size:20px; line-height:1;
                  padding:6px; color:#111; cursor:pointer; }
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
        // Digests arrive Saturday 7am in the reader's own time zone.
        tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      }),
    });
    out.textContent = res.ok
        ? 'Almost there: check your inbox and confirm with the link we just sent.'
        : 'That didn\\u2019t work — check the address and try again.';
    if (res.ok) form.elements.email.value = '';
  });
</script>
</body></html>`;

/// "October 11, 2026", or "October 11" under a month header.
export function sharedOn(seconds, { year = true } = {}) {
  return new Date(seconds * 1000).toLocaleDateString('en-US', {
    ...(year ? { year: 'numeric' } : {}),
    month: 'long', day: 'numeric', timeZone: 'UTC',
  });
}

function storyHtml(name, group, { headingLink = true, year = true } = {}) {
  const quotes = group.quotes.map((quote) => {
    const anchor = `q-${String(quote.id ?? '').slice(0, 12)}`;
    return `
      <blockquote id="${anchor}"><span class="q-perma"><a
        href="/${esc(name)}/q/${String(quote.id ?? '').slice(0, 12)}"
        title="Permalink to this quote">#</a></span>${esc(quote.text)}</blockquote>
      ${quote.comment ? `<p class="say">${esc(quote.comment)}</p>` : ''}`;
  }).join('\n');
  // When the reader shared it (newest quote in the story), shown above the
  // title so it can't be mistaken for the source's publication date.
  const date = group.latest ? sharedOn(group.latest, { year }) : '';
  const title = headingLink
      ? `<a href="/${esc(name)}/s/${group.id}">${esc(group.title)}</a>`
      : esc(group.title);
  const source = group.url
      ? `<a href="${esc(group.url)}" rel="nofollow noopener">${esc(group.domain ?? 'original')}</a>`
      : (group.domain ? esc(group.domain) : '');
  return `<article class="story">
    ${date ? `<div class="date">${date}</div>` : ''}
    <h2>${title}</h2>
    ${source ? `<div class="meta">${source}</div>` : ''}
    ${group.note ? `<p class="note">${esc(group.note)}</p>` : ''}
    ${quotes}
  </article>`;
}

function subscribeHtml(name, displayName) {
  const first = esc(displayName.split(' ')[0] || displayName);
  return `<div class="subscribe" id="subscribe">
    <p class="lead">Subscribe to ${first}'s feed</p>
    <button class="chan" data-modal="m-email">By email</button>
    <button class="chan" data-modal="m-rss">RSS</button>
    <button class="chan" data-modal="m-nostr">Nostr</button>
    <button class="chan" data-modal="m-app">einkreader app</button>

    <dialog id="m-email"><button class="close">✕</button>
      <h3>By email</h3>
      <p>A digest of ${first}'s new highlights and comments, Saturday
      mornings, only when there's something new.</p>
      <form id="email-form" data-profile="${esc(name)}"><div class="row">
        <input type="email" name="email" required autofocus
            autocomplete="email" placeholder="you@example.com">
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

  // From the server-side event cache (lib/profile_cache.js), not the
  // relays: a page renders in milliseconds.
  const events = await eventsFor(pubkey, {
    background,
    onRefreshed: () => invalidateProfile(name),
  });
  const meta = profileMeta(events);
  const displayName = meta.name || name;
  const groups = groupStories(events);

  // Quote permalink: redirect to its story page, anchored — one canonical
  // page per story, every quote addressable.
  const qid = String(req.query.qid ?? '').toLowerCase();
  if (qid) {
    const group = storyForQuote(groups, qid);
    if (group) {
      await cacheProfileResponse(res, name);
      return res
          .redirect(302, `/${name}/s/${group.id}#q-${qid.slice(0, 12)}`);
    }
    // Not on the relays yet (maybe still in the outbox) — the stream is
    // the gentlest landing.
    return res.redirect(302, `/${name}`);
  }

  const sid = String(req.query.sid ?? '').toLowerCase();
  const links = meta.links;
  const masthead = `<div class="masthead">
    <div class="who"><a href="/${esc(name)}">${esc(displayName)}</a></div>
    ${meta.about ? `<div class="bio">${esc(meta.about)}</div>` : ''}
    ${links.length ? `<div class="links">${links.map((l) =>
        `<a href="${esc(l)}" rel="nofollow noopener me">${esc(l.replace(/^https?:\/\/(www\.)?/, '').replace(/\/$/, ''))}</a>`)
        .join('')}</div>` : ''}
    <div><a class="sub" href="#subscribe">Subscribe</a></div>
  </div>`;
  const opts = {
    name,
    displayName,
    feedTitle: `${displayName} — highlights`,
  };
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  await cacheProfileResponse(res, name);

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
         ${storyHtml(name, group, { headingLink: false })}
         <p class="more"><a href="/${esc(name)}">View more highlights and notes
           from ${esc(displayName)} →</a></p>
         ${subscribeHtml(name, displayName)}`,
        opts));
  }

  const months = byMonth(groups);
  const path = (m) => `/${name}/${m.year}/${m.month}`;
  const section = (m, { link = true } = {}) => `<h2 class="month">${link
      ? `<a href="${path(m)}">${monthName(m)}</a>` : monthName(m)}</h2>
    ${m.groups.map((g) => storyHtml(name, g, { year: false }))
        .join('\n<div class="dots">· · ·</div>\n')}`;
  const shell = (title, body, status = 200) => res.status(status).send(page(
      title, `${masthead}${body}${subscribeHtml(name, displayName)}`, opts));
  const pager = (older, middle, newer) => `<div class="pager">
      ${older ?? '<span></span>'}${middle ?? ''}${newer ?? '<span></span>'}
    </div>`;

  // A year: its months, each linked, with the story count.
  const year = Number(req.query.year);
  const month = Number(req.query.month);
  if (year && !month) {
    const inYear = months.filter((m) => m.year === year);
    const years = [...new Set(months.map((m) => m.year))];
    const older = years.find((y) => y < year);
    const newer = years.filter((y) => y > year).pop();
    const list = inYear.length
        ? `<ul class="months">${inYear.map((m) => `<li>
            <a href="${path(m)}">${monthName(m).replace(` ${year}`, '')}</a>
            <span class="n">${m.groups.length} ${m.groups.length === 1
                ? 'story' : 'stories'}</span></li>`).join('')}</ul>`
        : '<p class="empty">Nothing shared that year.</p>';
    return shell(`${year} — ${displayName}`,
        `<h2 class="month">${year}</h2>${list}
         ${pager(older && `<a href="/${name}/${older}">← ${older}</a>`, null,
             newer && `<a href="/${name}/${newer}">${newer} →</a>`)}`,
        inYear.length ? 200 : 404);
  }

  // One month, with links to the months around it that have stories.
  if (year && month) {
    const i = months.findIndex((m) => m.year === year && m.month === month);
    if (i < 0) {
      return shell(`${displayName} — einkreader`,
          `<p class="empty">Nothing shared in ${monthName({ year, month })}.</p>
           <p style="text-align:center;margin-top:14px">
           <a href="/${name}">← all highlights</a></p>`, 404);
    }
    const m = months[i];
    const older = months[i + 1];
    const newer = months[i - 1];
    return shell(`${monthName(m)} — ${displayName}`,
        `${section(m, { link: false })}
         ${pager(older && `<a href="${path(older)}">← ${monthName(older)}</a>`,
             `<a href="/${name}/${m.year}">${m.year}</a>`,
             newer && `<a href="${path(newer)}">${monthName(newer)} →</a>`)}`);
  }

  // The stream: the latest month, plus the ones before it until there's a
  // page's worth to read; then a link to the month before those.
  if (!months.length) {
    return shell(`${displayName} — einkreader`,
        '<p class="empty">No shared highlights yet.</p>');
  }
  const shown = [];
  let stories = 0;
  for (const m of months) {
    if (shown.length && stories >= 8) break;
    shown.push(m);
    stories += m.groups.length;
  }
  const before = months[shown.length];
  return shell(`${displayName} — einkreader`,
      `${shown.map((m) => section(m)).join('\n')}
       ${before ? pager(
           `<a href="${path(before)}">← ${monthName(before)}</a>`) : ''}`);
}
