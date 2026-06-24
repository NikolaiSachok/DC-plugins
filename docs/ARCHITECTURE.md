# Architecture (overview)

This is a concise, offline-readable summary. The full teaching write-up — with
diagrams, failure modes, and "when not to" notes — lives in the
[project wiki](../../wiki).

## The plugin ABI

Double Commander inherits Total Commander's plugin system. A plugin is a native
shared library exporting a fixed table of C functions; DC `dlopen`s it and calls
those by name. There are four families:

| Type | Ext | Purpose |
|------|-----|---------|
| WLX | `.wlx` | **Lister** — custom viewers (what `markdown-wlx` is) |
| WCX | `.wcx` | Packers (archive formats) |
| WDX | `.wdx` | Content fields (columns, search) |
| WFX | `.wfx` | Virtual file systems |

A WLX plugin exports: `ListLoad`, `ListLoadNext`, `ListCloseWindow`,
`ListGetDetectString`, `ListSetDefaultParams`.

## WLX on macOS

The ABI was designed around Windows `HWND` window handles. On macOS, Double
Commander maps those handles to **`NSView*`**:

- `ListLoad(parentNSView, path, flags)` — build a view that displays `path`, add it
  under the parent, and return it. DC sizes it to the viewer.
- `ListLoadNext(...)` — reuse the same view for the next file (viewer navigation).
- `ListCloseWindow(view)` — tear the view down.
- `ListGetDetectString(buf, len)` — a rule string (e.g. `EXT="MD"|EXT="MARKDOWN"`)
  telling DC which files this plugin claims.

Because an Objective-C object crosses the C ABI boundary and must outlive the
function call, ownership is transferred explicitly with `CFBridgingRetain` on the
way out and `CFBridgingRelease` in `ListCloseWindow`.

## `markdown-wlx` rendering pipeline

1. `ListLoad` builds an `NSView` containing a `WKWebView`.
2. It reads the Markdown file, base64-embeds it in a generated HTML document, and
   references vendored assets (marked.js, highlight.js, GitHub CSS) by `file://`
   URL — **never inlined**, because a minified library can contain a literal
   `</script>` that would truncate an inline `<script>` tag.
3. The page is loaded via `loadFileURL:allowingReadAccessToURL:` with a `<base>`
   set to the document's directory, so relative images resolve.
4. marked.js renders Markdown → HTML client-side; highlight.js colors code blocks;
   `prefers-color-scheme` drives light/dark live.

## Case study: WKWebView swallows Escape

In Double Commander the viewer closes on Escape. With the plugin active it didn't —
pressing `1` (switch to Text) first, then Escape, worked. That pointed at **keyboard
focus**: a focused `WKWebView` consumes Escape instead of letting it travel up the
responder chain to DC's viewer window.

Rather than guess, a focused probe confirmed two things: a `keyDown:` override on a
`WKWebView` subclass *is* invoked, and forwarding the event to `nextResponder`
reaches the parent view. The fix is a few lines — forward **only** Escape up the
chain, leave every other key (scrolling, find, selection) to normal web handling:

```objc
@implementation MDWebView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53 /* Escape */) { [self.nextResponder keyDown:event]; return; }
    [super keyDown:event];
}
@end
```

This is the kind of root-cause fix the collection favors over intercepting and
re-dispatching events, which would be both more code and more fragile.

## Safety: the leak gate

Anything public passes a generic [`leak-guard`](../scripts/leak-guard.sh) check
(secrets, private absolute paths, OS cruft) in CI and as a pre-commit hook. It is
intentionally generic — a checker that enumerates sensitive business terms would
itself leak them.
