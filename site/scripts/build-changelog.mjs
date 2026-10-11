// Builds public/changelog.html and public/changelog.xml (Atom) from
// data/changelog.json. Run `npm run build:changelog` after editing it.
//
// Only minor versions (X.Y.0) are published: each entry gathers everything
// since the previous minor. Patch releases and site updates collect their
// notes in data/changelog-next.json until Xavier calls the next minor; its
// entry then folds them in (listing their versions under `includes`, so old
// links like /changelog#v0.6.3 still land on the right entry).
import { readFileSync, writeFileSync } from 'node:fs';

const root = new URL('..', import.meta.url);
const SITE = 'https://einkreader.app';

export const esc = (s) => String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');

export const anchorOf = (entry) =>
  entry.version ? `v${entry.version}` : `update-${entry.date}`;

const longDate = (iso) => new Date(`${iso}T12:00:00Z`).toLocaleDateString(
    'en-US', { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });

function entryHtml(entry) {
  const anchor = anchorOf(entry);
  const label = entry.version ? `Version ${esc(entry.version)}` : 'Service update';
  const feedback = (entry.feedback ?? []).map((f) =>
    `<a href="/feedback#/${esc(f.id)}">${esc(f.title)}</a>`).join(', ');
  const download = entry.version
    ? ` · <a href="https://github.com/xdamman/einkreader/releases/tag/v${esc(entry.version)}">Download</a>`
    : '';
  // Invisible anchors for the patch versions folded into this entry.
  const aliases = (entry.includes ?? []).map((v) =>
    `<span id="v${esc(v)}"></span>`).join('');
  return `
    <article class="entry" id="${anchor}">${aliases}
      <div class="meta"><a class="anchor" href="#${anchor}">${label}</a> · ${esc(longDate(entry.date))}${download}</div>
      <h2>${esc(entry.title)}</h2>
      <ul>${entry.changes.map((c) => `\n        <li>${esc(c)}</li>`).join('')}
      </ul>${feedback ? `
      <p class="feedback">From your feedback: ${feedback}</p>` : ''}
    </article>`;
}

export function changelogHtml(entries) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Changelog — einkreader</title>
  <meta name="description" content="What's new in each version of einkreader.">
  <link rel="alternate" type="application/atom+xml" title="einkreader changelog" href="/changelog.xml">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
  <link rel="apple-touch-icon" href="/apple-touch-icon.png">
  <meta property="og:title" content="einkreader changelog">
  <meta property="og:image" content="${SITE}/og-image.png">
  <meta name="twitter:card" content="summary_large_image">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: Georgia, 'Times New Roman', serif; color: #111; background: #fff; line-height: 1.6; }
    .wrap { max-width: 720px; margin: 0 auto; padding: 32px 16px 80px; }
    a { color: #111; }
    .brand { font-size: 15px; text-decoration: none; color: #555; }
    h1 { font-size: 30px; margin: 4px 0 6px; }
    .intro { font-size: 16px; color: #333; margin-bottom: 8px; }
    .entry { border-top: 1px solid #ddd; padding: 22px 0; }
    .meta { font-size: 14px; color: #555; }
    .meta a { color: #555; }
    .anchor { font-weight: bold; text-decoration: none; color: #111 !important; }
    h2 { font-size: 21px; margin: 4px 0 8px; }
    ul { padding-left: 22px; }
    li { font-size: 16px; margin-bottom: 6px; }
    .feedback { font-size: 15px; margin-top: 10px; padding: 8px 12px; border-left: 3px solid #111; background: #f6f6f6; }
    footer { margin-top: 24px; border-top: 1px solid #ddd; padding-top: 16px; font-size: 14px; color: #555; }
  </style>
</head>
<body>
  <div class="wrap">
    <a class="brand" href="/">← einkreader</a>
    <h1>Changelog</h1>
    <p class="intro">What's new in each version (smaller updates in
    between are gathered into the next one). Many changes start as
    <a href="/feedback">feedback</a>; follow along with the
    <a href="/changelog.xml">changelog feed</a>, in einkreader of course.</p>
${entries.map(entryHtml).join('\n')}
    <footer><a href="/">Home</a> · <a href="/feedback">Feedback</a> · <a href="/contact">Contact</a> · <a href="/privacy">Privacy</a></footer>
  </div>
</body>
</html>
`;
}

export function changelogAtom(entries) {
  const items = entries.slice(0, 30).map((entry) => {
    const anchor = anchorOf(entry);
    const title = entry.version
        ? `einkreader ${entry.version}: ${entry.title}` : entry.title;
    const feedback = (entry.feedback ?? []).map((f) =>
      `<a href="${SITE}/feedback#/${f.id}">${esc(f.title)}</a>`).join(', ');
    const html = `<ul>${entry.changes.map((c) => `<li>${esc(c)}</li>`).join('')}</ul>` +
        (feedback ? `<p>From your feedback: ${feedback}</p>` : '');
    return `  <entry>
    <id>${SITE}/changelog#${anchor}</id>
    <title>${esc(title)}</title>
    <link href="${SITE}/changelog#${anchor}"/>
    <updated>${entry.date}T12:00:00Z</updated>
    <content type="html">${esc(html)}</content>
  </entry>`;
  });
  return `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>${SITE}/changelog</id>
  <title>einkreader changelog</title>
  <link href="${SITE}/changelog"/>
  <link rel="self" href="${SITE}/changelog.xml"/>
  <updated>${entries[0].date}T12:00:00Z</updated>
  <author><name>einkreader</name></author>
${items.join('\n')}
</feed>
`;
}

/// The "What's new" line under the homepage's download button.
export function withLatest(indexHtml, entries) {
  const latest = entries.find((e) => e.version);
  const line = `<a class="whatsnew" href="/changelog#v${esc(latest.version)}">` +
      `New in ${esc(latest.version)}: ${esc(latest.title)} →</a>`;
  return indexHtml.replace(
      /<!-- latest-version -->[\s\S]*?<!-- \/latest-version -->/,
      `<!-- latest-version -->\n    ${line}\n    <!-- /latest-version -->`);
}

export function loadChangelog() {
  return JSON.parse(readFileSync(new URL('data/changelog.json', root), 'utf8'));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const entries = loadChangelog();
  writeFileSync(new URL('public/changelog.html', root), changelogHtml(entries));
  writeFileSync(new URL('public/changelog.xml', root), changelogAtom(entries));
  const index = new URL('public/index.html', root);
  writeFileSync(index, withLatest(readFileSync(index, 'utf8'), entries));
  console.log(`changelog: ${entries.length} entries`);
}
