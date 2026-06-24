/* End-to-end: load the real .wlx into a parent view that stands in for Double
 * Commander's viewer, focus the plugin's web view, press Esc through the normal
 * NSApplication event queue, and confirm the plugin re-routes it to the parent
 * (i.e. DC) via -sendEvent: dispatch — which is how LCL closes the viewer. */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>
typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);

static BOOL gDCGotEsc = NO;

@interface FakeDC : NSView @end
@implementation FakeDC
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 53) { gDCGotEsc = YES; NSLog(@"VERIFY: DC parent received Esc via event dispatch -> viewer closes"); }
}
@end

static NSEvent *EscDown(NSWindow *w) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:w.windowNumber context:nil
        characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
}

int main(int argc, char **argv){ @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    void *h = dlopen(argv[1], RTLD_NOW);
    ListLoad_t ListLoad = (ListLoad_t)dlsym(h, "ListLoad");

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,600)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    FakeDC *dc = [[FakeDC alloc] initWithFrame:NSMakeRect(0,0,800,600)];
    win.contentView = dc;

    HWND pw = ListLoad((__bridge HWND)dc, argv[2], 0);
    WKWebView *web = nil;
    for (NSView *v in ((__bridge NSView *)pw).subviews)
        if ([v isKindOfClass:[WKWebView class]]) web = (WKWebView *)v;
    [win makeKeyAndOrderFront:nil];
    [win makeFirstResponder:web];

    // Let the page settle, focus the web view, then queue Esc for normal dispatch.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [win makeFirstResponder:web];
        NSLog(@"VERIFY: firstResponder=%@; posting Esc to NSApp queue", win.firstResponder);
        [NSApp postEvent:EscDown(win) atStart:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.6*NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            printf(gDCGotEsc ? "RESULT: PASS (Esc reaches DC)\n" : "RESULT: FAIL (Esc swallowed)\n");
            [app stop:nil];
            // nudge the run loop so -stop takes effect promptly
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                context:nil subtype:0 data1:0 data2:0] atStart:YES];
        });
    });
    [app run];
    return gDCGotEsc ? 0 : 1;
}}
