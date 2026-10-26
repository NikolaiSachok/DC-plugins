/*
 * ImageView.wlx — Double Commander Lister (WLX) plugin for macOS.
 * Shows images in the F3 viewer and Quick View with free zoom (pinch,
 * Cmd+scroll, keyboard, toolbar), mouse-drag panning, and SVG that stays sharp
 * at any magnification.
 *
 * How it fits together
 * --------------------
 * Everything is native; there is no web view and nothing vendored.
 *
 *   - Raster formats are decoded with ImageIO, which on current macOS reads
 *     some sixty types (PNG, JPEG, HEIC, AVIF, JPEG XL, WebP, TIFF, PSD, EXR,
 *     camera RAW, ...). Decoding runs off the main thread; a cheap header read
 *     in ListLoad decides whether the file is an image at all, so a file the
 *     plugin cannot show falls through to the next lister (MacPreview).
 *   - SVG is drawn by AppKit's own renderer (NSImage's SVG representation, i.e.
 *     CoreSVG). It stays vector, so it is redrawn from the source at every
 *     magnification. It never runs script and never fetches an external
 *     resource, which is what makes untrusted SVG safe to show without a
 *     sanitizer.
 *   - Zoom and scrolling are NSScrollView's (allowsMagnification), the same
 *     machinery Preview uses: native pinch, momentum scrolling and
 *     zoom-around-a-point come for free.
 *
 * Double Commander enables floating-point exception traps (it is an FPC app),
 * and harmless FP math inside Apple's frameworks then crashes the host. Every
 * call into image decoding, SVG rendering or magnification therefore runs with
 * the default (masked) FP environment; see WithMaskedFP.
 *
 * On macOS, Double Commander passes/expects NSView* as the window handle.
 */

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <fenv.h>
#include <zlib.h>
#include "listplug.h"

#define IV_VERSION "0.1.1"   /* single source of truth for the plugin version */

/* Display bitmaps are capped so a 200-megapixel scan can't exhaust memory or
 * exceed the GPU's texture size: the longest side at 16384 px and the area at
 * 64 MP. Typical photos and RAW files are well inside it and show every pixel. */
static const double kMaxDisplaySide   = 16384;
static const double kMaxDisplayPixels = 64.0 * 1024 * 1024;

static const CGFloat kToolbarHeight = 30;
static const CGFloat kMaxMagnification = 64;

/* The extensions this plugin claims, as Double Commander's detect string. It is
 * the single source of truth: register_plugin.py reads it from the built
 * plugin through ListGetDetectString. */
static const char *kDetectString =
    "EXT=\"PNG\"|EXT=\"APNG\"|EXT=\"JPG\"|EXT=\"JPEG\"|EXT=\"JPE\"|EXT=\"JFIF\"|"
    "EXT=\"GIF\"|EXT=\"WEBP\"|EXT=\"HEIC\"|EXT=\"HEIF\"|EXT=\"HIF\"|EXT=\"HEICS\"|"
    "EXT=\"AVIF\"|EXT=\"JXL\"|EXT=\"TIF\"|EXT=\"TIFF\"|EXT=\"BMP\"|EXT=\"DIB\"|"
    "EXT=\"ICO\"|EXT=\"CUR\"|EXT=\"ICNS\"|EXT=\"PSD\"|EXT=\"TGA\"|EXT=\"EXR\"|"
    "EXT=\"HDR\"|EXT=\"DDS\"|EXT=\"KTX\"|EXT=\"ASTC\"|EXT=\"PVR\"|EXT=\"JP2\"|"
    "EXT=\"J2K\"|EXT=\"JPF\"|EXT=\"JPX\"|EXT=\"J2C\"|EXT=\"PBM\"|EXT=\"PGM\"|"
    "EXT=\"PPM\"|EXT=\"PFM\"|EXT=\"SGI\"|EXT=\"MPO\"|EXT=\"PICT\"|EXT=\"PCT\"|"
    "EXT=\"DCM\"|EXT=\"DNG\"|EXT=\"CR2\"|EXT=\"CR3\"|EXT=\"CRW\"|EXT=\"NEF\"|"
    "EXT=\"NRW\"|EXT=\"ARW\"|EXT=\"SRF\"|EXT=\"SR2\"|EXT=\"RAF\"|EXT=\"ORF\"|"
    "EXT=\"RW2\"|EXT=\"RWL\"|EXT=\"RAW\"|EXT=\"PEF\"|EXT=\"SRW\"|EXT=\"IIQ\"|"
    "EXT=\"3FR\"|EXT=\"FFF\"|EXT=\"MOS\"|EXT=\"MRW\"|EXT=\"ERF\"|EXT=\"DCR\"|"
    "EXT=\"SVG\"|EXT=\"SVGZ\"";

#pragma mark - Helpers

/* Run `block` with floating-point exceptions masked, then restore the host's
 * environment. Double Commander traps FP exceptions; Apple's frameworks assume
 * they are masked (see the header comment). */
static void WithMaskedFP(void (^block)(void)) {
    fenv_t host;
    fegetenv(&host);
    fesetenv(FE_DFL_ENV);
    @try { block(); }
    @finally { fesetenv(&host); }
}

/* Every ABI entry point does its work here: on the main thread, with FP
 * exceptions masked for everything it reaches (view creation, decoding,
 * layout), whatever the calling thread's environment. */
static void OnMain(void (^block)(void)) {
    void (^masked)(void) = ^{ WithMaskedFP(block); };
    if ([NSThread isMainThread]) masked();
    else dispatch_sync(dispatch_get_main_queue(), masked);
}

/* gzip-compressed data (an .svgz), inflated; nil if it isn't gzip or is corrupt.
 * CoreSVG reads only plain SVG. */
static NSData *Gunzip(NSData *data) {
    const uint8_t *b = data.bytes;
    if (data.length < 18 || b[0] != 0x1f || b[1] != 0x8b) return nil;
    z_stream zs = {0};
    if (inflateInit2(&zs, 15 + 16) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:data.length * 4];
    zs.next_in = (Bytef *)b;
    zs.avail_in = (uInt)data.length;
    int rc = Z_OK;
    while (rc == Z_OK) {
        if (zs.total_out >= out.length) {
            if (out.length > 256u * 1024 * 1024) break;   /* a decompression bomb */
            out.length *= 2;
        }
        zs.next_out = (Bytef *)out.mutableBytes + zs.total_out;
        zs.avail_out = (uInt)(out.length - zs.total_out);
        rc = inflate(&zs, Z_NO_FLUSH);
    }
    inflateEnd(&zs);
    if (rc != Z_STREAM_END) return nil;
    out.length = zs.total_out;
    return out;
}

/* Delay of one animation frame, in seconds, or -1 when the frame carries none
 * (a multi-page TIFF, say, which is not an animation). Follows browsers: a
 * delay of 10 ms or less means "as fast as the author dared" and shows at
 * 100 ms, which is how the files were tested by their authors. */
static double FrameDelay(NSDictionary *props) {
    for (NSString *dict in @[ (id)kCGImagePropertyGIFDictionary, (id)kCGImagePropertyPNGDictionary,
                               (id)kCGImagePropertyWebPDictionary, @"{HEICS}" ]) {
        NSDictionary *d = props[dict];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *v = d[@"UnclampedDelayTime"] ?: d[@"DelayTime"];
        if (!v) continue;
        double s = v.doubleValue;
        return s <= 0.011 ? 0.1 : s;
    }
    return -1;
}

/* 0 = loop forever. */
static NSUInteger LoopCount(NSDictionary *props) {
    for (NSString *dict in @[ (id)kCGImagePropertyGIFDictionary, (id)kCGImagePropertyPNGDictionary,
                               (id)kCGImagePropertyWebPDictionary, @"{HEICS}" ]) {
        NSDictionary *d = props[dict];
        if ([d isKindOfClass:[NSDictionary class]] && d[@"LoopCount"])
            return [d[@"LoopCount"] unsignedIntegerValue];
    }
    return 0;
}

#pragma mark - IVImage

typedef NS_ENUM(NSInteger, IVKind) { IVKindRaster, IVKindVector };

/*
 * One opened file. Built synchronously from the file's header (cheap); the
 * raster pixels themselves are decoded later, off the main thread.
 */
@interface IVImage : NSObject
@property (nonatomic) IVKind kind;
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, copy)   NSString *format;       /* "PNG", "HEIC", "SVG", ... */
@property (nonatomic)         NSSize    size;         /* display size in points (pixels for raster, after EXIF orientation) */
@property (nonatomic)         NSSize    pixelSize;    /* stored pixel size, for the toolbar */
@property (nonatomic)         unsigned long long fileSize;
@property (nonatomic)         BOOL      hasAlpha;
@property (nonatomic, strong) NSImageRep *vector;     /* the SVG */
@property (nonatomic, strong) NSData   *vectorData;   /* the SVG source, for Copy */
@property (nonatomic, strong) id        source;       /* CGImageSourceRef */
@property (nonatomic)         size_t    index;        /* which image in the source to show */
@property (nonatomic)         size_t    frameCount;   /* > 1 only for an animation */
@property (nonatomic)         NSUInteger loopCount;
@property (nonatomic)         BOOL      oriented;     /* EXIF orientation is not "up" */
+ (instancetype)imageAtPath:(NSString *)path;
@end

@implementation IVImage

+ (instancetype)imageAtPath:(NSString *)path {
    if (!path.length) return nil;
    __block IVImage *image = nil;
    WithMaskedFP(^{
        NSString *ext = path.pathExtension.lowercaseString;
        image = ([ext isEqualToString:@"svg"] || [ext isEqualToString:@"svgz"])
            ? [self vectorAtPath:path] : [self rasterAtPath:path];
    });
    if (image) {
        image.path = path;
        image.fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL]
                             fileSize];
    }
    return image;
}

/* CoreSVG does not know the CSS `transparent` keyword and paints it black,
 * so a connector drawn as `fill="transparent"` (Miro and other diagram tools
 * export them that way) becomes a solid black wedge, and a gradient fading to
 * `transparent` a black band. The keyword is rewritten before CoreSVG sees
 * it: to rgba(0,0,0,0) for fill, stroke and color; for stop-color and
 * flood-color, whose alpha CoreSVG ignores, to black at stop-opacity /
 * flood-opacity 0. CSS is rewritten only inside style attributes and <style>
 * elements, so text that reads "fill: transparent" is left alone. */
static NSData *CoreSVGCompatible(NSData *svg) {
    static const char kKeyword[] = "transparent";
    if (!memmem(svg.bytes, svg.length, kKeyword, sizeof kKeyword - 1)) return svg;
    NSString *text = [[NSString alloc] initWithData:svg encoding:NSUTF8StringEncoding];
    if (!text) return svg;
    static NSRegularExpression *paintAttr, *paintCSS, *opacityCSS, *opacityTag, *styles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSRegularExpressionOptions ci = NSRegularExpressionCaseInsensitive;
        NSString *value = @"(\\s*=\\s*)([\"'])\\s*transparent\\s*\\3";
        paintAttr = [NSRegularExpression regularExpressionWithPattern:
                     [@"(?<![\\w:-])(fill|stroke|color)" stringByAppendingString:value] options:ci error:NULL];
        paintCSS = [NSRegularExpression regularExpressionWithPattern:
                    @"(?<![\\w:-])(fill|stroke|color)(\\s*:\\s*)transparent(?![\\w-])" options:ci error:NULL];
        opacityCSS = [NSRegularExpression regularExpressionWithPattern:
                      @"(?<![\\w:-])(stop|flood)-color\\s*:\\s*transparent(?![\\w-])" options:ci error:NULL];
        opacityTag = [NSRegularExpression regularExpressionWithPattern:
                      @"<[^>]*?(?<![\\w:-])(stop|flood)-color\\s*=\\s*([\"'])\\s*transparent\\s*\\2[^>]*>"
                      options:ci error:NULL];
        styles = [NSRegularExpression regularExpressionWithPattern:
                  @"(?<![\\w:-])style\\s*=\\s*(\"[^\"]*\"|'[^']*')|<style\\b[^>]*>.*?</style\\s*>"
                  options:ci | NSRegularExpressionDotMatchesLineSeparators error:NULL];
    });
    NSMutableString *out = [text mutableCopy];
    [paintAttr replaceMatchesInString:out options:0 range:NSMakeRange(0, out.length)
                         withTemplate:@"$1$2$3rgba(0,0,0,0)$3"];
    /* Back to front, so the ranges still ahead stay valid. */
    for (NSTextCheckingResult *m in [opacityTag matchesInString:out options:0
                                                          range:NSMakeRange(0, out.length)].reverseObjectEnumerator) {
        NSString *kind = [[out substringWithRange:[m rangeAtIndex:1]] lowercaseString];
        NSMutableString *tag = [[out substringWithRange:m.range] mutableCopy];
        /* The element's own opacity attribute, if any, gives way to ours. */
        NSString *own = [NSString stringWithFormat:@"\\s(?<![\\w:-])%@-opacity\\s*=\\s*(\"[^\"]*\"|'[^']*')", kind];
        [[NSRegularExpression regularExpressionWithPattern:own options:NSRegularExpressionCaseInsensitive error:NULL]
            replaceMatchesInString:tag options:0 range:NSMakeRange(0, tag.length) withTemplate:@""];
        NSString *color = [NSString stringWithFormat:@"(?<![\\w:-])%@-color\\s*=\\s*([\"'])\\s*transparent\\s*\\1", kind];
        NSString *black = [NSString stringWithFormat:@"%@-color=\"#000\" %@-opacity=\"0\"", kind, kind];
        [[NSRegularExpression regularExpressionWithPattern:color options:NSRegularExpressionCaseInsensitive error:NULL]
            replaceMatchesInString:tag options:0 range:NSMakeRange(0, tag.length)
                      withTemplate:[NSRegularExpression escapedTemplateForString:black]];
        [out replaceCharactersInRange:m.range withString:tag];
    }
    for (NSTextCheckingResult *m in [styles matchesInString:out options:0
                                                      range:NSMakeRange(0, out.length)].reverseObjectEnumerator) {
        NSMutableString *css = [[out substringWithRange:m.range] mutableCopy];
        [paintCSS replaceMatchesInString:css options:0 range:NSMakeRange(0, css.length)
                            withTemplate:@"$1$2rgba(0,0,0,0)"];
        [opacityCSS replaceMatchesInString:css options:0 range:NSMakeRange(0, css.length)
                              withTemplate:@"$1-color:#000;$1-opacity:0"];
        [out replaceCharactersInRange:m.range withString:css];
    }
    return [out dataUsingEncoding:NSUTF8StringEncoding];
}

+ (instancetype)vectorAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data) return nil;
    NSData *plain = Gunzip(data) ?: data;
    NSImage *svg = [[NSImage alloc] initWithData:CoreSVGCompatible(plain)];
    /* Keep the SVG's own image rep, not the NSImage. Drawn through NSImage,
     * CoreSVG renders the whole document at the zoomed resolution and only
     * then clips to what is being repainted, so panning a large diagram at
     * 400% took seconds per step. The rep, drawn under the view's transform
     * and clip, draws only what is exposed and stays sharp at any zoom. */
    NSImageRep *vector = nil;
    for (NSImageRep *rep in svg.representations)
        if (![rep isKindOfClass:[NSBitmapImageRep class]]) { vector = rep; break; }
    if (!vector || svg.size.width < 1 || svg.size.height < 1) return nil;

    IVImage *image = [[IVImage alloc] init];
    image.kind = IVKindVector;
    image.format = @"SVG";
    image.vector = vector;
    image.vectorData = plain;
    image.size = svg.size;
    image.pixelSize = svg.size;
    image.hasAlpha = YES;
    return image;
}

+ (instancetype)rasterAtPath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url,
                               (__bridge CFDictionaryRef)@{ (id)kCGImageSourceShouldCache: @NO });
    if (!src) return nil;
    id source = CFBridgingRelease(src);
    size_t count = CGImageSourceGetCount(src);
    NSString *type = (__bridge NSString *)CGImageSourceGetType(src);
    if (count == 0 || !type) return nil;

    /* Which image to show: the primary one (HEIC), or for icon containers the
     * largest (an .ico lists its 16 px version first). */
    size_t index = CGImageSourceGetPrimaryImageIndex(src);
    if ([@[ @"com.microsoft.ico", @"com.microsoft.cur", @"com.apple.icns" ] containsObject:type]) {
        double best = 0;
        for (size_t i = 0; i < count; i++) {
            NSDictionary *p = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
            double area = [p[(id)kCGImagePropertyPixelWidth] doubleValue] *
                          [p[(id)kCGImagePropertyPixelHeight] doubleValue];
            if (area > best) { best = area; index = i; }
        }
    }
    if (index >= count) index = 0;

    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, index, NULL));
    double w = [props[(id)kCGImagePropertyPixelWidth] doubleValue];
    double h = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
    if (w < 1 || h < 1) return nil;
    int orientation = [props[(id)kCGImagePropertyOrientation] intValue];

    IVImage *image = [[IVImage alloc] init];
    image.kind = IVKindRaster;
    image.source = source;
    image.index = index;
    image.pixelSize = NSMakeSize(w, h);
    image.oriented = orientation > 1 && orientation <= 8;
    image.size = orientation >= 5 && orientation <= 8 ? NSMakeSize(h, w) : NSMakeSize(w, h);
    image.hasAlpha = [props[(id)kCGImagePropertyHasAlpha] boolValue];
    UTType *ut = [UTType typeWithIdentifier:type];
    image.format = (ut.preferredFilenameExtension ?: path.pathExtension).uppercaseString;

    /* An animation is a sequence whose frames carry a delay; a multi-page TIFF
     * has several images and no delays. */
    if (count > 1 && FrameDelay(props) >= 0) {
        image.frameCount = count;
        image.index = 0;
        NSDictionary *top = CFBridgingRelease(CGImageSourceCopyProperties(src, NULL));
        image.loopCount = LoopCount(top);
    }
    return image;
}

/* The pixels to show for the still image (or an animation's first frame),
 * scaled down only when it is beyond the display caps. Call off the main
 * thread; returns a +0 autoreleased CGImage wrapped as id. */
- (id)decodeDisplayImage {
    __block id result = nil;
    WithMaskedFP(^{
        CGImageSourceRef src = (__bridge CGImageSourceRef)self.source;
        double w = self.pixelSize.width, h = self.pixelSize.height;
        double scale = MIN(1.0, MIN(kMaxDisplaySide / MAX(w, h), sqrt(kMaxDisplayPixels / (w * h))));
        CGImageRef cg = NULL;
        if (scale >= 1.0 && !self.oriented) {
            /* Full size and upright: decode as stored, keeping its bit depth. */
            cg = CGImageSourceCreateImageAtIndex(src, self.index, (__bridge CFDictionaryRef)@{
                (id)kCGImageSourceShouldCacheImmediately: @YES });
        } else {
            cg = CGImageSourceCreateThumbnailAtIndex(src, self.index, (__bridge CFDictionaryRef)@{
                (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                (id)kCGImageSourceCreateThumbnailWithTransform:   @YES,
                (id)kCGImageSourceShouldCacheImmediately:         @YES,
                (id)kCGImageSourceThumbnailMaxPixelSize:          @(ceil(MAX(w, h) * scale)) });
        }
        if (cg) result = CFBridgingRelease(cg);
    });
    return result;
}

/* One animation frame, as composited by ImageIO, plus its delay. */
- (id)decodeFrame:(size_t)i delay:(double *)delay {
    __block id result = nil;
    __block double d = 0.1;
    WithMaskedFP(^{
        CGImageSourceRef src = (__bridge CGImageSourceRef)self.source;
        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, i, (__bridge CFDictionaryRef)@{
            (id)kCGImageSourceShouldCacheImmediately: @YES });
        if (cg) result = CFBridgingRelease(cg);
        NSDictionary *p = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
        double v = FrameDelay(p);
        if (v > 0) d = v;
    });
    if (delay) *delay = d;
    return result;
}

@end

#pragma mark - Canvas (the scroll view's document view)

@class IVView;

/*
 * The image's pixels. Up to 200% they are a layer's contents and the GPU
 * scales them, so fitting a 50-megapixel photo to the window and playing an
 * animation cost nothing on the CPU. Past 200% the view shows the actual
 * pixels, the way image editors do, rather than blurring them together: it
 * draws them itself without interpolation. AppKit renders a magnified view's
 * drawing at the magnified resolution, and only the visible part, so this is
 * exact at any zoom and costs little (the visible part is at most half the
 * window's pixels).
 */
@interface IVRasterView : NSView
@property (nonatomic, strong) id cgImage;
@property (nonatomic) BOOL pixelated;
@end

@implementation IVRasterView
- (BOOL)wantsUpdateLayer { return !self.pixelated; }
- (BOOL)isFlipped { return YES; }
- (void)updateLayer {
    CALayer *layer = self.layer;
    layer.contents = self.cgImage;
    layer.contentsGravity = kCAGravityResize;
    layer.minificationFilter = kCAFilterTrilinear;
    layer.magnificationFilter = kCAFilterLinear;
}
- (void)drawRect:(NSRect)dirty {
    CGImageRef cg = (__bridge CGImageRef)self.cgImage;
    if (!cg) return;
    WithMaskedFP(^{
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, NSRectToCGRect(dirty));
        CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
        /* The view is flipped; CGContextDrawImage draws bottom-up. */
        CGContextTranslateCTM(ctx, 0, NSHeight(self.bounds));
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, NSRectToCGRect(self.bounds), cg);
        CGContextRestoreGState(ctx);
    });
}
- (void)setCgImage:(id)cgImage { _cgImage = cgImage; self.needsDisplay = YES; }
- (void)setPixelated:(BOOL)p {
    if (p == _pixelated) return;
    _pixelated = p;
    /* Switching between the two ways of drawing: the layer's contents must
     * not linger under the drawn pixels, nor be missing when the layer takes
     * over again. */
    self.layer.contents = nil;
    self.needsDisplay = YES;
}
- (NSView *)hitTest:(NSPoint)p { (void)p; return nil; }   /* mouse goes to the canvas */
@end

/*
 * Draws the transparency checkerboard and the SVG; hosts the raster view.
 * Sized to the image in points, so the scroll view's magnification is the zoom
 * factor and 100% is one image pixel per point.
 */
@interface IVCanvas : NSView
@property (nonatomic, weak)   IVView       *owner;
@property (nonatomic, strong) NSImageRep   *vector;
@property (nonatomic)         BOOL          checkerboard;
@property (nonatomic, strong) IVRasterView *raster;
@property (nonatomic)         NSPoint       dragStart;    /* window coords */
@property (nonatomic)         NSPoint       originStart;  /* clip view bounds origin */
@property (nonatomic)         BOOL          dragging;
@end

/* The load counter. Background work reads it through this object, never
 * through the view, so it cannot hold the view's last reference and end up
 * deallocating an NSView off the main thread. */
@interface IVGeneration : NSObject
@property (atomic) NSUInteger value;
@end
@implementation IVGeneration
@end

@interface IVView : NSView
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) IVCanvas     *canvas;
- (void)toggleFitAtPoint:(NSPoint)docPoint;
- (void)zoomBy:(CGFloat)factor atPoint:(NSPoint)docPoint;
- (void)magnificationDidChange;
- (BOOL)handleZoomKey:(NSEvent *)event;
- (BOOL)isPannable;
- (void)claimFocusIfUnclaimed;
@end

@implementation IVCanvas

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        _raster = [[IVRasterView alloc] initWithFrame:self.bounds];
        _raster.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_raster];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return YES; }

- (void)drawRect:(NSRect)dirty {
    WithMaskedFP(^{
        if (self.checkerboard) [self drawCheckerboardIn:dirty];
        if (!self.vector) return;
        /* An image rep draws bottom-up; the canvas is flipped. */
        CGContextRef c = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(c);
        CGContextTranslateCTM(c, 0, NSHeight(self.bounds));
        CGContextScaleCTM(c, 1, -1);
        [self.vector drawInRect:NSMakeRect(0, 0, NSWidth(self.bounds), NSHeight(self.bounds))];
        CGContextRestoreGState(c);
    });
}

/* Squares stay 8 points on screen whatever the zoom, like an image editor's. */
- (void)drawCheckerboardIn:(NSRect)dirty {
    CGFloat mag = MAX(self.enclosingScrollView.magnification, 0.001);
    CGFloat sq = 8.0 / mag;
    BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:
                    @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] == NSAppearanceNameDarkAqua;
    [(dark ? [NSColor colorWithWhite:0.20 alpha:1] : [NSColor colorWithWhite:1.0 alpha:1]) setFill];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
    [(dark ? [NSColor colorWithWhite:0.26 alpha:1] : [NSColor colorWithWhite:0.90 alpha:1]) setFill];
    NSRect r = NSIntersectionRect(dirty, self.bounds);
    long x0 = (long)floor(NSMinX(r) / sq), x1 = (long)ceil(NSMaxX(r) / sq);
    long y0 = (long)floor(NSMinY(r) / sq), y1 = (long)ceil(NSMaxY(r) / sq);
    for (long y = y0; y < y1; y++)
        for (long x = x0 + ((x0 + y) & 1); x < x1; x += 2)
            NSRectFill(NSIntersectionRect(NSMakeRect(x * sq, y * sq, sq, sq), self.bounds));
}

#pragma mark Mouse: drag to pan, double-click to toggle Fit / 100%

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (event.clickCount == 2) { [self.owner toggleFitAtPoint:p]; return; }
    self.dragging = [self.owner isPannable];
    if (!self.dragging) return;
    self.dragStart = event.locationInWindow;
    self.originStart = self.enclosingScrollView.contentView.bounds.origin;
    [[NSCursor closedHandCursor] push];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.dragging) return;
    NSClipView *clip = self.enclosingScrollView.contentView;
    CGFloat mag = MAX(self.enclosingScrollView.magnification, 0.001);
    NSPoint now = event.locationInWindow;
    /* Window y grows upwards, the flipped document's downwards. */
    NSPoint origin = NSMakePoint(self.originStart.x - (now.x - self.dragStart.x) / mag,
                                 self.originStart.y + (now.y - self.dragStart.y) / mag);
    NSRect b = clip.bounds;
    b.origin = origin;
    [clip scrollToPoint:[clip constrainBoundsRect:b].origin];
    [self.enclosingScrollView reflectScrolledClipView:clip];
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (self.dragging) [NSCursor pop];
    self.dragging = NO;
}

#pragma mark Keyboard

/* The image keeps only the keys it uses: the zoom keys, and the arrows, Page
 * Up/Down, Home/End and Space without a modifier, which scroll. Every other
 * key belongs to Double Commander's viewer: Esc / Q close it, N / P and
 * Alt+Right / Alt+Left load the next or previous file, the digits switch view
 * mode. LCL processes its shortcuts through NSApplication's event dispatch
 * (-sendEvent:), not through -keyDown: forwarding along the responder chain,
 * so a key the plugin's view merely passes on never reaches it. The plugin
 * moves focus to DC's own view and re-posts the event, as markdown-wlx and
 * book-wlx do for Escape. */
- (void)keyDown:(NSEvent *)event {
    if ([self.owner handleZoomKey:event]) return;
    if ([self isScrollKey:event]) { [self interpretKeyEvents:@[ event ]]; return; }
    [self handKeyToHost:event];
}

- (BOOL)isScrollKey:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl);
    if (mods) return NO;
    switch (event.keyCode) {
        case 123: case 124: case 125: case 126:   /* arrows */
        case 116: case 121:                       /* Page Up, Page Down */
        case 115: case 119:                       /* Home, End */
        case 49:                                  /* Space */
            return YES;
        default:
            return NO;
    }
}

- (void)handKeyToHost:(NSEvent *)event {
    NSWindow *win = self.window;
    if (!win) return;
    NSView *dcView = self.owner.superview;
    BOOL moved = NO;
    if ([dcView isKindOfClass:[NSView class]]) moved = [win makeFirstResponder:dcView];
    if (!moved) moved = [win makeFirstResponder:win.contentView];
    if (!moved) moved = [win makeFirstResponder:nil];
    if (win.firstResponder == self) return; /* couldn't move focus; avoid a loop */

    NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                    location:event.locationInWindow
                               modifierFlags:event.modifierFlags
                                   timestamp:event.timestamp
                                windowNumber:event.windowNumber
                                     context:nil
                                  characters:event.characters
                 charactersIgnoringModifiers:event.charactersIgnoringModifiers
                                   isARepeat:event.isARepeat
                                     keyCode:event.keyCode];
    [NSApp postEvent:key atStart:YES];

    /* Take focus back once DC has handled the key, so the arrows keep panning
     * the next image after N. The re-posted event is at the head of the queue
     * and is dispatched before the run loop gets to this block. Not when DC
     * moved focus to a control of its own, closed the viewer, or opened a
     * dialog. */
    __weak IVView *owner = self.owner;
    dispatch_async(dispatch_get_main_queue(), ^{
        IVView *me = owner;
        if (me.window.isKeyWindow) [me claimFocusIfUnclaimed];
    });
}

/* Arrow keys, Page Up/Down, Home/End and Space scroll the image. */
- (void)scrollBy:(NSPoint)delta {
    NSClipView *clip = self.enclosingScrollView.contentView;
    NSRect b = clip.bounds;
    b.origin.x += delta.x;
    b.origin.y += delta.y;
    [clip scrollToPoint:[clip constrainBoundsRect:b].origin];
    [self.enclosingScrollView reflectScrolledClipView:clip];
}
- (CGFloat)lineStep { return 40 / MAX(self.enclosingScrollView.magnification, 0.001); }
- (CGFloat)pageStep { return NSHeight(self.enclosingScrollView.contentView.bounds) * 0.9; }
- (void)moveUp:(id)s    { (void)s; [self scrollBy:NSMakePoint(0, -[self lineStep])]; }
- (void)moveDown:(id)s  { (void)s; [self scrollBy:NSMakePoint(0,  [self lineStep])]; }
- (void)moveLeft:(id)s  { (void)s; [self scrollBy:NSMakePoint(-[self lineStep], 0)]; }
- (void)moveRight:(id)s { (void)s; [self scrollBy:NSMakePoint( [self lineStep], 0)]; }
- (void)scrollPageUp:(id)s   { (void)s; [self scrollBy:NSMakePoint(0, -[self pageStep])]; }
- (void)scrollPageDown:(id)s { (void)s; [self scrollBy:NSMakePoint(0,  [self pageStep])]; }
- (void)pageUp:(id)s         { [self scrollPageUp:s]; }
- (void)pageDown:(id)s       { [self scrollPageDown:s]; }
- (void)insertText:(id)text { (void)text; [self scrollPageDown:nil]; } /* Space */
- (void)scrollToBeginningOfDocument:(id)s { (void)s; [self scrollBy:NSMakePoint(0, -CGFLOAT_MAX / 4)]; }
- (void)scrollToEndOfDocument:(id)s       { (void)s; [self scrollBy:NSMakePoint(0,  CGFLOAT_MAX / 4)]; }
- (void)moveToBeginningOfDocument:(id)s   { [self scrollToBeginningOfDocument:s]; }
- (void)moveToEndOfDocument:(id)s         { [self scrollToEndOfDocument:s]; }
- (void)doCommandBySelector:(SEL)sel {
    if ([self respondsToSelector:sel])
        ((void (*)(id, SEL, id))[self methodForSelector:sel])(self, sel, nil);
}

@end

#pragma mark - Scroll view

/* Centers an image smaller than the view instead of pinning it to a corner. */
@interface IVClipView : NSClipView
@end

@implementation IVClipView
- (NSRect)constrainBoundsRect:(NSRect)proposed {
    NSRect r = [super constrainBoundsRect:proposed];
    NSView *doc = self.documentView;
    if (!doc) return r;
    NSRect f = doc.frame;
    if (NSWidth(r) > NSWidth(f))   r.origin.x = NSMinX(f) - (NSWidth(r) - NSWidth(f)) / 2;
    if (NSHeight(r) > NSHeight(f)) r.origin.y = NSMinY(f) - (NSHeight(r) - NSHeight(f)) / 2;
    return r;
}
@end

/* Pinch is NSScrollView's own; this adds Cmd/Option+scroll zoom around the
 * pointer, maps the two-finger double tap to Fit / 100%, and keeps the toolbar
 * in step. Every AppKit magnification call runs with FP exceptions masked. */
@interface IVScrollView : NSScrollView
@property (nonatomic, weak) IVView *owner;
@end

@implementation IVScrollView

- (void)scrollWheel:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (!(mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption))) {
        WithMaskedFP(^{ [super scrollWheel:event]; });
        return;
    }
    CGFloat dy = event.scrollingDeltaY;
    if (dy == 0) return;
    CGFloat factor = event.hasPreciseScrollingDeltas ? exp(dy * 0.01) : pow(1.15, dy > 0 ? 1 : -1);
    NSPoint p = [self.documentView convertPoint:event.locationInWindow fromView:nil];
    [self.owner zoomBy:factor atPoint:p];
}

- (void)magnifyWithEvent:(NSEvent *)event {
    WithMaskedFP(^{ [super magnifyWithEvent:event]; });
    [self.owner magnificationDidChange];
}

- (void)smartMagnifyWithEvent:(NSEvent *)event {
    [self.owner toggleFitAtPoint:[self.documentView convertPoint:event.locationInWindow fromView:nil]];
}

@end

#pragma mark - Toolbar background

/* The window background colour, resolved for the current appearance, so the
 * toolbar reads the same in light and dark mode whatever the host draws
 * behind the plugin. */
@interface IVToolbar : NSView
@end

@implementation IVToolbar
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;
    }];
}
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
@end

#pragma mark - IVView

typedef NS_ENUM(NSInteger, IVZoomMode) {
    IVZoomFit,           /* fit the window, enlarging small images */
    IVZoomFitLarge,      /* fit the window, never enlarge */
    IVZoomActual,        /* 100% */
    IVZoomManual,        /* whatever the user zoomed to; left alone on resize */
};

@interface IVView ()
@property (nonatomic, strong) IVImage     *image;
@property (nonatomic)         IVZoomMode   mode;
@property (nonatomic, strong) IVGeneration *generation;   /* bumped per load / close */
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, strong) id           keyMonitor;
@property (nonatomic)         CGFloat      shownMagnification;   /* what the toolbar and filters reflect */
/* Toolbar */
@property (nonatomic, strong) NSView        *toolbar;
@property (nonatomic, strong) NSPopUpButton *zoomPopup;
@property (nonatomic, strong) NSTextField   *infoLabel;
@property (nonatomic, strong) NSTextField   *messageLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@end

@implementation IVView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.wantsLayer = YES;
        _generation = [[IVGeneration alloc] init];
        _decodeQueue = dispatch_queue_create("image-wlx.decode", DISPATCH_QUEUE_SERIAL);

        NSRect body = NSMakeRect(0, 0, NSWidth(frame), MAX(0, NSHeight(frame) - kToolbarHeight));
        _scroll = [[IVScrollView alloc] initWithFrame:body];
        ((IVScrollView *)_scroll).owner = self;
        _scroll.contentView = [[IVClipView alloc] initWithFrame:body];
        _scroll.hasVerticalScroller = YES;
        _scroll.hasHorizontalScroller = YES;
        _scroll.autohidesScrollers = YES;
        _scroll.scrollerStyle = NSScrollerStyleOverlay;
        _scroll.borderType = NSNoBorder;
        _scroll.drawsBackground = YES;
        _scroll.backgroundColor = [NSColor underPageBackgroundColor];
        _scroll.allowsMagnification = YES;
        _scroll.maxMagnification = kMaxMagnification;
        _scroll.minMagnification = 0.01;

        _canvas = [[IVCanvas alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
        _canvas.owner = self;
        _scroll.documentView = _canvas;
        [self addSubview:_scroll];

        [self buildToolbar];

        _messageLabel = [NSTextField wrappingLabelWithString:@""];
        _messageLabel.alignment = NSTextAlignmentCenter;
        _messageLabel.textColor = [NSColor secondaryLabelColor];
        _messageLabel.hidden = YES;
        _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_messageLabel];
        _spinner = [[NSProgressIndicator alloc] init];
        _spinner.style = NSProgressIndicatorStyleSpinning;
        _spinner.displayedWhenStopped = NO;
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_spinner];
        [NSLayoutConstraint activateConstraints:@[
            [_messageLabel.centerXAnchor constraintEqualToAnchor:_scroll.centerXAnchor],
            [_messageLabel.centerYAnchor constraintEqualToAnchor:_scroll.centerYAnchor],
            [_messageLabel.widthAnchor constraintLessThanOrEqualToConstant:420],
            [_messageLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16],
            [_spinner.centerXAnchor constraintEqualToAnchor:_scroll.centerXAnchor],
            [_spinner.centerYAnchor constraintEqualToAnchor:_scroll.centerYAnchor],
        ]];

        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(liveMagnifyDidEnd:)
                name:NSScrollViewDidEndLiveMagnifyNotification object:_scroll];
        /* The clip view's bounds change on every zoom and scroll, whatever
         * caused it — gesture, keyboard, toolbar, or AppKit itself. */
        _scroll.contentView.postsBoundsChangedNotifications = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(visibleAreaDidChange:)
                name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    }
    return self;
}

#pragma mark Toolbar

static NSButton *ToolButton(NSString *symbol, NSString *fallback, NSString *tip, id target, SEL action) {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    NSButton *b = img ? [NSButton buttonWithImage:img target:target action:action]
                      : [NSButton buttonWithTitle:fallback target:target action:action];
    b.bezelStyle = NSBezelStyleRecessed;
    b.showsBorderOnlyWhileMouseInside = YES;
    b.refusesFirstResponder = YES;
    b.toolTip = tip;
    b.controlSize = NSControlSizeSmall;
    return b;
}

- (void)buildToolbar {
    IVToolbar *bar = [[IVToolbar alloc] initWithFrame:NSMakeRect(0, NSHeight(self.bounds) - kToolbarHeight,
                                                                 NSWidth(self.bounds), kToolbarHeight)];
    bar.wantsLayer = YES;
    self.toolbar = bar;

    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(bar.bounds), 1)];
    line.boxType = NSBoxSeparator;
    line.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [bar addSubview:line];

    NSButton *fit    = ToolButton(@"arrow.up.left.and.arrow.down.right", @"Fit",
                                  @"Zoom to Fit (⌘9)", self, @selector(zoomToFit:));
    NSButton *actual = ToolButton(@"1.magnifyingglass", @"1:1",
                                  @"Actual Size (⌘0)", self, @selector(zoomToActual:));
    NSButton *out    = ToolButton(@"minus.magnifyingglass", @"−",
                                  @"Zoom Out (⌘−)", self, @selector(zoomOut:));
    NSButton *in     = ToolButton(@"plus.magnifyingglass", @"+",
                                  @"Zoom In (⌘+)", self, @selector(zoomIn:));

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    /* Unlike the icon buttons, the zoom menu keeps its pill and arrow visible:
     * a bare percentage would not read as something to click. */
    popup.bezelStyle = NSBezelStyleRecessed;
    ((NSPopUpButtonCell *)popup.cell).arrowPosition = NSPopUpArrowAtBottom;
    popup.alignment = NSTextAlignmentCenter;
    popup.refusesFirstResponder = YES;
    popup.controlSize = NSControlSizeSmall;
    popup.font = [NSFont monospacedDigitSystemFontOfSize:[NSFont smallSystemFontSize]
                                                  weight:NSFontWeightRegular];
    popup.toolTip = @"Zoom";
    [popup addItemWithTitle:@"100%"];   /* the pull-down's title item */
    [popup.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *fitItem = [popup.menu addItemWithTitle:@"Zoom to Fit" action:@selector(zoomToFit:) keyEquivalent:@""];
    fitItem.target = self;
    NSMenuItem *actualItem = [popup.menu addItemWithTitle:@"Actual Size" action:@selector(zoomToActual:) keyEquivalent:@""];
    actualItem.target = self;
    [popup.menu addItem:[NSMenuItem separatorItem]];
    for (NSNumber *pct in @[ @25, @50, @200, @400, @800, @1600 ]) {
        NSMenuItem *it = [popup.menu addItemWithTitle:[NSString stringWithFormat:@"%@%%", pct]
                                               action:@selector(zoomToPreset:) keyEquivalent:@""];
        it.target = self;
        it.tag = pct.integerValue;
    }
    [popup.widthAnchor constraintEqualToConstant:70].active = YES;
    self.zoomPopup = popup;

    NSTextField *info = [NSTextField labelWithString:@""];
    info.font = [NSFont monospacedDigitSystemFontOfSize:[NSFont smallSystemFontSize]
                                                 weight:NSFontWeightRegular];
    info.textColor = [NSColor secondaryLabelColor];
    info.lineBreakMode = NSLineBreakByTruncatingMiddle;
    info.selectable = NO;    /* a click must not move focus off the image; the tooltip has the text */
    [info setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.infoLabel = info;

    NSTextField *version = [NSTextField labelWithString:@"v" IV_VERSION];
    version.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize] - 1];
    version.textColor = [NSColor tertiaryLabelColor];
    version.toolTip = @"ImageView " IV_VERSION;

    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *stack = [NSStackView stackViewWithViews:@[ fit, actual, out, popup, in, spacer,
                                                           info, version ]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 2;
    stack.edgeInsets = NSEdgeInsetsMake(0, 8, 0, 10);
    [stack setCustomSpacing:10 afterView:actual];
    [stack setCustomSpacing:12 afterView:info];
    /* In a narrow Quick View panel the version goes first, then the info. */
    [stack setVisibilityPriority:NSStackViewVisibilityPriorityDetachOnlyIfNecessary - 2 forView:version];
    [stack setVisibilityPriority:NSStackViewVisibilityPriorityDetachOnlyIfNecessary - 1 forView:info];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-1],
    ]];
    [self addSubview:bar];
}

/* The toolbar and the image area are placed from the bounds rather than by
 * autoresizing: Double Commander can create the view at a degenerate size
 * and only then give it its real one, and springs scaled from 0 x 0 put the
 * image area under the toolbar. */
- (void)layoutChrome {
    NSRect b = self.bounds;
    CGFloat body = MAX(0, NSHeight(b) - kToolbarHeight);
    self.scroll.frame = NSMakeRect(0, 0, NSWidth(b), body);
    self.toolbar.frame = NSMakeRect(0, body, NSWidth(b), kToolbarHeight);
}

- (NSString *)infoText {
    IVImage *im = self.image;
    if (!im) return @"";
    NSString *dims = im.kind == IVKindVector
        ? [NSString stringWithFormat:@"%.0f × %.0f pt", im.size.width, im.size.height]
        : [NSString stringWithFormat:@"%.0f × %.0f", im.size.width, im.size.height];
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:dims, im.format, nil];
    if (im.frameCount > 1) [parts addObject:[NSString stringWithFormat:@"%zu frames", im.frameCount]];
    [parts addObject:[NSByteCountFormatter stringFromByteCount:(long long)im.fileSize
                                                    countStyle:NSByteCountFormatterCountStyleFile]];
    return [parts componentsJoinedByString:@" · "];
}

#pragma mark Loading

/* Shows `image` (already validated by +imageAtPath:). Vector art is ready at
 * once; raster pixels are decoded off the main thread and arrive later, unless
 * another file has been loaded by then. */
- (void)showImage:(IVImage *)image flags:(int)flags {
    [self.spinner stopAnimation:nil];   /* a previous file's slow decode may have started it */
    IVGeneration *generation = self.generation;
    NSUInteger gen = ++generation.value;
    self.image = image;
    self.mode = [IVView modeForFlags:flags];

    self.canvas.vector = image.vector;
    self.canvas.raster.cgImage = nil;
    self.canvas.checkerboard = image.hasAlpha;
    self.canvas.frame = NSMakeRect(0, 0, image.size.width, image.size.height);
    self.canvas.needsDisplay = YES;
    self.messageLabel.hidden = YES;
    self.infoLabel.stringValue = [self infoText];
    self.infoLabel.toolTip = [NSString stringWithFormat:@"%@\n%@", image.path.lastPathComponent,
                              self.infoLabel.stringValue];
    [self applyMode];

    if (image.kind == IVKindVector) return;

    /* Large decodes (RAW, big TIFF) show a spinner, small ones don't flash it. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen == generation.value && !self.canvas.raster.cgImage && self.messageLabel.hidden)
            [self.spinner startAnimation:nil];
    });

    __weak IVView *weakSelf = self;
    dispatch_async(self.decodeQueue, ^{
        if (gen != generation.value) return;   /* superseded before it started */
        double firstDelay = 0.1;
        id cg = image.frameCount > 1 ? [image decodeFrame:0 delay:&firstDelay] : [image decodeDisplayImage];
        dispatch_async(dispatch_get_main_queue(), ^{
            IVView *me = weakSelf;
            if (!me || gen != generation.value) return;
            [me.spinner stopAnimation:nil];
            if (!cg) {
                [me showMessage:@"This image could not be decoded."];
                return;
            }
            me.canvas.raster.cgImage = cg;
            if (image.frameCount > 1) [me animateFrom:0 delay:firstDelay loop:1 generation:gen];
        });
    });
}

- (void)showMessage:(NSString *)text {
    self.messageLabel.stringValue = text;
    self.messageLabel.hidden = NO;
    self.canvas.checkerboard = NO;
    self.canvas.needsDisplay = YES;
}

#pragma mark Animation

/* Frame `i` is on screen. Decode the next one in the background while it shows,
 * then swap it in when its delay is up. Loading another file or closing the
 * viewer bumps the generation, which ends the loop. */
- (void)animateFrom:(size_t)i delay:(double)delay loop:(NSUInteger)loop generation:(NSUInteger)gen {
    IVImage *image = self.image;
    CFTimeInterval due = CACurrentMediaTime() + delay;
    size_t next = (i + 1) % image.frameCount;
    NSUInteger nextLoop = next == 0 ? loop + 1 : loop;
    if (next == 0 && image.loopCount > 0 && loop >= image.loopCount) return;   /* finished */

    __weak IVView *weakSelf = self;
    IVGeneration *generation = self.generation;
    dispatch_async(self.decodeQueue, ^{
        if (gen != generation.value) return;
        double nextDelay = 0.1;
        id frame = [image decodeFrame:next delay:&nextDelay];
        double wait = MAX(0, due - CACurrentMediaTime());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IVView *me = weakSelf;
            if (!me || gen != generation.value || !frame) return;
            me.canvas.raster.cgImage = frame;
            [me animateFrom:next delay:nextDelay loop:nextLoop generation:gen];
        });
    });
}

#pragma mark Zoom

+ (IVZoomMode)modeForFlags:(int)flags {
    if (!(flags & lcp_fittowindow)) return IVZoomActual;
    return (flags & lcp_fitlargeronly) ? IVZoomFitLarge : IVZoomFit;
}

- (NSSize)viewportSize { return self.scroll.contentView.frame.size; }

- (CGFloat)fitMagnification {
    NSSize vp = [self viewportSize], im = self.image.size;
    if (im.width < 1 || im.height < 1 || vp.width < 1 || vp.height < 1) return 1;
    return MIN(vp.width / im.width, vp.height / im.height);
}

/* Zoom limits follow the image: out to half of "fit" (or of 100% for a small
 * one), in to 64x or twice "fit" for a tiny icon. */
- (void)updateLimits {
    CGFloat fit = [self fitMagnification];
    self.scroll.minMagnification = MAX(0.005, MIN(fit, 1) / 2);
    self.scroll.maxMagnification = MAX(kMaxMagnification, fit * 2);
}

- (void)setMagnification:(CGFloat)mag centeredAt:(NSPoint)docPoint {
    [self updateLimits];
    mag = MIN(MAX(mag, self.scroll.minMagnification), self.scroll.maxMagnification);
    WithMaskedFP(^{ [self.scroll setMagnification:mag centeredAtPoint:docPoint]; });
    [self magnificationDidChange];
}

- (NSPoint)visibleCenter {
    NSRect b = self.scroll.contentView.bounds;
    return NSMakePoint(NSMidX(b), NSMidY(b));
}

- (void)applyMode {
    if (!self.image) return;
    CGFloat mag;
    switch (self.mode) {
        case IVZoomFit:      mag = [self fitMagnification]; break;
        case IVZoomFitLarge: mag = MIN(1, [self fitMagnification]); break;
        case IVZoomActual:   mag = 1; break;
        case IVZoomManual:   return;
    }
    NSPoint center = NSMakePoint(self.image.size.width / 2, self.image.size.height / 2);
    [self setMagnification:mag centeredAt:center];
    /* Centered, whether or not it fits. */
    NSClipView *clip = self.scroll.contentView;
    NSRect b = clip.bounds;
    b.origin = NSMakePoint(center.x - NSWidth(b) / 2, center.y - NSHeight(b) / 2);
    [clip scrollToPoint:[clip constrainBoundsRect:b].origin];
    [self.scroll reflectScrolledClipView:clip];
}

- (void)zoomBy:(CGFloat)factor atPoint:(NSPoint)docPoint {
    if (!self.image) return;
    self.mode = IVZoomManual;
    [self setMagnification:self.scroll.magnification * factor centeredAt:docPoint];
}

/* The zoom ladder for the toolbar and keyboard, as in Preview and browsers. */
static const CGFloat kSteps[] = { 0.01, 0.02, 0.03, 0.05, 0.08, 0.1, 0.125, 0.167, 0.25, 0.33,
                                  0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64 };

- (void)step:(int)direction {
    if (!self.image) return;
    CGFloat cur = self.scroll.magnification, target = cur;
    size_t n = sizeof kSteps / sizeof kSteps[0];
    if (direction > 0) {
        target = cur * 2;
        for (size_t i = 0; i < n; i++) if (kSteps[i] > cur * 1.01) { target = kSteps[i]; break; }
    } else {
        target = cur / 2;
        for (size_t i = n; i-- > 0;) if (kSteps[i] < cur / 1.01) { target = kSteps[i]; break; }
    }
    self.mode = IVZoomManual;
    [self setMagnification:target centeredAt:[self visibleCenter]];
}

- (void)toggleFitAtPoint:(NSPoint)docPoint {
    if (!self.image) return;
    CGFloat fit = [self fitMagnification];
    BOOL atFit = fabs(self.scroll.magnification - fit) < 0.005;
    if (atFit && fabs(fit - 1) > 0.005) {
        self.mode = IVZoomActual;
        [self setMagnification:1 centeredAt:docPoint];
    } else {
        self.mode = IVZoomFit;
        [self applyMode];
    }
}

- (void)zoomIn:(id)s      { (void)s; [self step:+1]; }
- (void)zoomOut:(id)s     { (void)s; [self step:-1]; }
- (void)zoomToFit:(id)s   { (void)s; self.mode = IVZoomFit; [self applyMode]; }
- (void)zoomToActual:(id)s {
    (void)s;
    if (!self.image) return;
    self.mode = IVZoomActual;
    [self setMagnification:1 centeredAt:[self visibleCenter]];
}
- (void)zoomToPreset:(NSMenuItem *)item {
    if (!self.image) return;
    self.mode = IVZoomManual;
    [self setMagnification:item.tag / 100.0 centeredAt:[self visibleCenter]];
}

- (BOOL)isPannable {
    NSSize doc = self.canvas.frame.size;
    NSSize vis = self.scroll.contentView.bounds.size;
    return doc.width > vis.width + 0.5 || doc.height > vis.height + 0.5;
}

- (void)visibleAreaDidChange:(NSNotification *)note {
    (void)note;
    if (fabs(self.scroll.magnification - self.shownMagnification) > 1e-6) [self magnificationDidChange];
}

- (void)magnificationDidChange {
    CGFloat mag = self.scroll.magnification;
    self.shownMagnification = mag;
    NSString *title = mag >= 0.995 || mag < 0.1
        ? [NSString stringWithFormat:@"%.0f%%", mag * 100]
        : [NSString stringWithFormat:@"%.0f%%", round(mag * 1000) / 10];
    [self.zoomPopup itemAtIndex:0].title = title;
    self.canvas.raster.pixelated = mag >= 2;
    if (self.canvas.raster.pixelated) self.canvas.raster.needsDisplay = YES;   /* redraw at the new scale */
    self.scroll.documentCursor = [self isPannable] ? [NSCursor openHandCursor] : nil;
    /* The checkerboard keeps its on-screen size, and SVG is redrawn from the
     * vector source at the new scale. */
    if (self.canvas.checkerboard || self.canvas.vector) self.canvas.needsDisplay = YES;
}

- (void)liveMagnifyDidEnd:(NSNotification *)note {
    (void)note;
    self.mode = IVZoomManual;
    [self magnificationDidChange];
}

- (void)resizeSubviewsWithOldSize:(NSSize)old {
    NSPoint center = self.image ? [self visibleCenter] : NSZeroPoint;
    [super resizeSubviewsWithOldSize:old];
    [self layoutChrome];
    if (!self.image) return;
    [self updateLimits];
    /* Fit modes re-fit; at actual size or a chosen zoom the part of the
     * image the user panned to stays in the middle of the window. */
    if (self.mode == IVZoomFit || self.mode == IVZoomFitLarge) { [self applyMode]; return; }
    NSClipView *clip = self.scroll.contentView;
    NSRect b = clip.bounds;
    b.origin = NSMakePoint(center.x - NSWidth(b) / 2, center.y - NSHeight(b) / 2);
    [clip scrollToPoint:[clip constrainBoundsRect:b].origin];
    [self.scroll reflectScrolledClipView:clip];
    [self magnificationDidChange];
}

/* Zoom shortcuts. Cmd+= and Cmd+- are bound on Double Commander's Viewer form
 * (cm_ZoomIn / cm_ZoomOut), and with a plugin open they only change the
 * viewer's font size; the keystroke never reaches the plugin. They are taken
 * from the event stream before DC sees them (see -installKeyMonitor), and only
 * while this view has keyboard focus. */
- (BOOL)handleZoomKey:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagOption |
         NSEventModifierFlagControl | NSEventModifierFlagShift);
    NSString *ch = event.charactersIgnoringModifiers;
    BOOL keypad = (event.modifierFlags & NSEventModifierFlagNumericPad) != 0;
    BOOL cmd = (mods & ~NSEventModifierFlagShift) == NSEventModifierFlagCommand;
    BOOL plain = (mods & ~NSEventModifierFlagShift) == 0;
    if (!cmd && !plain) return NO;

    if ([ch isEqualToString:@"="] || [ch isEqualToString:@"+"]) { [self step:+1]; return YES; }
    if ([ch isEqualToString:@"-"]) { [self step:-1]; return YES; }
    /* Digits are DC's view-mode keys (1 = Text, ..., 7 = Plugins); only the
     * Cmd versions are ours, as in Preview. */
    if (cmd && !keypad && [ch isEqualToString:@"0"]) { [self zoomToActual:nil]; return YES; }
    if (cmd && !keypad && [ch isEqualToString:@"9"]) { [self zoomToFit:nil]; return YES; }
    return NO;
}

- (void)installKeyMonitor {
    if (self.keyMonitor) return;
    __weak IVView *weakSelf = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                            handler:^NSEvent *(NSEvent *e) {
        IVView *me = weakSelf;
        if (!me || e.window != me.window || !me.window.isKeyWindow) return e;
        if (me.window.firstResponder != me.canvas || me.isHiddenOrHasHiddenAncestor) return e;
        return [me handleZoomKey:e] ? nil : e;
    }];
}

- (void)removeKeyMonitor {
    if (self.keyMonitor) [NSEvent removeMonitor:self.keyMonitor];
    self.keyMonitor = nil;
}

#pragma mark Copy

/* Cmd+C: the image itself, as PNG and TIFF for any app that pastes pictures,
 * plus the file's own bytes under its own type (an animated GIF stays
 * animated, an SVG stays vector where the target understands it). */
- (BOOL)copyImage {
    IVImage *im = self.image;
    if (!im) return NO;
    __block CGImageRef cg = (__bridge CGImageRef)self.canvas.raster.cgImage;
    __block id rendered = nil;
    if (im.kind == IVKindVector) {
        WithMaskedFP(^{
            CGFloat w = MAX(im.size.width, 1), h = MAX(im.size.height, 1);
            CGFloat scale = MIN(MAX(self.window.backingScaleFactor, 2),
                                MIN(kMaxDisplaySide / MAX(w, h), sqrt(kMaxDisplayPixels / (w * h))));
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL
                              pixelsWide:(NSInteger)ceil(im.size.width * scale)
                              pixelsHigh:(NSInteger)ceil(im.size.height * scale)
                           bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                          colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            rep.size = im.size;
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [im.vector drawInRect:NSMakeRect(0, 0, im.size.width, im.size.height)];
            [NSGraphicsContext restoreGraphicsState];
            rendered = (__bridge id)rep.CGImage;
        });
        cg = (__bridge CGImageRef)rendered;
    }
    if (!cg) return NO;

    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    __block NSData *png = nil, *tiff = nil;
    WithMaskedFP(^{
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
        png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        /* TIFF only for apps that still want it, and only while it stays a
         * sane size: an uncompressed 64 MP bitmap is 256 MB, which the
         * pasteboard refuses, failing the whole copy. */
        if (rep.pixelsWide * rep.pixelsHigh <= 16 * 1024 * 1024)
            tiff = [rep TIFFRepresentationUsingCompression:NSTIFFCompressionLZW factor:0];
    });
    /* Where the file itself is what an app pasting it wants — the SVG source,
     * an animation, a camera format's original bytes, or a PNG exactly as it
     * is (full size, even past the display cap) — it goes first, and the
     * rendered PNG / TIFF do not replace it. */
    NSString *originalType = nil;
    if (im.kind == IVKindVector) {
        originalType = UTTypeSVG.identifier;
        [item setData:im.vectorData forType:originalType];
    } else if (im.frameCount > 1 || [@[ @"JPEG", @"GIF", @"HEIC", @"WEBP" ] containsObject:im.format] ||
               ([im.format isEqualToString:@"PNG"] && !im.oriented)) {
        NSData *original = [NSData dataWithContentsOfFile:im.path options:NSDataReadingMappedIfSafe error:NULL];
        NSString *type = (__bridge NSString *)CGImageSourceGetType((__bridge CGImageSourceRef)im.source);
        if (original && type) { [item setData:original forType:type]; originalType = type; }
    }
    if (png && ![originalType isEqualToString:NSPasteboardTypePNG])   [item setData:png forType:NSPasteboardTypePNG];
    if (tiff && ![originalType isEqualToString:NSPasteboardTypeTIFF]) [item setData:tiff forType:NSPasteboardTypeTIFF];

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    return [pb writeObjects:@[ item ]];
}

#pragma mark Keyboard focus

/* Double Commander means to hand the plugin keyboard focus when the F3 viewer
 * opens (TfrmViewer.ActivatePlugin -> TWlxModule.SetFocus), but on macOS that
 * call is a no-op: it only has Windows, Qt and GTK branches. So the keys went
 * nowhere until the image was clicked. The plugin takes focus itself instead.
 *
 * Only when no control holds it, though. The same plugin also runs in Quick
 * View (Ctrl+Q), next to the file panel, where DC deliberately does not focus
 * it — taking focus there would steal the panel's cursor keys. In the viewer,
 * focus sits on the bare form: LCL's window content is a scroll view, and its
 * document view (TCocoaWindowContentDocument) is first responder, with the
 * plugin added beside it. In Quick View it sits on the file list, a control
 * nested deep in the main window. So focus is taken from the window, its
 * content view or that document view, from our own containers, and from a
 * hidden control — never from a visible one. */
- (BOOL)focusIsUnclaimed {
    NSWindow *win = self.window;
    NSResponder *fr = win.firstResponder;
    if (!fr || fr == win) return YES;
    if (![fr isKindOfClass:[NSView class]]) return NO;
    NSView *v = (NSView *)fr;
    if (v == self.canvas) return NO; /* already ours */
    /* The bare form: the content view itself, or the document view its clip
     * view scrolls. */
    NSView *content = win.contentView;
    if (v == content) return YES;
    if ([v.superview isKindOfClass:[NSClipView class]] && v.superview.superview == content)
        return YES;
    return [self isDescendantOf:v] || v.isHiddenOrHasHiddenAncestor;
}

- (void)claimFocusIfUnclaimed {
    if (self.window && [self focusIsUnclaimed]) [self.window makeFirstResponder:self.canvas];
}

/* Taken once the viewer window is key and LCL has handled its activation, not
 * earlier. LCL records which form is active only when one of its own controls
 * gets focus; taking focus before that leaves DC believing the main window is
 * active, and its dialogs then open on the main window's monitor instead of
 * the viewer's. DC loads the plugin before it shows the viewer, so this
 * normally happens on NSWindowDidBecomeKeyNotification; a window that is
 * already key (the viewer switched into plugin mode) is handled straight away. */
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    if (!self.window) { [self removeKeyMonitor]; return; }
    [self installKeyMonitor];
    [nc addObserver:self selector:@selector(windowDidBecomeKey:)
               name:NSWindowDidBecomeKeyNotification object:self.window];
    if (self.window.isKeyWindow) [self windowDidBecomeKey:nil];
}

- (void)windowDidBecomeKey:(NSNotification *)note {
    (void)note;
    /* After LCL's own activation handling, not before it. */
    dispatch_async(dispatch_get_main_queue(), ^{ [self claimFocusIfUnclaimed]; });
}

- (void)close {
    self.generation.value++;   /* ends decoding hand-offs and the animation loop */
    [self.spinner stopAnimation:nil];
    [self removeKeyMonitor];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self removeFromSuperview];
}

- (void)dealloc {
    [self removeKeyMonitor];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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

/* A file that is not an image this plugin can show returns NULL, and Double
 * Commander moves on to the next lister whose detect string matches. */
__attribute__((visibility("default")))
HWND __stdcall ListLoad(HWND ParentWin, char *FileToLoad, int ShowFlags) {
    NSString *path = PathFromABI(FileToLoad);
    __block IVView *result = nil;
    OnMain(^{
        IVImage *image = [IVImage imageAtPath:path];
        if (!image) return;
        NSView *parent = (__bridge NSView *)ParentWin;
        NSRect frame = parent ? parent.bounds : NSMakeRect(0, 0, 800, 600);
        result = [[IVView alloc] initWithFrame:frame];
        if (parent) [parent addSubview:result];
        [result showImage:image flags:ShowFlags];
    });
    if (!result) return NULL;
    return (HWND)CFBridgingRetain(result); /* +1; released in ListCloseWindow */
}

__attribute__((visibility("default")))
int __stdcall ListLoadNext(HWND ParentWin, HWND PluginWin, char *FileToLoad, int ShowFlags) {
    (void)ParentWin;
    IVView *view = (__bridge IVView *)PluginWin;
    if (![view isKindOfClass:[IVView class]]) return LISTPLUGIN_ERROR;
    NSString *path = PathFromABI(FileToLoad);
    __block BOOL ok = NO;
    OnMain(^{
        IVImage *image = [IVImage imageAtPath:path];
        if (!image) return;
        [view showImage:image flags:ShowFlags];
        ok = YES;
    });
    return ok ? LISTPLUGIN_OK : LISTPLUGIN_ERROR;
}

__attribute__((visibility("default")))
void __stdcall ListCloseWindow(HWND ListWin) {
    if (!ListWin) return;
    OnMain(^{
        IVView *view = (IVView *)CFBridgingRelease(ListWin); /* -1 */
        [view close];
    });
}

/* lc_copy: Double Commander binds Cmd+C on its Viewer form and dispatches it
 * here when a plugin owns the window. lc_newparams: the user changed DC's
 * Image > Stretch options (or pressed F / L); the new fit mode applies at once. */
__attribute__((visibility("default")))
int __stdcall ListSendCommand(HWND ListWin, int Command, int Parameter) {
    if (!ListWin) return LISTPLUGIN_ERROR;
    IVView *view = (__bridge IVView *)ListWin;
    if (![view isKindOfClass:[IVView class]]) return LISTPLUGIN_ERROR;
    __block int rc = LISTPLUGIN_ERROR;
    OnMain(^{
        if (Command == lc_copy) {
            rc = [view copyImage] ? LISTPLUGIN_OK : LISTPLUGIN_ERROR;
        } else if (Command == lc_newparams) {
            view.mode = [IVView modeForFlags:Parameter];
            [view applyMode];
            rc = LISTPLUGIN_OK;
        }
    });
    return rc;
}

__attribute__((visibility("default")))
void __stdcall ListGetDetectString(char *DetectString, int maxlen) {
    if (!DetectString || maxlen <= 0) return;
    strncpy(DetectString, kDetectString, maxlen - 1);
    DetectString[maxlen - 1] = '\0';
}

__attribute__((visibility("default")))
void __stdcall ListSetDefaultParams(ListDefaultParamStruct *dps) {
    (void)dps;
}
