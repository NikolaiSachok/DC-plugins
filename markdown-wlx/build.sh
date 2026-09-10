#!/bin/zsh
# Build MarkdownView.wlx for Double Commander (macOS, arm64).
set -e
cd "$(dirname "$0")"

OUT="build/MarkdownView.wlx"
# Universal binary so it runs on both Apple Silicon and Intel Macs.
ARCHS=(-arch arm64 -arch x86_64)

mkdir -p "$(dirname "$OUT")"

echo "==> Compiling $OUT"
clang -dynamiclib $ARCHS \
  -mmacosx-version-min=11.0 \
  -fobjc-arc \
  -fvisibility=hidden \
  -O2 \
  -framework Cocoa -framework WebKit \
  -o "$OUT" MarkdownView.m

echo "==> Staging assets"
# The harnesses load the plugin out of build/, so assets/ must be mirrored
# there — otherwise a test can pass against a stale copy of a file this
# build changed or deleted.
rm -rf build/assets
cp -R assets build/assets

echo "==> Ad-hoc signing"
codesign --force --sign - "$OUT"

echo "==> Architectures:"
lipo -archs "$OUT" | sed 's/^/    /'

echo "==> Exported symbols:"
nm -gU "$OUT" | sed 's/^/    /'

echo "==> Done: $OUT"
