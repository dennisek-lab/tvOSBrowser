// Cookie-Banner-Ablehner. Quelle fürs eingebettete Skript in BrowserCookieConsentBlocker.m
// (Neu erzeugen: python3 tools/embed_cookie_script.py). Läuft in jedem Frame (document-end).
(function () {
  'use strict';
  if (window.__browserConsentOff || window.__browserConsent) { return; }
  window.__browserConsent = 1;

  var HOST = location.hostname, TOP = (window === window.top);
  var finished = false, started = Date.now(), settingsClicks = 0, settingsAt = 0, saveTries = 0;
  var purSeen = false, wallLocal = false, scheduled = false, observer = null, timers = [];

  function post(cmp, action) {
    try { webkit.messageHandlers.browserConsent.postMessage({ cmp: cmp, action: action, host: HOST, top: TOP }); } catch (e) {}
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
  function vis(el) {
    try {
      var r = el.getBoundingClientRect();
      if (r.width < 4 || r.height < 4) { return false; }
      var s = getComputedStyle(el);
      if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) < 0.05) { return false; }
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
      el.scrollIntoView && el.scrollIntoView({ block: 'nearest' });
      ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function (t) {
        try { el.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, view: window })); } catch (e) {}
      });
      el.click();
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
  var SETTINGS = /^(cookie-?einstellungen|einstellungen( anpassen| verwalten| ändern)?|anpassen|individuelle einstellungen|mehr optionen|weitere optionen|optionen|zwecke( und anbieter)? (verwalten|anzeigen)|präferenzen|auswahl anpassen|datenschutzeinstellungen|konfigurieren|verwalten|cookie settings|settings|manage( cookies| preferences| options| settings)?|more options|customi[sz]e( settings)?|preferences|options|show purposes|cookie preferences|mehr infos?|details)$/;
  var SAVE = /^((auswahl|einstellungen|meine auswahl|änderungen|meine einstellungen) )?(speichern|bestätigen|übernehmen)( (und|&) (schließen|beenden|weiter|fortfahren))?$|^speichern (und|&) (beenden|schließen|weiter)$|^(save|confirm)( my)?( choices| preferences| settings| selection)?( (and|&) (close|exit|continue))?$|^save (&|and) exit$|^confirm my choices$/;
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
      js: function () { if (window.OneTrust && typeof OneTrust.RejectAll === 'function' && firstVisible('#onetrust-banner-sdk,#onetrust-pc-sdk')) { OneTrust.RejectAll(); return true; } return false; },
      settings: '#onetrust-pc-btn-handler', save: '.save-preference-btn-handler' },
    { n: 'usercentrics', sel: ['[data-testid=uc-deny-all-button]', 'button#deny', '.uc-deny-all-button'],
      js: function () { if (window.UC_UI && typeof UC_UI.denyAllConsents === 'function' && UC_UI.isInitialized && UC_UI.isInitialized() && firstVisible('#usercentrics-root')) { var p = UC_UI.denyAllConsents(); try { p.then(function () { UC_UI.closeCMP(); }); } catch (e) {} return true; } return false; },
      settings: '[data-testid=uc-more-button]', save: '[data-testid=uc-save-button]' },
    { n: 'sourcepoint', sel: ['button.sp_choice_type_13', 'button.sp_choice_type_REJECT_ALL', 'button[title="Alle ablehnen" i]', 'button[title="Reject All" i]', 'button[title="Ablehnen" i]', 'button[title="Nur notwendige" i]'],
      settings: 'button.sp_choice_type_12, button[title*="Einstellungen" i], button[title*="Optionen" i], button[title*="Options" i], button[title*="Manage" i]',
      save: 'button.sp_choice_type_SAVE_AND_EXIT, button[title*="Speichern" i], button[title*="Save" i]' },
    { n: 'didomi', sel: ['#didomi-notice-disagree-button', '.didomi-continue-without-agreeing', 'button.didomi-components-button--disagree'],
      js: function () { if (window.Didomi && typeof Didomi.setUserDisagreeToAll === 'function' && firstVisible('#didomi-host,.didomi-popup-container,#didomi-notice')) { Didomi.setUserDisagreeToAll(); return true; } return false; } },
    { n: 'quantcast', sel: ['.qc-cmp2-summary-buttons button[mode=secondary][class*=reject i]', '.qc-cmp2-footer button[mode=secondary]', 'button.qc-cmp2-reject-all'],
      settings: '.qc-cmp2-summary-buttons button[mode=secondary]', save: '.qc-cmp2-footer button[mode=primary], button[class*=save i]' },
    { n: 'funding-choices', sel: ['.fc-cta-do-not-consent', '.fc-consent-root .fc-secondary-button.fc-cta-do-not-consent'],
      settings: '.fc-cta-manage-options', save: '.fc-confirm-choices' },
    { n: 'cookiebot', sel: ['#CybotCookiebotDialogBodyButtonDecline', '#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll', '#CybotCookiebotDialogBodyLevelButtonDecline'],
      settings: '#CybotCookiebotDialogBodyLevelButtonCustomize', save: '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowallSelection' },
    { n: 'trustarc', sel: ['#truste-consent-required', 'a.rejectAll', 'button.rejectAll', '.pdynamicbutton .required'],
      settings: '#truste-show-consent, .truste-show-consent, a.show_preferences', save: 'a.submit, button.submit' },
    { n: 'consentmanager', sel: ['.cmpboxbtnno', '#cmpwelcomebtnno .cmpboxbtn', '.cmpboxbtnreject'],
      js: function () { if (typeof window.__cmp === 'function' && firstVisible('#cmpbox,#cmpbox2,.cmpwrapper')) { window.__cmp('setConsent', 0); return true; } return false; } },
    { n: 'borlabs', sel: ['._brlbs-refuse-btn a', '._brlbs-refuse-btn', '.brlbs-btn-accept-only-essential', '[data-cookie-refuse]', '#CookieBoxRejectAllButton'] },
    { n: 'klaro', sel: ['.klaro button.cn-decline', '.cookie-modal button.cn-decline', '.klaro .cm-btn-decline'] },
    { n: 'cookieyes', sel: ['.cky-btn-reject', '[data-cky-tag=reject-button]'] },
    { n: 'complianz', sel: ['.cmplz-deny', 'button.cmplz-btn.cmplz-deny'] },
    { n: 'cookie-law-info', sel: ['#cookie_action_close_header_reject', '.wt-cli-reject-btn', '#wt-cli-reject-btn'] },
    { n: 'iubenda', sel: ['.iubenda-cs-reject-btn'] },
    { n: 'termly', sel: ['[data-tid=banner-decline]'] },
    { n: 'google', sel: ['#W0wltc', 'button[aria-label="Alle ablehnen" i]', 'button[aria-label="Reject all" i]'], js: googleConsent }
  ];

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

  function done(cmp, action) {
    if (finished) { return true; }
    finished = true;
    post(cmp, action);
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

  // ---------- Abwählen über die Einstellungen ----------
  function uncheckAll(scopeCheck) {
    var n = 0;
    deepAll('input[type=checkbox],[role=switch],[role=checkbox]').forEach(function (el) {
      try {
        var on = el.checked === true || el.getAttribute('aria-checked') === 'true';
        if (!on || el.disabled || el.getAttribute('aria-disabled') === 'true') { return; }
        if (!scopeCheck(el)) { return; }
        var t = norm(label(el.closest ? (el.closest('label') || el) : el));
        if (/notwendig|erforderlich|essential|necessary|required|technisch/.test(t)) { return; }
        if (click(el)) { n++; }
      } catch (e) {}
    });
    return n;
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
      try { if (c.js && c.js()) { return done(c.n, 'reject-api'); } } catch (e) {}
      el = trySelectors(c.sel || []);
      if (el && click(el)) { return done(c.n, 'reject'); }
    }
    // 2) Generisch: Button mit Ablehn-Text in einem Banner-Element
    var cands = candidates(), walls = 0, settingsBtn = null;
    for (i = 0; i < cands.length; i++) {
      el = cands[i];
      if (!vis(el) || isAccept(el)) { continue; }
      var t = label(el);
      if (isRejectText(t) && safeLink(el) && inBanner(el)) {
        if (click(el)) { return done('generic', 'reject'); }
      }
      var nt = norm(t);
      if (BAD.test(nt) && nt.length < 60 && inBanner(el)) { walls++; }
      if (!settingsBtn && SETTINGS.test(nt) && safeLink(el) && inBanner(el)) { settingsBtn = el; }
    }
    if (walls > 0 && !wallLocal) {
      wallLocal = true;
      if (!TOP) { try { parent.postMessage({ __bcPur: 1 }, '*'); } catch (e) {} }
    }
    // 3) Einstellungen öffnen, dort ablehnen bzw. alles abwählen und speichern
    if (settingsClicks === 0) {
      var known = null;
      for (i = 0; i < CMPS.length && !known; i++) { if (CMPS[i].settings) { known = trySelectors([CMPS[i].settings]); } }
      var opener = known || settingsBtn;
      if (opener && vis(opener) && (Date.now() - started) > 1200 && click(opener)) {
        settingsClicks++; settingsAt = Date.now(); post('settings', 'open'); return;
      }
    } else if (saveTries < 2 && Date.now() - settingsAt > 1200) {
      var unticked = uncheckAll(function (x) { return inBanner(x); });
      var saveBtn = null;
      for (i = 0; i < CMPS.length && !saveBtn; i++) { if (CMPS[i].save) { saveBtn = trySelectors([CMPS[i].save]); } }
      if (!saveBtn) {
        for (i = 0; i < cands.length; i++) {
          if (vis(cands[i]) && !isAccept(cands[i]) && SAVE.test(norm(label(cands[i]))) && inBanner(cands[i])) { saveBtn = cands[i]; break; }
        }
      }
      saveTries++;
      if (saveBtn && click(saveBtn)) { return done('settings', 'save-' + unticked + '-off'); }
    }
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
