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
# 2s MKV (H264+AAC+AAC) — exercises alternate-audio proxy renditions
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc=duration=2:size=320x240:rate=10" \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -f lavfi -i "sine=frequency=880:duration=2" \
  -map 0:v -map 1:a -map 2:a \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=fre \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$OUT/fixture_multi.mkv"
# 2s HLS (H264+AAC, 2 segments) — bundled as RigelTests resources
# (fixture_hls/ is referenced by project.pbxproj; without these files the
# Swift test target's resource phase fails on fresh checkouts)
mkdir -p "$OUT/fixture_hls"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc=duration=2:size=320x240:rate=10" \
  -f lavfi -i "sine=frequency=440:duration=2" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
  -f hls -hls_time 1 -hls_list_size 0 -hls_segment_filename "$OUT/fixture_hls/seg%03d.ts" \
  "$OUT/fixture_hls/index.m3u8"
echo "Fixtures regenerated in $OUT"
