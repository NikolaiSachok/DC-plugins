# Changelog

All notable changes to this collection are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); plugins are versioned
independently and tagged below.

## [Unreleased]

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
