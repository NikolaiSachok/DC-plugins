/*
 * MediaInfo — Double Commander Content (WDX) plugin for macOS.
 *
 * Exposes per-file media metadata as content fields you can show in custom
 * columns / tooltips: image & video dimensions, audio & video duration,
 * bitrate, codecs, PDF page count, and an adaptive "Summary" field that picks
 * the single most useful string per file type.
 *
 * Backends are all native system frameworks — no third-party libraries, no
 * network:
 *   - images  -> ImageIO  (header read only; never decodes pixels)
 *   - audio   -> AVFoundation
 *   - video   -> AVFoundation
 *   - PDF     -> CoreGraphics (CGPDF)
 *
 * A field is simply empty (ft_fieldempty) for files it doesn't apply to, so a
 * single column serves every type without waste.
 */

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <sys/stat.h>
#import <fenv.h>

#include "contplug.h"

#define MI_VERSION "0.2.0"

/* ---- Field table -------------------------------------------------------- */

enum {
    F_SUMMARY = 0,
    F_DIMENSIONS,
    F_WIDTH,
    F_HEIGHT,
    F_MEGAPIXELS,
    F_DPI,
    F_COLORDEPTH,
    F_DURATION,
    F_DURATIONSECS,
    F_FRAMERATE,
    F_BITRATE,
    F_SAMPLERATE,
    F_CHANNELS,
    F_VIDEOCODEC,
    F_AUDIOCODEC,
    F_PAGECOUNT,
    F_PLUGINVERSION,
    F_COUNT
};

typedef struct {
    const char *name;
    int         type;     /* ft_* */
    const char *units;
} MIField;

/* Order MUST match the enum above. */
static const MIField kFields[F_COUNT] = {
    [F_SUMMARY]       = { "Summary",       ft_string,           ""        },
    [F_DIMENSIONS]    = { "Dimensions",    ft_string,           ""        },
    [F_WIDTH]         = { "Width",         ft_numeric_32,       "px"      },
    [F_HEIGHT]        = { "Height",        ft_numeric_32,       "px"      },
    [F_MEGAPIXELS]    = { "Megapixels",    ft_numeric_floating, "MP"      },
    [F_DPI]           = { "DPI",           ft_numeric_32,       "dpi"     },
    [F_COLORDEPTH]    = { "Bit depth",     ft_numeric_32,       "bit"     },
    [F_DURATION]      = { "Duration",      ft_string,           ""        },
    [F_DURATIONSECS]  = { "Duration (s)",  ft_numeric_floating, "s"       },
    [F_FRAMERATE]     = { "Frame rate",    ft_numeric_floating, "fps"     },
    [F_BITRATE]       = { "Bitrate",       ft_numeric_32,       "kbps"    },
    [F_SAMPLERATE]    = { "Sample rate",   ft_numeric_32,       "Hz"      },
    [F_CHANNELS]      = { "Channels",      ft_numeric_32,       ""        },
    [F_VIDEOCODEC]    = { "Video codec",   ft_string,           ""        },
    [F_AUDIOCODEC]    = { "Audio codec",   ft_string,           ""        },
    [F_PAGECOUNT]     = { "Page count",    ft_numeric_32,       "pages"   },
    [F_PLUGINVERSION] = { "Plugin version",ft_string,           ""        },
};

/* ---- Categories --------------------------------------------------------- */

typedef enum { CAT_OTHER = 0, CAT_IMAGE, CAT_AUDIO, CAT_VIDEO, CAT_PDF } MICategory;

static MICategory CategoryForPath(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    if (ext.length == 0) return CAT_OTHER;
    static NSSet *img, *aud, *vid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        img = [NSSet setWithArray:@[ @"jpg",@"jpeg",@"png",@"gif",@"tiff",@"tif",
            @"bmp",@"webp",@"heic",@"heif",@"avif",@"ico",@"icns",@"psd",@"jp2",
            @"dng",@"cr2",@"cr3",@"nef",@"arw",@"orf",@"rw2",@"raf",@"sr2",@"pef" ]];
        aud = [NSSet setWithArray:@[ @"mp3",@"m4a",@"aac",@"wav",@"aiff",@"aif",
            @"aifc",@"caf" ]];
        /* avi/mkv/webm are read by our own container parsers (macOS frameworks
           can't open them); the rest go through AVFoundation. */
        vid = [NSSet setWithArray:@[ @"mp4",@"mov",@"m4v",@"3gp",@"3g2",
            @"avi",@"mkv",@"webm" ]];
    });
    if ([img containsObject:ext]) return CAT_IMAGE;
    if ([aud containsObject:ext]) return CAT_AUDIO;
    if ([vid containsObject:ext]) return CAT_VIDEO;
    if ([ext isEqualToString:@"pdf"]) return CAT_PDF;
    return CAT_OTHER;
}

/* DetectString: only the extensions a system framework can actually read, so
   we never offer a column that is silently blank for a "supported" type. */
static const char *kDetectString =
    "(EXT=\"JPG\")|(EXT=\"JPEG\")|(EXT=\"PNG\")|(EXT=\"GIF\")|(EXT=\"TIFF\")|"
    "(EXT=\"TIF\")|(EXT=\"BMP\")|(EXT=\"WEBP\")|(EXT=\"HEIC\")|(EXT=\"HEIF\")|"
    "(EXT=\"AVIF\")|(EXT=\"ICO\")|(EXT=\"ICNS\")|(EXT=\"PSD\")|(EXT=\"JP2\")|"
    "(EXT=\"DNG\")|(EXT=\"CR2\")|(EXT=\"CR3\")|(EXT=\"NEF\")|(EXT=\"ARW\")|"
    "(EXT=\"ORF\")|(EXT=\"RW2\")|(EXT=\"RAF\")|(EXT=\"SR2\")|(EXT=\"PEF\")|"
    "(EXT=\"MP3\")|(EXT=\"M4A\")|(EXT=\"AAC\")|(EXT=\"WAV\")|(EXT=\"AIFF\")|"
    "(EXT=\"AIF\")|(EXT=\"AIFC\")|(EXT=\"CAF\")|(EXT=\"MP4\")|(EXT=\"MOV\")|"
    "(EXT=\"M4V\")|(EXT=\"3GP\")|(EXT=\"3G2\")|(EXT=\"AVI\")|(EXT=\"MKV\")|"
    "(EXT=\"WEBM\")|(EXT=\"PDF\")";

/* ---- Parsed-info value object + cache ----------------------------------- */

@interface MIInfo : NSObject
@property (nonatomic) MICategory category;
@property (nonatomic, strong) NSDictionary<NSNumber *, id> *values; /* field -> NSNumber|NSString */
@end
@implementation MIInfo
@end

static NSCache<NSString *, MIInfo *> *gCache;

/* ---- Formatting helpers ------------------------------------------------- */

static NSString *FormatDuration(double secs) {
    if (!isfinite(secs) || secs < 0) return nil;
    long t = (long)llround(secs);
    long h = t / 3600, m = (t % 3600) / 60, s = t % 60;
    if (h > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, s];
    return [NSString stringWithFormat:@"%ld:%02ld", m, s];
}

static NSString *FourCCToString(FourCharCode c) {
    char b[5] = { (char)((c >> 24) & 0xFF), (char)((c >> 16) & 0xFF),
                  (char)((c >> 8) & 0xFF), (char)(c & 0xFF), 0 };
    NSString *s = [[NSString stringWithUTF8String:b] ?: @""
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return s;
}

static NSString *CodecName(FourCharCode c) {
    switch (c) {
        case 'avc1': case 'avcC': return @"H.264";
        case 'hvc1': case 'hev1': return @"HEVC";
        case 'mp4v':              return @"MPEG-4";
        case 'jpeg':              return @"MJPEG";
        case 'ap4h': case 'apcn': case 'apch': case 'apcs': case 'apco':
        case 'ap4x':              return @"ProRes";
        case 'mp4a': case 'aac ': return @"AAC";
        case 'mp3 ': case '.mp3': return @"MP3";
        case 'alac':              return @"ALAC";
        case 'lpcm': case 'sowt': case 'twos': case 'in24': case 'fl32':
                                  return @"PCM";
        case 'ac-3':              return @"AC-3";
        case 'ec-3':              return @"E-AC-3";
        case 'Opus': case 'opus': return @"Opus";
        default:                  return FourCCToString(c);
    }
}

/* ---- Backends ----------------------------------------------------------- */

static MIInfo *ParseImage(NSURL *url) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    if (CGImageSourceGetCount(src) == 0) { CFRelease(src); return nil; }
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!props) return nil;

    NSDictionary *p = (__bridge_transfer NSDictionary *)props;
    NSNumber *wN = p[(id)kCGImagePropertyPixelWidth];
    NSNumber *hN = p[(id)kCGImagePropertyPixelHeight];
    if (!wN || !hN) return nil;

    long w = wN.longValue, h = hN.longValue;
    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    v[@(F_WIDTH)]  = @(w);
    v[@(F_HEIGHT)] = @(h);
    NSString *dims = [NSString stringWithFormat:@"%ld × %ld", w, h];
    v[@(F_DIMENSIONS)] = dims;
    v[@(F_SUMMARY)]    = dims;
    v[@(F_MEGAPIXELS)] = @(round((double)w * (double)h / 1.0e5) / 10.0);

    NSNumber *dpi = p[(id)kCGImagePropertyDPIWidth];
    if (dpi && dpi.doubleValue > 0) v[@(F_DPI)] = @((int)llround(dpi.doubleValue));
    NSNumber *depth = p[(id)kCGImagePropertyDepth];
    if (depth && depth.intValue > 0) v[@(F_COLORDEPTH)] = @(depth.intValue);

    MIInfo *info = [MIInfo new];
    info.category = CAT_IMAGE;
    info.values = v;
    return info;
}

static MIInfo *ParsePDF(NSURL *url) {
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    if (!doc) return nil;
    size_t n = CGPDFDocumentGetNumberOfPages(doc);
    CGPDFDocumentRelease(doc);
    if (n == 0) return nil;

    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    v[@(F_PAGECOUNT)] = @((int)n);
    v[@(F_SUMMARY)]   = (n == 1) ? @"1 page"
                                 : [NSString stringWithFormat:@"%zu pages", n];
    MIInfo *info = [MIInfo new];
    info.category = CAT_PDF;
    info.values = v;
    return info;
}

/* AVI is a RIFF format AVFoundation can't open on macOS, but its main header
   ('avih') carries dimensions and frame timing directly — read it ourselves. */
static uint32_t RdLE32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static MIInfo *ParseAVI(NSURL *url) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!fh) return nil;
    NSData *data = [fh readDataOfLength:65536];   /* header lives near the start */
    [fh closeFile];
    if (data.length < 64) return nil;

    const uint8_t *b = data.bytes;
    if (memcmp(b, "RIFF", 4) != 0 || memcmp(b + 8, "AVI ", 4) != 0) return nil;

    NSRange r = [data rangeOfData:[NSData dataWithBytes:"avih" length:4]
                          options:0 range:NSMakeRange(0, data.length)];
    if (r.location == NSNotFound || r.location + 8 + 40 > data.length) return nil;

    const uint8_t *h = b + r.location + 8;        /* MainAVIHeader */
    uint32_t usecPerFrame = RdLE32(h + 0);
    uint32_t totalFrames  = RdLE32(h + 16);
    uint32_t w            = RdLE32(h + 32);
    uint32_t hgt          = RdLE32(h + 36);
    if (w > 100000 || hgt > 100000) return nil;   /* sanity */

    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    NSString *dims = nil;
    if (w > 0 && hgt > 0) {
        v[@(F_WIDTH)]  = @(w);
        v[@(F_HEIGHT)] = @(hgt);
        dims = [NSString stringWithFormat:@"%u × %u", w, hgt];
        v[@(F_DIMENSIONS)] = dims;
    }
    double secs = (double)usecPerFrame * (double)totalFrames / 1.0e6;
    NSString *durStr = (secs > 0) ? FormatDuration(secs) : nil;
    if (durStr) {
        v[@(F_DURATION)]     = durStr;
        v[@(F_DURATIONSECS)] = @(round(secs * 10.0) / 10.0);
    }
    if (usecPerFrame > 0)
        v[@(F_FRAMERATE)] = @(round(1.0e6 / (double)usecPerFrame * 100.0) / 100.0);

    if (dims && durStr) v[@(F_SUMMARY)] = [NSString stringWithFormat:@"%@ · %@", dims, durStr];
    else if (dims)      v[@(F_SUMMARY)] = dims;
    else if (durStr)    v[@(F_SUMMARY)] = durStr;

    if (v.count == 0) return nil;
    MIInfo *info = [MIInfo new];
    info.category = CAT_VIDEO;
    info.values = v;
    return info;
}

/* Matroska / WebM is an EBML container that AVFoundation can't open on macOS.
   Its Segment > Info (Duration, TimecodeScale) and Segment > Tracks > TrackEntry
   > Video (PixelWidth/Height) elements carry everything we need, and they always
   precede the media Clusters — so a bounded read of the file head is enough.
   EBML basics: every element is an ID (variable 1-4 bytes, marker bits kept) then
   a size VINT (1-8 bytes, marker stripped) then data. */

/* Read one element at *pp within [*pp, end). On success sets id/data ptr/data
   len and advances *pp past the element; returns 1. Returns 0 to stop. */
static int MKVNext(const uint8_t **pp, const uint8_t *end,
                   uint32_t *id, const uint8_t **dp, uint64_t *dlen) {
    const uint8_t *p = *pp;
    if (p >= end) return 0;

    uint8_t f = p[0];
    int idn = (f & 0x80) ? 1 : (f & 0x40) ? 2 : (f & 0x20) ? 3 : (f & 0x10) ? 4 : 0;
    if (idn == 0 || p + idn > end) return 0;
    uint32_t eid = 0;
    for (int i = 0; i < idn; i++) eid = (eid << 8) | p[i];
    const uint8_t *q = p + idn;
    if (q >= end) return 0;

    uint8_t s = q[0];
    int sn = 0; uint8_t smask = 0;
    for (int b = 0; b < 8; b++) {
        if (s & (0x80 >> b)) { sn = b + 1; smask = (uint8_t)(0xFF >> (b + 1)); break; }
    }
    if (sn == 0 || q + sn > end) return 0;
    uint64_t size = (uint64_t)(s & smask);
    int allOnes = ((s & smask) == smask);
    for (int i = 1; i < sn; i++) { size = (size << 8) | q[i]; if (q[i] != 0xFF) allOnes = 0; }

    const uint8_t *d = q + sn;
    uint64_t avail = (uint64_t)(end - d);
    uint64_t dl = allOnes ? avail : (size > avail ? avail : size);  /* unknown size -> to buffer end */
    *id = eid; *dp = d; *dlen = dl;
    *pp = d + dl;                         /* truncated/unknown -> == end -> loop stops */
    return 1;
}

static uint64_t MKVUInt(const uint8_t *p, uint64_t n) {
    uint64_t v = 0;
    for (uint64_t i = 0; i < n && i < 8; i++) v = (v << 8) | p[i];
    return v;
}

static double MKVFloat(const uint8_t *p, uint64_t n) {
    if (n == 4) { uint32_t u = (uint32_t)MKVUInt(p, 4); float f;  memcpy(&f, &u, 4); return f; }
    if (n == 8) { uint64_t u = MKVUInt(p, 8);           double d; memcpy(&d, &u, 8); return d; }
    return 0;
}

typedef struct {
    double   timecodeScale;   /* ns per Duration unit (Matroska default 1e6) */
    double   duration;        /* in timecodeScale units */
    uint64_t width, height;   /* first video track's coded pixel size */
    uint64_t defDurNs;        /* first video track's per-frame duration, ns */
} MKVState;

static void MKVWalk(const uint8_t *p, const uint8_t *end, int depth, MKVState *s) {
    if (depth > 4) return;
    uint32_t id; const uint8_t *dp; uint64_t dl;
    while (MKVNext(&p, end, &id, &dp, &dl)) {
        switch (id) {
            case 0x18538067:  /* Segment  */
            case 0x1549A966:  /* Info     */
            case 0x1654AE6B:  /* Tracks   */
                MKVWalk(dp, dp + dl, depth + 1, s);
                break;
            case 0xAE: {      /* TrackEntry: isolate per-track fields */
                const uint8_t *tp = dp, *te = dp + dl;
                uint32_t tid; const uint8_t *tdp; uint64_t tdl;
                uint64_t w = 0, h = 0, defDur = 0, type = 0; int hasVideo = 0;
                while (MKVNext(&tp, te, &tid, &tdp, &tdl)) {
                    if (tid == 0x83) type = MKVUInt(tdp, tdl);            /* TrackType (1=video) */
                    else if (tid == 0x23E383) defDur = MKVUInt(tdp, tdl); /* DefaultDuration ns */
                    else if (tid == 0xE0) {                              /* Video */
                        hasVideo = 1;
                        const uint8_t *vp = tdp, *ve = tdp + tdl;
                        uint32_t vid; const uint8_t *vdp; uint64_t vdl;
                        while (MKVNext(&vp, ve, &vid, &vdp, &vdl)) {
                            if (vid == 0xB0) w = MKVUInt(vdp, vdl);       /* PixelWidth  */
                            else if (vid == 0xBA) h = MKVUInt(vdp, vdl);  /* PixelHeight */
                        }
                    }
                }
                if ((hasVideo || type == 1) && s->width == 0 && w > 0 && h > 0) {
                    s->width = w; s->height = h; s->defDurNs = defDur;
                }
                break;
            }
            case 0x2AD7B1: s->timecodeScale = (double)MKVUInt(dp, dl); break; /* TimecodeScale */
            case 0x4489:   s->duration      = MKVFloat(dp, dl);        break; /* Duration      */
            case 0x1F43B675: return;   /* Cluster: media data begins, nothing useful past here */
            default: break;
        }
    }
}

static MIInfo *ParseMKV(NSURL *url) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!fh) return nil;
    NSData *data = [fh readDataOfLength:2 * 1024 * 1024];  /* Info+Tracks precede Clusters */
    [fh closeFile];
    if (data.length < 4) return nil;

    const uint8_t *b = data.bytes;
    if (!(b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3)) return nil; /* EBML */

    MKVState s = { .timecodeScale = 1.0e6 };
    MKVWalk(b, b + data.length, 0, &s);
    if (s.timecodeScale <= 0) s.timecodeScale = 1.0e6;

    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    NSString *dims = nil;
    if (s.width > 0 && s.height > 0 && s.width <= 100000 && s.height <= 100000) {
        v[@(F_WIDTH)]  = @((int)s.width);
        v[@(F_HEIGHT)] = @((int)s.height);
        dims = [NSString stringWithFormat:@"%llu × %llu",
                (unsigned long long)s.width, (unsigned long long)s.height];
        v[@(F_DIMENSIONS)] = dims;
    }
    double secs = s.duration * s.timecodeScale / 1.0e9;
    NSString *durStr = (secs > 0) ? FormatDuration(secs) : nil;
    if (durStr) {
        v[@(F_DURATION)]     = durStr;
        v[@(F_DURATIONSECS)] = @(round(secs * 10.0) / 10.0);
    }
    if (s.defDurNs > 0)
        v[@(F_FRAMERATE)] = @(round(1.0e9 / (double)s.defDurNs * 100.0) / 100.0);

    if (dims && durStr) v[@(F_SUMMARY)] = [NSString stringWithFormat:@"%@ · %@", dims, durStr];
    else if (dims)      v[@(F_SUMMARY)] = dims;
    else if (durStr)    v[@(F_SUMMARY)] = durStr;

    if (v.count == 0) return nil;
    MIInfo *info = [MIInfo new];
    info.category = CAT_VIDEO;
    info.values = v;
    return info;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static MIInfo *ParseAV(NSURL *url, MICategory hint) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url
        options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @NO }];
    if (!asset) return nil;

    NSArray<AVAssetTrack *> *vts = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *ats = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (vts.count == 0 && ats.count == 0) return nil;

    BOOL isVideo = (vts.count > 0);
    NSMutableDictionary *v = [NSMutableDictionary dictionary];

    double secs = CMTimeGetSeconds(asset.duration);
    NSString *durStr = FormatDuration(secs);
    if (durStr) {
        v[@(F_DURATION)]     = durStr;
        v[@(F_DURATIONSECS)] = @(round(secs * 10.0) / 10.0);
    }

    float totalRate = 0;
    NSString *dims = nil;
    if (isVideo) {
        AVAssetTrack *vt = vts[0];
        CGSize sz = CGSizeApplyAffineTransform(vt.naturalSize, vt.preferredTransform);
        long w = llround(fabs(sz.width)), h = llround(fabs(sz.height));
        if (w > 0 && h > 0) {
            v[@(F_WIDTH)]  = @(w);
            v[@(F_HEIGHT)] = @(h);
            dims = [NSString stringWithFormat:@"%ld × %ld", w, h];
            v[@(F_DIMENSIONS)] = dims;
        }
        if (vt.nominalFrameRate > 0)
            v[@(F_FRAMERATE)] = @(round(vt.nominalFrameRate * 100.0) / 100.0);
        if (vt.formatDescriptions.count) {
            CMFormatDescriptionRef fd =
                (__bridge CMFormatDescriptionRef)vt.formatDescriptions[0];
            v[@(F_VIDEOCODEC)] = CodecName(CMFormatDescriptionGetMediaSubType(fd));
        }
        totalRate += vt.estimatedDataRate;
    }
    if (ats.count) {
        AVAssetTrack *at = ats[0];
        if (at.formatDescriptions.count) {
            CMFormatDescriptionRef fd =
                (__bridge CMFormatDescriptionRef)at.formatDescriptions[0];
            v[@(F_AUDIOCODEC)] = CodecName(CMFormatDescriptionGetMediaSubType(fd));
            const AudioStreamBasicDescription *asbd =
                CMAudioFormatDescriptionGetStreamBasicDescription(fd);
            if (asbd) {
                if (asbd->mSampleRate > 0)
                    v[@(F_SAMPLERATE)] = @((int)llround(asbd->mSampleRate));
                if (asbd->mChannelsPerFrame > 0)
                    v[@(F_CHANNELS)] = @((int)asbd->mChannelsPerFrame);
            }
        }
        totalRate += at.estimatedDataRate;
    }
    if (totalRate > 0)
        v[@(F_BITRATE)] = @((int)llround(totalRate / 1000.0));

    /* Adaptive, compact summary. */
    if (isVideo) {
        if (dims && durStr)
            v[@(F_SUMMARY)] = [NSString stringWithFormat:@"%@ · %@", dims, durStr];
        else if (dims)
            v[@(F_SUMMARY)] = dims;
        else if (durStr)
            v[@(F_SUMMARY)] = durStr;
    } else if (durStr) {
        v[@(F_SUMMARY)] = durStr;
    }

    if (v.count == 0) return nil;
    MIInfo *info = [MIInfo new];
    info.category = isVideo ? CAT_VIDEO : CAT_AUDIO;
    info.values = v;
    return info;
}
#pragma clang diagnostic pop

/* Video containers macOS frameworks can't open, read by our own parsers.
   These are fast (a bounded header read), unlike the AVFoundation path. */
static BOOL IsOwnParsedVideo(NSString *ext) {
    return [ext isEqualToString:@"avi"] ||
           [ext isEqualToString:@"mkv"] ||
           [ext isEqualToString:@"webm"];
}

/* Parse with caching keyed by path + mtime. Returns a (possibly empty) MIInfo
   so repeated probes of an unreadable file don't re-parse. */
static MIInfo *InfoForPath(NSString *path, MICategory cat) {
    struct stat st;
    long mtime = (stat(path.fileSystemRepresentation, &st) == 0)
                     ? (long)st.st_mtimespec.tv_sec : 0;
    NSString *key = [NSString stringWithFormat:@"%ld\x1f%@", mtime, path];

    MIInfo *cached = [gCache objectForKey:key];
    if (cached) return cached;

    NSURL *url = [NSURL fileURLWithPath:path];
    NSString *ext = path.pathExtension.lowercaseString;
    MIInfo *info = nil;

    /* Double Commander is a Lazarus/FPC app, which ENABLES floating-point
       exception traps. Apple's media frameworks (notably ImageIO's RAW /
       MakerNote path) do FP math that is harmless under the default masked
       environment but raises a fatal trap under FPC's — which DC surfaces as an
       "Access violation". Mask FP exceptions across the framework call, then
       restore the host's environment before returning to DC. */
    fenv_t hostEnv;
    fegetenv(&hostEnv);
    fesetenv(FE_DFL_ENV);
    @try {
        switch (cat) {
            case CAT_IMAGE: info = ParseImage(url);       break;
            case CAT_AUDIO: info = ParseAV(url, cat);     break;
            case CAT_VIDEO:
                if ([ext isEqualToString:@"avi"])                    info = ParseAVI(url);
                else if ([ext isEqualToString:@"mkv"] ||
                         [ext isEqualToString:@"webm"])              info = ParseMKV(url);
                else                                                 info = ParseAV(url, cat);
                break;
            case CAT_PDF:   info = ParsePDF(url);         break;
            default: break;
        }
    } @finally {
        fesetenv(&hostEnv);
    }
    if (!info) {                       /* sentinel: parsed, nothing usable */
        info = [MIInfo new];
        info.category = cat;
        info.values = @{};
    }
    [gCache setObject:info forKey:key];
    return info;
}

/* ---- Value writers ------------------------------------------------------ */

static int WriteString(NSString *s, void *buf, int maxlen) {
    if (maxlen <= 0) return ft_fieldempty;
    const char *utf8 = s.UTF8String ?: "";
    strlcpy((char *)buf, utf8, (size_t)maxlen);
    return ft_string;
}

/* ---- Exported WDX ABI --------------------------------------------------- */

DLLEXPORT int __stdcall ContentGetSupportedField(int n, char *name, char *units,
                                                 int maxlen) {
    if (n < 0 || n >= F_COUNT) { if (name && maxlen > 0) name[0] = 0; return ft_nomorefields; }
    if (name && maxlen > 0)  strlcpy(name,  kFields[n].name,  (size_t)maxlen);
    if (units && maxlen > 0) strlcpy(units, kFields[n].units, (size_t)maxlen);
    return kFields[n].type;
}

DLLEXPORT int __stdcall ContentGetSupportedFieldFlags(int n) {
    (void)n;
    return 0;
}

DLLEXPORT int __stdcall ContentGetValue(char *fileName, int field, int unit,
                                        void *fieldValue, int maxlen, int flags) {
    (void)unit;
    if (field < 0 || field >= F_COUNT) return ft_nosuchfield;
    if (!fileName || !fieldValue) return ft_fileerror;

    /* Version field applies to every file (a discoverable on-screen version). */
    if (field == F_PLUGINVERSION)
        return WriteString(@"MediaInfo " @MI_VERSION, fieldValue, maxlen);

    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:fileName];
        if (!path) return ft_fileerror;
        MICategory cat = CategoryForPath(path);
        if (cat == CAT_OTHER) return ft_fieldempty;

        /* AVFoundation parsing is the only slow path; defer it off the UI
           thread when DC asks us to. (Our own AVI/MKV parsers are fast.) */
        BOOL slow = (cat == CAT_AUDIO) ||
                    (cat == CAT_VIDEO &&
                     !IsOwnParsedVideo(path.pathExtension.lowercaseString));
        if (slow && (flags & CONTENT_DELAYIFSLOW)) {
            struct stat st;
            long mtime = (stat(path.fileSystemRepresentation, &st) == 0)
                             ? (long)st.st_mtimespec.tv_sec : 0;
            NSString *key = [NSString stringWithFormat:@"%ld\x1f%@", mtime, path];
            if (![gCache objectForKey:key]) return ft_delayed;
        }

        MIInfo *info = InfoForPath(path, cat);
        id value = info.values[@(field)];
        if (!value) return ft_fieldempty;

        switch (kFields[field].type) {
            case ft_numeric_32:
                if (maxlen < (int)sizeof(int32_t)) return ft_fieldempty;
                *(int32_t *)fieldValue = (int32_t)[value intValue];
                return ft_numeric_32;
            case ft_numeric_floating:
                if (maxlen < (int)sizeof(double)) return ft_fieldempty;
                *(double *)fieldValue = [value doubleValue];
                return ft_numeric_floating;
            case ft_string:
                return WriteString((NSString *)value, fieldValue, maxlen);
            default:
                return ft_fieldempty;
        }
    }
}

DLLEXPORT void __stdcall ContentGetDetectString(char *detectString, int maxlen) {
    if (detectString && maxlen > 0) strlcpy(detectString, kDetectString, (size_t)maxlen);
}

DLLEXPORT void __stdcall ContentSetDefaultParams(ContentDefaultParamStruct *dps) {
    (void)dps;
    if (!gCache) {
        gCache = [[NSCache alloc] init];
        gCache.countLimit = 256;
    }
}

DLLEXPORT void __stdcall ContentPluginUnloading(void) {
    [gCache removeAllObjects];
    gCache = nil;
}

/* Initialize the cache even if DC never calls ContentSetDefaultParams. */
__attribute__((constructor))
static void MIInit(void) {
    if (!gCache) {
        gCache = [[NSCache alloc] init];
        gCache.countLimit = 256;
    }
}
