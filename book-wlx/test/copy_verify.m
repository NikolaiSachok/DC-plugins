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

static int gFailures = 0;

static void check(BOOL cond, const char *what) {
    printf("  %-52s %s\n", what, cond ? "ok" : "FAILED");
    if (!cond) gFailures++;
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

    /* Be a good citizen: this drives the real system pasteboard, so put back
     * whatever the user had on it when we are done. */
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *saved = [pb stringForType:NSPasteboardTypeString];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        printf("ListSendCommand:\n");

        /* A command we do not handle must report ERROR so DC can fall back. */
        check(ListSendCommand(pw, lc_setpercent, 50) == LISTPLUGIN_ERROR,
              "unhandled command returns LISTPLUGIN_ERROR");
        check(ListSendCommand(NULL, lc_copy, 0) == LISTPLUGIN_ERROR,
              "NULL window returns LISTPLUGIN_ERROR");

        /* Sentinel so a no-op copy cannot masquerade as a pass. */
        [pb clearContents];
        [pb setString:@"SENTINEL_NOT_COPIED" forType:NSPasteboardTypeString];

        check(ListSendCommand(pw, lc_selectall, 0) == LISTPLUGIN_OK,
              "lc_selectall returns LISTPLUGIN_OK");
        check(ListSendCommand(pw, lc_copy, 0) == LISTPLUGIN_OK,
              "lc_copy returns LISTPLUGIN_OK");

        /* WebKit completes the copy on its own turn of the run loop. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            NSString *got = [pb stringForType:NSPasteboardTypeString] ?: @"";
            check(![got isEqualToString:@"SENTINEL_NOT_COPIED"],
                  "clipboard actually changed");
            check([got containsString:@"The Harbour"],
                  "clipboard holds the rendered book text");
            if (gFailures) printf("  clipboard was: %.120s\n", got.UTF8String);

            if (saved) { [pb clearContents]; [pb setString:saved forType:NSPasteboardTypeString]; }
            printf(gFailures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", gFailures);

            [app stop:nil];
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                context:nil subtype:0 data1:0 data2:0] atStart:YES];
        });
    });

    [app run];
    return gFailures ? 1 : 0;
}}
