# TableView 0.1.0 verification

Verified on macOS in a logged-in desktop session with Double Commander 1.2.8.
The live checks used an isolated Double Commander profile and synthetic files.

- Universal Mach-O binary: arm64 + x86_64; ad-hoc signature verified.
- Seven WLX entry points present, including `ListSendCommand` and `ListSearchTextW`.
- Real-artifact `test_host` and `keys_verify` desktop harnesses pass.
- Registration tests verify idempotence, unique backups and precedence over
  MacPreview, using detection read from the actual binary.
- Live F3: CSV, Numbers, ODS and XLSX show their values in the native grid.
- A CSV A2:B3 range copied via Cmd+C and pasted into DC's Find field contains
  Alpha/42 and Beta/0 in order, without toolbar or coordinate text.
- XLSX sheet picker switches First to Second and updates the displayed table.
- N navigates through several supported formats while the plugin owns focus.
- Esc closes the F3 viewer. Quick View displays the selected file without
  stealing the file panel's keyboard navigation.
- A large CSV shows the 100,000-row cap explicitly. PgDn/PgUp move selection;
  Find for `Row 500` selects A502 and scrolls it into view with headers frozen.
- Rendering snapshots are produced by the harness under `build/samples/`.

The plain terminal sandbox lacks macOS pasteboard/window-event services. Its
clipboard and event-delivery assertions fail with XPC connection errors; those
checks were therefore run successfully as native test apps in the desktop
session. This is an environment distinction, not a skipped assertion.

## TableView 0.2.0 feature verification (release 2026-11-14)

- Universal build, exported ABI, ad-hoc signature and registration checks pass.
- Desktop real-artifact harness: 79 assertions pass, covering divider dragging,
  width bounds, hit testing and copying after resize, wide-cell reveal, full
  multiline/long values, Find updates and clearing stale details. Adaptive panel
  checks cover single-line height, multiline growth, wrapping after narrowing the
  window, the 80-point cap, and shrinking without stale scroll space.
- Keyboard/focus harness: 11 assertions pass, including Esc, DC navigation keys
  and Quick View focus.
- Real Double Commander, isolated profile and synthetic `details.csv`: widen the
  Description column, navigate with arrows, read its full wrapped value, and
  scroll the multiline Notes value to its final line. Coordinate headers remain
  visible after horizontal scrolling settles. Esc closes the viewer.
- Real Double Commander: single-line values use a compact panel; a wrapped
  description expands it; multiline notes reach the original 80-point maximum
  with vertical scrolling.

## TableView 0.2.1 frozen header verification

- Frozen headers are a layer-backed sibling of the scroll view. Real-artifact
  checks cover a fixed viewport during two-axis scrolling, body click-through,
  row selection and copied values after scrolling, and divider resizing through
  the overlay. The existing parser, selection, details and keyboard checks pass.
- Verified in Double Commander 1.2.11 with an isolated profile and synthetic
  80-row, 12-column CSV: wheel scrolling, horizontal scrolling through the native
  scroll action, PgDn and Esc. Headers stay at the viewport edges and align with
  visible cells after scrolling.
