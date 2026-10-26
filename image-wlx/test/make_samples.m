/*
 * Generate the sample images the harnesses open, with ImageIO's writers, so
 * nothing binary is checked in.
 *
 *   ./build/make_samples <out-dir>
 */
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <zlib.h>

typedef void (^Painter)(CGContextRef ctx, size_t w, size_t h);

static CGImageRef Make(size_t w, size_t h, BOOL alpha, Painter paint) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        (CGBitmapInfo)(alpha ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNoneSkipLast));
    CGColorSpaceRelease(cs);
    paint(ctx, w, h);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

static BOOL Write(NSString *path, UTType *type, NSArray *images, NSArray<NSDictionary *> *props,
                  NSDictionary *fileProps) {
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFStringRef)type.identifier,
        images.count, NULL);
    if (!dst) { fprintf(stderr, "  no writer for %s\n", path.lastPathComponent.UTF8String); return NO; }
    if (fileProps) CGImageDestinationSetProperties(dst, (__bridge CFDictionaryRef)fileProps);
    for (NSUInteger i = 0; i < images.count; i++)
        CGImageDestinationAddImage(dst, (__bridge CGImageRef)images[i],
                                   (__bridge CFDictionaryRef)(props ? props[i] : @{}));
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    printf("  %-16s %s\n", path.lastPathComponent.UTF8String, ok ? "ok" : "FAILED");
    return ok;
}

static void Fill(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a, CGRect rect) {
    CGContextSetRGBFillColor(c, r, g, b, a);
    CGContextFillRect(c, rect);
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: make_samples <out-dir>\n"); return 2; }
    NSString *dir = @(argv[1]);
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    NSString *(^P)(NSString *) = ^(NSString *n) { return [dir stringByAppendingPathComponent:n]; };
    int failures = 0;

    /* A photo-like landscape: sky gradient, a sun, ground. */
    id photo = CFBridgingRelease(Make(1600, 1000, NO, ^(CGContextRef c, size_t w, size_t h) {
        for (size_t y = 0; y < h; y++)
            Fill(c, 0.25 + 0.5 * y / h, 0.5 + 0.3 * y / h, 0.95, 1, CGRectMake(0, y, w, 1));
        Fill(c, 0.2, 0.5, 0.25, 1, CGRectMake(0, 0, w, h * 0.3));
        CGContextSetRGBFillColor(c, 1, 0.85, 0.2, 1);
        CGContextFillEllipseInRect(c, CGRectMake(w * 0.7, h * 0.6, 220, 220));
    }));
    failures += !Write(P(@"photo.jpg"), UTTypeJPEG, @[ photo ], nil, nil);

    /* Stored 400x200 (red left half), tagged "rotate 90° CW": shows as 200x400. */
    id rot = CFBridgingRelease(Make(400, 200, NO, ^(CGContextRef c, size_t w, size_t h) {
        Fill(c, 0, 0, 1, 1, CGRectMake(0, 0, w, h));
        Fill(c, 1, 0, 0, 1, CGRectMake(0, 0, w / 2, h));
    }));
    failures += !Write(P(@"rotated.jpg"), UTTypeJPEG, @[ rot ],
                       @[ @{ (id)kCGImagePropertyOrientation: @6 } ], nil);

    /* Transparent background with an opaque circle. */
    id alpha = CFBridgingRelease(Make(300, 200, YES, ^(CGContextRef c, size_t w, size_t h) {
        (void)w; (void)h;
        CGContextSetRGBFillColor(c, 0.9, 0.2, 0.4, 1);
        CGContextFillEllipseInRect(c, CGRectMake(50, 25, 150, 150));
    }));
    failures += !Write(P(@"alpha.png"), UTTypePNG, @[ alpha ], nil, nil);

    /* 8x8 pixel art: a 1-px checker, for the nearest-neighbour check. */
    id pixel = CFBridgingRelease(Make(8, 8, NO, ^(CGContextRef c, size_t w, size_t h) {
        for (size_t y = 0; y < h; y++)
            for (size_t x = 0; x < w; x++)
                Fill(c, (x + y) % 2, 0, (x + y + 1) % 2, 1, CGRectMake(x, y, 1, 1));
    }));
    failures += !Write(P(@"pixel.png"), UTTypePNG, @[ pixel ], nil, nil);

    /* A 3-frame animation, 100 ms per frame, looping forever. */
    NSMutableArray *frames = [NSMutableArray array];
    NSArray *colors = @[ @[ @1, @0, @0 ], @[ @0, @1, @0 ], @[ @0, @0, @1 ] ];
    for (NSArray *rgb in colors)
        [frames addObject:CFBridgingRelease(Make(120, 80, NO, ^(CGContextRef c, size_t w, size_t h) {
            Fill(c, [rgb[0] doubleValue], [rgb[1] doubleValue], [rgb[2] doubleValue], 1,
                 CGRectMake(0, 0, w, h));
        }))];
    NSDictionary *gifFrame = @{ (id)kCGImagePropertyGIFDictionary:
                                    @{ (id)kCGImagePropertyGIFDelayTime: @0.1 } };
    failures += !Write(P(@"anim.gif"), UTTypeGIF, frames, @[ gifFrame, gifFrame, gifFrame ],
                       @{ (id)kCGImagePropertyGIFDictionary: @{ (id)kCGImagePropertyGIFLoopCount: @0 } });

    /* Wider than the 16384 px display cap. */
    id wide = CFBridgingRelease(Make(20000, 400, NO, ^(CGContextRef c, size_t w, size_t h) {
        for (size_t x = 0; x < w; x += 1000)
            Fill(c, (x / 1000) % 2, 0.5, 0.5, 1, CGRectMake(x, 0, 1000, h));
    }));
    failures += !Write(P(@"wide.png"), UTTypePNG, @[ wide ], nil, nil);

    /* Two pages, no frame delays: a document, not an animation. */
    failures += !Write(P(@"pages.tiff"), UTTypeTIFF, @[ photo, rot ], nil, nil);

    /* An icon whose first entry is the smallest. */
    id i16 = CFBridgingRelease(Make(16, 16, YES, ^(CGContextRef c, size_t w, size_t h) {
        Fill(c, 0, 0, 0, 1, CGRectMake(0, 0, w, h)); }));
    id i64 = CFBridgingRelease(Make(64, 64, YES, ^(CGContextRef c, size_t w, size_t h) {
        Fill(c, 0.1, 0.6, 0.9, 1, CGRectMake(0, 0, w, h)); }));
    failures += !Write(P(@"icon.ico"), [UTType typeWithIdentifier:@"com.microsoft.ico"],
                       @[ i16, i64 ], nil, nil);

    failures += !Write(P(@"photo.heic"), UTTypeHEIC, @[ photo ], nil, nil);
    failures += !Write(P(@"photo.bmp"), UTTypeBMP, @[ photo ], nil, nil);

    /* SVG with crisp, axis-aligned edges for the sharpness check: a black bar
     * on white, its left edge at x = 10. */
    NSString *svg =
        @"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\" viewBox=\"0 0 40 20\">"
        @"<rect width=\"40\" height=\"20\" fill=\"#fff\"/>"
        @"<rect x=\"10\" y=\"0\" width=\"20\" height=\"20\" fill=\"#000\"/>"
        @"<circle cx=\"5\" cy=\"10\" r=\"3\" fill=\"#e33\"/></svg>\n";
    [svg writeToFile:P(@"edge.svg") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    printf("  %-16s ok\n", "edge.svg");

    /* The same, gzip-compressed. */
    NSData *raw = [svg dataUsingEncoding:NSUTF8StringEncoding];
    gzFile gz = gzopen(P(@"edge.svgz").fileSystemRepresentation, "wb9");
    gzwrite(gz, raw.bytes, (unsigned)raw.length);
    gzclose(gz);
    printf("  %-16s ok\n", "edge.svgz");

    /* Red on top, blue below: catches an upside-down draw. */
    [@"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\">"
     @"<rect width=\"20\" height=\"10\" fill=\"#f00\"/>"
     @"<rect y=\"10\" width=\"20\" height=\"10\" fill=\"#00f\"/></svg>\n"
        writeToFile:P(@"updown.svg") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    printf("  %-16s ok\n", "updown.svg");

    /* Outlines painted `transparent` (CSS keyword) as diagram tools export
     * them: the shapes' insides must stay white, not turn black. */
    [@"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\">"
     @"<rect width=\"40\" height=\"20\" fill=\"#fff\"/>"
     @"<path d=\"M2 2 L18 2 L10 18 Z\" stroke=\"#333\" stroke-width=\"1\" fill=\"transparent\"/>"
     @"<path d=\"M22 2 L38 2 L30 18 Z\" style=\"stroke:#333;fill: transparent\"/></svg>\n"
        writeToFile:P(@"transparent.svg") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    printf("  %-16s ok\n", "transparent.svg");

    /* An SVG whose stated size is far past the display caps: copying it must
     * rasterize within them. */
    [@"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20000\" height=\"20000\">"
     @"<rect width=\"20000\" height=\"20000\" fill=\"#36c\"/></svg>\n"
        writeToFile:P(@"huge.svg") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    printf("  %-16s ok\n", "huge.svg");

    /* Not images: must fall through to the next lister. */
    NSMutableData *junk = [NSMutableData dataWithLength:4096];
    arc4random_buf(junk.mutableBytes, junk.length);
    [junk writeToFile:P(@"garbage.png") atomically:YES];
    [junk writeToFile:P(@"disk.raw") atomically:YES];
    [@"<svg><<not really" writeToFile:P(@"broken.svg") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    printf("  %-16s ok\n  %-16s ok\n  %-16s ok\n", "garbage.png", "disk.raw", "broken.svg");

    return failures ? 1 : 0;
}}
