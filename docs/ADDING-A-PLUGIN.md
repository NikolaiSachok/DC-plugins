# Adding a new plugin

A short, opinionated path to a second plugin that holds the collection's standard.

## 1. Pick the type and ABI

Decide WLX / WCX / WDX / WFX (see [ARCHITECTURE.md](ARCHITECTURE.md)). Copy only the
slice of the ABI you need into a local `listplug.h`-style header. On macOS, remember
window handles are `NSView*` and `__stdcall` is empty.

Find the exact entry points by inspecting a working plugin:

```sh
nm -gU "/Applications/Double Commander.app/Contents/MacOS/plugins/<type>/<name>/<file>"
```

## 2. Scaffold

```
<name>-<type>/
├── <Name>.m
├── listplug.h
├── build.sh           # clang -dynamiclib -arch arm64 -arch x86_64 ... ; codesign -s -
├── install.sh
├── assets/            # vendored, attributed
├── test/              # headless harness that dlopens the built plugin
├── docs/
├── README.md
└── THIRD_PARTY_LICENSES.md
```

Match `markdown-wlx/build.sh` (universal build + ad-hoc `codesign -s -` + symbol
dump). Double Commander is ad-hoc signed with no hardened runtime, so an ad-hoc
signed plugin loads fine.

## 3. Test headlessly

Write a `test/` host that `dlopen`s the built plugin, calls the entry points the way
DC would, and asserts an observable outcome (it rendered; a value came back; a key
routed correctly). Loading the **real built artifact** — not a mock — is what makes
the test meaningful. See `markdown-wlx/test/test_host.m` and `esc_verify.m`.

## 4. Register & verify live

`install.sh` should be idempotent, back up `doublecmd.xml`, and place the entry so
detection order is correct (DC uses the first plugin whose detect string matches —
mind the catch-all MacPreview `(EXT!="")`). Quit DC before editing its config.

## 5. Wire it into the repo standard

- Add a row to the root `README.md` plugins table.
- Add a `CHANGELOG.md` entry.
- Confirm `bash scripts/leak-guard.sh` is clean.
- CI builds every plugin and checks arches + exports; keep `build.sh` at the path CI
  expects, or extend `.github/workflows/ci.yml`.
