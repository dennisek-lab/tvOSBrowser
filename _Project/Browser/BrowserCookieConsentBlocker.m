#import "BrowserCookieConsentBlocker.h"
#import "BrowserPreferencesStore.h"

#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kConsentMessageName = @"browserConsent";
static NSString * const kStateActiveKey = @"active";
static NSString * const kStateExceptionKey = @"exception";
static NSString * const kStateScriptKey = @"script";

/// Empfängt die Meldungen {cmp, action, host, top} des Skripts.
@interface BrowserCookieConsentMessageProxy : NSObject
@property (nonatomic, weak) BrowserCookieConsentBlocker *blocker;
@end

@interface BrowserCookieConsentBlocker ()
@property (nonatomic, readwrite) NSUInteger handledCount;
/// Controller (schwach) -> @{active, exception, script}
@property (nonatomic, strong) NSMapTable<id, NSDictionary *> *controllerStates;
@property (nonatomic, strong) NSMutableArray *proxies;
- (void)handleMessageBody:(id)body;
@end

@implementation BrowserCookieConsentMessageProxy
- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    (void)controller;
    id body = [message respondsToSelector:@selector(body)] ? ((id (*)(id, SEL))objc_msgSend)(message, @selector(body)) : nil;
    [self.blocker handleMessageBody:body];
}
@end

/// Quelle: tools/cookie_consent.js (mit tools/embed_cookie_script.py hier eingebettet).
static NSString *BrowserCookieConsentScript(void) {
// BEGIN-COOKIE-SCRIPT
    return
    @"// Cookie-Banner-Ablehner. Quelle fürs eingebettete Skript in BrowserCookieConsentBlocker.m\n"
    @"// (Neu erzeugen: python3 tools/embed_cookie_script.py). Läuft in jedem Frame (document-end).\n"
    @"(function () {\n"
    @"  'use strict';\n"
    @"  if (window.__browserConsentOff || window.__browserConsent) { return; }\n"
    @"  window.__browserConsent = 1;\n"
    @"  var TOP = (window === window.top);\n"
    @"  function hostName() {\n"
    @"    if (location.hostname) { return location.hostname; }\n"
    @"    try { if (window.top.location.hostname) { return window.top.location.hostname; } } catch (e) {}\n"
    @"    try { if (window.parent.location.hostname) { return window.parent.location.hostname; } } catch (e) {}\n"
    @"    return 'about:blank';\n"
    @"  }\n"
    @"  var HOST = hostName();\n"
    @"  var finished = false, started = Date.now();\n"
    @"  var purSeen = false, wallLocal = false, scheduled = false, observer = null, timers = [];\n"
    @"  function post(cmp, action, detail) {\n"
    @"    try { webkit.messageHandlers.browserConsent.postMessage({ cmp: cmp, action: action, host: HOST, top: TOP, detail: detail || '' }); } catch (e) {}\n"
    @"  }\n"
    @"  var lastClicked = '';\n"
    @"  function describe(el) {\n"
    @"    var t = '';\n"
    @"    try { t = (el.innerText || el.textContent || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || '') + ''; } catch (e) {}\n"
    @"    t = t.replace(/\\s+/g, ' ').trim().slice(0, 40);\n"
    @"    var c = '';\n"
    @"    try { c = typeof el.className === 'string' ? el.className.trim().split(/\\s+/).slice(0, 3).join('.') : ''; } catch (e) {}\n"
    @"    var id = ''; try { id = el.id ? '#' + el.id : ''; } catch (e) {}\n"
    @"    return 'clicked: \"' + t + '\" ' + String(el.tagName || '').toLowerCase() + id + (c ? '.' + c : '');\n"
    @"  }\n"
    @"  // ---------- Hilfsfunktionen ----------\n"
    @"  function norm(s) {\n"
    @"    return String(s || '').toLowerCase().replace(/[ \\s]+/g, ' ').replace(/[»›«‹→…!.:]+/g, ' ').replace(/\\s+/g, ' ').trim();\n"
    @"  }\n"
    @"  function label(el) {\n"
    @"    var t = '';\n"
    @"    try { t = (el.innerText || el.textContent || el.value || '') + ''; } catch (e) {}\n"
    @"    if (!t.trim()) { t = (el.getAttribute('aria-label') || el.getAttribute('title') || '') + ''; }\n"
    @"    return t;\n"
    @"  }\n"
    @"  function vis(el, strict) {\n"
    @"    try {\n"
    @"      var r = el.getBoundingClientRect();\n"
    @"      if (r.width < 4 || r.height < 4) { return false; }\n"
    @"      var w = (el.ownerDocument && el.ownerDocument.defaultView) || window;\n"
    @"      var s = w.getComputedStyle(el);\n"
    @"      if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse' || parseFloat(s.opacity) < 0.05) { return false; }\n"
    @"      if (strict) {\n"
    @"        // Mitte des Elements muss im Viewport liegen und nicht von einem fremden Element verdeckt sein.\n"
    @"        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;\n"
    @"        if (cx < 0 || cy < 0 || cx > w.innerWidth || cy > w.innerHeight) { return false; }\n"
    @"        var top = el.ownerDocument.elementFromPoint(cx, cy);\n"
    @"        if (!top) { return false; }\n"
    @"        if (top !== el && !el.contains(top) && !(top.contains && top.contains(el))) {\n"
    @"          var root = el.getRootNode && el.getRootNode();\n"
    @"          if (!(root && root.host && (top === root.host || root.host.contains(top)))) { return false; }\n"
    @"        }\n"
    @"      }\n"
    @"      return true;\n"
    @"    } catch (e) { return false; }\n"
    @"  }\n"
    @"  // Akzeptier-Buttons bekannter CMPs: werden unter keinen Umständen angeklickt.\n"
    @"  var ACCEPT_SEL = '.fc-cta-consent,#onetrust-accept-btn-handler,#didomi-notice-agree-button,[data-testid=uc-accept-all-button],' +\n"
    @"    '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll,#CybotCookiebotDialogBodyButtonAccept,#truste-consent-button,#L2AGLb,.cky-btn-accept,.cmplz-accept';\n"
    @"  function isAccept(el) { try { return !!(el.matches && el.matches(ACCEPT_SEL)); } catch (e) { return false; } }\n"
    @"  // Alle Elemente zu einem Selektor, auch in offenen Shadow-DOMs (Usercentrics u. a.).\n"
    @"  function deepAll(sel, root, out, budget) {\n"
    @"    out = out || []; root = root || document; budget = budget || { n: 6000 };\n"
    @"    try { var found = root.querySelectorAll(sel); for (var i = 0; i < found.length; i++) { out.push(found[i]); } } catch (e) {}\n"
    @"    var all; try { all = root.querySelectorAll('*'); } catch (e) { return out; }\n"
    @"    for (var j = 0; j < all.length && budget.n-- > 0; j++) {\n"
    @"      if (all[j].shadowRoot) { deepAll(sel, all[j].shadowRoot, out, budget); }\n"
    @"    }\n"
    @"    return out;\n"
    @"  }\n"
    @"  function firstVisible(sel) {\n"
    @"    var els = deepAll(sel);\n"
    @"    for (var i = 0; i < els.length; i++) { if (vis(els[i])) { return els[i]; } }\n"
    @"    return null;\n"
    @"  }\n"
    @"  function click(el) {\n"
    @"    if (isAccept(el)) { return false; }\n"
    @"    try {\n"
    @"      var w = (el.ownerDocument && el.ownerDocument.defaultView) || window;\n"
    @"      el.scrollIntoView && el.scrollIntoView({ block: 'nearest' });\n"
    @"      var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;\n"
    @"      lastClicked = describe(el);\n"
    @"      ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (t) {\n"
    @"        var init = { bubbles: true, cancelable: true, view: w, clientX: x, clientY: y, button: 0, buttons: t.indexOf('down') > 0 ? 1 : 0 };\n"
    @"        try {\n"
    @"          var ev = (t.indexOf('pointer') === 0 && w.PointerEvent) ? new w.PointerEvent(t, init) : new w.MouseEvent(t, init);\n"
    @"          el.dispatchEvent(ev);\n"
    @"        } catch (e) {}\n"
    @"      });\n"
    @"      if (typeof el.click === 'function') { el.click(); }\n"
    @"      return true;\n"
    @"    } catch (e) { return false; }\n"
    @"  }\n"
    @"  // ---------- Texterkennung ----------\n"
    @"  var REJECT = [\n"
    @"    /^(alle |alles )?(optionalen |nicht notwendigen? |nicht erforderlichen? |unnötigen? )?(cookies )?(ablehnen|verweigern)$/,\n"
    @"    /^(alle |alles )?(cookies )?ablehnen (und|&) (schließen|weiter|fortfahren)$/,\n"
    @"    /^nur (notwendige|erforderliche|essenzielle|essentielle|technisch notwendige|technisch erforderliche|funktionale|wesentliche)( cookies| technologien)?( akzeptieren| zulassen| erlauben| speichern| verwenden)?$/,\n"
    @"    /^(notwendige|erforderliche|essenzielle|essentielle)( cookies)?( akzeptieren| zulassen| erlauben)?$/,\n"
    @"    /^(weiter|fortfahren) ohne (einwilligung|zustimmung|akzeptieren|tracking|zustimmen)$/,\n"
    @"    /^ohne (einwilligung|zustimmung|akzeptieren) (weiter|fortfahren|lesen)$/,\n"
    @"    /^(nicht einverstanden|ich lehne ab|ich stimme nicht zu|nicht zustimmen)$/,\n"
    @"    /^(reject|decline|deny|refuse|disagree)( all| everything)?( non-?essential| optional| unnecessary| additional)?( cookies)?$/,\n"
    @"    /^(only|use only|accept only|allow only) (necessary|essential|required|strictly necessary)( cookies)?( only)?$/,\n"
    @"    /^(necessary|essential|required|strictly necessary) (cookies )?only$/,\n"
    @"    /^continue without (accepting|agreeing|consent|tracking)$/,\n"
    @"    /^(i )?(do not|don't) (accept|consent|agree)$/,\n"
    @"    /^(i )?(decline|disagree|reject)$/,\n"
    @"    /^(tout )?refuser( tout)?( et continuer)?$/,\n"
    @"    /^continuer sans accepter$/,\n"
    @"    /^rechazar( todo| todas| todas las cookies)?$/,\n"
    @"    /^rifiuta( tutto| tutti)?$/\n"
    @"  ];\n"
    @"  // Bezahl-/Abo-Texte: nie anklicken\n"
    @"  var BAD = /(\\babo\\b|abonn|subscri|\\bpur\\b|pur-|€|\\bmonat|kostenpflichtig|bezahl|jetzt kaufen|premium|\\bplus\\b)/;\n"
    @"  var COOKIEWORDS = /cookie|datenschutz|privacy|consent|einwilligung|tracking|cmp|gdpr|dsgvo/i;\n"
    @"  var CTX = /cookie|consent|gdpr|dsgvo|privacy|datenschutz|cmp|didomi|onetrust|ot-sdk|cybot|usercentrics|sp_message|sp-message|qc-cmp|truste|trustarc|borlabs|brlbs|klaro|cky|cmplz|einwilligung|fc-/i;\n"
    @"  function matchesAny(list, t) { for (var i = 0; i < list.length; i++) { if (list[i].test(t)) { return true; } } return false; }\n"
    @"  function isRejectText(t) { t = norm(t); return t.length > 0 && t.length < 60 && !BAD.test(t) && matchesAny(REJECT, t); }\n"
    @"  // Ist das Dokument selbst ein CMP-Frame?\n"
    @"  function docIsCmp() {\n"
    @"    if (/^consent\\./.test(HOST)) { return true; }\n"
    @"    if (TOP) { return false; }\n"
    @"    var s = location.href + ' ' + document.title + ' ' + ((document.body && document.body.innerText) || '').slice(0, 1500);\n"
    @"    return COOKIEWORDS.test(s);\n"
    @"  }\n"
    @"  function inBanner(el) {\n"
    @"    if (docIsCmp()) { return true; }\n"
    @"    var n = el;\n"
    @"    for (var i = 0; n && i < 12; i++) {\n"
    @"      if (n.nodeType !== 1) { n = n.host || n.parentNode; continue; }\n"
    @"      var cls = typeof n.className === 'string' ? n.className : '';\n"
    @"      var meta = (n.id || '') + ' ' + cls + ' ' + (n.getAttribute('aria-label') || '') + ' ' + (n.getAttribute('data-testid') || '');\n"
    @"      if (CTX.test(meta)) { return true; }\n"
    @"      var role = n.getAttribute('role');\n"
    @"      var cs = getComputedStyle(n);\n"
    @"      var z = parseInt(cs.zIndex, 10);\n"
    @"      var overlay = (cs.position === 'fixed' || cs.position === 'sticky' || cs.position === 'absolute') && z >= 100;\n"
    @"      if (overlay || role === 'dialog' || role === 'alertdialog') {\n"
    @"        var tx = ''; try { tx = (n.innerText || '').slice(0, 2500); } catch (e) {}\n"
    @"        if (/cookie|datenschutz|privacy|einwilligung|consent|tracking/i.test(tx)) { return true; }\n"
    @"      }\n"
    @"      n = n.parentElement || n.getRootNode().host;\n"
    @"    }\n"
    @"    return false;\n"
    @"  }\n"
    @"  function candidates() {\n"
    @"    return deepAll('button,a,[role=button],input[type=button],input[type=submit],[class*=btn],[class*=button],[tabindex=\"0\"]');\n"
    @"  }\n"
    @"  function safeLink(el) {\n"
    @"    if (el.tagName !== 'A') { return true; }\n"
    @"    var h = el.getAttribute('href');\n"
    @"    return !h || h === '#' || /^javascript:/i.test(h) || /consent|cookie|reject|decline|optout|opt-out|ablehn/i.test(h);\n"
    @"  }\n"
    @"  // ---------- Bekannte CMPs ----------\n"
    @"  // Je Eintrag: Name, Selektoren für „Ablehnen“, optionaler JS-Aufruf. Reihenfolge = Priorität.\n"
    @"  var CMPS = [\n"
    @"    { n: 'onetrust', sel: ['#onetrust-reject-all-handler', '.ot-pc-refuse-all-handler', 'button.ot-bnr-reject-all'],\n"
    @"      js: function () { if (window.OneTrust && typeof OneTrust.RejectAll === 'function' && firstVisible('#onetrust-banner-sdk,#onetrust-pc-sdk')) { OneTrust.RejectAll(); return true; } return false; } },\n"
    @"    { n: 'usercentrics', sel: ['[data-testid=uc-deny-all-button]', 'button#deny', '.uc-deny-all-button'],\n"
    @"      js: function () { if (window.UC_UI && typeof UC_UI.denyAllConsents === 'function' && UC_UI.isInitialized && UC_UI.isInitialized() && firstVisible('#usercentrics-root')) { var p = UC_UI.denyAllConsents(); try { p.then(function () { UC_UI.closeCMP(); }); } catch (e) {} return true; } return false; } },\n"
    @"    { n: 'sourcepoint', sel: ['button.sp_choice_type_13', 'button.sp_choice_type_REJECT_ALL', 'button[title=\"Alle ablehnen\" i]', 'button[title=\"Reject All\" i]', 'button[title=\"Ablehnen\" i]', 'button[title=\"Nur notwendige\" i]'] },\n"
    @"    { n: 'didomi', sel: ['#didomi-notice-disagree-button', '.didomi-continue-without-agreeing', 'button.didomi-components-button--disagree'],\n"
    @"      js: function () { if (window.Didomi && typeof Didomi.setUserDisagreeToAll === 'function' && firstVisible('#didomi-host,.didomi-popup-container,#didomi-notice')) { Didomi.setUserDisagreeToAll(); return true; } return false; } },\n"
    @"    { n: 'quantcast', sel: ['.qc-cmp2-summary-buttons button[mode=secondary][class*=reject i]', '.qc-cmp2-footer button[mode=secondary]', 'button.qc-cmp2-reject-all'] },\n"
    @"    { n: 'funding-choices', sel: ['.fc-cta-do-not-consent', '.fc-consent-root .fc-secondary-button.fc-cta-do-not-consent'] },\n"
    @"    { n: 'cookiebot', sel: ['#CybotCookiebotDialogBodyButtonDecline', '#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll', '#CybotCookiebotDialogBodyLevelButtonDecline'] },\n"
    @"    { n: 'trustarc', sel: ['#truste-consent-required', 'a.rejectAll', 'button.rejectAll', '.pdynamicbutton .required'] },\n"
    @"    { n: 'consentmanager', sel: ['.cmpboxbtnno', '#cmpwelcomebtnno .cmpboxbtn', '.cmpboxbtnreject'],\n"
    @"      js: function () { if (typeof window.__cmp === 'function' && firstVisible('#cmpbox,#cmpbox2,.cmpwrapper')) { window.__cmp('setConsent', 0); return true; } return false; } },\n"
    @"    { n: 'borlabs', sel: ['._brlbs-refuse-btn a', '._brlbs-refuse-btn', '.brlbs-btn-accept-only-essential', '[data-cookie-refuse]', '#CookieBoxRejectAllButton'] },\n"
    @"    { n: 'klaro', sel: ['.klaro button.cn-decline', '.cookie-modal button.cn-decline', '.klaro .cm-btn-decline'] },\n"
    @"    { n: 'cookieyes', sel: ['.cky-btn-reject', '[data-cky-tag=reject-button]'] },\n"
    @"    { n: 'complianz', sel: ['.cmplz-deny', 'button.cmplz-btn.cmplz-deny'] },\n"
    @"    { n: 'cookie-law-info', sel: ['#cookie_action_close_header_reject', '.wt-cli-reject-btn', '#wt-cli-reject-btn'] },\n"
    @"    { n: 'iubenda', sel: ['.iubenda-cs-reject-btn'] },\n"
    @"    { n: 'termly', sel: ['[data-tid=banner-decline]'] },\n"
    @"    { n: 'fastcmp', js: fastCmp },\n"
    @"    { n: 'google', sel: ['#W0wltc', 'button[aria-label=\"Alle ablehnen\" i]', 'button[aria-label=\"Reject all\" i]'], js: googleConsent }\n"
    @"  ];\n"
    @"  // FastCMP (w3schools u. a.): same-origin iframe#fast-cmp-iframe ohne src. Eine verlässliche JS-API ist nicht bekannt,\n"
    @"  // daher wird der „Ablehnen“-Knopf im iframe-Dokument angeklickt (vom Hauptframe aus oder im iframe selbst).\n"
    @"  // FastCMP verdrahtet seine Knöpfe erst kurz nach dem Erscheinen: Ein zu früher Klick verpufft.\n"
    @"  // Deshalb erst klicken, wenn der Dialog seit 1,2 s sichtbar ist, und danach prüfen, ob er wirklich weg ist.\n"
    @"  var fastSeenAt = 0, fastTries = 0;\n"
    @"  function fastCmpVisible() {\n"
    @"    var fr = document.getElementById('fast-cmp-iframe');\n"
    @"    if (!fr) { return false; }\n"
    @"    var r = fr.getBoundingClientRect(), cs = getComputedStyle(fr);\n"
    @"    return r.width > 4 && r.height > 4 && cs.display !== 'none' && cs.visibility !== 'hidden';\n"
    @"  }\n"
    @"  function fastCmp() {\n"
    @"    var doc = null;\n"
    @"    try {\n"
    @"      var fr = document.getElementById('fast-cmp-iframe');\n"
    @"      if (fr && fr.contentDocument && fr.contentDocument.body) { doc = fr.contentDocument; }\n"
    @"    } catch (e) {}\n"
    @"    if (TOP && doc) {\n"
    @"      if (!fastCmpVisible()) { return false; }\n"
    @"      if (!fastSeenAt) { fastSeenAt = Date.now(); }\n"
    @"      if (Date.now() - fastSeenAt < 1200 || fastTries >= 4) { return false; }\n"
    @"    }\n"
    @"    if (!doc && !TOP && document.querySelector('.fast-cmp-home-refuse,.top-refuse-btn,.fast-cmp-button-secondary')) { doc = document; }\n"
    @"    if (!doc) { return false; }\n"
    @"    var sels = ['.fast-cmp-home-refuse', '.top-refuse-btn', '.fast-cmp-button-secondary'];\n"
    @"    for (var i = 0; i < sels.length; i++) {\n"
    @"      var els = doc.querySelectorAll(sels[i]);\n"
    @"      for (var j = 0; j < els.length; j++) {\n"
    @"        var el = els[j];\n"
    @"        if (!vis(el)) { continue; }\n"
    @"        var t = norm(label(el));\n"
    @"        if (t && !isRejectText(t) && !/^(refuse|ablehnen|reject|decline)/.test(t)) { continue; }\n"
    @"        if (TOP && doc !== document) {\n"
    @"          // Vom Hauptframe: klicken und nach 1 s nachsehen; ist der Dialog noch da, erneut versuchen.\n"
    @"          fastTries++;\n"
    @"          click(el);\n"
    @"          setTimeout(function () {\n"
    @"            if (!fastCmpVisible()) { done('fastcmp', 'reject', lastClicked) } else { schedule() }\n"
    @"          }, 1000);\n"
    @"          return false;\n"
    @"        }\n"
    @"        if (click(el)) { return true; }\n"
    @"      }\n"
    @"    }\n"
    @"    return false;\n"
    @"  }\n"
    @"  // consent.google.com / consent.youtube.com: das Formular mit set_eom=true ist „Alle ablehnen“.\n"
    @"  function googleConsent() {\n"
    @"    if (!/(^|\\.)(consent\\.(google|youtube)\\.|google\\.[a-z.]+$|youtube\\.com$)/.test(HOST)) { return false; }\n"
    @"    var forms = document.querySelectorAll('form[action*=\"consent\"]');\n"
    @"    for (var i = 0; i < forms.length; i++) {\n"
    @"      var f = forms[i];\n"
    @"      if (f.querySelector('input[name=set_eom][value=true]')) {\n"
    @"        var b = f.querySelector('button,input[type=submit]');\n"
    @"        if (b && vis(b)) { return click(b); }\n"
    @"      }\n"
    @"    }\n"
    @"    return false;\n"
    @"  }\n"
    @"  function done(cmp, action, detail) {\n"
    @"    if (finished) { return true; }\n"
    @"    finished = true;\n"
    @"    post(cmp, action, detail);\n"
    @"    if (observer) { observer.disconnect(); observer = null; }\n"
    @"    timers.forEach(clearTimeout);\n"
    @"    setTimeout(unlockScroll, 700); setTimeout(unlockScroll, 2500);\n"
    @"    return true;\n"
    @"  }\n"
    @"  // Nach erfolgreichem Ablehnen: von CMPs gesperrtes Scrollen wieder freigeben.\n"
    @"  function unlockScroll() {\n"
    @"    try {\n"
    @"      [document.documentElement, document.body].forEach(function (el) {\n"
    @"        if (!el) { return; }\n"
    @"        if (el.style.overflow === 'hidden' || el.style.overflowY === 'hidden') { el.style.overflow = ''; el.style.overflowY = ''; }\n"
    @"        if (el.style.position === 'fixed' && el === document.body) { el.style.position = ''; }\n"
    @"      });\n"
    @"    } catch (e) {}\n"
    @"  }\n"
    @"  function trySelectors(list) {\n"
    @"    for (var i = 0; i < list.length; i++) {\n"
    @"      var el = firstVisible(list[i]);\n"
    @"      if (el && !isAccept(el) && safeLink(el) && !BAD.test(norm(label(el)))) { return el; }\n"
    @"    }\n"
    @"    return null;\n"
    @"  }\n"
    @"  function attempt() {\n"
    @"    scheduled = false;\n"
    @"    if (finished || !document.body) { return; }\n"
    @"    var i, el;\n"
    @"    // 1) Gezielt: bekannte CMPs\n"
    @"    for (i = 0; i < CMPS.length; i++) {\n"
    @"      var c = CMPS[i];\n"
    @"      try { if (c.js && c.js()) { return done(c.n, 'reject-api', lastClicked); } } catch (e) {}\n"
    @"      el = trySelectors(c.sel || []);\n"
    @"      if (el && click(el)) { return done(c.n, 'reject', lastClicked); }\n"
    @"    }\n"
    @"    // 2) Generisch: nur eindeutig ablehnender Text, sichtbar (im Viewport, nicht verdeckt), in einem Banner.\n"
    @"    //    Einstellungen/„Mehr Optionen“ werden nie geöffnet; Pur-/Abo-Wände werden nicht angefasst.\n"
    @"    var cands = candidates(), walls = 0, rejectEl = null;\n"
    @"    for (i = 0; i < cands.length; i++) {\n"
    @"      el = cands[i];\n"
    @"      if (isAccept(el) || !vis(el)) { continue; }\n"
    @"      var t = label(el), nt = norm(t);\n"
    @"      if (BAD.test(nt) && nt.length < 60 && inBanner(el)) { walls++; }\n"
    @"      if (!rejectEl && isRejectText(t) && safeLink(el) && vis(el, true) && inBanner(el)) { rejectEl = el; }\n"
    @"    }\n"
    @"    if (walls > 0 && !wallLocal) {\n"
    @"      wallLocal = true;\n"
    @"      if (!TOP) { try { parent.postMessage({ __bcPur: 1 }, '*'); } catch (e) {} }\n"
    @"    }\n"
    @"    if (rejectEl && walls === 0 && click(rejectEl)) { return done('generic', 'reject', lastClicked); }\n"
    @"  }\n"
    @"  // ---------- Kosmetischer Rückfall ----------\n"
    @"  var OVERLAYS = ['#onetrust-consent-sdk', '#usercentrics-root', 'div[id^=sp_message_container]', 'iframe[id^=sp_message_iframe]', '#didomi-host',\n"
    @"    '.qc-cmp2-container', '#CybotCookiebotDialog', '#truste-consent-track', '#cmpbox', '#cmpbox2', '#BorlabsCookieBox', '.klaro', '.cky-consent-container',\n"
    @"    '.cmplz-cookiebanner', '#cmplz-cookiebanner-container', '#cookie-law-info-bar', '.cc-window', '#cookiescript_injected', '.cookie-consent-banner',\n"
    @"    '.fc-consent-root', '.fc-dialog-container'];\n"
    @"  var BACKDROPS = ['.onetrust-pc-dark-filter', '.cky-overlay', '.didomi-popup-backdrop', '.qc-cmp2-overlay', '#CybotCookiebotDialogBodyUnderlay', '.fc-dialog-overlay'];\n"
    @"  function cosmetic() {\n"
    @"    if (finished || !TOP || purSeen || wallLocal) { return; }\n"
    @"    var hidden = 0;\n"
    @"    OVERLAYS.concat(BACKDROPS).forEach(function (sel) {\n"
    @"      var els; try { els = document.querySelectorAll(sel); } catch (e) { return; }\n"
    @"      for (var i = 0; i < els.length; i++) {\n"
    @"        if (vis(els[i]) || sel.indexOf('iframe') === 0) { els[i].style.setProperty('display', 'none', 'important'); hidden++; }\n"
    @"      }\n"
    @"    });\n"
    @"    if (hidden > 0) {\n"
    @"      var st = document.createElement('style');\n"
    @"      st.textContent = 'html,body{overflow:auto !important;}';\n"
    @"      (document.head || document.documentElement).appendChild(st);\n"
    @"      unlockScroll();\n"
    @"      finished = true;\n"
    @"      post('cosmetic', 'hide');\n"
    @"    }\n"
    @"  }\n"
    @"  function schedule() {\n"
    @"    if (scheduled || finished) { return; }\n"
    @"    scheduled = true;\n"
    @"    setTimeout(attempt, 150);\n"
    @"  }\n"
    @"  // Meldung aus Kind-Frames (Pur-Abo-Wand erkannt): Banner nicht ausblenden.\n"
    @"  window.addEventListener('message', function (e) { try { if (e.data && e.data.__bcPur) { purSeen = true; } } catch (x) {} });\n"
    @"  // ---------- Start ----------\n"
    @"  attempt();\n"
    @"  if (finished) { return; }\n"
    @"  try {\n"
    @"    observer = new MutationObserver(schedule);\n"
    @"    observer.observe(document.documentElement, { childList: true, subtree: true });\n"
    @"  } catch (e) {}\n"
    @"  [300, 800, 1500, 2500, 4000, 6000, 8000].forEach(function (ms) { timers.push(setTimeout(attempt, ms)); });\n"
    @"  timers.push(setTimeout(function () {\n"
    @"    attempt();\n"
    @"    if (observer) { observer.disconnect(); observer = null; }\n"
    @"    cosmetic();\n"
    @"    finished = true;\n"
    @"  }, 10000));\n"
    @"})();\n";
// END-COOKIE-SCRIPT
}

@implementation BrowserCookieConsentBlocker

+ (instancetype)sharedBlocker {
    static BrowserCookieConsentBlocker *blocker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocker = [BrowserCookieConsentBlocker new];
    });
    return blocker;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _controllerStates = [NSMapTable weakToStrongObjectsMapTable];
        _proxies = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isEnabled {
    return [BrowserPreferencesStore new].cookieBannerBlockEnabled;
}

#pragma mark Ausnahmen pro Seite

+ (NSString *)exceptionKeyForURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if ([host hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    return host.length > 0 ? host : nil;
}

static BOOL BrowserConsentHostMatches(NSString *host, NSString *entry) {
    return [host isEqualToString:entry] || [host hasSuffix:[@"." stringByAppendingString:entry]];
}

- (BOOL)isExceptionForURL:(NSURL *)url {
    NSString *key = [BrowserCookieConsentBlocker exceptionKeyForURL:url];
    if (key == nil) {
        return NO;
    }
    for (NSString *entry in [BrowserPreferencesStore new].cookieBannerExceptionHosts) {
        if (BrowserConsentHostMatches(key, entry)) {
            return YES;
        }
    }
    return NO;
}

- (void)setException:(BOOL)exception forURL:(NSURL *)url {
    NSString *key = [BrowserCookieConsentBlocker exceptionKeyForURL:url];
    if (key == nil) {
        return;
    }
    BrowserPreferencesStore *store = [BrowserPreferencesStore new];
    NSMutableArray<NSString *> *hosts = [store.cookieBannerExceptionHosts mutableCopy];
    if (exception) {
        if (![hosts containsObject:key]) {
            [hosts addObject:key];
        }
    } else {
        for (NSString *entry in [hosts copy]) {
            if (BrowserConsentHostMatches(key, entry)) {
                [hosts removeObject:entry];
            }
        }
    }
    store.cookieBannerExceptionHosts = hosts;
}

#pragma mark Skript ein-/ausbauen

- (id)makeUserScript {
    Class scriptClass = NSClassFromString(@"WKUserScript");
    SEL scriptInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (scriptClass == Nil || ![scriptClass instancesRespondToSelector:scriptInit]) {
        return nil;
    }
    id script = ((id (*)(id, SEL))objc_msgSend)((id)scriptClass, @selector(alloc));
    // injectionTime 1 = document-end, forMainFrameOnly NO: CMPs wie Sourcepoint laufen in fremden iframes.
    return ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(script, scriptInit, BrowserCookieConsentScript(), 1, NO);
}

/// Bringt den Controller in den gewünschten Zustand. removeAllUserScripts kennt kein Einzel-Entfernen, daher werden die
/// übrigen Skripte (Video-Hooks usw.) gemerkt und wieder angehängt.
- (void)refreshController:(id)controller exception:(BOOL)exception force:(BOOL)force {
    SEL addScript = NSSelectorFromString(@"addUserScript:");
    SEL removeAll = NSSelectorFromString(@"removeAllUserScripts");
    SEL scriptsGetter = NSSelectorFromString(@"userScripts");
    if (![controller respondsToSelector:addScript] || ![controller respondsToSelector:removeAll] ||
        ![controller respondsToSelector:scriptsGetter]) {
        return;
    }
    BOOL active = self.enabled && !exception;
    NSDictionary *current = [self.controllerStates objectForKey:controller];
    id oldScript = current[kStateScriptKey];
    if (oldScript == NSNull.null) {
        oldScript = nil;
    }
    if (!force && current != nil && [current[kStateActiveKey] boolValue] == active) {
        return;
    }
    id newScript = active ? [self makeUserScript] : nil;
    if (oldScript != nil || newScript != nil) {
        NSArray *scripts = [((NSArray *(*)(id, SEL))objc_msgSend)(controller, scriptsGetter) copy];
        ((void (*)(id, SEL))objc_msgSend)(controller, removeAll);
        for (id script in scripts) {
            if (script != oldScript) {
                ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, script);
            }
        }
        if (newScript != nil) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, newScript);
        }
    }
    [self.controllerStates setObject:@{kStateActiveKey: @(active), kStateExceptionKey: @(exception),
                                       kStateScriptKey: newScript ?: NSNull.null} forKey:controller];
}

- (void)applyToUserContentController:(id)userContentController {
    if (userContentController == nil) {
        return;
    }
    SEL addHandler = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if ([self.controllerStates objectForKey:userContentController] == nil && [userContentController respondsToSelector:addHandler]) {
        Protocol *protocol = objc_getProtocol("WKScriptMessageHandler");
        if (protocol != NULL && !class_conformsToProtocol(BrowserCookieConsentMessageProxy.class, protocol)) {
            class_addProtocol(BrowserCookieConsentMessageProxy.class, protocol);
        }
        BrowserCookieConsentMessageProxy *proxy = [BrowserCookieConsentMessageProxy new];
        proxy.blocker = self;
        [self.proxies addObject:proxy];
        ((void (*)(id, SEL, id, id))objc_msgSend)(userContentController, addHandler, proxy, kConsentMessageName);
    }
    // Neue Tabs starten ohne Zielseite; eine Ausnahme greift mit der ersten Navigation.
    [self refreshController:userContentController exception:NO force:YES];
}

- (void)updateUserContentController:(id)userContentController forNavigationToURL:(NSURL *)url {
    if (userContentController == nil || [self.controllerStates objectForKey:userContentController] == nil) {
        return;
    }
    [self refreshController:userContentController exception:[self isExceptionForURL:url] force:NO];
}

- (void)preferencesDidChange {
    for (id controller in self.controllerStates.keyEnumerator.allObjects) {
        BOOL exception = [[self.controllerStates objectForKey:controller][kStateExceptionKey] boolValue];
        [self refreshController:controller exception:exception force:YES];
    }
}

#pragma mark Rückmeldung

- (void)handleMessageBody:(id)body {
    if (![body isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSString *action = [body[@"action"] isKindOfClass:NSString.class] ? body[@"action"] : @"";
    if (![action isEqualToString:@"open"]) {
        self.handledCount += 1;
    }
#if DEBUG
    NSLog(@"[CookieBlock] %@ %@ auf %@ (%@, gesamt %lu)", body[@"cmp"], action, body[@"host"],
          [body[@"top"] boolValue] ? @"Hauptframe" : @"iframe", (unsigned long)self.handledCount);
#endif
}

@end
