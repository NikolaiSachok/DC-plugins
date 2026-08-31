/* Verify the vendored libraries load no matter where the .wlx is installed.
 *
 * The regression this guards: assets used to be referenced as file:// URLs, and
 * WebKit's WebContent process is sandboxed out of DC's own user-plugin
 * directory (~/Library/Preferences/doublecmd/plugins). Every <script> 404'd
 * there and the preview showed only
 * "ReferenceError: Can't find variable: marked".
 *
 * So the harness does not test the plugin where it was built — it copies the
 * built artifact plus its assets into that denied directory, loads *that* copy,
 * and asserts the libraries are defined and the document actually rendered.
 */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>
typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { printf("usage: assets_verify <MarkdownView.wlx> <file.md>\n"); return 2; }
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *src    = [[NSString stringWithUTF8String:argv[1]] stringByStandardizingPath];
    NSString *srcDir = [src stringByDeletingLastPathComponent];

    /* The directory WebKit refuses to read — where DC actually installs plugins. */
    NSString *sandboxed = [NSString stringWithFormat:@"%@/Library/Preferences/dc-mdv-assettest-%d",
                           NSHomeDirectory(), getpid()];
    [fm removeItemAtPath:sandboxed error:NULL];
    if (![fm createDirectoryAtPath:sandboxed withIntermediateDirectories:YES
                        attributes:nil error:NULL]) {
        printf("RESULT: FAIL (cannot create %s)\n", sandboxed.UTF8String);
        return 1;
    }
    NSString *wlx = [sandboxed stringByAppendingPathComponent:src.lastPathComponent];
    BOOL staged = [fm copyItemAtPath:src toPath:wlx error:NULL] &&
                  [fm copyItemAtPath:[srcDir stringByAppendingPathComponent:@"assets"]
                              toPath:[sandboxed stringByAppendingPathComponent:@"assets"]
                               error:NULL];
    if (!staged) {
        [fm removeItemAtPath:sandboxed error:NULL];
        printf("RESULT: FAIL (cannot stage plugin + assets)\n");
        return 1;
    }
    /* An allowed-extension file *outside* assets/, to prove the handler will not
     * be walked out of its directory with a "../". */
    [@"window.__ESCAPED = 1;" writeToFile:[sandboxed stringByAppendingPathComponent:@"outside.js"]
                               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSLog(@"STAGED: %@", wlx);

    void *h = dlopen(wlx.fileSystemRepresentation, RTLD_NOW);
    ListLoad_t ListLoad = h ? (ListLoad_t)dlsym(h, "ListLoad") : NULL;
    if (!ListLoad) {
        [fm removeItemAtPath:sandboxed error:NULL];
        printf("RESULT: FAIL (dlopen: %s)\n", dlerror());
        return 1;
    }

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 700)
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered defer:NO];
    HWND pw = ListLoad((__bridge HWND)win.contentView, argv[2], 0);
    WKWebView *web = nil;
    for (NSView *v in ((__bridge NSView *)pw).subviews)
        if ([v isKindOfClass:[WKWebView class]]) web = (WKWebView *)v;

    __block BOOL done = NO, libsOK = NO, contained = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *js = @"[typeof marked, typeof DOMPurify, typeof hljs,"
                        "document.getElementById('content').innerHTML.indexOf('ReferenceError')].join('|')";
        [web evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
            NSString *got = [r description] ?: [e description];
            NSLog(@"LIBS: %@", got);
            libsOK = ![got containsString:@"undefined"] && [got hasSuffix:@"|-1"];

            /* The traversal probe: a real .js one level up must not be served.
             * The ".." is percent-encoded so the URL parser cannot normalize it
             * away before the request reaches the handler — the handler itself
             * is what has to refuse it. */
            NSString *probe = @"return new Promise(function(res){var s=document.createElement('script');"
                               "s.src='x-mdview:///%2e%2e/outside.js';"
                               "s.onload=function(){res('served:'+(window.__ESCAPED||0));};"
                               "s.onerror=function(){res('refused');};"
                               "document.head.appendChild(s);})";
            [web callAsyncJavaScript:probe arguments:nil inFrame:nil
                       inContentWorld:WKContentWorld.pageWorld
                    completionHandler:^(id r2, NSError *e2) {
                NSString *got2 = [r2 description] ?: [e2 description];
                NSLog(@"TRAVERSAL: %@", got2);
                contained = [got2 isEqualToString:@"refused"];
                done = YES;
            }];
        }];
    });

    NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:8];
    while (!done && [dl timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

    [fm removeItemAtPath:sandboxed error:NULL];
    if (!libsOK) {
        printf("RESULT: FAIL (libraries missing — assets are not reaching the page)\n");
        return 1;
    }
    if (!contained) {
        printf("RESULT: FAIL (handler served a file outside assets/)\n");
        return 1;
    }
    printf("RESULT: PASS (libraries load from a WebKit-denied directory; handler stays in assets/)\n");
    return 0;
}}
