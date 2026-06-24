# Changelog

All notable changes to this collection are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); plugins are versioned
independently and tagged below.

## [Unreleased]

## markdown-wlx 0.2.0 — 2026-06-24

### markdown-wlx
- **Mermaid diagrams** — ` ```mermaid ` blocks render as diagrams (Mermaid loads only
  for files that contain one). [#2]
- **Math** — `$inline$` and `$$block$$` rendered with KaTeX, vendored offline incl.
  fonts (KaTeX loads only for files that contain `$`). [#3]
- **User configuration** via an optional `MarkdownView.ini` (`[MarkdownView]`):
  `theme` (auto/light/dark), `maxwidth`, `fontsize`, `mermaid`, `math`. Re-read on
  every open — no restart needed. [#4]
- **Scroll position preserved** across viewer navigation: returning to a file
  restores its offset; a new file starts at the top. [#5]
- Two more sample documents (`samples/features.md`, `samples/basics.md`) and a
  scroll-restore regression harness (`test/scroll_verify.m`). [#8]

### Repo
- Release workflow: tagging `markdown-wlx-v*` builds the universal plugin and
  publishes a prebuilt, no-Xcode install bundle (zip + SHA-256) to GitHub Releases. [#6]
- `install.sh` now also installs from a prebuilt release bundle (no build step).

## markdown-wlx 0.1.0 — 2026-06-24

### Added
- WLX lister plugin that renders Markdown in Double Commander's viewer (F3) using
  `WKWebView` with GitHub-style CSS, syntax highlighting (highlight.js), GitHub
  Flavored Markdown (tables, task lists), and automatic light/dark theming.
- Universal binary (arm64 + x86_64).
- Headless test harnesses: render smoke test, PNG snapshot, and an end-to-end
  Escape-key routing verification.
- Idempotent `install.sh` + `register_plugin.py` (installs to a stable,
  update-proof location and registers ahead of the catch-all MacPreview plugin;
  backs up `doublecmd.xml` first).

### Fixed
- Escape now closes the viewer. `WKWebView` swallowed the Escape key, so Double
  Commander never received it; a thin `WKWebView` subclass forwards only Escape up
  the responder chain while leaving all other keys to normal web handling.
