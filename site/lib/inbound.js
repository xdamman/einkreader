// Inbound email → reading-feed item: conversion helpers, kept pure where
// possible so they are testable without Resend or Blob.
import { createHmac } from 'node:crypto';
import TurndownService from 'turndown';

const turndown = new TurndownService({
  headingStyle: 'atx',
  codeBlockStyle: 'fenced',
});
turndown.remove(['script', 'style']);

/// Email HTML (or plain text) to Markdown.
export function emailToMarkdown({ html, text }) {
  if (html && html.trim()) {
    try {
      return turndown.turndown(html).trim();
    } catch {
      // fall through to text
    }
  }
  return (text ?? '').trim();
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
export function buildItem({ subject, from, markdown, attachmentsMarkdown }) {
  const body = [markdown, ...attachmentsMarkdown]
    .filter((part) => part && part.trim())
    .join('\n\n---\n\n');
  return {
    subject: subject?.trim() || 'Email',
    from,
    markdown: body,
    url: firstLink(markdown),
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
