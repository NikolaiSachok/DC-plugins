# Third-party notices

## SheetJS Community Edition 0.20.3

Copyright (C) 2012-present SheetJS LLC.
Licensed under the Apache License, Version 2.0. Full license:
[`assets/SHEETJS-LICENSE.txt`](assets/SHEETJS-LICENSE.txt).

- Project: https://sheetjs.com/ and https://git.sheetjs.com/sheetjs/sheetjs
- Vendored decoder: https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js
- Test-only Numbers template: https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.zahl.js
- License: https://cdn.sheetjs.com/xlsx-0.20.3/package/LICENSE

`assets/xlsx.full.min.js` and `test/fixtures/xlsx.zahl.js` are unmodified upstream
files. The template is used only to generate synthetic Numbers test workbooks;
it is not included in the plugin. `assets/parse.js` and `assets/csv.js` are this project's adapters.
The decoder and adapter are embedded in the binary by `build.sh`.

AppKit, JavaScriptCore and libarchive are macOS system libraries, not redistributed
with this plugin. No third-party fonts, stylesheets or UI assets are used.
