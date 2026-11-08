// Eigene Umsetzung von uBOs trusted-prevent-dom-bypass(methodPath, targetProp) im Aufrufformat der AdGuard-corelibs
// (source, args). Seiten wie YouTube hängen ein leeres iframe an und holen sich daraus ein unverändertes fetch/Request,
// um Scriptlets zu umgehen. Nach dem Anhängen wird die Eigenschaft im iframe durch die (umgebogene) der Seite ersetzt.
function trustedPreventDomBypass(source, args) {
    var methodPath = args && args[0] ? String(args[0]) : '';
    var targetProp = args && args[1] ? String(args[1]) : '';
    if (!methodPath) {
        return;
    }
    var parts = methodPath.split('.');
    var owner = window;
    for (var i = 0; i < parts.length - 1; i++) {
        owner = owner[parts[i]];
        if (!owner) {
            return;
        }
    }
    var name = parts[parts.length - 1];
    var original = owner[name];
    if (typeof original !== 'function') {
        return;
    }
    owner[name] = new Proxy(original, {
        apply: function (target, thisArg, callArgs) {
            var result = Reflect.apply(target, thisArg, callArgs);
            for (var k = 0; k < callArgs.length; k++) {
                var elem = callArgs[k];
                if (!(elem instanceof HTMLElement)) {
                    continue;
                }
                try {
                    var cw = elem.contentWindow;
                    if (String(cw) !== '[object Window]') {
                        continue;
                    }
                    var href = cw.location.href;
                    if (href !== 'about:blank' && href !== window.location.href) {
                        continue;
                    }
                    if (targetProp) {
                        var chain = targetProp.split('.');
                        var me = window;
                        var it = cw;
                        for (var j = 0; j < chain.length - 1; j++) {
                            me = me[chain[j]];
                            it = it[chain[j]];
                        }
                        it[chain[chain.length - 1]] = me[chain[chain.length - 1]];
                    } else {
                        Object.defineProperty(elem, 'contentWindow', { value: window });
                    }
                } catch (e) {
                    // fremde Herkunft oder schreibgeschützt: nichts tun
                }
            }
            return result;
        }
    });
}
