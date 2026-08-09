/*
 * Render a book through the real BookView.wlx and save a PNG — the visual
 * counterpart to test_host.m, used to eyeball typography and theming.
 *
 *   ./build/snap_host <BookView.wlx> <book.epub> <out.png> [scrollY] [width] [height]
 */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);

static void pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: snap_host <wlx> <book.epub> <out.png> "
                            "[scrollY] [width] [height]\n");
            return 2;
        }
        [NSApplication sharedApplication];

        CGFloat w = argc > 5 ? atof(argv[5]) : 1100;
        CGFloat h = argc > 6 ? atof(argv[6]) : 860;
        long scrollY = argc > 4 ? atol(argv[4]) : 0;

        void *lib = dlopen(argv[1], RTLD_NOW);
        if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
        ListLoad_t ListLoad = dlsym(lib, "ListLoad");

        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, w, h)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        HWND pw = ListLoad((__bridge HWND)win.contentView, argv[2], 0);
        if (!pw) { fprintf(stderr, "ListLoad returned NULL\n"); return 2; }

        WKWebView *web = nil;
        for (NSView *v in ((__bridge NSView *)pw).subviews)
            if ([v isKindOfClass:[WKWebView class]]) web = (WKWebView *)v;

        pump(4.0);
        if (scrollY > 0) {
            [web evaluateJavaScript:
                [NSString stringWithFormat:@"window.scrollTo(0,%ld)", scrollY]
                  completionHandler:nil];
            pump(1.0);
        }

        __block BOOL done = NO;
        WKSnapshotConfiguration *cfg = [[WKSnapshotConfiguration alloc] init];
        [web takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *img, NSError *e) {
            if (img) {
                CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                [png writeToFile:[NSString stringWithUTF8String:argv[3]] atomically:YES];
                printf("saved %s\n", argv[3]);
            } else {
                fprintf(stderr, "snapshot failed: %s\n", e.description.UTF8String);
            }
            done = YES;
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!done && [deadline timeIntervalSinceNow] > 0) pump(0.05);
    }
    return 0;
}
