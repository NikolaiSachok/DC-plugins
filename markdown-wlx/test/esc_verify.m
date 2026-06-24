/* End-to-end: load the real .wlx into a parent view that stands in for Double
 * Commander's viewer, focus the plugin's web view, press Esc, and confirm the
 * parent (i.e. DC) receives it -> the viewer would close. */
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
    if (e.keyCode == 53) { gDCGotEsc = YES; NSLog(@"VERIFY: DC parent received Esc -> viewer closes"); }
}
@end

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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        NSLog(@"VERIFY: firstResponder=%@", win.firstResponder);
        NSEvent *esc = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:0 timestamp:0 windowNumber:win.windowNumber context:nil
            characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
        [win sendEvent:esc];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.4*NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            printf(gDCGotEsc ? "RESULT: PASS (Esc reaches DC)\n" : "RESULT: FAIL (Esc swallowed)\n");
            [app terminate:nil];
        });
    });
    [app run];
    return 0;
}}
