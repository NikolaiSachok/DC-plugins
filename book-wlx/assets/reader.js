/*
 * BookView reader.
 *
 * The native side serves the book over x-book:// straight out of its container;
 * this script owns the document models and the reading experience.
 *
 *   EPUB  META-INF/container.xml -> OPF (metadata, manifest, spine)
 *                                -> EPUB 3 nav document or EPUB 2 NCX for the TOC
 *                                -> spine documents, sanitized and appended in order
 *
 *   FB2   a single FictionBook XML -> description (metadata, cover)
 *                                  -> binary elements (images, base64)
 *                                  -> body sections, rebuilt element by element
 *
 * Both models produce the same thing — an ordered list of chapters plus a table
 * of contents — and everything downstream (rendering, navigation, progress,
 * reading position) is shared.
 *
 * Everything a book contributes is untrusted. EPUB chapters go through
 * DOMPurify and only x-book:/data: URIs survive, so an http(s) reference is
 * dropped rather than fetched. FB2 is never parsed as markup at all: its
 * elements are mapped one by one onto a fixed HTML vocabulary, and only text
 * crosses over.
 */
(function () {
  "use strict";

  var CFG = JSON.parse(document.getElementById("dc-config").textContent);

  var $ = function (id) { return document.getElementById(id); };
  var bookEl = $("book"), tocEl = $("toc"), tocList = $("toc-list"),
      statusEl = $("status"), percentEl = $("percent"), progressEl = $("progress-bar");

  var state = {
    chapters: [],        /* { key, section } in reading order */
    pending: null,       /* { key, frag } waiting for its chapter to load */
    tocLinks: [],
    userScrolled: false,
    restored: false,
    loaded: false,
    fontSize: CFG.fontSize
  };

  var XLINK = "http://www.w3.org/1999/xlink";

  /* ---------- small helpers ---------- */

  function abs(rel, base) {
    try { return new URL(rel, base).href; } catch (e) { return null; }
  }
  function stripFragment(u) { var i = u.indexOf("#"); return i < 0 ? u : u.slice(0, i); }
  function fragmentOf(u) { var i = u.indexOf("#"); return i < 0 ? "" : u.slice(i + 1); }
  function inBook(u) { return typeof u === "string" && u.indexOf(CFG.base) === 0; }
  /* A resource may come from inside the book, or be inlined in the markup — a
   * base64 image is self-contained and reaches nothing. Everything else is
   * dropped rather than fetched. */
  function usableResource(u) { return inBook(u) || /^data:/i.test(u || ""); }

  /* Local names, so a prefixed document (`opf:manifest`, `fb:section`) parses
   * like an unprefixed one. */
  function tags(root, name) {
    return Array.prototype.slice.call(root.getElementsByTagNameNS("*", name));
  }
  function kids(el, name) {
    return Array.prototype.filter.call(el.children, function (c) { return c.localName === name; });
  }
  function textOf(el) { return el ? (el.textContent || "").trim() : ""; }

  /* FB2 writes xlink:href, but the prefix it binds varies between producers. */
  function hrefOf(el) {
    return el.getAttributeNS(XLINK, "href") || el.getAttribute("xlink:href") ||
           el.getAttribute("l:href") || el.getAttribute("href") || "";
  }

  function fail(message) {
    if (statusEl && statusEl.parentNode) statusEl.textContent = message;
  }

  /* Books predate UTF-8 ubiquity — FictionBook especially — so honour a
   * declared encoding when there is one. */
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
    try { window.webkit.messageHandlers.dcbook.postMessage(msg); } catch (e) {}
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
    post({ t: "font", k: CFG.token, v: state.fontSize });
  }

  /* ---------- sanitising (EPUB) ---------- */

  /* Only in-book (x-book:), data: and fragment URIs survive. Anything remote is
   * stripped, which is what keeps "no network at view time" structurally true. */
  var URI_OK = /^(?:x-book:|#|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i;
  var PURIFY = {
    USE_PROFILES: { html: true, svg: true, svgFilters: true, mathMl: true },
    ALLOWED_URI_REGEXP: URI_OK,
    ADD_ATTR: ["colspan", "rowspan", "start", "reversed", "type"],
    /* DOMPurify keeps <style> by default, and a chapter's in-body stylesheet
     * would then apply to the whole document — including the reader's own bar
     * and sidebar. Publisher CSS only ever reaches the page through
     * injectPublisherCSS, which scopes it. */
    FORBID_TAGS: ["style"]
  };

  /* Rewrite every reference in a chapter to an absolute in-book URL, so the
   * whole spine can live in one document without a per-chapter <base>. */
  function resolveReferences(root, chapterURL) {
    var attrs = ["src", "poster", "data", "longdesc"];
    Array.prototype.forEach.call(root.querySelectorAll("*"), function (el) {
      attrs.forEach(function (a) {
        if (!el.hasAttribute(a)) return;
        var u = abs(el.getAttribute(a), chapterURL);
        if (u && usableResource(u)) el.setAttribute(a, u); else el.removeAttribute(a);
      });
      if (el.hasAttributeNS(XLINK, "href")) {
        var xu = abs(el.getAttributeNS(XLINK, "href"), chapterURL);
        if (xu && usableResource(xu)) el.setAttributeNS(XLINK, "xlink:href", xu);
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

  /* ---------- publisher CSS (EPUB, opt-in) ---------- */

  var cssSeen = Object.create(null);

  /* Scope the book's own stylesheet to chapter content using the browser's CSS
   * parser (so @media nesting and @font-face survive intact) — otherwise a rule
   * on `body` would restyle the reader's own chrome. */
  function injectPublisherCSS(cssText, cssURL) {
    var withURLs = cssText.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi, function (m, q, u) {
      if (/^(data:|x-book:)/i.test(u)) return m;
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

  /* ================= EPUB model ================= */

  function loadEpub() {
    return fetchText(CFG.base + "META-INF/container.xml").then(function (text) {
      var doc = parseXML(text);
      var rootfile = doc && tags(doc, "rootfile")[0];
      var full = rootfile && rootfile.getAttribute("full-path");
      if (!full) throw new Error("container.xml names no package document");
      var opfURL = abs(full, CFG.base);
      return fetchText(opfURL).then(function (opfText) {
        var opf = parseXML(opfText) || parseDocument(opfText);
        if (!opf) throw new Error("the package document (OPF) is not valid XML");
        var book = buildEpubBook(opf, opfURL);
        return loadEpubTOC(book).then(function (toc) {
          book.toc = toc;
          return book;
        });
      });
    });
  }

  function buildEpubBook(opf, opfURL) {
    var book = { format: "epub", items: {}, spine: [], meta: {}, cover: null,
                 tocSource: null, toc: [] };

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
      if (ncxId && book.items[ncxId]) book.tocSource = { url: book.items[ncxId].url, kind: "ncx" };
    }

    /* EPUB 3's nav document supersedes the NCX when both are present. */
    for (var id in book.items) {
      if (/\bnav\b/.test(book.items[id].props)) {
        book.tocSource = { url: book.items[id].url, kind: "nav" };
        break;
      }
    }

    book.cover = findEpubCover(opf, book);
    return book;
  }

  function findEpubCover(opf, book) {
    var id;
    for (id in book.items) {
      if (/\bcover-image\b/.test(book.items[id].props)) return book.items[id].url;
    }
    var metaCover = tags(opf, "meta").filter(function (m) {
      return (m.getAttribute("name") || "").toLowerCase() === "cover";
    })[0];
    var ref = metaCover && book.items[metaCover.getAttribute("content")];
    if (ref && /^image\//.test(ref.type)) return ref.url;
    for (id in book.items) {
      if (/^image\//.test(book.items[id].type) && /cover/i.test(id)) return book.items[id].url;
    }
    return null;
  }

  function loadEpubTOC(book) {
    if (!book.tocSource) return Promise.resolve([]);
    var src = book.tocSource;
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
          var u = href ? abs(href, navURL) : null;
          out.push({
            label: textOf(a), depth: depth,
            key: u ? stripFragment(u) : null,
            frag: u ? fragmentOf(u) : ""
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
        var content = tags(pt, "content")[0];
        var src = content && content.getAttribute("src");
        var u = src ? abs(src, ncxURL) : null;
        out.push({
          label: textOf(tags(pt, "text")[0]), depth: depth,
          key: u ? stripFragment(u) : null,
          frag: u ? fragmentOf(u) : ""
        });
        walk(pt, depth + 1);
      });
    })(map, 0);
    return out;
  }

  function addEpubChapter(item, index) {
    var key = stripFragment(item.url);
    return fetchText(item.url).then(function (text) {
      var doc = parseDocument(text);
      var body = doc.body || tags(doc, "body")[0] || doc.documentElement;
      return collectPublisherCSS(doc, item.url).then(function () {
        resolveReferences(body, item.url);
        var section = newChapter(key, index);
        section.innerHTML = DOMPurify.sanitize(body.innerHTML, PURIFY);
        return appendChapter(section, key);
      });
    }).catch(function () {
      /* One unreadable chapter must not end the book. */
      var section = newChapter(key, index);
      var p = document.createElement("p");
      p.className = "read-error";
      p.textContent = "[ this section could not be read ]";
      section.appendChild(p);
      return appendChapter(section, key);
    });
  }

  /* ================= FB2 model ================= */

  /*
   * FictionBook elements are mapped one at a time onto a fixed HTML vocabulary.
   * Nothing from the file is ever handed to an HTML parser — only text nodes
   * cross over — so a hostile FB2 has no markup surface to attack through.
   */
  var FB2_INLINE = {
    strong: "strong", emphasis: "em", strikethrough: "s",
    sub: "sub", sup: "sup", code: "code", style: "span"
  };
  var FB2_BLOCK = {
    p: "p", subtitle: "h4", "text-author": "p", cite: "blockquote",
    epigraph: "blockquote", poem: "div", stanza: "div", v: "div",
    annotation: "div", date: "p",
    table: "table", tr: "tr", td: "td", th: "th"
  };
  var FB2_CLASS = {
    "text-author": "text-author", cite: "cite", epigraph: "epigraph",
    poem: "poem", stanza: "stanza", v: "verse", annotation: "annotation",
    date: "date"
  };

  function loadFB2() {
    return fetchText(CFG.reader + "document.fb2").then(function (text) {
      var doc = parseXML(text) || parseDocument(text);
      if (!doc || !doc.documentElement) throw new Error("this FictionBook file is not valid XML");
      return buildFB2Book(doc);
    });
  }

  function buildFB2Book(doc) {
    var book = { format: "fb2", meta: {}, cover: null, toc: [], parts: [], binaries: {} };

    /* Images live in the file as base64 <binary> elements. */
    tags(doc, "binary").forEach(function (b) {
      var id = b.getAttribute("id");
      if (!id) return;
      var type = b.getAttribute("content-type") || "image/jpeg";
      var data = (b.textContent || "").replace(/\s+/g, "");
      if (data) book.binaries[id] = "data:" + type + ";base64," + data;
    });

    var titleInfo = tags(doc, "title-info")[0];
    if (titleInfo) {
      book.meta.title = textOf(kids(titleInfo, "book-title")[0]);
      book.meta.author = kids(titleInfo, "author").map(function (a) {
        return ["first-name", "middle-name", "last-name", "nickname"]
          .map(function (n) { return textOf(kids(a, n)[0]); })
          .filter(Boolean).join(" ");
      }).filter(Boolean).join(", ");
      var coverImg = tags(kids(titleInfo, "coverpage")[0] || document.createElement("x"), "image")[0];
      if (coverImg) book.cover = binaryFor(book, hrefOf(coverImg));
    }

    /* The unnamed body is the book; named ones are notes and footnote targets. */
    var bodies = tags(doc, "body");
    var main = bodies.filter(function (b) { return !b.getAttribute("name"); })[0] || bodies[0];
    var extras = bodies.filter(function (b) { return b !== main; });

    if (main) collectFB2Parts(book, main, false);
    extras.forEach(function (b) { collectFB2Parts(book, b, true); });

    return book;
  }

  function binaryFor(book, href) {
    return book.binaries[String(href).replace(/^#/, "")] || null;
  }

  /* Top-level sections become chapters, so a long book still arrives in pieces.
   * Anything before the first section (a title page, an epigraph) becomes a
   * chapter of its own. */
  function collectFB2Parts(book, body, isNotes) {
    var sections = kids(body, "section");
    var front = Array.prototype.filter.call(body.children, function (c) {
      return c.localName !== "section";
    });
    if (front.length) {
      book.parts.push({ nodes: front, notes: isNotes, title: null });
    }
    sections.forEach(function (s) {
      book.parts.push({ nodes: [s], notes: isNotes, title: fb2SectionTitle(s) });
    });
  }

  function fb2SectionTitle(section) {
    var t = kids(section, "title")[0];
    return t ? textOf(t).replace(/\s+/g, " ") : null;
  }

  /* Plenty of FB2 in the wild — anything produced by a converter, for one —
   * has sections but no <title> elements at all. Falling back to the section's
   * opening line gives those books a usable table of contents instead of none. */
  function fb2SectionLabel(section) {
    var title = fb2SectionTitle(section);
    if (title) return title;
    var first = kids(section, "subtitle")[0] || kids(section, "p")[0];
    var text = textOf(first).replace(/\s+/g, " ");
    if (text.length < 2) return null;
    return text.length > 70 ? text.slice(0, 69).trimEnd() + "…" : text;
  }

  /* Contents: every titled section at its nesting depth, plus the title a body
   * carries directly — which is how the notes body announces itself. */
  function buildFB2TOC(book) {
    var out = [];
    book.parts.forEach(function (part, index) {
      var key = "p" + index;
      part.nodes.forEach(function (node) {
        if (node.localName === "title") {
          var label = textOf(node).replace(/\s+/g, " ");
          if (label) out.push({ label: label, depth: 0, key: key, frag: "" });
          return;
        }
        if (node.localName !== "section") return;
        (function walk(section, depth, path) {
          var label = fb2SectionLabel(section);
          if (label) out.push({ label: label, depth: depth, key: key, frag: path });
          kids(section, "section").forEach(function (child, i) {
            walk(child, depth + 1, path + "-" + i);
          });
        })(node, 0, "s" + index);
      });
    });
    return out;
  }

  function addFB2Chapter(book, part, index) {
    var key = "p" + index;
    var section = newChapter(key, index);
    if (part.notes) section.classList.add("notes");

    var pathIndex = 0;
    part.nodes.forEach(function (node) {
      if (node.localName === "section") {
        section.appendChild(fb2Section(book, node, 0, "s" + index));
        pathIndex++;
      } else {
        var el = fb2Node(book, node, 0);
        if (el) section.appendChild(el);
      }
    });
    return Promise.resolve(appendChapter(section, key));
  }

  function fb2Section(book, node, depth, path) {
    var wrap = document.createElement("section");
    wrap.className = "fb2-section";
    wrap.id = path;
    if (node.getAttribute("id")) {
      /* Note targets keep their identity, prefixed so a book can never collide
       * with the reader's own element ids. */
      var anchor = document.createElement("span");
      anchor.id = "fb-" + node.getAttribute("id");
      anchor.className = "anchor";
      wrap.appendChild(anchor);
    }
    var childIndex = 0;
    Array.prototype.forEach.call(node.children, function (child) {
      if (child.localName === "section") {
        wrap.appendChild(fb2Section(book, child, depth + 1, path + "-" + childIndex));
        childIndex++;
      } else {
        var el = fb2Node(book, child, depth);
        if (el) wrap.appendChild(el);
      }
    });
    return wrap;
  }

  function fb2Node(book, node, depth) {
    if (node.nodeType === 3) return document.createTextNode(node.nodeValue);
    if (node.nodeType !== 1) return null;

    var name = node.localName;

    if (name === "empty-line") return document.createElement("br");

    if (name === "image") {
      var src = binaryFor(book, hrefOf(node));
      if (!src) return null;
      var img = document.createElement("img");
      img.src = src;
      img.alt = node.getAttribute("alt") || "";
      return img;
    }

    if (name === "title") {
      var level = Math.min(6, depth + 1);
      var h = document.createElement("h" + level);
      var lines = [];
      Array.prototype.forEach.call(node.children, function (line) {
        if (line.localName === "empty-line") return;
        lines.push(textOf(line));
      });
      h.textContent = lines.filter(Boolean).join(" · ") || textOf(node);
      return h;
    }

    if (name === "a") {
      var a = document.createElement("a");
      var target = hrefOf(node).replace(/^#/, "");
      if (target) {
        a.setAttribute("href", "#fb-" + target);
        a.setAttribute("data-anchor", "fb-" + target);
      }
      if ((node.getAttribute("type") || "").toLowerCase() === "note") a.className = "note-ref";
      appendFB2Children(book, node, a, depth);
      return a;
    }

    var tag = FB2_INLINE[name] || FB2_BLOCK[name];
    if (!tag) {
      /* Unknown wrapper (or <body>/<section> content we don't model): keep the
       * children, drop the element. */
      var frag = document.createDocumentFragment();
      appendFB2Children(book, node, frag, depth);
      return frag.childNodes.length ? frag : null;
    }

    var el = document.createElement(tag);
    if (FB2_CLASS[name]) el.className = FB2_CLASS[name];
    if (node.getAttribute("id")) el.id = "fb-" + node.getAttribute("id");
    appendFB2Children(book, node, el, depth);
    return el;
  }

  function appendFB2Children(book, node, into, depth) {
    Array.prototype.forEach.call(node.childNodes, function (child) {
      var el = fb2Node(book, child, depth);
      if (el) into.appendChild(el);
    });
  }

  /* ================= shared rendering ================= */

  function newChapter(key, index) {
    var section = document.createElement("section");
    section.className = "chapter";
    section.setAttribute("data-key", key);
    section.id = "ch" + index;
    return section;
  }

  function appendChapter(section, key) {
    bookEl.appendChild(section);
    state.chapters.push({ key: key, section: section });
    return section;
  }

  /* Most books open on a cover page that already shows the cover art, so the
   * plate is only added when the first section doesn't display it — otherwise
   * the reader would show the same image twice. */
  function maybeRenderCover(book, firstSection) {
    if (!book.cover) return;
    var shown = Array.prototype.some.call(
      firstSection.querySelectorAll("img, image"),
      function (el) {
        return el.getAttribute("src") === book.cover ||
               el.getAttributeNS(XLINK, "href") === book.cover;
      });
    if (shown) return;

    var wrap = document.createElement("div");
    wrap.id = "cover";
    var img = document.createElement("img");
    img.src = book.cover;
    img.alt = book.meta.title || "Cover";
    img.addEventListener("error", function () { wrap.remove(); });
    wrap.appendChild(img);
    bookEl.insertBefore(wrap, bookEl.firstChild);
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
      a.href = "#";
      a.addEventListener("click", function (ev) {
        ev.preventDefault();
        if (!goTo(e.key, e.frag)) {
          a.classList.add("dead");
          a.title = "This section is not in the book file.";
          return;
        }
        if (window.innerWidth <= 900) setTOC(false);
      });
      li.appendChild(a);
      frag.appendChild(li);
      state.tocLinks.push({ entry: e, el: a });
    });
    tocList.appendChild(frag);
  }

  /* ---------- navigation ---------- */

  function findTarget(key, frag) {
    if (frag) {
      /* An id may live in any loaded chapter (FB2 notes, EPUB cross-links). */
      var scoped = null;
      for (var i = 0; i < state.chapters.length; i++) {
        var c = state.chapters[i];
        if (key && c.key !== key) continue;
        scoped = c.section.querySelector('[id="' + CSS.escape(frag) + '"]') ||
                 c.section.querySelector('[name="' + CSS.escape(frag) + '"]');
        if (scoped) return scoped;
      }
      var anywhere = bookEl.querySelector('[id="' + CSS.escape(frag) + '"]');
      if (anywhere) return anywhere;
    }
    if (!key) return null;
    for (var j = 0; j < state.chapters.length; j++) {
      if (state.chapters[j].key === key) return state.chapters[j].section;
    }
    return null;
  }

  function goTo(key, frag) {
    var el = findTarget(key, frag);
    if (el) {
      state.userScrolled = true;
      scrollToElement(el);
      state.pending = null;
      return true;
    }
    /* Once the whole book is in, a target that still isn't there does not
     * exist — say so rather than queueing a jump that can never happen. */
    if (state.loaded) return false;
    state.pending = { key: key, frag: frag };
    return true;
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
      /* Not before the remembered position has been applied: during the
       * incremental load the page still sits at the top, and posting from
       * there would overwrite where the reader actually left off. */
      if (state.restored || state.userScrolled) {
        post({ t: "pos", k: CFG.token, i: i, r: r });
      }
      highlightTOC(c.key);
    }
  }

  var lastHighlight = null;
  function highlightTOC(key) {
    if (key === lastHighlight) return;
    lastHighlight = key;
    var best = null;
    state.tocLinks.forEach(function (l) {
      l.el.classList.remove("current");
      if (l.entry.key === key && !best) best = l;
    });
    if (best) best.el.classList.add("current");
  }

  function restorePosition() {
    var pos = CFG.position || {};
    /* Only a genuinely remembered position moves the page — otherwise opening a
     * book would scroll past its own cover. */
    if (!("i" in pos) && !("r" in pos)) { state.restored = true; return; }
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

    /* In-book links (EPUB cross-references, FB2 footnotes) jump within the
     * single scrolling document. */
    bookEl.addEventListener("click", function (ev) {
      var a = ev.target.closest && ev.target.closest("a[data-link], a[data-anchor]");
      if (!a) return;
      ev.preventDefault();
      if (a.hasAttribute("data-anchor")) {
        goTo(null, a.getAttribute("data-anchor"));
      } else {
        var href = a.getAttribute("href");
        goTo(stripFragment(href), fragmentOf(href));
      }
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
      v.textContent = "BookView v" + CFG.version;
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

  var isFB2 = CFG.format === "fb2";

  (isFB2 ? loadFB2() : loadEpub()).then(function (book) {
    wireChrome(book);

    var units = isFB2 ? book.parts : book.spine;
    if (!units.length) throw new Error("this book contains no readable sections");

    statusEl.remove();
    renderTOC(isFB2 ? buildFB2TOC(book) : book.toc);

    /* Chapters are appended one at a time so the first page is readable while
     * the rest of the book is still arriving. */
    var chain = Promise.resolve();
    units.forEach(function (unit, i) {
      chain = chain.then(function () {
        var step = isFB2 ? addFB2Chapter(book, unit, i) : addEpubChapter(unit, i);
        return step.then(function (section) {
          if (i === 0) maybeRenderCover(book, section);
          if (state.pending) {
            var el = findTarget(state.pending.key, state.pending.frag);
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
      state.loaded = true;
      addColophon(book);
      restorePosition();
      /* A jump queued while the book was still arriving gets one last chance;
       * if its target never appeared, drop it so later clicks still work. */
      if (state.pending) {
        var el = findTarget(state.pending.key, state.pending.frag);
        if (el) scrollToElement(el);
        state.pending = null;
      }
      onScroll();
    });
  }).catch(function (err) {
    fail("This book could not be opened — " + (err && err.message ? err.message : err) + ".");
  });
})();
