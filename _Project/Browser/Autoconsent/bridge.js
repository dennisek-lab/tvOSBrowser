// Brücke zwischen DuckDuckGos autoconsent (autoconsent.standalone.js, unverändert) und der App.
// Läuft im selben Seitenkontext direkt nach dem Bundle. Das Standalone-Bundle trägt die Regeln selbst, entscheidet
// mit autoAction „optOut“ (Standardwert) allein und führt eval-Regeln im Seitenkontext (isMainWorld) aus; die App
// bekommt nur Lesemeldungen für das Log.
// Ausnahme Bezahlschranken („Mit Werbung weiterlesen oder Abo“): Dort gibt es kein Ablehnen. Ist der Schalter
// window.__browserAcceptPayWalls an (setzt die App vor dem Bundle), klickt die Brücke dort „Akzeptieren“, damit kein
// Banner stehen bleibt. Normale Banner werden weiter nur abgelehnt.
(function () {
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserAutoconsent;
  var standalone = window.autoconsentStandalone;
  if (!handler || !standalone || !standalone.messages) { return; }
  var top = window.top === window;
  var lastLifecycle = '';
  function forward(m) {
    try {
      if (!m || typeof m.type !== 'string') { return; }
      var out = { type: m.type, cmp: typeof m.cmp === 'string' ? m.cmp : '', url: String(m.url || location.href), top: top };
      if (typeof m.result === 'boolean') { out.result = m.result; }
      if (m.type === 'report') {
        var st = m.state || {};
        if (st.lifecycle === lastLifecycle) { return; }
        lastLifecycle = st.lifecycle;
        out.cmp = (st.detectedCmps && st.detectedCmps[0]) || '';
        out.lifecycle = String(st.lifecycle || '');
      } else if (m.type === 'autoconsentError') {
        out.details = String((m.details && m.details.message) || m.details || '').slice(0, 200);
      }
      handler.postMessage(out);
    } catch (e) {}
  }
  var original = standalone.messages.push;
  standalone.messages.push = function () {
    var r = original.apply(this, arguments);
    for (var i = 0; i < arguments.length; i++) { forward(arguments[i]); }
    return r;
  };
  standalone.messages.slice().forEach(forward);

  // --- Bezahlschranken -------------------------------------------------------------------------------------------
  if (window.__browserAcceptPayWalls !== true) { return; }
  // Text, der eine Bezahlschranke ausmacht (Abo-/Pur-Angebot statt Ablehnen).
  var PAY = /(\babo\b|abonn|\bpur\b|pur-abo|werbefrei|ohne werbung|ohne werbebanner|ohne werbetracking|\bpro\b bestellen|\bplus\b.{0,20}(abo|testen|lesen)|subscribe|subscription|ad-free|€|euro\b)/i;
  // Beschriftung des Zustimmen-Knopfs.
  var ACCEPT = /^(akzeptieren( (und|&) weiter(lesen)?)?|alle akzeptieren|zustimmen( (und|&) weiter(lesen)?)?|allen zustimmen|einverstanden|ich stimme zu|ok(ay)?|accept( all)?( and continue)?|agree( and continue)?|i agree|mit werbung (weiter|lesen|nutzen|weiterlesen)|weiter mit werbung|mit werbung und tracking weiter)$/i;
  var accepted = false;
  function visible(el) {
    var r = el.getBoundingClientRect();
    if (r.width < 8 || r.height < 8 || r.bottom < 0 || r.right < 0 || r.top > innerHeight || r.left > innerWidth) { return false; }
    var cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || parseFloat(cs.opacity) < 0.1) { return false; }
    var x = Math.min(Math.max(r.left + r.width / 2, 0), innerWidth - 1), y = Math.min(Math.max(r.top + r.height / 2, 0), innerHeight - 1);
    var hit = document.elementFromPoint(x, y);
    return !!hit && (hit === el || el.contains(hit) || hit.contains(el));
  }
  // Umgebender Dialog: fixiertes Element, role=dialog/aria-modal oder (im CMP-iframe) die ganze Seite.
  // Im iframe (CMP-Fenster) zählt die ganze Seite, sonst der äußerste fixierte Container: Abo-Hinweis und
  // Zustimmen-Knopf stehen oft in getrennten Spalten.
  function dialogOf(el) {
    if (!top) { return document.body; }
    var found = null;
    for (var n = el; n && n !== document.documentElement; n = n.parentElement) {
      var cs = getComputedStyle(n);
      if (cs.position === 'fixed' || cs.position === 'sticky' || n.getAttribute('role') === 'dialog' || n.getAttribute('aria-modal') === 'true') { found = n; }
    }
    return found;
  }
  var skipped = {};
  // Diagnose: warum ein passender Knopf nicht geklickt wurde (je Grund und Text nur einmal).
  function skip(label, why) {
    var key = why + label;
    if (skipped[key]) { return; }
    skipped[key] = true;
    try { handler.postMessage({ type: 'payWallSkip', cmp: '', url: location.href, top: top, details: label + ': ' + why }); } catch (e) {}
  }
  function scan(reason) {
    if (accepted || !document.body) { return; }
    var nodes = document.querySelectorAll('button, a, [role=button], input[type=button], input[type=submit]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var label = (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
      if (!label || label.length > 60 || !ACCEPT.test(label)) { continue; }
      if (!visible(el)) { skip(label, 'unsichtbar'); continue; }
      var dialog = dialogOf(el);
      if (!dialog) { skip(label, 'kein Dialog'); continue; }
      var text = dialog.innerText || '';
      if (!PAY.test(text)) { skip(label, 'keine Bezahlschranke'); continue; }
      accepted = true;
      try { el.click(); } catch (e) {}
      try { handler.postMessage({ type: 'payWallAccepted', cmp: '', url: location.href, top: top, details: label + ' (' + reason + ')' }); } catch (e) {}
      return;
    }
  }
  // Erst autoconsent ablehnen lassen; was danach noch sichtbar ist, ist eine Bezahlschranke.
  // Manche Schranken kommen spät (eigene Zustimmungsseite, nachgeladenes iframe): 30 s lang alle 1,5 s nachsehen.
  var started = Date.now();
  var timer = setInterval(function () {
    var ms = Date.now() - started;
    if (accepted || ms > 30000) { clearInterval(timer); return; }
    if (ms >= 2500) { scan('t' + Math.round(ms / 100) * 100); }
  }, 1500);
  var push = standalone.messages.push;
  standalone.messages.push = function () {
    var r = push.apply(this, arguments);
    for (var i = 0; i < arguments.length; i++) {
      var m = arguments[i];
      if (m && (m.type === 'autoconsentDone' || m.type === 'optOutResult')) { setTimeout(function () { scan('nach Ablehnen'); }, 1500); }
    }
    return r;
  };
})();
