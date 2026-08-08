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

// -- story grouping for the public page -------------------------------------
const { groupStories, storyForQuote, storyId } =
    await import('../lib/profile_render.js');
const ev = (id, at, url, title, text, comment) => ({
  kind: 9802, id, created_at: at, content: text,
  tags: [
    ...(url ? [['r', url]] : []),
    ['title', title],
    ...(comment ? [['comment', comment]] : []),
  ],
});
const groups = groupStories([
  ev('a'.repeat(64), 100, 'https://x.com/a', 'Story A', 'first quote', 'my take'),
  ev('b'.repeat(64), 300, 'https://x.com/a', 'Story A', 'second quote', null),
  ev('c'.repeat(64), 200, 'https://y.org/b', 'Story B', 'other quote', null),
  { kind: 0, id: 'meta', content: '{}', tags: [] }, // ignored
]);
assert.equal(groups.length, 2, 'grouped by story, not per quote');
assert.equal(groups[0].title, 'Story A', 'newest share leads');
assert.equal(groups[0].quotes.length, 2);
assert.equal(groups[0].quotes[0].text, 'second quote', 'newest quote first');
assert.equal(groups[0].quotes[1].comment, 'my take');
assert.equal(groups[0].domain, 'x.com');
assert.equal(groups[0].id, storyId('https://x.com/a', 'Story A'));
assert.equal(storyForQuote(groups, 'cccccccc').title, 'Story B');
assert.equal(storyForQuote(groups, 'ffffffff'), null);
console.log('profile grouping tests passed');
