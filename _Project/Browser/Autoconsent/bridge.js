// Brücke zwischen DuckDuckGos autoconsent (autoconsent.standalone.js, unverändert) und der App.
// Läuft im selben Seitenkontext direkt nach dem Bundle. Das Standalone-Bundle trägt die Regeln selbst, entscheidet
// mit autoAction „optOut“ (Standardwert) allein und führt eval-Regeln im Seitenkontext (isMainWorld) aus; die App
// bekommt nur Lesemeldungen für das Log.
// Ausnahme Bezahlschranken („Mit Werbung weiterlesen oder Abo“): Dort gibt es kein Ablehnen. Ist der Schalter
// window.__browserAcceptPayWalls an (setzt die App vor dem Bundle), klickt die Brücke dort „Akzeptieren“, damit kein
// Banner stehen bleibt. Normale Banner werden weiter nur abgelehnt.
(function () {
  // --- Störer ------------------------------------------------------------------------------------------------------
  // Google One Tap („Über Google anmelden“, iframe von accounts.google.com) ist kein Cookie-Banner, stört aber auf dem
  // Fernseher (CNN u. a.) und verdeckt Inhalte. Nur eindeutig harmlose Selektoren: Container und iframe des One-Tap-
  // Dialogs (credential_picker, gsi/iframe/select). Der normale „Mit Google anmelden“-Knopf (.g_id_signin) bleibt.
  try {
    if (location.hostname === 'accounts.google.com' && location.pathname.indexOf('/gsi/') === 0 && window.top !== window) {
      var hs = document.createElement('style');
      hs.textContent = 'html,body{display:none!important}';
      (document.head || document.documentElement).appendChild(hs);
    } else {
      var ns = document.createElement('style');
      ns.textContent = '#credential_picker_container,#credential_picker_iframe,#g_id_onload,iframe[src*="accounts.google.com/gsi/iframe/select"],iframe[src*="accounts.google.com/gsi/iframe/one"]{display:none!important;visibility:hidden!important;pointer-events:none!important}';
      (document.head || document.documentElement).appendChild(ns);
    }
  } catch (e) {}
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserAutoconsent;
  var standalone = window.autoconsentStandalone;
  if (!handler || !standalone || !standalone.messages) { return; }
  var top = window.top === window;
  // Consent-or-Pay-Seiten, bei denen Ablehnen in eine Sackgasse führt (Bild: Ablehnen blockiert Tracking, die Seite hält das für
  // einen Werbeblocker und bleibt weiß/gesperrt). Mit aktiver Bezahlschranken-Zustimmung läuft autoconsent dort nur als
  // Erkenner (keine Aktion); die Bezahlschranken-Logik unten klickt dann „Akzeptieren“/„Mit Werbung weiter“.
  var PAY_FIRST_HOSTS = /(^|\.)(bild|autobild|computerbild|sportbild)\.de$/i;
  var siteHost = location.hostname;
  try {
    if (!top) {
      if (location.ancestorOrigins && location.ancestorOrigins.length) { siteHost = new URL(location.ancestorOrigins[location.ancestorOrigins.length - 1]).hostname; }
      else if (document.referrer) { siteHost = new URL(document.referrer).hostname; }
    }
  } catch (e) {}
  if (window.__browserAcceptPayWalls === true && PAY_FIRST_HOSTS.test(siteHost) && standalone.instance && standalone.instance.config) {
    try { standalone.instance.config.autoAction = null; } catch (e) {}
  }
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

  // --- Ablehnen-Nachlauf -----------------------------------------------------------------------------------------
  // Manchmal meldet autoconsent „abgelehnt“ (oder erkennt ein anderes CMP, z. B. The Verge: Regel „pmc-privacy-banner“
  // statt OneTrust), und der Banner steht trotzdem noch. Dann sucht diese Prüfung einen sichtbaren Ablehnen-Knopf
  // in einem Cookie-/Datenschutz-Dialog und klickt ihn. Nie „Einstellungen“, nie „Akzeptieren“.
  var REJECT = /^(reject( all)?( non-essential| optional| non-necessary)?( cookies)?|decline( all| optional)?( cookies)?|deny( all)?|refuse( all)?|(alle |optionale |nicht notwendige )?(cookies )?ablehnen|alles ablehnen|nur (notwendige|erforderliche|essenzielle|essentielle|technisch notwendige)( cookies)?( zulassen| akzeptieren| verwenden)?|only (necessary|essential)( cookies)?|necessary only|essential only|continue without accepting|weiter ohne (zustimmen|zustimmung|akzeptieren)|ohne zustimmung fortfahren)$/i;
  var CONSENT_TEXT = /(cookie|consent|privacy|personal data|tracking|datenschutz|einwilligung|partner)/i;
  var rejected = false;
  var accepted = false;
  var rejectSkipped = {};
  function rejectScan(reason) {
    if (rejected || accepted || !document.body) { return; }
    var nodes = document.querySelectorAll('button, a, [role=button], input[type=button], input[type=submit]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var label = (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
      if (!label || label.length > 40 || !REJECT.test(label)) { continue; }
      if (!visible(el)) { continue; }
      var dialog = dialogOf(el);
      if (!dialog || !CONSENT_TEXT.test(dialog.innerText || '')) {
        if (!rejectSkipped[label]) { rejectSkipped[label] = true; try { handler.postMessage({ type: 'rejectSkip', cmp: '', url: location.href, top: top, details: label + ': kein Cookie-Dialog' }); } catch (e) {} }
        continue;
      }
      rejected = true;
      try { el.click(); } catch (e) {}
      try { handler.postMessage({ type: 'rejectClicked', cmp: '', url: location.href, top: top, details: label + ' (' + reason + ')' }); } catch (e) {}
      return;
    }
  }
  var rejectStarted = Date.now();
  var rejectTimer = setInterval(function () {
    var ms = Date.now() - rejectStarted;
    if (rejected || ms > 30000) { clearInterval(rejectTimer); return; }
    if (ms >= 3000) { rejectScan('t' + Math.round(ms / 100) * 100); }
  }, 2000);

  // --- Bezahlschranken -------------------------------------------------------------------------------------------
  if (window.__browserAcceptPayWalls !== true) { return; }
  // Text, der eine Bezahlschranke ausmacht (Abo-/Pur-Angebot statt Ablehnen).
  var PAY = /(\babo\b|abonn|\bpur\b|pur-abo|werbefrei|ohne werbung|ohne werbebanner|ohne werbetracking|\bpro\b bestellen|\bplus\b.{0,20}(abo|testen|lesen)|bild\s?plus|subscribe|subscription|ad-free|€|euro\b)/i;
  // Beschriftung des Zustimmen-Knopfs.
  var ACCEPT = /^(akzeptieren( (und|&) weiter(lesen)?)?|alle akzeptieren|zustimmen( (und|&) weiter(lesen)?)?|allen zustimmen|einverstanden|ich stimme zu|ok(ay)?|accept( all)?( and continue)?|agree( and continue)?|i agree|mit werbung (weiter|lesen|nutzen|weiterlesen)|weiter mit werbung|mit werbung und tracking weiter)$/i;
  var skipped = {};
  // Diagnose: warum ein passender Knopf nicht geklickt wurde (je Grund und Text nur einmal).
  function skip(label, why) {
    var key = why + label;
    if (skipped[key]) { return; }
    skipped[key] = true;
    try { handler.postMessage({ type: 'payWallSkip', cmp: '', url: location.href, top: top, details: label + ': ' + why }); } catch (e) {}
  }
  // Knopf- und Linktexte samt Beschriftungen (innerText fehlt bei versteckten/abgeschnittenen Teilen).
  function buttonTexts(root) {
    var out = [];
    var ns = root.querySelectorAll('button, a, [role=button], input[type=button], input[type=submit]');
    for (var i = 0; i < ns.length && i < 60; i++) {
      out.push(ns[i].textContent || ns[i].value || '', ns[i].getAttribute('aria-label') || '', ns[i].getAttribute('title') || '');
    }
    return out.join(' ');
  }
  // Das Bezahl-Angebot steht oft nicht im Fenster mit dem Zustimmen-Knopf: Golem lädt den Sourcepoint-Knopf in ein
  // iframe (cmp-cdn.golem.de), Abo-Text („Zu Golem pur“) steht im umgebenden Dokument. Cross-origin kann das iframe
  // den Text nicht lesen, deshalb meldet jedes Dokument sein Ergebnis per postMessage an die Kindframes.
  // Als Bezahlschranke zählt nur eine kurze Seite (Zustimmungsseite) oder ein Dialog/Overlay mit Bezahltext.
  var parentPay = false;
  function ownPaySignal() {
    try {
      var body = document.body;
      if (!body) { return false; }
      var txt = (body.innerText || '') + ' ' + buttonTexts(body);
      if ((body.innerText || '').length < 6000 && PAY.test(txt)) { return true; }
      var ds = document.querySelectorAll('[role=dialog],[aria-modal=true],[id*=consent i],[class*=consent i],[id*=cookie i],[class*=cookie i],[id*=cmp i],[class*=cmp i]');
      for (var i = 0; i < ds.length && i < 40; i++) {
        var d = ds[i];
        if (!visible(d) && d.getBoundingClientRect().width < 8) { continue; }
        if (PAY.test((d.innerText || '') + ' ' + buttonTexts(d))) { return true; }
      }
    } catch (e) {}
    return false;
  }
  function broadcast() {
    if (!(parentPay || ownPaySignal())) { return; }
    var fr = document.querySelectorAll('iframe');
    for (var i = 0; i < fr.length; i++) {
      try { fr[i].contentWindow.postMessage({ browserPaySignal: 1 }, '*'); } catch (e) {}
    }
  }
  window.addEventListener('message', function (e) {
    if (!e.data || e.data.browserPaySignal !== 1 || e.source !== window.parent || top) { return; }
    parentPay = true;
    scan('Signal vom Elterndokument');
  });
  function scan(reason) {
    if (accepted || rejected || !document.body) { return; }
    broadcast();
    var nodes = document.querySelectorAll('button, a, [role=button], input[type=button], input[type=submit]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var label = (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
      if (!label || label.length > 60 || !ACCEPT.test(label)) { continue; }
      if (!visible(el)) { skip(label, 'unsichtbar'); continue; }
      var dialog = dialogOf(el);
      if (!dialog) { skip(label, 'kein Dialog'); continue; }
      var text = (dialog.innerText || '') + ' ' + buttonTexts(dialog);
      if (!PAY.test(text) && !parentPay) { skip(label, 'keine Bezahlschranke'); continue; }
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
