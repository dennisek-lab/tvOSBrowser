# Drittanbieter-Hinweise

## @duckduckgo/autoconsent 18.1.0

- Zweck: automatisches Ablehnen von Cookie-Bannern (fest auf „optOut“ konfiguriert, nie Zustimmen).
- Quelle: https://github.com/duckduckgo/autoconsent (npm: https://www.npmjs.com/package/@duckduckgo/autoconsent)
- Lizenz: Mozilla Public License 2.0, Text in `_Project/Browser/Autoconsent/LICENSE-MPL-2.0.txt`
- Beigelegt: `_Project/Browser/Autoconsent/autoconsent.standalone.js` (`dist/autoconsent.standalone.js` aus dem npm-Paket,
  unverändert, enthält die kompakten Regeln `rules/compact-rules.json`). Der MPL-Quellcode steht im oben genannten Repository.
- `_Project/Browser/Autoconsent/bridge.js` ist eine eigene, kleine Datei der App und kein Teil von autoconsent.
