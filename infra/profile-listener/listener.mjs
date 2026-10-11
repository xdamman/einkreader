// Follows every einkreader.app author on the relays and forwards their new
// profile (kind 0) and highlight (kind 9802) events to
// https://einkreader.app/api/profile-event, which updates the server-side
// event cache and regenerates only that author's pages. Without it the
// pages still refresh from the relays, just up to an hour late.
//
// Authors come from /.well-known/nostr.json (re-read every 10 minutes).
// Node 22+ (built-in WebSocket); no dependencies, no secrets.
const SITE = process.env.SITE ?? 'https://einkreader.app';
const RELAYS = ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net'];
const KINDS = [0, 9802];

const log = (...args) => console.log(new Date().toISOString(), ...args);
let authors = [];
const seen = new Set();
const sockets = new Map();
let pending = [];
let flushTimer = null;

async function loadAuthors() {
  try {
    const res = await fetch(`${SITE}/.well-known/nostr.json`);
    const names = (await res.json()).names ?? {};
    const next = [...new Set(Object.values(names))].sort();
    if (next.join() !== authors.join()) {
      authors = next;
      log(`following ${authors.length} authors`);
      for (const ws of sockets.values()) ws.close();
    }
  } catch (e) {
    log('could not load authors:', e.message);
  }
}

// Events arrive from several relays at once: batch them briefly.
function forward(event) {
  if (seen.has(event.id)) return;
  seen.add(event.id);
  pending.push(event);
  clearTimeout(flushTimer);
  flushTimer = setTimeout(flush, 1500);
}

async function flush() {
  const batch = pending;
  pending = [];
  if (!batch.length) return;
  try {
    const res = await fetch(`${SITE}/api/profile-event`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(batch),
    });
    log(`forwarded ${batch.length} event(s):`, res.status,
        JSON.stringify((await res.json()).added ?? {}));
  } catch (e) {
    log('forward failed, will retry:', e.message);
    for (const event of batch) seen.delete(event.id);
    pending.push(...batch);
    flushTimer = setTimeout(flush, 30000);
  }
}

function connect(url) {
  if (!authors.length) return setTimeout(() => connect(url), 5000);
  const ws = new WebSocket(url);
  sockets.set(url, ws);
  ws.onopen = () => {
    // A little overlap with the last connection: duplicates are dropped.
    const since = Math.floor(Date.now() / 1000) - 600;
    ws.send(JSON.stringify(['REQ', 'einkreader', { kinds: KINDS, authors, since }]));
  };
  ws.onmessage = (message) => {
    try {
      const [type, , event] = JSON.parse(message.data);
      if (type === 'EVENT' && event?.id) forward(event);
    } catch {}
  };
  ws.onclose = () => {
    sockets.delete(url);
    setTimeout(() => connect(url), 5000);
  };
  ws.onerror = () => {};
}

await loadAuthors();
setInterval(loadAuthors, 10 * 60 * 1000);
for (const url of RELAYS) connect(url);
