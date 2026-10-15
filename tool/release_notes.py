#!/usr/bin/env python3
"""Prints the GitHub release notes for a version, from its changelog entry
(site/data/changelog.json for a minor, changelog-next.json for a patch):
what changed for readers, and where to get it.

    python3 tool/release_notes.py 0.6.21 > notes.md
"""
import json
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parents[1] / "site/data"


def entry(version):
    for name in ("changelog.json", "changelog-next.json"):
        for e in json.loads((SITE / name).read_text()):
            if e.get("version") == version:
                return e
    sys.exit(f"no changelog entry for {version}")


def notes(version):
    e = entry(version)
    lines = [f"## {e['title']}", ""]
    lines += [f"- {change}" for change in e.get("changes", [])]
    lines += [
        "",
        f"**Download:** `einkreader-v{version}.apk` below, to install on your "
        "e-ink device. Installed from Google Play? It updates on its own.",
        "",
        "All versions: https://einkreader.app/changelog",
    ]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.stdout.write(notes(sys.argv[1].removeprefix("v")))
