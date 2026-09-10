# MarkdownView — Double Commander WLX plugin (macOS)

A Lister (WLX) viewer plugin that renders Markdown files **beautifully formatted**
inside Double Commander's viewer (F3), using a `WKWebView`.

Features: GitHub-style CSS, syntax highlighting, GitHub Flavored Markdown (tables,
task lists), **Mermaid diagrams**, **KaTeX math**, relative images, scroll position
preserved across viewer navigation, and configurable light/dark theming. Heavy
libraries (Mermaid, KaTeX) load **only** for files that actually use them.

You can still switch back to the raw **Text** view at any time from the viewer's
mode controls — see "Switching views" below.

## Requirements

- macOS 11+ on Apple Silicon **or** Intel — the build is a universal binary
- Xcode command-line tools (`clang`) to build
- Double Commander (ad-hoc signed, no hardened runtime — loads third-party `.wlx`)

## Build

```sh
./build.sh
```

Produces a universal `build/MarkdownView.wlx` (arm64 + x86_64). The `assets/` folder
(marked.js, highlight.js, GitHub CSS) must always sit **next to** the `.wlx` — the
plugin loads them from `./assets/` relative to its own location.

## Install

Quit Double Commander first (it rewrites its config on exit), then:

```sh
./install.sh
```

This copies the plugin to
`~/Library/Preferences/doublecmd/plugins/wlx/MarkdownView/` (survives DC app
updates) and registers it in `doublecmd.xml` — inserted **before** the bundled
MacPreview plugin, whose `(EXT!="")` detect string would otherwise claim every
file. A timestamped `doublecmd.xml.bak-*` backup is made automatically.

Re-running `install.sh` is idempotent (it replaces the existing entry).

### Manual registration (alternative)

Configuration → Options → Plugins → WLX → Add, then point at the installed
`MarkdownView.wlx`. Move it **above** MacPreview in the list. Set the detect
string to:

```
EXT="MD"|EXT="MARKDOWN"|EXT="MDOWN"|EXT="MKD"|EXT="MKDN"|EXT="MDWN"|EXT="MDTXT"|EXT="MDTEXT"|EXT="MARKDN"|EXT="RMD"|EXT="QMD"
```

## Usage

Select a `.md` file and press **F3** (internal viewer). It opens rendered.

### Switching to raw text and back

In the Lister window, the **View** / mode menu lets you cycle viewer modes
(Text · Binary · Hex · Plugins). Pick **Text** to see the raw Markdown source,
or the plugin/Plugins mode to return to the rendered view. (Default cycle key is
configurable in DC; the View menu always works.)

## Configuration (optional)

All settings are optional — the plugin works with no config. To customize, copy
[`MarkdownView.ini.sample`](MarkdownView.ini.sample) to `MarkdownView.ini` next to
the installed `MarkdownView.wlx` and edit. Changes apply the next time you open a
file — no restart.

```ini
[MarkdownView]
theme    = auto      ; auto (follow macOS) | light | dark
maxwidth = 980       ; content column width, px
fontsize = 16        ; base font size, px
mermaid  = 1         ; render ```mermaid blocks (1/0)
math     = 1         ; render $$…$$ and \(…\)/\[…\] with KaTeX (1/0)
mathdollar = 0       ; also treat single $…$ as math (off — avoids mangling "$5 to $10")
showversion = 1      ; faint plugin-version badge in the bottom-right corner (1/0)
```

Math notes: `\(` and `\[` are also Markdown's escapes for a literal paren or
bracket, so a backslash-delimited span is rendered as math only when it looks like
one. Left as text: anything containing a space but no TeX character (`match \(a
group\)`), bare numbers (`see footnote \[1\]`), a display span with no TeX character
at all (`\[TODO\]`), and any delimiter glued to a word (`file\(s\)`). The heuristic
is not a parser, and it errs toward rendering for inline spans — a single bare token
such as `\(x\)` is treated as math, so write `\\(group\\)` if you mean literal
parens. `$$…$$` gets no content test, only the same not-glued-to-a-word rule.

Delimiters inside code spans, fenced blocks and both inline and block raw HTML
`<pre>`/`<code>`/`<kbd>` are never touched; math inside a raw HTML block (the common
`<div align="center">$$…$$</div>`) does render. The delimiter logic lives in
[`assets/mathext.js`](assets/mathext.js).

**Seeing the version:** the bottom-right corner shows a faint `MarkdownView vX.Y.Z`
badge (hover to brighten). Hide it with `showversion = 0`. The version string is
also embedded in the binary (`strings MarkdownView.wlx | grep MarkdownView`).

Markdown is rendered through **DOMPurify**, so raw HTML/JS embedded in a document
(e.g. `<img onerror=…>`, `<script>`) is stripped and cannot execute in the viewer.

## Sample documents

[`samples/`](samples/) holds Markdown files exercising the renderer (Mermaid, math,
code, tables, relative images, RTL). See [`samples/README.md`](samples/README.md).

## Supported extensions

`.md .markdown .mdown .mkd .mkdn .mdwn .mdtxt .mdtext .markdn .rmd .qmd`

## How it works

- A `.wlx` is a Mach-O dylib exporting the Total Commander Lister API
  (`ListLoad`, `ListLoadNext`, `ListCloseWindow`, `ListGetDetectString`,
  `ListSetDefaultParams`). On macOS the window handles are `NSView*`.
- `ListLoad` builds an `NSView` containing a `WKWebView`, generates an HTML
  document (Markdown base64-embedded, rendered client-side by marked.js +
  highlight.js, with Mermaid/KaTeX added only when the file needs them), and loads
  it via `loadFileURL:allowingReadAccessToURL:` so relative images in the document
  resolve against the file's directory.
- Light/dark follows the system appearance via `prefers-color-scheme`, or is forced
  by the `theme` setting.
- Scroll offset is reported back to the plugin via a `WKScriptMessageHandler` and
  restored when you navigate back to a file (`ListLoadNext`).

For the full design, see the [project wiki](../../../wiki).

## Updating the bundled libraries

```sh
cd assets
curl -sSL -o marked.min.js       https://cdn.jsdelivr.net/npm/marked@12/marked.min.js
curl -sSL -o github-markdown.css https://cdn.jsdelivr.net/npm/github-markdown-css@5/github-markdown.css
curl -sSL -o highlight.min.js    https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js
curl -sSL -o hl-github.css       https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github.min.css
curl -sSL -o hl-github-dark.css  https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github-dark.min.css
curl -sSL -o mermaid/mermaid.min.js https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js
curl -sSL -o katex/katex.min.js     https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.min.js
# KaTeX also needs katex.min.css and fonts/*.woff2 (auto-render is deliberately
# not vendored — math is tokenized in marked instead; see #23)
```

## Uninstall

Remove the entry from `~/Library/Preferences/doublecmd/doublecmd.xml`
(while DC is quit) and delete
`~/Library/Preferences/doublecmd/plugins/wlx/MarkdownView/`.

## Test harnesses (development)

All harnesses load the **real built `.wlx`** via `dlopen` and drive it the way
Double Commander does. Build them with:
`clang -arch arm64 -fobjc-arc -framework Cocoa -framework WebKit -o build/<name> test/<name>.m`

- `test/test_host.m` — render smoke test: loads the plugin, renders `test/sample.md`,
  asserts content rendered (`RESULT: PASS`).
- `test/snap_host.m` — saves a PNG snapshot of the rendered output.
- `test/copy_verify.m` — regression for the `ListSendCommand` export: drives
  `lc_selectall` + `lc_copy` the way DC's viewer does and asserts the system
  clipboard really changed (a text clipboard is saved and restored).
- `test/esc_verify.m` — end-to-end regression for the Escape-key fix: focuses the
  web view, sends Escape, asserts it reaches the host (so the viewer closes).
- `test/math_verify.m` — KaTeX delimiter regression: asserts all three pairs
  (`$$…$$`, `\(…\)`, `\[…\]`) produce real `.katex` nodes, including inside lists
  and tables, and that an escaped `\\(…\\)` and prose dollar amounts are left alone.
- `test/esc_probe.m` — the diagnostic probe used to find the root cause (whether
  `keyDown:` reaches a `WKWebView` subclass and forwarding reaches the parent).
- `test/scroll_verify.m` — scroll-restore regression: scroll a file, navigate away
  and back, assert the offset is restored.
- `test/assets_verify.m` — asset-loading regression: stages the built plugin plus
  its `assets/` into a directory WebKit's content process is sandboxed out of
  (`~/Library/Preferences/…`, where DC installs plugins), loads it from there, and
  asserts marked / DOMPurify / highlight.js are defined and the page rendered.
