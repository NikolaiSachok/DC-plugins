/* Math delimiter handling for MarkdownView (issue #23).
 *
 * marked must tokenize math itself. Left to the default rules it treats \( \) \[ \]
 * as backslash escapes for punctuation and emits a bare ( or [, so the delimiter is
 * gone before KaTeX ever sees the DOM — which is why $$ was once the only pair that
 * worked. An inline extension is tried ahead of the built-in escape tokenizer, so
 * the span is claimed intact; it also makes math work inside lists and tables.
 *
 * The TeX is carried as textContent, never markup, and rendered after sanitizing.
 *
 * This lives in its own file rather than inside the plugin's bootstrap string
 * because the regexes below need exact escaping, and a C string literal is a
 * needless second layer of it.
 */
(function () {
  "use strict";

  /* Bound the scan so a stray opener cannot swallow a whole document. */
  var INLINE_MAX = 500;
  var DISPLAY_MAX = 5000;

  /* A character that suggests real TeX rather than prose. */
  var MATHY = /[\\^_{}=+*\/<>|&~!-]/;

  function mkSpan(tex, display) {
    var sp = document.createElement("span");
    sp.className = "dc-math";
    sp.setAttribute("data-display", display ? "1" : "0");
    sp.textContent = tex;
    return sp.outerHTML;
  }

  /* \( and \[ are also CommonMark's escapes for a literal paren or bracket, so a
   * backslash-delimited span has to look like math before we claim it: "see
   * footnote \[1\]" and "match \(a group\)" are text, not formulas. Dollar pairs
   * carry no such ambiguity and get no content test — $$ x $$, $$0$$ and
   * $$a b c$$ are all valid display math. */
  function bodyOk(pair, tex) {
    if (!tex || !tex.trim()) return false;
    if (tex.indexOf("`") >= 0) return false;      /* ran into an inline code span */
    if (tex.length > (pair.display ? DISPLAY_MAX : INLINE_MAX)) return false;
    if (!pair.escape) return true;
    if (/^[\s\d.,;:]+$/.test(tex)) return false;  /* \[1\], \(2\) — footnote markers */
    if (!MATHY.test(tex)) {
      /* No TeX character at all. Display math is a big centred block, so a false
       * positive there is far more damaging: require the hint. Inline may pass on
       * a single bare token, which is how \(x\) works. */
      if (pair.display) return false;
      if (/\s/.test(tex)) return false;           /* \(a group\) */
    }
    return true;
  }

  /* Never claim a delimiter glued to a word: "file\(s\)" is an escaped paren,
   * "let \(x\) be" is math. */
  function afterWordChar(ch) {
    return !!ch && /[A-Za-z0-9]/.test(ch);
  }

  function prevOk(tokens) {
    if (!tokens || !tokens.length) return true;
    var raw = tokens[tokens.length - 1].raw || "";
    return !afterWordChar(raw.charAt(raw.length - 1));
  }

  function pairsFor(dollar) {
    var p = [
      { name: "dcMathDD", open: "$$",   close: "$$",   display: true,  escape: false },
      { name: "dcMathDB", open: "\\[",  close: "\\]",  display: true,  escape: true  },
      { name: "dcMathIP", open: "\\(",  close: "\\)",  display: false, escape: true  }
    ];
    /* Single-$ must be tried after $$, or every $$ block parses as an empty $…$ */
    if (dollar) p.push({ name: "dcMathID", open: "$", close: "$", display: false, escape: false });
    return p;
  }

  /* Text inside these raw-HTML elements is meant to be shown, not rendered. */
  var SKIP_OPEN = /^<\s*(pre|code|script|style)\b/i;
  var SKIP_CLOSE = /^<\s*\/\s*(pre|code|script|style)\s*>/i;
  /* A tag — quoted attribute values may contain ">" — or a run of text. */
  var CHUNK = /<[^>"']*(?:"[^"]*"|'[^']*'|[^>"'])*>|[^<]+/g;

  function substitute(pairs, text) {
    pairs.forEach(function (p) {
      var out = "", rest = text;
      for (;;) {
        var a = rest.indexOf(p.open);
        if (a < 0) break;
        var b = rest.indexOf(p.close, a + p.open.length);
        if (b < 0) break;
        var tex = rest.slice(a + p.open.length, b);
        var before = a > 0 ? rest.charAt(a - 1) : out.charAt(out.length - 1);
        if (bodyOk(p, tex) && !afterWordChar(before)) {
          out += rest.slice(0, a) + mkSpan(tex, p.display);
        } else {
          out += rest.slice(0, b + p.close.length);
        }
        rest = rest.slice(b + p.close.length);
      }
      text = out + rest;
    });
    return text;
  }

  function inRawHtml(pairs, s) {
    var skipDepth = 0;
    return String(s).replace(CHUNK, function (chunk) {
      if (chunk.charAt(0) === "<") {
        if (SKIP_OPEN.test(chunk) && chunk.slice(-2) !== "/>") skipDepth++;
        else if (SKIP_CLOSE.test(chunk) && skipDepth > 0) skipDepth--;
        return chunk;
      }
      return skipDepth > 0 ? chunk : substitute(pairs, chunk);
    });
  }

  /* Register the tokenizers. Call before marked.parse(). */
  window.__dcMathSetup = function (marked, opts) {
    var pairs = pairsFor(opts && opts.dollar);

    /* marked.use() *unshifts* each tokenizer, so the registered order comes out
     * reversed — register back-to-front to keep $$ ahead of $. */
    marked.use({
      extensions: pairs.slice().reverse().map(function (p) {
        return {
          name: p.name,
          level: "inline",
          start: function (s) { var i = s.indexOf(p.open); return i < 0 ? undefined : i; },
          tokenizer: function (s, tokens) {
            if (s.slice(0, p.open.length) !== p.open) return;
            if (!prevOk(tokens)) return;
            var e = s.indexOf(p.close, p.open.length);
            if (e < 0) return;
            var tex = s.slice(p.open.length, e);
            if (!bodyOk(p, tex)) return;
            return { type: p.name, raw: s.slice(0, e + p.close.length),
                     text: tex, display: p.display };
          },
          renderer: function (t) { return mkSpan(t.text, t.display); }
        };
      })
    });

    /* marked passes raw HTML blocks through untouched, so the extension never sees
     * them. Substitute in their text as well, which keeps the common
     * <div align="center">$$…$$</div> idiom working. Backslashes are literal in
     * raw HTML, so the escape ambiguity above does not arise there. */
    marked.use({
      renderer: {
        html: function (tok) {
          /* marked 12 passes a string; newer versions pass a token. */
          var s = (typeof tok === "string") ? tok : ((tok && (tok.text || tok.raw)) || "");
          return inRawHtml(pairs, s);
        }
      }
    });
  };

  /* Render the spans the tokenizers left behind. Call after sanitizing. */
  window.__dcMathRender = function (root) {
    if (!window.katex || !root) return;
    root.querySelectorAll("span.dc-math").forEach(function (el) {
      try {
        katex.render(el.textContent, el, {
          displayMode: el.getAttribute("data-display") === "1",
          throwOnError: false
        });
      } catch (e) { /* leave the source visible */ }
    });
  };
})();
