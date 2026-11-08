// Brücke zwischen DuckDuckGos autoconsent (autoconsent.standalone.js, unverändert) und der App.
// Läuft im selben Seitenkontext direkt nach dem Bundle. Das Standalone-Bundle trägt die Regeln selbst, entscheidet
// mit autoAction „optOut“ (Standardwert) allein und führt eval-Regeln im Seitenkontext (isMainWorld) aus; die App
// bekommt nur Lesemeldungen für das Log. Es wird nirgends zugestimmt.
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
})();
