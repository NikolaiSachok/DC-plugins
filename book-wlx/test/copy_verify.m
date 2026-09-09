/* Regression net for the ListSendCommand export.
 *
 * Double Commander binds Cmd+C / Cmd+A on its own Viewer form; when a plugin owns
 * the window it does NOT deliver those keys to our web view, it calls
 * ListSendCommand(lc_copy / lc_selectall) instead (fviewer.pas). A plugin that
 * does not export the entry point makes both keys silently dead.
 *
 * This loads the real .wlx into a parent view standing in for DC's viewer, drives
 * the actual ABI the way DC does, and asserts the system clipboard really changed.
 * It covers both flows: Cmd+A then Cmd+C, and the one actually reported in #25 —
 * a selection made with the mouse, then Cmd+C on its own.
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
#define MARKER      @"The Harbour"
/* Page chrome that must never reach the clipboard: the toolbar, contents sidebar and version badge sit outside
 * the content element and carries user-select:none, which a programmatic
 * -[WKWebView selectAll:] would ignore. */
#define CHROME      @"BookView v"
#define CONTENT_ID  "book"

static int gFailures = 0;

static void check(BOOL cond, const char *what) {
    printf("  %-56s %s\n", what, cond ? "ok" : "FAILED");
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

/* Poll a JS predicate until it is true. Used instead of a fixed sleep: rendering
 * means unzipping, parsing and sanitising, which is slower on a loaded machine or
 * straight after another harness has run. */
static void PollJS(WKWebView *web, NSString *js, int attemptsLeft, void (^then)(BOOL)) {
    if (attemptsLeft <= 0) { then(NO); return; }
    [web evaluateJavaScript:js completionHandler:^(id result, NSError *err) {
        (void)err;
        if ([result respondsToSelector:@selector(boolValue)] && [result boolValue]) { then(YES); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{ PollJS(web, js, attemptsLeft - 1, then); });
    }];
}

/* Wait for the pasteboard to change: -copy: is async IPC to the WebContent
 * process, so there is nothing to synchronously wait on. */
static void WhenPasteboardChanges(NSPasteboard *pb, NSInteger before,
                                  int attemptsLeft, void (^then)(void)) {
    if (pb.changeCount != before || attemptsLeft <= 0) { then(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        WhenPasteboardChanges(pb, before, attemptsLeft - 1, then);
    });
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: copy_verify <plugin.wlx> <book.epub>\n"); return 2; }

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

    /* Issue lc_copy and hand the resulting clipboard text to `then`. */
    void (^copyThen)(void (^)(NSString *)) = ^(void (^then)(NSString *)) {
        [pb clearContents];
        [pb setString:@"SENTINEL_NOT_COPIED" forType:NSPasteboardTypeString];
        NSInteger before = pb.changeCount;
        check(ListSendCommand(pw, lc_copy, 0) == LISTPLUGIN_OK, "lc_copy returns LISTPLUGIN_OK");
        WhenPasteboardChanges(pb, before, 20, ^{
            then([pb stringForType:NSPasteboardTypeString] ?: @"");
        });
    };

    NSString *rendered = @"(function(){var c=document.getElementById('" @CONTENT_ID
                         @"');return !!c&&c.children.length>0;})()";
    NSString *hasSelection = @"(function(){var s=window.getSelection();"
                             @"return !!s&&s.toString().trim().length>0;})()";
    /* Stand in for a mouse drag: select one element inside the content. */
    NSString *selectOne = @"(function(){var c=document.getElementById('" @CONTENT_ID @"');"
                          @"var p=c&&c.querySelector('p');if(!p)return false;"
                          @"var s=window.getSelection();s.removeAllRanges();"
                          @"s.selectAllChildren(p);return true;})()";

    PollJS(web, rendered, 60, ^(BOOL ok) {
        printf("ListSendCommand:\n");
        check(ok, "document rendered before copying");
        if (!ok) { finish(); return; }

        /* A command we do not handle must report ERROR so DC can fall back. */
        check(ListSendCommand(pw, lc_setpercent, 50) == LISTPLUGIN_ERROR,
              "unhandled command returns LISTPLUGIN_ERROR");
        check(ListSendCommand(NULL, lc_copy, 0) == LISTPLUGIN_ERROR,
              "NULL window returns LISTPLUGIN_ERROR");

        /* Flow 1 — Cmd+A then Cmd+C. */
        check(ListSendCommand(pw, lc_selectall, 0) == LISTPLUGIN_OK,
              "lc_selectall returns LISTPLUGIN_OK");
        PollJS(web, hasSelection, 40, ^(BOOL selected) {
            check(selected, "lc_selectall actually selects the document");
            copyThen(^(NSString *all) {
                check(![all isEqualToString:@"SENTINEL_NOT_COPIED"], "clipboard actually changed");
                check([all containsString:MARKER], "clipboard holds the rendered book text");
                check(![all containsString:CHROME], "version badge is NOT copied");
                check(![all containsString:@"Contents"], "contents sidebar is NOT copied");
                if (gFailures) printf("  clipboard was: %.200s\n", all.UTF8String);

                /* Flow 2 — the bug as reported in #25: select with the mouse,
                 * then press Cmd+C on its own, with no preceding Select All. */
                PollJS(web, selectOne, 20, ^(BOOL one) {
                    check(one, "a selection can be made without lc_selectall");
                    copyThen(^(NSString *part) {
                        check(part.length > 0 && ![part isEqualToString:@"SENTINEL_NOT_COPIED"],
                              "Cmd+C alone copies an existing selection");
                        check(part.length < all.length,
                              "it copies only the selection, not the document");
                        if (gFailures) printf("  partial was: %.200s\n", part.UTF8String);
                        finish();
                    });
                });
            });
        });
    });

    [app run];
    return gFailures ? 1 : 0;
}}
