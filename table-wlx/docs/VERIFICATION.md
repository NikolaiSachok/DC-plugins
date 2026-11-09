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
