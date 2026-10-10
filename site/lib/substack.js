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
const INVISIBLE = /[͏­᠎​-‏ ⁠-⁤﻿]/g;

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

/// The public web address of the post, when the email carries one:
/// a /p/slug link (canonical, without query), else the app link to it.
export function substackPostUrl(doc) {
  const hrefs = Array.from(doc.querySelectorAll('a[href]'))
      .map((a) => a.getAttribute('href'));
  for (const href of hrefs) {
    const m = /^https?:\/\/([a-z0-9-]+\.substack\.com|[^/\s]+)\/p\/([a-z0-9-]+)/i
        .exec(href);
    if (m && !/open\.substack\.com/i.test(m[1])) return `https://${m[1]}/p/${m[2]}`;
  }
  for (const href of hrefs) {
    const m = /open\.substack\.com\/pub\/([a-z0-9-]+)\/p\/([a-z0-9-]+)/i
        .exec(href);
    if (m) return `https://${m[1]}.substack.com/p/${m[2]}`;
  }
  const title = doc.querySelector('h1 a[href*="app-link/post"]') ??
      doc.querySelector('a[href*="app-link/post"]');
  return title ? cleanSubstackUrl(title.getAttribute('href')) : null;
}

const isHidden = (el) => /display\s*:\s*none|max-height\s*:\s*0|mso-hide\s*:\s*all/i
    .test(el.getAttribute?.('style') ?? '');

/// Converts a Substack email to { title, byline, markdown, url, note }.
/// [note] is what the forwarder wrote above the forwarded newsletter.
export function substackToMarkdown(html) {
  const doc = domino.createDocument(String(html ?? ''));
  const body = doc.body;

  for (const el of Array.from(body.querySelectorAll('*'))) {
    if (el.isConnected !== false && isHidden(el)) el.remove();
  }

  // Forwarded: the newsletter sits in the mail app's quote; what's above it
  // is the forwarder's note, and the forwarded headers are dropped.
  const quotes = Array.from(body.querySelectorAll(
      'blockquote[type="cite"], .gmail_quote, blockquote'));
  let root = body;
  let note = '';
  const post = body.querySelector('.post, .body.markup, h1.post-title') ??
      body.querySelector('h1');
  // The outermost quote holding the post (mail apps nest them).
  const container = post && quotes.filter((q) => q.contains(post)).pop();
  if (container) {
    root = container;
    let outer = container;
    while (outer.parentNode && outer.parentNode !== body) outer = outer.parentNode;
    const noteDoc = domino.createDocument('');
    for (const node of Array.from(body.childNodes)) {
      if (node === outer) break;
      noteDoc.body.appendChild(node.cloneNode(true));
    }
    for (const q of Array.from(noteDoc.body.querySelectorAll('blockquote, .gmail_quote, .gmail_attr'))) {
      q.remove();
    }
    note = tidy(turndown.turndown(noteDoc.body.innerHTML))
        .split('\n')
        .filter((l) => !/^(begin forwarded message|-+\s*forwarded message\s*-+)/i
            .test(l.trim()))
        .join('\n')
        .trim();
  }

  const titleEl = root.querySelector('h1.post-title, h1');
  const title = titleEl?.textContent.replace(INVISIBLE, '').trim() || null;
  // The subtitle: by class, else the h3 right after the title.
  const subtitleEl = root.querySelector('h3.subtitle, .subtitle') ??
      Array.from(root.querySelectorAll('h3')).find((h) => titleEl &&
          titleEl.compareDocumentPosition(h) & 4 /* FOLLOWING */);
  const subtitle =
      subtitleEl?.textContent.replace(INVISIBLE, '').trim() || null;
  const author = root.querySelector('a.author, .meta-author') ??
      Array.from(root.querySelectorAll('a[href*="substack.com/@"]'))
          .find((a) => !a.querySelector('img') && a.textContent.trim());
  let authorName = author?.textContent.replace(INVISIBLE, '').trim() || null;
  if (!authorName) {
    // The forwarded headers: "From: Name from Publication <x@substack.com>".
    const from = /From:\s*([^<\n]+?)\s*<[^>]*substack\.com>/i
        .exec(body.textContent ?? '');
    authorName = from?.[1].trim() || null;
  }
  const date = author?.parentNode?.querySelector('.meta, .post-date, time')
      ?.textContent.trim() || null;
  const url = substackPostUrl(doc);

  const content = root.querySelector('.body.markup, .markup') ??
      root.querySelector('.post') ?? root;
  // Newsletter widgets inside the post body.
  for (const el of Array.from(content.querySelectorAll(
      '.subscription-widget-wrap, .subscription-widget, .button-wrapper, ' +
      '.captioned-button-wrap, .install-substack-app-embed, ' +
      '.email-ufi-2-top, .email-ufi-2-bottom, .footer, .post-header, ' +
      'p.forwarded'))) {
    el.remove();
  }
  for (const a of Array.from(content.querySelectorAll('a[href]'))) {
    a.setAttribute('href', cleanSubstackUrl(a.getAttribute('href')));
    // Icon links (like, comment, share…) carry only a small image.
    const img = a.querySelector('img');
    const small = img && Number(img.getAttribute('width') ?? 999) <= 48;
    if (small && !a.textContent.replace(INVISIBLE, '').trim()) a.remove();
  }
  // Image links to the full-size picture: keep just the image.
  for (const a of Array.from(content.querySelectorAll('a[href]'))) {
    if (!a.querySelector('img') || a.textContent.replace(INVISIBLE, '').trim()) continue;
    if (!a.classList.contains('image-link') &&
        !/substackcdn\.com|\.(jpe?g|png|gif|webp)(\?|$)/i.test(a.getAttribute('href'))) {
      continue;
    }
    a.replaceWith(...Array.from(a.childNodes));
  }

  if (content === root) {
    // No post container (unfamiliar markup): the post starts at its title.
    if (titleEl) {
      for (const node of Array.from(root.querySelectorAll('*'))) {
        if (node.isConnected === false || node.contains(titleEl)) continue;
        if (node.compareDocumentPosition(titleEl) &
            4 /* DOCUMENT_POSITION_FOLLOWING */) {
          node.remove();
        }
      }
      // Text directly in a container before the title.
      for (let n = titleEl; n && n !== root; n = n.parentNode) {
        while (n.previousSibling) n.previousSibling.remove();
      }
      subtitleEl?.remove();
      titleEl.remove();
    }
    for (const q of Array.from(root.querySelectorAll('blockquote[type="cite"]'))) {
      q.replaceWith(...Array.from(q.childNodes));
    }
  }

  // A container's own markup (not the quote around it).
  let markdown = tidy(turndown.turndown(
      content === root ? root.innerHTML : content.outerHTML));
  if (content === root) {
    // Drop the chrome lines we know by heart, and the footer.
    const lines = [];
    for (const raw of markdown.split('\n')) {
      const line = raw.trim();
      if (/^©/.test(line)) break;
      if (CHROME.test(line)) continue;
      lines.push(raw);
    }
    markdown = tidy(lines.join('\n'));
  }

  const byline = [authorName, date].filter(Boolean).join(' · ');
  const header = [
    subtitle && subtitle !== title ? `*${subtitle}*` : null,
    byline ? `By ${byline}` : null,
  ].filter(Boolean).join('\n\n');
  return {
    title,
    byline: byline || null,
    url,
    note,
    markdown: [header, markdown].filter(Boolean).join('\n\n'),
  };
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
