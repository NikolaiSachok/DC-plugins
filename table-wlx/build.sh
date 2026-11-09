#!/bin/zsh
# Build one self-contained universal plugin, including the offline decoder.
set -eu
cd "$(dirname "$0")"
mkdir -p build
python3 - <<'PY'
from pathlib import Path
import hashlib
assert hashlib.sha256(Path('assets/xlsx.full.min.js').read_bytes()).hexdigest() == 'cc015130aa8521e7f088f88898eba949ccdcbfb38df0bd129b44b7273c3a6f41', 'Vendored SheetJS checksum mismatch'
with Path('build/parser.h').open('w') as out:
    for name, path in [('xlsx', 'assets/xlsx.full.min.js'), ('csv', 'assets/csv.js'), ('adapter', 'assets/parse.js')]:
        data = Path(path).read_bytes()
        out.write('static const unsigned char tv_%s[] = {\n' % name)
        for i in range(0, len(data), 24):
            out.write(','.join(str(x) for x in data[i:i+24]) + ',\n')
        out.write('0};\n')
PY
clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -fvisibility=hidden -O2 -fobjc-arc -Wall -Wextra \
  -framework Cocoa -framework JavaScriptCore -larchive \
  -o build/TableView.wlx TableView.m
codesign --force --sign - build/TableView.wlx
lipo -archs build/TableView.wlx
nm -gU build/TableView.wlx
