// In-Page-Übersetzung (Apples Übersetzung, BrowserPageTranslation in BrowserAppleTranslator.m).
// Läuft in einer eigenen WKContentWorld ("BrowserTranslation"): Seitenskripte sehen window.__btr nicht.
//
// Ablauf: start() sucht sichtbaren Text und gruppiert Textknoten zu Absätzen (nächster Block-Vorfahr, Inline-
// Elemente wie Links bleiben Teil des Absatzes). Ein IntersectionObserver reiht Absätze ein, sobald sie in die
// Nähe des sichtbaren Bereichs kommen; ein MutationObserver nimmt nachgeladene oder geänderte Inhalte mit.
// Die App holt mit take() Absätze ab ([{i, p:[[knotenId, text], …]}]), übersetzt sie (je Textknoten ein Bereich)
// und gibt mit apply() die Texte je Knoten zurück. restore() setzt alle Originaltexte zurück (ohne Neuladen).
(function () {
  'use strict';
  if (window.__btr) {
    return;
  }
  var HTML_NS = 'http://www.w3.org/1999/xhtml';
  var SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'INPUT', 'SELECT', 'OPTION', 'CODE', 'PRE',
    'KBD', 'SAMP', 'VAR', 'CANVAS', 'IFRAME', 'OBJECT', 'EMBED', 'VIDEO', 'AUDIO', 'TEMPLATE', 'HEAD', 'TITLE']);
  var INLINE_TAGS = new Set(['A', 'ABBR', 'B', 'BDI', 'BDO', 'BIG', 'BR', 'CITE', 'DATA', 'DEL', 'DFN', 'EM', 'FONT',
    'I', 'IMG', 'INS', 'LABEL', 'MARK', 'NOBR', 'Q', 'S', 'SMALL', 'SPAN', 'STRIKE', 'STRONG', 'SUB', 'SUP', 'TIME',
    'TT', 'U', 'WBR']);
  var LETTER = /\p{L}/u;
  var WORD_END = /[\p{L}\p{N}]$/u;
  var WORD_START = /^[\p{L}\p{N}]/u;
  var MAX_PARAGRAPH_CHARS = 5000;
  var MAX_PARTS = 300;

  var S = null;

  function selfSkipped(el) {
    if (el.namespaceURI !== HTML_NS || SKIP_TAGS.has(el.tagName)) {
      return true;
    }
    if (el.getAttribute('translate') === 'no' || (el.classList && el.classList.contains('notranslate'))) {
      return true;
    }
    if (el.isContentEditable && (!el.parentElement || !el.parentElement.isContentEditable)) {
      return true; // Eingabefelder (Editoren) nicht anfassen
    }
    return false;
  }

  // Liegt el (oder ein Vorfahr) in einem nicht zu übersetzenden Bereich? Ergebnis je Element zwischengespeichert.
  function skipped(el) {
    var path = [];
    var result;
    while (el && el.nodeType === 1) {
      if (S.skipCache.has(el)) {
        result = S.skipCache.get(el);
        break;
      }
      path.push(el);
      if (selfSkipped(el)) {
        result = true;
        break;
      }
      el = el.parentElement;
    }
    if (result === undefined) {
      result = false;
    }
    for (var i = 0; i < path.length; i++) {
      S.skipCache.set(path[i], result);
    }
    return result;
  }

  function blockOf(el) {
    while (el && el !== document.body && INLINE_TAGS.has(el.tagName)) {
      el = el.parentElement;
    }
    return el || document.body;
  }

  function entryFor(block) {
    var entry = S.blocks.get(block);
    if (!entry) {
      entry = { id: 'b' + (++S.seq), el: block, st: 0, vis: false };
      S.blocks.set(block, entry);
      S.byId.set(entry.id, entry);
      S.io.observe(block);
    }
    return entry;
  }

  // Absatz (neu) einreihen: sichtbar oder nahe dran sofort, sonst beim nächsten IntersectionObserver-Treffer.
  function requeue(entry) {
    if (entry.st === 1) {
      return;
    }
    entry.st = 0;
    if (entry.vis) {
      entry.st = 1;
      S.queue.push(entry);
    }
  }

  function noteTextNode(node) {
    var parent = node.parentElement;
    if (!parent || !LETTER.test(node.data) || skipped(parent)) {
      return null;
    }
    return entryFor(blockOf(parent));
  }

  function scan(root) {
    if (root.nodeType === 3) {
      var single = noteTextNode(root);
      if (single && single.st === 3) {
        requeue(single);
      }
      return;
    }
    if (root.nodeType !== 1 || skipped(root)) {
      return;
    }
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        if (n.nodeType === 1) {
          return selfSkipped(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
        }
        return LETTER.test(n.data) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
      }
    });
    var node;
    while ((node = walker.nextNode())) {
      var parent = node.parentElement;
      if (!parent) {
        continue;
      }
      var entry = entryFor(blockOf(parent));
      if (entry.st === 3) {
        requeue(entry); // neuer Text in einem schon übersetzten Absatz
      }
    }
  }

  // Textknoten eines Absatzes in Dokumentreihenfolge, ohne verschachtelte Blöcke (die sind eigene Absätze).
  function partsOf(block) {
    var out = [];
    var walker = document.createTreeWalker(block, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        if (n.nodeType === 1) {
          return (!INLINE_TAGS.has(n.tagName) || selfSkipped(n)) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var node;
    while ((node = walker.nextNode())) {
      out.push(node);
    }
    return out;
  }

  function nodeId(node) {
    var id = S.nodeIds.get(node);
    if (!id) {
      id = 'n' + (++S.seq);
      S.nodeIds.set(node, id);
      S.nodes.set(id, node);
    }
    return id;
  }

  function originalOf(node) {
    return S.orig.has(node) ? S.orig.get(node) : node.data;
  }

  function onIntersect(entries) {
    for (var i = 0; i < entries.length; i++) {
      var entry = S.blocks.get(entries[i].target);
      if (!entry) {
        continue;
      }
      entry.vis = entries[i].isIntersecting;
      if (entry.vis && entry.st === 0) {
        entry.st = 1;
        S.queue.push(entry);
      }
    }
  }

  function flushMutations() {
    S.mutationTimer = 0;
    var pending = S.pendingNodes;
    S.pendingNodes = [];
    for (var i = 0; i < pending.length; i++) {
      if (pending[i].isConnected) {
        scan(pending[i]);
      }
    }
  }

  function onMutations(records) {
    for (var i = 0; i < records.length; i++) {
      var record = records[i];
      if (record.type === 'characterData') {
        var node = record.target;
        if (S.written.has(node)) {
          if (S.written.get(node) === node.data) {
            continue; // unsere eigene Änderung
          }
          // Die Seite hat den Text selbst geändert: neues Original, Absatz neu übersetzen.
          S.written.delete(node);
          S.orig.delete(node);
        }
        S.pendingNodes.push(node);
      } else {
        for (var j = 0; j < record.addedNodes.length; j++) {
          S.pendingNodes.push(record.addedNodes[j]);
        }
      }
    }
    if (S.pendingNodes.length > 0 && !S.mutationTimer) {
      S.mutationTimer = setTimeout(flushMutations, 250);
    }
  }

  window.__btr = {
    // options.spaces: Zielsprache trennt Wörter mit Leerzeichen (nicht bei Chinesisch, Japanisch, Thai …).
    start: function (options) {
      if (S) {
        return this.state();
      }
      S = {
        blocks: new Map(), byId: new Map(), nodes: new Map(), nodeIds: new WeakMap(), orig: new Map(),
        written: new Map(), skipCache: new WeakMap(), queue: [], seq: 0, done: 0, failed: 0, sent: 0,
        pendingNodes: [], mutationTimer: 0, title: null, started: Date.now(),
        spaces: !options || options.spaces !== false
      };
      S.io = new IntersectionObserver(onIntersect, { rootMargin: '1200px 0px 1200px 0px' });
      S.mo = new MutationObserver(onMutations);
      if (document.body) {
        scan(document.body);
        S.mo.observe(document.body, { childList: true, subtree: true, characterData: true });
      }
      if (document.title && LETTER.test(document.title)) {
        S.title = document.title;
        var titleEntry = { id: 'title', st: 1, vis: true, isTitle: true };
        S.byId.set('title', titleEntry);
        S.queue.unshift(titleEntry);
      }
      return this.state();
    },

    // Bis zu max Absätze bzw. maxChars Zeichen abholen. null = keine Übersetzung aktiv.
    take: function (max, maxChars) {
      if (!S) {
        return null;
      }
      var out = [];
      var chars = 0;
      while (S.queue.length > 0 && out.length < max && chars < maxChars) {
        var entry = S.queue.shift();
        if (entry.st !== 1) {
          continue;
        }
        if (entry.isTitle) {
          entry.st = 2;
          out.push({ i: entry.id, p: [['t', S.title]] });
          chars += S.title.length;
          continue;
        }
        if (!entry.el.isConnected) {
          entry.st = 3;
          continue;
        }
        var nodes = partsOf(entry.el);
        var parts = [];
        var length = 0;
        var letters = false;
        for (var i = 0; i < nodes.length; i++) {
          var text = originalOf(nodes[i]).replace(/\s+/g, ' ');
          if (text.length === 0) {
            continue;
          }
          parts.push([nodeId(nodes[i]), text]);
          length += text.length;
          letters = letters || LETTER.test(text);
        }
        if (!letters || length > MAX_PARAGRAPH_CHARS || parts.length > MAX_PARTS) {
          entry.st = 3; // nichts zu übersetzen oder zu groß
          continue;
        }
        entry.st = 2;
        S.sent++;
        out.push({ i: entry.id, p: parts });
        chars += length;
      }
      return out;
    },

    // results: [{i: absatzId, t: [[knotenId, text], …]}] oder [{i, f: 1}] (fehlgeschlagen).
    apply: function (results) {
      if (!S) {
        return 0;
      }
      var applied = 0;
      for (var r = 0; r < results.length; r++) {
        var result = results[r];
        var entry = S.byId.get(result.i);
        if (!entry || entry.st !== 2) {
          continue; // inzwischen neu eingereiht (Seite hat geändert): späteres Ergebnis zählt
        }
        entry.st = 3;
        if (result.f || !result.t) {
          S.failed++;
          continue;
        }
        if (entry.isTitle) {
          if (result.t.length > 0 && result.t[0][1]) {
            document.title = String(result.t[0][1]).trim();
          }
          S.done++;
          continue;
        }
        // result.t: [[knotenId, text], …] in Seitenreihenfolge. Leerraum am Rand kommt vom Original (Layout bleibt);
        // stellt die Übersetzung Wörter so um, dass zwei Wörter ohne Leerzeichen aneinanderstoßen, wo im Original
        // eine Grenze war (Link „Brutzeit“ + „ziehen …“), kommt ein Leerzeichen dazu.
        var previousValue = '';
        var previousOriginal = '';
        for (var k = 0; k < result.t.length; k++) {
          var id = result.t[k][0];
          var node = S.nodes.get(id);
          if (!node || !node.isConnected) {
            continue;
          }
          var original = originalOf(node);
          if (!S.orig.has(node)) {
            S.orig.set(node, original);
          }
          var text = String(result.t[k][1]);
          var lead = original.match(/^\s*/)[0];
          var trail = lead.length === original.length ? '' : original.match(/\s*$/)[0];
          var core = text.trim();
          if (!lead && /^\s/.test(text)) {
            lead = ' ';
          }
          if (!trail && /\S\s+$/.test(text)) {
            trail = ' ';
          }
          var value = core ? lead + core + trail : original.replace(/\S+/g, '').replace(/\s+/g, ' ');
          if (S.spaces && core && !lead && WORD_END.test(previousValue) && WORD_START.test(value) &&
              !(WORD_END.test(previousOriginal) && WORD_START.test(original))) {
            value = ' ' + value;
          }
          if (node.data !== value) {
            node.data = value;
          }
          S.written.set(node, value);
          previousValue = value;
          previousOriginal = original;
        }
        S.done++;
        applied++;
      }
      return applied;
    },

    restore: function () {
      if (!S) {
        delete window.__btr;
        return 0;
      }
      S.io.disconnect();
      S.mo.disconnect();
      if (S.mutationTimer) {
        clearTimeout(S.mutationTimer);
      }
      var restored = 0;
      S.orig.forEach(function (original, node) {
        if (S.written.get(node) === node.data) {
          node.data = original;
          restored++;
        }
      });
      if (S.title !== null) {
        document.title = S.title;
      }
      S = null;
      delete window.__btr;
      return restored;
    },

    state: function () {
      if (!S) {
        return null;
      }
      return { n: S.blocks.size, q: S.queue.length, s: S.sent, d: S.done, f: S.failed, ms: Date.now() - S.started };
    }
  };
})();
