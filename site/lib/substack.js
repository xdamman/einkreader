// Substack newsletters, received directly or forwarded: the email is turned
// into a clean article (title, byline, the post body) instead of the raw
// newsletter chrome — hidden preview text padded with invisible characters,
// like/comment/share icons, "Read in app", subscribe widgets and footer.
import domino from '@mixmark-io/domino';
import TurndownService from 'turndown';

const turndown = new TurndownService({
  headingStyle: 'atx',
  codeBlockStyle: 'fenced',
});
turndown.remove(['script', 'style']);

/// Characters Substack (and other senders) repeat to pad the inbox preview:
/// combining grapheme joiner, zero-width (non-)joiners/spaces, soft hyphen,
/// figure space, BOM.
const INVISIBLE = new RegExp(`[${[
  0x034F, 0x00AD, 0x180E, 0x2007, 0xFEFF, // grapheme joiner, soft hyphen…
  ...range(0x200B, 0x200F), // zero-width spaces and joiners, marks
  ...range(0x2060, 0x2064), // word joiner and invisible operators
].map((c) => String.fromCodePoint(c)).join('')}]`, 'g');

function range(from, to) {
  return Array.from({ length: to - from + 1 }, (_, i) => from + i);
}

/// Whether this email is a Substack newsletter (direct or forwarded). A
/// plain email that merely shares a Substack link is not.
export function isSubstackEmail({ html, from }) {
  if (/@substack\.com>?\s*$/i.test(String(from ?? ''))) return true;
  const h = String(html ?? '');
  if (/substack\.com\/app-link\/post/i.test(h)) return true;
  return /substackcdn\.com/i.test(h) &&
      /class="[^"]*\b(post-title|body markup)\b/i.test(h);
}

/// Drops tracking and, above all, the subscriber's login token from a
/// Substack link: a shared link must never sign someone in as the reader.
export function cleanSubstackUrl(href) {
  let url;
  try {
    url = new URL(href);
  } catch {
    return href;
  }
  if (!/(^|\.)substack\.com$/i.test(url.hostname) &&
      !url.pathname.startsWith('/p/') &&
      !url.searchParams.has('token')) {
    return href;
  }
  for (const key of [...url.searchParams.keys()]) {
    if (/^(token|utm_.*|r|isFreemail|triedRedirect|redirect|action)$/i
        .test(key)) {
      url.searchParams.delete(key);
    }
  }
  return url.toString();
}

/// The public web address of the post, when the email carries one: a
/// /p/slug link, canonical (no query). Never an app link: without the
/// subscriber's token those land on the publication's subscribe page.
export function substackPostUrl(doc) {
  const hrefs = Array.from(doc.querySelectorAll('a[href]'))
      .map((a) => a.getAttribute('href'));
  for (const href of hrefs) {
    const m = /open\.substack\.com\/pub\/([a-z0-9-]+)\/p\/([a-z0-9-]+)/i
        .exec(href);
    if (m) return `https://${m[1]}.substack.com/p/${m[2]}`;
  }
  for (const href of hrefs) {
    const m = /^https?:\/\/([a-z0-9.-]+)\/p\/([a-z0-9-]+)/i.exec(href);
    if (m && !/^(open\.)?substack\.com$/i.test(m[1])) {
      return `https://${m[1]}/p/${m[2]}`;
    }
  }
  return null;
}

const HIDDEN_STYLE =
    /display\s*:\s*none|max-height\s*:\s*0(px)?\s*(;|$)|opacity\s*:\s*0(\.0+)?\s*(;|$)|font-size\s*:\s*0(px)?\s*(;|$)/i;
const textOf = (el) => (el.textContent ?? '').replace(INVISIBLE, '')
    .replace(/\s+/g, ' ').trim();
const wordCount = (s) => (s.replace(INVISIBLE, '').match(/[\p{L}\p{N}]{2,}/gu) ?? []).length;

/// Converts a Substack email to { title, byline, markdown, url, note }.
///
/// Conservative on purpose: it removes only what it can recognize (hidden
/// preview padding, icon links, forwarded headers, known buttons and the
/// footer) and never picks a "post container" that could drop text. If the
/// result still lost much of the email's words, the email's full text is
/// used instead, just without the invisible padding.
export function substackToMarkdown(html) {
  const doc = domino.createDocument(String(html ?? ''));
  const body = doc.body;
  const fullWords = wordCount(body.textContent ?? '');
  const fallback = tidy(turndown.turndown(body.innerHTML));

  // Hidden preview text: only small hidden bits, never a hidden wrapper
  // around the post (some emails hide content per client).
  for (const el of Array.from(body.querySelectorAll('[style]'))) {
    if (el.isConnected === false) continue;
    if (HIDDEN_STYLE.test(el.getAttribute('style')) && textOf(el).length < 300) {
      el.remove();
    }
  }
  // Icon links (like, comment, share, the author's avatar): a small image
  // and no words.
  for (const a of Array.from(body.querySelectorAll('a[href]'))) {
    a.setAttribute('href', cleanSubstackUrl(a.getAttribute('href')));
    const imgs = Array.from(a.querySelectorAll('img'));
    if (!imgs.length || textOf(a)) continue;
    const small = imgs.every((img) =>
      Number(img.getAttribute('width') ?? 999) <= 48 ||
      Number(img.getAttribute('height') ?? 999) <= 48 ||
      /\/icon\/|lucide/i.test(img.getAttribute('src') ?? ''));
    if (small) a.remove();
  }
  for (const img of Array.from(body.querySelectorAll('img'))) {
    if (/\/icon\/|lucide/i.test(img.getAttribute('src') ?? '')) img.remove();
  }

  const titleEl = body.querySelector('h1.post-title') ?? body.querySelector('h1');
  const title = titleEl ? textOf(titleEl) || null : null;
  const url = substackPostUrl(doc);

  // The author: the post's byline link, else the forwarded "From:" line.
  const authorLink = body.querySelector('a.author') ??
      Array.from(body.querySelectorAll('a[href*="substack.com/@"]'))
          .find((link) => textOf(link));
  const fromHeader = /From:\s*([^<\n]+?)\s*<[^>]*substack\.com>/i
      .exec(body.textContent ?? '');
  const authorName = (authorLink && textOf(authorLink)) ||
      fromHeader?.[1].replace(INVISIBLE, '').trim() || null;

  const { note, lines } = splitForward(
      tidy(turndown.turndown(body.innerHTML)).split('\n'));

  // The post starts at its title: what's above it in the newsletter is the
  // inbox preview and "Forwarded this email? Subscribe". Only when the
  // title is near the top, so nothing real is skipped.
  let start = 0;
  const titleIndex = title
    ? lines.findIndex((l) => /^#\s/.test(l) && l.includes(title.slice(0, 40)))
    : -1;
  if (titleIndex >= 0 &&
      lines.slice(0, titleIndex).filter((l) => l.trim()).length <= 12) {
    start = titleIndex + 1;
  }
  let out = lines.slice(start);
  // The subtitle right under the title becomes an italic line.
  let subtitle = null;
  const firstText = out.findIndex((l) => l.trim());
  if (firstText >= 0 && /^#{2,6}\s/.test(out[firstText])) {
    subtitle = out[firstText].replace(/^#+\s*/, '').trim();
    out.splice(firstText, 1);
  }
  out = out.filter((l) => !CHROME.test(l.trim()));
  // The footer: from the © line, when it's near the end.
  const copyright = out.findIndex((l) => /^©/.test(l.trim()));
  if (copyright >= 0 &&
      out.slice(copyright).filter((l) => l.trim()).length <= 12) {
    out = out.slice(0, copyright);
  }
  // A picture linking to its full-size file: just the picture (the
  // reader shows images inside links as a bare "!").
  let markdown = tidy(out.join('\n')
      .replace(/\[(!\[[^\]]*\]\([^)\s]+\))\]\([^)\s]+\)/g, '$1'));
  const header = [
    subtitle && subtitle !== title ? `*${subtitle}*` : null,
    authorName ? `By ${authorName}` : null,
  ].filter(Boolean).join('\n\n');
  markdown = [header, markdown].filter(Boolean).join('\n\n');

  // Safety net: never lose the post. The chrome is a small part of an
  // email; losing more than half the words means something went wrong.
  if (wordCount(markdown) + wordCount(note) < fullWords * 0.5) {
    return { title, byline: authorName, url, note: '', markdown: fallback };
  }
  return { title, byline: authorName, url, note, markdown };
}

/// Splits a forwarded email's markdown: the forwarder's note (above the
/// "Begin forwarded message" / "Forwarded message" marker) and the
/// forwarded email itself, unquoted and without its From/Date/To/Subject
/// header lines.
function splitForward(lines) {
  const marker = lines.findIndex((l) =>
    /^(>\s*)*(begin forwarded message|-{2,}\s*forwarded message\s*-{2,})/i
        .test(l.trim()));
  if (marker < 0) return { note: '', lines };
  const note = tidy(lines.slice(0, marker).join('\n'));
  const rest = lines.slice(marker + 1).map((l) => l.replace(/^>\s?/, ''));
  const header = /^\**(from|date|sent|to|cc|subject|reply-to):?\**:?\s/i;
  // Header lines come first (possibly after blank lines).
  let i = 0;
  while (i < rest.length && (!rest[i].trim() || header.test(rest[i].trim()))) i++;
  return { note, lines: rest.slice(i) };
}

const CHROME = new RegExp('^(' + [
  String.raw`\[!\]\(.*\)`, // icon-only links
  String.raw`\[(!\[[^\]]*\]\([^)]*\))?\s*(like|comment|restack|share|subscribe now|start writing|unsubscribe|read in app)\]\(.*\)`,
  'forwarded this email\\?.*',
  'read in app',
  String.raw`\[[^\]]*\]\(https:\/\/substack\.com\/@[^)]*\)`, // author link
  '(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \\d{1,2}(, \\d{4})?',
].join('|') + ')$', 'i');

/// Invisible padding out, whitespace-only lines emptied, runs of blank
/// lines collapsed.
function tidy(markdown) {
  return markdown
      .replace(INVISIBLE, '')
      .replace(/ /g, ' ')
      .split('\n')
      .map((l) => (l.trim() === '' || /^>\s*$/.test(l.trim()) ? '' : l.replace(/\s+$/, '')))
      .join('\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
}
