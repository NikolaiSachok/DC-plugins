/* Probe: does keyDown: reach a WKWebView subclass, and does forwarding to the
 * nextResponder reach the parent view (simulating DC's viewer)? */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface ProbeWebView : WKWebView @end
@implementation ProbeWebView
- (void)keyDown:(NSEvent *)e {
    NSLog(@"PROBE: WKWebView keyDown keyCode=%d", (int)e.keyCode);
    if (e.keyCode == 53) { NSLog(@"PROBE: forwarding ESC to nextResponder %@", self.nextResponder);
        [self.nextResponder keyDown:e]; return; }
    [super keyDown:e];
}
@end

@interface FakeDC : NSView @end
@implementation FakeDC
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e { NSLog(@"PROBE: FakeDC(parent) GOT keyDown keyCode=%d  <<< DC would close", (int)e.keyCode); }
@end

static NSEvent *EscDown(NSWindow *w) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:w.windowNumber context:nil
        characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
}

int main(void){ @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,400)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    FakeDC *dc = [[FakeDC alloc] initWithFrame:NSMakeRect(0,0,600,400)];
    win.contentView = dc;
    ProbeWebView *wv = [[ProbeWebView alloc] initWithFrame:dc.bounds];
    [dc addSubview:wv];
    [wv loadHTMLString:@"<h1>hi</h1><p>scroll me</p>" baseURL:nil];
    [win makeKeyAndOrderFront:nil];
    [win makeFirstResponder:wv];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        NSLog(@"PROBE: firstResponder before Esc = %@", win.firstResponder);
        NSLog(@"PROBE: sending Esc...");
        [win sendEvent:EscDown(win)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{ NSLog(@"PROBE: done"); [app terminate:nil]; });
    });
    [app run];
    return 0;
}}
