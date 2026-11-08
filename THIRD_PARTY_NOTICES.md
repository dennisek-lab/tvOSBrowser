# Drittanbieter-Hinweise

## @duckduckgo/autoconsent 18.1.0

- Zweck: automatisches Ablehnen von Cookie-Bannern (fest auf „optOut“ konfiguriert, nie Zustimmen).
- Quelle: https://github.com/duckduckgo/autoconsent (npm: https://www.npmjs.com/package/@duckduckgo/autoconsent)
- Lizenz: Mozilla Public License 2.0, Text in `_Project/Browser/Autoconsent/LICENSE-MPL-2.0.txt`
- Beigelegt: `_Project/Browser/Autoconsent/autoconsent.standalone.js` (`dist/autoconsent.standalone.js` aus dem npm-Paket,
  unverändert, enthält die kompakten Regeln `rules/compact-rules.json`). Der MPL-Quellcode steht im oben genannten Repository.
- `_Project/Browser/Autoconsent/bridge.js` ist eine eigene, kleine Datei der App und kein Teil von autoconsent.

## @mozilla/readability 0.6.0

- Zweck: Reader-Modus (Erkennung lesbarer Seiten mit `isProbablyReaderable`, Extraktion des Artikels).
- Quelle: https://github.com/mozilla/readability (npm: https://www.npmjs.com/package/@mozilla/readability)
- Lizenz: Apache License 2.0, Text in `_Project/Browser/Reader/LICENSE.md`
- Beigelegt: `_Project/Browser/Reader/Readability.js` und `Readability-readerable.js` (aus dem npm-Paket, unverändert).
- `_Project/Browser/Reader/reader.js` ist eine eigene, kleine Datei der App und kein Teil von Readability.

## Zeigerbilder (SF Symbols, optionaler Stil)

- Der Zeigerstil „SF Symbols“ (`BrowserCursorRenderer`, Einstellung `CursorStyle` = 2) nutzt die Systemsymbole `cursorarrow` und `hand.point.up.left.fill` zur Laufzeit; Nutzung in Apps auf Apple-Plattformen laut SF-Symbols-Lizenz erlaubt. Die Standardzeiger sind eigene Vektorzeichnungen, kein Material von Apple oder Dritten.
