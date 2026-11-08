// Laufzeit der erweiterten Werbeblocker-Regeln (handgeschrieben, nicht von tools/build_scriptlets.py erzeugt).
// BrowserScriptletInjector ersetzt die Platzhalterzeile durch die Daten der aktuellen Seite:
//   T  Host -> {s: [Scriptlet-Indizes], c: [CSS-Indizes]} (nur die Hosts dieser Seite und ihrer Unterframes)
//   F  Scriptlet-Funktionen (AdGuard corelibs), N ihre Namen, R [Funktionsindex, Argumente]
//   C  [Text, prozedural 0/1, Pfadbedingung?], EC Fabrik für ExtendedCss oder null, V Bibliotheksversion, D Debug
// Läuft in jedem Frame (document-start, Seitenwelt) und wendet nur die Regeln für den eigenen Host an.
(function () {
    /*BROWSER_SCRIPTLET_DATA*/
    var host = location.hostname;
    if (!host) {
        try { host = window.parent.location.hostname; } catch (x) { host = ''; }
    }
    if (!host) {
        return;
    }
    var entry = T[host];
    if (!entry) {
        for (var key in T) {
            if (host.endsWith('.' + key) || key.endsWith('.' + host)) {
                entry = T[key];
                break;
            }
        }
    }
    if (!entry) {
        return;
    }
    var ran = 0;
    var failed = [];
    (entry.s || []).forEach(function (i) {
        var rule = R[i];
        try {
            F[rule[0]].call(window, { name: N[rule[0]], args: rule[1], engine: 'corelibs', version: V, verbose: false, ruleText: '' }, rule[1]);
            ran++;
        } catch (x) {
            failed.push(N[rule[0]] + ': ' + x);
        }
    });
    var info = { host: host, scriptlets: ran, failed: failed, css: 0, extended: 0, rejected: 0, error: '' };
    if (entry.c && entry.c.length) {
        info.css = applyCss(entry.c.map(function (i) { return C[i]; }));
    }
    if (D) {
        window.__browserScriptlets = info;
    }

    function pathMatches(p) {
        var path = location.pathname + location.search;
        var m = /^\/(.*)\/([a-z]*)$/.exec(p);
        if (m) {
            try { return new RegExp(m[1], m[2]).test(path); } catch (x) { return false; }
        }
        return path.indexOf(p) >= 0;
    }

    function whenReady(fn) {
        if (document.documentElement) {
            fn();
        } else {
            document.addEventListener('DOMContentLoaded', fn, { once: true });
        }
    }

    function applyCss(list) {
        var plain = [], ext = [];
        list.forEach(function (c) {
            if (c[2] && !pathMatches(c[2])) {
                return;
            }
            (c[1] ? ext : plain).push(c[0]);
        });
        if (plain.length) {
            var css = plain.map(function (s) { return s + '{display:none!important}'; }).join('\n');
            whenReady(function () {
                var style = document.createElement('style');
                style.textContent = css;
                (document.head || document.documentElement).appendChild(style);
            });
        }
        var applied = plain.length;
        if (ext.length && EC) {
            var X;
            try { X = EC(); } catch (x) { info.error = String(x); return applied; }
            if (D) {
                window.__browserExtendedCss = X;
            }
            var rules = [];
            ext.forEach(function (t) {
                var i = t.indexOf(' { ');
                var sel = i >= 0 ? t.slice(0, i) : t;
                try {
                    if (!X.validate(sel).ok) {
                        info.rejected++;
                        return;
                    }
                } catch (x) {
                    info.rejected++;
                    return;
                }
                rules.push(i >= 0 || /:remove(-attr|-class)?\(/.test(sel) ? t : t + ' { display: none !important; }');
            });
            if (rules.length) {
                applied += rules.length;
                info.extended = rules.length;
                whenReady(function () {
                    try { new X({ cssRules: rules }).apply(); } catch (x) { info.error = String(x); }
                });
            }
        }
        return applied;
    }
})();
