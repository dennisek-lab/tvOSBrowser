// Eigener Teil des Reader-Modus (nicht von Mozilla). Läuft im Seitenkontext, NACH Readability.js und
// Readability-readerable.js (BrowserReaderMode.m setzt die drei Dateien zusammen und stellt
// window.__browserReaderViewWidth voran, die Breite der Ansicht in Punkten).
//
// Ansatz: Overlay im selben Dokument statt neuer Seite. Der Artikel wird als <div id="__reader"> in den Body
// gesetzt, die übrigen Kinder des Body werden per CSS ausgeblendet. Die Seite selbst scrollt (nativ, wie sonst),
// beim Beenden ist die Originalseite samt Scrollstand sofort wieder da, ohne Neuladen und ohne Verlaufseintrag.
(function () {
  if (window.__browserReader) { return; }

  var state = { active: false, savedY: 0, savedTitle: null };

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) { e.className = cls; }
    if (text) { e.textContent = text; }
    return e;
  }

  function unit() {
    var vw = window.__browserReaderViewWidth || 1920;
    return Math.max(0.2, window.innerWidth / vw); // CSS-Pixel je Punkt
  }

  function css(u) {
    function p(n) { return (n * u).toFixed(2) + 'px'; }
    return [
      'html.__rd{overflow:visible!important;height:auto!important;min-height:0!important;scroll-behavior:auto!important;background:var(--rd-bg)!important;}',
      'html.__rd>body{display:block!important;position:static!important;overflow:visible!important;height:auto!important;min-height:0!important;',
      'margin:0!important;padding:0!important;border:0!important;transform:none!important;background:transparent!important;}',
      'html.__rd>body>*:not(#__reader){display:none!important;}',
      '#__reader{all:initial;display:block;position:relative;box-sizing:border-box;width:100%;min-height:100vh;',
      '--rd-bg:#fbfaf6;--rd-fg:#1d1d1f;--rd-dim:#6e6e73;--rd-link:#0a5bd3;--rd-rule:rgba(0,0,0,.14);--rd-quote:rgba(0,0,0,.05);',
      'background:var(--rd-bg);color:var(--rd-fg);padding:' + p(150) + ' ' + p(80) + ' ' + p(160) + ';',
      'font:400 ' + p(36) + '/1.6 -apple-system,system-ui,sans-serif;-webkit-text-size-adjust:none;text-align:start;}',
      '#__reader *{box-sizing:border-box;}',
      '#__reader .rd-col{display:block;max-width:' + p(1280) + ';margin:0 auto;}',
      '#__reader .rd-site{display:block;font:600 ' + p(26) + '/1.3 -apple-system,system-ui,sans-serif;letter-spacing:.06em;text-transform:uppercase;color:var(--rd-dim);margin:0 0 ' + p(26) + ';}',
      '#__reader h1.rd-title{display:block;border:0;padding:0;background:none;font:700 ' + p(68) + '/1.15 -apple-system,system-ui,sans-serif;letter-spacing:-.01em;margin:0 0 ' + p(28) + ';color:var(--rd-fg);}',
      '#__reader .rd-meta{display:block;font:500 ' + p(28) + '/1.4 -apple-system,system-ui,sans-serif;color:var(--rd-dim);margin:0 0 ' + p(54) + ';padding-bottom:' + p(40) + ';border-bottom:' + p(2) + ' solid var(--rd-rule);}',
      '#__reader .rd-body{display:block;}',
      '#__reader .rd-body p,#__reader .rd-body li,#__reader .rd-body dd{font:inherit;color:var(--rd-fg);line-height:1.6;margin:0 0 ' + p(30) + ';text-align:start;}',
      '#__reader .rd-body div,#__reader .rd-body section,#__reader .rd-body article,#__reader .rd-body span{font:inherit;color:inherit;max-width:100%;}',
      '#__reader .rd-body *::first-letter,#__reader .rd-body *::first-line{font:inherit!important;float:none!important;margin:0!important;padding:0!important;color:inherit!important;initial-letter:normal!important;text-transform:none!important;}',
      '#__reader .rd-body *::before,#__reader .rd-body *::after{content:none!important;}',
      '#__reader .rd-body ul,#__reader .rd-body ol{margin:0 0 ' + p(30) + ';padding-left:' + p(56) + ';}',
      '#__reader .rd-body li{margin-bottom:' + p(14) + ';}',
      '#__reader .rd-body h1,#__reader .rd-body h2,#__reader .rd-body h3,#__reader .rd-body h4,#__reader .rd-body h5,#__reader .rd-body h6{',
      'border:0;padding:0;background:none;font-family:-apple-system,system-ui,sans-serif;font-weight:700;line-height:1.25;color:var(--rd-fg);margin:' + p(54) + ' 0 ' + p(22) + ';letter-spacing:-.005em;}',
      '#__reader .rd-body h1,#__reader .rd-body h2{font-size:' + p(50) + ';}',
      '#__reader .rd-body h3{font-size:' + p(42) + ';}',
      '#__reader .rd-body h4,#__reader .rd-body h5,#__reader .rd-body h6{font-size:' + p(36) + ';}',
      '#__reader .rd-body a{color:var(--rd-link);text-decoration:underline;text-underline-offset:.18em;text-decoration-thickness:.07em;}',
      '#__reader .rd-body img,#__reader .rd-body video,#__reader .rd-body svg,#__reader .rd-body canvas,#__reader .rd-body iframe{max-width:100%!important;height:auto!important;display:block;margin:' + p(40) + ' auto;border-radius:' + p(14) + ';}',
      '#__reader .rd-body figure{display:block;margin:' + p(40) + ' 0;}',
      '#__reader .rd-body figcaption{font:500 ' + p(26) + '/1.4 -apple-system,system-ui,sans-serif;color:var(--rd-dim);margin-top:' + p(14) + ';}',
      '#__reader .rd-body blockquote{display:block;margin:' + p(36) + ' 0;padding:' + p(14) + ' ' + p(34) + ';border-left:' + p(6) + ' solid var(--rd-rule);background:var(--rd-quote);border-radius:' + p(8) + ';}',
      '#__reader .rd-body blockquote p:last-child{margin-bottom:0;}',
      '#__reader .rd-body pre,#__reader .rd-body code{font:400 ' + p(28) + '/1.5 ui-monospace,Menlo,monospace;}',
      '#__reader .rd-body pre{display:block;overflow:auto;padding:' + p(26) + ';background:var(--rd-quote);border-radius:' + p(12) + ';margin:0 0 ' + p(30) + ';white-space:pre-wrap;}',
      '#__reader .rd-body table{display:block;max-width:100%;overflow:auto;border-collapse:collapse;font-size:' + p(28) + ';margin:0 0 ' + p(30) + ';}',
      '#__reader .rd-body td,#__reader .rd-body th{padding:' + p(10) + ' ' + p(18) + ';border:' + p(2) + ' solid var(--rd-rule);}',
      '#__reader .rd-body hr{border:0;border-top:' + p(2) + ' solid var(--rd-rule);margin:' + p(46) + ' 0;}',
      '#__reader .rd-foot{display:block;margin-top:' + p(70) + ';padding-top:' + p(34) + ';border-top:' + p(2) + ' solid var(--rd-rule);font:500 ' + p(26) + '/1.4 -apple-system,system-ui,sans-serif;color:var(--rd-dim);word-break:break-all;}',
      '#__reader .rd-foot a{color:var(--rd-link);text-decoration:none;}',
      '@media (prefers-color-scheme:dark){#__reader{--rd-bg:#161618;--rd-fg:#ebebed;--rd-dim:#9a9aa1;--rd-link:#6cb0ff;--rd-rule:rgba(255,255,255,.18);--rd-quote:rgba(255,255,255,.07);}}'
    ].join('');
  }

  function dateText(iso) {
    if (!iso) { return ''; }
    var d = new Date(iso);
    if (isNaN(d.getTime())) { return ''; }
    try { return d.toLocaleDateString(document.documentElement.lang || undefined, { year: 'numeric', month: 'long', day: 'numeric' }); } catch (e) { return ''; }
  }

  function sanitize(root) {
    var all = root.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var attrs = all[i].attributes;
      for (var j = attrs.length - 1; j >= 0; j--) {
        var n = attrs[j].name.toLowerCase();
        if (n === 'style' || n === 'data-browser-original-font-size') { all[i].removeAttribute(attrs[j].name); }
        else if (n.indexOf('on') === 0) { all[i].removeAttribute(attrs[j].name); }
        else if ((n === 'href' || n === 'src') && /^\s*javascript:/i.test(attrs[j].value)) { all[i].removeAttribute(attrs[j].name); }
      }
    }
    var fix = root.querySelectorAll('script,style,link,object,embed');
    for (var k = 0; k < fix.length; k++) { fix[k].remove(); }
  }

  function readable() {
    try {
      return !!isProbablyReaderable(document, { minContentLength: 400, minScore: 20 });
    } catch (e) { return false; }
  }

  function enter() {
    var article = null;
    try { article = new Readability(document.cloneNode(true), { charThreshold: 200 }).parse(); } catch (e) { article = null; }
    if (!article || !article.content) { return false; }

    var u = unit();
    state.savedY = window.pageYOffset || 0;
    state.savedTitle = null;

    var style = el('style');
    style.id = '__reader_style';
    style.textContent = css(u);

    var root = el('div');
    root.id = '__reader';
    if (article.lang) { root.setAttribute('lang', article.lang); }
    if (article.dir) { root.setAttribute('dir', article.dir); }
    var col = el('div', 'rd-col');
    var host = location.hostname.replace(/^www\./, '');
    col.appendChild(el('span', 'rd-site', article.siteName || host));
    col.appendChild(el('h1', 'rd-title', article.title || document.title || host));

    var words = (article.textContent || '').trim().split(/\s+/).length;
    var minutes = Math.max(1, Math.round(words / 200));
    var parts = [];
    if (article.byline) { parts.push(article.byline.replace(/\s+/g, ' ').trim()); }
    var when = dateText(article.publishedTime);
    if (when) { parts.push(when); }
    parts.push(host);
    parts.push(minutes + ' Min. Lesezeit');
    col.appendChild(el('span', 'rd-meta', parts.join('  ·  ')));

    var body = el('div', 'rd-body');
    body.innerHTML = article.content;
    sanitize(body);
    col.appendChild(body);

    var foot = el('div', 'rd-foot');
    foot.appendChild(document.createTextNode('Original: '));
    var a = el('a', null, location.href);
    a.href = location.href;
    foot.appendChild(a);
    col.appendChild(foot);
    root.appendChild(col);

    (document.head || document.documentElement).appendChild(style);
    document.body.appendChild(root);
    document.documentElement.classList.add('__rd');
    state.active = true;
    window.scrollTo(0, 0);
    if (window.__browserTargets && window.__browserTargets.report) { setTimeout(function () { window.__browserTargets.report(); }, 50); }
    return true;
  }

  function exit() {
    if (!state.active) { return; }
    state.active = false;
    var root = document.getElementById('__reader');
    if (root) { root.remove(); }
    var style = document.getElementById('__reader_style');
    if (style) { style.remove(); }
    document.documentElement.classList.remove('__rd');
    window.scrollTo(0, state.savedY);
    if (window.__browserTargets && window.__browserTargets.report) { setTimeout(function () { window.__browserTargets.report(); }, 50); }
  }

  // Reiner Artikeltext für Zusammenfassen/Übersetzen, ohne Overlay. Absätze durch Leerzeile getrennt,
  // Überschriften, Tabellen, Bildunterschriften und Fußnotenzeichen fehlen. Ohne Readability-Ergebnis:
  // Text aus <article>/<main>/<body> ohne Navigation. Rückgabe JSON {title, site, lang, source, text, total}.
  function articleText(max) {
    max = max > 0 ? max : 6000;
    var article = null;
    try { article = new Readability(document.cloneNode(true), { charThreshold: 200 }).parse(); } catch (e) { article = null; }
    var root = null;
    var source = 'reader';
    if (article && article.content) {
      // DOMParser: inertes Dokument, lädt keine Bilder und führt nichts aus.
      try { root = new DOMParser().parseFromString(article.content, 'text/html').body; } catch (e) { root = null; }
    }
    if (!root) {
      source = 'body';
      root = document.querySelector('article, main, [role=main]') || document.body;
    }
    var skip = 'nav, header, footer, aside, table, figure, figcaption, sup, style, script, noscript, form, button, #__reader .rd-meta, #__reader .rd-foot, #__reader .rd-site';
    var blocks = [];
    var total = 0;
    var nodes = root ? root.querySelectorAll('p, li, blockquote, dd') : [];
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      if (node.querySelector('p, li, blockquote')) { continue; }
      if (node.closest && node.closest(skip)) { continue; }
      var copy = node.cloneNode(true);
      var noise = copy.querySelectorAll('sup, style, script, .mw-editsection');
      for (var j = 0; j < noise.length; j++) { noise[j].remove(); }
      var text = (copy.textContent || '').replace(/\[\d+\]/g, '').replace(/\s+/g, ' ').trim();
      if (text.length < 2) { continue; }
      total += text.length;
      blocks.push(text);
    }
    if (blocks.length === 0 && root) {
      var fallback = (root.innerText || root.textContent || '').replace(/[ \t]+/g, ' ').trim();
      blocks = fallback.split(/\n{2,}|\n/).map(function (s) { return s.trim(); }).filter(function (s) { return s.length > 1; });
      total = fallback.length;
      source = source + '-raw';
    }
    var out = [];
    var used = 0;
    for (var k = 0; k < blocks.length && used < max; k++) {
      var b = blocks[k];
      if (used + b.length > max) { b = b.slice(0, max - used); }
      out.push(b);
      used += b.length + 2;
    }
    var host = location.hostname.replace(/^www\./, '');
    return JSON.stringify({
      title: (article && article.title) || document.title || host,
      site: (article && article.siteName) || host,
      lang: document.documentElement.lang || (article && article.lang) || '',
      source: source,
      text: out.join('\n\n'),
      total: total
    });
  }

  window.__browserReader = {
    // 'a' = Reader aktiv, 'y' = Seite lesbar, 'n' = nicht lesbar
    check: function () { return state.active ? 'a' : (readable() ? 'y' : 'n'); },
    text: function (max) { return articleText(max); },
    toggle: function () {
      if (state.active) { exit(); return this.check(); }
      return enter() ? 'a' : 'n';
    },
    exit: function () { exit(); return this.check(); }
  };
})();
