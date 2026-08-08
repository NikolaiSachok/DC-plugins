#!/usr/bin/env python3
"""Generate the sample e-books the EpubView harnesses run against.

Books are synthesised rather than committed so the repo carries no binary
fixtures and no third-party text. Two are produced:

  sample3.epub — EPUB 3: nav document, cover image, an inline image, and a
                 chapter carrying hostile content (inline <script>, an
                 onerror handler, a remote image) that must not survive.
  sample2.epub — EPUB 2: NCX table of contents, windows-1251 chapter, and a
                 stray uncompressed entry — the older shapes still in the wild.
"""
import os
import struct
import sys
import zlib
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))


def png(width, height, rgb):
    """A minimal solid-colour PNG — avoids depending on an imaging library."""
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


CH1 = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Chapter One</title><link rel="stylesheet" href="style.css"/></head>
<body>
  <h1 id="c1">Chapter One: The Harbour</h1>
  <p>The tide came in slowly that morning, and with it the smell of rope and
  cold iron. Marguerite counted the boats twice and got a different answer each
  time, which she decided was the harbour's fault and not her own.</p>
  <p>She had been told the crossing took four hours. It took eleven.</p>
  <blockquote><p>Nothing that floats is ever entirely still.</p></blockquote>
  <p>Later there was <em>bread</em>, and it was <strong>good</strong>, and she
  wrote none of this down. <a href="chapter2.xhtml#c2">The next morning</a> she
  would forget it entirely.</p>
  <figure><img src="images/plate.png" alt="A plate"/>
  <figcaption>Plate I — the harbour at low water.</figcaption></figure>
</body></html>
"""

CH2 = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter Two</title></head>
<body>
  <h1 id="c2">Chapter Two: The Ledger</h1>
  <p>Every page of the ledger was numbered and every number was wrong.</p>
  <table><tr><th>Day</th><th>Weight</th></tr><tr><td>Monday</td><td>14</td></tr></table>
  <ul><li>salt</li><li>tar</li><li>one lamp, wandering</li></ul>
</body></html>
"""

# Everything hostile a real book might carry. None of it may reach the page.
CH3 = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Chapter Three</title></head>
<body>
  <h1 id="c3">Chapter Three: The Lamp</h1>
  <p>The lamp had wandered again.</p>
  <script>window.PWNED = 1;</script>
  <img src="does-not-exist.png" onerror="window.PWNED = 2;" alt="broken"/>
  <img src="https://example.invalid/tracker.gif" alt="remote"/>
  <a href="https://example.invalid/somewhere">an outside link</a>
  <p onclick="window.PWNED = 3;">clickable prose</p>
  <iframe src="https://example.invalid/frame"></iframe>
</body></html>
"""

NAV = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>Contents</h1>
    <ol>
      <li><a href="chapter1.xhtml">The Harbour</a>
        <ol><li><a href="chapter1.xhtml#c1">Arrival</a></li></ol></li>
      <li><a href="chapter2.xhtml">The Ledger</a></li>
      <li><a href="chapter3.xhtml">The Lamp</a></li>
    </ol>
  </nav>
</body></html>
"""

STYLE = """body { background: #ff00ff; color: #00ff00; }
h1 { font-family: "Publisher Serif", serif; }
.drop { float: left; font-size: 300%; }
"""

OPF3 = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:epubview-sample-3</dc:identifier>
    <dc:title>The Wandering Lamp</dc:title>
    <dc:creator>Marguerite Vance</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="plate" href="images/plate.png" media-type="image/png"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="chapter3.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/>
  </spine>
</package>
"""

NCX = """<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:epubview-sample-2"/></head>
  <docTitle><text>A Ledger of Small Weights</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1">
      <navLabel><text>The Harbour</text></navLabel>
      <content src="chapter1.xhtml"/>
      <navPoint id="n1a" playOrder="2">
        <navLabel><text>Arrival</text></navLabel>
        <content src="chapter1.xhtml#c1"/>
      </navPoint>
    </navPoint>
    <navPoint id="n2" playOrder="3">
      <navLabel><text>The Ledger</text></navLabel>
      <content src="chapter2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>
"""

OPF2 = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="bookid">urn:uuid:epubview-sample-2</dc:identifier>
    <dc:title>A Ledger of Small Weights</dc:title>
    <dc:creator opf:role="aut">Marguerite Vance</dc:creator>
    <dc:language>en</dc:language>
    <meta name="cover" content="cover"/>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="cover" href="images/cover.png" media-type="image/png"/>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>
"""

# Declares windows-1251 and is encoded as such — older Cyrillic books do this.
CH_1251 = """<?xml version="1.0" encoding="windows-1251"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Глава</title></head>
<body><h1 id="c2">Вторая глава</h1>
<p>Текст в кодировке windows-1251, как в старых книгах.</p></body></html>
"""

CONTAINER = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="{opf}" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""


def write_epub(path, opf_path, files):
    with zipfile.ZipFile(path, "w") as z:
        # The spec requires `mimetype` first and stored uncompressed.
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip",
                   compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER.format(opf=opf_path),
                   compress_type=zipfile.ZIP_DEFLATED)
        for name, data in files:
            if isinstance(data, str):
                data = data.encode("utf-8")
            z.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    cover = png(120, 180, (58, 74, 120))
    plate = png(64, 40, (200, 170, 120))

    three = os.path.join(outdir, "sample3.epub")
    write_epub(three, "OEBPS/content.opf", [
        ("OEBPS/content.opf", OPF3),
        ("OEBPS/nav.xhtml", NAV),
        ("OEBPS/style.css", STYLE),
        ("OEBPS/chapter1.xhtml", CH1),
        ("OEBPS/chapter2.xhtml", CH2),
        ("OEBPS/chapter3.xhtml", CH3),
        ("OEBPS/images/cover.png", cover),
        ("OEBPS/images/plate.png", plate),
    ])

    two = os.path.join(outdir, "sample2.epub")
    with zipfile.ZipFile(two, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip",
                   compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER.format(opf="content.opf"))
        z.writestr("content.opf", OPF2)
        z.writestr("toc.ncx", NCX)
        z.writestr("chapter1.xhtml", CH1)
        # Stored, not deflated: exercises the other decompression path.
        z.writestr(zipfile.ZipInfo("chapter2.xhtml"), CH_1251.encode("cp1251"),
                   compress_type=zipfile.ZIP_STORED)
        z.writestr("images/cover.png", cover)

    print(three)
    print(two)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "build", "samples"))
