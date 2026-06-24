#!/bin/zsh
# Build MediaInfo.wdx for Double Commander (macOS, universal arm64 + x86_64).
set -e
cd "$(dirname "$0")"

OUT="build/MediaInfo.wdx"
ARCHS=(-arch arm64 -arch x86_64)

mkdir -p "$(dirname "$OUT")"

echo "==> Compiling $OUT"
clang -dynamiclib $ARCHS \
  -mmacosx-version-min=11.0 \
  -fobjc-arc \
  -fvisibility=hidden \
  -O2 \
  -framework Foundation \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework AVFoundation \
  -framework CoreMedia \
  -o "$OUT" MediaInfo.m

echo "==> Ad-hoc signing"
codesign --force --sign - "$OUT"

echo "==> Architectures:"
file "$OUT" | sed 's/^/    /'

echo "==> Exported symbols:"
nm -gU "$OUT" | sed 's/^/    /'

echo "==> Done: $OUT"
