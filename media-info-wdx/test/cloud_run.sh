#!/bin/zsh
# A test-only filesystem shim models availability; production WDX is unmodified.
set -eu
cd "$(dirname "$0")/.."
clang -dynamiclib -fobjc-arc -Wall -Wextra -framework Foundation \
  -install_name @rpath/libcloud_filesystem.dylib \
  -o build/libcloud_filesystem.dylib test/cloud_filesystem.m
clang -fobjc-arc -Wall -Wextra -framework Foundation -framework CoreGraphics \
  -framework ImageIO -Lbuild -lcloud_filesystem -Wl,-rpath,@executable_path \
  -o build/cloud_verify test/cloud_verify.m
DYLD_INSERT_LIBRARIES="$PWD/build/libcloud_filesystem.dylib" \
  ./build/cloud_verify build/MediaInfo.wdx
