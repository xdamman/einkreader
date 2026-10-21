// Entry for public/js/nostr.js, the signing helpers the /feedback page
// needs in the browser. Rebuild with `npm run build:browser`.
import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';

export { bytesToHex, hexToBytes };

export const sha256Hex = (bytes) => bytesToHex(sha256(bytes));

export function generateSecretKey() {
  return bytesToHex(schnorr.utils.randomPrivateKey());
}

export function getPublicKey(secretHex) {
  return bytesToHex(schnorr.getPublicKey(hexToBytes(secretHex)));
}

/// Fills in pubkey, id and sig (NIP-01) for an event template.
export function signEvent(template, secretHex) {
  const event = {
    kind: template.kind,
    created_at: template.created_at ?? Math.floor(Date.now() / 1000),
    tags: template.tags ?? [],
    content: template.content ?? '',
    pubkey: getPublicKey(secretHex),
  };
  const serialized = JSON.stringify([
    0, event.pubkey, event.created_at, event.kind, event.tags, event.content,
  ]);
  event.id = bytesToHex(sha256(new TextEncoder().encode(serialized)));
  event.sig = bytesToHex(schnorr.sign(event.id, hexToBytes(secretHex)));
  return event;
}

// bech32 (NIP-19) for npub and note links, and decoding the official npub.
const CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

function polymod(values) {
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) if ((top >> i) & 1) chk ^= GEN[i];
  }
  return chk;
}

const hrpExpand = (hrp) => [
  ...[...hrp].map((c) => c.charCodeAt(0) >> 5),
  0,
  ...[...hrp].map((c) => c.charCodeAt(0) & 31),
];

function convertBits(data, from, to, pad) {
  let acc = 0;
  let bits = 0;
  const out = [];
  const maxv = (1 << to) - 1;
  for (const value of data) {
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.push((acc >> bits) & maxv);
    }
  }
  if (pad && bits > 0) out.push((acc << (to - bits)) & maxv);
  return out;
}

function bech32Encode(hrp, hex) {
  const data = convertBits(hexToBytes(hex), 8, 5, true);
  const values = [...hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0];
  const mod = polymod(values) ^ 1;
  const checksum = [];
  for (let i = 0; i < 6; i++) checksum.push((mod >> (5 * (5 - i))) & 31);
  return `${hrp}1` + [...data, ...checksum].map((d) => CHARSET[d]).join('');
}

export const npubEncode = (hex) => bech32Encode('npub', hex);

/// A note's NIP-19 id (note1…), the form Nostr apps open.
export const noteEncode = (hex) => bech32Encode('note', hex);

export function npubDecode(npub) {
  const data = [...npub.slice(npub.lastIndexOf('1') + 1)]
    .map((c) => CHARSET.indexOf(c))
    .slice(0, -6);
  return bytesToHex(Uint8Array.from(convertBits(data, 5, 8, false)));
}
