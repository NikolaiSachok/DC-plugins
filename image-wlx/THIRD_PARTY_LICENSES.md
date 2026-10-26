# Third-party licenses — image-wlx

This plugin vendors nothing. Decoding uses Apple's **ImageIO** and **AppKit**
(CoreSVG for SVG), drawing uses AppKit and Core Animation, and `.svgz`
decompression uses **zlib**, which ships with macOS and is linked from the SDK
(`-lz`). zlib is under the [zlib license](https://zlib.net/zlib_license.html).

The toolbar icons are SF Symbols drawn by the system at run time; none are
bundled.

The plugin's own source is MIT-licensed — see the repository [LICENSE](../LICENSE).
