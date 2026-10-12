#!/usr/bin/env node
// Google Play publishing for com.xlcollective.einkreader, through the
// Android Publisher API with a service account (no dependencies).
//
//   node tool/play/play.mjs status
//   node tool/play/play.mjs upload <app.aab> <track> [notes.txt] [--draft]
//   node tool/play/play.mjs promote <versionCode> <track> [notes.txt]
//                                   [--fraction 0.1]
//   node tool/play/play.mjs reviews
//
// The key: $PLAY_SERVICE_ACCOUNT_JSON (the JSON itself, as in CI) or the
// file ~/.config/einkreader/play-service-account.json.
import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const PACKAGE = process.env.PLAY_PACKAGE || 'com.xlcollective.einkreader';
const API = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE}`;
const UPLOAD = `https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${PACKAGE}`;

function serviceAccount() {
  const raw = process.env.PLAY_SERVICE_ACCOUNT_JSON ||
      readFileSync(`${homedir()}/.config/einkreader/play-service-account.json`, 'utf8');
  return JSON.parse(raw);
}

async function accessToken() {
  const sa = serviceAccount();
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64({ alg: 'RS256', typ: 'JWT' })}.${b64({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/androidpublisher',
    aud: sa.token_uri,
    iat: now,
    exp: now + 3600,
  })}`;
  const signature = createSign('RSA-SHA256').update(unsigned)
      .sign(sa.private_key, 'base64url');
  const res = await fetch(sa.token_uri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${signature}`,
    }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`token: ${JSON.stringify(body)}`);
  return body.access_token;
}

let token;
async function call(method, url, body, contentType = 'application/json') {
  token ??= await accessToken();
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body !== undefined ? { 'Content-Type': contentType } : {}),
    },
    body: body === undefined ? undefined
        : contentType === 'application/json' ? JSON.stringify(body) : body,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${url.replace(API, '')}: ${res.status} ${text}`);
  return text ? JSON.parse(text) : {};
}

const openEdit = async () => (await call('POST', `${API}/edits`, {})).id;
// After a rejection (or with managed publishing), Play won't take a commit
// that sends itself for review: it's committed as pending, and someone
// clicks "Send for review" in Publishing overview.
async function commit(edit) {
  try {
    return await call('POST', `${API}/edits/${edit}:commit`);
  } catch (e) {
    if (!/changesNotSentForReview/.test(e.message)) throw e;
    const result = await call('POST',
        `${API}/edits/${edit}:commit?changesNotSentForReview=true`);
    console.log('Committed, not yet sent for review: Play Console → ' +
        'Publishing overview → Send changes for review.');
    return result;
  }
}
const discard = (edit) => call('DELETE', `${API}/edits/${edit}`).catch(() => {});

function notes(file) {
  if (!file) return undefined;
  return [{ language: 'en-US', text: readFileSync(file, 'utf8').trim().slice(0, 500) }];
}

async function status() {
  const edit = await openEdit();
  try {
    const { tracks = [] } = await call('GET', `${API}/edits/${edit}/tracks`);
    const { bundles = [] } = await call('GET', `${API}/edits/${edit}/bundles`);
    for (const t of tracks) {
      const releases = t.releases ?? [];
      console.log(`${t.track}: ${releases.length ? '' : '(empty)'}`);
      for (const r of releases) {
        console.log(`  ${r.name ?? '-'} [${(r.versionCodes ?? []).join(',')}] ` +
            `${r.status}${r.userFraction ? ` ${r.userFraction * 100}%` : ''}`);
      }
    }
    console.log(`bundles uploaded: ${bundles.map((b) => b.versionCode).join(', ') || 'none'}`);
  } finally {
    await discard(edit);
  }
}

async function setTrack(edit, track, release) {
  return call('PUT', `${API}/edits/${edit}/tracks/${track}`,
      { track, releases: [release] });
}

async function upload(aab, track, notesFile, draft) {
  const edit = await openEdit();
  try {
    const bundle = await call('POST',
        `${UPLOAD}/edits/${edit}/bundles?uploadType=media`,
        readFileSync(aab), 'application/octet-stream');
    console.log(`uploaded versionCode ${bundle.versionCode}`);
    await setTrack(edit, track, {
      versionCodes: [String(bundle.versionCode)],
      status: draft ? 'draft' : 'completed',
      releaseNotes: notes(notesFile),
    });
    await commit(edit);
    console.log(`${track}: ${bundle.versionCode} ${draft ? 'draft' : 'released'}`);
  } catch (e) {
    await discard(edit);
    throw e;
  }
}

async function promote(versionCode, track, notesFile, fraction) {
  const edit = await openEdit();
  try {
    await setTrack(edit, track, {
      versionCodes: [String(versionCode)],
      status: fraction ? 'inProgress' : 'completed',
      ...(fraction ? { userFraction: fraction } : {}),
      releaseNotes: notes(notesFile),
    });
    await commit(edit);
    console.log(`${track}: ${versionCode} ${fraction ? `rolling out to ${fraction * 100}%` : 'released'}`);
  } catch (e) {
    await discard(edit);
    throw e;
  }
}

async function reviews() {
  const { reviews: list = [] } = await call('GET', `${API}/reviews`);
  for (const r of list) {
    const c = r.comments?.[0]?.userComment;
    console.log(`${r.reviewId} ${c?.starRating}★ ${r.authorName ?? ''}: ${c?.text?.trim()}`);
  }
  if (!list.length) console.log('no reviews in the last week');
}

const [cmd, ...args] = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const [, value] = args.splice(i, 2);
  return value;
};
const fraction = Number(flag('--fraction')) || undefined;
const draft = args.includes('--draft');
const rest = args.filter((a) => a !== '--draft');

try {
  if (cmd === 'status') await status();
  else if (cmd === 'upload') await upload(rest[0], rest[1], rest[2], draft);
  else if (cmd === 'promote') await promote(rest[0], rest[1], rest[2], fraction);
  else if (cmd === 'reviews') await reviews();
  else {
    console.error('usage: play.mjs status | upload <aab> <track> [notes] [--draft] | ' +
        'promote <versionCode> <track> [notes] [--fraction f] | reviews');
    process.exit(2);
  }
} catch (e) {
  console.error(e.message);
  process.exit(1);
}
