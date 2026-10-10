// The changelog page and feed are generated from data/changelog.json and
// committed: they must be up to date, and every app version documented.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { changelogAtom, changelogHtml, loadChangelog, withLatest } from '../scripts/build-changelog.mjs';

const entries = loadChangelog();
const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
assert.equal(read('public/changelog.html'), changelogHtml(entries),
    'changelog.html is stale: run `npm run build:changelog`');
assert.equal(read('public/changelog.xml'), changelogAtom(entries),
    'changelog.xml is stale: run `npm run build:changelog`');

const index = read('public/index.html');
assert.equal(index, withLatest(index, entries),
    "the homepage's What's new line is stale: run `npm run build:changelog`");
assert.match(index, /href="\/changelog"/, 'the footer links the changelog');

const versions = entries.filter((e) => e.version).map((e) => e.version);
assert.equal(new Set(versions).size, versions.length, 'one entry per version');
const dates = entries.map((e) => e.date);
assert.deepEqual(dates, [...dates].sort().reverse(), 'newest first');
for (const e of entries) {
  assert.match(e.date, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(e.title && e.changes.length, `${e.version ?? e.date}: title and changes`);
  for (const f of e.feedback ?? []) assert.match(f.id, /^[0-9a-f]{64}$/);
}
// The app's current version has its entry.
const pubspec = read('../pubspec.yaml');
const current = /^version:\s*([0-9.]+)/m.exec(pubspec)[1];
assert.ok(versions.includes(current),
    `version ${current} (pubspec.yaml) is missing from data/changelog.json`);

console.log('changelog tests passed');
