#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
node test/make_samples.js build/samples
python3 test/make_archives.py build/samples
python3 test/register_verify.py build/TableView.wlx
for harness in test_host keys_verify; do
  clang -fobjc-arc -Wall -Wextra -framework Cocoa -o "build/$harness" "test/$harness.m"
done
./build/test_host build/TableView.wlx build/samples
./build/keys_verify build/TableView.wlx build/samples/sample.csv
