# Sample documents

Markdown files for eyeballing the renderer and for snapshot testing.

| File | Exercises |
|------|-----------|
| [`features.md`](features.md) | Mermaid diagram, KaTeX math, code highlighting, tables, task lists, nested structure |
| [`basics.md`](basics.md) | Emphasis, autolinks, **relative image** (`img/sample.svg`), long code block, RTL text, nested lists |

Render one without installing, via the snapshot harness:

```sh
cd ..        # markdown-wlx/
./build.sh && cp -R assets build/assets
clang -arch arm64 -fobjc-arc -framework Cocoa -framework WebKit -o build/snap_host test/snap_host.m
./build/snap_host build/MarkdownView.wlx samples/features.md /tmp/out.png && open /tmp/out.png
```

Contributions of more samples (footnotes, definition lists, complex tables, large
documents) are welcome — see issue #8.
