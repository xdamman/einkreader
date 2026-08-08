// POST /api/subscribe { name, email } — joins the weekly email digest of a
// profile's shared highlights. Addresses are stored per profile in Blob;
// the digest sender (a separate scheduled job, later) reads them.
import { list, put } from '@vercel/blob';
import { loadRegistry, pubkeyOf } from '../lib/registry.js';

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });

  const { name, email } = req.body ?? {};
  const profile = String(name ?? '').toLowerCase();
  const address = String(email ?? '').trim().toLowerCase();
  if (!EMAIL.test(address) || address.length > 254) {
    return res.status(400).json({ error: 'invalid email' });
  }
  const registry = await loadRegistry();
  if (!pubkeyOf(registry[profile])) {
    return res.status(404).json({ error: 'unknown profile' });
  }

  const path = `subscribers/${profile}.json`;
  let subscribers = [];
  try {
    const { blobs } = await list({ prefix: path });
    const blob = blobs.find((b) => b.pathname === path);
    if (blob) {
      const fetched = await fetch(blob.url, { cache: 'no-store' });
      if (fetched.ok) subscribers = await fetched.json();
    }
  } catch {}
  if (subscribers.length >= 5000) {
    return res.status(429).json({ error: 'list full' });
  }
  if (!subscribers.some((s) => s.email === address)) {
    subscribers.push({ email: address, at: Date.now() });
    await put(path, JSON.stringify(subscribers), {
      access: 'public',
      contentType: 'application/json',
      addRandomSuffix: false,
      allowOverwrite: true,
    });
  }
  return res.status(200).json({ ok: true });
}
