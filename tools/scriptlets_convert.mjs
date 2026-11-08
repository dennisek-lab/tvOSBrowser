// Hilfsskript für tools/build_scriptlets.py (nicht direkt aufrufen).
// Liest von stdin ein JSON-Array mit Scriptlet-Regeln (uBO `##+js(...)`, AdGuard `#%#//scriptlet(...)`, ABP `#$#`)
// und gibt je Regel {ok, name, args} bzw. {ok:false, error} zurück. Wandelt mit dem Konverter von @adguard/scriptlets
// ins AdGuard-Format und prüft den Namen gegen die Bibliothek.
// Aufruf: node scriptlets_convert.mjs <Ordner mit node_modules>
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

const base = process.argv[2];
const pkg = path.join(base, 'node_modules', '@adguard', 'scriptlets', 'dist');
const C = await import(pathToFileURL(path.join(pkg, 'converters', 'index.js')).href);
const V = await import(pathToFileURL(path.join(pkg, 'validators', 'index.js')).href);

/** Argumente aus `//scriptlet('a', 'b')` lesen (AdGuard-Quoting: ' oder ", Escape mit Backslash). */
function parseAdgCall(text) {
    const marker = '//scriptlet(';
    const i = text.indexOf(marker);
    if (i < 0 || !text.endsWith(')')) {
        return null;
    }
    const body = text.slice(i + marker.length, -1);
    const out = [];
    let p = 0;
    while (p < body.length) {
        while (p < body.length && (body[p] === ' ' || body[p] === ',')) p++;
        if (p >= body.length) break;
        const q = body[p];
        if (q !== "'" && q !== '"') return null;
        p++;
        let s = '';
        while (p < body.length && body[p] !== q) {
            if (body[p] === '\\' && p + 1 < body.length) {
                if (body[p + 1] === q) { s += q; p += 2; continue; }
                s += body[p] + body[p + 1];
                p += 2;
                continue;
            }
            s += body[p++];
        }
        if (body[p] !== q) return null;
        p++;
        out.push(s);
    }
    return out.length ? out : null;
}

const rules = JSON.parse(fs.readFileSync(0, 'utf8'));
const result = rules.map((rule) => {
    try {
        let converted;
        if (V.isUboScriptletRule(rule)) {
            converted = C.convertUboToAdg(rule);
        } else if (V.isAbpSnippetRule(rule)) {
            converted = C.convertAbpToAdg(rule);
        } else {
            converted = [rule];
        }
        const out = [];
        for (const adg of converted) {
            if (!V.isValidScriptletRule(adg)) {
                return { ok: false, error: 'ungueltig: ' + adg.slice(adg.indexOf('//scriptlet(') + 12, adg.indexOf('//scriptlet(') + 60) };
            }
            const args = parseAdgCall(adg);
            if (!args) {
                return { ok: false, error: 'nicht lesbar' };
            }
            out.push({ name: args[0], args: args.slice(1) });
        }
        return { ok: true, calls: out };
    } catch (e) {
        return { ok: false, error: 'fehler: ' + String(e.message).slice(0, 60) };
    }
});
process.stdout.write(JSON.stringify(result));
