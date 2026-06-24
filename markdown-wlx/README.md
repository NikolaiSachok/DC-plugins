# MarkdownView — Double Commander WLX plugin (macOS)

A Lister (WLX) viewer plugin that renders Markdown files **beautifully formatted**
inside Double Commander's viewer (F3), using a `WKWebView` with GitHub-style CSS,
syntax highlighting, tables, task lists, and automatic light/dark theming.

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

## Supported extensions

`.md .markdown .mdown .mkd .mkdn .mdwn .mdtxt .mdtext .markdn .rmd .qmd`

## How it works

- A `.wlx` is a Mach-O dylib exporting the Total Commander Lister API
  (`ListLoad`, `ListLoadNext`, `ListCloseWindow`, `ListGetDetectString`,
  `ListSetDefaultParams`). On macOS the window handles are `NSView*`.
- `ListLoad` builds an `NSView` containing a `WKWebView`, generates an HTML
  document (Markdown base64-embedded, rendered client-side by marked.js +
  highlight.js), and loads it via `loadFileURL:allowingReadAccessToURL:` so
  relative images in the document resolve against the file's directory.
- Light/dark follows the system appearance via `prefers-color-scheme`.

## Updating the bundled libraries

```sh
cd assets
curl -sSL -o marked.min.js       https://cdn.jsdelivr.net/npm/marked@12/marked.min.js
curl -sSL -o github-markdown.css https://cdn.jsdelivr.net/npm/github-markdown-css@5/github-markdown.css
curl -sSL -o highlight.min.js    https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js
curl -sSL -o hl-github.css       https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github.min.css
curl -sSL -o hl-github-dark.css  https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github-dark.min.css
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
- `test/esc_verify.m` — end-to-end regression for the Escape-key fix: focuses the
  web view, sends Escape, asserts it reaches the host (so the viewer closes).
- `test/esc_probe.m` — the diagnostic probe used to find the root cause (whether
  `keyDown:` reaches a `WKWebView` subclass and forwarding reaches the parent).
