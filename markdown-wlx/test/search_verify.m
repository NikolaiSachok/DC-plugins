/* Regression net for the ListSearchTextW export.
 *
 * Double Commander only enables Find / Find Next / Find Previous in its viewer
 * when the plugin exports a search entry point (TWlxModule.CanSearch in
 * uwlxmodule.pas); without one, searching a rendered Markdown file meant
 * switching to Text mode first.
 *
 * This loads the real .wlx into a parent view standing in for DC's viewer, calls
 * ListSearchTextW with the flags DC's DoSearch passes (lcs_findfirst from the
 * Find dialog, then plain Find Next / lcs_backwards for Find Previous, plus
 * lcs_matchcase), and asserts which piece of rendered text ends up selected.
 *
 * Note this is a regression net, not proof: per the charter, confirm F7 / Cmd+F
 * in a real Double Commander. */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>

typedef void *HWND;
typedef uint16_t WCHAR;
typedef HWND (*ListLoad_t)(HWND, char *, int);
typedef int  (*ListSearchTextW_t)(HWND, WCHAR *, int);

#define LISTPLUGIN_OK    0
#define LISTPLUGIN_ERROR 1
#define lcs_findfirst    1
#define lcs_matchcase    2
#define lcs_backwards    8

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

static void PollJS(WKWebView *web, NSString *js, int attemptsLeft, void (^then)(BOOL)) {
    if (attemptsLeft <= 0) { then(NO); return; }
    [web evaluateJavaScript:js completionHandler:^(id result, NSError *err) {
        (void)err;
        if ([result respondsToSelector:@selector(boolValue)] && [result boolValue]) { then(YES); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{ PollJS(web, js, attemptsLeft - 1, then); });
    }];
}

/* What is selected now: the text, the block it sits in, and the scroll offset. */
static NSString *const kSelectionJS =
    @"(function(){var s=window.getSelection();var t=s?s.toString():'';"
     @"var n=s&&s.rangeCount?s.getRangeAt(0).startContainer:null;"
     @"var el=n&&(n.nodeType===1?n:n.parentElement);"
     @"var blk=el&&el.closest('p,h1,h2,li,div');"
     @"return JSON.stringify({text:t,block:blk?(blk.id||blk.textContent):'',"
     @"y:Math.round(window.scrollY)});})()";

typedef struct { const char *what; const char *needle; int flags;
                 const char *text; const char *block; int scrolled; int then; } Step;
/* scrolled: 1 = must be scrolled down, 0 = must be at the top, -1 = don't care.
 * then: flags for a second search issued straight after the first, without
 * waiting (-1 = none) — Find Previous pressed while the fresh search is in flight. */

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: search_verify <plugin.wlx> <search.md>\n"); return 2; }

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
    ListLoad_t ListLoad = (ListLoad_t)dlsym(h, "ListLoad");
    ListSearchTextW_t Search = (ListSearchTextW_t)dlsym(h, "ListSearchTextW");
    if (!ListLoad) { fprintf(stderr, "missing ListLoad\n"); return 2; }
    if (!Search) {
        printf("RESULT: FAIL (ListSearchTextW not exported — DC hides Find for this plugin)\n");
        return 1;
    }

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 400)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView *dc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 400)];
    win.contentView = dc;

    HWND pw = ListLoad((__bridge HWND)dc, argv[2], 0);
    if (!pw) { fprintf(stderr, "ListLoad returned NULL\n"); return 2; }
    [win makeKeyAndOrderFront:nil];

    WKWebView *web = FindWebView((__bridge NSView *)pw);
    if (!web) { fprintf(stderr, "no WKWebView in the plugin view\n"); return 2; }

    static const Step steps[] = {
        { "Find: first hit from the top",          "needle", lcs_findfirst, "needle", "The first",  0, -1 },
        { "Find Next: second hit, scrolled to it", "needle", 0,             "needle", "The second", 1, -1 },
        { "Find Next: wraps back to the first",    "needle", 0,             "needle", "The first",  0, -1 },
        { "Find Previous: wraps to the last",      "needle", lcs_backwards, "needle", "The second", 1, -1 },
        { "Find backwards from scratch: last hit", "needle", lcs_findfirst | lcs_backwards,
                                                                            "needle", "The second", 1, -1 },
        { "Case-insensitive by default",           "HAYSTACK", lcs_findfirst, "Haystack", "Case matters", -1, -1 },
        { "Match case skips the other spelling",   "haystack", lcs_findfirst | lcs_matchcase,
                                                                            "haystack", "Case matters", -1, -1 },
        { "Match case with no hit selects nothing","HAYSTACK", lcs_findfirst | lcs_matchcase,
                                                                            "",         "",             -1, -1 },
        { "Non-ASCII needle (UTF-16 in)",          "grüße", lcs_findfirst,  "Grüße",  "Non-ASCII",  -1, -1 },
        { "Fresh search then an instant Find Prev", "needle", lcs_findfirst, "needle", "The second", 1, lcs_backwards },
        /* The version badge is page chrome, not the document. */
        { "Version badge is not a hit",            "MarkdownView v", lcs_findfirst, "", "",        -1, -1 },
    };
    const int nSteps = (int)(sizeof steps / sizeof steps[0]);

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
        NSString *needle = [NSString stringWithUTF8String:st.needle];
        NSUInteger n = needle.length;
        WCHAR *buf = calloc(n + 1, sizeof(WCHAR));
        [needle getCharacters:buf range:NSMakeRange(0, n)];
        int rc = Search(pw, buf, st.flags);
        if (rc == LISTPLUGIN_OK && st.then >= 0) rc = Search(pw, buf, st.then);
        free(buf);
        if (rc != LISTPLUGIN_OK) { check(NO, st.what); next(i + 1); return; }

        /* The find is async IPC; give it (and the scroll) time to land. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            [web evaluateJavaScript:kSelectionJS completionHandler:^(id json, NSError *err) {
                NSDictionary *s = [json isKindOfClass:[NSString class]]
                    ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                      options:0 error:NULL] : nil;
                NSString *text  = s[@"text"] ?: @"";
                NSString *block = s[@"block"] ?: @"";
                long y = [s[@"y"] longValue];
                NSString *wantText  = [NSString stringWithUTF8String:st.text];
                NSString *wantBlock = [NSString stringWithUTF8String:st.block];
                BOOL ok = !err && [text isEqualToString:wantText] &&
                          (wantBlock.length ? [block hasPrefix:wantBlock] : block.length == 0) &&
                          (st.scrolled < 0 || (st.scrolled ? y > 0 : y == 0));
                check(ok, st.what);
                if (!ok) printf("    got text=\"%s\" block=\"%.40s\" y=%ld\n",
                                text.UTF8String, block.UTF8String, y);
                next(i + 1);
            }];
        });
    };

    next = runStep;

    NSString *rendered = @"(function(){var c=document.getElementById('content');"
                         @"return !!c&&c.textContent.indexOf('second needle')>=0;})()";
    PollJS(web, rendered, 60, ^(BOOL ok) {
        printf("ListSearchTextW:\n");
        check(ok, "document rendered before searching");
        if (!ok) { finish(); return; }

        WCHAR empty[] = { 0 }, x[] = { 'x', 0 };
        check(Search(pw, empty, lcs_findfirst) == LISTPLUGIN_ERROR, "empty needle returns LISTPLUGIN_ERROR");
        check(Search(NULL, x, lcs_findfirst) == LISTPLUGIN_ERROR, "NULL window returns LISTPLUGIN_ERROR");
        runStep(0);
    });

    [app run];
    return gFailures ? 1 : 0;
}}
