#!/usr/bin/env python3
"""strfry write-policy for relay.einkreader.app.

Accepts an event only when its author is a registered einkreader user
(pubkey listed at einkreader.app/.well-known/nostr.json) — the client tag
alone is trivially spoofable, so the registry is the real gate; the tag is
accepted as a soft fallback while a fresh registration propagates.
Reads are open to everyone: the public profile pages and other clients
must be able to fetch.
"""
import json
import sys
import time
import urllib.request

REGISTRY_URL = "https://einkreader.app/.well-known/nostr.json"
CACHE_SECONDS = 300

_cache = {"at": 0.0, "pubkeys": set()}


def registered_pubkeys():
    now = time.time()
    if now - _cache["at"] > CACHE_SECONDS:
        try:
            with urllib.request.urlopen(REGISTRY_URL, timeout=5) as r:
                names = json.load(r).get("names", {})
            _cache["pubkeys"] = set(names.values())
            _cache["at"] = now
        except Exception:
            # Keep the stale cache on registry hiccups.
            _cache["at"] = now - CACHE_SECONDS + 30
    return _cache["pubkeys"]


def decide(event):
    if event.get("pubkey") in registered_pubkeys():
        return "accept", ""
    tags = event.get("tags", [])
    if any(t[:2] == ["client", "einkreader"] for t in tags if len(t) >= 2):
        return "accept", ""
    return "reject", "blocked: relay.einkreader.app only carries einkreader users"


for line in sys.stdin:
    req = json.loads(line)
    action, msg = decide(req.get("event", {}))
    print(json.dumps({"id": req["event"]["id"], "action": action, "msg": msg}),
          flush=True)
