# MediaInfo — Double Commander WDX content plugin (macOS)

A **content (WDX) plugin** that surfaces per-file media metadata as fields you can
show in Double Commander's **custom columns** and **tooltips** — so the resolution
of an image, the length of a clip, or a PDF's page count is visible **right in the
file listing**, without opening a preview or a second app.

It fills a real gap: DC's bundled `MacPreview` (QuickLook) previews images but never
shows their pixel dimensions, and DC ships no image/video content plugin on macOS.

Everything is read with **native system frameworks — no third-party libraries and no
network**:

| File type | Fields | Backend |
|-----------|--------|---------|
| **Images** (jpg, png, gif, tiff, bmp, webp, heic, raw, …) | Dimensions, Width, Height, Megapixels, DPI, Bit depth | **ImageIO** (header only — never decodes pixels) |
| **Audio** (mp3, m4a, aac, wav, aiff, caf) | Duration, Bitrate, Sample rate, Channels, Audio codec | **AVFoundation** |
| **Video** (mp4, mov, m4v, 3gp) | Dimensions, Duration, Frame rate, Bitrate, Video/Audio codec | **AVFoundation** |
| **Video** (avi) | Dimensions, Duration, Frame rate | self-contained **RIFF `avih`** reader (AVFoundation can't open AVI on macOS) |
| **PDF** | Page count | **CoreGraphics (CGPDF)** |

## The `Summary` field

The headline field is **`Summary`** — the plugin picks the single most useful string
per file type, so **one column** covers every kind of file (and is simply blank for
files it doesn't apply to):

| File | `Summary` shows |
|------|-----------------|
| image | `3024 × 4032` |
| video | `1920 × 1080 · 12:30` |
| audio | `3:45` |
| pdf | `14 pages` |
| anything else | *(blank)* |

Prefer dedicated columns? Every field is also exposed individually — add a sortable
`Duration` column, a `Dimensions` column, etc.

## Requirements

- macOS 11+ on Apple Silicon **or** Intel — the build is a universal binary
- Xcode command-line tools (`clang`) to build
- Double Commander (ad-hoc signed, no hardened runtime — loads third-party `.wdx`)

## Build

```sh
./build.sh
```

Produces a universal `build/MediaInfo.wdx` (arm64 + x86_64), ad-hoc signed.

## Install

Quit Double Commander first (it rewrites its config on exit), then:

```sh
./install.sh
```

This copies the plugin to
`~/Library/Preferences/doublecmd/plugins/wdx/MediaInfo/` (survives DC app updates)
and registers it in `doublecmd.xml`. A timestamped `doublecmd.xml.bak-*` backup is
made automatically. Re-running is idempotent.

### Add a column

In a file panel: **right-click the column header → Configure / Columns…**, add a
column, set its field to **`MediaInfo` → `Summary`** (or `Dimensions`, `Duration`,
`Page count`, …). You can mix fields and literal text in one column template, e.g.
`[=MediaInfo.Dimensions]`.

The same fields are available in **tooltips** (Options → Tooltips → Fields).

## Fields

`Summary`, `Dimensions`, `Width`, `Height`, `Megapixels`, `DPI`, `Bit depth`,
`Duration`, `Duration (s)`, `Frame rate`, `Bitrate`, `Sample rate`, `Channels`,
`Video codec`, `Audio codec`, `Page count`, `Plugin version`.

`Duration (s)` is numeric (sortable); `Duration` is the formatted `m:ss` / `h:mm:ss`
string. **`Plugin version`** returns the build's version — add it as a column to see
which build is loaded (it's also embedded in the binary:
`strings MediaInfo.wdx | grep MediaInfo`).

## How it works

- A `.wdx` is a Mach-O dylib exporting the Total Commander **Content plugin** C ABI
  (`ContentGetSupportedField`, `ContentGetValue`, `ContentGetDetectString`,
  `ContentSetDefaultParams`, …). DC asks the plugin which fields it provides, then
  calls `ContentGetValue(path, fieldIndex, …)` per file/field.
- A field returns `ft_fieldempty` for files it doesn't apply to, so one column serves
  every type without waste. The plugin routes by extension to the right backend and
  caches parsed values per `path + mtime` (thread-safe `NSCache`).
- **Non-blocking:** AVFoundation parsing is the only slow path. When DC requests a
  value in the foreground with `CONTENT_DELAYIFSLOW`, the plugin returns `ft_delayed`
  and lets DC re-query it on a background thread — the panel never stalls while
  scrolling. ImageIO, CGPDF, and the AVI reader are fast and answer immediately.
- **Crash-safe under DC's runtime:** Double Commander is a Lazarus/FPC app that
  *enables* floating-point exception traps. FP math inside Apple's media frameworks
  (notably ImageIO's RAW / EXIF MakerNote path) is harmless under the default masked
  environment but raises a fatal trap under FPC's — surfacing as an "Access
  violation" dialog. The plugin masks FP exceptions around every system-framework
  call and restores the host's environment before returning, so browsing folders of
  camera JPEGs is safe. (This is the same class of host-dependent gotcha as the
  Escape-key fix in `markdown-wlx` — verified against the real host, not a mock.)

## Supported extensions

Only formats a system framework can actually read (so a column is never silently
blank for a "supported" type):

```
images: jpg jpeg png gif tiff tif bmp webp heic heif avif ico icns psd jp2
        dng cr2 cr3 nef arw orf rw2 raf sr2 pef
audio:  mp3 m4a aac wav aiff aif aifc caf
video:  mp4 mov m4v 3gp 3g2 avi
pdf:    pdf
```

`.avi` is read by a built-in RIFF parser. Other containers neither AVFoundation nor
that parser handle (e.g. `.mkv`, `.webm`, `.flv`) are intentionally left out rather
than shown as empty.

## Uninstall

Remove the `MediaInfo` entry from
`~/Library/Preferences/doublecmd/doublecmd.xml` (while DC is quit) and delete
`~/Library/Preferences/doublecmd/plugins/wdx/MediaInfo/`.

## Test harness (development)

The harness loads the **real built `.wdx`** via `dlopen` and drives the actual ABI
against files it synthesizes with known properties (a 320×200 PNG, a 1-page PDF, a
1.0s 8 kHz mono WAV), and exercises the `CONTENT_DELAYIFSLOW` deferral protocol.

```sh
clang -arch arm64 -fobjc-arc -framework Foundation -framework CoreGraphics \
  -framework ImageIO -o build/test_host test/test_host.m
./build/test_host build/MediaInfo.wdx      # -> RESULT: PASS
```
