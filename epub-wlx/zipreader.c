#include "zipreader.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

/* A single entry may not inflate to more than this — a cheap zip-bomb guard.
 * No legitimate resource inside an e-book comes anywhere near it. */
#define ZIP_MAX_ENTRY_SIZE ((uint64_t)512 * 1024 * 1024)

#define SIG_LOCAL      0x04034b50u
#define SIG_CENTRAL    0x02014b50u
#define SIG_EOCD       0x06054b50u
#define SIG_EOCD64     0x06064b50u
#define SIG_EOCD64_LOC 0x07064b50u

typedef struct {
    char    *name;
    uint16_t method;
    uint32_t crc;
    uint64_t compSize;
    uint64_t uncompSize;
    uint64_t localOffset;
} ZipEntry;

struct ZipArchive {
    const uint8_t *base;
    size_t         size;
    ZipEntry      *entries;
    size_t         count;
};

#pragma mark - Bounds-checked little-endian reads

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t rd64(const uint8_t *p) {
    return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}

/* True when [off, off+len) lies inside the mapping. */
static int inBounds(const ZipArchive *z, uint64_t off, uint64_t len) {
    return off <= z->size && len <= (uint64_t)z->size - off;
}

#pragma mark - Central directory

/* Locate the End Of Central Directory record by scanning backwards over the
 * (up to 64 KiB) trailing comment. Returns NULL when there is none. */
static const uint8_t *findEOCD(const uint8_t *base, size_t size) {
    if (size < 22) return NULL;
    size_t maxBack = size < 66000 ? size : 66000;
    for (size_t back = 22; back <= maxBack; back++) {
        const uint8_t *p = base + size - back;
        if (rd32(p) == SIG_EOCD) return p;
    }
    return NULL;
}

/* Pull the ZIP64 sizes/offset out of an entry's extra field, replacing the
 * 0xFFFF.. sentinels. The ZIP64 extra packs only the fields that overflowed,
 * in a fixed order, so each is consumed conditionally. */
static void applyZip64Extra(ZipEntry *e, const uint8_t *extra, size_t extraLen,
                            uint32_t rawUncomp, uint32_t rawComp, uint32_t rawOffset) {
    size_t pos = 0;
    while (pos + 4 <= extraLen) {
        uint16_t id  = rd16(extra + pos);
        uint16_t len = rd16(extra + pos + 2);
        if (pos + 4 + len > extraLen) return;
        if (id == 0x0001) {
            const uint8_t *v = extra + pos + 4;
            size_t remain = len;
            if (rawUncomp == 0xFFFFFFFFu && remain >= 8) {
                e->uncompSize = rd64(v); v += 8; remain -= 8;
            }
            if (rawComp == 0xFFFFFFFFu && remain >= 8) {
                e->compSize = rd64(v); v += 8; remain -= 8;
            }
            if (rawOffset == 0xFFFFFFFFu && remain >= 8) {
                e->localOffset = rd64(v);
            }
            return;
        }
        pos += 4 + len;
    }
}

static int parseCentralDirectory(ZipArchive *z) {
    const uint8_t *eocd = findEOCD(z->base, z->size);
    if (!eocd) return 0;

    uint64_t count  = rd16(eocd + 10);
    uint64_t cdSize = rd32(eocd + 12);
    uint64_t cdOff  = rd32(eocd + 16);

    /* ZIP64: the 32-bit fields are saturated and the real values live in the
     * ZIP64 EOCD record, found via a locator sitting just before the EOCD. */
    if (count == 0xFFFFu || cdSize == 0xFFFFFFFFu || cdOff == 0xFFFFFFFFu) {
        if ((size_t)(eocd - z->base) < 20) return 0;
        const uint8_t *loc = eocd - 20;
        if (rd32(loc) != SIG_EOCD64_LOC) return 0;
        uint64_t z64Off = rd64(loc + 8);
        if (!inBounds(z, z64Off, 56) || rd32(z->base + z64Off) != SIG_EOCD64) return 0;
        const uint8_t *z64 = z->base + z64Off;
        count  = rd64(z64 + 32);
        cdSize = rd64(z64 + 40);
        cdOff  = rd64(z64 + 48);
    }

    if (!inBounds(z, cdOff, cdSize) || count == 0 || count > 200000) return 0;

    z->entries = calloc((size_t)count, sizeof(ZipEntry));
    if (!z->entries) return 0;

    const uint8_t *p   = z->base + cdOff;
    const uint8_t *end = p + cdSize;
    size_t n = 0;

    while (n < count && p + 46 <= end && rd32(p) == SIG_CENTRAL) {
        uint16_t nameLen    = rd16(p + 28);
        uint16_t extraLen   = rd16(p + 30);
        uint16_t commentLen = rd16(p + 32);
        if (p + 46 + nameLen + extraLen + commentLen > end) break;

        uint32_t rawComp   = rd32(p + 20);
        uint32_t rawUncomp = rd32(p + 24);
        uint32_t rawOffset = rd32(p + 42);

        ZipEntry *e     = &z->entries[n];
        e->method       = rd16(p + 10);
        e->crc          = rd32(p + 16);
        e->compSize     = rawComp;
        e->uncompSize   = rawUncomp;
        e->localOffset  = rawOffset;
        applyZip64Extra(e, p + 46 + nameLen, extraLen, rawUncomp, rawComp, rawOffset);

        e->name = malloc((size_t)nameLen + 1);
        if (!e->name) break;
        memcpy(e->name, p + 46, nameLen);
        e->name[nameLen] = '\0';

        n++;
        p += 46 + nameLen + extraLen + commentLen;
    }

    z->count = n;
    return n > 0;
}

#pragma mark - Public API

ZipArchive *ZipOpen(const char *path) {
    if (!path) return NULL;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 22 || !S_ISREG(st.st_mode)) {
        close(fd);
        return NULL;
    }

    void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd); /* the mapping keeps the file alive */
    if (map == MAP_FAILED) return NULL;

    ZipArchive *z = calloc(1, sizeof(ZipArchive));
    if (!z) {
        munmap(map, (size_t)st.st_size);
        return NULL;
    }
    z->base = map;
    z->size = (size_t)st.st_size;

    if (!parseCentralDirectory(z)) {
        ZipClose(z);
        return NULL;
    }
    return z;
}

void ZipClose(ZipArchive *z) {
    if (!z) return;
    for (size_t i = 0; i < z->count; i++) free(z->entries[i].name);
    free(z->entries);
    if (z->base) munmap((void *)z->base, z->size);
    free(z);
}

size_t ZipEntryCount(const ZipArchive *z) { return z ? z->count : 0; }

const char *ZipEntryName(const ZipArchive *z, size_t index) {
    if (!z || index >= z->count) return NULL;
    return z->entries[index].name;
}

/* EPUB paths are case-sensitive by spec, but real-world books do get this wrong,
 * so an exact match is tried first and a case-insensitive one as a fallback. */
static const ZipEntry *findEntry(const ZipArchive *z, const char *name) {
    if (!z || !name) return NULL;
    for (size_t i = 0; i < z->count; i++)
        if (strcmp(z->entries[i].name, name) == 0) return &z->entries[i];
    for (size_t i = 0; i < z->count; i++)
        if (strcasecmp(z->entries[i].name, name) == 0) return &z->entries[i];
    return NULL;
}

int ZipHasEntry(const ZipArchive *z, const char *name) {
    return findEntry(z, name) != NULL;
}

unsigned char *ZipCopyEntry(const ZipArchive *z, const char *name, size_t *outLen) {
    if (outLen) *outLen = 0;
    const ZipEntry *e = findEntry(z, name);
    if (!e) return NULL;
    if (e->uncompSize > ZIP_MAX_ENTRY_SIZE) return NULL;

    /* The local header repeats the name/extra lengths, and they may differ from
     * the central directory's — the data offset must come from the local one. */
    if (!inBounds(z, e->localOffset, 30)) return NULL;
    const uint8_t *lh = z->base + e->localOffset;
    if (rd32(lh) != SIG_LOCAL) return NULL;
    uint64_t dataOff = e->localOffset + 30 + rd16(lh + 26) + rd16(lh + 28);
    if (!inBounds(z, dataOff, e->compSize)) return NULL;
    const uint8_t *data = z->base + dataOff;

    unsigned char *out = malloc((size_t)e->uncompSize + 1);
    if (!out) return NULL;

    if (e->method == 0) {
        if (e->compSize != e->uncompSize) { free(out); return NULL; }
        memcpy(out, data, (size_t)e->uncompSize);
    } else if (e->method == 8) {
        z_stream s;
        memset(&s, 0, sizeof(s));
        if (inflateInit2(&s, -MAX_WBITS) != Z_OK) { free(out); return NULL; }
        s.next_in   = (Bytef *)data;
        s.avail_in  = (uInt)e->compSize;
        s.next_out  = out;
        s.avail_out = (uInt)e->uncompSize;
        int rc = inflate(&s, Z_FINISH);
        uint64_t produced = s.total_out;
        inflateEnd(&s);
        if ((rc != Z_STREAM_END && rc != Z_OK) || produced != e->uncompSize) {
            free(out);
            return NULL;
        }
    } else {
        free(out); /* bzip2/LZMA/… are legal ZIP but never used by EPUB */
        return NULL;
    }

    if (e->crc && crc32(crc32(0L, NULL, 0), out, (uInt)e->uncompSize) != e->crc) {
        free(out);
        return NULL;
    }

    out[e->uncompSize] = '\0'; /* convenience NUL, not counted in outLen */
    if (outLen) *outLen = (size_t)e->uncompSize;
    return out;
}
