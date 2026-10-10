// Inbound email → reading-feed item: conversion helpers, kept pure where
// possible so they are testable without Resend or Blob.
import { createHmac } from 'node:crypto';
import TurndownService from 'turndown';

const turndown = new TurndownService({
  headingStyle: 'atx',
  codeBlockStyle: 'fenced',
});
turndown.remove(['script', 'style']);

/// A Substack newsletter (sent directly or forwarded) as a clean article:
/// the post's title, byline and body, the forwarder's note quoted above
/// it, and the post's public address (without the subscriber's token).
/// Null when the email isn't one. Loaded only for Substack mail, so
/// other emails (and their PDF parsing) run exactly as before.
export async function substackEmail({ html, from, subject }) {
  if (!html || !looksLikeSubstack(html, from)) return null;
  const { isSubstackEmail, substackToMarkdown } = await import('./substack.js');
  if (!isSubstackEmail({ html, from })) return null;
  try {
    const post = substackToMarkdown(html);
    if (!post.markdown) return null;
    const note = post.note
        ? post.note.split('\n').map((l) => `> ${l}`.trimEnd()).join('\n') +
            '\n\n---\n\n'
        : '';
    return {
      subject: post.title ?? subject?.replace(/^\s*(fwd?|tr|wg):\s*/i, ''),
      markdown: note + post.markdown,
      url: post.url,
    };
  } catch {
    return null;
  }
}

const looksLikeSubstack = (html, from) =>
  /substack/i.test(String(html)) || /substack\.com/i.test(String(from ?? ''));

/// Email HTML (or plain text) to Markdown. Images embedded inline in the
/// body (data: or cid: URIs — a mail app's preview of a shared article)
/// are dropped: they'd store megabytes of base64 in the item, and real
/// image attachments are stored and linked separately anyway.
export function emailToMarkdown({ html, text }) {
  if (html && html.trim()) {
    try {
      return cleanInlineImages(turndown.turndown(html));
    } catch {
      // fall through to text
    }
  }
  return (text ?? '').trim();
}

function cleanInlineImages(markdown) {
  return markdown
    .replace(/!\[[^\]]*\]\((?:data|cid):[^)]*\)/g, '')
    // A link left wrapping nothing: "[\n\n](url)".
    .replace(/\[\s*\]\([^)]*\)/g, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/// First http(s) link in a markdown/text body, if any.
export function firstLink(markdown) {
  const match = /https?:\/\/[^\s<>")\]]+/.exec(markdown ?? '');
  return match ? match[0].replace(/[).,;:!?'"”]+$/, '') : null;
}

/// The username in a list of "to" recipients (strings or {address}) for our
/// domain, e.g. xavier@einkreader.app → xavier.
export function usernameFromRecipients(to, domain = 'einkreader.app') {
  const list = Array.isArray(to) ? to : [to];
  for (const recipient of list) {
    const address = (
      typeof recipient === 'string'
        ? recipient
        : recipient?.address ?? recipient?.email ?? ''
    ).toLowerCase();
    const match = address.match(/<?([^<>\s@]+)@([^<>\s@]+)>?$/);
    if (match && match[2] === domain) return match[1];
  }
  return null;
}

/// Bare lowercase address out of "Name <a@b.c>" or plain forms.
export function bareAddress(from) {
  const raw = typeof from === 'string' ? from : from?.address ?? from?.email;
  const match = String(raw ?? '').match(/<?([^<>\s@]+@[^<>\s@]+)>?\s*$/);
  return match ? match[1].toLowerCase() : null;
}

/// Verifies a Svix-style webhook signature (what Resend uses).
/// secret is the whsec_… value; payload is the raw request body string.
export function verifySvixSignature(secret, headers, payload) {
  const id = headers['svix-id'];
  const timestamp = headers['svix-timestamp'];
  const signatures = headers['svix-signature'];
  if (!id || !timestamp || !signatures) return false;
  // Reject stale timestamps (5 minutes).
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false;
  const key = Buffer.from(secret.replace(/^whsec_/, ''), 'base64');
  const expected = createHmac('sha256', key)
    .update(`${id}.${timestamp}.${payload}`)
    .digest('base64');
  return signatures
    .split(' ')
    .some((part) => part.split(',')[1] === expected);
}

/// Assembles the stored inbox item from converted parts (pure).
export function buildItem(
    { subject, from, markdown, attachmentsMarkdown, documents = 0, url }) {
  const body = [markdown, ...attachmentsMarkdown]
    .filter((part) => part && part.trim())
    .join('\n\n---\n\n');
  return {
    subject: subject?.trim() || 'Email',
    from,
    markdown: body,
    url: url ?? firstLink(markdown),
    // PDF/EPUB attachments converted into the body: the email is then
    // content in itself, not just a link to read.
    documents,
    receivedAt: Date.now(),
  };
}

const TEXT_CAP = 200 * 1024;

/// PDF attachment → markdown text (best effort).
export async function pdfToMarkdown(buffer) {
  const { default: pdfParse } = await import('pdf-parse/lib/pdf-parse.js');
  const parsed = await pdfParse(buffer);
  const text = (parsed.text ?? '').trim();
  return text.slice(0, TEXT_CAP);
}

/// EPUB attachment → markdown: unzip, take the content documents in spine
/// order (best effort: manifest order), convert each with turndown.
export async function epubToMarkdown(buffer) {
  const { default: JSZip } = await import('jszip');
  const zip = await JSZip.loadAsync(buffer);
  const documents = Object.keys(zip.files)
    .filter((name) => /\.x?html?$/i.test(name) && !zip.files[name].dir)
    .sort();
  const parts = [];
  let total = 0;
  for (const name of documents) {
    if (total > TEXT_CAP) break;
    const html = await zip.files[name].async('string');
    try {
      const md = turndown.turndown(html).trim();
      if (md) {
        parts.push(md);
        total += md.length;
      }
    } catch {
      // skip malformed chapter
    }
  }
  return parts.join('\n\n').slice(0, TEXT_CAP);
}
