// NIP-05: GET /.well-known/nostr.json?name=<username>
// (rewritten here by vercel.json)
import { loadRegistry } from '../lib/registry.js';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'public, max-age=60');
  const name = String(req.query.name ?? '').toLowerCase();
  const registry = await loadRegistry();
  const names = name
    ? registry[name]
        ? { [name]: registry[name] }
        : {}
    : registry;
  return res.status(200).json({ names });
}
