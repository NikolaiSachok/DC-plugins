/* Headless smoke test: load the .wlx like Double Commander would. */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef void (*ListClose_t)(HWND);
typedef void (*ListDetect_t)(char *, int);

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: %s <wlx> <md>\n", argv[0]); return 2; }
        [NSApplication sharedApplication];

        void *h = dlopen(argv[1], RTLD_NOW);
        if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }

        ListLoad_t   ListLoad   = (ListLoad_t)dlsym(h, "ListLoad");
        ListClose_t  ListClose  = (ListClose_t)dlsym(h, "ListCloseWindow");
        ListDetect_t ListDetect = (ListDetect_t)dlsym(h, "ListGetDetectString");
        if (!ListLoad || !ListClose || !ListDetect) {
            fprintf(stderr, "missing symbols\n"); return 1;
        }

        char det[1024] = {0};
        ListDetect(det, sizeof(det));
        printf("DetectString: %s\n", det);

        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 900, 700)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered defer:NO];
        NSView *content = win.contentView;

        HWND pw = ListLoad((__bridge HWND)content, argv[2], 0);
        if (!pw) { fprintf(stderr, "ListLoad returned NULL\n"); return 1; }
        printf("ListLoad OK -> %p\n", pw);

        // Find the WKWebView that the plugin added.
        WKWebView *web = nil;
        for (NSView *v in ((__bridge NSView *)pw).subviews)
            if ([v isKindOfClass:[WKWebView class]]) web = (WKWebView *)v;
        if (!web) { fprintf(stderr, "no WKWebView found\n"); return 1; }

        __block int childCount = -1;
        __block NSString *title = nil;
        __block BOOL done = NO;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];

        // Poll until marked has rendered child nodes into #content.
        void (^poll)(void);
        __block __weak void (^weakPoll)(void);
        weakPoll = poll = ^{
            [web evaluateJavaScript:
                @"(function(){var c=document.getElementById('content');"
                 "return c?c.children.length:-1;})()"
                completionHandler:^(id res, NSError *e) {
                    int n = [res isKindOfClass:[NSNumber class]] ? [res intValue] : -1;
                    if (n > 0) {
                        childCount = n;
                        [web evaluateJavaScript:@"document.title"
                            completionHandler:^(id t, NSError *e2){
                                title = [t description]; done = YES; }];
                    } else if ([deadline timeIntervalSinceNow] > 0) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                            (int64_t)(0.15 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), weakPoll);
                    } else { done = YES; }
                }];
        };
        poll();

        while (!done && [deadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

        printf("Rendered #content children: %d\n", childCount);
        printf("document.title: %s\n", title ? title.UTF8String : "(none)");

        ListClose(pw);
        printf("ListCloseWindow OK\n");

        if (childCount > 0) { printf("RESULT: PASS\n"); return 0; }
        printf("RESULT: FAIL\n"); return 1;
    }
}
