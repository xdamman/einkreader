#!/usr/bin/env python3
"""Refreshes the Google Play assets in store/ from their sources, in the
formats Play accepts.

  icon          <- site/public/brand/icon-square-512.png (brand kit)
  feature       <- site/public/brand/play-feature-graphic.png (brand kit)
  screenshots   <- test/screenshots/goldens/*_{phone,tablet}.png

Play rules applied: feature graphic and screenshots are 24-bit PNG (no
transparency), and a screenshot's long side is at most twice its short
side (phone captures are cropped at the bottom).

Regenerate the sources first when the UI or brand changed:
  flutter test test/screenshots/screenshot_test.dart --update-goldens \
    --dart-define=screenshots=true
  (cd site && node scripts/build-brand.mjs)
Then:  python3 tool/store_assets.py
"""
import shutil
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / "store"
BRAND = ROOT / "site/public/brand"
GOLDENS = ROOT / "test/screenshots/goldens"
PHONE = ["home_phone", "reader_phone"]
TABLET = ["home_tablet", "reader_tablet", "read_tablet", "highlights_tablet",
          "sources_tablet", "to_read_tablet"]


def flatten(path):
    """RGB on white: Play rejects transparency in these images."""
    im = Image.open(path).convert("RGBA")
    bg = Image.new("RGB", im.size, (255, 255, 255))
    bg.paste(im, mask=im.split()[3])
    return bg


def max_two_to_one(im):
    w, h = im.size
    if h > 2 * w:
        return im.crop((0, 0, w, 2 * w))
    if w > 2 * h:
        return im.crop((0, 0, 2 * h, h))
    return im


def main():
    shutil.copy(BRAND / "icon-square-512.png", STORE / "icon_512.png")
    flatten(BRAND / "play-feature-graphic.png").save(
        STORE / "feature_graphic.png", optimize=True)
    for kind, names in (("phone", PHONE), ("tablet", TABLET)):
        out = STORE / "screenshots" / kind
        out.mkdir(parents=True, exist_ok=True)
        for name in names:
            im = max_two_to_one(flatten(GOLDENS / f"{name}.png"))
            im.save(out / f"{name}.png", optimize=True)
            print(f"{kind}/{name}.png {im.size}")
    print("icon_512.png, feature_graphic.png updated")


if __name__ == "__main__":
    main()
