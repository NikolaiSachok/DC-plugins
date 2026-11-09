# Format research (2026-11-09)

The goal is selectable, copyable cell data inside native macOS Double Commander.
A parser's advertised codec coverage is not enough: formats are registered only
when the actual built plugin has a fixture exercising the decode path.

## Included in TableView 0.1.0

| Format | Decision and verification |
|---|---|
| CSV / TSV | Separate bounded text parser preserves string values, leading zeros, quoting and embedded newlines. UTF-8 / UTF-16 / Windows-1252 coverage. |
| XLSX / XLSM / XLSB / XLS | Embedded SheetJS decoder, worksheet picker, number/date formatting, cached results. All four have real-artifact tests. |
| Numbers 3.0+ (`.numbers`) | Supported for single-file IWA documents. SheetJS exposes each Numbers table as a worksheet; it does not reproduce the freeform canvas layout. Tests generate an IWA workbook from the upstream Numbers template. |
| ODS / FODS | Supported. Tests cover workbook-generated and hand-authored sparse/repeated XML, trailing repeated values and hostile expansion metadata. Native preflight rejects dangerous expansion before decoding. |
| DIF / SYLK / DBF | Supported and tested for data interchange and dBASE table browsing. |

SheetJS's [format documentation](https://docs.sheetjs.com/docs/miscellany/formats/)
describes its codecs and the Numbers one-table-per-worksheet mapping. The complete
[standalone build](https://docs.sheetjs.com/docs/getting-started/installation/standalone/)
is necessary for Numbers, XLS and XLSB; the mini build omits those codecs.

Numbers packages are directories rather than regular single files. They are not
claimed as supported inputs. Apple documents switching back to a single file in
[Save a document as a package or a single file](https://support.apple.com/en-us/119883).
Older pre-iWork-2013 Numbers XML is also outside the decoder's supported Numbers
format; exporting XLSX/ODS/CSV is the practical alternative.

## Additional candidates

The same upstream decoder advertises Lotus 1-2-3, Quattro Pro and WPS ET codecs.
These are reasonable future additions, but are not registered until representative
fixtures establish actual display/copy behavior and bounded decoding. Each family
is tracked separately ([Lotus #40](https://github.com/NikolaiSachok/DC-plugins/issues/40),
[Quattro Pro #41](https://github.com/NikolaiSachok/DC-plugins/issues/41),
[WPS #42](https://github.com/NikolaiSachok/DC-plugins/issues/42)) rather than silently claiming every upstream extension.

Google Sheets `.gsheet` files are cloud-document pointers, not spreadsheet data.
Offline support means previewing exported XLSX, ODS or CSV; a live Google API
integration would be a separate product decision involving accounts and networking.
Generic `.xml`, `.html` and `.txt` are intentionally left to other viewers, since
claiming them would intercept unrelated documents. Spreadsheet-template extensions are not registered in this initial version.
