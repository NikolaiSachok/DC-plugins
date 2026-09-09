/* Regression net for the ListSendCommand export.
 *
 * Double Commander binds Cmd+C / Cmd+A on its own Viewer form; when a plugin owns
 * the window it does NOT deliver those keys to our web view, it calls
 * ListSendCommand(lc_copy / lc_selectall) instead (fviewer.pas). A plugin that
 * does not export the entry point makes both keys silently dead.
 *
 * This loads the real .wlx into a parent view standing in for DC's viewer, drives
 * the actual ABI the way DC does, and asserts the system clipboard really changed.
 *
 * Note this is a regression net, not proof: per the charter, host key dispatch is
 * confirmed by pressing Cmd+C in a real Double Commander. */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef int  (*ListSendCommand_t)(HWND, int, int);

#define LISTPLUGIN_OK    0
#define LISTPLUGIN_ERROR 1
#define lc_copy          1
#define lc_selectall     3
#define lc_setpercent    4

/* Text that must be on screen before copying means anything. */
#define MARKER    @"smoke test"
#define READY_MAX 60          /* × 250 ms = 15 s ceiling */

static int gFailures = 0;

static void check(BOOL cond, const char *what) {
    printf("  %-52s %s\n", what, cond ? "ok" : "FAILED");
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

/* Wait for the document to actually render rather than sleeping a fixed amount.
 * A fixed delay is flaky: rendering a book means unzipping, parsing and
 * sanitising it, which is slower on a loaded machine or right after another
 * harness has run. */
static void WhenRendered(WKWebView *web, int attemptsLeft, void (^then)(BOOL)) {
    if (attemptsLeft <= 0) { then(NO); return; }
    [web evaluateJavaScript:@"document.body ? document.body.innerText : ''"
          completionHandler:^(id result, NSError *err) {
        (void)err;
        NSString *text = [result isKindOfClass:[NSString class]] ? result : @"";
        if ([text containsString:MARKER]) { then(YES); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{ WhenRendered(web, attemptsLeft - 1, then); });
    }];
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: copy_verify <plugin.wlx> <file.md>\n"); return 2; }

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
    ListLoad_t ListLoad = (ListLoad_t)dlsym(h, "ListLoad");
    ListSendCommand_t ListSendCommand = (ListSendCommand_t)dlsym(h, "ListSendCommand");
    if (!ListLoad) { fprintf(stderr, "missing ListLoad\n"); return 2; }
    if (!ListSendCommand) {
        printf("RESULT: FAIL (ListSendCommand not exported — Cmd+C/Cmd+A are dead in DC)\n");
        return 1;
    }

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView *dc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    win.contentView = dc;

    HWND pw = ListLoad((__bridge HWND)dc, argv[2], 0);
    if (!pw) { fprintf(stderr, "ListLoad returned NULL\n"); return 2; }
    [win makeKeyAndOrderFront:nil];

    WKWebView *web = FindWebView((__bridge NSView *)pw);
    if (!web) { fprintf(stderr, "no WKWebView in the plugin view\n"); return 2; }

    /* Be a good citizen: this drives the real system pasteboard, so put back
     * whatever text the user had on it when we are done. Non-text contents
     * (an image, say) cannot be restored this way and are left alone. */
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *saved = [pb stringForType:NSPasteboardTypeString];

    void (^finish)(void) = ^{
        if (saved) { [pb clearContents]; [pb setString:saved forType:NSPasteboardTypeString]; }
        printf(gFailures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", gFailures);
        [app stop:nil];
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
            location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
            context:nil subtype:0 data1:0 data2:0] atStart:YES];
    };

    WhenRendered(web, READY_MAX, ^(BOOL rendered) {
        printf("ListSendCommand:\n");
        check(rendered, "document rendered before copying");
        if (!rendered) { finish(); return; }

        /* A command we do not handle must report ERROR so DC can fall back. */
        check(ListSendCommand(pw, lc_setpercent, 50) == LISTPLUGIN_ERROR,
              "unhandled command returns LISTPLUGIN_ERROR");
        check(ListSendCommand(NULL, lc_copy, 0) == LISTPLUGIN_ERROR,
              "NULL window returns LISTPLUGIN_ERROR");

        /* Sentinel so a no-op copy cannot masquerade as a pass. */
        [pb clearContents];
        [pb setString:@"SENTINEL_NOT_COPIED" forType:NSPasteboardTypeString];
        NSInteger before = pb.changeCount;

        check(ListSendCommand(pw, lc_selectall, 0) == LISTPLUGIN_OK,
              "lc_selectall returns LISTPLUGIN_OK");
        check(ListSendCommand(pw, lc_copy, 0) == LISTPLUGIN_OK,
              "lc_copy returns LISTPLUGIN_OK");

        /* WebKit completes the copy on a later turn of the run loop; poll the
         * pasteboard change count rather than guessing how long that takes. */
        __block int waits = 20; /* × 100 ms */
        __block void (^poll)(void);
        poll = ^{
            if (pb.changeCount == before && waits-- > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), poll);
                return;
            }
            NSString *got = [pb stringForType:NSPasteboardTypeString] ?: @"";
            check(![got isEqualToString:@"SENTINEL_NOT_COPIED"], "clipboard actually changed");
            check([got containsString:MARKER], "clipboard holds the rendered document text");
            if (gFailures) printf("  clipboard was: %.120s\n", got.UTF8String);
            poll = nil;
            finish();
        };
        poll();
    });

    [app run];
    return gFailures ? 1 : 0;
}}
