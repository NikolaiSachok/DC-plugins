# Third-party licenses — book-wlx

This plugin vendors the following library under `assets/` and loads it at
runtime. It retains its own license.

| Library | File(s) | License | Project |
|---------|---------|---------|---------|
| DOMPurify | `assets/dompurify.min.js` | Apache-2.0 OR MPL-2.0 | https://github.com/cure53/DOMPurify |

Decompression uses **zlib**, which ships with macOS and is linked from the SDK
(`-lz`); nothing is vendored for it. zlib is under the
[zlib license](https://zlib.net/zlib_license.html).

`assets/reader.css` and `assets/reader.js` are this plugin's own source.

To refresh DOMPurify to a current upstream version, see the "Updating the
bundled library" section of [README.md](README.md).

The plugin's own source is MIT-licensed — see the repository [LICENSE](../LICENSE).
