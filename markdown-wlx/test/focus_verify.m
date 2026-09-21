/* Regression net for keyboard focus on open.
 *
 * Double Commander's TWlxModule.SetFocus is a no-op on macOS, so when the F3
 * viewer opened nothing gave the web view keyboard focus: PgUp/PgDn and the
 * arrows did nothing until the page was clicked. The plugin now takes focus
 * itself — but only when no control holds it, because the same plugin
 * also runs in Quick View next to the file panel, which must keep its keys.
 *
 * Viewer: first as Double Commander actually builds it (seen in its logs): the
 * window's content view is a scroll view, its document view — the bare form —
 * is first responder, and the plugin is added to the content view beside it.
 * Then focus on the window, on the plugin's own container, or on a hidden
 * control (DC's text viewer behind the plugin panel). After loading, the
 * web view must be first responder and real PgDn / Down-arrow key events sent
 * through the window must scroll the page.
 *
 * Quick View: a visible file list next to the plugin panel holds focus. After
 * loading it must still hold it.
 *
 * Note this is a regression net, not proof: per the charter, press PgDn right
 * after F3 in a real Double Commander. */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef void (*ListCloseWindow_t)(HWND);

static int gFailures = 0;
static ListLoad_t ListLoad;
static ListCloseWindow_t ListCloseWindow;
static const char *gFile;

static void check(BOOL cond, const char *what) {
    printf("  %-60s %s\n", what, cond ? "ok" : "FAILED");
    if (!cond) gFailures++;
}

static WKWebView *FindWebView(NSView *root) {
    if ([root isKindOfClass:[WKWebView class]]) return (WKWebView *)root;
    for (NSView *v in root.subviews) {
        WKWebView *found = FindWebView(v);
        if (found) return found;
    }
    return nil;
}

static void After(double seconds, void (^block)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

static NSEvent *Key(NSWindow *win, unsigned short code, unichar ch) {
    NSString *s = [NSString stringWithCharacters:&ch length:1];
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                       modifierFlags:NSEventModifierFlagFunction timestamp:0
                        windowNumber:win.windowNumber context:nil
                          characters:s charactersIgnoringModifiers:s
                           isARepeat:NO keyCode:code];
}

static void ScrollY(WKWebView *web, void (^then)(double)) {
    [web evaluateJavaScript:@"window.scrollY" completionHandler:^(id v, NSError *e) {
        (void)e; then([v doubleValue]);
    }];
}

typedef enum { FocusFormDocument, FocusWindow, FocusContainer, FocusHiddenControl, QuickView } Setup;

/* Build a host window standing in for DC, load the plugin into it, and report. */
static void RunCase(Setup setup, const char *title, void (^next)(void)) {
    printf("%s:\n", title);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 400)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    win.releasedWhenClosed = NO;
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 400)];
    win.contentView = form;
    NSView *document = nil;
    if (setup == FocusFormDocument) {
        /* LCL: TCocoaWindowContent (a scroll view) -> NSClipView ->
         * TCocoaWindowContentDocument, which holds focus; ListLoad's parent is
         * the content view itself. */
        NSScrollView *content = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 800, 400)];
        document = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 400)];
        content.documentView = document;
        win.contentView = content;
        form = content;
    }

    /* The panel DC hands to ListLoad. */
    NSView *panel = setup == FocusFormDocument ? form : [[NSView alloc] initWithFrame:
        setup == QuickView ? NSMakeRect(400, 0, 400, 400) : NSMakeRect(0, 0, 800, 400)];
    if (panel != form) [form addSubview:panel];
    /* A focusable control DC owns: the text viewer (hidden behind the plugin)
     * in the viewer, the file list (visible, beside it) in Quick View. */
    NSTextView *other = [[NSTextView alloc] initWithFrame:
        setup == QuickView ? NSMakeRect(0, 0, 400, 400) : NSMakeRect(0, 0, 800, 400)];
    [form addSubview:other];
    other.hidden = (setup != QuickView);

    [win makeKeyAndOrderFront:nil];
    switch (setup) {
        case FocusFormDocument:  [win makeFirstResponder:document]; break;
        case FocusWindow:        [win makeFirstResponder:nil];   break;
        case FocusContainer:     [win makeFirstResponder:panel]; break;
        case FocusHiddenControl: [win makeFirstResponder:other]; break;
        case QuickView:          [win makeFirstResponder:other]; break;
    }
    NSResponder *before = win.firstResponder;

    HWND pw = ListLoad((__bridge HWND)panel, (char *)gFile, 0);
    if (!pw) { check(NO, "ListLoad returned a window"); next(); return; }
    WKWebView *web = FindWebView((__bridge NSView *)pw);

    /* Let the page render and the window's key status settle. */
    After(1.5, ^{
        void (^done)(void) = ^{
            ListCloseWindow(pw);
            [win orderOut:nil];
            next();
        };
        if (setup == QuickView) {
            check(win.firstResponder == before, "the file list keeps keyboard focus");
            check(win.firstResponder != web, "the web view does not take it");
            done();
            return;
        }
        check(win.firstResponder == web, "the web view has keyboard focus on open");
        ScrollY(web, ^(double y0) {
            [win sendEvent:Key(win, 121 /* kVK_PageDown */, NSPageDownFunctionKey)];
            After(0.6, ^{
                ScrollY(web, ^(double y1) {
                    check(y1 > y0, "PgDn scrolls the page");
                    [win sendEvent:Key(win, 125 /* kVK_DownArrow */, NSDownArrowFunctionKey)];
                    After(0.6, ^{
                        ScrollY(web, ^(double y2) {
                            check(y2 > y1, "Down arrow scrolls the page");
                            if (gFailures) printf("    scrollY %.0f -> %.0f -> %.0f\n", y0, y1, y2);
                            done();
                        });
                    });
                });
            });
        });
    });
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: focus_verify <plugin.wlx> <long.md>\n"); return 2; }
    gFile = argv[2];

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [app activateIgnoringOtherApps:YES];

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
    ListLoad = (ListLoad_t)dlsym(h, "ListLoad");
    ListCloseWindow = (ListCloseWindow_t)dlsym(h, "ListCloseWindow");
    if (!ListLoad || !ListCloseWindow) { fprintf(stderr, "missing exports\n"); return 2; }

    void (^finish)(void) = ^{
        printf(gFailures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", gFailures);
        [app stop:nil];
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
            location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
            context:nil subtype:0 data1:0 data2:0] atStart:YES];
    };

    RunCase(FocusFormDocument, "Viewer as DC builds it, focus on the form", ^{
    RunCase(FocusWindow, "Viewer, focus on the window", ^{
      RunCase(FocusContainer, "Viewer, focus on the plugin's container", ^{
        RunCase(FocusHiddenControl, "Viewer, focus on a hidden text viewer", ^{
          RunCase(QuickView, "Quick View, focus on the visible file list", finish);
        });
      });
    });
    });

    [app run];
    return gFailures ? 1 : 0;
}}
