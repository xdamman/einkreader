#!/usr/bin/env python3
"""Prints the release note to post on Nostr when a version reaches Google
Play: everything that changed since the last version that got one, from
the changelog files. The app lists it under Feedback > Release notes when
it comes from one of the maintainers' accounts.

    python3 tool/nostr_release_note.py 0.6.33 --since 0.6.20 > note.txt
    python3 tool/nostr_release_note.py 0.6.33 --since 0.6.20 --tags

Post it from the official account with its tags and the screenshots'
URLs at the end of the text (the app shows them as images):

    nostr post --tags "$(python3 tool/nostr_release_note.py 0.6.33 --tags)" < note.txt

Without --since, only the version itself is described.
"""
import argparse
import json
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parents[1] / "site/data"
# npub1dq33rr42kfeqss8kjpd0l4tn20ppq9fgu5j28c08vlsqjazr8t5qltl4h7
OFFICIAL_HEX = "6823118eaab2720840f6905affd57353c2101528e524a3e1e767e00974433ae8"
PLAY = "https://play.google.com/store/apps/details?id=com.xlcollective.einkreader"


def parse(version):
    return tuple(int(n) for n in version.removeprefix("v").split("."))


def entries(since, version):
    """The changelog entries after `since` up to `version`, newest first."""
    low, high = parse(since) if since else parse(version), parse(version)
    found = {}
    for name in ("changelog.json", "changelog-next.json"):
        for e in json.loads((SITE / name).read_text()):
            if "version" not in e:  # a site-only update
                continue
            v = parse(e["version"])
            if low < v <= high or v == high:
                found[v] = e
    if parse(version) not in found:
        sys.exit(f"no changelog entry for {version}")
    return [found[v] for v in sorted(found, reverse=True)]


def note(version, since=None):
    version = version.removeprefix("v")
    lines = [f"einkReader {version} on Google Play: what's new", ""]
    for e in entries(since, version):
        lines.append(f"{e['title']} ({e['version']})")
        lines += [f"- {change}" for change in e.get("changes", [])]
        lines.append("")
    lines += [f"Update from Google Play: {PLAY}", "",
              "All versions: https://einkreader.app/changelog"]
    return "\n".join(lines) + "\n"


def tags(version):
    version = version.removeprefix("v")
    return [["p", OFFICIAL_HEX], ["t", "feedback"],
            ["t", "einkreader"], ["t", "release-notes"],
            ["subject", f"einkReader {version} on Google Play: what's new"]]


if __name__ == "__main__":
    args = argparse.ArgumentParser()
    args.add_argument("version")
    args.add_argument("--since", help="the last version with a release note")
    args.add_argument("--tags", action="store_true",
                      help="print the note's tags (JSON) instead of its text")
    a = args.parse_args()
    if a.tags:
        print(json.dumps(tags(a.version)))
    else:
        sys.stdout.write(note(a.version, a.since))
