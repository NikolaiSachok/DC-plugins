/*
 * Headless checks for the ZIP (OCF) reader, run against the generated sample
 * books. No GUI, so this one runs in CI.
 *
 *   cc -o build/zip_test test/zip_test.c zipreader.c -lz && ./build/zip_test <dir>
 */
#include "../zipreader.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void check(int cond, const char *what) {
    printf("  %s %s\n", cond ? "ok  " : "FAIL", what);
    if (!cond) failures++;
}

static char *joinPath(const char *dir, const char *name) {
    size_t n = strlen(dir) + strlen(name) + 2;
    char *p = malloc(n);
    snprintf(p, n, "%s/%s", dir, name);
    return p;
}

static void testSample3(const char *dir) {
    char *path = joinPath(dir, "sample3.epub");
    printf("sample3.epub (EPUB 3)\n");

    ZipArchive *z = ZipOpen(path);
    check(z != NULL, "opens");
    if (!z) { free(path); failures++; return; }

    check(ZipEntryCount(z) == 10, "central directory lists 10 entries");
    check(ZipHasEntry(z, "META-INF/container.xml"), "finds META-INF/container.xml");
    check(!ZipHasEntry(z, "OEBPS/nope.xhtml"), "reports a missing entry as missing");

    /* `mimetype` is stored uncompressed — the method-0 path. */
    size_t len = 0;
    unsigned char *mt = ZipCopyEntry(z, "mimetype", &len);
    check(mt && len == 20 && memcmp(mt, "application/epub+zip", 20) == 0,
          "reads the stored `mimetype` entry");
    check(mt && mt[len] == '\0', "result is NUL-terminated past the length");
    free(mt);

    /* Chapters are deflated — the method-8 path, with a CRC check. */
    unsigned char *ch = ZipCopyEntry(z, "OEBPS/chapter1.xhtml", &len);
    check(ch && len > 400, "inflates a deflated chapter");
    check(ch && strstr((char *)ch, "Chapter One: The Harbour") != NULL,
          "inflated bytes are the expected document");
    free(ch);

    unsigned char *png = ZipCopyEntry(z, "OEBPS/images/cover.png", &len);
    check(png && len > 8 && memcmp(png, "\x89PNG\r\n\x1a\n", 8) == 0,
          "reads a binary entry byte-exact");
    free(png);

    /* A book cannot reach outside itself: these are simply not entries. */
    check(ZipCopyEntry(z, "../../../etc/hosts", &len) == NULL, "rejects a traversal path");
    check(ZipCopyEntry(z, "/etc/hosts", &len) == NULL, "rejects an absolute path");

    /* EPUB paths are case-sensitive, but sloppy books get it wrong. */
    unsigned char *ci = ZipCopyEntry(z, "oebps/CHAPTER1.xhtml", &len);
    check(ci != NULL, "falls back to a case-insensitive match");
    free(ci);

    ZipClose(z);
    free(path);
}

static void testSample2(const char *dir) {
    char *path = joinPath(dir, "sample2.epub");
    printf("sample2.epub (EPUB 2)\n");

    ZipArchive *z = ZipOpen(path);
    check(z != NULL, "opens");
    if (!z) { free(path); failures++; return; }

    size_t len = 0;
    unsigned char *ncx = ZipCopyEntry(z, "toc.ncx", &len);
    check(ncx && strstr((char *)ncx, "navMap") != NULL, "reads the NCX");
    free(ncx);

    unsigned char *cp = ZipCopyEntry(z, "chapter2.xhtml", &len);
    check(cp && strstr((char *)cp, "windows-1251") != NULL,
          "reads a stored, non-UTF-8 chapter");
    free(cp);

    ZipClose(z);
    free(path);
}

static void testGarbage(const char *dir) {
    printf("malformed input\n");
    check(ZipOpen("/nonexistent/nowhere.epub") == NULL, "missing file returns NULL");
    check(ZipOpen("/etc/hosts") == NULL, "a non-ZIP file returns NULL");
    check(ZipOpen(dir) == NULL, "a directory returns NULL");

    /* A truncated book must be refused, not read past the mapping. */
    char *src = joinPath(dir, "sample3.epub");
    char *cut = joinPath(dir, "truncated.epub");
    FILE *in = fopen(src, "rb"), *out = fopen(cut, "wb");
    if (in && out) {
        fseek(in, 0, SEEK_END);
        long half = ftell(in) / 2;   /* keeps the payload, loses the directory */
        fseek(in, 0, SEEK_SET);
        char buf[512];
        for (long left = half; left > 0; ) {
            size_t want = (size_t)(left < (long)sizeof(buf) ? left : (long)sizeof(buf));
            size_t n = fread(buf, 1, want, in);
            if (!n) break;
            fwrite(buf, 1, n, out);
            left -= (long)n;
        }
    }
    if (in) fclose(in);
    if (out) fclose(out);
    check(ZipOpen(cut) == NULL, "a truncated ZIP returns NULL");
    remove(cut);
    free(src);
    free(cut);
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "build/samples";
    printf("zipreader checks against %s\n\n", dir);
    testSample3(dir);
    testSample2(dir);
    testGarbage(dir);
    printf("\n%s\n", failures ? "FAILURES" : "all zipreader checks passed");
    return failures ? 1 : 0;
}
