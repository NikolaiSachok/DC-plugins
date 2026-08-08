#!/bin/zsh
# Build EpubView.wlx for Double Commander (macOS, universal: arm64 + x86_64).
set -e
cd "$(dirname "$0")"

OUT="build/EpubView.wlx"
ARCHS=(-arch arm64 -arch x86_64)
COMMON=(-mmacosx-version-min=11.0 -fvisibility=hidden -O2)

mkdir -p build/obj

# zipreader is plain C (no ARC); the view is ARC Objective-C. Compiled apart so
# each gets exactly the flags it should.
echo "==> Compiling zipreader.c"
clang -c $ARCHS $COMMON -std=c11 -Wall -Wextra -o build/obj/zipreader.o zipreader.c

echo "==> Compiling EpubView.m"
clang -c $ARCHS $COMMON -fobjc-arc -Wall -o build/obj/EpubView.o EpubView.m

echo "==> Linking $OUT"
clang -dynamiclib $ARCHS $COMMON \
  -framework Cocoa -framework WebKit \
  -lz \
  -o "$OUT" build/obj/EpubView.o build/obj/zipreader.o

# The plugin loads its reader assets from ./assets next to the .wlx, so the
# build output is runnable (and testable) on its own.
echo "==> Staging assets"
rm -rf build/assets
cp -R assets build/assets

echo "==> Ad-hoc signing"
codesign --force --sign - "$OUT"

echo "==> Architectures:"
lipo -archs "$OUT" | sed 's/^/    /'

echo "==> Exported symbols:"
nm -gU "$OUT" | sed 's/^/    /'

echo "==> Done: $OUT"
