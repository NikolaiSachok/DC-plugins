#!/usr/bin/env python3
"""Hand-authored XML workbooks and hostile containers; no decoder round trip."""
from pathlib import Path
import sys, zipfile
out = Path(sys.argv[1])
with zipfile.ZipFile(out / 'oversized.ods', 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('content.xml', b'x' * (65 * 1024 * 1024))
# ODF repetition is particularly important for sparse spreadsheet layouts.
(out / 'repeated.fods').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<office:document xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"
 office:mimetype="application/vnd.oasis.opendocument.spreadsheet">
<office:body><office:spreadsheet><table:table table:name="Sparse">
<table:table-row><table:table-cell table:number-columns-repeated="2"/>
<table:table-cell office:value-type="string"><text:p>Third column</text:p></table:table-cell></table:table-row>
<table:table-row table:number-rows-repeated="2"><table:table-cell office:value-type="float" office:value="7"><text:p>7</text:p></table:table-cell></table:table-row>
</table:table></office:spreadsheet></office:body></office:document>''')
with (out / 'oversized.csv').open('wb') as f:
    f.truncate(21 * 1024 * 1024)

base = (out / 'repeated.fods').read_text()
# This tiny input formerly allocated a million cells inside the third-party parser.
bomb = base.replace('table:number-columns-repeated="2"', 'table:number-columns-repeated="1000000" office:value-type="float" office:value="1"')
(out / 'repetition-bomb.fods').write_text(bomb)
with zipfile.ZipFile(out / 'repetition-bomb.ods', 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('mimetype', 'application/vnd.oasis.opendocument.spreadsheet')
    z.writestr('content.xml', bomb)
repeated = base.replace('table:number-columns-repeated="2"/>', 'table:number-columns-repeated="3" office:value-type="string"><text:p>x</text:p></table:table-cell>')
(out / 'repeated-values.fods').write_text(repeated)

(out / 'alias-bomb.fods').write_text(bomb.replace('table:table-cell', 'table:table-cell_bypass'))
spaces = base.replace('Third column', 'x' + '<text:s text:c="32768"/>' * 1000)
(out / 'spaces-bomb.fods').write_text(spaces)
# A foreign extension must not evade content validation of XML input.
(out / 'renamed-bomb.xls').write_text(bomb)
# CSV is always text, even when it looks like an OpenDocument document.
(out / 'xml-looking.csv').write_text(bomb)
