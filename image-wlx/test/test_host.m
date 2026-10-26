/*
 * End-to-end harness for the real built ImageView.wlx: dlopen it, drive the
 * WLX ABI the way Double Commander does, and check what the user would see —
 * which files open (and which fall through to the next lister), the size and
 * zoom an image opens at, the toolbar's readout, and that keyboard, Cmd+scroll,
 * drag and double-click zoom and pan as they should.
 *
 *   ./build/test_host <ImageView.wlx> <samples-dir>
 *
 * Events go through the same loop DC uses (nextEventMatchingMask + sendEvent),
 * so the plugin's key monitor sees them exactly as it would in the host.
 */
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <fenv.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef int  (*ListLoadNext_t)(HWND, HWND, char *, int);
typedef void (*ListCloseWindow_t)(HWND);
typedef int  (*ListSendCommand_t)(HWND, int, int);
typedef void (*ListGetDetectString_t)(char *, int);

enum { kFit = 4, kFitLarge = 4 | 128, lc_newparams = 2 };

static ListLoad_t ListLoad;
static ListLoadNext_t ListLoadNext;
static ListCloseWindow_t ListCloseWindow;
static ListSendCommand_t ListSendCommand;
static ListGetDetectString_t ListGetDetectString;
static NSString *gDir;
static int gFailures = 0;

static void check(BOOL cond, NSString *what) {
    printf("  %-66s %s\n", what.UTF8String, cond ? "ok" : "FAILED");
    if (!cond) gFailures++;
}

static BOOL near(double a, double b) { return fabs(a - b) < 0.01 * MAX(1, fabs(b)); }

/* Run DC's kind of event loop for a while. */
static void pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                                           inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e) [NSApp sendEvent:e];
    } while ([until timeIntervalSinceNow] > 0);
}

static NSView *Find(NSView *root, NSString *cls) {
    if ([root isKindOfClass:NSClassFromString(cls)]) return root;
    for (NSView *v in root.subviews) { NSView *f = Find(v, cls); if (f) return f; }
    return nil;
}

/* Key status is the test's to decide, not the window server's: a background
 * test process cannot reliably make its windows key. */
@interface HostWindow : NSWindow
@property (nonatomic) BOOL key;
@end
@implementation HostWindow
- (BOOL)isKeyWindow { return self.key; }
@end

/* What a loaded plugin view looks like from the outside. */
@interface Probe : NSObject
@property (nonatomic) HWND handle;
@property (nonatomic, strong) NSView *view;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSView *canvas;
@property (nonatomic, strong) NSView *raster;
@end
@implementation Probe
- (CGFloat)mag { return self.scroll.magnification; }
- (NSSize)docSize { return self.canvas.frame.size; }
- (CGImageRef)pixels { return (__bridge CGImageRef)[self.raster valueForKey:@"cgImage"]; }
- (id)vector { return [self.canvas valueForKey:@"vector"]; }
- (NSString *)info {
    NSTextField *f = [self.view valueForKey:@"infoLabel"];
    return f.stringValue;
}
- (NSString *)zoomTitle {
    NSPopUpButton *p = [self.view valueForKey:@"zoomPopup"];
    return [p itemAtIndex:0].title;
}
- (NSPoint)origin { return self.scroll.contentView.bounds.origin; }
- (BOOL)waitForPixels {
    for (int i = 0; i < 300 && !self.pixels; i++) pump(0.02);
    return self.pixels != NULL;
}
@end

/* Stands in for a DC control that holds focus (the file panel in Quick View). */
@interface Bystander : NSView
@end
@implementation Bystander
- (BOOL)acceptsFirstResponder { return YES; }
@end

static HostWindow *gWin;

static NSString *Sample(NSString *name) { return [gDir stringByAppendingPathComponent:name]; }

static Probe *Load(NSString *name, int flags) {
    HWND h = ListLoad((__bridge HWND)gWin.contentView, (char *)Sample(name).fileSystemRepresentation, flags);
    if (!h) return nil;
    Probe *p = [[Probe alloc] init];
    p.handle = h;
    p.view = (__bridge NSView *)h;
    p.scroll = (NSScrollView *)Find(p.view, @"IVScrollView");
    p.canvas = Find(p.view, @"IVCanvas");
    p.raster = Find(p.view, @"IVRasterView");
    pump(0.05);
    return p;
}

static void Close(Probe *p) { if (p) ListCloseWindow(p.handle); pump(0.05); }

static NSEvent *Key(NSString *ch, unsigned short code, NSEventModifierFlags mods) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods
                           timestamp:0 windowNumber:gWin.windowNumber context:nil
                          characters:ch charactersIgnoringModifiers:ch isARepeat:NO keyCode:code];
}

static NSEvent *Wheel(NSPoint windowPoint, int lines, CGEventFlags flags) {
    CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, lines * 10);
    CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    CGEventSetLocation(cg, CGPointMake(windowPoint.x, top - windowPoint.y));
    CGEventSetFlags(cg, flags);
    NSEvent *e = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    return e;
}

static void Press(NSEvent *e) { [NSApp postEvent:e atStart:NO]; pump(0.1); }

static NSEvent *Mouse(NSEventType type, NSPoint windowPoint, NSInteger clicks) {
    return [NSEvent mouseEventWithType:type location:windowPoint modifierFlags:0 timestamp:0
                          windowNumber:gWin.windowNumber context:nil eventNumber:0
                            clickCount:clicks pressure:1];
}

static void TestDetectString(void) {
    printf("Detect string:\n");
    char buf[2048] = {0};
    ListGetDetectString(buf, sizeof buf);
    NSString *s = @(buf);
    check(strlen(buf) > 0 && strlen(buf) < sizeof buf - 1, @"fits Double Commander's 2048-byte buffer");
    for (NSString *ext in @[ @"PNG", @"JPG", @"HEIC", @"WEBP", @"CR2", @"SVG", @"SVGZ" ])
        check([s containsString:[NSString stringWithFormat:@"EXT=\"%@\"", ext]],
              [NSString stringWithFormat:@"claims .%@", ext.lowercaseString]);
    check(![s containsString:@"EXT!="], @"is not a catch-all");
}

static void TestFallThrough(void) {
    printf("Files that are not images fall through to the next lister:\n");
    for (NSString *n in @[ @"garbage.png", @"disk.raw", @"broken.svg", @"missing.jpg" ]) {
        Probe *p = Load(n, kFitLarge);
        check(p == nil, [NSString stringWithFormat:@"ListLoad(%@) returns NULL", n]);
        Close(p);
    }
}

static void TestFormats(void) {
    printf("Formats open at their true size:\n");
    struct { const char *name; double w, h; const char *fmt; } cases[] = {
        { "photo.jpg",   1600, 1000, "JPEG" },
        { "rotated.jpg",  200,  400, "JPEG" },   /* stored 400x200, EXIF "rotate 90" */
        { "alpha.png",    300,  200, "PNG"  },
        { "pixel.png",      8,    8, "PNG"  },
        { "anim.gif",     120,   80, "GIF"  },
        { "wide.png",   20000,  400, "PNG"  },
        { "pages.tiff",  1600, 1000, "TIFF" },
        { "icon.ico",      64,   64, "ICO"  },   /* the largest entry, not the first */
        { "photo.heic",  1600, 1000, "HEIC" },
        { "photo.bmp",   1600, 1000, "BMP"  },
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        NSString *name = @(cases[i].name);
        Probe *p = Load(name, kFitLarge);
        if (!p) { check(NO, [NSString stringWithFormat:@"%@ opens", name]); continue; }
        BOOL decoded = [p waitForPixels];
        NSSize s = p.docSize;
        check(decoded && near(s.width, cases[i].w) && near(s.height, cases[i].h),
              [NSString stringWithFormat:@"%@ shows as %.0f x %.0f", name, cases[i].w, cases[i].h]);
        NSString *dims = [NSString stringWithFormat:@"%.0f × %.0f", cases[i].w, cases[i].h];
        check([p.info hasPrefix:dims] && [p.info containsString:@(cases[i].fmt)],
              [NSString stringWithFormat:@"  toolbar reads \"%@\"", p.info]);
        if ([name isEqualToString:@"rotated.jpg"]) {
            /* Upright after orientation: the red half ends up on top. */
            CGImageRef cg = p.pixels;
            check(CGImageGetWidth(cg) == 200 && CGImageGetHeight(cg) == 400,
                  @"  decoded upright (200 x 400 pixels)");
        }
        if ([name isEqualToString:@"wide.png"])
            check(CGImageGetWidth(p.pixels) <= 16384, @"  display bitmap capped at 16384 px");
        if ([name isEqualToString:@"pages.tiff"])
            check(![p.info containsString:@"frames"], @"  a multi-page TIFF is not an animation");
        if ([name isEqualToString:@"anim.gif"])
            check([p.info containsString:@"3 frames"], @"  the animation's frames are counted");
        Close(p);
    }

    for (NSString *name in @[ @"edge.svg", @"edge.svgz" ]) {
        Probe *p = Load(name, kFitLarge);
        check(p && p.vector && near(p.docSize.width, 40) && near(p.docSize.height, 20),
              [NSString stringWithFormat:@"%@ opens as vector, 40 x 20 pt", name]);
        check([p.info hasPrefix:@"40 × 20 pt · SVG"],
              [NSString stringWithFormat:@"  toolbar reads \"%@\"", p.info]);
        Close(p);
    }
}

static void TestOpeningZoom(void) {
    printf("Opening zoom follows DC's Image > Stretch setting:\n");
    Probe *p = Load(@"photo.jpg", kFitLarge);
    NSSize vp = p.scroll.contentView.frame.size;
    double fit = MIN(vp.width / 1600, vp.height / 1000);
    check(near(p.mag, fit), [NSString stringWithFormat:@"large image, Stretch only large -> fit (%.0f%%)", fit * 100]);
    check([p.zoomTitle isEqualToString:[NSString stringWithFormat:@"%.0f%%", round(fit * 1000) / 10]],
          [NSString stringWithFormat:@"  toolbar shows %@", p.zoomTitle]);
    Close(p);

    p = Load(@"alpha.png", kFitLarge);
    check(near(p.mag, 1), @"small image, Stretch only large -> 100%");
    check([p.zoomTitle isEqualToString:@"100%"], @"  toolbar shows 100%");
    Close(p);

    p = Load(@"alpha.png", kFit);
    vp = p.scroll.contentView.frame.size;
    check(near(p.mag, MIN(vp.width / 300, vp.height / 200)), @"small image, Stretch -> enlarged to fit");
    Close(p);

    p = Load(@"photo.jpg", 0);
    check(near(p.mag, 1), @"no Stretch -> 100%");
    NSRect b = p.scroll.contentView.bounds;
    check(near(NSMidX(b), 800) && near(NSMidY(b), 500), @"  centered on the image");
    ListSendCommand(p.handle, lc_newparams, kFitLarge);
    pump(0.05);
    check(near(p.mag, fit), @"lc_newparams (user pressed L) re-fits at once");
    Close(p);
}

static void TestKeys(void) {
    printf("Zoom keys (taken before DC's own Cmd+= / Cmd+- bindings):\n");
    Probe *p = Load(@"photo.jpg", 0);
    [p waitForPixels];
    gWin.key = YES;
    [gWin makeFirstResponder:p.canvas];

    Press(Key(@"=", 24, NSEventModifierFlagCommand));
    check(near(p.mag, 1.25), [NSString stringWithFormat:@"Cmd+= zooms in one step (100%% -> %.0f%%)", p.mag * 100]);
    Press(Key(@"-", 27, NSEventModifierFlagCommand));
    Press(Key(@"-", 27, NSEventModifierFlagCommand));
    check(near(p.mag, 0.75), [NSString stringWithFormat:@"Cmd+- twice zooms out (-> %.0f%%)", p.mag * 100]);
    Press(Key(@"0", 29, NSEventModifierFlagCommand));
    check(near(p.mag, 1), @"Cmd+0 -> actual size");
    Press(Key(@"9", 25, NSEventModifierFlagCommand));
    NSSize vp = p.scroll.contentView.frame.size;
    check(near(p.mag, MIN(vp.width / 1600, vp.height / 1000)), @"Cmd+9 -> fit");
    Press(Key(@"+", 69, NSEventModifierFlagNumericPad));
    check(p.mag > MIN(vp.width / 1600, vp.height / 1000) * 1.05, @"keypad + zooms in");
    CGFloat before = p.mag;
    Press(Key(@"1", 18, 0));
    check(near(p.mag, before), @"plain digits are left to DC (1 = Text mode)");

    /* Quick View: a file-panel control in the same window holds focus. Its
     * keys are its own, even the ones the plugin would take. */
    Bystander *panel = [[Bystander alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [gWin.contentView addSubview:panel];
    [gWin makeFirstResponder:panel];
    Press(Key(@"=", 24, NSEventModifierFlagCommand));
    check(near(p.mag, before), @"with focus elsewhere, Cmd+= is left to that control");
    [panel removeFromSuperview];
    Close(p);
}

static void TestMouse(void) {
    printf("Mouse: Cmd+scroll zooms at the pointer, drag pans, double-click toggles:\n");
    Probe *p = Load(@"photo.jpg", 0);
    [p waitForPixels];
    gWin.key = YES;

    /* Cmd+scroll up over a point: zoom in, and that point stays under the
     * pointer. The host window sits at the screen origin, so the window-less
     * event's screen location is also its window location. */
    NSPoint win = [p.scroll convertPoint:NSMakePoint(200, 150) toView:nil];
    NSPoint docBefore = [p.canvas convertPoint:win fromView:nil];
    CGFloat mag0 = p.mag;
    [p.scroll scrollWheel:Wheel(win, 3, kCGEventFlagMaskCommand)];
    pump(0.05);
    NSPoint docAfter = [p.canvas convertPoint:win fromView:nil];
    check(p.mag > mag0 * 1.05, [NSString stringWithFormat:@"Cmd+scroll up zooms in (%.0f%% -> %.0f%%)", mag0 * 100, p.mag * 100]);
    check(fabs(docAfter.x - docBefore.x) < 1 && fabs(docAfter.y - docBefore.y) < 1,
          @"  around the point under the pointer");
    [p.scroll scrollWheel:Wheel(win, -3, kCGEventFlagMaskAlternate)];
    pump(0.05);
    check(p.mag < mag0 * 1.01, @"Option+scroll down zooms back out");

    /* A plain scroll is NSScrollView's to pan with. AppKit ignores a
     * synthetic, window-less wheel event for that, so only "it does not
     * zoom" is checked here; panning by scroll is checked in DC. */
    CGFloat mag1 = p.mag;
    [p.scroll scrollWheel:Wheel(win, -3, 0)];
    pump(0.05);
    check(near(p.mag, mag1), @"plain scroll does not zoom");

    /* Drag at 100%: the image follows the pointer. */
    Press(Key(@"0", 29, NSEventModifierFlagCommand));
    [gWin makeFirstResponder:p.canvas];
    Press(Key(@"0", 29, NSEventModifierFlagCommand));
    NSPoint start = [p.scroll convertPoint:NSMakePoint(400, 300) toView:nil];
    NSPoint before = p.origin;
    [p.canvas mouseDown:Mouse(NSEventTypeLeftMouseDown, start, 1)];
    [p.canvas mouseDragged:Mouse(NSEventTypeLeftMouseDragged, NSMakePoint(start.x - 120, start.y + 80), 1)];
    [p.canvas mouseUp:Mouse(NSEventTypeLeftMouseUp, NSMakePoint(start.x - 120, start.y + 80), 1)];
    NSPoint after = p.origin;
    /* Pointer left and up: the image follows, showing more of its right and
     * lower part (the document is flipped, so y grows downwards). */
    check(near(after.x - before.x, 120) && near(after.y - before.y, 80),
          [NSString stringWithFormat:@"dragging moves the image with the pointer (%+.0f, %+.0f)",
              after.x - before.x, after.y - before.y]);
    check(p.scroll.documentCursor == [NSCursor openHandCursor], @"open-hand cursor over a pannable image");

    /* Double-click: 100% -> fit -> 100%. */
    [p.canvas mouseDown:Mouse(NSEventTypeLeftMouseDown, start, 2)];
    NSSize vp = p.scroll.contentView.frame.size;
    double fit = MIN(vp.width / 1600, vp.height / 1000);
    check(near(p.mag, fit), @"double-click at 100% fits the window");
    check(p.scroll.documentCursor == nil, @"no hand cursor when there is nothing to pan");
    [p.canvas mouseDown:Mouse(NSEventTypeLeftMouseDown, start, 2)];
    check(near(p.mag, 1), @"double-click again returns to 100%");
    Close(p);
}

static void TestZoomLimits(void) {
    printf("Zoom limits and pixel view:\n");
    Probe *p = Load(@"pixel.png", kFitLarge);
    [p waitForPixels];
    gWin.key = YES;
    [gWin makeFirstResponder:p.canvas];
    for (int i = 0; i < 40; i++) Press(Key(@"=", 24, NSEventModifierFlagCommand));
    NSSize vp = p.scroll.contentView.frame.size;
    double cap = MAX(64, 2 * MIN(vp.width / 8, vp.height / 8));
    check(near(p.mag, cap), [NSString stringWithFormat:@"a tiny image zooms in to twice its fit (%.0f%%)", p.mag * 100]);
    check([[p.raster valueForKey:@"pixelated"] boolValue], @"past 200% the pixels are drawn unsmoothed");
    for (int i = 0; i < 60; i++) Press(Key(@"-", 27, NSEventModifierFlagCommand));
    check(near(p.mag, 0.5), [NSString stringWithFormat:@"zoom out stops at half of 100%% (%.0f%%)", p.mag * 100]);
    check(![[p.raster valueForKey:@"pixelated"] boolValue], @"zoomed out, the pixels are smoothed again");
    Close(p);
}

static void TestAnimation(void) {
    printf("Animation:\n");
    Probe *p = Load(@"anim.gif", kFitLarge);
    [p waitForPixels];
    NSMutableSet *seen = [NSMutableSet set];
    for (int i = 0; i < 40; i++) { [seen addObject:@((uintptr_t)p.pixels)]; pump(0.02); }
    check(seen.count >= 3, [NSString stringWithFormat:@"frames advance (%lu distinct in 0.8 s)", (unsigned long)seen.count]);
    Close(p);
    pump(0.3);   /* a stopped animation must not touch a closed view */
    check(YES, @"closing mid-animation is clean");
}

static void TestVectorSharpness(void) {
    printf("SVG stays vector at high zoom:\n");
    Probe *p = Load(@"edge.svg", kFitLarge);
    NSRect b = p.scroll.contentView.bounds;
    [p.scroll setMagnification:16 centeredAtPoint:NSMakePoint(10, 10)];
    pump(0.1);
    /* The bar's left edge is at x = 10 pt: render 4 pt around it as the
     * screen would, at 16x, and count the grey columns in one row. */
    NSRect r = NSMakeRect(8, 1, 4, 4);   /* clear of the red dot */
    NSBitmapImageRep *rep = [p.canvas bitmapImageRepForCachingDisplayInRect:r];
    [p.canvas cacheDisplayInRect:r toBitmapImageRep:rep];
    NSInteger y = rep.pixelsHigh / 2, grey = 0, dark = 0;
    for (NSInteger x = 0; x < rep.pixelsWide; x++) {
        CGFloat v = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace].greenComponent;
        if (v > 0.1 && v < 0.9) grey++;
        if (v <= 0.1) dark++;
    }
    double scale = (double)rep.pixelsWide / NSWidth(r);
    check(scale >= 16, [NSString stringWithFormat:@"drawn at the zoomed resolution (%.0f px per pt)", scale]);
    check(dark > 0 && grey <= 2,
          [NSString stringWithFormat:@"edge is crisp: %ld grey pixel(s) across a %.0f px/pt edge", (long)grey, scale]);
    (void)b;
    Close(p);
}

/* Free Pascal enables the invalid-operation, divide-by-zero and overflow
 * traps on every thread it starts (rtl/aarch64 SysInitFPU); Apple's frameworks
 * expect them masked. DC's own event loop cannot run trapped on current macOS
 * (a bare window traps on resize), but code DC calls into directly may see
 * them, so each ABI call here runs with all three enabled, as on a fresh FPC
 * thread. The plugin must mask them for its own work; a crash ends the test. */
static void WithHostFPTraps(void (^call)(void)) {
    fenv_t saved;
    fegetenv(&saved);
#if defined(__arm64__)
    uint64_t fpcr;
    __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
    fpcr |= (1ull << 8) | (1ull << 9) | (1ull << 10);   /* IOE, DZE, OFE */
    __asm__ volatile("msr fpcr, %0" : : "r"(fpcr));
#elif defined(__x86_64__)
    uint32_t mxcsr;
    __asm__ volatile("stmxcsr %0" : "=m"(mxcsr));
    mxcsr &= ~((1u << 7) | (1u << 9) | (1u << 10));     /* unmask IM, ZM, OM */
    __asm__ volatile("ldmxcsr %0" : : "m"(mxcsr));
#endif
    call();
    fesetenv(&saved);
}

static void TestUnderHostFPTraps(void) {
    printf("ABI calls under Free Pascal's floating-point traps:\n");
    NSArray *names = @[ @"photo.jpg", @"rotated.jpg", @"anim.gif", @"wide.png", @"pages.tiff",
                        @"icon.ico", @"photo.heic", @"edge.svg", @"edge.svgz", @"garbage.png" ];
    for (NSString *n in names) {
        __block HWND h = NULL;
        WithHostFPTraps(^{
            h = ListLoad((__bridge HWND)gWin.contentView, (char *)Sample(n).fileSystemRepresentation, kFitLarge);
        });
        pump(0.3);
        if (h) {
            WithHostFPTraps(^{
                ListSendCommand(h, lc_newparams, 0);
                ListSendCommand(h, lc_newparams, kFit);
                ListLoadNext((__bridge HWND)gWin.contentView, h,
                             (char *)Sample(@"alpha.png").fileSystemRepresentation, kFitLarge);
                ListCloseWindow(h);
            });
        }
        check(YES, [NSString stringWithFormat:@"%@: load, re-fit, load next, close", n]);
    }
}

static void TestLoadNext(void) {
    printf("ListLoadNext (N / P in the viewer):\n");
    Probe *p = Load(@"photo.jpg", kFitLarge);
    [p waitForPixels];
    int rc = ListLoadNext((__bridge HWND)gWin.contentView, p.handle,
                          (char *)Sample(@"edge.svg").fileSystemRepresentation, kFitLarge);
    check(rc == 0 && p.vector && near(p.docSize.width, 40), @"photo -> SVG switches in place");
    check(p.pixels == NULL, @"  the previous photo's pixels are gone");
    rc = ListLoadNext((__bridge HWND)gWin.contentView, p.handle,
                      (char *)Sample(@"alpha.png").fileSystemRepresentation, kFitLarge);
    check(rc == 0 && [p waitForPixels] && !p.vector && near(p.docSize.width, 300), @"SVG -> PNG switches back");
    rc = ListLoadNext((__bridge HWND)gWin.contentView, p.handle,
                      (char *)Sample(@"garbage.png").fileSystemRepresentation, kFitLarge);
    check(rc == 1, @"a non-image reports an error, so DC leaves plugin mode");
    NSView *parent = p.view.superview;
    Close(p);
    check(parent.subviews.count == 0, @"ListCloseWindow removes the view");
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: test_host <ImageView.wlx> <samples-dir>\n"); return 2; }
    gDir = @(argv[2]);
    setvbuf(stdout, NULL, _IONBF, 0);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    ListLoad = dlsym(h, "ListLoad");
    ListLoadNext = dlsym(h, "ListLoadNext");
    ListCloseWindow = dlsym(h, "ListCloseWindow");
    ListSendCommand = dlsym(h, "ListSendCommand");
    ListGetDetectString = dlsym(h, "ListGetDetectString");
    if (!ListLoad || !ListLoadNext || !ListCloseWindow || !ListSendCommand || !ListGetDetectString) {
        fprintf(stderr, "missing exports\n");
        return 2;
    }

    gWin = [[HostWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    [gWin setFrameOrigin:NSZeroPoint];
    gWin.releasedWhenClosed = NO;
    [gWin orderFront:nil];

    TestDetectString();
    TestFallThrough();
    TestFormats();
    TestOpeningZoom();
    TestKeys();
    TestMouse();
    TestZoomLimits();
    TestAnimation();
    TestLoadNext();
    TestVectorSharpness();
    TestUnderHostFPTraps();

    printf(gFailures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", gFailures);
    return gFailures ? 1 : 0;
}}
