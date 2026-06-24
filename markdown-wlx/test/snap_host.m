/* Render the .wlx output and dump innerHTML + a PNG snapshot. */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>
typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        void *h = dlopen(argv[1], RTLD_NOW);
        ListLoad_t ListLoad = (ListLoad_t)dlsym(h, "ListLoad");
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0,0,900,1200)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        HWND pw = ListLoad((__bridge HWND)win.contentView, argv[2], 0);
        WKWebView *web = nil;
        for (NSView *v in ((__bridge NSView *)pw).subviews)
            if ([v isKindOfClass:[WKWebView class]]) web = (WKWebView *)v;

        __block BOOL done = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            [web evaluateJavaScript:@"document.getElementById('content').innerHTML.slice(0,400)"
                completionHandler:^(id r, NSError *e){
                    printf("INNERHTML[0:400]:\n%s\n\n", [[r description] UTF8String]);
                    WKSnapshotConfiguration *cfg = [[WKSnapshotConfiguration alloc] init];
                    [web takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *img, NSError *se){
                        if (img) {
                            CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
                            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
                            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                            [png writeToFile:[NSString stringWithUTF8String:argv[3]] atomically:YES];
                            printf("Saved snapshot: %s\n", argv[3]);
                        } else printf("snapshot error: %s\n", se.description.UTF8String);
                        done = YES;
                    }];
                }];
        });
        NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:8];
        while (!done && [dl timeIntervalSinceNow]>0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return 0;
}
