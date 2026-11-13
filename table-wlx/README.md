# TableView — spreadsheet previews for Double Commander on macOS

A native, read-only table viewer for **F3** and **Quick View**. Select a cell or
rectangle and copy its values into Excel, Numbers, a text editor or another app.
No Office installation, Python packages, network connection or external converter
is required. Universal arm64 + x86_64; macOS 11 or later.

## Formats

| Family | Extensions | Notes |
|---|---|---|
| Delimited text | `.csv`, `.tsv` | Comma/semicolon/tab detection, quoted delimiters and multiline cells. CSV values stay text, preserving leading zeros. UTF-8, BOM-marked UTF-16, Windows-1252 fallback. |
| Microsoft Excel | `.xlsx`, `.xlsm`, `.xlsb`, `.xls` | Multiple worksheets, formatted numbers/dates and stored formula results. Macros never run. |
| Apple Numbers | `.numbers` | Modern Numbers 3.0+ / iWork 2013+ files saved as a single file. Each Numbers table becomes a separate worksheet in the picker. Older XML/package documents are unsupported. |
| OpenDocument | `.ods`, `.fods` | LibreOffice/OpenOffice spreadsheet values and worksheets; includes flat XML spreadsheets. |
| Data interchange | `.dif`, `.slk`, `.sylk`, `.dbf` | DIF, SYLK and dBASE tables. |

Workbook decoding uses [SheetJS CE 0.20.3](https://docs.sheetjs.com/docs/miscellany/formats/),
embedded in the binary and run in JavaScriptCore without filesystem or network
APIs. CSV/TSV have a separate bounded text parser and never undergo workbook-format
detection. The grid is AppKit; cell contents are drawn as literal text, never HTML.
Builds and tests run offline using the vendored library and generated fixtures.

## Selection and copying

- Click a cell; drag or Shift-click to select a rectangular range.
- Click a row number or column letter to select the entire row or column.
- Click the top-left corner or press **Cmd+A** to select the current worksheet.
- **Cmd+C**, **Copy cells**, or the context menu copies selected values as TSV.
  Tabs separate columns, newlines separate rows, and embedded delimiters/newlines
  are quoted. The clipboard excludes headers, row numbers and toolbar text.
- Arrow keys move the active cell; Shift+arrows extend the selection.
  PgUp/PgDn move by a screen; Home/End go to the first/last cell;
  Cmd+arrows go to a worksheet edge. Scroll with the mouse or trackpad.
- Use the worksheet picker to switch sheets or Numbers tables.
- **Cmd+F** and DC's Find Next/Previous search the current worksheet's cell values.
- **Esc**, **N/P**, **Alt+Left/Right** and other unused keys go to DC's viewer.
  In Quick View, the file panel keeps keyboard focus until you click the grid.

## Reading long cells

Drag a divider between column-letter headers to widen or narrow a column
(48–4096 points). Selection, copying and horizontal scrolling follow the new
widths. Widths reset when switching worksheets or opening another file.

The panel below the grid shows the active cell's address and full preview value,
with line breaks preserved. It follows mouse selection, keyboard navigation and
Find. The panel fits one line for short values and grows with wrapped or multiline
content, up to 80 points (its original height). It adapts when the window is
resized. Longer values can be scrolled within the panel; Cmd+C still copies
the selected grid cells. For a range, the panel shows the cell at the moving end
of the selection. The existing per-cell preview limit still applies.

## Scope and limits

This is a data preview, not a spreadsheet editor or a print-layout renderer.
It displays stored values and number formats, without recalculating formulas.
A formula without a cached result may appear blank. Charts, images, comments,
merged-cell layout, rich formatting and conditional formatting are not rendered;
only the stored anchor value of a merged area is shown. Password-protected files
are unsupported. For a Numbers package, use **File → Advanced → Change File Type
→ Single File** in Numbers ([Apple guidance](https://support.apple.com/en-us/119883)).
Google Sheets cloud documents must first be exported as XLSX,
ODS or CSV; `.gsheet` shortcuts do not contain the table data.

The preview accepts regular files up to **20 MB**, with at most **64 MB** of
expanded ZIP data, **128 sheets**, **100,000 rows / 512 columns per sheet**, and
**2 million grid cells across the workbook**. Sheets beyond the remaining cell
budget are empty and marked truncated. Individual displayed cells are limited to
32,768 characters; total cell text is limited to 16 million characters.
ODF repetitions are preflighted before decoding: excessive nonempty row/column
repetitions, expanded text, DTDs/entities and nonstandard legacy tag aliases are
rejected. Large trailing blank ODF ranges are allowed. Oversized
or invalid files show a readable error, and truncated previews are labelled in
the status bar. Only visible grid cells are drawn; parsing runs on a serial
background queue. Navigation cancels stale display handoffs.

## Build and install

```sh
./build.sh
# Quit Double Commander first:
./install.sh
```

The installer places `TableView.wlx` under
`~/Library/Preferences/doublecmd/plugins/wlx/TableView/`, backs up
`doublecmd.xml`, and registers it **before MacPreview**, whose catch-all detection
would otherwise take these files. Re-running is safe and updates one entry.
Prebuilt release bundles use the same installer without requiring Xcode.

To uninstall, remove TableView from DC's **Options → Plugins → Lister plugins**
and delete that plugin directory while DC is closed.

## Verification

```sh
./build.sh
./test/run.sh
```

The fixture generator needs Node.js; the plugin itself does not. Harnesses
`dlopen` the actual universal `.wlx` and call its WLX exports. They cover formats,
quoted CSV, Unicode, leading zeros, cached formulas, dates, worksheet changes,
selection, clipboard contents, search ordering, malformed/large files, stale
loads, rendering, focus and re-posted host shortcuts. Run from a logged-in macOS
desktop session: pasteboard and window-event assertions require desktop services.
The parsers, fixture template and licenses are vendored, so no test downloads occur.

Before shipping, verify F3, mouse range selection, Cmd+C, Cmd+A, Find, worksheet
switching, N/P, Esc, PgUp/PgDn and Ctrl+Q in **real Double Commander**. A host
harness is a regression net; it cannot prove LCL's event dispatch works.
