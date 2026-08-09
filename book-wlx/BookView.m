/*
 * BookView.wlx — Double Commander Lister (WLX) plugin for macOS.
 * Renders EPUB and FictionBook (FB2) e-books in the F3 viewer: table of
 * contents, continuous reflowable text, cover and metadata, light / dark /
 * sepia themes.
 *
 * How it fits together
 * --------------------
 * An `.epub` is a ZIP (OCF) container of XHTML, CSS and images; an `.fb2` is a
 * single self-contained XML document (optionally zipped, as `.fbz`). Rather
 * than unpacking anything to a temp directory, the plugin serves the book
 * straight out of the container through a WKURLSchemeHandler on a private
 * `x-book://` scheme. That keeps every resource same-origin (so relative
 * hrefs, images, fonts and `fetch()` all just work), writes nothing to disk,
 * and makes escaping the container structurally impossible — a path simply
 * either names an entry or it doesn't.
 *
 * The native side therefore owns container I/O and the page shell; both
 * document models — EPUB's container.xml -> OPF -> spine -> nav/NCX, and FB2's
 * description/body/binary tree — are parsed in `assets/reader.js`, where
 * DOMParser handles real-world markup far better than hand-rolled parsing
 * would.
 *
 * Book content is untrusted: EPUB chapters are sanitized with DOMPurify before
 * they are inserted (FB2 is rebuilt element by element from a fixed vocabulary,
 * so nothing from the file is ever parsed as markup), and a CSP restricts the
 * page to its own origin, so nothing in a book can execute script or reach the
 * network.
 *
 * On macOS, Double Commander passes/expects NSView* as the window handle.
 */

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dlfcn.h>
#include "listplug.h"
#include "zipreader.h"

#define BKV_VERSION "0.1.0"   /* single source of truth for the plugin version */

/* Reserved first path segment for the reader's own assets. Checked before the
 * ZIP, so a book cannot shadow the reader's stylesheet or script. */
#define READER_PREFIX @"__dcreader__"

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

static NSData *ReadAsset(NSString *name) {
    NSString *dir = PluginDirectory();
    if (!dir) return nil;
    NSString *path = [[dir stringByAppendingPathComponent:@"assets"]
                         stringByAppendingPathComponent:name];
    return [NSData dataWithContentsOfFile:path];
}

static NSString *MimeForPath(NSString *path) {
    NSString *ext = [[path pathExtension] lowercaseString];
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"xhtml": @"application/xhtml+xml", @"html": @"text/html",
                 @"htm":  @"text/html",  @"xml": @"application/xml",
                 @"opf":  @"application/oebps-package+xml",
                 @"ncx":  @"application/x-dtbncx+xml",
                 @"css":  @"text/css",   @"js":   @"text/javascript",
                 @"json": @"application/json", @"txt": @"text/plain",
                 @"jpg":  @"image/jpeg", @"jpeg": @"image/jpeg",
                 @"png":  @"image/png",  @"gif":  @"image/gif",
                 @"svg":  @"image/svg+xml", @"webp": @"image/webp",
                 @"bmp":  @"image/bmp",  @"tif":  @"image/tiff",
                 @"tiff": @"image/tiff", @"avif": @"image/avif",
                 @"otf":  @"font/otf",   @"ttf":  @"font/ttf",
                 @"woff": @"font/woff",  @"woff2": @"font/woff2",
                 @"mp3":  @"audio/mpeg", @"m4a":  @"audio/mp4",
                 @"ogg":  @"audio/ogg",  @"mp4":  @"video/mp4",
                 @"webm": @"video/webm", @"smil": @"application/smil+xml" };
    });
    return map[ext] ?: @"application/octet-stream";
}

static NSString *HTMLEscape(NSString *s) {
    NSMutableString *m = [(s ?: @"") mutableCopy];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;"  options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;"  options:0 range:NSMakeRange(0, m.length)];
    return m;
}

#pragma mark - Configuration (optional BookView.ini)

static NSString *gIniPath = nil;   /* set by ListSetDefaultParams */
static long      gFontSizeOverride = 0; /* last size chosen with A- / A+ this session */

static NSString *ConfigIniPath(void) {
    if (gIniPath.length) return gIniPath;
    NSString *dir = PluginDirectory();
    return dir ? [dir stringByAppendingPathComponent:@"BookView.ini"] : nil;
}

/* Read the optional [BookView] section. Re-read on every load so edits apply
 * without restarting Double Commander. Unset keys keep their defaults. */
static NSDictionary *ReadConfig(void) {
    NSMutableDictionary *cfg = [@{ @"theme": @"auto", @"fontsize": @"18",
                                   @"maxwidth": @"680", @"lineheight": @"1.7",
                                   @"justify": @"0", @"publishercss": @"0",
                                   @"toc": @"1", @"showversion": @"1" } mutableCopy];
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
            inSection = [[line lowercaseString] isEqualToString:@"[bookview]"];
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

#pragma mark - BKWebView

/* WKWebView swallows the Escape key, so Double Commander's viewer never sees it
 * and won't close on Esc.
 *
 * Double Commander is a Lazarus/LCL app: it processes key shortcuts (including
 * Esc -> close viewer) through NSApplication's event dispatch (-sendEvent:),
 * NOT through synthetic -keyDown: responder forwarding. So walking the responder
 * chain is not enough — it reaches DC's window but never re-enters LCL's key
 * handling.
 *
 * The fix mirrors the manual workaround "switch to Text mode, then Esc works":
 * move keyboard focus off the web view onto DC's own view, then re-post the
 * Escape event so NSApplication dispatches it normally and LCL closes the
 * viewer. Every other key is left to normal web handling. */
@interface BKWebView : WKWebView
@end

@implementation BKWebView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode != 53 /* kVK_Escape */) {
        [super keyDown:event];
        return;
    }

    NSWindow *win = self.window;
    if (!win) return;

    NSView *dcView = self.superview.superview;
    BOOL moved = NO;
    if ([dcView isKindOfClass:[NSView class]]) moved = [win makeFirstResponder:dcView];
    if (!moved) moved = [win makeFirstResponder:win.contentView];
    if (!moved) moved = [win makeFirstResponder:nil];
    if (win.firstResponder == self) return; /* couldn't move focus; avoid a loop */

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

#pragma mark - x-book:// scheme handler

/*
 * Serves four things under x-book://book/<token>/ :
 *   /<token>/__dcreader__/index.html   the generated reader shell
 *   /<token>/__dcreader__/<asset>      reader.css / reader.js / dompurify.min.js
 *   /<token>/__dcreader__/document.fb2 the FictionBook document, for an FB2 book
 *   /<token>/<zip entry path>          a file from inside an EPUB
 *
 * `<token>` changes on every load so a reused web view can never serve a
 * previous book's cached resource under the same URL.
 */
/*
 * Owns a ZipArchive for exactly as long as someone is still reading from it.
 * Entries are inflated on a background queue, so the archive cannot be a bare
 * pointer the main thread frees on the next file: a block that captures this
 * object keeps the mapping alive until it finishes.
 */
@interface BKArchive : NSObject
@property (nonatomic, readonly) ZipArchive *zip;
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation BKArchive
- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _zip = path.length ? ZipOpen(path.fileSystemRepresentation) : NULL;
        if (!_zip) return nil;
    }
    return self;
}
- (void)dealloc { if (_zip) ZipClose(_zip); }
@end

@interface BKSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, strong) BKArchive  *archive;     /* keeps the ZIP mapped */
@property (nonatomic, strong) NSData     *fb2;         /* the whole FB2 document */
@property (nonatomic, copy)   NSString   *shellHTML;
@property (nonatomic, copy)   NSString   *token;
@property (nonatomic, strong) NSMutableSet *liveTasks; /* main thread only */
@end

@implementation BKSchemeHandler

- (instancetype)init {
    self = [super init];
    if (self) _liveTasks = [NSMutableSet set];
    return self;
}

/* Reply on the main queue, and only while the task is still live — WebKit
 * raises if a stopped task is written to. */
- (void)finishTask:(id<WKURLSchemeTask>)task
              data:(NSData *)data
              mime:(NSString *)mime {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self.liveTasks containsObject:task]) return;
        [self.liveTasks removeObject:task];
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc]
            initWithURL:task.request.URL
             statusCode:data ? 200 : 404
            HTTPVersion:@"HTTP/1.1"
           headerFields:@{ @"Content-Type": mime ?: @"application/octet-stream",
                           @"Content-Length": [@(data.length) stringValue],
                           @"Cache-Control": @"no-store" }];
        [task didReceiveResponse:resp];
        [task didReceiveData:data ?: [NSData data]];
        [task didFinish];
    });
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    [self.liveTasks addObject:task];

    /* The still-encoded path: NSURL.path decodes once already, and decoding a
     * second time would corrupt an entry whose name contains a literal `%`. */
    NSURLComponents *parts = [NSURLComponents componentsWithURL:task.request.URL
                                       resolvingAgainstBaseURL:NO];
    NSString *path = parts.percentEncodedPath ?: @"";
    if ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];

    /* Strip the per-load token; anything under a stale token is gone. */
    NSString *token = self.token ?: @"";
    if ([path hasPrefix:[token stringByAppendingString:@"/"]]) {
        path = [path substringFromIndex:token.length + 1];
    } else {
        [self finishTask:task data:nil mime:@"text/plain"];
        return;
    }

    if ([path hasPrefix:READER_PREFIX @"/"]) {
        NSString *name = [path substringFromIndex:[READER_PREFIX length] + 1];
        if ([name isEqualToString:@"index.html"]) {
            [self finishTask:task
                        data:[(self.shellHTML ?: @"") dataUsingEncoding:NSUTF8StringEncoding]
                        mime:@"text/html; charset=utf-8"];
            return;
        }
        if ([name isEqualToString:@"document.fb2"]) {
            /* Served as text so the reader can sniff the declared encoding —
             * plenty of FictionBook files are windows-1251, not UTF-8. */
            [self finishTask:task data:self.fb2 mime:@"application/octet-stream"];
            return;
        }
        /* Fixed allow-list — never a caller-controlled path into the filesystem. */
        NSSet *allowed = [NSSet setWithObjects:@"reader.css", @"reader.js",
                                               @"dompurify.min.js", nil];
        NSData *data = [allowed containsObject:name] ? ReadAsset(name) : nil;
        [self finishTask:task data:data mime:MimeForPath(name)];
        return;
    }

    /* A book resource. Inflating happens off the main thread so a large image
     * never stalls scrolling; the block holds the archive so switching files
     * mid-read cannot pull the mapping out from under it. */
    BKArchive *archive = self.archive;
    if (!archive) {
        [self finishTask:task data:nil mime:@"text/plain"];
        return;
    }
    NSString *entry = [path stringByRemovingPercentEncoding] ?: path;
    NSString *mime  = MimeForPath(entry);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        size_t len = 0;
        unsigned char *bytes = ZipCopyEntry(archive.zip, entry.UTF8String, &len);
        NSData *data = bytes ? [NSData dataWithBytesNoCopy:bytes length:len freeWhenDone:YES]
                             : nil;
        [self finishTask:task data:data mime:mime];
    });
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    [self.liveTasks removeObject:task];
}

@end

#pragma mark - BKView

@class BKView;

/* Receives reading position / font size from the page. Holds the view weakly so
 * the userContentController -> handler -> view chain is not a retain cycle. */
@interface BKMessageSink : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) BKView *owner;
@end

@interface BKView : NSView
@property (nonatomic, strong) WKWebView       *web;
@property (nonatomic, strong) BKSchemeHandler *handler;
@property (nonatomic, strong) BKMessageSink   *sink;
@property (nonatomic, copy)   NSString        *currentPath;
@property (nonatomic, copy)   NSString        *currentToken;
@property (nonatomic, assign) NSUInteger       loadCounter;
/* Reading position per book: chapter index + fraction scrolled through it. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *positionByPath;
- (BOOL)loadBookAtPath:(NSString *)path;
@end

@implementation BKMessageSink
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    BKView *v = self.owner;
    if (!v || ![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *msg = message.body;
    NSString *type = [msg[@"t"] description];

    /* Messages carry the token of the load that produced them. A message still
     * in flight from the previous book would otherwise be filed under the new
     * book's path and send the reader to a position it never reached. */
    if ([type isEqualToString:@"pos"] && v.currentPath &&
        [[msg[@"k"] description] isEqualToString:v.currentToken ?: @""]) {
        v.positionByPath[v.currentPath] = @{ @"i": msg[@"i"] ?: @0,
                                             @"r": msg[@"r"] ?: @0 };
    } else if ([type isEqualToString:@"font"]) {
        long size = [msg[@"v"] integerValue];
        if (size >= 10 && size <= 40) gFontSizeOverride = size;
    }
}
@end

@implementation BKView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _positionByPath = [NSMutableDictionary dictionary];
        _handler = [[BKSchemeHandler alloc] init];
        _sink = [[BKMessageSink alloc] init];
        _sink.owner = self;

        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        [cfg setURLSchemeHandler:_handler forURLScheme:@"x-book"];
        cfg.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        [cfg.userContentController addScriptMessageHandler:_sink name:@"dcbook"];

        _web = [[BKWebView alloc] initWithFrame:self.bounds configuration:cfg];
        _web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        @try { [_web setValue:@NO forKey:@"drawsBackground"]; } @catch (__unused id e) {}
        [self addSubview:_web];
    }
    return self;
}

/* The page shell: theming, config, and the mount points reader.js fills in. */
- (NSString *)shellHTMLForToken:(NSString *)token
                         config:(NSDictionary *)cfg
                       position:(NSDictionary *)pos
                       fileName:(NSString *)fileName
                         format:(NSString *)format {
    NSString *theme = [[cfg[@"theme"] description] lowercaseString];
    if (![@[@"light", @"dark", @"sepia"] containsObject:theme]) theme = @"auto";

    long fontSize = gFontSizeOverride ?: MAX(10, [cfg[@"fontsize"] integerValue] ?: 18);
    long maxWidth = MAX(320, [cfg[@"maxwidth"] integerValue] ?: 680);
    double lineHeight = [cfg[@"lineheight"] doubleValue] ?: 1.7;
    if (lineHeight < 1.1 || lineHeight > 2.6) lineHeight = 1.7;

    NSDictionary *jsCfg = @{
        @"base":         [NSString stringWithFormat:@"x-book://book/%@/", token],
        @"reader":       [NSString stringWithFormat:@"x-book://book/%@/%@/", token, READER_PREFIX],
        @"theme":        theme,
        @"fontSize":     @(fontSize),
        @"maxWidth":     @(maxWidth),
        @"lineHeight":   @(lineHeight),
        @"justify":      @(CfgBool(cfg, @"justify")),
        @"publisherCSS": @(CfgBool(cfg, @"publishercss")),
        @"tocOpen":      @(CfgBool(cfg, @"toc")),
        @"showVersion":  @(CfgBool(cfg, @"showversion")),
        @"version":      @BKV_VERSION,
        @"token":        token,
        @"fileName":     fileName ?: @"",
        @"position":     pos ?: @{},
        @"format":       format ?: @"epub",
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:jsCfg options:0 error:NULL];
    NSString *jsonStr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];

    /* Scripts and styles come only from this origin; images may additionally be
     * inline data: URIs. No http(s) source is permitted, so a book cannot reach
     * the network however it is written. */
    NSString *csp = @"default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
                    @"img-src 'self' data:; font-src 'self' data:; media-src 'self' data:; "
                    @"connect-src 'self'; base-uri 'none'; form-action 'none'";

    /* The sidebar's opening state is decided here rather than in script, so the
     * first paint is already correct — no flash, and no slide animation
     * competing with the chapter loading that follows. */
    BOOL tocOpen = CfgBool(cfg, @"toc") && self.bounds.size.width > 900;

    return [NSString stringWithFormat:
        @"<!DOCTYPE html><html data-theme=\"%@\"%@><head><meta charset=\"utf-8\">"
        @"<meta http-equiv=\"Content-Security-Policy\" content=\"%@\">"
        @"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        @"<title>%@</title>"
        @"<link rel=\"stylesheet\" href=\"%@reader.css\">"
        @"<script id=\"dc-config\" type=\"application/json\">%@</script>"
        @"</head><body>"
        @"<div id=\"progress\"><div id=\"progress-bar\"></div></div>"
        @"<header id=\"bar\">"
          @"<button id=\"toc-toggle\" type=\"button\" title=\"Contents (t)\" aria-label=\"Contents\">"
            @"<svg viewBox=\"0 0 16 16\" width=\"15\" height=\"15\" aria-hidden=\"true\">"
            @"<rect x=\"1\" y=\"2.5\" width=\"14\" height=\"1.6\" rx=\".8\"/>"
            @"<rect x=\"1\" y=\"7.2\" width=\"14\" height=\"1.6\" rx=\".8\"/>"
            @"<rect x=\"1\" y=\"11.9\" width=\"14\" height=\"1.6\" rx=\".8\"/></svg>"
          @"</button>"
          @"<div id=\"bar-title\"><span id=\"book-title\"></span>"
          @"<span id=\"book-author\"></span></div>"
          @"<div id=\"bar-tools\">"
            @"<button id=\"font-down\" type=\"button\" title=\"Smaller text (-)\">A&#8722;</button>"
            @"<button id=\"font-up\" type=\"button\" title=\"Larger text (+)\">A+</button>"
            @"<span id=\"percent\"></span>"
          @"</div>"
        @"</header>"
        @"<nav id=\"toc\" aria-label=\"Table of contents\"><div id=\"toc-head\">Contents</div>"
        @"<ol id=\"toc-list\"></ol></nav>"
        @"<div id=\"scrim\"></div>"
        @"<main id=\"book\"><div id=\"status\">Opening book…</div></main>"
        @"<script src=\"%@dompurify.min.js\"></script>"
        @"<script src=\"%@reader.js\"></script>"
        @"</body></html>",
        theme, tocOpen ? @" class=\"toc-open\"" : @"",
        csp, HTMLEscape(fileName), jsCfg[@"reader"], jsonStr,
        jsCfg[@"reader"], jsCfg[@"reader"]];
}

- (NSString *)errorHTMLForFile:(NSString *)fileName reason:(NSString *)reason {
    return [NSString stringWithFormat:
        @"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>"
        @"html,body{margin:0;height:100%%;display:flex;align-items:center;"
        @"justify-content:center;background:#fbfaf7;color:#3a352e;"
        @"font:14px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;}"
        @"@media(prefers-color-scheme:dark){html,body{background:#16181c;color:#c9cdd4;}}"
        @".box{max-width:480px;padding:28px;text-align:center;}"
        @".t{font-size:16px;font-weight:600;margin-bottom:8px;}"
        @".f{opacity:.6;font-size:12px;margin-top:14px;word-break:break-all;}"
        @"</style></head><body><div class=\"box\">"
        @"<div class=\"t\">Can't open this book</div><div>%@</div>"
        @"<div class=\"f\">%@</div></div></body></html>",
        HTMLEscape(reason), HTMLEscape(fileName)];
}

/* First entry that looks like a FictionBook document, for `.fbz` / zipped FB2.
 * Compared as raw bytes: ZIP entry names are not required to be UTF-8, and
 * Russian FictionBook archives are routinely written with CP866/CP1251 names,
 * which would not survive a trip through NSString. */
static const char *FB2EntryInZip(ZipArchive *zip) {
    for (size_t i = 0; i < ZipEntryCount(zip); i++) {
        const char *name = ZipEntryName(zip, i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len >= 4 && strcasecmp(name + len - 4, ".fb2") == 0) return name;
    }
    return NULL;
}

/* FictionBook is a bare XML file; the root element names it. Only the head of
 * the file is examined, and as bytes, because the declared encoding is often
 * windows-1251 and decoding is the reader's job. */
static BOOL LooksLikeFB2(NSData *data) {
    NSData *head = data.length > 4096 ? [data subdataWithRange:NSMakeRange(0, 4096)] : data;
    return [head rangeOfData:[@"FictionBook" dataUsingEncoding:NSASCIIStringEncoding]
                     options:0 range:NSMakeRange(0, head.length)].location != NSNotFound;
}

/*
 * Both supported formats are recognised from content, not from the extension:
 * a ZIP holding META-INF/container.xml is an EPUB, a ZIP holding a .fb2 entry
 * is a zipped FictionBook, and a bare XML file naming FictionBook is an FB2. A
 * mis-named book therefore still opens.
 */
- (BOOL)loadBookAtPath:(NSString *)path {
    /* The previous archive is simply released — any background read still in
     * flight holds its own reference and finishes against a live mapping. */
    self.handler.archive = nil;
    self.handler.fb2 = nil;
    self.currentPath = path;
    self.loadCounter++;

    NSString *token = [NSString stringWithFormat:@"b%lu", (unsigned long)self.loadCounter];
    NSString *fileName = [path lastPathComponent] ?: @"";
    self.handler.token = token;
    self.currentToken = token;

    NSString *format = nil;
    NSString *reason = nil;

    BKArchive *archive = path.length ? [[BKArchive alloc] initWithPath:path] : nil;
    if (archive) {
        const char *fb2Entry = NULL;
        if (ZipHasEntry(archive.zip, "META-INF/container.xml")) {
            format = @"epub";
            self.handler.archive = archive;
        } else if ((fb2Entry = FB2EntryInZip(archive.zip))) {
            size_t len = 0;
            unsigned char *bytes = ZipCopyEntry(archive.zip, fb2Entry, &len);
            if (bytes) {
                format = @"fb2";
                self.handler.fb2 = [NSData dataWithBytesNoCopy:bytes length:len freeWhenDone:YES];
            } else {
                reason = @"The FictionBook file inside this archive could not be decompressed.";
            }
            /* Everything needed is in memory; the archive can go. */
        } else {
            reason = @"This ZIP is neither an EPUB (no META-INF/container.xml) "
                     @"nor a zipped FictionBook.";
        }
    } else if (path.length) {
        NSData *raw = [NSData dataWithContentsOfFile:path
                                             options:NSDataReadingMappedIfSafe
                                               error:NULL];
        if (raw && LooksLikeFB2(raw)) {
            format = @"fb2";
            self.handler.fb2 = raw;
        } else {
            reason = raw ? @"This is neither an EPUB container nor a FictionBook document."
                         : @"The file could not be read.";
        }
    } else {
        reason = @"No file name was given.";
    }

    self.handler.shellHTML = format
        ? [self shellHTMLForToken:token
                           config:ReadConfig()
                         position:self.positionByPath[path]
                         fileName:fileName
                           format:format]
        : [self errorHTMLForFile:fileName reason:reason];

    NSString *url = [NSString stringWithFormat:@"x-book://book/%@/%@/index.html",
                     token, READER_PREFIX];
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    return format != nil;
}

- (void)dealloc {
    [_web.configuration.userContentController removeScriptMessageHandlerForName:@"dcbook"];
    _handler.archive = nil;   /* released once the last background read is done */
}

@end

#pragma mark - WLX exported API

/* Double Commander hands us a filesystem byte string, which is not necessarily
 * valid UTF-8 — a volume with legacy-codepage names produces one that isn't.
 * `stringWithUTF8String:` returns nil for those; this always round-trips. */
static NSString *PathFromABI(const char *cpath) {
    if (!cpath) return @"";
    NSString *path = [[NSFileManager defaultManager]
                         stringWithFileSystemRepresentation:cpath length:strlen(cpath)];
    return path ?: @"";
}

static BKView *MakeAndLoad(HWND ParentWin, const char *FileToLoad) {
    NSView *parent = (__bridge NSView *)ParentWin;
    NSRect frame = parent ? parent.bounds : NSMakeRect(0, 0, 800, 600);
    BKView *view = [[BKView alloc] initWithFrame:frame];
    NSString *path = PathFromABI(FileToLoad);
    /* A malformed book still gets a view — it shows why it couldn't be opened,
     * which beats falling through to a hex dump of the ZIP. */
    [view loadBookAtPath:path];
    if (parent) [parent addSubview:view];
    return view;
}

__attribute__((visibility("default")))
HWND __stdcall ListLoad(HWND ParentWin, char *FileToLoad, int ShowFlags) {
    (void)ShowFlags;
    __block BKView *result = nil;
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
    BKView *view = (__bridge BKView *)PluginWin;
    if (![view isKindOfClass:[BKView class]]) return LISTPLUGIN_ERROR;
    NSString *path = PathFromABI(FileToLoad);
    __block BOOL ok = NO;
    if ([NSThread isMainThread]) {
        ok = [view loadBookAtPath:path];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{ ok = [view loadBookAtPath:path]; });
    }
    return ok ? LISTPLUGIN_OK : LISTPLUGIN_ERROR;
}

__attribute__((visibility("default")))
void __stdcall ListCloseWindow(HWND ListWin) {
    if (!ListWin) return;
    void (^close)(void) = ^{
        BKView *view = (BKView *)CFBridgingRelease(ListWin); /* -1 */
        [view removeFromSuperview];
    };
    if ([NSThread isMainThread]) close();
    else dispatch_sync(dispatch_get_main_queue(), close);
}

__attribute__((visibility("default")))
void __stdcall ListGetDetectString(char *DetectString, int maxlen) {
    if (!DetectString || maxlen <= 0) return;
    const char *s = "EXT=\"EPUB\"|EXT=\"FB2\"|EXT=\"FBZ\"";
    strncpy(DetectString, s, maxlen - 1);
    DetectString[maxlen - 1] = '\0';
}

__attribute__((visibility("default")))
void __stdcall ListSetDefaultParams(ListDefaultParamStruct *dps) {
    if (dps && dps->DefaultIniName[0]) {
        gIniPath = [NSString stringWithUTF8String:dps->DefaultIniName];
    }
}
