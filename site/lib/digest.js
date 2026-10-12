// The weekly email digest of a profile's shared highlights: pure rendering
// (HTML and plain text), grouped by story exactly like the public page.
import { groupStories } from './profile_render.js';

const sharedOn = (seconds) =>
    new Date(seconds * 1000).toLocaleDateString('en-US',
        { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });

const esc = (value) => String(value ?? '')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// Highlights and notes about an article shared after [sinceSeconds].
export function highlightsSince(events, sinceSeconds) {
  return events.filter((e) => (e.kind === 9802 || e.kind === 1111) &&
      (e.created_at ?? 0) > sinceSeconds);
}

/// { subject, html, text } for [events] (already narrowed to the period).
export function buildDigest({ name, displayName, about, events,
  unsubscribeUrl, test = false }) {
  const groups = groupStories(events);
  const base = `https://einkreader.app/${name}`;
  const count = events.filter((e) => e.kind === 9802).length;
  const subject = `${test ? '[Test] ' : ''}${displayName}: ` +
      `${count} new highlight${count === 1 ? '' : 's'}` +
      (groups[0] ? ` from "${groups[0].title}"` +
          (groups.length > 1 ? ` and ${groups.length - 1} more` : '') : '');

  const storiesHtml = groups.map((g) => `
    <div style="margin:0 0 30px">
      <div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#888;margin-bottom:2px">${sharedOn(g.latest)}</div>
      <h2 style="font-size:20px;line-height:1.3;margin:0 0 2px">
        <a href="${base}/s/${g.id}" style="color:#111;text-decoration:none">${esc(g.title)}</a></h2>
      ${g.url ? `<div style="font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#888;margin-bottom:8px">
        <a href="${esc(g.url)}" style="color:#888">${esc(g.domain ?? 'original')}</a></div>` : ''}
      ${g.note ? `<p style="font-size:16px;margin:6px 0 0">${esc(g.note)}</p>` : ''}
      ${g.quotes.map((q) => `
      <blockquote style="border-left:3px solid #111;margin:12px 0 6px;padding:2px 0 2px 14px;font-style:italic;font-size:17px;color:#333">${esc(q.text)}</blockquote>
      ${q.comment ? `<p style="font-size:16px;margin:6px 0 0">${esc(q.comment)}</p>` : ''}`).join('')}
    </div>`).join('');

  const html = `<!doctype html><html><body style="margin:0;background:#fff">
  <div style="max-width:34em;margin:0 auto;padding:28px 20px;font-family:Georgia,'Times New Roman',serif;color:#111;line-height:1.6">
    <div style="text-align:center;border-bottom:3px solid #111;padding-bottom:12px;margin-bottom:26px">
      <div style="font-size:24px;font-weight:700"><a href="${base}" style="color:#111;text-decoration:none">${esc(displayName)}</a></div>
      ${about ? `<div style="font-size:14px;color:#444">${esc(about)}</div>` : ''}
      <div style="font-size:13px;color:#777;margin-top:4px">New highlights and notes</div>
    </div>
    ${storiesHtml}
    <p style="text-align:center;margin:10px 0 0"><a href="${base}" style="color:#111">Read everything on ${esc(displayName)}'s page →</a></p>
    <p style="font-size:12.5px;color:#777;text-align:center;margin-top:34px;border-top:1px solid #ddd;padding-top:14px">
      You get this because you subscribed to ${esc(displayName)}'s highlights on
      <a href="https://einkreader.app" style="color:#777">einkreader</a>, only in weeks with something new.
      <a href="${esc(unsubscribeUrl)}" style="color:#777">Unsubscribe</a></p>
  </div></body></html>`;

  const text = [
    `${displayName}: new highlights and notes`,
    ...(about ? [about] : []),
    '',
    ...groups.flatMap((g) => [
      sharedOn(g.latest),
      g.title.toUpperCase(),
      `${base}/s/${g.id}`,
      '',
      ...(g.note ? [g.note, ''] : []),
      ...g.quotes.flatMap((q) => [
        `> ${q.text.replace(/\n/g, '\n> ')}`,
        ...(q.comment ? [q.comment] : []),
        '',
      ]),
    ]),
    `All of ${displayName}'s highlights: ${base}`,
    '',
    `Unsubscribe: ${unsubscribeUrl}`,
  ].join('\n');

  return { subject, html, text };
}
