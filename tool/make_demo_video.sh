#!/usr/bin/env bash
# Assembles the demo video from the frames rendered by
# test/screenshots/demo_video_test.dart (see that file to regenerate).
# Usage: tool/make_demo_video.sh  →  site/public/demo.mp4
set -euo pipefail
cd "$(dirname "$0")/.."
FRAMES=test/screenshots/demo
OUT=site/public/demo.mp4

list=$(mktemp)
add() { printf "file '%s/%s'\nduration %s\n" "$PWD/$FRAMES" "$1" "$2" >>"$list"; }

add 01_card_intro.png 2.6
add 02_feed.png 3.0
add 03_feed_filtered.png 2.4
add 04_card_offline.png 2.2
add 05_reader.png 2.8
add 06_reader_scroll1.png 1.5
add 07_reader_scroll2.png 1.5
add 08_card_highlights.png 2.2
add 09_hl_1.png 0.5
add 09_hl_2.png 0.5
add 09_hl_3.png 0.5
add 09_hl_4.png 0.5
add 09_hl_5.png 1.6
add 10_hl_menu.png 2.6
add 11_card_annotate.png 2.2
add 12_share_dialog.png 3.2
add 13_resume.png 2.8
add 14_card_outro.png 3.0
# concat demuxer needs the last file repeated (its duration is ignored).
printf "file '%s/14_card_outro.png'\n" "$PWD/$FRAMES" >>"$list"

ffmpeg -y -f concat -safe 0 -i "$list" \
  -vf "scale=1200:1600:flags=lanczos,format=yuv420p" \
  -r 30 -c:v libx264 -preset slow -crf 26 -movflags +faststart \
  "$OUT"
rm -f "$list"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
