// Inbound email conversion + auth helpers, pure parts only.
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import {
  bareAddress,
  buildItem,
  emailToMarkdown,
  epubToMarkdown,
  firstLink,
  usernameFromRecipients,
  verifySvixSignature,
} from '../lib/inbound.js';
import { applyRegistration, entryForPubkey, pubkeyOf, senderOf }
  from '../lib/registry.js';
import JSZip from 'jszip';

// -- html → markdown -------------------------------------------------------
const md = emailToMarkdown({
  html: '<h1>Hello</h1><p>Read <a href="https://example.com/a">this</a>.'
      + '</p><script>evil()</script>',
});
assert.match(md, /# Hello/);
assert.match(md, /\[this\]\(https:\/\/example\.com\/a\)/);
assert.ok(!md.includes('evil'), 'scripts stripped');
assert.equal(emailToMarkdown({ text: 'plain body' }), 'plain body');

// -- link + address parsing ------------------------------------------------
assert.equal(firstLink('see https://example.com/x, ok?'),
    'https://example.com/x');
assert.equal(firstLink('no links'), null);
assert.equal(
    usernameFromRecipients(['Xavier <xavier@einkreader.app>']), 'xavier');
assert.equal(
    usernameFromRecipients([{ address: 'BOB@EINKREADER.APP' }]), 'bob');
assert.equal(usernameFromRecipients(['x@other.com']), null);
assert.equal(bareAddress('Newsletter Bot <bot@Example.COM>'),
    'bot@example.com');

// -- svix signature round-trip ---------------------------------------------
const secretBytes = Buffer.from('0123456789abcdef0123456789abcdef');
const secret = `whsec_${secretBytes.toString('base64')}`;
const payload = '{"hello":"world"}';
const timestamp = String(Math.floor(Date.now() / 1000));
const sig = createHmac('sha256', secretBytes)
    .update(`msg_1.${timestamp}.${payload}`).digest('base64');
const headers = {
  'svix-id': 'msg_1',
  'svix-timestamp': timestamp,
  'svix-signature': `v1,${sig}`,
};
assert.ok(verifySvixSignature(secret, headers, payload));
assert.ok(!verifySvixSignature(secret, headers, payload + 'tampered'));
assert.ok(!verifySvixSignature(secret,
    { ...headers, 'svix-timestamp': '1000' }, payload), 'stale rejected');

// -- item assembly ---------------------------------------------------------
const item = buildItem({
  subject: '  A read  ',
  from: 'me@example.com',
  markdown: 'Check https://example.com/story now',
  attachmentsMarkdown: ['![photo](https://blob/x.jpg)'],
});
assert.equal(item.subject, 'A read');
assert.equal(item.url, 'https://example.com/story');
assert.match(item.markdown, /---/);
assert.match(item.markdown, /!\[photo\]/);

// -- epub extraction -------------------------------------------------------
const zip = new JSZip();
zip.file('OEBPS/ch1.xhtml', '<html><body><h1>Chapter 1</h1><p>Once.</p></body></html>');
zip.file('OEBPS/ch2.xhtml', '<html><body><p>Twice.</p></body></html>');
const epub = await zip.generateAsync({ type: 'nodebuffer' });
const epubMd = await epubToMarkdown(epub);
assert.match(epubMd, /# Chapter 1/);
assert.match(epubMd, /Twice\./);

// -- registry entries carry the allowed sender -----------------------------
const registry = {};
applyRegistration(registry,
    { name: 'xavier', pubkey: 'a'.repeat(64), sender: 'Me@Example.com' });
assert.equal(pubkeyOf(registry.xavier), 'a'.repeat(64));
assert.equal(senderOf(registry.xavier), 'me@example.com');
// Old-shape (bare string) entries still resolve.
registry.legacy = 'b'.repeat(64);
assert.equal(pubkeyOf(registry.legacy), 'b'.repeat(64));
assert.equal(senderOf(registry.legacy), undefined);
assert.equal(entryForPubkey(registry, 'a'.repeat(64)).name, 'xavier');

console.log('inbound tests passed');
