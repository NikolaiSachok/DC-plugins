# Third-party licenses — markdown-wlx

This plugin vendors the following libraries under `assets/` and loads them at
runtime. Each retains its own license; all are permissive.

| Library | File(s) | License | Project |
|---------|---------|---------|---------|
| marked | `assets/marked.min.js` | MIT | https://github.com/markedjs/marked |
| DOMPurify | `assets/dompurify.min.js` | Apache-2.0 OR MPL-2.0 | https://github.com/cure53/DOMPurify |
| highlight.js | `assets/highlight.min.js`, `assets/hl-github.css`, `assets/hl-github-dark.css` | BSD-3-Clause | https://github.com/highlightjs/highlight.js |
| github-markdown-css | `assets/github-markdown.css`, `assets/github-markdown-light.css`, `assets/github-markdown-dark.css` | MIT | https://github.com/sindresorhus/github-markdown-css |
| Mermaid | `assets/mermaid/mermaid.min.js` | MIT | https://github.com/mermaid-js/mermaid |
| KaTeX | `assets/katex/*` (js, css, fonts) | MIT | https://github.com/KaTeX/KaTeX |

To refresh these to current upstream versions, see the "Updating the bundled
libraries" section of [README.md](README.md).

The plugin's own source is MIT-licensed — see the repository [LICENSE](../LICENSE).
