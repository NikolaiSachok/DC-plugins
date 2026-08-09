/*
 * zipreader — a minimal, read-only ZIP (OCF) reader.
 *
 * An `.epub` is a ZIP container, so the viewer needs exactly two things: list the
 * entries, and pull one out by name. macOS ships libarchive but no `archive.h`
 * in the SDK, so this reads the central directory directly and inflates with
 * zlib (`zlib.h` *is* in the SDK). Nothing is written to disk and no subprocess
 * is spawned — the book is served straight out of the file.
 *
 * Supports stored (0) and deflate (8) entries, ZIP64, and verifies CRC-32.
 */
#ifndef ZIPREADER_H
#define ZIPREADER_H

#include <stddef.h>

typedef struct ZipArchive ZipArchive;

/* Open a ZIP file (mmap'd read-only). Returns NULL if it isn't a readable ZIP. */
ZipArchive *ZipOpen(const char *path);
void        ZipClose(ZipArchive *z);

size_t      ZipEntryCount(const ZipArchive *z);
/* Entry path as stored, e.g. "OEBPS/chapter1.xhtml". Valid until ZipClose. */
const char *ZipEntryName(const ZipArchive *z, size_t index);

/* Whether `name` resolves to an entry (exact match, then case-insensitive). */
int         ZipHasEntry(const ZipArchive *z, const char *name);

/*
 * Decompress one entry. Returns a malloc'd buffer of *outLen bytes with one
 * extra NUL byte past the end (so the result can also be treated as a C string
 * when the entry is text). Caller frees. NULL on a missing or corrupt entry.
 */
unsigned char *ZipCopyEntry(const ZipArchive *z, const char *name, size_t *outLen);

#endif /* ZIPREADER_H */
