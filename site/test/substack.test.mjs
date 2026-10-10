// Substack newsletters sent to name@einkreader.app, directly or forwarded,
// become clean articles: no invisible preview padding, no icon links, no
// newsletter chrome, the post's public URL without the subscriber's token.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { buildItem, emailToMarkdown, substackEmail } from '../lib/inbound.js';
import { cleanSubstackUrl, isSubstackEmail } from '../lib/substack.js';

const fixture = (name) =>
  readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
const forwarded = fixture('substack-forwarded.html');
const direct = fixture('substack-direct.html');
// The same newsletter with every class stripped: markup we don't know.
const unfamiliar = forwarded.replace(/ class="[^"]*"/g, '');

function assertClean(markdown, label) {
  assert.ok(!/[͏​-‍­ ]/.test(markdown),
      `${label}: no invisible padding`);
  assert.ok(!/\n{3,}/.test(markdown), `${label}: no runs of blank lines`);
  assert.ok(!/\[!\]\(/.test(markdown), `${label}: no icon-only links`);
  assert.ok(!/token=/.test(markdown), `${label}: no subscriber token`);
  for (const chrome of ['READ IN APP', 'Forwarded this email', 'Unsubscribe',
    'Restack', 'Start writing', '548 Market Street', 'Begin forwarded',
    'Reply-To']) {
    assert.ok(!markdown.includes(chrome), `${label}: no "${chrome}"`);
  }
  assert.ok(!/^>?\s*#/m.test(markdown.replace(/^## Why it matters$/m, '')),
      `${label}: no title heading left in the body`);
  assert.match(markdown, /^## Why it matters$/m, `${label}: headings kept`);
  assert.match(markdown, /Artizen is a funding platform/, `${label}: body`);
  assert.match(markdown, /Last paragraph of the post\./, `${label}: end`);
  assert.match(markdown, /^> A real quote/m, `${label}: real quotes kept`);
  assert.match(markdown, /!\[A gallery\]\(https:\/\/substackcdn\.com/,
      `${label}: images kept`);
  assert.match(markdown, /\*The Dopest Worldline\*/, `${label}: subtitle`);
  assert.match(markdown, /By PapaPitta🔥wasJeremy/, `${label}: byline`);
}

// -- detection --------------------------------------------------------------
assert.ok(isSubstackEmail({ html: direct, from: 'x@substack.com' }));
assert.ok(isSubstackEmail({ html: forwarded, from: 'xdamman@gmail.com' }));
assert.ok(!isSubstackEmail({
  html: '<p>Read <a href="https://foo.substack.com/p/bar">this</a></p>',
  from: 'friend@example.com',
}), 'an email sharing a Substack link is a plain link share');
assert.equal(await substackEmail({ html: '<p>Hello</p>', from: 'a@b.c' }), null);

// -- forwarded --------------------------------------------------------------
const fwd = await substackEmail(
    { html: forwarded, from: 'xdamman@gmail.com', subject: 'Fwd: Artizen' });
assert.equal(fwd.subject, 'Artizen');
assert.equal(fwd.url, 'https://gospelofchange.substack.com/p/artizen');
assert.match(fwd.markdown, /^> Thought you'd like this one\.\n\n---\n\n/,
    "the forwarder's note is quoted on top");
assertClean(fwd.markdown, 'forwarded');

// -- direct -----------------------------------------------------------------
const dir = await substackEmail(
    { html: direct, from: 'Gospel <gospelofchange@substack.com>' });
assert.equal(dir.subject, 'Artizen');
assert.ok(!dir.markdown.startsWith('>'), 'no note when sent directly');
assertClean(dir.markdown, 'direct');

// -- unfamiliar markup --------------------------------------------------------
const bare = await substackEmail({ html: unfamiliar, from: 'xdamman@gmail.com' });
assert.equal(bare.subject, 'Artizen');
assert.equal(bare.url, 'https://gospelofchange.substack.com/p/artizen');
// (A subscribe widget's sentence may stay: harmless prose.)
assertClean(bare.markdown
    .replace('Gospel of Change is a reader-supported publication.', '')
    .replace(/\n{3,}/g, '\n\n'), 'unfamiliar');

// -- the item keeps the post URL and the whole post -------------------------
const item = buildItem({
  subject: fwd.subject,
  from: 'xdamman@gmail.com',
  markdown: fwd.markdown,
  attachmentsMarkdown: [],
  url: fwd.url,
});
assert.equal(item.url, 'https://gospelofchange.substack.com/p/artizen');
assert.equal(item.subject, 'Artizen');

// -- links lose tracking and tokens ------------------------------------------
assert.equal(
    cleanSubstackUrl('https://substack.com/app-link/post?publication_id=1&post_id=2&utm_source=x&token=SECRET'),
    'https://substack.com/app-link/post?publication_id=1&post_id=2');
assert.equal(cleanSubstackUrl('https://example.com/a?token=keep-elsewhere&x=1'),
    'https://example.com/a?x=1');
assert.equal(cleanSubstackUrl('https://example.com/a?b=1'),
    'https://example.com/a?b=1', 'other links untouched');

// Regular emails are unaffected.
assert.match(emailToMarkdown({ html: '<h1>Hi</h1>' }), /# Hi/);

console.log('substack email tests passed');
