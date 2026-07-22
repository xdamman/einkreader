// Live E2E: register a throwaway user with a whitelisted sender, email it
// (with a link and an image attachment) via Resend's send API, wait for the
// inbound webhook, then read the inbox with signed auth. Cleaned up after.
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex } from '@noble/hashes/utils';

const RESEND_KEY = process.env.RESEND_KEY;
const name = `e2e${Date.now() % 1000000}x`;
const secret = bytesToHex(schnorr.utils.randomPrivateKey());
const pubkey = bytesToHex(schnorr.getPublicKey(secret));

function signed(content) {
  const event = {
    pubkey,
    created_at: Math.floor(Date.now() / 1000),
    kind: 27235,
    tags: [],
    content,
  };
  event.id = bytesToHex(sha256(new TextEncoder().encode(JSON.stringify(
      [0, event.pubkey, event.created_at, event.kind, event.tags,
        event.content]))));
  event.sig = bytesToHex(schnorr.sign(event.id, secret));
  return event;
}

// 1. Register with a whitelisted sender.
const reg = await fetch('https://einkreader.app/api/register', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    name,
    pubkey,
    event: signed(name),
    sender: 'probe@einkreader.app',
  }),
});
console.log('register:', reg.status);

// 2. Send a real email to the address (1x1 PNG attached).
const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
const send = await fetch('https://api.resend.com/emails', {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${RESEND_KEY}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    from: 'probe@einkreader.app',
    to: `${name}@einkreader.app`,
    subject: 'E2E: worth a read',
    html: '<p>Check <a href="https://example.com/essay">this essay</a>.</p>',
    attachments: [{ filename: 'dot.png', content: png }],
  }),
});
console.log('send:', send.status, (await send.json()).id ?? '');

// 3. Poll the inbox (webhook delivery takes a few seconds).
const auth = `Nostr ${Buffer.from(JSON.stringify(signed('inbox'))).toString('base64')}`;
let items = [];
for (let attempt = 0; attempt < 12; attempt++) {
  await new Promise((resolve) => setTimeout(resolve, 5000));
  const inbox = await fetch('https://einkreader.app/api/inbox', {
    headers: { Authorization: auth },
  });
  items = (await inbox.json()).items ?? [];
  if (items.length) break;
}
console.log('inbox items:', items.length);
if (items.length) {
  const item = await (await fetch(items[0].url)).json();
  console.log('subject:', item.subject);
  console.log('from:', item.from);
  console.log('url:', item.url);
  console.log('has link md:', /\[this essay\]\(https:\/\/example\.com\/essay\)/.test(item.markdown));
  console.log('has image md:', /!\[dot\.png\]\(https:.*\)/.test(item.markdown));
  console.log('debugShape:', JSON.stringify(item.debugShape));
  console.log('markdown head:', JSON.stringify(item.markdown.slice(0, 200)));
  // 4. Ack (delete) it.
  const ack = await fetch('https://einkreader.app/api/inbox', {
    method: 'DELETE',
    headers: { Authorization: auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids: items.map((i) => i.id) }),
  });
  console.log('ack:', (await ack.json()).deleted);
}
