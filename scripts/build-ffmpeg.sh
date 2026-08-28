#!/bin/bash
# Build FFmpeg static libraries for iosSimulatorArm64 and install into
# iosApp/vendor/ffmpeg/{include,lib}. LGPL-3.0; source offer: https://ffmpeg.org
set -euo pipefail

FF_VERSION="${FF_VERSION:-7.1}"
SDK="${SDK:-iphonesimulator}"
ARCH=arm64
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$SDK" = "iphoneos" ]; then
  PREFIX="${PREFIX:-$ROOT/iosApp/vendor/ffmpeg-device}"
else
  PREFIX="${PREFIX:-$ROOT/iosApp/vendor/ffmpeg}"
fi
WORK="${FF_BUILD_DIR:-/tmp/ffbuild-$SDK}"

mkdir -p "$WORK" "$PREFIX"
cd "$WORK"
if [ ! -f "ffmpeg-$FF_VERSION.tar.xz" ]; then
  curl -fL "https://ffmpeg.org/releases/ffmpeg-$FF_VERSION.tar.xz" -o "ffmpeg-$FF_VERSION.tar.xz"
fi
rm -rf "ffmpeg-$FF_VERSION"
tar xf "ffmpeg-$FF_VERSION.tar.xz"
cd "ffmpeg-$FF_VERSION"

SYSROOT="$(xcrun -sdk "$SDK" --show-sdk-path)"
./configure \
  --prefix="$PREFIX" \
  --cc="$(xcrun -f clang)" \
  --arch="$ARCH" \
  --target-os=darwin \
  --enable-cross-compile \
  --sysroot="$SYSROOT" \
  --disable-programs \
  --disable-doc \
  --disable-avdevice \
  --disable-avfilter \
  --disable-postproc \
  --enable-network \
  --enable-protocol=file,http,tcp \
  --enable-videotoolbox \
  --enable-demuxer=matroska,mp4,mov,m4v,hls,mpegts,avi,webm,asf,wav,flac,ogg,mp3,mpegvideo,vc1,webvtt,srt,ass \
  --enable-parser=h264,hevc,vp8,vp9,av1,aac,ac3,eac3,dca,mp3,flac,opus,vorbis,mpeg4video,mpegvideo,vc1 \
  --enable-decoder=h264,hevc,vp8,vp9,av1,aac,ac3,eac3,dca,mp3,flac,opus,vorbis,alac,pcm_s16le,mpeg4,mpeg2video,vc1,subrip,ass,webvtt,mov_text,text \
  --enable-encoder=h264_videotoolbox,aac,webvtt \
  --disable-x86asm \
  --pkg-config-flags="--static"

# Parallel make races on generated headers with -j$(ncpu) on fast machines
# (flaky 'libavutil/... file not found' failures); JOBS lets callers pin it.
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
make -j"$JOBS"
make install
echo "FFmpeg installed to $PREFIX"
