# Basics

Common Markdown elements — useful for eyeballing typography and the
relative-image path.

## Text

**Bold**, _italic_, ~~strikethrough~~, `inline code`, and an autolink:
https://github.com/NikolaiSachok/DC-plugins.

A footnote-style aside and [a labelled link][dc].

[dc]: https://doublecmd.sourceforge.io/

## Relative image

The image below is referenced with a **relative path** (`img/sample.svg`); it
resolves against the document's own folder via the page's `<base>` tag:

![relative image sample](img/sample.svg)

## Long code block

```javascript
// A longer block to check horizontal scrolling and highlighting.
export function debounce(fn, wait = 120) {
  let t = null;
  return function (...args) {
    if (t) clearTimeout(t);
    t = setTimeout(() => { t = null; fn.apply(this, args); }, wait);
  };
}
```

## Right-to-left text

> مرحبا بالعالم — هذا اختبار للنص من اليمين إلى اليسار.
>
> שלום עולם — זוהי בדיקה של טקסט מימין לשמאל.

## Quote, rule, nested list

> Markdown is a lightweight markup language.

---

1. First
   - sub A
   - sub B
2. Second
3. Third
