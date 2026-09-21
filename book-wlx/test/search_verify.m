/* Regression net for the ListSearchTextW export.
 *
 * Double Commander only enables Find / Find Next / Find Previous in its viewer
 * when the plugin exports a search entry point (TWlxModule.CanSearch in
 * uwlxmodule.pas); without one, an open book could not be searched at all.
 *
 * This loads the real .wlx into a parent view standing in for DC's viewer, calls
 * ListSearchTextW with the flags DC's DoSearch passes (lcs_findfirst from the
 * Find dialog, then plain Find Next, lcs_backwards for Find Previous, plus
 * lcs_matchcase), and asserts which piece of text ends up selected. What it pins
 * down beyond a plain port of the markdown-wlx harness:
 *
 *   - the first search is issued the instant the book is opened, before a
 *     single chapter is in, and must still find text in the LAST chapter;
 *   - the title bar, contents sidebar and version badge are never a hit, even
 *     though the book title, author and chapter titles all appear there first;
 *   - a hit is scrolled into view below the fixed title bar, not under it;
 *   - searches cross chapters, wrap, and a reloaded book (ListLoadNext) is
 *     searched afresh.
 *
 * Note this is a regression net, not proof: per the charter, confirm F7 / Cmd+F
 * in a real Double Commander. */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>

typedef void *HWND;
typedef uint16_t WCHAR;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef int  (*ListLoadNext_t)(HWND, HWND, char *, int);
typedef int  (*ListSearchTextW_t)(HWND, WCHAR *, int);

#define LISTPLUGIN_OK    0
#define LISTPLUGIN_ERROR 1
#define lcs_findfirst    1
#define lcs_matchcase    2
#define lcs_backwards    8

#define BAR_HEIGHT       40   /* #bar in reader.css */

static int gFailures = 0;

static void check(BOOL cond, const char *what) {
    printf("  %-60s %s\n", what, cond ? "ok" : "FAILED");
    if (!cond) gFailures++;
}

static WKWebView *FindWebView(NSView *root) {
    if ([root isKindOfClass:[WKWebView class]]) return (WKWebView *)root;
    for (NSView *v in root.subviews) {
        WKWebView *found = FindWebView(v);
        if (found) return found;
    }
    return nil;
}

/* What is selected now: the text, the block it sits in, and whether the hit is
 * actually visible — inside the viewport and below the fixed title bar. */
static NSString *const kSelectionJS =
    @"(function(){var s=window.getSelection();var t=s?s.toString():'';"
     @"var r=s&&s.rangeCount?s.getRangeAt(0):null;"
     @"var n=r?r.startContainer:null;"
     @"var el=n&&(n.nodeType===1?n:n.parentElement);"
     @"var blk=el&&el.closest('p,h1,h2,li,div,nav,header');"
     @"var b=r?r.getBoundingClientRect():null;"
     @"return JSON.stringify({text:t,block:blk?(blk.id||blk.textContent.trim()):'',"
     @"visible:!!b&&b.height>0&&b.top>=%d&&b.bottom<=window.innerHeight});})()";

typedef struct {
    const char *what;
    const char *load;    /* book to ListLoadNext before searching (relative to the
                          * samples dir, or absolute), or NULL */
    const char *needle;
    int flags;
    int then;            /* flags for a second search issued straight after the
                          * first without waiting, or -1: Find Previous pressed
                          * while the fresh search is still in flight */
    const char *text;    /* expected selection; "" = nothing selected (a miss) */
    const char *block;   /* expected block: its id, or a prefix of its text */
} Step;

static void SearchFor(ListSearchTextW_t Search, HWND pw, const char *utf8, int flags) {
    NSString *needle = [NSString stringWithUTF8String:utf8];
    NSUInteger n = needle.length;
    WCHAR *buf = calloc(n + 1, sizeof(WCHAR));
    [needle getCharacters:buf range:NSMakeRange(0, n)];
    if (Search(pw, buf, flags) != LISTPLUGIN_OK) check(NO, "ListSearchTextW returns LISTPLUGIN_OK");
    free(buf);
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: search_verify <BookView.wlx> <samples dir>\n"); return 2; }

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
    ListLoad_t ListLoad = (ListLoad_t)dlsym(h, "ListLoad");
    ListLoadNext_t ListLoadNext = (ListLoadNext_t)dlsym(h, "ListLoadNext");
    ListSearchTextW_t Search = (ListSearchTextW_t)dlsym(h, "ListSearchTextW");
    if (!ListLoad || !ListLoadNext) { fprintf(stderr, "missing ListLoad/ListLoadNext\n"); return 2; }
    if (!Search) {
        printf("RESULT: FAIL (ListSearchTextW not exported — DC hides Find for this plugin)\n");
        return 1;
    }
    NSString *dir = [NSString stringWithUTF8String:argv[2]];
    /* Any file that is neither an EPUB nor a FictionBook — the plugin itself. */
    NSString *notABook = [NSString stringWithUTF8String:argv[1]];

    /* Wide enough that the contents sidebar is open, as in a typical viewer. */
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 420)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView *dc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 420)];
    win.contentView = dc;
    [win makeKeyAndOrderFront:nil];

    NSString *first = [dir stringByAppendingPathComponent:@"sample3.epub"];
    HWND pw = ListLoad((__bridge HWND)dc, (char *)first.fileSystemRepresentation, 0);
    if (!pw) { fprintf(stderr, "ListLoad returned NULL\n"); return 2; }
    WKWebView *web = FindWebView((__bridge NSView *)pw);
    if (!web) { fprintf(stderr, "no WKWebView in the plugin view\n"); return 2; }

    printf("ListSearchTextW:\n");
    WCHAR empty[] = { 0 }, x[] = { 'x', 0 };
    check(Search(pw, empty, lcs_findfirst) == LISTPLUGIN_ERROR, "empty needle returns LISTPLUGIN_ERROR");
    check(Search(NULL, x, lcs_findfirst) == LISTPLUGIN_ERROR, "NULL window returns LISTPLUGIN_ERROR");

    /* sample3.epub is "The Wandering Lamp" by Marguerite Vance: three chapters,
     * The Harbour / The Ledger / The Lamp, listed in the contents sidebar. */
    static const Step steps[] = {
        { "Searched on open: hit in the last chapter", NULL, "wandered", lcs_findfirst, -1,
          "wandered", "The lamp had wandered" },
        { "Title bar is not a hit (book title)",       NULL, "Wandering", lcs_findfirst | lcs_matchcase, -1,
          "Wandering", "colophon" },
        { "Title bar is not a hit (author)",           NULL, "Vance", lcs_findfirst, -1,
          "Vance", "colophon" },
        { "Contents sidebar is not a hit",             NULL, "Ledger", lcs_findfirst | lcs_matchcase, -1,
          "Ledger", "c2" /* the chapter heading */ },
        { "Match case skips the other spelling",       NULL, "ledger", lcs_findfirst | lcs_matchcase, -1,
          "ledger", "Every page of the ledger" },
        { "Case-insensitive fresh search",             NULL, "LAMP", lcs_findfirst, -1,
          "lamp", "one lamp, wandering" },
        { "Find Next: across into the next chapter",   NULL, "lamp", 0, -1,
          "Lamp", "c3" },
        { "Find Next: next hit in the chapter",        NULL, "lamp", 0, -1,
          "lamp", "The lamp had wandered" },
        { "Find Next: on into the colophon",           NULL, "lamp", 0, -1,
          "Lamp", "colophon" },
        { "Find Next: wraps to the first hit",         NULL, "lamp", 0, -1,
          "lamp", "one lamp, wandering" },
        { "Find Previous: wraps back to the last",     NULL, "lamp", lcs_backwards, -1,
          "Lamp", "colophon" },
        { "Fresh search then an instant Find Prev",    NULL, "lamp", lcs_findfirst, lcs_backwards,
          "Lamp", "colophon" },
        { "Version badge is not a hit",                NULL, "BookView v", lcs_findfirst, -1, "", "" },
        { "Toolbar buttons are not a hit",             NULL, "A+", lcs_findfirst, -1, "", "" },
        { "After ListLoadNext: the new book, UTF-16",  "sample.fb2", "дёготь", lcs_findfirst, -1,
          "дёготь", "Соль, дёготь" },
        /* Not a book: the plugin shows why it can't open it. A search there
         * must run against that page rather than wait for chapters forever... */
        { "Error page is searched, not waited on",     "@notabook", "open", lcs_findfirst, -1,
          "open", "Can't open this book" },
        /* ...and must not leave later searches stuck behind it. */
        { "Searching works again after the error page", "sample3.epub", "wandered", lcs_findfirst, -1,
          "wandered", "The lamp had wandered" },
    };
    const int nSteps = (int)(sizeof steps / sizeof steps[0]);
    NSString *selJS = [NSString stringWithFormat:kSelectionJS, BAR_HEIGHT];

    void (^finish)(void) = ^{
        printf(gFailures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", gFailures);
        [app stop:nil];
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
            location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
            context:nil subtype:0 data1:0 data2:0] atStart:YES];
    };

    /* Weak self-reference: the chain recurses through dispatch callbacks, and
     * `runStep` itself stays alive on main's stack for the whole [app run]. */
    __block __weak void (^next)(int);
    void (^runStep)(int) = ^(int i) {
        if (i >= nSteps) { finish(); return; }
        Step st = steps[i];
        if (st.load) {
            BOOL bad = !strcmp(st.load, "@notabook");
            NSString *p = bad ? notABook
                : [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:st.load]];
            int rc = ListLoadNext((__bridge HWND)dc, pw, (char *)p.fileSystemRepresentation, 0);
            check(rc == (bad ? LISTPLUGIN_ERROR : LISTPLUGIN_OK),
                  bad ? "ListLoadNext on a non-book returns LISTPLUGIN_ERROR"
                      : "ListLoadNext returns LISTPLUGIN_OK");
        }
        /* Issued immediately, even right after a (re)load: the plugin must wait
         * for the book itself, not rely on the caller to. */
        SearchFor(Search, pw, st.needle, st.flags);
        if (st.then >= 0) SearchFor(Search, pw, st.needle, st.then);

        /* The find is async; give it (and the scroll) time to land. The first
         * search also waits for the whole book to load. */
        double wait = (i == 0 || st.load) ? 2.5 : 0.6;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            [web evaluateJavaScript:selJS completionHandler:^(id json, NSError *err) {
                NSDictionary *s = [json isKindOfClass:[NSString class]]
                    ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                      options:0 error:NULL] : nil;
                NSString *text  = s[@"text"] ?: @"";
                NSString *block = s[@"block"] ?: @"";
                BOOL visible = [s[@"visible"] boolValue];
                NSString *wantText  = [NSString stringWithUTF8String:st.text];
                NSString *wantBlock = [NSString stringWithUTF8String:st.block];
                BOOL miss = wantText.length == 0;
                BOOL ok = !err && [text isEqualToString:wantText] &&
                          (miss ? block.length == 0 : ([block hasPrefix:wantBlock] && visible));
                check(ok, st.what);
                if (!ok) printf("    got text=\"%s\" block=\"%.40s\" visible=%d\n",
                                text.UTF8String, block.UTF8String, visible);
                next(i + 1);
            }];
        });
    };
    next = runStep;
    runStep(0);

    [app run];
    return gFailures ? 1 : 0;
}}
