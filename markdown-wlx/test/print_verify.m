/* Drive the real WLX printing ABI and real WebKit/AppKit pagination. Only the
 * sheet presentation is replaced: save to PDF instead of sending paper to a
 * printer. Real-host sheet/menu/cancellation verification is still required.
 * Usage: print_verify <plugin.wlx> <output-directory>
 */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <PDFKit/PDFKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include "../listplug.h"

typedef HWND (*LoadFn)(HWND, char *, int);
typedef int (*NextFn)(HWND, HWND, char *, int);
typedef void (*CloseFn)(HWND);
typedef int (*PrintFn)(HWND, WCHAR *, WCHAR *, int, ListPrintMargins *);
static int failures, presentations, completions;
static BOOL cancelNext;
static BOOL printSubset;
static NSString *outputDir;
static NSPrintInfo *lastInfo;
static NSString *lastTitle;
static IMP original;
static void check(BOOL ok, const char *what);

@interface PrintCompletion : NSObject
@property id target;
@property SEL callback;
@property void *context;
@end
@implementation PrintCompletion
- (void)didRun:(NSPrintOperation *)op success:(BOOL)ok contextInfo:(void *)context {
    PrintCompletion *keepAlive = CFBridgingRelease(context);
    dispatch_async(dispatch_get_main_queue(), ^{
        check(ok, "native WebKit print operation saved PDF");
        ((void (*)(id, SEL, NSPrintOperation *, BOOL, void *))objc_msgSend)
            (keepAlive.target, keepAlive.callback, op, ok, keepAlive.context);
        completions++;
    });
}
@end

static void check(BOOL ok, const char *what) {
    printf("  %-65s %s\n", what, ok ? "ok" : "FAILED");
    if (!ok) failures++;
}

static BOOL pump(BOOL (^done)(void), double seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return done();
}

static id js(WKWebView *web, NSString *source) {
    __block BOOL done = NO;
    __block id value;
    [web evaluateJavaScript:source completionHandler:^(id v, NSError *e) {
        if (!e) value = v;
        done = YES;
    }];
    pump(^BOOL{ return done; }, 10);
    return value;
}

static void saveInsteadOfSheet(NSPrintOperation *op, SEL cmd, NSWindow *window,
                              id delegate, SEL callback, void *context) {
    presentations++;
    lastInfo = [op.printInfo copy];
    lastTitle = op.jobTitle;
    if (!cancelNext) {
        op.showsPrintPanel = NO;
        op.showsProgressPanel = NO;
        op.printInfo.paperSize = NSMakeSize(595, 842); /* A4, reproducible pagination */
        NSString *path = [outputDir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"print-%d.pdf", presentations]];
        op.printInfo.jobDisposition = NSPrintSaveJob;
        op.printInfo.dictionary[NSPrintJobSavingURL] = [NSURL fileURLWithPath:path];
        if (printSubset) {
            op.printInfo.dictionary[NSPrintAllPages] = @NO;
            op.printInfo.dictionary[NSPrintFirstPage] = @2;
            op.printInfo.dictionary[NSPrintLastPage] = @3;
        }
        PrintCompletion *completion = [PrintCompletion new];
        completion.target = delegate;
        completion.callback = callback;
        completion.context = context;
        ((void (*)(id, SEL, NSWindow *, id, SEL, void *))original)
            (op, cmd, window, completion, @selector(didRun:success:contextInfo:),
             (void *)CFBridgingRetain(completion));
        return;
    }
    cancelNext = NO;
    ((void (*)(id, SEL, NSPrintOperation *, BOOL, void *))objc_msgSend)
        (delegate, callback, op, NO, context);
    completions++;
}

int main(int argc, char **argv) { @autoreleasepool {
    setbuf(stdout, NULL);
    if (argc != 3) { fprintf(stderr, "usage: print_verify <plugin.wlx> <output-dir>\n"); return 2; }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    outputDir = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]].path;
    [[NSFileManager defaultManager] createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:NULL];
    void *handle = dlopen(argv[1], RTLD_NOW);
    if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 2; }
    LoadFn load = (LoadFn)dlsym(handle, "ListLoad");
    NextFn next = (NextFn)dlsym(handle, "ListLoadNext");
    CloseFn close = (CloseFn)dlsym(handle, "ListCloseWindow");
    PrintFn print = (PrintFn)dlsym(handle, "ListPrintW");
    if (!load || !next || !close || !print) { fprintf(stderr, "missing WLX exports\n"); return 1; }

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,450)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    [window orderFront:nil];

    NSMutableString *md = [NSMutableString stringWithString:
        @"# FIRST PRINT MARKER\n\nA **formatted** document with a table, math and a diagram.\n\n"
         @"| Name | Value |\n| --- | --- |\n| Sample | 42 |\n\n"
         @"$$E=mc^2$$\n\n```mermaid\nflowchart LR\n A[Start] --> B[Finish]\n```\n\n"
         @"![Local image](print-image.svg)\n\n```text\n"];
    for (int i = 0; i < 12; i++) [md appendString:@"long_code_line_"];
    [md appendString:@"END_OF_LONG_CODE\n```\n\n"];
    for (int i = 0; i < 65; i++) [md appendFormat:@"Paragraph %d: content beyond the viewer's visible viewport.\n\n", i];
    [md appendString:@"## LAST PRINT MARKER\n\nThe full document was printed.\n"];
    NSString *path = [outputDir stringByAppendingPathComponent:@"Grüße-print.md"];
    [md writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"<svg xmlns='http://www.w3.org/2000/svg' width='240' height='60'><rect width='240' height='60' fill='#ddd'/><text x='10' y='35'>Local image</text></svg>"
        writeToFile:[outputDir stringByAppendingPathComponent:@"print-image.svg"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    HWND view = load((__bridge HWND)window.contentView, (char *)path.UTF8String, 0);
    if (!view) return 2;
    WKWebView *web = nil;
    for (NSView *v in ((__bridge NSView *)view).subviews)
        if ([v isKindOfClass:WKWebView.class]) web = (WKWebView *)v;
    if (!web) return 2;
    NSPrintOperation *probe = [web printOperationWithPrintInfo:[NSPrintInfo.sharedPrintInfo copy]];
    Method method = class_getInstanceMethod(probe.class,
        @selector(runOperationModalForWindow:delegate:didRunSelector:contextInfo:));
    printf("Printing operation: %s\n", class_getName(probe.class));
    original = method_setImplementation(method, (IMP)saveInsteadOfSheet);
    /* Exercise a dark screen even when the system appearance is light. */
    web.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    ListPrintMargins margins = {200, 150, 180, 120};
    WCHAR basename[] = {'x', '.', 'm', 'd', 0};
    check(print(NULL, basename, NULL, 0, &margins) == LISTPLUGIN_ERROR, "NULL plugin window rejected");
    check(print((__bridge HWND)window.contentView, basename, NULL, 0, &margins) == LISTPLUGIN_ERROR, "non-plugin view rejected");
    check(print(view, basename, NULL, 0, &margins) == LISTPLUGIN_OK, "print accepted immediately, before Markdown renders");
    check(print(view, basename, NULL, 0, &margins) == LISTPLUGIN_ERROR, "duplicate pending print rejected");
    check(pump(^BOOL{ return completions == 1; }, 25), "queued print runs after resources settle");
    check(fabs(lastInfo.leftMargin - 200 * 72.0/254) < .01 &&
          fabs(lastInfo.topMargin - 150 * 72.0/254) < .01 &&
          fabs(lastInfo.rightMargin - 180 * 72.0/254) < .01 &&
          fabs(lastInfo.bottomMargin - 120 * 72.0/254) < .01, "WLX tenths-of-mm margins converted to points");
    check([lastTitle isEqualToString:path.lastPathComponent], "Unicode job title uses loaded file, not host basename");
    PDFDocument *pdf = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:
                      [outputDir stringByAppendingPathComponent:@"print-1.pdf"]]];
    check(pdf.pageCount > 1, "full document paginated over multiple pages");
    for (NSUInteger i = 0; i < pdf.pageCount; i++) {
        NSString *footer = [NSString stringWithFormat:@"Page %lu of %lu",
                            (unsigned long)i + 1, (unsigned long)pdf.pageCount];
        PDFPage *page = [pdf pageAtIndex:i];
        check([page.string containsString:footer], footer.UTF8String);
        PDFSelection *selection = [[pdf findString:footer withOptions:0] firstObject];
        NSRect bounds = [selection boundsForPage:page];
        check(!NSIsEmptyRect(bounds) && bounds.origin.y >= 0 &&
              NSMaxY(bounds) < lastInfo.bottomMargin + 24,
              "page number lies in reserved footer below content");
    }
    check([pdf.string containsString:@"FIRST PRINT MARKER"] &&
          [pdf.string containsString:@"LAST PRINT MARKER"], "PDF contains first and last content");
    check([pdf.string containsString:@"END_OF_LONG_CODE"], "long code wraps without losing its end");
    check(![pdf.string containsString:@"MarkdownView v"], "version badge omitted from all PDF pages");
    check([js(web, @"!!document.querySelector('.mermaid svg')&&!!document.querySelector('.katex')") boolValue], "diagram and math rendered before printing");
    check([[js(web, @"getComputedStyle(document.getElementById('mdv-ver')).display") description] isEqualToString:@"block"], "print media does not hide screen version badge");

    cancelNext = YES;
    __block int backgroundResult = -1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        int rc = print(view, NULL, NULL, 0, NULL);
        dispatch_async(dispatch_get_main_queue(), ^{ backgroundResult = rc; });
    });
    check(pump(^BOOL{ return backgroundResult != -1; }, 5) && backgroundResult == LISTPLUGIN_OK,
          "background ABI call dispatches safely to main thread");
    check(pump(^BOOL{ return completions == 2; }, 5), "cancellation callback completes");
    cancelNext = YES;
    check(print(view, NULL, NULL, 0, NULL) == LISTPLUGIN_OK, "print accepted again after cancelling");
    check(pump(^BOOL{ return completions == 3; }, 5), "retry completes");

    printSubset = YES;
    check(print(view, NULL, NULL, 0, &margins) == LISTPLUGIN_OK, "page-range print accepted");
    check(pump(^BOOL{ return completions == 4; }, 15), "page-range print completes");
    PDFDocument *subset = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:
                         [outputDir stringByAppendingPathComponent:@"print-4.pdf"]]];
    check(subset.pageCount == 2, "only the requested two pages printed");
    for (NSUInteger i = 0; i < subset.pageCount; i++) {
        NSString *footer = [NSString stringWithFormat:@"Page %lu of %lu",
                            (unsigned long)i + 2, (unsigned long)pdf.pageCount];
        check([[subset pageAtIndex:i].string containsString:footer],
              "selected pages retain document numbering and total");
    }
    printSubset = NO;

    /* A navigation before the queued presentation must cancel that request. */
    check(print(view, NULL, NULL, 0, NULL) == LISTPLUGIN_OK, "print queued before navigation");
    check(next((__bridge HWND)window.contentView, view, (char *)path.UTF8String, 0) == LISTPLUGIN_OK, "navigation accepted");
    pump(^BOOL{ return [js(web, @"document.readyState==='complete'") boolValue]; }, 10);
    check(presentations == 4, "navigation cancels old document's print request");
    check(print(view, NULL, NULL, 0, NULL) == LISTPLUGIN_OK, "print queued before close");
    close(view);
    pump(^BOOL{ return NO; }, .5);
    check(presentations == 4, "closing viewer cancels pending print");
    method_setImplementation(method, original);
    [window close];
    printf("RESULT: %s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}}
