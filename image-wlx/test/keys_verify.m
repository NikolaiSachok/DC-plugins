/* Regression net for Double Commander's viewer hotkeys.
 *
 * With the image focused, the keys the plugin does not use must still reach
 * DC's viewer: N / P and Alt+Right / Alt+Left load the next or previous file
 * (cm_LoadNextFile / cm_LoadPrevFile), Q closes the viewer. LCL handles them
 * through NSApplication's event dispatch, so the plugin re-posts them to DC's
 * view. Afterwards the image must have keyboard focus again, so the arrows
 * keep panning the next image — unless DC moved focus to a control of its
 * own (Tab to the file panel) or a dialog took the key window (F7, Find).
 * The keys the plugin does use (plain arrows, Cmd+Up / Cmd+Down, the zoom
 * keys) must stay with it.
 *
 * The stand-in for DC's viewer panel records each key it receives, and on N
 * or P calls ListLoadNext, as cm_LoadNextFile does.
 *
 * This is a regression net, not proof: per the charter, press N and P with
 * the image focused in a real Double Commander.
 *
 *   ./build/keys_verify <ImageView.wlx> <large image> <other image>
 */
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef int (*ListLoadNext_t)(HWND, HWND, char *, int);

static int gFailures = 0;
static ListLoadNext_t ListLoadNext;
static HWND gPlugin;
static const char *gNext;
static int gLoads = 0;

@class HostWindow;
static HostWindow *gWin;
static NSView *gPanel;

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


/* Key status is the test's to decide (see focus_verify.m). */
@interface HostWindow : NSWindow
@property (nonatomic) BOOL key;
@end
@implementation HostWindow
- (BOOL)isKeyWindow { return self.key; }
@end

/* DC's viewer panel: the parent ListLoad gets. Tab moves focus to a control
 * of DC's own; F7 opens a dialog, so the viewer window stops being key. */
@interface FakeDC : NSView
@property (nonatomic, strong) NSMutableArray<NSEvent *> *keys;
@end
@implementation FakeDC
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e {
    [self.keys addObject:e];
    NSEventModifierFlags mods = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL alt = (mods & NSEventModifierFlagOption) != 0;
    BOOL next = e.keyCode == 45 /* N */ || (alt && e.keyCode == 124);
    BOOL prev = e.keyCode == 35 /* P */ || (alt && e.keyCode == 123);
    if ((next || prev) && ListLoadNext(gPlugin, gPlugin, (char *)gNext, 0) == 0) gLoads++;
    if (e.keyCode == 48 /* Tab */) [self.window makeFirstResponder:gPanel];
    if (e.keyCode == 98 /* F7 */) gWin.key = NO;
}
@end

typedef enum { FocusImage, FocusPanel, FocusDC } Focus;

typedef struct {
    unsigned short code;
    unichar ch;
    NSEventModifierFlags mods;
    BOOL toDC;      /* the key belongs to DC's viewer */
    BOOL loads;     /* DC answers it with ListLoadNext */
    const char *name;
    Focus focus;    /* who has keyboard focus afterwards */
} Case;

#define ARROW (NSEventModifierFlagFunction | NSEventModifierFlagNumericPad)
static const Case kCases[] = {
    { 45,  'n', 0, YES, YES, "N", FocusImage },
    { 35,  'p', 0, YES, YES, "P", FocusImage },
    { 124, NSRightArrowFunctionKey, ARROW | NSEventModifierFlagOption, YES, YES, "Alt+Right", FocusImage },
    { 123, NSLeftArrowFunctionKey,  ARROW | NSEventModifierFlagOption, YES, YES, "Alt+Left", FocusImage },
    { 18,  '1', 0, YES, NO, "1 (view as text)", FocusImage },
    { 124, NSRightArrowFunctionKey, ARROW | NSEventModifierFlagShift, YES, NO, "Shift+Right", FocusImage },
    { 124, NSRightArrowFunctionKey, ARROW, NO, NO, "Right", FocusImage },
    { 125, NSDownArrowFunctionKey,  ARROW, NO, NO, "Down", FocusImage },
    { 126, NSUpArrowFunctionKey,    ARROW | NSEventModifierFlagCommand, NO, NO, "Cmd+Up (top)", FocusImage },
    { 125, NSDownArrowFunctionKey,  ARROW | NSEventModifierFlagCommand, NO, NO, "Cmd+Down (bottom)", FocusImage },
    { 115, NSHomeFunctionKey, NSEventModifierFlagFunction, NO, NO, "Home (top)", FocusImage },
    { 119, NSEndFunctionKey,  NSEventModifierFlagFunction, NO, NO, "End (bottom)", FocusImage },
    { 24,  '=', 0, NO, NO, "= (zoom in)", FocusImage },
    { 48,  '\t', 0, YES, NO, "Tab (DC focuses its file panel)", FocusPanel },
    { 98,  NSF7FunctionKey, NSEventModifierFlagFunction, YES, NO, "F7 (DC opens a dialog)", FocusDC },
    { 12,  'q', 0, YES, NO, "Q", FocusImage },
};
static const int kCount = (int)(sizeof kCases / sizeof kCases[0]);

static FakeDC *gDC;
static NSView *gCanvas;
static NSScrollView *gScroll;

/* The clip view shows the top (-1) or the bottom (+1) edge of the image. */
static BOOL AtEdge(int edge) {
    NSRect b = gScroll.contentView.bounds, doc = gCanvas.frame;
    return edge < 0 ? fabs(NSMinY(b) - NSMinY(doc)) < 0.5 : fabs(NSMaxY(b) - NSMaxY(doc)) < 0.5;
}

static void Step(int i) {
    if (i == kCount) {
        printf(gFailures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", gFailures);
        [NSApp stop:nil];
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
            location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
            context:nil subtype:0 data1:0 data2:0] atStart:YES];
        return;
    }
    Case c = kCases[i];
    printf("%s:\n", c.name);
    gWin.key = YES;
    [gWin makeFirstResponder:gCanvas];
    NSUInteger seen = gDC.keys.count;
    int loads = gLoads;
    NSPoint origin = gScroll.contentView.bounds.origin;
    CGFloat mag = gScroll.magnification;
    NSString *chars = [NSString stringWithCharacters:&c.ch length:1];
    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:c.mods timestamp:0 windowNumber:gWin.windowNumber context:nil
        characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:c.code];
    [NSApp postEvent:e atStart:NO];
    After(0.3, ^{
        NSEvent *got = gDC.keys.count > seen ? gDC.keys.lastObject : nil;
        if (c.toDC) {
            check(gDC.keys.count == seen + 1, "reaches DC's viewer, once");
            check(got.keyCode == c.code && [got.characters isEqualToString:chars] &&
                  (got.modifierFlags & NSEventModifierFlagOption) == (c.mods & NSEventModifierFlagOption),
                  "arrives unchanged");
            if (c.loads) check(gLoads == loads + 1, "DC loads the next file");
        } else {
            check(got == nil, "stays with the image");
            if (c.code == 24) check(gScroll.magnification > mag, "zooms in");
            else if (c.code == 115 || c.code == 126) check(AtEdge(-1), "scrolls to the top");
            else if (c.code == 119 || (c.code == 125 && c.mods & NSEventModifierFlagCommand))
                check(AtEdge(+1), "scrolls to the bottom");
            else check(!NSEqualPoints(gScroll.contentView.bounds.origin, origin), "scrolls the image");
        }
        switch (c.focus) {
            case FocusImage: check(gWin.firstResponder == gCanvas, "the image has keyboard focus afterwards"); break;
            case FocusPanel: check(gWin.firstResponder == gPanel, "DC's file panel keeps the focus it took"); break;
            case FocusDC:    check(gWin.firstResponder == gDC, "focus is not taken back behind the dialog"); break;
        }
        Step(i + 1);
    });
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 4) {
        fprintf(stderr, "usage: keys_verify <ImageView.wlx> <large image> <other image>\n");
        return 2;
    }
    gNext = argv[3];
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
    ListLoad_t ListLoad = (ListLoad_t)dlsym(h, "ListLoad");
    ListLoadNext = (ListLoadNext_t)dlsym(h, "ListLoadNext");
    if (!ListLoad || !ListLoadNext) { fprintf(stderr, "missing exports\n"); return 2; }

    HostWindow *win = [[HostWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 400)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    win.releasedWhenClosed = NO;
    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 400)];
    win.contentView = form;
    FakeDC *dc = [[FakeDC alloc] initWithFrame:form.bounds];
    dc.keys = [NSMutableArray array];
    [form addSubview:dc];
    gPanel = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [form addSubview:gPanel positioned:NSWindowBelow relativeTo:dc];
    [win orderFront:nil];
    win.key = YES;

    /* No Stretch: the image opens at 100%, larger than the window. */
    gPlugin = ListLoad((__bridge HWND)dc, argv[2], 0);
    if (!gPlugin) { fprintf(stderr, "ListLoad returned NULL\n"); return 2; }
    gWin = win;
    gDC = dc;
    gCanvas = Find((__bridge NSView *)gPlugin, @"IVCanvas");
    gScroll = (NSScrollView *)Find((__bridge NSView *)gPlugin, @"IVScrollView");
    After(0.8, ^{ Step(0); });
    [app run];
    return gFailures ? 1 : 0;
}}
