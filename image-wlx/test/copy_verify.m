/* Regression net for the ListSendCommand export.
 *
 * Double Commander binds Cmd+C on its own Viewer form; when a plugin owns the
 * window it does not deliver the key to the plugin's view, it calls
 * ListSendCommand(lc_copy) instead (fviewer.pas). A plugin that does not
 * export the entry point leaves Cmd+C silently dead.
 *
 * This loads the real .wlx into a parent view standing in for DC's viewer,
 * drives the ABI the way DC does, and checks what lands on the system
 * clipboard: the rendered image for any app, plus the original where that is
 * what a paste should get (SVG source, animation, camera format, exact PNG).
 * The user's clipboard is saved first and put back after.
 *
 * Note this is a regression net, not proof: per the charter, host key dispatch
 * is confirmed by pressing Cmd+C in a real Double Commander.
 *
 *   ./build/copy_verify <ImageView.wlx> <samples-dir>
 */
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef void (*ListCloseWindow_t)(HWND);
typedef int  (*ListSendCommand_t)(HWND, int, int);

#define LISTPLUGIN_OK    0
#define LISTPLUGIN_ERROR 1
#define lc_copy          1
#define lc_selectall     3

static int gFailures = 0;

static void check(BOOL cond, NSString *what) {
    printf("  %-62s %s\n", what.UTF8String, cond ? "ok" : "FAILED");
    if (!cond) gFailures++;
}

static NSSize PixelSize(NSData *data) {
    NSBitmapImageRep *rep = data ? [NSBitmapImageRep imageRepWithData:data] : nil;
    return rep ? NSMakeSize(rep.pixelsWide, rep.pixelsHigh) : NSZeroSize;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: copy_verify <ImageView.wlx> <samples-dir>\n"); return 2; }
    NSString *dir = @(argv[2]);

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
    ListLoad_t ListLoad = (ListLoad_t)dlsym(h, "ListLoad");
    ListCloseWindow_t ListCloseWindow = (ListCloseWindow_t)dlsym(h, "ListCloseWindow");
    ListSendCommand_t ListSendCommand = (ListSendCommand_t)dlsym(h, "ListSendCommand");
    if (!ListLoad || !ListCloseWindow || !ListSendCommand) { fprintf(stderr, "missing exports\n"); return 2; }

    /* Save the user's clipboard. Items are copied type by type; promised data
     * that cannot be read now is left out. */
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSMutableArray<NSPasteboardItem *> *saved = [NSMutableArray array];
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        NSPasteboardItem *copy = [[NSPasteboardItem alloc] init];
        for (NSString *type in item.types) {
            NSData *d = [item dataForType:type];
            if (d) [copy setData:d forType:type];
        }
        [saved addObject:copy];
    }

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    win.releasedWhenClosed = NO;
    [win orderFront:nil];

    HWND (^load)(NSString *) = ^HWND(NSString *name) {
        HWND pw = ListLoad((__bridge HWND)win.contentView,
                           (char *)[dir stringByAppendingPathComponent:name].fileSystemRepresentation, 4 | 128);
        /* Let the background decode finish. */
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        return pw;
    };
    NSData *(^file)(NSString *) = ^NSData *(NSString *name) {
        return [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
    };

    struct { const char *name; const char *originalType; double w, h; } cases[] = {
        { "photo.jpg",   "public.jpeg",        1600, 1000 },
        { "rotated.jpg", "public.jpeg",         200,  400 },   /* the paste is upright */
        { "anim.gif",    "com.compuserve.gif",  120,   80 },
        { "wide.png",    "public.png",        20000,  400 },   /* full size, past the display cap */
        { "photo.heic",  "public.heic",        1600, 1000 },
        { "photo.bmp",   NULL,                 1600, 1000 },
        { "icon.ico",    NULL,                   64,   64 },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        NSString *name = @(cases[i].name);
        printf("%s:\n", cases[i].name);
        HWND pw = load(name);
        if (!pw) { check(NO, @"ListLoad returned a window"); continue; }
        NSInteger before = pb.changeCount;
        int rc = ListSendCommand(pw, lc_copy, 0);
        check(rc == LISTPLUGIN_OK && pb.changeCount != before, @"lc_copy puts the image on the clipboard");
        NSData *png = [pb dataForType:NSPasteboardTypePNG];
        NSSize s = PixelSize(png);
        check(s.width == cases[i].w && s.height == cases[i].h,
              [NSString stringWithFormat:@"PNG is %.0f x %.0f (got %.0f x %.0f)", cases[i].w, cases[i].h, s.width, s.height]);
        check([pb dataForType:NSPasteboardTypeTIFF] != nil, @"TIFF for apps that only take TIFF");
        if (cases[i].originalType) {
            NSString *type = @(cases[i].originalType);
            check([[pb dataForType:type] isEqualToData:file(name)],
                  [NSString stringWithFormat:@"%@ is the original file, byte for byte", type]);
        }
        ListCloseWindow(pw);
    }

    for (NSString *name in @[ @"edge.svg", @"edge.svgz" ]) {
        printf("%s:\n", name.UTF8String);
        HWND pw = load(name);
        int rc = ListSendCommand(pw, lc_copy, 0);
        NSString *svg = [[NSString alloc] initWithData:[pb dataForType:@"public.svg-image"]
                                              encoding:NSUTF8StringEncoding];
        NSString *source = [[NSString alloc] initWithData:file(@"edge.svg") encoding:NSUTF8StringEncoding];
        check(rc == LISTPLUGIN_OK && [svg isEqualToString:source], @"the SVG source (inflated for .svgz)");
        NSSize s = PixelSize([pb dataForType:NSPasteboardTypePNG]);
        check(s.width >= 80 && s.height >= 40,
              [NSString stringWithFormat:@"PNG rendered at 2x or more (%.0f x %.0f px)", s.width, s.height]);
        ListCloseWindow(pw);
    }

    printf("huge.svg (20000 x 20000 pt):\n");
    {
        HWND pw = load(@"huge.svg");
        NSDate *t0 = [NSDate date];
        int rc = ListSendCommand(pw, lc_copy, 0);
        NSTimeInterval took = -t0.timeIntervalSinceNow;
        NSSize s = PixelSize([pb dataForType:NSPasteboardTypePNG]);
        check(rc == LISTPLUGIN_OK && s.width <= 16384 && s.width * s.height <= 64.0 * 1024 * 1024 && s.width > 0,
              [NSString stringWithFormat:@"rasterized within the display caps (%.0f x %.0f px, %.1f s)",
                  s.width, s.height, took]);
        ListCloseWindow(pw);
    }

    printf("Select All:\n");
    HWND pw = load(@"photo.jpg");
    NSInteger before = pb.changeCount;
    int rc = ListSendCommand(pw, lc_selectall, 0);
    check(rc == LISTPLUGIN_ERROR && pb.changeCount == before, @"lc_selectall is declined, clipboard untouched");
    ListCloseWindow(pw);

    [pb clearContents];
    if (saved.count) [pb writeObjects:saved];

    printf(gFailures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", gFailures);
    return gFailures ? 1 : 0;
}}
