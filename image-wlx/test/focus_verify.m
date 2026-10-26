/* Regression net for keyboard focus on open.
 *
 * Double Commander's TWlxModule.SetFocus is a no-op on macOS, so a viewer
 * plugin opened with F3 has no keyboard focus unless it takes it: the arrows,
 * PgUp/PgDn and the zoom keys would do nothing until the image was clicked.
 * The plugin takes focus itself — but only when no control holds it, because
 * it also runs in Quick View next to the file panel, which must keep its keys.
 *
 * Viewer: first as Double Commander actually builds it: the window's content
 * view is a scroll view, its document view — the bare form — is first
 * responder, and the plugin is added to the content view beside it. Then focus
 * on the window, on the plugin's own container, or on a hidden control (DC's
 * text viewer behind the plugin panel). After loading, the image canvas must
 * be first responder, and real PgDn / Down-arrow / Cmd+= key events must
 * scroll and zoom the image.
 *
 * Quick View: a visible file list next to the plugin panel holds focus. After
 * loading it must still hold it, and Cmd+= must not zoom the image.
 *
 * Note this is a regression net, not proof: per the charter, press PgDn and
 * Cmd+= right after F3 in a real Double Commander.
 *
 *   ./build/focus_verify <ImageView.wlx> <large image>
 */
#import <Cocoa/Cocoa.h>
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

static NSView *Find(NSView *root, NSString *cls) {
    if ([root isKindOfClass:NSClassFromString(cls)]) return root;
    for (NSView *v in root.subviews) { NSView *f = Find(v, cls); if (f) return f; }
    return nil;
}

static void After(double seconds, void (^block)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

static NSEvent *Key(NSWindow *win, unsigned short code, NSString *s, NSEventModifierFlags mods) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                       modifierFlags:mods timestamp:0
                        windowNumber:win.windowNumber context:nil
                          characters:s charactersIgnoringModifiers:s
                           isARepeat:NO keyCode:code];
}

static NSString *Fn(unichar ch) { return [NSString stringWithCharacters:&ch length:1]; }

/* Key status is the test's to decide, not the window server's. A background
 * test process cannot reliably make itself active (macOS declines activation
 * requests from an app that isn't frontmost), and without that no window of
 * ours is ever key, so the outcome would depend on what else is on screen.
 * `key` is reported as key status, and flipping it on posts the same
 * notification AppKit posts. */
@interface HostWindow : NSWindow
@property (nonatomic) BOOL key;
@end
@implementation HostWindow
- (BOOL)isKeyWindow { return self.key; }
- (void)setKey:(BOOL)key {
    BOOL was = _key;
    _key = key;
    if (key && !was)
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidBecomeKeyNotification
                                                            object:self];
}
@end

typedef enum { FocusFormDocument, FocusWindow, FocusContainer, FocusHiddenControl, QuickView } Setup;

/* Build a host window standing in for DC, load the plugin into it, and report. */
static void RunCase(Setup setup, const char *title, void (^next)(void)) {
    printf("%s:\n", title);
    HostWindow *win = [[HostWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 400)
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

    /* DC loads the plugin first and shows the viewer after; the other cases
     * cover a window that is already key (the viewer switched to plugin mode). */
    BOOL showAfterLoad = (setup == FocusFormDocument);
    if (!showAfterLoad) { [win orderFront:nil]; win.key = YES; }
    switch (setup) {
        case FocusFormDocument:  [win makeFirstResponder:document]; break;
        case FocusWindow:        [win makeFirstResponder:nil];   break;
        case FocusContainer:     [win makeFirstResponder:panel]; break;
        case FocusHiddenControl: [win makeFirstResponder:other]; break;
        case QuickView:          [win makeFirstResponder:other]; break;
    }
    NSResponder *before = win.firstResponder;

    /* No Stretch: the image opens at 100%, larger than the window. */
    HWND pw = ListLoad((__bridge HWND)panel, (char *)gFile, 0);
    if (!pw) { check(NO, "ListLoad returned a window"); next(); return; }
    NSView *canvas = Find((__bridge NSView *)pw, @"IVCanvas");
    NSScrollView *scroll = (NSScrollView *)Find((__bridge NSView *)pw, @"IVScrollView");
    if (showAfterLoad) {
        check(win.firstResponder == before, "focus is left alone until the viewer is shown");
        [win orderFront:nil];
        win.key = YES;
    }

    /* Let the image decode and the window's key status settle. */
    After(0.8, ^{
        void (^done)(void) = ^{
            ListCloseWindow(pw);
            win.key = NO;
            [win orderOut:nil];
            next();
        };
        CGFloat mag0 = scroll.magnification;
        if (setup == QuickView) {
            check(win.firstResponder == before, "the file list keeps keyboard focus");
            check(win.firstResponder != canvas, "the image does not take it");
            [NSApp postEvent:Key(win, 24, @"=", NSEventModifierFlagCommand) atStart:NO];
            After(0.2, ^{
                check(scroll.magnification == mag0, "Cmd+= does not zoom the image");
                done();
            });
            return;
        }
        check(win.firstResponder == canvas, "the image has keyboard focus on open");
        CGFloat y0 = scroll.contentView.bounds.origin.y;
        /* Scroll keys go to the window: NSApp routes key events to the real key
         * window, and no window of a background test process is ever key. Cmd+=
         * goes through NSApp, where the plugin's event monitor sees it. */
        [win sendEvent:Key(win, 125 /* kVK_DownArrow */, Fn(NSDownArrowFunctionKey),
                           NSEventModifierFlagFunction | NSEventModifierFlagNumericPad)];
        After(0.3, ^{
            CGFloat y1 = scroll.contentView.bounds.origin.y;
            check(y1 > y0, "Down arrow scrolls the image");
            [win sendEvent:Key(win, 121 /* kVK_PageDown */, Fn(NSPageDownFunctionKey),
                               NSEventModifierFlagFunction)];
            After(0.3, ^{
                CGFloat y2 = scroll.contentView.bounds.origin.y;
                check(y2 > y1 + 100, "PgDn scrolls the image by a page");
                [NSApp postEvent:Key(win, 24, @"=", NSEventModifierFlagCommand) atStart:NO];
                After(0.2, ^{
                    check(scroll.magnification > mag0, "Cmd+= zooms in");
                    if (gFailures) printf("    y %.0f -> %.0f -> %.0f, zoom %.2f -> %.2f\n",
                                          y0, y1, y2, mag0, scroll.magnification);
                    done();
                });
            });
        });
    });
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: focus_verify <ImageView.wlx> <large image>\n"); return 2; }
    gFile = argv[2];

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

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
