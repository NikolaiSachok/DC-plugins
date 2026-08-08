# EpubView — Double Commander WLX plugin (macOS)

Reads **EPUB e-books** in Double Commander's F3 viewer: a contents sidebar, the
whole book as one continuous reflowable column, cover and metadata, and
light / dark / sepia themes. Press **F3** on any `.epub` and it opens as a book
rather than as a ZIP file.

There was no EPUB lister for Double Commander on macOS before this — the
existing ones (EPUB Lister, eBookInfo, SumatraLister) are Windows PE plugins and
cannot load into a Mach-O host. See [#19](https://github.com/NikolaiSachok/DC-plugins/issues/19).

- **Contents sidebar** from the EPUB 3 `nav` document or the EPUB 2 NCX, nested,
  with the current chapter highlighted as you scroll
- **Reading position remembered** per book for the session, and a progress readout
- **Text size** adjustable with `A-` / `A+` (or `-` / `+`); the choice sticks for
  the session
- **Cover** shown when the book doesn't already open on one
- **Nothing written to disk and nothing fetched from the network** — the book is
  served straight out of the ZIP, in-process

## Requirements

macOS 11+ and the Xcode command-line tools (`xcode-select --install`) to build.
No other dependencies: decompression uses the system zlib, rendering uses WebKit.

## Build

```sh
./build.sh          # → build/EpubView.wlx  (universal: arm64 + x86_64)
```

The script compiles both architectures, ad-hoc signs the result (`codesign -s -`,
which is all Double Commander needs), stages `assets/` beside the binary, and
prints the architectures and exported symbols so you can see the ABI is complete.

## Install

Quit Double Commander first — it rewrites its config on exit and will otherwise
overwrite the registration.

```sh
./install.sh
```

This copies the plugin and its assets to
`~/Library/Preferences/doublecmd/plugins/wlx/EpubView/`, backs up
`doublecmd.xml`, and registers the plugin **before** the bundled `MacPreview`
plugin — whose detect string is the catch-all `(EXT!="")`, so anything after it
never gets a chance at `.epub`.

### Manual registration (alternative)

Configuration → Options → Plugins → WLX Plugins → Add, choose
`EpubView.wlx`, set the detect string to `EXT="EPUB"`, and move the entry above
`MacPreview`.

## Usage

| Action | How |
|--------|-----|
| Open a book | **F3** on an `.epub` |
| Show/hide contents | the ☰ button, or **t** |
| Jump to a chapter | click it in the contents |
| Larger / smaller text | `A+` / `A-`, or **+** / **-** |
| Scroll | trackpad, arrows, Page Up/Down, Home/End |
| Close the viewer | **Esc** |
| Read it as raw text instead | the viewer's own mode switch |

## Configuration (optional)

Copy `EpubView.ini.sample` to `EpubView.ini` next to the installed `EpubView.wlx`
and edit it. Settings are re-read every time you open a book, so there is no
restart. Keys: `theme` (auto/light/dark/sepia), `fontsize`, `maxwidth`,
`lineheight`, `justify`, `toc`, `publishercss`, `showversion` — each documented
inline in the sample.

By default the reader applies its own typography rather than the book's
stylesheets, so every book is legible and honours the theme. Set
`publishercss = 1` for books whose own layout matters (comics, poetry, heavily
designed pages); the publisher's CSS is then scoped to the text so it cannot
restyle the reader's own chrome.

## Supported extensions

`.epub` — EPUB 2 and EPUB 3, including books whose chapters are declared in a
legacy encoding such as `windows-1251`.

## How it works

An `.epub` is a ZIP (OCF) container of XHTML, CSS and images. Rather than
unpacking it to a temporary directory, the plugin serves the book straight out of
the ZIP through a `WKURLSchemeHandler` on a private `x-epub://` scheme:

```
x-epub://book/<token>/__dcreader__/index.html   the generated reader shell
x-epub://book/<token>/__dcreader__/reader.js    the reader itself
x-epub://book/<token>/OEBPS/chapter1.xhtml      a file from inside the book
```

Every resource is therefore same-origin — relative hrefs, images, fonts and
`fetch()` all behave normally — while nothing is written to disk and a path
either names a ZIP entry or resolves to nothing, so there is no filesystem to
escape into. The `<token>` changes on every load, so a reused web view can never
serve a previous book's cached resource.

The native side (`EpubView.m`, `zipreader.c`) owns container I/O and the page
shell. The EPUB document model — `META-INF/container.xml` → OPF → spine →
`nav`/NCX — is parsed in `assets/reader.js`, where `DOMParser` copes with
real-world XHTML far better than hand-rolled parsing would. Chapters are appended
one at a time, so the first page is readable while the rest of the book is still
arriving.

Book content is untrusted, and is treated that way:

- every chapter passes through **DOMPurify** before it is inserted
- only `x-epub:` and `data:` URIs survive rewriting — an `http(s)` reference is
  dropped rather than fetched
- a **Content-Security-Policy** on the shell allows scripts and styles only from
  the plugin's own origin and forbids network connections outright

So a book cannot run script, phone home, or track the reader — by construction,
not by good behaviour.

`zipreader.c` reads the central directory itself and inflates with the system
zlib (macOS ships libarchive but no `archive.h` in the SDK). It handles stored
and deflated entries, ZIP64, and verifies CRC-32; oversized entries are refused.

### Escape closes the viewer

`WKWebView` swallows Esc, and Double Commander — a Lazarus/LCL app — dispatches
shortcuts through `NSApplication`'s `-sendEvent:`, not through synthetic
`-keyDown:` forwarding. The plugin moves focus off the web view and re-posts the
Escape event so LCL sees it and closes the viewer. This has to be verified in the
real Double Commander; a mock host will pass either way. See
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## Updating the bundled library

```sh
curl -L -o assets/dompurify.min.js \
  https://unpkg.com/dompurify@latest/dist/purify.min.js
```

Then rebuild and re-run the harnesses below — the sanitising assertions in
`test/test_host.m` are what tell you the new version still strips what it should.

## Uninstall

Remove the plugin entry in Configuration → Options → Plugins → WLX Plugins, then
delete `~/Library/Preferences/doublecmd/plugins/wlx/EpubView/`.

## Test harnesses (development)

Sample books are generated rather than committed, so the repo carries no binary
fixtures:

```sh
python3 test/make_sample_epub.py build/samples

# ZIP/OCF reader — headless, runs in CI
clang -O1 -Wall -Wextra -o build/zip_test test/zip_test.c zipreader.c -lz
./build/zip_test build/samples

# Full ABI + rendering + sanitising, against the real built .wlx (needs a GUI session)
clang -fobjc-arc -framework Cocoa -framework WebKit -o build/test_host test/test_host.m
./build/test_host build/EpubView.wlx build/samples

# Visual check: render a book and save a PNG
clang -fobjc-arc -framework Cocoa -framework WebKit -o build/snap_host test/snap_host.m
./build/snap_host build/EpubView.wlx build/samples/sample3.epub build/shot.png 0 1100 860
```

`test_host.m` drives the actual WLX entry points — `ListGetDetectString`,
`ListLoad`, `ListLoadNext`, `ListCloseWindow` — against the plugin as built, and
asserts on the live DOM: that the book renders, that the TOC comes out of the nav
document and the NCX, that a `windows-1251` chapter decodes, and that the hostile
chapter in the sample (inline `<script>`, an `onerror` handler, a remote image,
an `<iframe>`) reaches the page as inert text.
