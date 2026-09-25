// NIP-05: GET /.well-known/nostr.json?name=<username>
// (rewritten here by vercel.json)
import { loadRegistry, pubkeyOf, OFFICIAL_NIP05 } from '../lib/registry.js';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'public, max-age=60');
  const name = String(req.query.name ?? '').toLowerCase();
  const registry = await loadRegistry();
  const names = {};
  for (const [n, pubkey] of Object.entries(OFFICIAL_NIP05)) {
    if (!name || n === name) names[n] = pubkey;
  }
  for (const [n, entry] of Object.entries(registry)) {
    if (!name || n === name) names[n] = pubkeyOf(entry);
  }
  return res.status(200).json({ names });
}
