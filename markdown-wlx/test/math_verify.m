/* Regression net for the KaTeX delimiter handling (#23).
 *
 * marked treats \( \) \[ \] as backslash escapes for punctuation and emits a bare
 * ( or [, so by the time KaTeX's auto-render walks the DOM the delimiter it is
 * looking for is gone and only $$…$$ ever rendered. This asserts all three pairs
 * produce real .katex nodes, in paragraphs, lists and tables — and that the two
 * things which must NOT become math still don't.
 *
 * Loads the real built .wlx and inspects the live DOM, like the other harnesses. */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>

typedef void *HWND;
typedef HWND (*ListLoad_t)(HWND, char *, int);

static int gFailures = 0;

static void check(BOOL cond, const char *what) {
    printf("  %-56s %s\n", what, cond ? "ok" : "FAILED");
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

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: math_verify <plugin.wlx> <math.md>\n"); return 2; }

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
    ListLoad_t ListLoad = (ListLoad_t)dlsym(h, "ListLoad");
    if (!ListLoad) { fprintf(stderr, "missing ListLoad\n"); return 2; }

    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 700)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView *dc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 700)];
    win.contentView = dc;

    HWND pw = ListLoad((__bridge HWND)dc, argv[2], 0);
    if (!pw) { fprintf(stderr, "ListLoad returned NULL\n"); return 2; }
    [win makeKeyAndOrderFront:nil];

    WKWebView *web = FindWebView((__bridge NSView *)pw);
    if (!web) { fprintf(stderr, "no WKWebView in the plugin view\n"); return 2; }

    void (^finish)(void) = ^{
        printf(gFailures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", gFailures);
        [app stop:nil];
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
            location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
            context:nil subtype:0 data1:0 data2:0] atStart:YES];
    };

    /* KaTeX runs after marked; wait for it to have produced at least one node. */
    NSString *ready = @"(function(){var c=document.getElementById('content');"
                      @"return !!c&&c.children.length>0&&!!document.querySelector('.katex');})()";

    NSString *probe =
        @"(function(){var c=document.getElementById('content');"
        @"var t=c.innerText;"
        @"function inSel(sel){var e=c.querySelector(sel);return !!e&&!!e.querySelector('.katex');}"
        @"return JSON.stringify({"
        @"  katex:      c.querySelectorAll('.katex').length,"
        @"  display:    c.querySelectorAll('.katex-display').length,"
        @"  inList:     inSel('li'),"
        @"  inTable:    inSel('td'),"
        @"  bareParen:  t.indexOf('a^2+b^2=c^2')>=0,"
        @"  bareBrack:  t.indexOf('e^{i\\\\pi}+1=0')>=0,"
        @"  literal:    t.indexOf('\\\\(not math\\\\)')>=0,"
        @"  codespan:   !!Array.prototype.find.call(c.querySelectorAll('code'),"
        @"                function(e){return e.textContent.indexOf('code not math')>=0;}),"
        @"  dollars:    t.indexOf('$5 to $10')>=0,"
        @"  shellPid:   t.indexOf('use $$ for the pid')>=0,"
        @"  codeIntact: !!Array.prototype.find.call(c.querySelectorAll('code'),"
        @"                function(e){return e.textContent==='echo $$';}),"
        @"  footnote:   t.indexOf('footnote [1] and reference [2]')>=0,"
        @"  regexProse: t.indexOf('match (a group) and later a literal (second group)')>=0,"
        @"  rawHtml:    (function(){var d=c.querySelector('div[align=\"center\"]');"
        @"                return !!d&&d.querySelectorAll('.katex').length===2;})(),"
        @"  padded:     t.indexOf('Padded display math: $$')<0"
        @"              &&t.indexOf('bare numbers $$')<0,"
        @"  glued:      t.indexOf('the file(s) to open')>=0,"
        @"  labels:     t.indexOf('[TODO] and [x] stay literal')>=0,"
        @"  preIntact:  (function(){var e=c.querySelector('pre code');"
        @"                return !!e&&e.textContent.indexOf('$$E=mc^2$$')>=0"
        @"                       &&e.querySelectorAll('.katex').length===0;})(),"
        @"  attrIntact: (function(){var d=c.querySelector('div[title]');"
        @"                return !!d&&d.getAttribute('title')==='a > b'"
        @"                       &&d.querySelectorAll('.katex').length===1;})(),"
        @"  inlineRaw:  (function(){var e=Array.prototype.filter.call("
        @"                c.querySelectorAll('code'),function(x){"
        @"                  return x.textContent==='$$E=mc^2$$';});"
        @"                var k=c.querySelector('kbd');"
        @"                return e.length===1"
        @"                       &&e[0].querySelectorAll('.katex').length===0"
        @"                       &&!!k&&k.querySelectorAll('.katex').length===0;})(),"
        @"  ltHidesPre: (function(){"
        @"                var all=Array.prototype.filter.call(c.querySelectorAll('pre'),"
        @"                  function(x){return x.textContent.indexOf('F=ma')>=0;});"
        @"                return all.length===1"
        @"                       &&all[0].textContent.indexOf('$$F=ma$$')>=0"
        @"                       &&all[0].querySelectorAll('.katex').length===0;})(),"
        @"  ltInMath:   (function(){var d=Array.prototype.filter.call("
        @"                c.querySelectorAll('div[align=\"center\"]'),function(x){"
        @"                  return x.textContent.indexOf('both render')>=0;});"
        @"                return d.length===1&&d[0].querySelectorAll('.katex').length===2"
        @"                       &&d[0].textContent.indexOf('$$')<0;})(),"
        @"  kbdBlock:   (function(){var k=c.querySelector('kbd');"
        @"                var all=Array.prototype.filter.call(c.querySelectorAll('kbd'),"
        @"                  function(x){return x.textContent.indexOf('k^2')>=0;});"
        @"                return all.length===1"
        @"                       &&all[0].querySelectorAll('.katex').length===0"
        @"                       &&all[0].textContent.indexOf('$$k^2$$')>=0;})(),"
        @"  unicodeGlue: t.indexOf('fich\u00e9(s) and \u0444\u0430\u0439\u043b(\u044b) stay text')>=0"
        @"});})()";

    PollJS(web, ready, 60, ^(BOOL ok) {
        printf("KaTeX delimiters:\n");
        if (!ok) {
            check(NO, "any math rendered at all");
            [web evaluateJavaScript:@"document.getElementById('content').innerText"
                  completionHandler:^(id r, NSError *e) {
                (void)e;
                printf("  content was: %.300s\n", [[r description] UTF8String]);
                finish();
            }];
            return;
        }
        [web evaluateJavaScript:probe completionHandler:^(id r, NSError *e) {
            (void)e;
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:
                [[r description] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            if (!d) { check(NO, "probe returned JSON"); finish(); return; }

            /* 3 in paragraphs, 2 in a list, 1 in a table, 2 in raw HTML,
             * 3 padded/bare dollar blocks, 1 in a titled div,
             * 1 after a literal <, 2 with < and > in a div = 15 */
            check([d[@"katex"] intValue] == 15,          "exactly the fifteen formulas render as .katex");
            /* \[…\] and $$…$$ are display; \(…\) is inline */
            check([d[@"display"] intValue] == 8,         "\\[…\\] and $$…$$ render as display math");
            check([d[@"inList"] boolValue],              "math inside a list item renders");
            check([d[@"inTable"] boolValue],             "math inside a table cell renders");
            check(![d[@"bareParen"] boolValue],          "\\(…\\) leaves no literal text behind");
            check(![d[@"bareBrack"] boolValue],          "\\[…\\] leaves no literal text behind");
            check([d[@"literal"] boolValue],             "an escaped \\\\(…\\\\) stays literal text");
            check([d[@"codespan"] boolValue],            "math delimiters inside a code span stay literal");
            check([d[@"dollars"] boolValue],             "prose dollar amounts are not eaten as math");
            check([d[@"shellPid"] boolValue],            "a $$ span that runs into a code span is rejected");
            check([d[@"codeIntact"] boolValue],          "a $$ scan never swallows an inline code span");
            check([d[@"footnote"] boolValue],            "\\[1\\] stays an escaped bracket, not display math");
            check([d[@"regexProse"] boolValue],          "\\(a group\\) stays escaped parens, not math");
            check([d[@"rawHtml"] boolValue],             "math inside a raw HTML block renders");
            check([d[@"padded"] boolValue],              "padded $$ x $$ and bare $$0$$ still render");
            check([d[@"glued"] boolValue],               "file\\(s\\) glued to a word stays an escape");
            check([d[@"labels"] boolValue],              "\\[TODO\\] and \\[x\\] stay literal labels");
            check([d[@"preIntact"] boolValue],           "raw HTML <pre><code> is shown, not rendered");
            check([d[@"attrIntact"] boolValue],          "a > inside an attribute value is not mis-split");
            check([d[@"inlineRaw"] boolValue],           "inline raw <code>/<kbd> is shown, not rendered");
            check([d[@"ltHidesPre"] boolValue],          "a literal < cannot hide a <pre> from the skip");
            check([d[@"ltInMath"] boolValue],            "$$x < y$$ renders inside a raw HTML block");
            check([d[@"kbdBlock"] boolValue],            "a block-level <kbd> is shown, not rendered");
            check([d[@"unicodeGlue"] boolValue],         "non-ASCII words glued to \\(s\\) stay text");

            if (gFailures) printf("  probe: %s\n", [[r description] UTF8String]);
            finish();
        }];
    });

    [app run];
    return gFailures ? 1 : 0;
}}
