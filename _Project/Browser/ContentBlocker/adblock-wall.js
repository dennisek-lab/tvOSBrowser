// Erkennt „Bitte Werbeblocker ausschalten“-Sperren (Adblock-Wall) und meldet sie an die App (Handler browserAdblockWall).
// Läuft bei document-end in allen Frames. Prüft in den ersten ~15 s einige Male, danach Ende. Die App setzt dann für den
// Host der Hauptseite eine automatische Werbeblocker-Ausnahme und lädt einmal neu.
// Eng gefasst: Treffer nur in großen, sichtbaren, fixierten/modalen Containern, in ganzen CMP-iframes oder wenn die ganze
// Hauptseite fast nur aus der Sperre besteht, und nur bei Blocker-Wort UND Aufforderung (deaktivieren/disable/whitelist …).
(function () {
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserAdblockWall;
  if (!handler || window.__browserAdblockWall) { return; }
  window.__browserAdblockWall = true;
  var top = window.top === window;
  // Blocker-Wort: Adblocker, Ad-Blocker, Werbeblocker, „Ihres Blockers“, ad blocker/ad blocking …
  var BLOCKER = /(ad[\s­-]?block|werbe[\s­-]?block|anzeigen[\s­-]?block|\b(ihr|ihre|ihres|ihren|ihrem|dein|deine|deines|deinen|deinem|your)\s+(ad[\s-]?)?blocker|content[\s-]?blocker|blocker[\s-]?(erkannt|detected)|werbeblock)/i;
  // Aufforderung dazu: abschalten, Ausnahme/Whitelist, disable …
  var ACTION = /(deaktivier|ausschalt|abschalt|ausstellen|pausier|ausnahme|freischalt|zulassen|erlaub|whitelist|allow[\s-]?list|weiße liste|weisse liste|disable|turn (it )?off|switch (it )?off|pause (your|the)|add .{0,40}(exception|whitelist|allow)|allow (ads|us)|unblock)/i;
  var host = '';
  try {
    if (top) { host = location.hostname; }
    else if (location.ancestorOrigins && location.ancestorOrigins.length) { host = new URL(location.ancestorOrigins[location.ancestorOrigins.length - 1]).hostname; }
    else if (document.referrer) { host = new URL(document.referrer).hostname; }
  } catch (e) {}

  function matches(text) { return text && text.length < 4000 && BLOCKER.test(text) && ACTION.test(text); }
  function visible(el) {
    var r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) { return false; }
    var cs = getComputedStyle(el);
    return cs.display !== 'none' && cs.visibility !== 'hidden' && parseFloat(cs.opacity) > 0.1;
  }
  // Groß genug für ein Overlay: mindestens 35 % der Breite und 25 % der Höhe des Fensters.
  function bigEnough(el) {
    var r = el.getBoundingClientRect();
    return r.width >= innerWidth * 0.35 && r.height >= innerHeight * 0.25;
  }
  function modalContainers() {
    var out = [];
    var list = document.querySelectorAll('dialog[open], [role=dialog], [role=alertdialog], [aria-modal=true]');
    for (var i = 0; i < list.length; i++) { out.push(list[i]); }
    var all = document.body ? document.body.querySelectorAll('div, section, aside, article, form') : [];
    for (var j = 0; j < all.length; j++) {
      var el = all[j];
      var t = el.textContent;
      if (!t || t.length > 4000 || !BLOCKER.test(t)) { continue; }
      var pos = getComputedStyle(el).position;
      if (pos === 'fixed' || pos === 'sticky') { out.push(el); }
    }
    return out;
  }
  function headingMatches() {
    var hs = document.querySelectorAll('h1, h2, h3, [role=heading]');
    for (var i = 0; i < hs.length; i++) { if (BLOCKER.test(hs[i].textContent || '') && visible(hs[i])) { return true; } }
    return false;
  }
  function find() {
    if (!document.body) { return null; }
    var body = document.body.textContent || '';
    if (!BLOCKER.test(body) || !ACTION.test(body)) { return null; }
    if (!top) {
      // CMP-/Sperr-iframe: das ganze Dokument zählt, wenn der iframe groß genug ist.
      if (innerWidth >= 280 && innerHeight >= 180 && matches((document.body.innerText || '').trim())) {
        return (document.body.innerText || '').trim();
      }
      return null;
    }
    var cands = modalContainers();
    for (var i = 0; i < cands.length; i++) {
      var el = cands[i];
      if (visible(el) && bigEnough(el)) {
        var text = (el.innerText || '').trim();
        if (matches(text)) { return text; }
      }
    }
    // Seite ersetzt: im Hauptdokument bleibt fast nur die Sperre stehen.
    var all = (document.body.innerText || '').trim();
    if (all.length < 700 && matches(all)) { return all; }
    // Eigene Sperr-Seite (z. B. /adblockwall.html, Navigation und Fußzeile stehen noch drumherum) oder kurze Seite mit
    // Überschrift über den Blocker: dann zählt der Seitentext.
    if (matches(all) && (/ad[-_]?block|blocker|werbeblock/i.test(location.pathname) || (all.length < 2500 && headingMatches()))) {
      var m = all.search(BLOCKER);
      return all.slice(Math.max(0, m - 20), m + 180);
    }
    return null;
  }
  var runs = 0;
  var timer = setInterval(function () {
    runs++;
    var hit = null;
    try { hit = find(); } catch (e) {}
    if (hit) {
      clearInterval(timer);
      try { handler.postMessage({ host: host, text: hit.replace(/\s+/g, ' ').slice(0, 200), top: top }); } catch (e) {}
    } else if (runs >= 10) {
      clearInterval(timer);
    }
  }, 1500);
})();
