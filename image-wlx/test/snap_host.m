/*
 * Render an image through the real ImageView.wlx and save a PNG of the whole
 * plugin view (toolbar included) — the visual check behind test_host.m.
 *
 *   ./build/snap_host <ImageView.wlx> <image> <out.png> [zoom%] [width] [height] [dark]
 *
 * zoom% 0 (default) keeps the opening zoom DC's "Stretch only large" gives.
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);

static void pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static NSScrollView *FindScroll(NSView *v) {
    if ([v isKindOfClass:[NSScrollView class]]) return (NSScrollView *)v;
    for (NSView *s in v.subviews) { NSScrollView *f = FindScroll(s); if (f) return f; }
    return nil;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 4) {
        fprintf(stderr, "usage: snap_host <wlx> <image> <out.png> [zoom%%] [width] [height] [dark]\n");
        return 2;
    }
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    double zoom = argc > 4 ? atof(argv[4]) : 0;
    CGFloat w = argc > 5 ? atof(argv[5]) : 900, h = argc > 6 ? atof(argv[6]) : 600;
    if (argc > 7 && atoi(argv[7])) app.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    else app.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];

    void *lib = dlopen(argv[1], RTLD_NOW);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    ListLoad_t ListLoad = dlsym(lib, "ListLoad");

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    win.contentView.wantsLayer = YES;
    [win orderFront:nil];
    HWND pw = ListLoad((__bridge HWND)win.contentView, argv[2], 2 | 32 /* lcp_fittowindow | lcp_fitlargeronly */);
    if (!pw) { fprintf(stderr, "ListLoad returned NULL\n"); return 3; }
    NSView *view = (__bridge NSView *)pw;
    pump(1.5);

    if (zoom > 0) {
        NSScrollView *scroll = FindScroll(view);
        NSRect b = scroll.contentView.bounds;
        [scroll setMagnification:zoom / 100 centeredAtPoint:NSMakePoint(NSMidX(b), NSMidY(b))];
        pump(0.8);
    }
    [win display];
    pump(0.3);

    CGFloat scale = win.backingScaleFactor;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(w * scale) pixelsHigh:(NSInteger)(h * scale)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGContextScaleCTM(gc.CGContext, scale, scale);
    [win.contentView.layer renderInContext:gc.CGContext];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:@(argv[3]) atomically:YES];
    printf("saved %s\n", argv[3]);
    return 0;
}}
