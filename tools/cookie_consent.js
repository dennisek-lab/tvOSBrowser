// Cookie-Banner-Ablehner. Quelle fürs eingebettete Skript in BrowserCookieConsentBlocker.m
// (Neu erzeugen: python3 tools/embed_cookie_script.py). Läuft in jedem Frame (document-end).
(function () {
  'use strict';
  if (window.__browserConsentOff || window.__browserConsent) { return; }
  window.__browserConsent = 1;

  var TOP = (window === window.top);
  function hostName() {
    if (location.hostname) { return location.hostname; }
    try { if (window.top.location.hostname) { return window.top.location.hostname; } } catch (e) {}
    try { if (window.parent.location.hostname) { return window.parent.location.hostname; } } catch (e) {}
    return 'about:blank';
  }
  var HOST = hostName();
  var finished = false, started = Date.now();
  var purSeen = false, wallLocal = false, scheduled = false, observer = null, timers = [];

  function post(cmp, action, detail) {
    try { webkit.messageHandlers.browserConsent.postMessage({ cmp: cmp, action: action, host: HOST, top: TOP, detail: detail || '' }); } catch (e) {}
  }
  var lastClicked = '';
  function describe(el) {
    var t = '';
    try { t = (el.innerText || el.textContent || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || '') + ''; } catch (e) {}
    t = t.replace(/\s+/g, ' ').trim().slice(0, 40);
    var c = '';
    try { c = typeof el.className === 'string' ? el.className.trim().split(/\s+/).slice(0, 3).join('.') : ''; } catch (e) {}
    var id = ''; try { id = el.id ? '#' + el.id : ''; } catch (e) {}
    return 'clicked: "' + t + '" ' + String(el.tagName || '').toLowerCase() + id + (c ? '.' + c : '');
  }

  // ---------- Hilfsfunktionen ----------
  function norm(s) {
    return String(s || '').toLowerCase().replace(/[ \s]+/g, ' ').replace(/[»›«‹→…!.:]+/g, ' ').replace(/\s+/g, ' ').trim();
  }
  function label(el) {
    var t = '';
    try { t = (el.innerText || el.textContent || el.value || '') + ''; } catch (e) {}
    if (!t.trim()) { t = (el.getAttribute('aria-label') || el.getAttribute('title') || '') + ''; }
    return t;
  }
  function vis(el, strict) {
    try {
      var r = el.getBoundingClientRect();
      if (r.width < 4 || r.height < 4) { return false; }
      var w = (el.ownerDocument && el.ownerDocument.defaultView) || window;
      var s = w.getComputedStyle(el);
      if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse' || parseFloat(s.opacity) < 0.05) { return false; }
      if (strict) {
        // Mitte des Elements muss im Viewport liegen und nicht von einem fremden Element verdeckt sein.
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        if (cx < 0 || cy < 0 || cx > w.innerWidth || cy > w.innerHeight) { return false; }
        var top = el.ownerDocument.elementFromPoint(cx, cy);
        if (!top) { return false; }
        if (top !== el && !el.contains(top) && !(top.contains && top.contains(el))) {
          var root = el.getRootNode && el.getRootNode();
          if (!(root && root.host && (top === root.host || root.host.contains(top)))) { return false; }
        }
      }
      return true;
    } catch (e) { return false; }
  }
  // Akzeptier-Buttons bekannter CMPs: werden unter keinen Umständen angeklickt.
  var ACCEPT_SEL = '.fc-cta-consent,#onetrust-accept-btn-handler,#didomi-notice-agree-button,[data-testid=uc-accept-all-button],' +
    '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll,#CybotCookiebotDialogBodyButtonAccept,#truste-consent-button,#L2AGLb,.cky-btn-accept,.cmplz-accept';
  function isAccept(el) { try { return !!(el.matches && el.matches(ACCEPT_SEL)); } catch (e) { return false; } }

  // Alle Elemente zu einem Selektor, auch in offenen Shadow-DOMs (Usercentrics u. a.).
  function deepAll(sel, root, out, budget) {
    out = out || []; root = root || document; budget = budget || { n: 6000 };
    try { var found = root.querySelectorAll(sel); for (var i = 0; i < found.length; i++) { out.push(found[i]); } } catch (e) {}
    var all; try { all = root.querySelectorAll('*'); } catch (e) { return out; }
    for (var j = 0; j < all.length && budget.n-- > 0; j++) {
      if (all[j].shadowRoot) { deepAll(sel, all[j].shadowRoot, out, budget); }
    }
    return out;
  }
  function firstVisible(sel) {
    var els = deepAll(sel);
    for (var i = 0; i < els.length; i++) { if (vis(els[i])) { return els[i]; } }
    return null;
  }
  function click(el) {
    if (isAccept(el)) { return false; }
    try {
      var w = (el.ownerDocument && el.ownerDocument.defaultView) || window;
      el.scrollIntoView && el.scrollIntoView({ block: 'nearest' });
      var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
      lastClicked = describe(el);
      ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (t) {
        var init = { bubbles: true, cancelable: true, view: w, clientX: x, clientY: y, button: 0, buttons: t.indexOf('down') > 0 ? 1 : 0 };
        try {
          var ev = (t.indexOf('pointer') === 0 && w.PointerEvent) ? new w.PointerEvent(t, init) : new w.MouseEvent(t, init);
          el.dispatchEvent(ev);
        } catch (e) {}
      });
      if (typeof el.click === 'function') { el.click(); }
      return true;
    } catch (e) { return false; }
  }

  // ---------- Texterkennung ----------
  var REJECT = [
    /^(alle |alles )?(optionalen |nicht notwendigen? |nicht erforderlichen? |unnötigen? )?(cookies )?(ablehnen|verweigern)$/,
    /^(alle |alles )?(cookies )?ablehnen (und|&) (schließen|weiter|fortfahren)$/,
    /^nur (notwendige|erforderliche|essenzielle|essentielle|technisch notwendige|technisch erforderliche|funktionale|wesentliche)( cookies| technologien)?( akzeptieren| zulassen| erlauben| speichern| verwenden)?$/,
    /^(notwendige|erforderliche|essenzielle|essentielle)( cookies)?( akzeptieren| zulassen| erlauben)?$/,
    /^(weiter|fortfahren) ohne (einwilligung|zustimmung|akzeptieren|tracking|zustimmen)$/,
    /^ohne (einwilligung|zustimmung|akzeptieren) (weiter|fortfahren|lesen)$/,
    /^(nicht einverstanden|ich lehne ab|ich stimme nicht zu|nicht zustimmen)$/,
    /^(reject|decline|deny|refuse|disagree)( all| everything)?( non-?essential| optional| unnecessary| additional)?( cookies)?$/,
    /^(only|use only|accept only|allow only) (necessary|essential|required|strictly necessary)( cookies)?( only)?$/,
    /^(necessary|essential|required|strictly necessary) (cookies )?only$/,
    /^continue without (accepting|agreeing|consent|tracking)$/,
    /^(i )?(do not|don't) (accept|consent|agree)$/,
    /^(i )?(decline|disagree|reject)$/,
    /^(tout )?refuser( tout)?( et continuer)?$/,
    /^continuer sans accepter$/,
    /^rechazar( todo| todas| todas las cookies)?$/,
    /^rifiuta( tutto| tutti)?$/
  ];
  // Bezahl-/Abo-Texte: nie anklicken
  var BAD = /(\babo\b|abonn|subscri|\bpur\b|pur-|€|\bmonat|kostenpflichtig|bezahl|jetzt kaufen|premium|\bplus\b)/;
  var COOKIEWORDS = /cookie|datenschutz|privacy|consent|einwilligung|tracking|cmp|gdpr|dsgvo/i;
  var CTX = /cookie|consent|gdpr|dsgvo|privacy|datenschutz|cmp|didomi|onetrust|ot-sdk|cybot|usercentrics|sp_message|sp-message|qc-cmp|truste|trustarc|borlabs|brlbs|klaro|cky|cmplz|einwilligung|fc-/i;

  function matchesAny(list, t) { for (var i = 0; i < list.length; i++) { if (list[i].test(t)) { return true; } } return false; }
  function isRejectText(t) { t = norm(t); return t.length > 0 && t.length < 60 && !BAD.test(t) && matchesAny(REJECT, t); }

  // Ist das Dokument selbst ein CMP-Frame?
  function docIsCmp() {
    if (/^consent\./.test(HOST)) { return true; }
    if (TOP) { return false; }
    var s = location.href + ' ' + document.title + ' ' + ((document.body && document.body.innerText) || '').slice(0, 1500);
    return COOKIEWORDS.test(s);
  }

  function inBanner(el) {
    if (docIsCmp()) { return true; }
    var n = el;
    for (var i = 0; n && i < 12; i++) {
      if (n.nodeType !== 1) { n = n.host || n.parentNode; continue; }
      var cls = typeof n.className === 'string' ? n.className : '';
      var meta = (n.id || '') + ' ' + cls + ' ' + (n.getAttribute('aria-label') || '') + ' ' + (n.getAttribute('data-testid') || '');
      if (CTX.test(meta)) { return true; }
      var role = n.getAttribute('role');
      var cs = getComputedStyle(n);
      var z = parseInt(cs.zIndex, 10);
      var overlay = (cs.position === 'fixed' || cs.position === 'sticky' || cs.position === 'absolute') && z >= 100;
      if (overlay || role === 'dialog' || role === 'alertdialog') {
        var tx = ''; try { tx = (n.innerText || '').slice(0, 2500); } catch (e) {}
        if (/cookie|datenschutz|privacy|einwilligung|consent|tracking/i.test(tx)) { return true; }
      }
      n = n.parentElement || n.getRootNode().host;
    }
    return false;
  }

  function candidates() {
    return deepAll('button,a,[role=button],input[type=button],input[type=submit],[class*=btn],[class*=button],[tabindex="0"]');
  }
  function safeLink(el) {
    if (el.tagName !== 'A') { return true; }
    var h = el.getAttribute('href');
    return !h || h === '#' || /^javascript:/i.test(h) || /consent|cookie|reject|decline|optout|opt-out|ablehn/i.test(h);
  }

  // ---------- Bekannte CMPs ----------
  // Je Eintrag: Name, Selektoren für „Ablehnen“, optionaler JS-Aufruf. Reihenfolge = Priorität.
  var CMPS = [
    { n: 'onetrust', sel: ['#onetrust-reject-all-handler', '.ot-pc-refuse-all-handler', 'button.ot-bnr-reject-all'],
      js: function () { if (window.OneTrust && typeof OneTrust.RejectAll === 'function' && firstVisible('#onetrust-banner-sdk,#onetrust-pc-sdk')) { OneTrust.RejectAll(); return true; } return false; } },
    { n: 'usercentrics', sel: ['[data-testid=uc-deny-all-button]', 'button#deny', '.uc-deny-all-button'],
      js: function () { if (window.UC_UI && typeof UC_UI.denyAllConsents === 'function' && UC_UI.isInitialized && UC_UI.isInitialized() && firstVisible('#usercentrics-root')) { var p = UC_UI.denyAllConsents(); try { p.then(function () { UC_UI.closeCMP(); }); } catch (e) {} return true; } return false; } },
    { n: 'sourcepoint', sel: ['button.sp_choice_type_13', 'button.sp_choice_type_REJECT_ALL', 'button[title="Alle ablehnen" i]', 'button[title="Reject All" i]', 'button[title="Ablehnen" i]', 'button[title="Nur notwendige" i]'] },
    { n: 'didomi', sel: ['#didomi-notice-disagree-button', '.didomi-continue-without-agreeing', 'button.didomi-components-button--disagree'],
      js: function () { if (window.Didomi && typeof Didomi.setUserDisagreeToAll === 'function' && firstVisible('#didomi-host,.didomi-popup-container,#didomi-notice')) { Didomi.setUserDisagreeToAll(); return true; } return false; } },
    { n: 'quantcast', sel: ['.qc-cmp2-summary-buttons button[mode=secondary][class*=reject i]', '.qc-cmp2-footer button[mode=secondary]', 'button.qc-cmp2-reject-all'] },
    { n: 'funding-choices', sel: ['.fc-cta-do-not-consent', '.fc-consent-root .fc-secondary-button.fc-cta-do-not-consent'] },
    { n: 'cookiebot', sel: ['#CybotCookiebotDialogBodyButtonDecline', '#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll', '#CybotCookiebotDialogBodyLevelButtonDecline'] },
    { n: 'trustarc', sel: ['#truste-consent-required', 'a.rejectAll', 'button.rejectAll', '.pdynamicbutton .required'] },
    { n: 'consentmanager', sel: ['.cmpboxbtnno', '#cmpwelcomebtnno .cmpboxbtn', '.cmpboxbtnreject'],
      js: function () { if (typeof window.__cmp === 'function' && firstVisible('#cmpbox,#cmpbox2,.cmpwrapper')) { window.__cmp('setConsent', 0); return true; } return false; } },
    { n: 'borlabs', sel: ['._brlbs-refuse-btn a', '._brlbs-refuse-btn', '.brlbs-btn-accept-only-essential', '[data-cookie-refuse]', '#CookieBoxRejectAllButton'] },
    { n: 'klaro', sel: ['.klaro button.cn-decline', '.cookie-modal button.cn-decline', '.klaro .cm-btn-decline'] },
    { n: 'cookieyes', sel: ['.cky-btn-reject', '[data-cky-tag=reject-button]'] },
    { n: 'complianz', sel: ['.cmplz-deny', 'button.cmplz-btn.cmplz-deny'] },
    { n: 'cookie-law-info', sel: ['#cookie_action_close_header_reject', '.wt-cli-reject-btn', '#wt-cli-reject-btn'] },
    { n: 'iubenda', sel: ['.iubenda-cs-reject-btn'] },
    { n: 'termly', sel: ['[data-tid=banner-decline]'] },
    { n: 'fastcmp', js: fastCmp },
    { n: 'google', sel: ['#W0wltc', 'button[aria-label="Alle ablehnen" i]', 'button[aria-label="Reject all" i]'], js: googleConsent }
  ];

  // FastCMP (w3schools u. a.): same-origin iframe#fast-cmp-iframe ohne src. Eine verlässliche JS-API ist nicht bekannt,
  // daher wird der „Ablehnen“-Knopf im iframe-Dokument angeklickt (vom Hauptframe aus oder im iframe selbst).
  // FastCMP verdrahtet seine Knöpfe erst kurz nach dem Erscheinen: Ein zu früher Klick verpufft.
  // Deshalb erst klicken, wenn der Dialog seit 1,2 s sichtbar ist, und danach prüfen, ob er wirklich weg ist.
  var fastSeenAt = 0, fastTries = 0;
  function fastCmpVisible() {
    var fr = document.getElementById('fast-cmp-iframe');
    if (!fr) { return false; }
    var r = fr.getBoundingClientRect(), cs = getComputedStyle(fr);
    return r.width > 4 && r.height > 4 && cs.display !== 'none' && cs.visibility !== 'hidden';
  }
  function fastCmp() {
    var doc = null;
    try {
      var fr = document.getElementById('fast-cmp-iframe');
      if (fr && fr.contentDocument && fr.contentDocument.body) { doc = fr.contentDocument; }
    } catch (e) {}
    if (TOP && doc) {
      if (!fastCmpVisible()) { return false; }
      if (!fastSeenAt) { fastSeenAt = Date.now(); }
      if (Date.now() - fastSeenAt < 1200 || fastTries >= 4) { return false; }
    }
    if (!doc && !TOP && document.querySelector('.fast-cmp-home-refuse,.top-refuse-btn,.fast-cmp-button-secondary')) { doc = document; }
    if (!doc) { return false; }
    var sels = ['.fast-cmp-home-refuse', '.top-refuse-btn', '.fast-cmp-button-secondary'];
    for (var i = 0; i < sels.length; i++) {
      var els = doc.querySelectorAll(sels[i]);
      for (var j = 0; j < els.length; j++) {
        var el = els[j];
        if (!vis(el)) { continue; }
        var t = norm(label(el));
        if (t && !isRejectText(t) && !/^(refuse|ablehnen|reject|decline)/.test(t)) { continue; }
        if (TOP && doc !== document) {
          // Vom Hauptframe: klicken und nach 1 s nachsehen; ist der Dialog noch da, erneut versuchen.
          fastTries++;
          click(el);
          setTimeout(function () {
            if (!fastCmpVisible()) { done('fastcmp', 'reject', lastClicked) } else { schedule() }
          }, 1000);
          return false;
        }
        if (click(el)) { return true; }
      }
    }
    return false;
  }

  // consent.google.com / consent.youtube.com: das Formular mit set_eom=true ist „Alle ablehnen“.
  function googleConsent() {
    if (!/(^|\.)(consent\.(google|youtube)\.|google\.[a-z.]+$|youtube\.com$)/.test(HOST)) { return false; }
    var forms = document.querySelectorAll('form[action*="consent"]');
    for (var i = 0; i < forms.length; i++) {
      var f = forms[i];
      if (f.querySelector('input[name=set_eom][value=true]')) {
        var b = f.querySelector('button,input[type=submit]');
        if (b && vis(b)) { return click(b); }
      }
    }
    return false;
  }

  function done(cmp, action, detail) {
    if (finished) { return true; }
    finished = true;
    post(cmp, action, detail);
    if (observer) { observer.disconnect(); observer = null; }
    timers.forEach(clearTimeout);
    setTimeout(unlockScroll, 700); setTimeout(unlockScroll, 2500);
    return true;
  }

  // Nach erfolgreichem Ablehnen: von CMPs gesperrtes Scrollen wieder freigeben.
  function unlockScroll() {
    try {
      [document.documentElement, document.body].forEach(function (el) {
        if (!el) { return; }
        if (el.style.overflow === 'hidden' || el.style.overflowY === 'hidden') { el.style.overflow = ''; el.style.overflowY = ''; }
        if (el.style.position === 'fixed' && el === document.body) { el.style.position = ''; }
      });
    } catch (e) {}
  }

  function trySelectors(list) {
    for (var i = 0; i < list.length; i++) {
      var el = firstVisible(list[i]);
      if (el && !isAccept(el) && safeLink(el) && !BAD.test(norm(label(el)))) { return el; }
    }
    return null;
  }

  function attempt() {
    scheduled = false;
    if (finished || !document.body) { return; }
    var i, el;
    // 1) Gezielt: bekannte CMPs
    for (i = 0; i < CMPS.length; i++) {
      var c = CMPS[i];
      try { if (c.js && c.js()) { return done(c.n, 'reject-api', lastClicked); } } catch (e) {}
      el = trySelectors(c.sel || []);
      if (el && click(el)) { return done(c.n, 'reject', lastClicked); }
    }
    // 2) Generisch: nur eindeutig ablehnender Text, sichtbar (im Viewport, nicht verdeckt), in einem Banner.
    //    Einstellungen/„Mehr Optionen“ werden nie geöffnet; Pur-/Abo-Wände werden nicht angefasst.
    var cands = candidates(), walls = 0, rejectEl = null;
    for (i = 0; i < cands.length; i++) {
      el = cands[i];
      if (isAccept(el) || !vis(el)) { continue; }
      var t = label(el), nt = norm(t);
      if (BAD.test(nt) && nt.length < 60 && inBanner(el)) { walls++; }
      if (!rejectEl && isRejectText(t) && safeLink(el) && vis(el, true) && inBanner(el)) { rejectEl = el; }
    }
    if (walls > 0 && !wallLocal) {
      wallLocal = true;
      if (!TOP) { try { parent.postMessage({ __bcPur: 1 }, '*'); } catch (e) {} }
    }
    if (rejectEl && walls === 0 && click(rejectEl)) { return done('generic', 'reject', lastClicked); }
  }

  // ---------- Kosmetischer Rückfall ----------
  var OVERLAYS = ['#onetrust-consent-sdk', '#usercentrics-root', 'div[id^=sp_message_container]', 'iframe[id^=sp_message_iframe]', '#didomi-host',
    '.qc-cmp2-container', '#CybotCookiebotDialog', '#truste-consent-track', '#cmpbox', '#cmpbox2', '#BorlabsCookieBox', '.klaro', '.cky-consent-container',
    '.cmplz-cookiebanner', '#cmplz-cookiebanner-container', '#cookie-law-info-bar', '.cc-window', '#cookiescript_injected', '.cookie-consent-banner',
    '.fc-consent-root', '.fc-dialog-container'];
  var BACKDROPS = ['.onetrust-pc-dark-filter', '.cky-overlay', '.didomi-popup-backdrop', '.qc-cmp2-overlay', '#CybotCookiebotDialogBodyUnderlay', '.fc-dialog-overlay'];

  function cosmetic() {
    if (finished || !TOP || purSeen || wallLocal) { return; }
    var hidden = 0;
    OVERLAYS.concat(BACKDROPS).forEach(function (sel) {
      var els; try { els = document.querySelectorAll(sel); } catch (e) { return; }
      for (var i = 0; i < els.length; i++) {
        if (vis(els[i]) || sel.indexOf('iframe') === 0) { els[i].style.setProperty('display', 'none', 'important'); hidden++; }
      }
    });
    if (hidden > 0) {
      var st = document.createElement('style');
      st.textContent = 'html,body{overflow:auto !important;}';
      (document.head || document.documentElement).appendChild(st);
      unlockScroll();
      finished = true;
      post('cosmetic', 'hide');
    }
  }

  function schedule() {
    if (scheduled || finished) { return; }
    scheduled = true;
    setTimeout(attempt, 150);
  }

  // Meldung aus Kind-Frames (Pur-Abo-Wand erkannt): Banner nicht ausblenden.
  window.addEventListener('message', function (e) { try { if (e.data && e.data.__bcPur) { purSeen = true; } } catch (x) {} });

  // ---------- Start ----------
  attempt();
  if (finished) { return; }
  try {
    observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, { childList: true, subtree: true });
  } catch (e) {}
  [300, 800, 1500, 2500, 4000, 6000, 8000].forEach(function (ms) { timers.push(setTimeout(attempt, ms)); });
  timers.push(setTimeout(function () {
    attempt();
    if (observer) { observer.disconnect(); observer = null; }
    cosmetic();
    finished = true;
  }, 10000));
})();
