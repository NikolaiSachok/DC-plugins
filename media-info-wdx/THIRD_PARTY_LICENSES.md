# Third-party licenses — media-info-wdx

**None.** This plugin vendors no third-party libraries and makes no network access.

All metadata is read with macOS system frameworks that ship with the OS:

| Framework | Used for |
|-----------|----------|
| ImageIO | image dimensions, DPI, bit depth (header read only) |
| AVFoundation / CoreMedia | audio & video duration, dimensions, codecs, sample rate, channels |
| CoreGraphics (CGPDF) | PDF page count |
| Foundation | everything else |

The plugin's own source is MIT-licensed — see the repository [LICENSE](../LICENSE).
