# einkreader.app

Landing page + the NIP-05 username service that gives every reader a free
`name@einkreader.app` address.

## Layout

- `public/` — static landing page and screenshots
- `api/nostr-json.js` — serves `/.well-known/nostr.json?name=<username>`
  (rewritten by `vercel.json`), the NIP-05 lookup
- `api/register.js` — `POST { name, pubkey, event }` claims a username;
  ownership is proven by a signed kind-27235 event
- `lib/registry.js` — shared rules + storage (one JSON blob in Vercel Blob)
- `npm test` — pure-logic tests (name rules, signatures, conflicts)

## Deploy (once)

1. In the Vercel dashboard: **Add New Project → Import** the
   `xdamman/einkreader` repo, set **Root Directory** to `site/`.
   (Or from this folder: `npx vercel --prod`.)
2. **Storage → Create Blob store** and connect it to the project — the
   `BLOB_READ_WRITE_TOKEN` env var is added automatically. The username
   registry lives there as `nostr-registry.json`.
3. Point the `einkreader.app` domain at the project (Domains tab — it is
   already on this account).

After that every push to `main` redeploys automatically.

## Notes

- Username rule (server and app agree): 5–20 chars, `a-z 0-9 _` only, plus
  a reserved-names list.
- A pubkey re-registering under a new name releases its old one.
- Registrations are last-write-wins on the single blob; at this scale a
  race is harmless (worst case: one of two simultaneous first-time
  registrations retries).
