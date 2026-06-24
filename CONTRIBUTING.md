# Contributing

Thanks for your interest. This collection values small, correct, well-tested native
plugins over feature sprawl.

## Prerequisites

- macOS 11+
- Xcode command-line tools: `xcode-select --install`
- Double Commander (for live testing)

## Build / test loop (per plugin)

Each plugin is self-contained in its own directory with a `build.sh`:

```sh
cd markdown-wlx
./build.sh                      # universal .wlx in build/

# Local GUI-bound checks (see the plugin's test/ dir):
clang -arch arm64 -fobjc-arc -framework Cocoa -framework WebKit \
    -o build/test_host test/test_host.m
cp -R assets build/assets
./build/test_host build/MarkdownView.wlx test/sample.md   # asserts it renders
```

Before committing:

```sh
bash scripts/leak-guard.sh      # must print "clean ✓"
```

### Pre-commit hook (deterministic gate)

The repo ships a version-controlled pre-commit hook in [`.githooks/`](.githooks/)
that runs the **Tier 1** deterministic gate: `leak-guard` on every commit, plus a
universal build + ABI-export check whenever a plugin's native source is staged.
Enable it once per clone:

```sh
git config core.hooksPath .githooks
```

It's fast and blocking; bypass in an emergency with `git commit --no-verify`.
Semantic code review (`/code-review`) is **not** part of this hook — run it at
push / PR / release boundaries, on the accumulated diff.

## Plugin layout convention

```
<name>-<type>/            # e.g. markdown-wlx
├── <Name>.m              # implementation (Objective-C / C)
├── listplug.h            # the relevant slice of the TC/DC plugin ABI
├── build.sh              # produces a universal build/<Name>.<ext>
├── install.sh            # installs + registers (idempotent; backs up config)
├── assets/               # vendored runtime assets (attributed in THIRD_PARTY_LICENSES.md)
├── test/                 # headless harnesses that load the real built plugin
├── docs/                 # screenshots, plugin-specific notes
├── README.md             # what it does, install, how it works, uninstall
└── THIRD_PARTY_LICENSES.md
```

See [docs/ADDING-A-PLUGIN.md](docs/ADDING-A-PLUGIN.md) to scaffold a new one.

## Code style

- Match the surrounding code; 4-space indent (see `.editorconfig`).
- Keep the C ABI surface minimal and `extern "C"`-clean — export only what DC calls.
- Manage cross-ABI object lifetimes explicitly (e.g. `CFBridgingRetain`/`Release`
  for an `NSView` handed across the plugin boundary).
- Fix root causes. If a workaround is unavoidable, label it clearly and file the
  proper fix.

## Pull requests

Use the PR template checklist: universal build, exports present, local tests run,
leak-guard clean, and tested live in Double Commander.

## Reporting bugs / proposing plugins

Use the issue templates (bug, feature, new-plugin). Include your macOS and Double
Commander versions and architecture.
