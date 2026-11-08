# Drittanbieter-Hinweise

## @duckduckgo/autoconsent 18.1.0

- Zweck: automatisches Ablehnen von Cookie-Bannern (fest auf „optOut“ konfiguriert, nie Zustimmen).
- Quelle: https://github.com/duckduckgo/autoconsent (npm: https://www.npmjs.com/package/@duckduckgo/autoconsent)
- Lizenz: Mozilla Public License 2.0, Text in `_Project/Browser/Autoconsent/LICENSE-MPL-2.0.txt`
- Beigelegt: `_Project/Browser/Autoconsent/autoconsent.standalone.js` (`dist/autoconsent.standalone.js` aus dem npm-Paket,
  unverändert, enthält die kompakten Regeln `rules/compact-rules.json`). Der MPL-Quellcode steht im oben genannten Repository.
- `_Project/Browser/Autoconsent/bridge.js` ist eine eigene, kleine Datei der App und kein Teil von autoconsent.

## @adguard/scriptlets 2.5.1

- Zweck: Scriptlet-Bibliothek für die erweiterten Werbeblocker-Regeln (`##+js(...)` aus den uBO-Listen), siehe `BrowserScriptletInjector`.
- Quelle: https://github.com/AdguardTeam/Scriptlets (npm: https://www.npmjs.com/package/@adguard/scriptlets)
- Lizenz: GNU General Public License 3.0, Text in `_Project/Browser/Scriptlets/LICENSE-GPL-3.0.txt`
- Beigelegt: die Funktionen aus `dist/scriptlets.corelibs.json` (unverändert), eingebettet in `_Project/Browser/Scriptlets/scriptlets.json.z`
  (von `tools/build_scriptlets.py` mit den Regeln zusammengepackt). Der Konverter des Pakets (uBO- nach AdGuard-Syntax) läuft nur
  beim Bauen auf dem Mac (`tools/scriptlets_convert.mjs`) und ist nicht in der App.

## @adguard/extended-css 2.3.0

- Zweck: prozedurale Kosmetikregeln (`:has-text`, `:upward`, `:xpath`, `:remove()` …) für die erweiterten Werbeblocker-Regeln.
- Quelle: https://github.com/AdguardTeam/ExtendedCss (npm: https://www.npmjs.com/package/@adguard/extended-css)
- Lizenz: GNU General Public License 3.0, Text in `_Project/Browser/Scriptlets/LICENSE-GPL-3.0.txt`
- Beigelegt: `_Project/Browser/Scriptlets/extended-css.min.js` (`dist/extended-css.min.js` aus dem npm-Paket, unverändert).

## Filterlisten (uBlock Origin, EasyList, EasyPrivacy, EasyList Germany, Peter Lowe, URLhaus)

- Zweck: Regeln für den Werbeblocker (`ContentBlocker/`) und die erweiterten Regeln (`Scriptlets/scriptlets.json.z`), umgewandelt
  von `tools/build_adblock_rules.py` und `tools/build_scriptlets.py`.
- Lizenzen: uBlock-Origin-Listen GPL-3.0, EasyList/EasyPrivacy/EasyList Germany GPL-3.0 bzw. CC BY-SA 3.0 (Doppellizenz),
  Peter Lowes Liste und URLhaus nach den Bedingungen der jeweiligen Anbieter.

Hinweis: Die GPL-3.0-Bestandteile verlangen bei Weitergabe der App die Weitergabe des Quelltexts unter GPL-3.0.
