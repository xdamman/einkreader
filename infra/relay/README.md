# relay.einkreader.app

Our own Nostr relay: **writes only from einkreader users** (pubkey must be
registered at einkreader.app — checked against /.well-known/nostr.json,
cached 5 min; the `client einkreader` tag is a soft fallback), **reads open
to everyone** so profile pages and other clients can fetch.

Why strfry: single battle-tested binary, LMDB storage (no database to run),
and a stdin/stdout write-policy plugin — our whole custom logic is the
~50-line strfry-policy.py next to this file. Why not Vercel: relays are
long-lived WebSocket servers; Vercel functions can't accept inbound
WebSockets, so this runs on the VPS.

## Deploy (VPS with Docker)

1. DNS: `vercel dns add einkreader.app relay A <VPS-IP>`
2. Copy this directory to the VPS, then: `docker compose up -d`
3. Verify: `websocat wss://relay.einkreader.app` then send
   `["REQ","test",{"kinds":[1],"limit":1}]` → expect EOSE.

## After it's live (app/site wiring — Claude does this)

- Prepend `wss://relay.einkreader.app` to the app's default relays.
- Prepend it to `site/lib/relay.js` DEFAULT_RELAYS so profile pages read
  our relay first.
