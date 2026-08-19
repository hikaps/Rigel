#!/bin/bash
# Regenerate Swift-test media fixtures into RigelTests/Fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/RigelTests/Fixtures"
mkdir -p "$OUT"
# 2s MP4 (H264+AAC) — AVPlayer-native, DIRECT route
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc=duration=2:size=320x240:rate=10" \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart -shortest "$OUT/fixture.mp4"
# 2s MKV (H264+DTS) — forces REMUX route (dca encoder is experimental)
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc=duration=2:size=320x240:rate=10" \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -c:v libx264 -pix_fmt yuv420p -c:a dca -strict -2 -shortest "$OUT/fixture_dts.mkv"
echo "Fixtures regenerated in $OUT"
