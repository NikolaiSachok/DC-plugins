# DC-plugins — Agent Charter

Public repo of **native macOS Double Commander plugins**. It doubles as a portfolio
piece, so every plugin holds the same bar and the history stays leak-clean and
professional. This file is the operational charter; deeper docs are linked at the end.

## The SDLC every plugin follows

Per change, in order:

1. **Branch for non-trivial work** — never commit straight to `main` for a feature or
   fix. (Docs/process tweaks may go direct.)
2. **Build universal** — `build.sh` → one `.wlx` with `arm64 + x86_64`, ad-hoc signed
   (`codesign -s -`). Verify with `file`/`lipo` + `nm -gU` (all ABI exports present).
3. **Test the REAL built artifact** — headless harnesses in `test/` that `dlopen` the
   built plugin and drive the actual ABI; visual snapshots for rendering. For
   **GUI-bound behavior, verify in real Double Commander** — do not trust a mock (see
   the Esc lesson below). Keep render + any regression harnesses green.
4. **Deterministic pre-commit gate runs automatically** — `.githooks/pre-commit`
   (leak-guard always; universal build + ABI check when a plugin's native source is
   staged). Enable once per clone: `git config core.hooksPath .githooks`.
5. **Semantic review at PR / release boundaries** — run **`/code-review`** on the
   accumulated diff before opening or updating a PR (and before a release). Fix
   verified findings or file them as issues. The reviewer is a **fresh agent, never
   the author**. This is **not** a per-commit step.
6. **Leak hygiene** — `scripts/leak-guard.sh` must be clean. No secrets, no private
   absolute paths, no business/domain terms (this is a public repo; the gate stays
   generic on purpose). For larger content changes, also run the `audit-repo-for-leaks`
   skill before pushing.
7. **Ship** — push via **SSH**; issues/releases via `gh`. End commit messages with the
   `Co-Authored-By:` trailer. Bump the plugin's `VERSION` constant (single source of
   truth, must equal the tag), update `CHANGELOG.md`, then tag `<plugin>-vX.Y.Z` — the
   release workflow builds the universal binary and publishes a no-Xcode install bundle.

### Cadence (match the gate to its cost)
- **Every commit** → deterministic hook only (fast, blocking).
- **Every PR / release** → `/code-review` (semantic, fresh subagents). Reviewing WIP
  micro-commits wastes tokens and breeds alert fatigue; review the accumulated diff.

## Repo invariants
- **Public + leak-clean by construction.** Genericize anything domain-revealing.
- **One directory per plugin**, self-contained. Native, universal, tested, documented.
- **Assets vendored offline and attributed** in each plugin's `THIRD_PARTY_LICENSES.md`.
  No network at view time.
- **Untrusted file content is sanitized** before rendering (e.g. DOMPurify for HTML).
- **Plugins version independently**; each ships a user-visible version surface.

## Platform facts (don't re-learn these)
- A `.wlx`/`.wcx`/`.wdx`/`.wfx` is a Mach-O dylib exporting the Total Commander plugin
  **C ABI**. On macOS, window handles are **`NSView*`** and `__stdcall` is empty.
- Double Commander is **ad-hoc signed, no hardened runtime / library validation**, so
  an ad-hoc-signed plugin loads fine.
- Double Commander is a **Lazarus/LCL** app: it handles key shortcuts through
  **`NSApplication`'s `-sendEvent:` dispatch**, *not* synthetic `-keyDown:` forwarding.
  (This is why the first Esc fix passed a mock test but failed in the app — verify
  host-dependent behavior in the real host.)
- Objects returned across the C ABI must be balanced with
  **`CFBridgingRetain` / `CFBridgingRelease`** under ARC.
- DC uses the **first** registered plugin whose `DetectString` matches → register a
  specific plugin **before** any catch-all (the bundled MacPreview uses `(EXT!="")`).

## Per-plugin checklist (for a new plugin, e.g. image-view)
Each plugin directory owns: `build.sh` (universal + ad-hoc sign), `install.sh`
(idempotent, prebuilt-bundle aware, backs up `doublecmd.xml`), `register_plugin.py` if
it edits config, `test/` (real-artifact harnesses), `assets/` + `THIRD_PARTY_LICENSES.md`,
`README.md`, a `VERSION` constant + on-screen version surface, and `CHANGELOG.md`
entries. Add a row to the root `README.md` table and extend `.github/workflows/` (CI +
release) for the new plugin. See **docs/ADDING-A-PLUGIN.md**.

## Pointers
- **CONTRIBUTING.md** — build/test loop, layout convention, the pre-commit hook.
- **docs/ADDING-A-PLUGIN.md** — scaffold a new plugin to this standard.
- **docs/ARCHITECTURE.md** + the **wiki** — the *why*, platform deep-dive, case studies.
