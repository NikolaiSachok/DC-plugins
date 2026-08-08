/*
 * End-to-end harness for EpubView.wlx.
 *
 * dlopens the REAL built plugin and drives the WLX ABI exactly as Double
 * Commander does — ListGetDetectString, ListLoad, ListLoadNext, ListCloseWindow
 * — then asserts against the live DOM inside the plugin's own WKWebView.
 *
 * GUI-bound (WebKit needs a run loop), so this runs locally rather than on a
 * headless CI runner. See zip_test.c for the part CI can run.
 *
 *   ./build/test_host build/EpubView.wlx build/samples
 */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef int  (*ListLoadNext_t)(HWND, HWND, char *, int);
typedef void (*ListCloseWindow_t)(HWND);
typedef void (*ListGetDetectString_t)(char *, int);

static int gFailures = 0;

static void check(BOOL cond, NSString *what) {
    printf("  %s %s\n", cond ? "ok  " : "FAIL", what.UTF8String);
    if (!cond) gFailures++;
}

static void pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([until timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

/* Evaluate JS in the plugin's web view and block (pumping the run loop) for it. */
static id runJS(WKWebView *web, NSString *src) {
    __block id result = nil;
    __block BOOL done = NO;
    [web evaluateJavaScript:src completionHandler:^(id r, NSError *e) {
        result = e ? [NSString stringWithFormat:@"JSERROR: %@", e.localizedDescription] : r;
        done = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return result;
}

/* Wait until `expr` evaluates truthy, or give up. */
static BOOL waitFor(WKWebView *web, NSString *expr, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        id v = runJS(web, expr);
        if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) return YES;
        pump(0.1);
    }
    return NO;
}

static WKWebView *webViewIn(NSView *plugin) {
    for (NSView *v in plugin.subviews)
        if ([v isKindOfClass:[WKWebView class]]) return (WKWebView *)v;
    return nil;
}

static NSString *str(id v) { return [v isKindOfClass:[NSString class]] ? v : [v description]; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: test_host <EpubView.wlx> <samples dir>\n");
            return 2;
        }
        [NSApplication sharedApplication];

        void *lib = dlopen(argv[1], RTLD_NOW);
        if (!lib) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }

        ListLoad_t            ListLoad            = dlsym(lib, "ListLoad");
        ListLoadNext_t        ListLoadNext        = dlsym(lib, "ListLoadNext");
        ListCloseWindow_t     ListCloseWindow     = dlsym(lib, "ListCloseWindow");
        ListGetDetectString_t ListGetDetectString = dlsym(lib, "ListGetDetectString");

        printf("ABI\n");
        check(ListLoad && ListLoadNext && ListCloseWindow && ListGetDetectString,
              @"all WLX entry points resolve");
        if (!ListLoad) return 2;

        char detect[512] = {0};
        ListGetDetectString(detect, sizeof(detect));
        check(strcmp(detect, "EXT=\"EPUB\"") == 0,
              [NSString stringWithFormat:@"detect string is EXT=\"EPUB\" (got %s)", detect]);

        NSString *dir = [NSString stringWithUTF8String:argv[2]];
        NSString *three = [dir stringByAppendingPathComponent:@"sample3.epub"];
        NSString *two   = [dir stringByAppendingPathComponent:@"sample2.epub"];

        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 1000, 900)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];

        HWND pluginWin = ListLoad((__bridge HWND)win.contentView,
                                  (char *)three.UTF8String, 0);
        check(pluginWin != NULL, @"ListLoad returns a window handle");
        if (!pluginWin) return 2;

        NSView *pluginView = (__bridge NSView *)pluginWin;
        WKWebView *web = webViewIn(pluginView);
        check(web != nil, @"plugin view hosts a WKWebView");
        check(pluginView.superview == win.contentView, @"plugin view is added to the parent");

        printf("\nEPUB 3 book (nav TOC, cover, hostile chapter)\n");
        BOOL ready = waitFor(web, @"document.querySelectorAll('.chapter').length === 3 &&"
                                  @"!!document.getElementById('colophon')", 20);
        check(ready, @"all three spine documents render");

        check([str(runJS(web, @"document.getElementById('book-title').textContent"))
                  isEqualToString:@"The Wandering Lamp"], @"title comes from the OPF metadata");
        check([str(runJS(web, @"document.getElementById('book-author').textContent"))
                  isEqualToString:@"Marguerite Vance"], @"author comes from the OPF metadata");
        check([runJS(web, @"document.querySelectorAll('#toc-list a').length") intValue] == 4,
              @"nav document yields 4 TOC entries");
        check([runJS(web, @"document.querySelectorAll('#toc-list li[data-depth=\"1\"]').length") intValue] == 1,
              @"nested TOC level is preserved");

        check([runJS(web, @"(document.querySelector('#cover img')||{}).naturalWidth") intValue] == 120,
              @"cover image loads over x-epub://");
        check([runJS(web, @"(document.querySelector('.chapter img[alt=\"A plate\"]')||{}).naturalWidth") intValue] == 64,
              @"an inline chapter image loads");
        check([runJS(web, @"!!document.querySelector('.chapter figcaption')") boolValue],
              @"figure/figcaption survive sanitising");
        check([runJS(web, @"!!document.querySelector('.chapter table th')") boolValue],
              @"tables survive sanitising");

        printf("\nuntrusted content is neutralised\n");
        check([runJS(web, @"typeof window.PWNED === 'undefined'") boolValue],
              @"no script from the book executed");
        check([runJS(web, @"document.querySelectorAll('.chapter script, .chapter iframe').length") intValue] == 0,
              @"script and iframe elements are stripped");
        check([runJS(web, @"document.querySelectorAll('.chapter [onerror], .chapter [onclick]').length") intValue] == 0,
              @"inline event handlers are stripped");
        check([runJS(web, @"[...document.querySelectorAll('.chapter [src]')]"
                          @".every(e => e.getAttribute('src').startsWith('x-epub:'))") boolValue],
              @"every remaining resource points inside the book");
        check([runJS(web, @"[...document.querySelectorAll('.chapter a')]"
                          @".every(a => !a.getAttribute('href') ||"
                          @"           a.getAttribute('href').startsWith('x-epub:'))") boolValue],
              @"outside links lose their href but keep their text");
        check([runJS(web, @"!!document.querySelector('.chapter a[data-link]')") boolValue],
              @"an in-book link is marked for in-page navigation");

        printf("\nreader chrome\n");
        check([runJS(web, @"getComputedStyle(document.documentElement)"
                          @".getPropertyValue('--font-size').trim()") length] > 0,
              @"typography variables are applied");
        check([str(runJS(web, @"document.getElementById('percent').textContent")) hasSuffix:@"%"],
              @"reading progress is reported");
        BOOL tocWasOpen = [runJS(web, @"document.documentElement.classList.contains('toc-open')") boolValue];
        check(tocWasOpen, @"the sidebar starts open on a wide window");
        runJS(web, @"document.getElementById('toc-toggle').click()");
        check([runJS(web, @"document.documentElement.classList.contains('toc-open')") boolValue] != tocWasOpen,
              @"the contents button toggles the sidebar");
        runJS(web, @"document.getElementById('toc-toggle').click()");
        runJS(web, @"document.querySelectorAll('#toc-list a')[2].click()");
        pump(0.4);
        check([runJS(web, @"window.scrollY > 0") boolValue],
              @"clicking a TOC entry scrolls into the book");

        printf("\nEPUB 2 book via ListLoadNext (NCX TOC, windows-1251)\n");
        int rc = ListLoadNext((__bridge HWND)win.contentView, pluginWin,
                              (char *)two.UTF8String, 0);
        check(rc == 0, @"ListLoadNext reports success");
        BOOL ready2 = waitFor(web, @"document.querySelectorAll('.chapter').length === 2 &&"
                                   @"!!document.getElementById('colophon')", 20);
        check(ready2, @"the second book replaces the first");
        check([str(runJS(web, @"document.getElementById('book-title').textContent"))
                  isEqualToString:@"A Ledger of Small Weights"], @"the new book's title is shown");
        check([runJS(web, @"document.querySelectorAll('#toc-list a').length") intValue] == 3,
              @"NCX navMap yields 3 TOC entries");
        check([runJS(web, @"document.body.textContent.includes('Вторая глава')") boolValue],
              @"a windows-1251 chapter is decoded correctly");
        check([runJS(web, @"document.body.textContent.includes('The Lamp')") boolValue] == NO,
              @"no content from the previous book survives");

        printf("\nteardown\n");
        ListCloseWindow(pluginWin);
        pump(0.3);
        check(pluginView.superview == nil, @"ListCloseWindow removes the view");

        printf("\n%s\n", gFailures ? "FAILURES" : "all EpubView checks passed");
    }
    return gFailures ? 1 : 0;
}
