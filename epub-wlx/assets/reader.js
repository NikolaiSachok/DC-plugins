/*
 * EpubView reader.
 *
 * The native side serves the book over x-epub:// straight out of the ZIP; this
 * script owns the EPUB document model and the reading experience:
 *
 *   META-INF/container.xml -> OPF (metadata, manifest, spine)
 *                          -> EPUB 3 nav document or EPUB 2 NCX for the TOC
 *                          -> spine documents, sanitized and appended in order
 *
 * Everything a book contributes is untrusted, so each chapter goes through
 * DOMPurify, and only x-epub:/data: URIs survive — an http(s) reference is
 * dropped rather than fetched (the page CSP forbids it in any case).
 */
(function () {
  "use strict";

  var CFG = JSON.parse(document.getElementById("dc-config").textContent);

  var $ = function (id) { return document.getElementById(id); };
  var bookEl = $("book"), tocEl = $("toc"), tocList = $("toc-list"),
      statusEl = $("status"), percentEl = $("percent"), progressEl = $("progress-bar");

  var state = {
    chapters: [],        /* { url, path, section } in spine order */
    pending: null,       /* TOC target waiting for its chapter to load */
    tocLinks: [],
    userScrolled: false,
    restored: false,
    fontSize: CFG.fontSize
  };

  /* ---------- small helpers ---------- */

  function abs(rel, base) {
    try { return new URL(rel, base).href; } catch (e) { return null; }
  }
  function stripFragment(u) { var i = u.indexOf("#"); return i < 0 ? u : u.slice(0, i); }
  function fragmentOf(u) { var i = u.indexOf("#"); return i < 0 ? "" : u.slice(i + 1); }
  function inBook(u) { return typeof u === "string" && u.indexOf(CFG.base) === 0; }

  /* Local names, so a prefixed OPF (`opf:manifest`) parses like an unprefixed one. */
  function tags(root, name) {
    return Array.prototype.slice.call(root.getElementsByTagNameNS("*", name));
  }
  function textOf(el) { return el ? (el.textContent || "").trim() : ""; }

  function fail(message) {
    if (statusEl) {
      statusEl.textContent = message;
      statusEl.style.color = "";
    }
  }

  /* Books predate UTF-8 ubiquity; honour a declared encoding when there is one. */
  function decode(bytes) {
    if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      return new TextDecoder("utf-8").decode(bytes.subarray(3));
    }
    var head = new TextDecoder("windows-1252").decode(bytes.subarray(0, 1024));
    var m = head.match(/encoding\s*=\s*["']([\w-]+)["']/i) ||
            head.match(/charset\s*=\s*["']?([\w-]+)/i);
    var label = m ? m[1].toLowerCase() : "utf-8";
    if (label === "utf8") label = "utf-8";
    try { return new TextDecoder(label).decode(bytes); }
    catch (e) { return new TextDecoder("utf-8").decode(bytes); }
  }

  function fetchText(url) {
    return fetch(url).then(function (r) {
      if (!r.ok) throw new Error(r.status + " " + url);
      return r.arrayBuffer();
    }).then(function (buf) { return decode(new Uint8Array(buf)); });
  }

  function parseXML(text) {
    var doc = new DOMParser().parseFromString(text, "application/xml");
    if (doc.getElementsByTagName("parsererror").length) return null;
    return doc;
  }

  /* XHTML first (it is what the spec asks for), HTML as the forgiving fallback
   * — plenty of shipped books are not well-formed XML. */
  function parseDocument(text) {
    var doc = new DOMParser().parseFromString(text, "application/xhtml+xml");
    if (!doc || doc.getElementsByTagName("parsererror").length || !doc.documentElement) {
      doc = new DOMParser().parseFromString(text, "text/html");
    }
    return doc;
  }

  /* ---------- theme / typography ---------- */

  function applyTypography() {
    var root = document.documentElement.style;
    root.setProperty("--font-size", state.fontSize + "px");
    root.setProperty("--line-height", String(CFG.lineHeight));
    root.setProperty("--measure", CFG.maxWidth + "px");
    root.setProperty("--align", CFG.justify ? "justify" : "start");
  }

  function setFontSize(px) {
    state.fontSize = Math.max(12, Math.min(34, px));
    applyTypography();
    post({ t: "font", v: state.fontSize });
  }

  /* Hand the main thread back between chapters. Chapters are appended in a
   * promise chain, and microtasks alone never let a frame through — without
   * this the reader stays frozen on the first page until the whole book has
   * been parsed. A timer, not requestAnimationFrame: frame callbacks are
   * suspended while the viewer window is occluded or off-screen, which would
   * stall the book entirely. */
  function yieldToRender() {
    return new Promise(function (resolve) { setTimeout(resolve, 0); });
  }

  function post(msg) {
    try { window.webkit.messageHandlers.dcepub.postMessage(msg); } catch (e) {}
  }

  /* ---------- sanitising ---------- */

  /* Only in-book (x-epub:), data: and fragment URIs survive. Anything remote is
   * stripped, which is what keeps "no network at view time" structurally true. */
  var URI_OK = /^(?:x-epub:|#|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i;
  var PURIFY = {
    USE_PROFILES: { html: true, svg: true, svgFilters: true, mathMl: true },
    ALLOWED_URI_REGEXP: URI_OK,
    ADD_ATTR: ["colspan", "rowspan", "start", "reversed", "type"]
  };

  var XLINK = "http://www.w3.org/1999/xlink";

  /* Rewrite every reference in a chapter to an absolute in-book URL, so the
   * whole spine can live in one document without a per-chapter <base>. */
  function resolveReferences(root, chapterURL) {
    var attrs = ["src", "poster", "data", "longdesc"];
    Array.prototype.forEach.call(root.querySelectorAll("*"), function (el) {
      attrs.forEach(function (a) {
        if (!el.hasAttribute(a)) return;
        var u = abs(el.getAttribute(a), chapterURL);
        if (u && inBook(u)) el.setAttribute(a, u); else el.removeAttribute(a);
      });
      if (el.hasAttributeNS(XLINK, "href")) {
        var xu = abs(el.getAttributeNS(XLINK, "href"), chapterURL);
        if (xu && inBook(xu)) el.setAttributeNS(XLINK, "xlink:href", xu);
        else el.removeAttributeNS(XLINK, "href");
      }
      if (el.hasAttribute("srcset")) el.removeAttribute("srcset");
      if (el.hasAttribute("href")) {
        var raw = el.getAttribute("href");
        var name = el.localName;
        if (name === "a" || name === "area") {
          var h = abs(raw, chapterURL);
          /* Internal links become in-page jumps; external ones lose their href
           * but keep their text — the viewer has nowhere to navigate to. */
          if (h && inBook(h)) { el.setAttribute("href", h); el.setAttribute("data-link", "1"); }
          else el.removeAttribute("href");
        } else if (name !== "link") {
          var o = abs(raw, chapterURL);
          if (o && inBook(o)) el.setAttribute("href", o); else el.removeAttribute("href");
        }
      }
    });
  }

  /* ---------- publisher CSS (opt-in) ---------- */

  var cssSeen = Object.create(null);

  /* Scope the book's own stylesheet to chapter content using the browser's CSS
   * parser (so @media nesting and @font-face survive intact) — otherwise a rule
   * on `body` would restyle the reader's own chrome. */
  function injectPublisherCSS(cssText, cssURL) {
    var withURLs = cssText.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi, function (m, q, u) {
      if (/^(data:|x-epub:)/i.test(u)) return m;
      var r = abs(u, cssURL);
      return r && inBook(r) ? 'url("' + r + '")' : "url(about:blank)";
    });
    var style = document.createElement("style");
    style.textContent = withURLs;
    document.head.appendChild(style);
    var sheet = style.sheet;
    if (!sheet) return;
    (function rewrite(rules) {
      Array.prototype.forEach.call(rules, function (rule) {
        if (rule.selectorText) {
          rule.selectorText = rule.selectorText.split(",").map(function (s) {
            s = s.trim();
            return /^(html|body)\b/i.test(s)
              ? "#book " + s.replace(/^(html|body)/i, ".chapter")
              : "#book " + s;
          }).join(", ");
        } else if (rule.cssRules) {
          rewrite(rule.cssRules);
        }
      });
    })(sheet.cssRules || []);
  }

  function collectPublisherCSS(doc, chapterURL) {
    if (!CFG.publisherCSS) return Promise.resolve();
    var jobs = [];
    Array.prototype.forEach.call(doc.querySelectorAll("style"), function (el) {
      jobs.push(Promise.resolve(injectPublisherCSS(el.textContent || "", chapterURL)));
    });
    Array.prototype.forEach.call(doc.querySelectorAll('link[rel~="stylesheet" i]'),
      function (el) {
        var u = abs(el.getAttribute("href") || "", chapterURL);
        if (!u || !inBook(u) || cssSeen[u]) return;
        cssSeen[u] = true;
        jobs.push(fetchText(u).then(function (t) { injectPublisherCSS(t, u); })
                              .catch(function () {}));
      });
    return Promise.all(jobs);
  }

  /* ---------- package parsing ---------- */

  function loadPackage() {
    return fetchText(CFG.base + "META-INF/container.xml").then(function (text) {
      var doc = parseXML(text);
      var rootfile = doc && tags(doc, "rootfile")[0];
      var full = rootfile && rootfile.getAttribute("full-path");
      if (!full) throw new Error("container.xml names no package document");
      var opfURL = abs(full, CFG.base);
      return fetchText(opfURL).then(function (opfText) {
        var opf = parseXML(opfText) || parseDocument(opfText);
        if (!opf) throw new Error("the package document (OPF) is not valid XML");
        return buildBook(opf, opfURL);
      });
    });
  }

  function buildBook(opf, opfURL) {
    var book = { url: opfURL, items: {}, spine: [], meta: {}, cover: null, tocHref: null };

    tags(opf, "item").forEach(function (el) {
      var id = el.getAttribute("id");
      var href = el.getAttribute("href");
      if (!id || !href) return;
      book.items[id] = {
        id: id,
        url: abs(href, opfURL),
        type: el.getAttribute("media-type") || "",
        props: el.getAttribute("properties") || ""
      };
    });

    var metaEl = tags(opf, "metadata")[0] || opf.documentElement;
    book.meta.title  = textOf(tags(metaEl, "title")[0]);
    book.meta.author = tags(metaEl, "creator").map(textOf).filter(Boolean).join(", ");

    /* Spine order is the reading order; `linear="no"` items are kept because a
     * viewer should show everything the file contains. */
    var spineEl = tags(opf, "spine")[0];
    if (spineEl) {
      tags(spineEl, "itemref").forEach(function (el) {
        var item = book.items[el.getAttribute("idref")];
        if (item && item.url) book.spine.push(item);
      });
      var ncxId = spineEl.getAttribute("toc");
      if (ncxId && book.items[ncxId]) book.tocHref = { url: book.items[ncxId].url, kind: "ncx" };
    }

    /* EPUB 3's nav document supersedes the NCX when both are present. */
    for (var id in book.items) {
      if (/\bnav\b/.test(book.items[id].props)) {
        book.tocHref = { url: book.items[id].url, kind: "nav" };
        break;
      }
    }

    book.cover = findCover(opf, book);
    return book;
  }

  function findCover(opf, book) {
    var id;
    for (id in book.items) {
      if (/\bcover-image\b/.test(book.items[id].props)) return book.items[id];
    }
    var metaCover = tags(opf, "meta").filter(function (m) {
      return (m.getAttribute("name") || "").toLowerCase() === "cover";
    })[0];
    var ref = metaCover && book.items[metaCover.getAttribute("content")];
    if (ref && /^image\//.test(ref.type)) return ref;
    for (id in book.items) {
      if (/^image\//.test(book.items[id].type) && /cover/i.test(id)) return book.items[id];
    }
    return null;
  }

  /* ---------- table of contents ---------- */

  function loadTOC(book) {
    if (!book.tocHref) return Promise.resolve([]);
    var src = book.tocHref;
    return fetchText(src.url).then(function (text) {
      return src.kind === "nav" ? parseNav(text, src.url) : parseNCX(text, src.url);
    }).catch(function () { return []; });
  }

  function parseNav(text, navURL) {
    var doc = parseDocument(text);
    var navs = tags(doc, "nav");
    var toc = navs.filter(function (n) {
      return /\btoc\b/.test(n.getAttribute("epub:type") || n.getAttribute("type") || "");
    })[0] || navs[0];
    if (!toc) return [];

    var out = [];
    (function walk(list, depth) {
      Array.prototype.forEach.call(list.children, function (li) {
        if (li.localName !== "li") return;
        var a = li.querySelector("a, span");
        var href = a && a.getAttribute && a.getAttribute("href");
        if (a) {
          out.push({
            label: textOf(a),
            url: href ? abs(href, navURL) : null,
            depth: depth
          });
        }
        Array.prototype.forEach.call(li.children, function (child) {
          if (child.localName === "ol" || child.localName === "ul") walk(child, depth + 1);
        });
      });
    })(toc.querySelector("ol, ul") || toc, 0);
    return out;
  }

  function parseNCX(text, ncxURL) {
    var doc = parseXML(text) || parseDocument(text);
    if (!doc) return [];
    var map = tags(doc, "navMap")[0];
    if (!map) return [];

    var out = [];
    (function walk(parent, depth) {
      Array.prototype.forEach.call(parent.children, function (pt) {
        if (pt.localName !== "navPoint") return;
        var label = textOf(tags(pt, "text")[0]);
        var content = tags(pt, "content")[0];
        var src = content && content.getAttribute("src");
        out.push({ label: label, url: src ? abs(src, ncxURL) : null, depth: depth });
        walk(pt, depth + 1);
      });
    })(map, 0);
    return out;
  }

  function renderTOC(entries) {
    if (!entries.length) {
      tocEl.classList.add("empty");
      return;
    }
    var frag = document.createDocumentFragment();
    entries.forEach(function (e) {
      var li = document.createElement("li");
      li.setAttribute("data-depth", String(Math.min(e.depth, 3)));
      var a = document.createElement("a");
      a.textContent = e.label || "—";
      a.href = e.url || "#";
      a.addEventListener("click", function (ev) {
        ev.preventDefault();
        if (e.url) goTo(e.url);
        if (window.innerWidth <= 900) setTOC(false);
      });
      li.appendChild(a);
      frag.appendChild(li);
      state.tocLinks.push({ entry: e, el: a });
    });
    tocList.appendChild(frag);
  }

  /* ---------- chapters ---------- */

  function addChapter(item, index) {
    return fetchText(item.url).then(function (text) {
      var doc = parseDocument(text);
      var body = doc.body || tags(doc, "body")[0] || doc.documentElement;
      return collectPublisherCSS(doc, item.url).then(function () {
        resolveReferences(body, item.url);

        var section = document.createElement("section");
        section.className = "chapter";
        section.setAttribute("data-path", stripFragment(item.url));
        section.id = "ch" + index;
        section.innerHTML = DOMPurify.sanitize(body.innerHTML, PURIFY);
        bookEl.appendChild(section);
        state.chapters.push({ url: item.url, path: stripFragment(item.url), section: section });
        return section;
      });
    }).catch(function () {
      /* One unreadable chapter must not end the book. */
      var section = document.createElement("section");
      section.className = "chapter";
      section.setAttribute("data-path", stripFragment(item.url));
      section.id = "ch" + index;
      section.innerHTML = "";
      var p = document.createElement("p");
      p.style.color = "var(--muted)";
      p.textContent = "[ this section could not be read ]";
      section.appendChild(p);
      bookEl.appendChild(section);
      state.chapters.push({ url: item.url, path: stripFragment(item.url), section: section });
      return section;
    });
  }

  /* Most books open on a cover page that already shows the cover art, so the
   * plate is only added when the first section doesn't display it — otherwise
   * the reader would show the same image twice. */
  function maybeRenderCover(book, firstSection) {
    if (!book.cover) return;
    var shown = Array.prototype.some.call(
      firstSection.querySelectorAll("img, image"),
      function (el) {
        return el.getAttribute("src") === book.cover.url ||
               el.getAttributeNS(XLINK, "href") === book.cover.url;
      });
    if (shown) return;

    var wrap = document.createElement("div");
    wrap.id = "cover";
    var img = document.createElement("img");
    img.src = book.cover.url;
    img.alt = book.meta.title || "Cover";
    img.addEventListener("error", function () { wrap.remove(); });
    wrap.appendChild(img);
    bookEl.insertBefore(wrap, bookEl.firstChild);
  }

  /* ---------- navigation ---------- */

  function findTarget(url) {
    var path = stripFragment(url), frag = fragmentOf(url);
    for (var i = 0; i < state.chapters.length; i++) {
      var c = state.chapters[i];
      if (c.path !== path) continue;
      if (!frag) return c.section;
      return c.section.querySelector('[id="' + CSS.escape(frag) + '"]') ||
             c.section.querySelector('[name="' + CSS.escape(frag) + '"]') ||
             c.section;
    }
    return null;
  }

  function goTo(url) {
    var el = findTarget(url);
    if (el) {
      state.userScrolled = true;
      scrollToElement(el);
      state.pending = null;
    } else {
      state.pending = url;  /* the chapter has not been appended yet */
    }
  }

  function scrollToElement(el) {
    var top = el.getBoundingClientRect().top + window.scrollY - 52;
    window.scrollTo({ top: Math.max(0, top), behavior: "auto" });
  }

  function setTOC(open) {
    document.documentElement.classList.toggle("toc-open", open);
  }

  /* ---------- reading position ---------- */

  function currentChapterIndex() {
    var probe = window.scrollY + 64, idx = 0;
    for (var i = 0; i < state.chapters.length; i++) {
      if (state.chapters[i].section.offsetTop <= probe) idx = i; else break;
    }
    return idx;
  }

  function onScroll() {
    var doc = document.documentElement;
    var scrollable = doc.scrollHeight - window.innerHeight;
    var pct = scrollable > 0 ? Math.min(1, Math.max(0, window.scrollY / scrollable)) : 0;
    progressEl.style.width = (pct * 100).toFixed(2) + "%";
    percentEl.textContent = Math.round(pct * 100) + "%";

    var i = currentChapterIndex();
    var c = state.chapters[i];
    if (c) {
      var h = c.section.offsetHeight || 1;
      var r = Math.min(1, Math.max(0, (window.scrollY - c.section.offsetTop) / h));
      post({ t: "pos", i: i, r: r });
      highlightTOC(c.path);
    }
  }

  var lastHighlight = null;
  function highlightTOC(path) {
    if (path === lastHighlight) return;
    lastHighlight = path;
    var best = null;
    state.tocLinks.forEach(function (l) {
      l.el.classList.remove("current");
      if (l.entry.url && stripFragment(l.entry.url) === path && !best) best = l;
    });
    if (best) best.el.classList.add("current");
  }

  function restorePosition() {
    var pos = CFG.position || {};
    var i = pos.i | 0;
    if (state.restored || state.userScrolled || !state.chapters[i]) return;
    var c = state.chapters[i];
    var top = c.section.offsetTop + (c.section.offsetHeight * (Number(pos.r) || 0));
    if (top > 4) window.scrollTo({ top: top, behavior: "auto" });
    state.restored = true;
  }

  /* ---------- chrome ---------- */

  function wireChrome(book) {
    $("book-title").textContent = book.meta.title || CFG.fileName;
    $("book-author").textContent = book.meta.author || "";
    document.title = book.meta.title || CFG.fileName;

    $("toc-toggle").addEventListener("click", function () {
      setTOC(!document.documentElement.classList.contains("toc-open"));
    });
    $("scrim").addEventListener("click", function () { setTOC(false); });
    $("font-down").addEventListener("click", function () { setFontSize(state.fontSize - 1); });
    $("font-up").addEventListener("click", function () { setFontSize(state.fontSize + 1); });

    /* In-book links jump within the single scrolling document. */
    bookEl.addEventListener("click", function (ev) {
      var a = ev.target.closest && ev.target.closest("a[data-link]");
      if (!a) return;
      ev.preventDefault();
      goTo(a.getAttribute("href"));
    });

    document.addEventListener("keydown", function (ev) {
      if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
      if (ev.key === "t" || ev.key === "T") {
        setTOC(!document.documentElement.classList.contains("toc-open"));
        ev.preventDefault();
      } else if (ev.key === "+" || ev.key === "=") {
        setFontSize(state.fontSize + 1); ev.preventDefault();
      } else if (ev.key === "-" || ev.key === "_") {
        setFontSize(state.fontSize - 1); ev.preventDefault();
      }
    });

    ["wheel", "touchstart", "keydown", "mousedown"].forEach(function (evt) {
      window.addEventListener(evt, function () { state.userScrolled = true; },
                              { passive: true, once: true });
    });

    /* Throttled on a timer rather than a frame callback, for the same reason as
     * yieldToRender: an occluded window gets no frames, and a pending flag that
     * never clears would freeze the progress readout for good. */
    var ticking = false;
    window.addEventListener("scroll", function () {
      if (ticking) return;
      ticking = true;
      setTimeout(function () { ticking = false; onScroll(); }, 60);
    }, { passive: true });

    if (CFG.showVersion) {
      var v = document.createElement("div");
      v.id = "version";
      v.textContent = "EpubView v" + CFG.version;
      document.body.appendChild(v);
    }
  }

  function addColophon(book) {
    var el = document.createElement("div");
    el.id = "colophon";
    var bits = [book.meta.title, book.meta.author].filter(Boolean);
    el.textContent = bits.join(" — ") || CFG.fileName;
    bookEl.appendChild(el);
  }

  /* ---------- go ---------- */

  applyTypography();

  loadPackage().then(function (book) {
    wireChrome(book);
    if (!book.spine.length) throw new Error("the package document lists no readable sections");

    statusEl.remove();

    return loadTOC(book).then(function (entries) {
      renderTOC(entries);

      /* Chapters are appended one at a time so the first page is readable while
       * the rest of the book is still arriving. */
      var chain = Promise.resolve();
      book.spine.forEach(function (item, i) {
        chain = chain.then(function () {
          return addChapter(item, i).then(function (section) {
            if (i === 0) maybeRenderCover(book, section);
            if (state.pending) {
              var el = findTarget(state.pending);
              if (el) { scrollToElement(el); state.pending = null; }
            } else if (!state.restored && (CFG.position || {}).i === i) {
              restorePosition();
            }
            onScroll();
            return yieldToRender();
          });
        });
      });
      return chain.then(function () {
        addColophon(book);
        restorePosition();
        onScroll();
      });
    });
  }).catch(function (err) {
    fail("This book could not be opened — " + (err && err.message ? err.message : err) + ".");
  });
})();
