/*
 * MarkdownView.wlx — Double Commander Lister (WLX) plugin for macOS.
 * Renders Markdown files in a WKWebView with GitHub-style CSS, syntax
 * highlighting, tables, task lists and automatic light/dark theming.
 *
 * On macOS, Double Commander passes/expects NSView* as the window handle.
 * The viewer's built-in mode switch still lets the user flip back to the
 * raw Text / Hex view at any time.
 */

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>
#include "listplug.h"

#pragma mark - Helpers

/* Directory that contains this .wlx, so we can find the assets folder beside it. */
static NSString *PluginDirectory(void) {
    Dl_info info;
    if (dladdr((const void *)&PluginDirectory, &info) && info.dli_fname) {
        NSString *dylib = [NSString stringWithUTF8String:info.dli_fname];
        return [dylib stringByDeletingLastPathComponent];
    }
    return nil;
}

static NSString *ReadFile(NSString *path) {
    if (!path) return @"";
    NSString *s = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    return s ?: @"";
}

/* Absolute file:// URL string for an asset shipped next to the .wlx. */
static NSString *AssetURL(NSString *name) {
    NSString *dir = PluginDirectory();
    if (!dir) return @"";
    NSString *path = [[dir stringByAppendingPathComponent:@"assets"]
                         stringByAppendingPathComponent:name];
    return [[NSURL fileURLWithPath:path] absoluteString];
}

#pragma mark - MDWebView

/* WKWebView swallows the Escape key, so Double Commander's viewer never sees it
 * and won't close on Esc. We forward only Escape up the responder chain
 * (webView -> MDView -> DC's parent view -> viewer window) and leave every other
 * key to normal web handling (scrolling, find, text selection). */
@interface MDWebView : WKWebView
@end

@implementation MDWebView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53 /* kVK_Escape */) {
        [self.nextResponder keyDown:event];
        return;
    }
    [super keyDown:event];
}
@end

#pragma mark - MDView

@interface MDView : NSView
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, copy)   NSString  *tmpHTMLPath;
- (BOOL)loadMarkdownAtPath:(NSString *)mdPath;
@end

@implementation MDView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        _web = [[MDWebView alloc] initWithFrame:self.bounds configuration:cfg];
        _web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        // Allow our generated page to read local image files referenced by the doc.
        @try { [_web setValue:@NO forKey:@"drawsBackground"]; } @catch (__unused id e) {}
        [self addSubview:_web];

        // One stable temp file per view instance; overwritten on reload.
        NSString *name = [NSString stringWithFormat:@"dc-md-preview-%d-%p.html",
                          getpid(), (void *)self];
        _tmpHTMLPath = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    }
    return self;
}

- (BOOL)loadMarkdownAtPath:(NSString *)mdPath {
    NSData *raw = [NSData dataWithContentsOfFile:mdPath];
    if (!raw) raw = [NSData data];
    NSString *b64 = [raw base64EncodedStringWithOptions:0];

    NSString *mdDir = [mdPath stringByDeletingLastPathComponent];
    NSString *baseHref = [[NSURL fileURLWithPath:mdDir isDirectory:YES] absoluteString];
    NSString *title = [[mdPath lastPathComponent]
                          stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

    /* Reference assets by absolute file:// URLs — never inline JS, because
     * minified libraries can contain a literal "</script>" that would
     * truncate an inline <script> tag. loadFileURL grants read access. */
    NSString *markdownCSS = AssetURL(@"github-markdown.css");
    NSString *hlLight     = AssetURL(@"hl-github.css");
    NSString *hlDark      = AssetURL(@"hl-github-dark.css");
    NSString *markedJS    = AssetURL(@"marked.min.js");
    NSString *hlJS        = AssetURL(@"highlight.min.js");

    NSString *html = [NSString stringWithFormat:@""
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        "<base href=\"%@\">"
        "<title>%@</title>"
        "<link rel=\"stylesheet\" href=\"%@\">"
        "<link rel=\"stylesheet\" href=\"%@\" media=\"(prefers-color-scheme: light)\">"
        "<link rel=\"stylesheet\" href=\"%@\" media=\"(prefers-color-scheme: dark)\">"
        "<style>"
        ":root{color-scheme: light dark;}"
        "html,body{margin:0;padding:0;background:#ffffff;}"
        "@media (prefers-color-scheme: dark){html,body{background:#0d1117;}}"
        ".markdown-body{box-sizing:border-box;max-width:980px;margin:0 auto;"
        "padding:32px 44px;}"
        "@media (max-width:767px){.markdown-body{padding:18px;}}"
        "</style>"
        "<script src=\"%@\"></script>"
        "<script src=\"%@\"></script>"
        "</head><body>"
        "<article class=\"markdown-body\" id=\"content\"></article>"
        "<script id=\"md-data\" type=\"application/x-markdown-base64\">%@</script>"
        "<script>"
        "window.addEventListener('load',function(){"
        "var b64=document.getElementById('md-data').textContent.trim();"
        "var bytes=Uint8Array.from(atob(b64),function(c){return c.charCodeAt(0);});"
        "var md=new TextDecoder('utf-8').decode(bytes);"
        "try{marked.setOptions({gfm:true,breaks:false});}catch(e){}"
        "var out;try{out=marked.parse(md);}catch(e){out='<pre>'+String(e)+'</pre>';}"
        "document.getElementById('content').innerHTML=out;"
        "try{document.querySelectorAll('pre code').forEach(function(el){hljs.highlightElement(el);});}catch(e){}"
        "});"
        "</script>"
        "</body></html>",
        baseHref, title, markdownCSS, hlLight, hlDark, markedJS, hlJS, b64];

    NSError *werr = nil;
    if (![html writeToFile:self.tmpHTMLPath atomically:YES
                  encoding:NSUTF8StringEncoding error:&werr]) {
        return NO;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:self.tmpHTMLPath];
    NSURL *rootURL = [NSURL fileURLWithPath:@"/" isDirectory:YES];
    [self.web loadFileURL:fileURL allowingReadAccessToURL:rootURL];
    return YES;
}

- (void)dealloc {
    if (_tmpHTMLPath) {
        [[NSFileManager defaultManager] removeItemAtPath:_tmpHTMLPath error:NULL];
    }
}

@end

#pragma mark - WLX exported API

static MDView *MakeAndLoad(HWND ParentWin, const char *FileToLoad) {
    NSView *parent = (__bridge NSView *)ParentWin;
    NSRect frame = parent ? parent.bounds : NSMakeRect(0, 0, 800, 600);
    MDView *view = [[MDView alloc] initWithFrame:frame];
    NSString *path = FileToLoad ? [NSString stringWithUTF8String:FileToLoad] : @"";
    if (![view loadMarkdownAtPath:path]) return nil;
    if (parent) [parent addSubview:view];
    return view;
}

__attribute__((visibility("default")))
HWND __stdcall ListLoad(HWND ParentWin, char *FileToLoad, int ShowFlags) {
    (void)ShowFlags;
    __block MDView *result = nil;
    if ([NSThread isMainThread]) {
        result = MakeAndLoad(ParentWin, FileToLoad);
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = MakeAndLoad(ParentWin, FileToLoad);
        });
    }
    if (!result) return NULL;
    return (HWND)CFBridgingRetain(result); /* +1; released in ListCloseWindow */
}

__attribute__((visibility("default")))
int __stdcall ListLoadNext(HWND ParentWin, HWND PluginWin, char *FileToLoad, int ShowFlags) {
    (void)ParentWin; (void)ShowFlags;
    MDView *view = (__bridge MDView *)PluginWin;
    if (![view isKindOfClass:[MDView class]]) return LISTPLUGIN_ERROR;
    NSString *path = FileToLoad ? [NSString stringWithUTF8String:FileToLoad] : @"";
    __block BOOL ok = NO;
    if ([NSThread isMainThread]) {
        ok = [view loadMarkdownAtPath:path];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{ ok = [view loadMarkdownAtPath:path]; });
    }
    return ok ? LISTPLUGIN_OK : LISTPLUGIN_ERROR;
}

__attribute__((visibility("default")))
void __stdcall ListCloseWindow(HWND ListWin) {
    if (!ListWin) return;
    void (^close)(void) = ^{
        MDView *view = (MDView *)CFBridgingRelease(ListWin); /* -1 */
        [view removeFromSuperview];
    };
    if ([NSThread isMainThread]) close();
    else dispatch_sync(dispatch_get_main_queue(), close);
}

__attribute__((visibility("default")))
void __stdcall ListGetDetectString(char *DetectString, int maxlen) {
    const char *s =
        "EXT=\"MD\"|EXT=\"MARKDOWN\"|EXT=\"MDOWN\"|EXT=\"MKD\"|EXT=\"MKDN\"|"
        "EXT=\"MDWN\"|EXT=\"MDTXT\"|EXT=\"MDTEXT\"|EXT=\"MARKDN\"|EXT=\"RMD\"|EXT=\"QMD\"";
    strncpy(DetectString, s, maxlen - 1);
    DetectString[maxlen - 1] = '\0';
}

__attribute__((visibility("default")))
void __stdcall ListSetDefaultParams(ListDefaultParamStruct *dps) {
    (void)dps; /* nothing to configure */
}
