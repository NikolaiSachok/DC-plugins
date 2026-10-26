#!/bin/zsh
# Build ImageView.wlx for Double Commander (macOS, universal: arm64 + x86_64).
set -e
cd "$(dirname "$0")"

OUT="build/ImageView.wlx"
ARCHS=(-arch arm64 -arch x86_64)
COMMON=(-mmacosx-version-min=11.0 -fvisibility=hidden -O2)

mkdir -p build

echo "==> Compiling and linking $OUT"
clang -dynamiclib $ARCHS $COMMON -fobjc-arc -Wall -Wextra \
  -framework Cocoa -framework ImageIO -framework QuartzCore \
  -framework UniformTypeIdentifiers \
  -lz \
  -o "$OUT" ImageView.m

echo "==> Ad-hoc signing"
codesign --force --sign - "$OUT"

echo "==> Architectures:"
lipo -archs "$OUT" | sed 's/^/    /'

echo "==> Exported symbols:"
nm -gU "$OUT" | sed 's/^/    /'

echo "==> Done: $OUT"
