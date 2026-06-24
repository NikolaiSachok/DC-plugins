#!/bin/zsh
# Build MarkdownView.wlx for Double Commander (macOS, arm64).
set -e
cd "$(dirname "$0")"

OUT="build/MarkdownView.wlx"
# Universal binary so it runs on both Apple Silicon and Intel Macs.
ARCHS=(-arch arm64 -arch x86_64)

echo "==> Compiling $OUT"
clang -dynamiclib $ARCHS \
  -mmacosx-version-min=11.0 \
  -fobjc-arc \
  -fvisibility=hidden \
  -O2 \
  -framework Cocoa -framework WebKit \
  -o "$OUT" MarkdownView.m

echo "==> Ad-hoc signing"
codesign --force --sign - "$OUT"

echo "==> Architectures:"
lipo -archs "$OUT" | sed 's/^/    /'

echo "==> Exported symbols:"
nm -gU "$OUT" | sed 's/^/    /'

echo "==> Done: $OUT"
