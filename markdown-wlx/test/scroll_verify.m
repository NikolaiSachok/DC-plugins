/* Verify scroll restore across ListLoadNext: scroll file A, navigate to B, come
 * back to A, and confirm the regenerated page restores A's offset (the host
 * injects __scrollY into the HTML it writes). */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>
typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef int  (*ListNext_t)(HWND, HWND, char *, int);

static NSString *NewestTempHTML(void) {
    NSString *dir = NSTemporaryDirectory();
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    NSString *best = nil; NSDate *bestDate = nil;
    for (NSString *f in files) {
        if (![f hasPrefix:@"dc-md-preview-"]) continue;
        NSString *p = [dir stringByAppendingPathComponent:f];
        NSDate *m = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL].fileModificationDate;
        if (!bestDate || [m compare:bestDate] == NSOrderedDescending) { best = p; bestDate = m; }
    }
    return best;
}

int main(int argc, char **argv) { @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    void *h = dlopen(argv[1], RTLD_NOW);
    ListLoad_t ListLoad = (ListLoad_t)dlsym(h, "ListLoad");
    ListNext_t ListLoadNext = (ListNext_t)dlsym(h, "ListLoadNext");
    char *A = argv[2], *B = argv[3];

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,500,300)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView *parent = win.contentView;
    HWND pw = ListLoad((__bridge HWND)parent, A, 0);
    WKWebView *web = nil;
    for (NSView *v in ((__bridge NSView *)pw).subviews)
        if ([v isKindOfClass:[WKWebView class]]) web = (WKWebView *)v;
    [win makeKeyAndOrderFront:nil];

    __block BOOL done = NO; __block long restored = -1;
    // 1) let A render, then scroll it
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [web evaluateJavaScript:@"window.scrollTo(0,450); window.scrollY" completionHandler:^(id r, NSError *e){
            NSLog(@"SCROLL: set A scrollY -> %@", r);
            // 2) wait past the 120ms throttle so the host stores it, then go to B and back to A
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ListLoadNext((__bridge HWND)parent, pw, B, 0);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.4*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ListLoadNext((__bridge HWND)parent, pw, A, 0);  // regenerates A's HTML with saved offset
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.3*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        NSString *html = [NSString stringWithContentsOfFile:NewestTempHTML() encoding:NSUTF8StringEncoding error:NULL];
                        NSRange rg = [html rangeOfString:@"var __scrollY="];
                        if (rg.location != NSNotFound) {
                            NSString *tail = [html substringFromIndex:rg.location + rg.length];
                            restored = [tail integerValue];
                        }
                        NSLog(@"RESTORE: A regenerated with __scrollY=%ld", restored);
                        done = YES;
                    });
                });
            });
        }];
    });

    NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!done && [dl timeIntervalSinceNow]>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

    printf(restored >= 400 ? "RESULT: PASS (restored %ld)\n" : "RESULT: FAIL (restored %ld)\n", restored);
    return restored >= 400 ? 0 : 1;
}}
