/*
 * MarkdownView.wlx — Double Commander Lister (WLX) plugin for macOS.
 * Renders Markdown files in a WKWebView with GitHub-style CSS, syntax
 * highlighting, GitHub Flavored Markdown, Mermaid diagrams, KaTeX math, and
 * automatic (or configured) light/dark theming.
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

/* Absolute file:// URL string for an asset shipped next to the .wlx. */
static NSString *AssetURL(NSString *name) {
    NSString *dir = PluginDirectory();
    if (!dir) return @"";
    NSString *path = [[dir stringByAppendingPathComponent:@"assets"]
                         stringByAppendingPathComponent:name];
    return [[NSURL fileURLWithPath:path] absoluteString];
}

#pragma mark - Configuration (optional MarkdownView.ini)

static NSString *gIniPath = nil; /* set by ListSetDefaultParams */

static NSString *ConfigIniPath(void) {
    if (gIniPath.length) return gIniPath;
    NSString *dir = PluginDirectory();
    return dir ? [dir stringByAppendingPathComponent:@"MarkdownView.ini"] : nil;
}

/* Read the optional [MarkdownView] section. Re-read every load so edits apply
 * without restarting Double Commander. Unset keys keep their defaults. */
static NSDictionary *ReadConfig(void) {
    NSMutableDictionary *cfg = [@{ @"theme": @"auto", @"maxwidth": @"980",
                                   @"fontsize": @"16", @"mermaid": @"1",
                                   @"math": @"1" } mutableCopy];
    NSString *path = ConfigIniPath();
    NSString *text = path ? [NSString stringWithContentsOfFile:path
                                encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!text) return cfg;

    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
    BOOL inSection = NO;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:
                              [NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:ws];
        if (line.length == 0 || [line hasPrefix:@";"] || [line hasPrefix:@"#"]) continue;
        if ([line hasPrefix:@"["]) {
            inSection = [[line lowercaseString] isEqualToString:@"[markdownview]"];
            continue;
        }
        if (!inSection) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[[line substringToIndex:eq.location]
                          stringByTrimmingCharactersInSet:ws] lowercaseString];
        NSString *v = [[line substringFromIndex:eq.location + 1]
                          stringByTrimmingCharactersInSet:ws];
        if (k.length) cfg[k] = v;
    }
    return cfg;
}

static BOOL CfgBool(NSDictionary *cfg, NSString *key) {
    NSString *v = [[cfg[key] description] lowercaseString];
    return [v isEqualToString:@"1"] || [v isEqualToString:@"true"] ||
           [v isEqualToString:@"yes"] || [v isEqualToString:@"on"];
}

#pragma mark - MDWebView

/* WKWebView swallows the Escape key, so Double Commander's viewer never sees it
 * and won't close on Esc.
 *
 * Double Commander is a Lazarus/LCL app: it processes key shortcuts (including
 * Esc -> close viewer) through NSApplication's event dispatch (-sendEvent:),
 * NOT through synthetic -keyDown: responder forwarding. So just walking the
 * responder chain is not enough — it reaches DC's window but never re-enters
 * LCL's key handling.
 *
 * The fix mirrors the manual workaround "switch to Text mode, then Esc works":
 * move keyboard focus off the web view onto DC's own view, then re-post the
 * Escape event so NSApplication dispatches it normally and LCL closes the
 * viewer. Every other key is left to normal web handling (scrolling, find,
 * text selection). */
@interface MDWebView : WKWebView
@end

@implementation MDWebView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode != 53 /* kVK_Escape */) {
        [super keyDown:event];
        return;
    }

    NSWindow *win = self.window;
    if (!win) return;

    /* The view DC handed us is our container's superview — a control inside the
     * viewer form. Focus it (or fall back) so the web view stops eating keys. */
    NSView *dcView = self.superview.superview;
    BOOL moved = NO;
    if ([dcView isKindOfClass:[NSView class]]) moved = [win makeFirstResponder:dcView];
    if (!moved) moved = [win makeFirstResponder:win.contentView];
    if (!moved) moved = [win makeFirstResponder:nil];
    if (win.firstResponder == self) return; /* couldn't move focus; avoid a loop */

    /* Re-inject Escape into the normal event queue (fresh copy, not the
     * in-flight event) so NSApplication -> LCL handles it. */
    NSEvent *esc = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                    location:event.locationInWindow
                               modifierFlags:event.modifierFlags
                                   timestamp:event.timestamp
                                windowNumber:event.windowNumber
                                     context:nil
                                  characters:@"\x1b"
                 charactersIgnoringModifiers:@"\x1b"
                                   isARepeat:NO
                                     keyCode:53];
    [NSApp postEvent:esc atStart:YES];
}
@end

#pragma mark - MDView

@class MDView;

/* Receives scroll offsets from the page. Holds the view weakly so the
 * userContentController -> handler -> view chain is not a retain cycle. */
@interface MDScrollSink : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) MDView *owner;
@end

@interface MDView : NSView
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) MDScrollSink *sink;
@property (nonatomic, copy)   NSString *tmpHTMLPath;
@property (nonatomic, copy)   NSString *currentPath;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *scrollByPath;
- (BOOL)loadMarkdownAtPath:(NSString *)mdPath;
@end

@implementation MDScrollSink
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    MDView *v = self.owner;
    if (v && v.currentPath && [message.body isKindOfClass:[NSNumber class]]) {
        v.scrollByPath[v.currentPath] = (NSNumber *)message.body;
    }
}
@end

@implementation MDView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _scrollByPath = [NSMutableDictionary dictionary];

        _sink = [[MDScrollSink alloc] init];
        _sink.owner = self;

        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        [cfg.userContentController addScriptMessageHandler:_sink name:@"dcmd"];

        _web = [[MDWebView alloc] initWithFrame:self.bounds configuration:cfg];
        _web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        @try { [_web setValue:@NO forKey:@"drawsBackground"]; } @catch (__unused id e) {}
        [self addSubview:_web];

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
    NSString *mdText = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding] ?: @"";

    self.currentPath = mdPath;
    long savedY = [self.scrollByPath[mdPath] longValue];

    NSDictionary *cfg = ReadConfig();
    NSString *theme = [[cfg[@"theme"] description] lowercaseString];
    if (![theme isEqualToString:@"light"] && ![theme isEqualToString:@"dark"]) theme = @"auto";
    long maxWidth = MAX(320, [cfg[@"maxwidth"] integerValue] ?: 980);
    long fontSize = MAX(8,   [cfg[@"fontsize"] integerValue] ?: 16);
    BOOL wantMermaid = CfgBool(cfg, @"mermaid") &&
                       [mdText rangeOfString:@"```mermaid"].location != NSNotFound;
    BOOL wantMath    = CfgBool(cfg, @"math") &&
                       [mdText rangeOfString:@"$"].location != NSNotFound;

    NSString *mdDir = [mdPath stringByDeletingLastPathComponent];
    NSString *baseHref = [[NSURL fileURLWithPath:mdDir isDirectory:YES] absoluteString];
    NSString *title = [[mdPath lastPathComponent]
                          stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];

    /* ---- theme-dependent stylesheets ---- */
    NSMutableString *head = [NSMutableString string];
    if ([theme isEqualToString:@"light"]) {
        [head appendFormat:@"<link rel=\"stylesheet\" href=\"%@\">", AssetURL(@"github-markdown-light.css")];
        [head appendFormat:@"<link rel=\"stylesheet\" href=\"%@\">", AssetURL(@"hl-github.css")];
        [head appendString:@"<style>:root{color-scheme:light;}html,body{background:#fff;}</style>"];
    } else if ([theme isEqualToString:@"dark"]) {
        [head appendFormat:@"<link rel=\"stylesheet\" href=\"%@\">", AssetURL(@"github-markdown-dark.css")];
        [head appendFormat:@"<link rel=\"stylesheet\" href=\"%@\">", AssetURL(@"hl-github-dark.css")];
        [head appendString:@"<style>:root{color-scheme:dark;}html,body{background:#0d1117;}</style>"];
    } else {
        [head appendFormat:@"<link rel=\"stylesheet\" href=\"%@\">", AssetURL(@"github-markdown.css")];
        [head appendFormat:@"<link rel=\"stylesheet\" href=\"%@\" media=\"(prefers-color-scheme: light)\">", AssetURL(@"hl-github.css")];
        [head appendFormat:@"<link rel=\"stylesheet\" href=\"%@\" media=\"(prefers-color-scheme: dark)\">", AssetURL(@"hl-github-dark.css")];
        [head appendString:@"<style>:root{color-scheme:light dark;}"
                            @"html,body{background:#fff;}"
                            @"@media(prefers-color-scheme:dark){html,body{background:#0d1117;}}</style>"];
    }
    [head appendFormat:@"<style>html,body{margin:0;padding:0;}"
                       @".markdown-body{box-sizing:border-box;max-width:%ldpx;margin:0 auto;"
                       @"padding:32px 44px;font-size:%ldpx;}"
                       @"@media(max-width:767px){.markdown-body{padding:18px;}}"
                       @".mermaid{display:flex;justify-content:center;margin:16px 0;}</style>",
                       maxWidth, fontSize];

    /* ---- libraries ---- */
    [head appendFormat:@"<script src=\"%@\"></script>", AssetURL(@"marked.min.js")];
    [head appendFormat:@"<script src=\"%@\"></script>", AssetURL(@"highlight.min.js")];
    if (wantMermaid) {
        [head appendFormat:@"<script src=\"%@\"></script>", AssetURL(@"mermaid/mermaid.min.js")];
    }
    if (wantMath) {
        [head appendFormat:@"<link rel=\"stylesheet\" href=\"%@\">", AssetURL(@"katex/katex.min.css")];
        [head appendFormat:@"<script src=\"%@\"></script>", AssetURL(@"katex/katex.min.js")];
        [head appendFormat:@"<script src=\"%@\"></script>", AssetURL(@"katex/auto-render.min.js")];
    }

    NSString *bootstrap = [NSString stringWithFormat:@""
        "var __theme=\"%@\";var __scrollY=%ld;"
        "window.addEventListener('load',function(){"
        "var b64=document.getElementById('md-data').textContent.trim();"
        "var md=new TextDecoder('utf-8').decode(Uint8Array.from(atob(b64),function(c){return c.charCodeAt(0);}));"
        "try{marked.setOptions({gfm:true,breaks:false});}catch(e){}"
        "var out;try{out=marked.parse(md);}catch(e){out='<pre>'+String(e)+'</pre>';}"
        "var content=document.getElementById('content');content.innerHTML=out;"
        "if(window.mermaid){"
          "content.querySelectorAll('code.language-mermaid').forEach(function(code){"
            "var d=document.createElement('div');d.className='mermaid';d.textContent=code.textContent;"
            "var pre=code.parentNode;pre.parentNode.replaceChild(d,pre);});"
          "try{var dark=(__theme==='dark')||(__theme==='auto'&&matchMedia('(prefers-color-scheme: dark)').matches);"
          "mermaid.initialize({startOnLoad:false,theme:dark?'dark':'default',securityLevel:'strict'});"
          "mermaid.run();}catch(e){}}"
        "try{content.querySelectorAll('pre code:not(.language-mermaid)').forEach(function(el){hljs.highlightElement(el);});}catch(e){}"
        "if(window.renderMathInElement){try{renderMathInElement(content,{delimiters:["
          "{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false},"
          "{left:'\\\\(',right:'\\\\)',display:false},{left:'\\\\[',right:'\\\\]',display:true}],"
          "throwOnError:false});}catch(e){}}"
        "try{if(__scrollY>0)window.scrollTo(0,__scrollY);}catch(e){}"
        "var post=function(){try{window.webkit.messageHandlers.dcmd.postMessage(window.scrollY);}catch(e){}};"
        "var t=null;window.addEventListener('scroll',function(){if(t)return;t=setTimeout(function(){t=null;post();},120);},{passive:true});"
        "});", theme, savedY];

    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
                       @"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"];
    [html appendFormat:@"<base href=\"%@\"><title>%@</title>", baseHref, title];
    [html appendString:head];
    [html appendString:@"</head><body><article class=\"markdown-body\" id=\"content\"></article>"];
    [html appendFormat:@"<script id=\"md-data\" type=\"application/x-markdown-base64\">%@</script>", b64];
    [html appendFormat:@"<script>%@</script>", bootstrap];
    [html appendString:@"</body></html>"];

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
    [_web.configuration.userContentController removeScriptMessageHandlerForName:@"dcmd"];
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
    if (dps && dps->DefaultIniName[0]) {
        gIniPath = [NSString stringWithUTF8String:dps->DefaultIniName];
    }
}
