/*
 * Real-artifact harness for MediaInfo.wdx.
 *
 * dlopen()s the actual built plugin and drives its WDX C ABI exactly as Double
 * Commander does — ContentGetSupportedField to map field indices, then
 * ContentGetValue against files we synthesize here with known properties:
 *   - a 320x200 PNG          (ImageIO path)
 *   - a 1-page PDF           (CGPDF path)
 *   - a 1.0s 8kHz mono WAV    (AVFoundation path)
 * Also exercises the CONTENT_DELAYIFSLOW deferral protocol for the AV path.
 *
 * Build:
 *   clang -arch arm64 -fobjc-arc -framework Foundation -framework CoreGraphics \
 *     -framework ImageIO -o build/test_host test/test_host.m
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>

#define ft_numeric_32        1
#define ft_numeric_floating  3
#define ft_string            8
#define ft_delayed           0
#define CONTENT_DELAYIFSLOW  1

typedef int  (*GetField_t)(int, char *, char *, int);
typedef int  (*GetValue_t)(char *, int, int, void *, int, int);
typedef void (*GetDetect_t)(char *, int);

static GetField_t GetField;
static GetValue_t GetValue;
static GetDetect_t GetDetect;
static NSMutableDictionary<NSString *, NSNumber *> *gIndex; /* field name -> index */

static int gPass = 0, gFail = 0;
static void check(BOOL ok, NSString *msg) {
    fprintf(ok ? stdout : stderr, "  [%s] %s\n", ok ? "PASS" : "FAIL", msg.UTF8String);
    if (ok) gPass++; else gFail++;
}

static int idx(NSString *name) {
    NSNumber *n = gIndex[name];
    return n ? n.intValue : -1;
}

static int getInt(const char *path, NSString *field) {
    int32_t out = INT32_MIN;
    int r = GetValue((char *)path, idx(field), 0, &out, sizeof(out), 0);
    return (r == ft_numeric_32) ? out : INT32_MIN;
}
static double getFloat(const char *path, NSString *field) {
    double out = NAN;
    int r = GetValue((char *)path, idx(field), 0, &out, sizeof(out), 0);
    return (r == ft_numeric_floating) ? out : NAN;
}
static NSString *getStr(const char *path, NSString *field) {
    char buf[1024] = {0};
    int r = GetValue((char *)path, idx(field), 0, buf, sizeof(buf), 0);
    return (r == ft_string) ? @(buf) : nil;
}

/* ---- sample synthesis --------------------------------------------------- */

static NSString *makePNG(NSString *dir) {
    NSString *path = [dir stringByAppendingPathComponent:@"sample.png"];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, 320, 200, 8, 0, cs,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(ctx, 0.2, 0.4, 0.8, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, 320, 200));
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path],
        (CFStringRef)@"public.png", 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL);
    CGImageDestinationFinalize(dst);
    CFRelease(dst); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    return path;
}

static NSString *makePDF(NSString *dir) {
    NSString *path = [dir stringByAppendingPathComponent:@"sample.pdf"];
    CGRect box = CGRectMake(0, 0, 612, 792);
    CGContextRef pdf = CGPDFContextCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], &box, NULL);
    CGPDFContextBeginPage(pdf, NULL);
    CGContextSetRGBFillColor(pdf, 0, 0, 0, 1);
    CGContextFillRect(pdf, CGRectMake(100, 100, 50, 50));
    CGPDFContextEndPage(pdf);
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
    return path;
}

static void put32le(NSMutableData *d, uint32_t v) { uint8_t b[4]={v,v>>8,v>>16,v>>24}; [d appendBytes:b length:4]; }
static void put16le(NSMutableData *d, uint16_t v) { uint8_t b[2]={v,v>>8}; [d appendBytes:b length:2]; }

static NSString *makeAVI(NSString *dir) {
    /* Minimal RIFF/AVI with a MainAVIHeader: 320x240, 25 fps, 50 frames = 2.0s. */
    NSMutableData *d = [NSMutableData data];
    [d appendBytes:"RIFF" length:4]; put32le(d, 0); [d appendBytes:"AVI " length:4];
    [d appendBytes:"LIST" length:4]; put32le(d, 4 + 8 + 56); [d appendBytes:"hdrl" length:4];
    [d appendBytes:"avih" length:4]; put32le(d, 56);
    put32le(d, 40000);                       /* dwMicroSecPerFrame -> 25 fps */
    put32le(d, 0); put32le(d, 0); put32le(d, 0);
    put32le(d, 50);                          /* dwTotalFrames -> 2.0s */
    put32le(d, 0); put32le(d, 0); put32le(d, 0);
    put32le(d, 320);                         /* dwWidth */
    put32le(d, 240);                         /* dwHeight */
    put32le(d, 0); put32le(d, 0); put32le(d, 0); put32le(d, 0);
    uint32_t riff = (uint32_t)(d.length - 8);
    uint8_t le[4] = { riff, riff >> 8, riff >> 16, riff >> 24 };
    [d replaceBytesInRange:NSMakeRange(4, 4) withBytes:le length:4];
    NSString *path = [dir stringByAppendingPathComponent:@"sample.avi"];
    [d writeToFile:path atomically:YES];
    return path;
}

static NSString *makeWAV(NSString *dir) {
    /* 1.0s, 8000 Hz, mono, 16-bit PCM silence. */
    const uint32_t rate = 8000, channels = 1, bps = 16, frames = 8000;
    const uint32_t dataSize = frames * channels * (bps / 8);
    NSMutableData *d = [NSMutableData data];
    [d appendBytes:"RIFF" length:4]; put32le(d, 36 + dataSize); [d appendBytes:"WAVE" length:4];
    [d appendBytes:"fmt " length:4]; put32le(d, 16); put16le(d, 1); put16le(d, channels);
    put32le(d, rate); put32le(d, rate * channels * (bps / 8));
    put16le(d, channels * (bps / 8)); put16le(d, bps);
    [d appendBytes:"data" length:4]; put32le(d, dataSize);
    [d increaseLengthBy:dataSize]; /* zero-filled silence */
    NSString *path = [dir stringByAppendingPathComponent:@"sample.wav"];
    [d writeToFile:path atomically:YES];
    return path;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: test_host <MediaInfo.wdx>\n"); return 2; }
        void *h = dlopen(argv[1], RTLD_NOW);
        if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }
        GetField  = (GetField_t)dlsym(h, "ContentGetSupportedField");
        GetValue  = (GetValue_t)dlsym(h, "ContentGetValue");
        GetDetect = (GetDetect_t)dlsym(h, "ContentGetDetectString");
        if (!GetField || !GetValue || !GetDetect) {
            fprintf(stderr, "missing ABI exports\n"); return 2;
        }

        /* Map field names -> indices (decouples the test from enum order). */
        gIndex = [NSMutableDictionary dictionary];
        for (int i = 0; i < 256; i++) {
            char name[128] = {0}, units[128] = {0};
            int t = GetField(i, name, units, sizeof(name));
            if (t == 0 /* ft_nomorefields */) break;
            gIndex[@(name)] = @(i);
        }
        check(gIndex.count >= 16, ([NSString stringWithFormat:@"plugin exposes %lu fields",
                                    (unsigned long)gIndex.count]));
        check(idx(@"Summary") >= 0 && idx(@"Dimensions") >= 0 && idx(@"Page count") >= 0,
              @"core fields present (Summary, Dimensions, Page count)");

        char det[2048] = {0};
        GetDetect(det, sizeof(det));
        check(strstr(det, "PNG") && strstr(det, "PDF") && strstr(det, "WAV"),
              @"detect string covers image/pdf/audio extensions");

        NSString *dir = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"mediainfo-test"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
            withIntermediateDirectories:YES attributes:nil error:nil];

        /* ---- image ---- */
        const char *png = makePNG(dir).fileSystemRepresentation;
        check(getInt(png, @"Width") == 320,  @"PNG Width = 320");
        check(getInt(png, @"Height") == 200, @"PNG Height = 200");
        check([getStr(png, @"Dimensions") isEqualToString:@"320 × 200"],
              ([NSString stringWithFormat:@"PNG Dimensions = '%@'", getStr(png, @"Dimensions")]));
        check([getStr(png, @"Summary") isEqualToString:@"320 × 200"], @"PNG Summary = '320 × 200'");
        check(fabs(getFloat(png, @"Megapixels") - 0.1) < 0.001, @"PNG Megapixels = 0.1");
        check(getStr(png, @"Duration") == nil, @"PNG has no Duration (field empty)");

        /* ---- pdf ---- */
        const char *pdf = makePDF(dir).fileSystemRepresentation;
        check(getInt(pdf, @"Page count") == 1, @"PDF Page count = 1");
        check([getStr(pdf, @"Summary") isEqualToString:@"1 page"], @"PDF Summary = '1 page'");
        check(getInt(pdf, @"Width") == INT32_MIN, @"PDF has no Width (field empty)");

        /* ---- audio (AVFoundation) ---- */
        const char *wav = makeWAV(dir).fileSystemRepresentation;
        check([getStr(wav, @"Duration") isEqualToString:@"0:01"],
              ([NSString stringWithFormat:@"WAV Duration = '%@' (want 0:01)", getStr(wav, @"Duration")]));
        check(getInt(wav, @"Sample rate") == 8000, @"WAV Sample rate = 8000");
        check(getInt(wav, @"Channels") == 1, @"WAV Channels = 1");
        check([getStr(wav, @"Summary") isEqualToString:@"0:01"], @"WAV Summary = '0:01'");

        /* ---- video: AVI via our own RIFF parser ---- */
        const char *avi = makeAVI(dir).fileSystemRepresentation;
        check(getInt(avi, @"Width") == 320,  @"AVI Width = 320");
        check(getInt(avi, @"Height") == 240, @"AVI Height = 240");
        check([getStr(avi, @"Duration") isEqualToString:@"0:02"],
              ([NSString stringWithFormat:@"AVI Duration = '%@' (want 0:02)", getStr(avi, @"Duration")]));
        check(fabs(getFloat(avi, @"Frame rate") - 25.0) < 0.01, @"AVI Frame rate = 25");
        check([getStr(avi, @"Summary") isEqualToString:@"320 × 240 · 0:02"],
              ([NSString stringWithFormat:@"AVI Summary = '%@'", getStr(avi, @"Summary")]));

        /* ---- regression: survive DC's FP-exception traps (the RawCamera crash) ----
           Double Commander (Lazarus/FPC) enables FP-exception traps; Apple media
           frameworks can raise them. The plugin must mask them during parsing and
           restore the host environment. We can only assert survival + restore here
           on clean inputs; the deterministic trap repro lives in the dev notes. */
#if defined(__arm64__)
        {
            uint64_t fpcr;
            __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
            fpcr |= (uint64_t)0x700;          /* IOE | DZE | OFE, as FPC sets */
            __asm__ volatile("msr fpcr, %0" :: "r"(fpcr));

            /* Fresh (uncached) copies so parsing actually runs under the traps. */
            for (int i = 0; i < 4; i++) {
                NSString *kind = @[@"png", @"pdf", @"wav", @"avi"][i];
                NSString *srcp = @[@(png), @(pdf), @(wav), @(avi)][i];
                NSString *dstp = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"trap.%@", kind]];
                [[NSFileManager defaultManager] removeItemAtPath:dstp error:nil];
                [[NSFileManager defaultManager] copyItemAtPath:srcp toPath:dstp error:nil];
                getStr(dstp.fileSystemRepresentation, @"Summary");
                getInt(dstp.fileSystemRepresentation, @"Width");
            }
            check(YES, @"survived ContentGetValue with FP-exception traps enabled");

            uint64_t after;
            __asm__ volatile("mrs %0, fpcr" : "=r"(after));
            check((after & (uint64_t)0x700) == (uint64_t)0x700,
                  @"plugin restored the host FP-exception environment");

            fpcr &= ~(uint64_t)0x700;          /* disable traps for the rest of the run */
            __asm__ volatile("msr fpcr, %0" :: "r"(fpcr));
        }
#endif

        /* ---- DELAYIFSLOW deferral protocol ---- */
        NSString *wav2 = [dir stringByAppendingPathComponent:@"defer.wav"];
        [[NSFileManager defaultManager] copyItemAtPath:@(wav) toPath:wav2 error:nil];
        const char *w2 = wav2.fileSystemRepresentation;
        char dbuf[64] = {0};
        int rd = GetValue((char *)w2, idx(@"Duration"), 0, dbuf, sizeof(dbuf), CONTENT_DELAYIFSLOW);
        check(rd == ft_delayed, @"first DELAYIFSLOW call defers (ft_delayed)");
        check([getStr(w2, @"Duration") isEqualToString:@"0:01"],
              @"background call (no flag) returns the real value");

        /* ---- version surface ---- */
        NSString *ver = getStr(png, @"Plugin version");
        check(ver != nil && [ver hasPrefix:@"MediaInfo "], @"Plugin version field present");

        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        printf("\nRESULT: %s  (%d passed, %d failed)\n",
               gFail == 0 ? "PASS" : "FAIL", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
