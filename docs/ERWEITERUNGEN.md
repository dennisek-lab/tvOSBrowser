# Eigene Erweiterungen und Eigenbauten (Entwicklerdokumentation)

Zweck: Wenn nach einem Update von tvOS/WebKit oder einer Drittbibliothek (autoconsent, Filterlisten) etwas kaputtgeht, soll man hier schnell den passenden Baustein, die betroffenen Selektoren, das Symptom und den Test finden.

Stand: 8. November 2026, gegen den Code auf Commit `0f216e6` geprüft. Projektordner: `_Project/Browser/`, Werkzeuge: `tools/`, Plan und Historie: `PLAN.md`, Lizenzen: `THIRD_PARTY_NOTICES.md`.

Grundprinzip der App: WebKit ist **nicht gelinkt**. `BrowserWebView.m` lädt es per `dlopen` (`BrowserEnsureWebKitRuntimeLoaded`) und spricht alles über `NSClassFromString`/`NSSelectorFromString`/`objc_msgSend` an. Fehlt ein Selektor, passiert fast immer **nichts** (kein Absturz), die Funktion fällt still aus. Deshalb zählen die Logzeilen und der Selbsttest.

Menübeschriftungen ändern sich. Deshalb wird hier auf Methoden verwiesen (`extensionMenuItems`, `cookieBannerMenuItem`, `adBlockMenuItem` usw. in `BrowserMenuCoordinator.m`), nicht auf Menütexte.

## Inhalt

1. [Übersicht und Risiko](#1-übersicht-und-risiko)
2. [Checkliste nach einem tvOS-/WebKit-Update](#2-checkliste-nach-einem-tvos-webkit-update)
3. [WKWebView per Laufzeit](#3-wkwebview-per-laufzeit-browserwebview)
4. [Nutzerskripte und die userScripts-Falle](#4-nutzerskripte-und-die-userscripts-falle)
5. [Cookie-Ablehner (autoconsent) und Bezahlschranken](#5-cookie-ablehner-autoconsent-und-bezahlschranken)
6. [Werbeblocker](#6-werbeblocker-browsercontentblocker)
7. [Klickziele, Seitenfarbe, Glow-Farbe](#7-klickziele-seitenfarbe-glow-farbe-browserclicktargettracker)
8. [Fernbedienung](#8-fernbedienung-browserremoteinputcontroller)
9. [Obere Leiste](#9-obere-leiste-browsertopbarview) (mit 9.1 [Reader-Modus](#91-reader-modus-browserreadermode))
10. [Video: Hooks, nativer Player, Asset-Loader, YouTube](#10-video)
11. [DNS-Proxy (Cloudflare)](#11-dns-proxy-browserdnsproxy)
12. [Weitere Eingriffe in Systemklassen](#12-weitere-eingriffe-in-systemklassen)
13. [Start-/Verlaufsansicht, Bedienungsdialog, Tab-Übersicht](#13-start-und-verlaufsansicht-bedienungsdialog-tab-übersicht)
14. [Selbsttest und Gerätezyklus](#14-selbsttest-und-gerätezyklus)
15. [Alle Logpräfixe](#15-logpräfixe)
16. [Offen/unklar](#16-offenunklar)

---

## 1. Übersicht und Risiko

Risiko bei Updates: **hoch** = nutzt private/undokumentierte APIs oder Layout-Interna, bricht erfahrungsgemäß; **mittel** = öffentliche API mit Laufzeitzugriff oder Drittcode mit fester Schnittstelle; **niedrig** = reines UIKit/Foundation.

| Baustein | Dateien | Risiko |
|:--|:--|:--:|
| WKWebView per Laufzeit, private Prefs, Zoom, Insets, Rendering-Ereignisse, eigener Datenspeicher | `BrowserWebView.m/.h` | hoch |
| Nutzerskripte, `userScripts`-Handling | `BrowserCookieConsentBlocker.m` (`refreshController:…`), `BrowserWebView.m`, `BrowserClickTargetTracker.m` | hoch |
| Cookie-Ablehner (autoconsent) + Bezahlschranken | `BrowserCookieConsentBlocker.m/.h`, `Autoconsent/bridge.js`, `Autoconsent/autoconsent.standalone.js` | mittel (Drittcode) bis hoch (Brücke hängt an Interna des Bundles) |
| Werbeblocker | `BrowserContentBlocker.m/.h`, `ContentBlocker/*`, `tools/build_adblock_rules.py`, `tools/validate_adblock_rules.swift` | hoch (Store-Pfad, Regelformat) |
| Klickziele, Seitenfarbe, Glow-Farbe, Videomeldungen | `BrowserClickTargetTracker.m/.h` | mittel |
| Fernbedienung (GameController, Presses, Ring, Magnetic Buttons, Lupe) | `BrowserRemoteInputController.m/.h`, `UIApplication+BrowserSelectPressForwarding.m`, Host-Methoden in `ViewController.m` | hoch (GameController-Verhalten, `sendEvent:`-Tausch) |
| Obere Leiste | `BrowserTopBarView.m/.h`, `BrowserTabCoordinator.m` (`updateTopNavAndWebView`) | mittel (`UIGlassEffect`) |
| Nativer Videoplayer, Handover | `BrowserVideoPlaybackCoordinator.m`, `BrowserNativeVideoPlayerViewController.m`, `BrowserNativeVideoAssetLoader.m` | mittel |
| Video-Hooks, Media-Session | `BrowserClickTargetTracker.m` (`BrowserVideoHookScript`, `BrowserMediaSessionHookScript`), `BrowserNowPlayingController.m` | mittel |
| YouTube-Erfassung/-Extraktor | `BrowserWebView.m` (`BrowserYouTubeRequestCaptureScript`), `BrowserYouTubeExtractor.m` | hoch (Extraktion ist abgeschaltet) |
| DNS-Proxy (Cloudflare DoH) | `BrowserDNSProxy.m/.h`, `SceneDelegate.m`, `AppDelegate.m` | hoch (`nw_*`-Privacy-Context, `proxyConfigurations`) |
| Eingabedialog für Formulare (Passwörter) | `BrowserPageActionCoordinator.m`, `BrowserDOMInteractionService.m` | niedrig bis mittel |
| Adress-Bearbeiten mit Aufklapp-Bereich (Favoriten, Oft, Zuletzt), Favicons | `BrowserAddressPanelView.m`, `BrowserFaviconCache.m`, `BrowserHistoryStore.m` (alte Vollbild-Startansicht `BrowserStartViewController.m` nicht mehr eingebunden) | niedrig |
| Bedienungsdialog | `BrowserGuideViewController.m` | niedrig |
| Tab-Übersicht, Sitzung | `BrowserTabOverviewController.m`, `BrowserTabCoordinator.m`, `BrowserSessionStore.m` | niedrig |
| Systemklassen-Hacks | `WebCoreNSURLSessionTaskTransactionMetrics+AddPrivacyStance.m` (aktiv), `AVPlayerViewController+BrowserFullscreenBlock.m` und `WebAVPlayerViewController+FullscreenSubviewHack.m` (beide per Schalter aus) | hoch |
| Machbarkeitstest | `BrowserFeasibilityProbe.m` | niedrig |
| Selbsttest | `ViewController.m` (`runPointerSelfTestIfRequested`, nur DEBUG) | niedrig |

---

## 2. Checkliste nach einem tvOS-/WebKit-Update

Reihenfolge nach Wahrscheinlichkeit, dass etwas bricht. Geräteablauf siehe [Abschnitt 14](#14-selbsttest-und-gerätezyklus).

**Nach jedem tvOS-Update** (Apple TV und Xcode) die App neu aufspielen (`Installieren.command`), starten und diese Liste zumindest bis Punkt 7 durchgehen: Die App nutzt private APIs, die ein Update ohne Vorwarnung ändern kann.

1. **Startet die App überhaupt?** Abstürze beim Start: UIScene-Pflicht (`SceneDelegate`, Scene-Manifest in `Info.plist`, siehe PLAN.md), Konsole nach `UIApplicationEvaluateRuntimeIssue…` durchsuchen.
2. **Lädt eine Seite?** Logzeilen `[Load] commit/layout/paint/finish +N ms`. Fehlen `layout`/`paint`: `_webView:renderingProgressDidChange:` kommt nicht mehr an (Abschnitt 3).
3. **Datenspeicher:** Log `[DataStore] eigener Speicher in Caches, N Verzeichnisse gesetzt, store=ok`. Bei `nicht verfügbar` oder `store=nil` gehen Logins/LocalStorage nach Neustart verloren. Verzeichnisanzahl mit dem Vorwert vergleichen (aktuell bis zu 14 Selektoren, nicht alle müssen greifen).
4. **Zoom und Layout:** Selbsttest `zoom` (loggt `_viewScale`), Wikipedia öffnen (Überzoom-Fix), Klickziele bei 150 % treffen.
5. **Werbeblocker:** Logzeilen `[AdBlock] … aus Store` bzw. `kompiliert`; `Fehler`/`nicht lesbar` heißt Regelformat oder Store defekt. Danach Testseite mit Werbung.
6. **Cookie-Ablehner:** Selbsttest mit `clearsite:`/`clearall` und `url:`, dann `[CookieBlock] …`-Zeilen. Prüfen, dass andere Nutzerskripte (Zeiger-Ziele, Video-Hooks) nach dem Umschalten noch laufen (Abschnitt 4).
7. **Fernbedienung:** Log `[Input] Clickpad über GameController: …` beim Start; sonst läuft nur der UIKit-Fallback. Mit echter Fernbedienung Zeiger, oben/unten, links/rechts, Ring, Play/Pause, Menü prüfen.
8. **Magnetic Buttons und Linse:** Zeiger auf einen Link ziehen, Glas-Hervorhebung/Glow prüfen (Snapshot-Linse: `resizableSnapshotViewFromRect:`).
9. **Obere Leiste:** Glas sichtbar (`UIGlassEffect`), Klickziele unter der Leiste um **94 pt** versetzt richtig (Selbsttest `probe`, `views`).
10. **Video:** Video antippen/Vollbild-Knopf → nativer Player. Logs `[NativeVideoPlayer]`, `[NativeVideoAssetLoader]`. Zurück in die Seite mit richtiger Position.
11. **DNS:** Log `[DNSProxy] SOCKS5 auf 127.0.0.1:PORT, DNS über Cloudflare` und `[DNSProxy] CONNECT host:port`. Test `https://1.1.1.1/help` (zeigt DoH ja/nein).
12. **Systemhacks:** `UIApplication sendEvent:` (Abschnitt 12) und der `_privacyStance`-Shim; Konsole auf `unrecognized selector` prüfen.
13. **Drittbibliotheken** nur bei Bedarf aktualisieren (Abschnitte 5.7, 6.7), nicht gleichzeitig mit einem OS-Update, damit Ursachen trennbar bleiben.

---

## 3. WKWebView per Laufzeit (`BrowserWebView`)

**Zweck.** Kapselt eine zur Laufzeit geladene `WKWebView` (tvOS liefert WebKit nur privat) und stellt sie wie eine alte `UIWebView` bereit; enthält alle privaten Einstellungen, Zoom, Leisteneinschub, weichen Seitenwechsel und den eigenen Datenspeicher.

**Dateien.** `_Project/Browser/BrowserWebView.m/.h`. Gebraucht von `BrowserTabCoordinator.m` (je Tab eine Instanz), `ViewController.m`.

**Einhängung.** `commonInitWithUserAgent:allowsInlineMediaPlayback:` baut Konfiguration → private Medien-Prefs → Nutzerskripte (YouTube-Erfassung, Viewport-Normalisierer) → `contentController` → `BrowserContentBlocker`/`BrowserCookieConsentBlocker applyToUserContentController:` → `BrowserClickTargetTracker installIntoConfiguration:` → Datenspeicher (`defaultWebsiteDataStore`) → `BrowserDNSProxy applyToWebsiteDataStore:` → `initWithFrame:configuration:`. Navigationsdelegate ist die `BrowserWebView` selbst. `decidePolicyForNavigationAction` ruft vor jeder Hauptframe-Navigation `updateUserContentController:forNavigationToURL:` beider Blocker (Ausnahmen pro Seite).

**Private/fragile APIs (alle Aufrufe per `respondsToSelector` abgesichert, falls nicht anders vermerkt).**

| Selektor / Name | Wofür | Fallback |
|:--|:--|:--|
| `WKWebView`-Laden per `dlopen` der Pfade `/System/Library/Frameworks/WebKit.framework/WebKit`, `…/PrivateFrameworks/WebKit.framework/WebKit`, `…/StagedFrameworks/Safari/WebKit.framework/WebKit` | WebKit verfügbar machen | nein: ohne Klasse bleibt die WebView leer (`commonInit` kehrt früh zurück) |
| Prefs: `_setMediaSourceEnabled:`, `_setManagedMediaSourceEnabled:`, `_setMediaCapabilityGrantsEnabled:`, `_setVideoQualityIncludesDisplayCompositingEnabled:` | MSE/Managed MSE (YouTube & Co.) | ja (still ohne Wirkung) |
| `_setShouldIgnoreMetaViewport:` | Meta-Viewport der Seite ignorieren (Wikipedia: `width=1120`) | ja; zusätzlich Skript `BrowserViewportNormalizerScript` |
| `setMediaTypesRequiringUserActionForPlayback:` (0), `setAllowsPictureInPictureMediaPlayback:` | `play()` aus der App ohne Nutzergeste | ja |
| `_setViewScale:` | Grundzoom (`pageZoom`, Standard 150 %) in `applyPageScalingIfNeeded` | ja: Fallback CSS-`zoom` per JS (im Gerätetest unbrauchbar, `setPageZoom:` und CSS-Zoom schieben unter tvOS 27 Inhalt aus dem Bild) |
| `_setObscuredInsets:` plus `scrollView.contentInset.top` | Seite läuft unter der schwebenden Leiste durch (`setTopObscuredInset:`) | ja |
| `_setObservedRenderingProgressEvents:` mit **fest einkodierten Bits** `1<<1` (FirstVisuallyNonEmptyLayout) und `1<<2` (FirstPaintWithSignificantArea) | weicher Seitenwechsel | ja, aber Bitwerte sind privat und können sich ändern |
| Delegate `_webView:renderingProgressDidChange:` (privat, von WebKit nur aufgerufen, wenn vorhanden) | beendet den Snapshot-Überblendeffekt | Sicherheitsnetz: nach 6 s wird der Snapshot ohnehin entfernt |
| `setUnderPageBackgroundColor:` | Farbe hinter dem Seiteninhalt | ja |
| Datenspeicher: Klasse `_WKWebsiteDataStoreConfiguration`, `_initWithConfiguration:` und Verzeichnis-Setter `setGeneralStorageDirectory:`, `_setWebStorageDirectory:`, `_setIndexedDBDatabaseDirectory:`, `_setWebSQLDatabaseDirectory:`, `_setCacheStorageDirectory:`, `_setServiceWorkerRegistrationDirectory:`, `_setResourceLoadStatisticsDirectory:`, `setNetworkCacheDirectory:`, `setDeviceIdHashSaltsStorageDirectory:`, `setMediaKeysStorageDirectory:`, `setAlternativeServicesStorageDirectory:`, `setHSTSStorageDirectory:`, `setSearchFieldHistoryDirectory:`, `_setApplicationCacheDirectory:` | tvOS verbietet `Library/WebKit`; WebKit bekommt Ordner unter `Library/Caches/WebsiteData/` | ja: Fallback `defaultDataStore` (dann ohne dauerhaftes LocalStorage) |
| `proxyConfigurations` (über `BrowserDNSProxy`) | siehe Abschnitt 11 | ja |
| `userContentController`, `addUserScript:`, `initWithSource:injectionTime:forMainFrameOnly:`, `addScriptMessageHandler:name:`, `removeAllUserScripts`, `removeAllContentRuleLists`, `addContentRuleList:` | Skripte, Rückkanal, Regeln | meist ja; Ausnahme: `BrowserClickTargetTracker installIntoConfiguration:` ruft `userContentController` auf der Konfiguration **ohne** `respondsToSelector`-Prüfung |

**Synchrones JS mit Zeitgrenze.** `stringByEvaluatingJavaScriptFromString:` ruft `evaluateJavaScript:completionHandler:` und wartet per `BrowserPumpRunLoopUntil(BOOL *done)` höchstens **2,0 s** (Run-Loop in 10-ms-Schritten). Gleiches gilt für Cookie-Abfragen (`getAllCookies:`, `setCookie:completionHandler:`). Grund: Endlosschleifen im Seiten-JS hielten sonst die App an, und tvOS beendet hängende Apps. Rückgabe bei Zeitüberschreitung: `nil`/leer. Wer neue synchrone Aufrufe baut, muss dieselbe Funktion nutzen. Für alles, was nicht zwingend synchron sein muss: `evaluateJavaScriptAsync:`.

**Viewport-Normalisierer.** `BrowserViewportNormalizerScript` (Nutzerskript, document-start, nur Hauptframe) schreibt `<meta name=viewport>` mit `width=<Zahl>` oder `initial-scale≠1` auf `width=device-width, initial-scale=1` um (max. 8 Korrekturen, `MutationObserver`, nach 3 s abgeschaltet). Wirkung: Wikipedia wurde sonst um Faktor 3 statt 1,5 überzoomt und seitlich abgeschnitten. Zusammen mit `_setShouldIgnoreMetaViewport:` und `_setViewScale:` bildet das die Zoomkette; ändert sich eins, alle drei prüfen.

**Klickziel-Versatz 94 pt.** Die WebView füllt den ganzen Bildschirm, der Inhalt beginnt per Einschub (`topObscuredInset`, gesetzt in `BrowserTabCoordinator.updateTopNavAndWebView`) unter der Leiste. Der Wert ist die Höhe des `topMenuView` (`Base.lproj/Main.storyboard`: 94 pt; im Code Glasfläche 86 pt plus 8 pt Rand, `kTopBarHeight`/`kTopBarVerticalInset`). Konsequenz: CSS-Koordinaten (ab 0 unter der Leiste) und Ansichtskoordinaten (ab Bildschirmrand) unterscheiden sich um genau diesen Wert. Alle Stellen müssen ihn kennen: `BrowserWebView rectsShiftedByTopInset:`, `glowColorAtPoint:`, `sendVideoCommand:atPoint:`, `BrowserDOMInteractionService DOMPointForCursorOrigin:` (`point.y -= webView.topObscuredInset`), `ViewController browserHandlePrimaryAction`. Wird die Leistenhöhe geändert, nur an einer Stelle ändern (Storyboard) und diese Stellen mit Selbsttest `probe`/`click` prüfen.

**Woran man merkt, dass es kaputt ist.**

| Symptom | Ursache / Logzeile |
|:--|:--|
| Seite bleibt bis 6 s auf dem alten Bild stehen | `[Load]` zeigt kein `paint`/`layout` → `_setObservedRenderingProgressEvents:` oder Delegate `_webView:renderingProgressDidChange:` greift nicht |
| Seiten zu groß, seitlich abgeschnitten | `_setViewScale:` oder `_setShouldIgnoreMetaViewport:` fehlt; Selbsttest `zoom` |
| Klicks landen ca. 94 pt neben dem Ziel | Einschub nicht angewendet (`_setObscuredInsets:`/`contentInset`); Selbsttest `probe` loggt `webFrame`, `offset`, `inset` |
| YouTube/MSE-Videos starten nicht | Medien-Prefs; „Inspect WebKit Media Prefs“-Menüpunkt (`presentWebKitRuntimeMediaPreferences`, `runtimeMediaPreferenceReport`) |
| Login/Cookies weg nach Neustart | `[DataStore] … store=nil` oder Selektoren fehlen |
| App friert bei Skript-Endlosschleife ein | Zeitgrenze `BrowserPumpRunLoopUntil` umgangen |

**Test.** Selbsttest-Schritte `url:`, `zoom`, `probe`, `state`, `js:`, `label`; Logzeilen `[Load]`, `[DataStore]`. Beispiel: `POINTER_SELFTEST="url:https://de.wikipedia.org;zoom;probe"`.

**Aktualisieren.** Neue private Selektoren: in den WebKit-Headern der Xcode-SDK (`WKWebView+Private.h` ist nicht enthalten) oder per `class_copyMethodList` zur Laufzeit suchen; die Debug-Hilfe `runtimeMediaPreferenceReport` listet Preferences. Bitwerte der Rendering-Ereignisse (`_WKRenderingProgressEvents`) am WebKit-Quellcode der passenden Version prüfen.

---

## 4. Nutzerskripte und die userScripts-Falle

**Zweck.** Alle Eigenbauten, die in Seiten laufen, sind `WKUserScript`s in einem gemeinsamen `WKUserContentController` pro Tab.

**Skripte (Reihenfolge der Installation in `commonInit`).**

| Skript | Zeitpunkt / Frames | Installiert in |
|:--|:--|:--|
| `BrowserYouTubeRequestCaptureScript` | document-start (0), alle Frames | `BrowserInstallYouTubeCaptureUserScript` in `BrowserWebView.m` |
| `BrowserViewportNormalizerScript` | document-start, nur Hauptframe | ebenda |
| Autoconsent-Bundle + `bridge.js` (mit vorangestelltem `window.__browserAcceptPayWalls=…`) | document-start, **alle** Frames | `BrowserCookieConsentBlocker makeUserScript` |
| `BrowserClickTargetScript` | document-end (1), Hauptframe | `BrowserClickTargetTracker installIntoConfiguration:` |
| `BrowserVideoHookScript` | document-start, Hauptframe | ebenda |
| `BrowserMediaSessionHookScript` | document-start, Hauptframe | ebenda |

Nachrichten-Handler (Rückkanal, `addScriptMessageHandler:name:`): `browserTargets`, `browserVideo` (beide Tracker), `browserAutoconsent` (Cookie-Ablehner). Die Handler-Klassen (`BrowserClickTargetMessageProxy`, `BrowserVideoMessageProxy`, `BrowserCookieConsentMessageProxy`) bekommen das Protokoll `WKScriptMessageHandler` per `class_addProtocol` zur Laufzeit angehängt, weil WebKit nicht gelinkt ist. Das Protokoll wird per `objc_getProtocol("WKScriptMessageHandler")` gesucht; fehlt es, wird nicht angehängt und WebKit lehnt den Handler eventuell ab.

**Die Falle.** `WKUserContentController userScripts` ist eine **Live-Ansicht** auf die interne Liste. Der Cookie-Ablehner muss sein Skript ein- und ausbauen (Schalter, Ausnahme pro Seite), WebKit kennt aber kein Einzel-Entfernen, nur `removeAllUserScripts`. Deshalb in `BrowserCookieConsentBlocker refreshController:exception:force:`:

```objc
NSArray *scripts = [NSArray arrayWithArray:((NSArray *(*)(id, SEL))objc_msgSend)(controller, scriptsGetter)];
removeAll(controller);
for (id script in scripts) { if (script != oldScript) addScript(controller, script); }
```

`[… copy]` wäre falsch: `copy` auf der Live-Ansicht gibt dieselbe Ansicht zurück, die nach `removeAllUserScripts` leer ist; dann würden **alle** anderen Skripte (Zeigerziele, Video-Hooks, Viewport-Fix, YouTube-Erfassung) verloren gehen. Symptom: Nach Umschalten von Cookie-Ablehner oder Seitenwechsel auf eine Ausnahme-Seite rasten Zeiger nicht mehr ein, Videos werden nicht mehr erkannt, Wikipedia überzoomt. Ändert Apple den Rückgabetyp von `userScripts` (z. B. `NSArray` zu Proxy-Objekt), muss die Kopie weiterhin eine echte `NSArray` mit eigenem Speicher sein.

Auch für anderen Code, der Skripte ändert: neue Nutzerskripte immer **vor** dem ersten Umschalten des Cookie-Ablehners installieren oder zusätzlich in dieser Routine berücksichtigen (sie fasst nur das eigene Skript an, lässt die übrigen aber stehen).

**Woran man merkt, dass es kaputt ist.** Siehe Symptome oben. Hilfreich: Selbsttest `js:` mit `typeof window.__browserTargets` (Zeiger-Skript), `typeof window.__browserVideoHook`, `typeof window.__browserViewportFix`, `typeof window.autoconsentStandalone` (alle `object`/`number`/`boolean`, nicht `undefined`).

**Test.** `POINTER_SELFTEST="url:https://example.org;js:typeof window.__browserTargets;menu"`, dann im Menü Cookie-Ablehner aus/ein (Methode `cookieBannerMenuItem`), Seite lädt neu, `js:` erneut.

---

## 5. Cookie-Ablehner (autoconsent) und Bezahlschranken

### 5.1 Zweck
Lehnt Cookie-Banner automatisch ab (`autoAction: "optOut"`, nie zustimmen) auf Basis von DuckDuckGos `autoconsent` (mehrere hundert Banner-Systeme). Sonderfall Bezahlschranken (Abo/„mit Werbung weiterlesen“): optional zustimmen, damit kein Banner stehen bleibt.

### 5.2 Dateien
- `_Project/Browser/Autoconsent/autoconsent.standalone.js`: unverändertes Bundle (`@duckduckgo/autoconsent` 18.1.0, MPL-2.0, Regeln `compact-rules.json` eingebettet; siehe `THIRD_PARTY_NOTICES.md`, `LICENSE-MPL-2.0.txt`)
- `_Project/Browser/Autoconsent/bridge.js`: **eigene** Brücke (Log-Weiterleitung und Bezahlschranken)
- `_Project/Browser/BrowserCookieConsentBlocker.m/.h`: Singleton `sharedBlocker`
- Einstellungen in `BrowserPreferencesStore`: `cookieBannerBlockEnabled` (Standard an), `cookieBannerExceptionHosts`, `cookieBannerAcceptPayWalls` (Standard an)
- Menü: `cookieBannerMenuItem`, `cookiePayWallMenuItem`, `cookieBannerSiteMenuItem` in `BrowserMenuCoordinator.m` (alle in `extensionMenuItems`)

### 5.3 Datenfluss
1. `BrowserWebView commonInit` → `applyToUserContentController:` registriert den Handler `browserAutoconsent` und ruft `refreshController:exception:NO force:YES`.
2. `makeUserScript` liest Bundle und Brücke aus dem App-Paket (`pathForResource:… inDirectory:@"Autoconsent"`, einmal gelesen, in `BrowserAutoconsentSource`), stellt `window.__browserAcceptPayWalls=true|false;` voran und baut ein `WKUserScript` (document-start, **alle** Frames, Hauptwelt). Alle Frames, weil CMPs oft in fremden iframes liegen.
3. Seite lädt, Bundle legt `window.autoconsentStandalone = {instance, messages}` an, entscheidet mit `autoAction: "optOut"` selbst (Konfiguration im Bundle, nicht in der App).
4. `bridge.js` hängt sich in `autoconsentStandalone.messages.push` ein und meldet gefilterte Nachrichten (`type`, `cmp`, `url`, `top`, ggf. `result`, `lifecycle`, `details`) per `webkit.messageHandlers.browserAutoconsent.postMessage` an die App (`handleMessageBody:` → nur Zähler `handledCount` und DEBUG-Log). Die App steuert autoconsent **nicht**.
5. Ausnahmen pro Seite: vor jeder Hauptframe-Navigation (`decidePolicyForNavigationAction`) → `updateUserContentController:forNavigationToURL:` → `refreshController:` baut das Skript aus oder ein (Host ohne `www.`, Treffer auch für Subdomains, `BrowserConsentHostMatches`). Schalter ändern → `preferencesDidChange` + Seite neu laden.

### 5.4 Bezahlschranken
`bridge.js` läuft den zweiten Teil nur, wenn `window.__browserAcceptPayWalls === true`. Nach 2,5/5/8/12 s sowie 1,5 s nach `autoconsentDone`/`optOutResult` sucht `scan()` sichtbare Knöpfe (`button, a, [role=button], input[type=button|submit]`), deren Beschriftung regulär zu `ACCEPT` passt (Akzeptieren, Zustimmen, „Mit Werbung weiter“, accept/agree …). Geklickt wird nur, wenn der umgebende Dialog (fixed/sticky, `role=dialog`, `aria-modal`, im CMP-iframe die ganze Seite) Text enthält, der zu `PAY` passt (Abo, Pur, werbefrei, subscribe, ad-free, `€` …). Meldung `payWallAccepted` erhöht ebenfalls `handledCount`. Nur einmal pro Seite (`accepted`). Normale Banner werden weiter nur abgelehnt.

### 5.5 Private/fragile Schnittstellen
- WebKit (alle mit `respondsToSelector`/`instancesRespondToSelector`-Prüfung, bei Fehlen stilles Aus): `WKUserScript initWithSource:injectionTime:forMainFrameOnly:`, `addUserScript:`, `removeAllUserScripts`, `userScripts`, `addScriptMessageHandler:name:`, Protokoll `WKScriptMessageHandler` per `class_addProtocol`.
- **Interne Struktur des Bundles**, von `bridge.js` abhängig: `window.autoconsentStandalone.messages` (Array mit `push`), Nachrichtentypen `report` (mit `state.lifecycle`, `state.detectedCmps`), `autoconsentDone`, `optOutResult` (mit `result`), `autoconsentError` (mit `details.message`), `cmp`, `url`. Fehlt `messages` oder ändert sich das Format, endet `bridge.js` nach dem ersten `return` still (Logzeilen verschwinden, Ablehnen funktioniert evtl. trotzdem weiter, nur die Bezahlschranken-Zustimmung läuft dann nicht).
- Texte in `PAY` und `ACCEPT` (deutsch/englisch) in `bridge.js`: bei neuen Formulierungen von Bezahlschranken zu ergänzen.

### 5.6 Woran man merkt, dass es kaputt ist
| Symptom | Prüfung |
|:--|:--|
| Banner bleiben stehen | Keine Zeilen `[CookieBlock] …` → Skript nicht installiert, Bundle fehlt im Paket (`[CookieBlock] Ressource Autoconsent fehlt im App-Paket`) oder Ausnahme/Schalter aus |
| Zeilen `[CookieBlock] report … zustand=…` kommen, aber Banner bleibt | Regel des CMP veraltet → Bundle aktualisieren (5.7) oder Seite in Ausnahmen |
| `autoconsentError` | Fehlertext steht in der Zeile (`details`); meist Regel-Fehler im Bundle oder CSP |
| Bezahlschranke bleibt stehen | Keine Zeile `payWallAccepted` → `PAY`/`ACCEPT` erweitern, Dialog-Erkennung (`dialogOf`) prüfen |
| Alle anderen Eigenbauten fallen nach Umschalten aus | `userScripts`-Falle, Abschnitt 4 |
| Banner kehren bei jedem Besuch zurück | Zustimmung der Seite wird im Datenspeicher abgelegt; `[DataStore]`-Zeile prüfen |

DEBUG-Zeile: `[CookieBlock] <type> <cmp> <url> [ergebnis=ja|nein] [zustand=…] [details] (Hauptframe|iframe)`. Die Zeilen existieren nur in DEBUG-Builds (`#if DEBUG`).

### 5.7 Test
Selbsttest (Gerät, DEBUG): `clearsite:spiegel.de` löscht die gespeicherte Einwilligung nur dieses Hosts (loggt `clearsite … Einträge gelöscht`), `clearall` löscht alle Website-Daten (`clearall fertig`). Danach `url:https://www.spiegel.de` laden und nach mindestens 12 s Screenshot machen. Beispiel:

```
POINTER_SELFTEST="clearall;url:https://www.spiegel.de" 
```

Testliste: deutsche und internationale Seiten, darunter Pur-Seiten, TCF-CMPs und Bezahlschranken-Beispiele. Eine feste Seitenliste ist im Repo nicht hinterlegt.

### 5.8 Aktualisieren
Es gibt in `tools/` **kein** Skript dafür. Vorgehen (aus `THIRD_PARTY_NOTICES.md` abgeleitet, nicht automatisiert):
1. Aus dem npm-Paket `@duckduckgo/autoconsent` die Datei `dist/autoconsent.standalone.js` der gewünschten Version holen und **unverändert** nach `_Project/Browser/Autoconsent/` kopieren (MPL-2.0: Datei nicht ändern, Quelle bleibt im Upstream-Repo).
2. Version in `THIRD_PARTY_NOTICES.md` anpassen.
3. Prüfen, dass `window.autoconsentStandalone = {instance, messages}` und die Nachrichtentypen aus 5.5 noch existieren (`grep -n "autoconsentStandalone" …`).
4. `bridge.js` nur anfassen, wenn sich die Schnittstelle geändert hat.
5. Neu bauen, Selbsttest wie 5.7. Neue Dateien im Ordner `Autoconsent/` brauchen keine Projektänderung (Ordnerreferenz); ein neuer Ordner würde `tools/add_resource.py <Ordner>` erfordern.

---

## 6. Werbeblocker (`BrowserContentBlocker`)

### 6.1 Zweck
Blockiert Werbung/Tracker über WebKit-Content-Rule-Lists. Die Regeln stammen aus den Standardlisten von uBlock Origin Lite und EasyList Germany, umgewandelt auf dem Mac.

### 6.2 Dateien
- `_Project/Browser/BrowserContentBlocker.m/.h`: Singleton `sharedBlocker`
- `_Project/Browser/ContentBlocker/`: `network-1.json.z`, `network-2.json.z`, `cosmetic-generic.json.z`, `cosmetic-domain.json.z`, `manifest.json` (Namen, Dateien, Hash, Regelzahl, Statistik nicht umsetzbarer Regeln)
- `tools/build_adblock_rules.py` (Konverter), `tools/validate_adblock_rules.swift` (Prüfer mit echtem WebKit), `tools/add_resource.py`
- Einstellungen: `adBlockEnabled` (Standard an), `adBlockExceptionHosts`; Menü: `adBlockMenuItem`, `adBlockSiteMenuItem`

### 6.3 Datenfluss
1. `BrowserWebView commonInit` → `applyToUserContentController:` → `prepare` (einmal): liest `manifest.json`, legt `Library/Caches/ContentRuleLists` an, erzeugt `WKContentRuleListStore storeWithURL:`.
2. `processNextEntry` arbeitet die Listen **nacheinander** ab: `lookUpContentRuleListForIdentifier:completionHandler:` mit Kennung `adblock-<name>-<hash>`; nicht gefunden → `compileEntry:` entpackt die `.json.z` auf einer eigenen Queue (`decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib`, entspricht raw deflate) und ruft `compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:`.
3. Jede fertige Liste → `listBecameReady:` → `refreshAllControllersForce:NO` setzt auf allen Tabs `removeAllContentRuleLists` + `addContentRuleList:` für alle fertigen Listen. Danach `removeStaleLists` entfernt Stände mit anderem Hash.
4. Ausnahmen pro Seite wirken nur ganz oder gar nicht (`ignore-previous-rules` wirkt nicht über Listen hinweg): `updateUserContentController:forNavigationToURL:` nimmt alle Listen weg oder hängt sie wieder an.

### 6.4 Private/fragile APIs
Alle per Klassenname `WKContentRuleListStore` und `NSSelectorFromString`: `storeWithURL:`, `lookUpContentRuleListForIdentifier:completionHandler:`, `compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:`, `getAvailableContentRuleListIdentifiers:`, `removeContentRuleListForIdentifier:completionHandler:`; am Controller `removeAllContentRuleLists`, `addContentRuleList:` (letztere mit `respondsToSelector`-Prüfung, die Store-Selektoren **ohne** Prüfung). Der `defaultStore` scheitert unter tvOS (WKErrorDomain 6, `Library/WebKit` nicht beschreibbar), darum der eigene Ordner in `Library/Caches`. tvOS darf `Caches` leeren: dann wird beim nächsten Start neu kompiliert (am Gerät rund 8 s für alle vier Sätze, aus dem Store 50 ms).

Limit je Liste: Konverter schneidet bei 140.000 Regeln (`MAX_RULES_PER_LIST`, Reserve unter dem WebKit-Limit 150.000). Ob neuere WebKit-Versionen mehr erlauben, wurde laut PLAN.md noch nicht getestet.

### 6.5 Woran man merkt, dass es kaputt ist
Alle Zeilen sind **nicht** auf DEBUG beschränkt:

| Logzeile | Bedeutung |
|:--|:--|
| `[AdBlock] <name> aus Store (N ms)` | in Ordnung |
| `[AdBlock] <name> kompiliert (X s, N Regeln)` | in Ordnung (erster Start/neuer Hash) |
| `[AdBlock] <name> Fehler <Code>: …` | WebKit lehnt die Liste ab → Regelformat/Limit; mit `validate_adblock_rules.swift` den schuldigen Eintrag finden |
| `[AdBlock] <name> nicht lesbar` | Datei fehlt im Paket oder Entpacken schlug fehl |
| `[AdBlock] Store nicht erstellbar` | `storeWithURL:` liefert `nil` (Pfad/Berechtigung/API) |
| `[AdBlock] nicht verfügbar (Klasse …, Regelsätze 0)` | `WKContentRuleListStore` fehlt oder Manifest leer/nicht im Paket |

Symptom ohne Fehlerzeile: Werbung erscheint trotz `aus Store` → Controller bekommt Listen nicht (Selektoren `removeAllContentRuleLists`/`addContentRuleList:`) oder Seite steht in den Ausnahmen.

### 6.6 Test
Log beim Start lesen (`devicectl … --console`), dann Nachrichtenseite mit Werbung öffnen. Nicht umgesetzt sind Scriptlets (`##+js`), `$redirect`, `$removeparam`, prozedurale Kosmetik u. a. (Zahlen in `manifest.json`, Abschnitt `sources`); ein Teil der YouTube-Werbung bleibt deshalb sichtbar (offen laut PLAN.md).

### 6.7 Aktualisieren
```
python3 tools/build_adblock_rules.py            # lädt Listen (Cache tools/.adblock-cache), schreibt Regeln und manifest.json
python3 tools/build_adblock_rules.py --refresh  # Listen neu herunterladen
python3 tools/build_adblock_rules.py --no-register   # ohne Eintrag im Xcode-Projekt
swiftc -O tools/validate_adblock_rules.swift -o /tmp/validate_adblock
/tmp/validate_adblock _Project/Browser/ContentBlocker   # kompiliert jeden Satz mit echtem WebKit, sucht bei Fehlern per Halbierung die Regel
```
Die Listenauswahl steht in `LISTS` am Anfang von `build_adblock_rules.py` (aus `gorhill/uBlock`, `platform/mv3/rulesets.json`, Gruppen „default“ und „malware“, dazu EasyList Germany). Nach einem Lauf ändern sich die Hashes im `manifest.json`; die App kompiliert beim nächsten Start neu und räumt alte Stände weg. Ergebnisdateien committen. `tools/add_resource.py ContentBlocker` trägt den Ordner nur einmalig als Ordnerreferenz ein; neue Dateien darin brauchen keine Projektänderung.

### 6.8 Automatische Ausnahme bei Adblock-Sperre
- **Zweck:** Seiten wie bild.de zeigen „Aufgrund Ihres Blockers zeigen wir BILD.de nicht an“. Die App erkennt solche Sperren und pausiert den Werbeblocker für diese Seite.
- **Dateien:** `ContentBlocker/adblock-wall.js` (Erkennung), Logik in `BrowserContentBlocker.m` (`handleWallMessage:`, `refreshWallController:`). Handler `browserAdblockWall`. Einstellungen: `adBlockAutoPauseOnWall` (Standard an), `adBlockAutoExceptionHosts` (Teilmenge von `adBlockExceptionHosts`). Menü: `adBlockAutoPauseMenuItem`; `adBlockSiteMenuItem` zeigt „Pausiert (Sperre)“.
- **Erkennung:** Nutzerskript document-end, alle Frames, nur im Controller, wenn Werbeblocker und Automatik an sind und die Seite keine Ausnahme hat (Ein-/Ausbau mit der Live-Ansicht-Kopie wie in Abschnitt 4). Prüft alle 1,5 s bis zu 10-mal. Treffer nur bei Blocker-Wort (Adblocker, Werbeblocker, „Ihres Blockers“, ad blocker …) **und** Aufforderung (deaktivieren, whitelist, disable …) im selben Text, und nur in einem großen sichtbaren fixierten/modalen Container, einem ganzen Sperr-iframe, einer fast leeren Seite, einer Seite mit „adblock/blocker“ im Pfad (bild.de: `/adblockwall.html`) oder einer kurzen Seite mit passender Überschrift.
- **Reaktion:** Host der Hauptseite (aus `message.webView.URL`) wird per `setException:YES` ausgenommen, in `adBlockAutoExceptionHosts` vermerkt, Seite einmal neu geladen. Schleifenschutz: pro Host einmal je App-Lauf. Eine Menüentscheidung des Nutzers (`setException:`) entfernt den Auto-Vermerk.
- **Log (DEBUG):** `[AdBlockWall] host … erkannt → Ausnahme, neu laden`.
- **Keine eingebaute Hostliste:** Die Filterliste „Adblock Warning Removal List“ (EasyList, antiadblockfilters) ist gepflegt, besteht aber aus Netzwerk-/Kosmetikregeln, nicht aus einer Liste von Sperr-Seiten. Eine Vorab-Ausnahme würde unnötig Werbung zeigen, daher nur Erkennung.
- **Test:** `POINTER_SELFTEST="clearall;url:https://www.bild.de;wait;wait;wait;wait;wait;wait;wait;wait"`. Gegenprobe ohne Treffer: spiegel.de, heise.de, `de.wikipedia.org/wiki/Werbeblocker`. Sperrtexte fehlen? `BLOCKER`/`ACTION` in `adblock-wall.js` ergänzen.

---

## 7. Klickziele, Seitenfarbe, Glow-Farbe (`BrowserClickTargetTracker`)

**Zweck.** Ein Seitenskript meldet klickbare Elemente, Videos, Medieninfos, Seitenfarbe, Titel/Sitename an die App. Grundlage für magnetischen Zeiger, Leistenfarbe, Glow-Farbe, Now Playing und Bildschirmschoner-Sperre.

**Dateien.** `BrowserClickTargetTracker.m/.h`; Anbindung in `BrowserWebView.m` (`clickTargetRects`, `glowColorAtPoint:`, `videoRects`, `pageBackgroundColor`, `reportedSiteName`, `mediaInfo`), Verbraucher in `ViewController.m` (`observeClickTargetsOfWebView:`, `applyPageColorOfWebView:`).

**Datenfluss.**
- `BrowserClickTargetScript` (document-end, Hauptframe, Rückkanal `browserTargets`) sammelt per `querySelectorAll` (Links, Knöpfe, Felder, `role=button|link|tab|…`, `[onclick]`, `[tabindex]`, `contenteditable`), filtert auf sichtbar/erreichbar (`elementFromPoint`) und meldet bis zu 500 Rechtecke `[x, y, w, h, fixed, glow]` plus `v` (Videos), `p` (spielt), `m` (Medieninfo), `fs` (Vollbild), `bg` (Seitenfarbe), `ti` (Titel), `sn` (Sitename), `w` (`innerWidth`), `sx/sy`. Neu bei Scrollen/DOM-Änderungen (gedrosselt); `window.__browserTargets.report()` erzwingt (`refreshScript`).
- Seitenfarbe (`pageColor()`): oberen Rand abtasten (`elementsFromPoint` bei y=2, Overlays und iframes überspringen), sonst `meta[name=theme-color]`, sonst `body`/`html`, sonst Weiß.
- Glow-Farbe (`glow()`): Hintergrundfarbe, sonst Textfarbe des Ziels; Weiß, Schwarz, Grau und Durchsichtiges zählen als „keine“ (`-1`), dann nimmt `BrowserRemoteInputController` Standardblau. Ergebnis packt RGB in eine Zahl (`entry[5]`), `glowColorAtViewPoint:` wählt das kleinste Ziel unter dem Punkt.
- Umrechnung CSS → Punkte: `viewWidth / innerWidth` (`cssViewportWidth`); seit der Meldung gescrollte Ziele wandern mit (`contentOffsetAtReport`), `fixed`/`sticky` nicht. Dazu der Einschub aus Abschnitt 3.
- `reset` bei `didStartProvisionalNavigation`.

**Fragile Stellen.** Rein JavaScript/DOM, also anfällig für seitenseitige Änderungen (Shadow DOM wird nicht durchsucht, laut Code nur `querySelectorAll`), ansonsten nur die Nutzerskript-APIs aus Abschnitt 4. Nachrichtenformat ist stillschweigend vertraut: Einträge mit weniger als 5 (Ziele) bzw. 6 (Videos) Feldern werden verworfen.

**Woran man merkt, dass es kaputt ist.** Zeiger rastet nirgends ein (Selbsttest `move`: loggt `targets=N`; bei 0 meldet das Skript nichts), Glow immer blau, Leiste bleibt weiß/schwarz. `js:` mit `typeof window.__browserTargets`.

**Test.** `POINTER_SELFTEST="url:https://de.wikipedia.org;300,400;click"`; `move`-Zeilen zeigen die Zielzahl, `label` den Seitennamen, `[TopBar] Seitenfarbe …` die erkannte Farbe.

**Aktualisieren.** Nur das Skript in `BrowserClickTargetScript()` anpassen (Selektorliste `SEL`, Farblogik, Filter).

---

## 8. Fernbedienung (`BrowserRemoteInputController`)

**Zweck.** Zeigerbedienung der Siri Remote mit Einrasten (Magnetic Buttons), Scrollen, Sprung von Element zu Element, Ring-Geste, Play/Pause-Varianten und Menütaste.

**Dateien.** `BrowserRemoteInputController.m/.h` (Logik, Hervorhebung, Linse), `UIApplication+BrowserSelectPressForwarding.m` (globale Tastenweiterleitung), Host-Implementierung in `ViewController.m` (Methoden `browserRemoteInputController…`), `BrowserPageActionCoordinator.m` (Klick), `BrowserDOMInteractionService.m` (DOM-Koordinaten).

### 8.1 Eingabewege
- **GameController (bevorzugt):** `GCControllerDidConnectNotification` → `attachToGameController:` setzt `microGamepad.reportsAbsoluteDpadValues = YES`, `allowsRotation = NO` und `dpad.valueChangedHandler`. Rohwerte −1…1 werden mit `kPadPointsPerUnit = 640` in Punkte umgerechnet, dann Beschleunigung (`PointerSpeed` aus `NSUserDefaults`, begrenzt 0,3…3,0). Log: `[Input] Clickpad über GameController: <Name>`.
- **UIKit-Fallback:** `handleTouchesBegan/Moved/Ended:` mit Indirect-Touches (auch iPhone/iPad-Fernbedienung). Wird ignoriert, solange in den letzten 0,25 s eine GameController-Probe kam (`padLastSampleTime`), damit nicht doppelt bewegt wird. DEBUG-Log: `[Input] Raten: GameController N/s, UIKit-Berührungen N/s`.
- **Presses** (`handlePressesBegan/Ended`, weitergeleitet aus `ViewController`; `UIApplication browser_sendEvent:` fängt Tasten vorab ab, Abschnitt 12).

### 8.2 Belegung (im Code)
| Eingabe | Aktion |
|:--|:--|
| Wischen | Zeiger bewegen, rastet ein (`kSnapRadius` 36 pt, löst bei `kReleaseMargin` 28 pt; Ziele größer als 420 × 140 werden nur hervorgehoben); Randscrollen am Bildschirmrand |
| Auswahl (Mitte) | Klick (`performSelectAction` → Host `browserRemoteInputControllerHandlePrimaryAction`); Doppelzustellung wird mit 0,15 s entprellt |
| Oben/unten | eine Seite scrollen (`kPageScrollFraction` 0,8); **oben zweimal** (< 0,4 s) → `browserRemoteInputControllerOpenAddressBar` (Leiste ausklappen, Bearbeiten-Zustand mit Aufklapp-Bereich, Abschnitt 13; keine Tastatur); **unten zweimal** → `browserRemoteInputControllerCompactTopBar` |
| Links/rechts | `browserRemoteInputControllerNavigateBack/Forward`: Zeiger auf laufendem Video → ±10 s (`sendVideoCommand:… seek:±10`), sonst `stepTargetBy:∓1` (Element-zu-Element; Reihenfolge nach Zeilen à 24 pt, dann links→rechts; am Ende des Sichtbaren `scrollThenStep:` scrollt weiter und springt zum nächsten Ziel, nach 0,45 s Wartezeit auf die neue Meldung). Ziele: `browserRemoteInputControllerStepTargets` (Zeigerziele plus Videos ohne eigene Bedienelemente, obere Leiste nur am Seitenanfang) |
| Play/Pause | kurz (nach 0,3 s Doppeltipp-Fenster): Video steuern, sonst Adressdialog; lang (≥ 0,6 s): `…HandlePlayPauseLongPress` (Suche/Diktat); doppelt: `…HandleAdvancedMenuPress` (•••-Menü) |
| Menü/Zurück | `browserRemoteInputControllerHandleMenuPress`: Seitenvollbild verlassen → Dialog schließen → Seite zurück → sonst `NO` (System geht zum Home-Bildschirm, vorher Sitzung sichern) |
| Im Aufklapp-Bereich der Adresse | optionale Host-Methode `browserRemoteInputControllerAddressPanelActive`: Pfeile → `stepTargetInDirection:` (räumlicher Sprung: Kandidaten in Blickrichtung, Wertung Abstand + 2 × seitlicher Versatz ab Zielkante), kein Seiten- oder Randscrollen, Zeiger wird nicht ausgeblendet; Select → `browserHandlePrimaryAction` → `handleAddressEditingSelectionAtPoint:`; Play/Pause → Eingabedialog; Menü → schließen. Eckenradius der Hervorhebung per `browserRemoteInputControllerCornerRadiusForTarget:` (Feld: Kapselform, Kacheln: Radius des Icons), keine Linse |
| Ring (Kreisbewegung) | `trackRotationWithDelta:`: Eintritt bei ≥ 200° akkumulierter Drehung (`kRotationEnterAngle`), danach je 60° (`kRotationStepAngle`) ein Schritt; im Uhrzeigersinn vor, dagegen zurück; Zeiger kehrt zum Gestenstart zurück |

### 8.3 Magnetic Buttons (Hervorhebung)
Ziele (Rechtecke in `rootView`-Koordinaten) liefert der Host: `browserRemoteInputControllerPointerTargets` (Seitenziele aus Abschnitt 7 plus Knöpfe der oberen Leiste per `enumeratePointerTargetsUsingBlock:`; was unter der Leiste liegt, wird verworfen). Darstellung in `BrowserRemoteInputController`:
- `BrowserGlassHighlightSurfaceView`: Tönung, Glanzverlauf, Lichtkante
- `BrowserGlowView`: Glow statt Schatten, Farbe vom Host (`browserRemoteInputControllerGlowColorForTarget:`, Fallback Systemblau `0.23/0.57/1.0`)
- **Linse:** `updateLensForFrame:radius:` nimmt per `resizableSnapshotViewFromRect:afterScreenUpdates:` zwei Schnappschüsse der WebView (`browserRemoteInputControllerLensSourceView`), Mitte 1,04-fach, Randband 1,13-fach, feiner Saum. Nur bei neuer Lage/Größe, nicht pro Frame.

- **Zeigerbilder:** `BrowserCursorRenderer` (eigene Vektorzeichnung per `UIBezierPath`/`UIGraphicsImageRenderer`, 3-fach gerastert, kein Apple-Bildmaterial; die alten PNGs `Cursor`/`Pointer` im Asset-Katalog sind ungenutzt). Arten: Pfeil, Hand (Zeigefinger, nur bei großen Zielen oder in der Tabübersicht sichtbar, sonst ersetzt die Hervorhebung den Zeiger), I-Beam (noch ohne Aufrufer). Stile in `BrowserPreferencesStore.cursorStyle` (Schlüssel `CursorStyle`, additiv, kein Menüeintrag): 0 macOS-Stil (Pfeil schwarz mit weißem Rand, Hand weiß mit schwarzem Rand, Standard), 1 invertiert, 2 SF Symbols (`cursorarrow`, `hand.point.up.left.fill`, Kontur durch 16 versetzte Kopien, Spitze per Pixelsuche). Höhe etwa 44 pt.
  **Hotspot:** `BrowserCursorImageView` (Unterklasse von `UIImageView`, in `BrowserRemoteInputController` als `cursorView` angelegt) zeichnet das Bild in einer inneren Ansicht, versetzt um `+[BrowserCursorRenderer hotspot]` (30/14 pt Rand für Kontur, Schatten, Daumen). So bleibt `cursorView.frame.origin` die Klickspitze, und alle Hosts (`DOMPointForCursorOrigin:` usw.) bleiben unverändert. Wichtig: `image` der Oberklasse bleibt leer (Setter überschrieben, Getter nicht), sonst zeichnet UIImageView zusätzlich ein zweites, verkleinertes Bild.
  **Test:** `POINTER_SELFTEST="url:https://de.wikipedia.org/wiki/Apple_TV;wait;wait;wait;672,910;wait"` plus Stil per `xcrun simctl spawn <udid> defaults write io.github.tvosbrowser.app CursorStyle -int N`; `770,566;click` trifft den Link „Bildschirm“ (Seite lädt neu). Screenshots in `docs/cursor-screens/` (`zeiger-varianten.png` Kontaktbogen; Zeiger verschwindet nach kurzer Ruhe, Screenshot direkt nach dem `move`-Log aufnehmen).

### 8.4 Private/fragile Punkte
- GameController: Verhalten von `GCMicroGamepad` mit absoluten Werten (Wertebereich, Nullwert beim Loslassen als „nicht berührt“: `handlePadValue:` wertet `(0,0)` als Loslassen). Ohne `respondsToSelector`-Fallback, aber der UIKit-Fallback übernimmt, wenn keine Proben kommen.
- Hängt von `UIPress`-Typen und davon ab, dass die Taste sowohl über `pressesEnded` als auch global ankommt (Doppelzustellung, Entprellung 0,15 s).
- Linse nutzt öffentliche UIKit-API, ist aber layoutabhängig (`source.window`, Rechteck innerhalb der Quelle).
- Abstimmungswerte (`kSnapRadius`, `kPadPointsPerUnit`, Beschleunigung) sind laut PLAN.md noch nicht endgültig mit echter Fernbedienung abgestimmt.

### 8.5 Woran man merkt, dass es kaputt ist
| Symptom | Ursache |
|:--|:--|
| Zeiger ruckelt/träge | kein `[Input] Clickpad über GameController`-Log → UIKit-Fallback; DEBUG-Rate-Log vergleichen |
| Zeiger springt beim Drücken | `pressInProgress`-Unterdrückung greift nicht (Presses kommen nicht an) |
| Doppelte Klicks | Entprellung/`lastDirectSelectPressTimestamp` |
| Kein Einrasten | `move`-Selbsttest meldet `targets=0` (Abschnitt 7) |
| Hervorhebung ohne Linse | `source.window` nil oder Rechteck außerhalb der WebView |
| Ring springt nie / immer | Selbsttest `gestures` (siehe unten) |
| Tasten kommen im nativen Player doppelt an | `[InputTrace][App] …`-Zeilen, Abschnitt 12 |

### 8.6 Test
- Selbsttest (ohne Fernbedienung, DEBUG): `x,y` (Zeiger setzen, loggt `move … targets=N`), `click`, `left`/`right` (loggt `overVideo`, danach `Zeiger … scroll=…`), `next`/`prev` (Sprung), `gestures` (loggt `cw1.5`, `ccw1`, `line`, `quarter`; erwartet: Kreise > 0, Gerade und Viertelkreis = 0), `playpause`, `menu`.
- Echte Fernbedienung: Zeigerbewegung, oben/unten, links/rechts über Video, Ring, Play/Pause kurz/doppelt/lang, Menü.

### 8.7 Aktualisieren
Kein externer Teil. Werte in `#pragma mark - Abstimmung` und in den Konstanten der Abschnitte „Clickpad über GameController“ und „Kreisgeste“ anpassen.

---

## 9. Obere Leiste (`BrowserTopBarView`)

**Zweck.** Schwebende Glas-Leiste mit Adresse/Seitenname und Knöpfen; wird beim Scrollen zur Kapsel.

**Dateien.** `BrowserTopBarView.m/.h` (`UIVisualEffectView`-Unterklasse), Steuerung in `ViewController.m` (`pageDidScrollToOffset:`, `applyPageColorOfWebView:`), `BrowserTabCoordinator.m` (`updateTopNavAndWebView`, Einschub).

**Merkmale und Einhängung.**
- Glas: `UIGlassEffect effectWithStyle:UIGlassEffectStyleClear` mit `interactive = YES` ab tvOS 26 (`#if __has_include(<UIKit/UIGlassEffect.h>)` plus `@available(tvOS 26.0, *)`), sonst `UIBlurEffect` dunkel.
- Seitenfarbe: `setPageBackgroundColor:` passt Symbole/Schrift an (hell/dunkel) und färbt den Streifen hinter der Leiste (`BrowserWebView setSurroundingColor:`); DEBUG-Zeile `[TopBar] Seitenfarbe … s=… b=… bunt=…`. Die Seitenfarbe überspringt Cookie-Overlays (Abschnitt 7).
- HTTPS: `setDisplayTitle:domain:secure:` – Seitenname grün, bei kräftig gefärbter Leiste (`colorfulPage`) stattdessen Schloss-Symbol `lock.fill` in Schriftfarbe.
- Favoritenstern: `favorite` (gefüllt/gelb), Datenquelle `BrowserHistoryStore` (Abschnitt 13).
- Ladelinie: `setLoadingProgress:loading:`, gespeist aus `estimatedProgress` (KVO in `BrowserWebView`, `loadingProgressDidChange`).
- Kompaktmodus: `setCompact:animated:` – Kapsel 560 × 58 pt statt 86 pt hoch; Auslöser in `pageDidScrollToOffset:`: Offset < 24 pt (Seitenanfang) oder mehr als 140 pt nach oben gescrollt → aufklappen; mehr als 24 pt nach unten gescrollt bei Offset > 60 pt → Kapsel. Doppelt unten (Fernbedienung) → `browserRemoteInputControllerCompactTopBar` (schließt vorher den Bearbeiten-Zustand). Klick auf die Kapsel öffnet den Bearbeiten-Zustand (klappt dabei auf).
- Bearbeiten-Zustand: `setAddressEditing:animated:` (eigener Abschnitt am Ende von `BrowserTopBarView.m`, eigene Subviews `dictationFieldView`/`dictationIconView`/`dictationLabel`). Die Kapsel zeigt mittig Mikrofon `mic.fill` und „Sprechen, um zu diktieren“ (halbtransparent), alle Knöpfe, Name und Kreisel auf Alpha 0. Einziges Zeigerziel ist dann `addressFieldFrame` (Aktion `BrowserTopBarActionURL`); `setCompact:YES` wird solange ignoriert.
- Kanteneffekt des Systems: `attachToScrollView:`.
- Zeigerziele: `enumeratePointerTargetsUsingBlock:`; Fokusmodus (tvOS-Fokus statt Zeiger) für die Knöpfe über `BrowserTopBarFocusButton`.

**Fragile Stellen.** `UIGlassEffect` (neue API, Stil/Verhalten ändert sich mit tvOS); Layoutkonstanten (`kTopBarHeight` 86, `kTopBarVerticalInset` 8) müssen zur Storyboardhöhe 94 passen (Abschnitt 3). Ansonsten öffentliche UIKit-API.

**Woran man merkt, dass es kaputt ist.** Leiste ohne Glas (dunkler Fallback), Leiste überdeckt/klippt Seiteninhalt oder Klicks sind versetzt (Höhe geändert), Kapsel öffnet/schließt nicht (`pageDidScrollToOffset:` bekommt keinen Offset: KVO `contentOffset` in `BrowserWebView observeScrollOffset`). Selbsttest `views` listet die Ansichtshierarchie bei (300, 6), `label` den Seitennamen.

**Test.** Seite mit Farbe laden (`url:`), `[TopBar] Seitenfarbe`-Zeile, nach unten scrollen (Kapsel), Screenshot.

**Aktualisieren.** Kein externer Teil.

### 9.1 Reader-Modus (`BrowserReaderMode`)

**Zweck.** Knopf links neben dem •••-Symbol (SF Symbol `doc.plaintext`, Rückfall `text.page`). Zeigt den Hauptartikel der Seite groß und ruhig (Sofaabstand): Systemserife (`ui-serif`, New York), ca. 36 pt Fließtext, Zeile ca. 1280 pt breit (rund 70 Zeichen), mittig; Titel, Autor, Datum, Domain, Lesezeit; Bilder höchstens spaltenbreit; hell/dunkel per `prefers-color-scheme` (folgt der Systemeinstellung, die Leistenfarbe folgt über den Klickziel-Tracker der Seitenfarbe).

**Dateien.** `_Project/Browser/BrowserReaderMode.m/.h` (Brücke), Ordner `_Project/Browser/Reader/` (Ordnerreferenz, per `tools/add_resource.py Reader`): `Readability.js` und `Readability-readerable.js` (Mozilla, Apache-2.0, **unverändert**, Version 0.6.0 aus npm `@mozilla/readability`, siehe `THIRD_PARTY_NOTICES.md`), `LICENSE.md`, `reader.js` (eigener Teil: Overlay und Stil). Leiste: `BrowserTopBarView` (`BrowserTopBarActionReader` am Ende der Enum, `setReaderAvailable:active:`, `readerImageView`, `readerFocusButton`). Steuerung: `ViewController.m` (Abschnitt „Reader-Modus“: `toggleReaderMode`, `updateReaderAvailability`, `scheduleReaderAvailabilityChecks`).

**Datenfluss.**
1. `BrowserReaderMode` liest die drei Skriptdateien einmal und setzt sie zu `(function(module){ … })(undefined);` zusammen (`module` verdeckt, damit die Dateien nichts an ein seiteneigenes `module` hängen). Jeder Aufruf (`check`, `toggle`, `exit`) installiert bei Bedarf `window.__browserReader` im Seitenkontext (`evaluateJavaScriptAsync:`) und ruft die Methode auf. Rückgabe `a` (aktiv), `y` (lesbar), `n` (nicht lesbar). Zusätzlich `window.__browserReaderViewWidth` (Breite der Ansicht in Punkten), daraus rechnet `reader.js` Punkte in CSS-Pixel um (die App-WebView hat `innerWidth` 1280 bei 1920 pt, Faktor 2/3).
2. **Erkennung:** nach `webViewDidFinishLoad` nach 0,4 s und nochmals nach 2,5 s (Seiten, die ihren Text per Skript aufbauen) `isProbablyReaderable(document, {minContentLength: 400, minScore: 20})`. Bei `webViewDidStartLoad` und Tabwechsel wird der Zustand zurückgesetzt (Knopf weg, Reader aus). Nicht lesbar: Knopf unsichtbar (`alpha` 0, kein Zeigerziel, kein Fokusknopf); sein Platz bleibt in der Leiste reserviert, damit Ladekreisel und Seitenname nicht springen. Ladekreisel sitzt links vom Reader-Platz, Reader-Platz direkt links vom Menü. Im Kompaktmodus ist der Knopf wie die anderen Symbole ausgeblendet.
3. **Einschalten:** `new Readability(document.cloneNode(true), {charThreshold: 200}).parse()`, dann Overlay `<div id="__reader">` ans Ende des Body, `<style id="__reader_style">` in den Kopf, `html.__rd` setzen. Per CSS (`!important`) sind alle übrigen Kinder des Body ausgeblendet und `html`/`body` auf normales Scrollen gezwungen. Der Inhalt wird nach dem Einsetzen bereinigt (`style`-Attribute, weil Readability sie behält und die Textgröße-Funktion der App sie mit `!important` setzt; `on…`-Attribute, `javascript:`-Adressen, Skripte). Danach `scrollTo(0,0)` und `__browserTargets.report()`.
4. **Ausschalten:** Overlay und Stil entfernen, Klasse weg, gemerkter Scrollstand wiederherstellen. Auslöser: erneuter Knopfdruck oder Menütaste (`browserRemoteInputControllerHandleMenuPress` prüft `topMenuView.readerActive` **vor** „Seite zurück“) oder Navigation (neue Seite = Reader zu Ende).

**Warum Overlay statt `loadHTMLString:baseURL:`.** (a) Beim Ausschalten kommt die Originalseite sofort zurück, mit Scrollstand, Formularen, laufenden Skripten, ohne Neuladen und ohne Verlauf zu verbiegen (`loadHTMLString` legt einen Verlaufseintrag an; „Zurück“ würde die Seite neu laden). (b) Die Extraktion läuft auf dem fertig gerenderten DOM (auch per Skript gebauter Inhalt, Cookie-Overlays sind bereits weg). (c) Dieselbe Herkunft: relative Bild- und Link-Adressen, Cookies und Bildschutz (Referer) funktionieren wie auf der Seite. (d) Alle Nutzerskripte (Klickziel-Tracker, Video-Hooks, Cookie-Ablehner) laufen unverändert weiter, weil es dasselbe Dokument bleibt: Links im Reader sind normale `<a>`-Elemente im Haupt-DOM und werden vom Tracker (document-end, `querySelectorAll`) gemeldet; nach dem Umschalten stößt die App `refreshClickTargets` an. Ein eigenes Reader-Dokument per `loadHTMLString` bräuchte dagegen eine neue Navigation, Tracker und Cookie-Ablehner liefen neu, das Original käme nur über Neuladen zurück. Bewusst **kein** Shadow DOM, weil der Tracker Shadow DOM nicht durchsucht und Links dort nicht einrasten würden; stattdessen `all: initial` auf dem Container, Selektoren mit `#__reader`-Präfix und `!important` für `::first-letter`/`::first-line`/`::before`/`::after` (Seitenstile wie Initialen). 

**Private/fragile Stellen.** Kein privates API. Anfällig: (a) das Ausblenden per `html.__rd > body > *:not(#__reader)` bei Seiten, die Inhalt außerhalb des Body oder nach dem Einschalten neu einfügen (dann erscheint er unter/über dem Reader), (b) Seitenstile, die den Container trotz `all: initial` verändern (selten), (c) Readability kann bei Nicht-Artikeln `null` liefern: dann bleibt die Seite unverändert und der Knopf verschwindet (`toggle` gibt `n` zurück), (d) lange Seiten: `parse()` läuft synchron im Seitenthread (Sekundenbruchteile bis wenige Sekunden), (e) `loadHTMLString`-Alternative wäre der Rückfall, falls Apple Skriptausführung im Seitenkontext einschränkt.

**Woran man merkt, dass es kaputt ist.** Knopf erscheint nie: `[Reader] check -> n` bzw. `e:…` in der Konsole (DEBUG), `js:typeof window.__browserReader`; `Datei fehlt: Reader/…js` heißt Ordner nicht im Paket. Reader zeigt Seite doppelt oder halb: Seitenstil schlägt durch. Links im Reader rasten nicht ein: `window.__browserTargets` prüfen (Abschnitt 4).

**Test.** `POINTER_SELFTEST="url:https://de.wikipedia.org/wiki/Apple_TV;js:1;js:1;reader;js:1;next;next;click"` (Schritt `reader` schaltet um und loggt `reader vorher/nachher verfügbar=… aktiv=…`; `[Reader] check/toggle -> a|y|n`). Geprüft mit heise.de-Artikel, theguardian.com-Artikel, de.wikipedia.org (Screenshots in `docs/reader-screens/`).

**Aktualisieren.** Readability: neue Version aus npm holen (`npm view @mozilla/readability version`, Tarball), die beiden Dateien und `LICENSE.md` unverändert ersetzen, Version in `THIRD_PARTY_NOTICES.md` und hier ändern. Stil: nur `css()` in `reader.js`.

---

## 10. Video

Gliederung: 10.1 Video-Hooks im Seitenkontext, 10.2 Übergabe an den nativen Player, 10.3 Asset-Loader, 10.4 Now Playing, 10.5 YouTube.

### 10.1 Video-Hooks und Medienmeldungen
**Zweck.** Vollbild-Wünsche und Videostarts der Seite abfangen, HLS/DASH-Manifeste für MSE-Videos (`blob:`) merken, Media-Session-Handler der Seite sichern.

**Dateien.** `BrowserClickTargetTracker.m`: `BrowserVideoHookScript` (Rückkanal `browserVideo`, document-start, Hauptframe), `BrowserMediaSessionHookScript`, Teil von `BrowserClickTargetScript`; Weitergabe `BrowserWebView.videoEventHandler` → `ViewController observeClickTargetsOfWebView:` → `BrowserVideoPlaybackCoordinator handlePageVideoEvent:`.

**Ablauf.**
- Überschreibt `fetch` und `XMLHttpRequest.prototype.open`, merkt `.m3u8` (`window.__browserManifests.hls`, bis 20 Einträge in `all`) und `.mpd` (`dash`).
- Überschreibt `HTMLVideoElement.prototype.webkitEnterFullscreen`/`webkitEnterFullScreen` und `Element.prototype.requestFullscreen`/`webkitRequestFullscreen`/`webkitRequestFullScreen`; bei Video meldet es `{type:'fullscreen', bid}` und unterdrückt das Vollbild. Ebenfalls Ereignis `webkitbeginfullscreen`.
- `playing`-Ereignis (nur Videos ≥ 320 × 180 CSS-Pixel, keine stummen Loops/Autoplay-Vorschauen) → `{type:'playing', bid}`; die App öffnet den nativen Player, wenn `autoOpenVideosInNativePlayer` (Standard ja) gesetzt ist (Menü: `autoOpenNativePlayerMenuItem`).
- Media-Session: `navigator.mediaSession.setActionHandler` wird gewrappt, Handler landen in `window.__browserMediaHandlers` (für nächster/voriger Titel).
- Befehle an das Video: `videoCommandScriptWithCSSPoint:command:` mit `toggle`, `seek:±S`, `play`, `pause`, `seekto:S`, `action:<name>`.

**Fragil.** Überschreibt Prototypen der Seite; Seiten, die Referenzen früh sichern, umgehen die Hooks. Video-Vollbild kann tvOS-WebKit ohnehin nicht (`feature is not supported`), deshalb der Umweg über den nativen Player.

**Kaputt?** Vollbildknopf tut nichts oder öffnet Systemfehler; kein automatischer Player. Selbsttest `video` (loggt Zeit, `paused`, `readyState`, `rects`, `playing`, `idle`), `js:` mit `JSON.stringify(window.__browserManifests)`.

### 10.2 Nativer Player und Handover
**Zweck.** Videos der Seite in `AVPlayerViewController` (4K/HDR, Transportleiste, Siri) abspielen und danach die Position zurückgeben.

**Dateien.** `BrowserVideoPlaybackCoordinator.m/.h`, `BrowserNativeVideoPlayerViewController.m/.h`.

**Datenfluss.** `openPageVideoWithID:trigger:` (Trigger: Fullscreen/Automatic/Menu) → `BrowserPageVideoProbeScript` wählt das Video (Kennung, Zeigerposition, laufendes, aktives, größtes), merkt es als `window.__browserHandoverVideo` und liefert JSON (`currentSrc`, `src`, `source`-Kinder, `hls`, `hlsAll`, `dash`, Position, User-Agent, Seiten-URL, Titel) → `nativeURLFromProbe:unsupportedReason:` (Reihenfolge: direkte Adresse, dann zuletzt gesehenes HLS; `.mpd`, `.webm`, `.ogv`, `.ogg`, `.flv`, `.mkv`, `.avi`, `.f4v` werden ausgeschlossen, Grund wird dem Nutzer gemeldet) → `pauseAndPresentPlayerForURL:probe:webView:` pausiert (`kBrowserHandoverPauseScript`), baut Header (User-Agent, `Referer`, `Origin`) und Cookies der WebView (`webViewCookiesForURL:`) und präsentiert `BrowserNativeVideoPlayerViewController` mit `initialPlaybackTime`. Beim Schließen schreibt `dismissHandler` die Position zurück in die Seite (Video bleibt pausiert). Bei Fehlern: `failureHandler` → zurück zur Seite (`kBrowserHandoverResumeScript`) plus Hinweis.

**Fragil/Grenzen.** DASH und DRM (FairPlay) gehen nicht. Der Player-Controller-Typ wird in `UIApplication+BrowserSelectPressForwarding.m` per `NSClassFromString(@"BrowserNativeVideoPlayerViewController")` gesucht, d. h. Umbenennung der Klasse bricht die Tastenweiterleitung (Abschnitt 12). Privater Selektor-Aufruf auf dem Player: `scrubByHorizontalDelta:`, `togglePlayback`, `skipByInterval:` (eigene Methoden der Klasse, per `respondsToSelector` geprüft).

**Kaputt?** Logzeilen mit `[NativeVideoPlayer]` (Status, Fehler), `[NativeVideoPlayer] Wiedergabe fehlgeschlagen, zurück zur Seite: …` (aus dem Koordinator). `[InputTrace][NativePlayer]` loggt Tasten im Player.

### 10.3 Asset-Loader (`BrowserNativeVideoAssetLoader`)
**Zweck.** Reicht Header und Cookies an `AVURLAsset` weiter, sonst verweigern viele Server den Stream.

**Ablauf.** `assetURLForPlaybackURL:` ersetzt `https`/`http` durch ein eigenes Schema; `attachToAsset:` setzt sich per `resourceLoader setDelegate:queue:` (Selektor `resourceLoader` mit Prüfung) als Delegate; Anfragen laufen mit `NSURLSession` und den Original-Headern/Cookies. Wichtige Besonderheiten in `fillContentInfoForLoadingRequest:…`:
- **UTI statt MIME:** `contentInformationRequest.contentType` erwartet einen UTI (`public.mpeg-4`), nicht `video/mp4`. Umwandlung über `UTType typeWithMIMEType:` bzw. Dateiendung; HLS-Playlists werden als `application/vnd.apple.mpegurl` erkannt (`isPlaylistResponse:`).
- **Content-Range:** Bei Teilantworten (206) steht die Gesamtlänge hinter dem `/` in `Content-Range` (`bytes 0-1/788493`); sonst `expectedContentLength`, sonst Datengröße. `byteRangeAccessSupported` aus `Accept-Ranges`/206.

**Kaputt?** Player bleibt schwarz oder meldet Status „failed“; `[NativeVideoAssetLoader]`-Zeilen (Anfrage, Antwort, Fehler). Typische Ursachen: UTI nicht ermittelbar, falsche Länge, Server verlangt Header.

### 10.4 Now Playing
`BrowserNowPlayingController.m`: `MPRemoteCommandCenter` (Play, Pause, Toggle, ±10 s, Position, nächster/voriger Titel) → Befehle werden als `sendVideoCommand:` an die Seite gegeben; Angaben kommen aus `mediaInfo` (Abschnitt 7). Im nativen Player meldet AVKit selbst, die Seitenmeldung schweigt dann. Log `[NowPlaying] <Titel> t=…/… paused=…`, Fehler `[NowPlaying] category error`/`activate error`. Bildschirmschoner: `ViewController` setzt `idleTimerDisabled` aus `videoPlaying`.

### 10.5 YouTube
- `BrowserYouTubeRequestCaptureScript` (Nutzerskript, alle Frames, document-start, wird zusätzlich nach `didFinishNavigation` erneut ausgeführt) fängt `fetch`/XHR zu `/youtubei/v1/player` ab und merkt PoToken, Client-Name/-Version, erste/letzte Anfrage in `window.__browserYouTubeIntegrity`.
- `BrowserYouTubeExtractor` baut daraus eine Wiedergabeadresse. **Abgeschaltet:** `kBrowserYouTubeNativeExtractionEnabled = NO` in `BrowserVideoPlaybackCoordinator.m`. Der Erfassungsskript läuft weiter, der Extraktor wird nicht aufgerufen.
- Logpräfix `[YouTubeExtractor]`. Risiko hoch: YouTube ändert Formate laufend, PoToken-Pflicht.

**Test.** Alle Videoteile: `POINTER_SELFTEST="url:<Seite mit Video>;x,y;click;video;playpause;left;right;state"` – die Zeilen `video`, `playpause overVideo=… playing=…`, `state presented=BrowserNativeVideoPlayerViewController` zeigen, ob der Player geöffnet wurde.

---

## 11. DNS-Proxy (`BrowserDNSProxy`)

**Zweck.** tvOS erlaubt Apps keine eigene DNS-Einstellung, und WebKit löst Namen im eigenen Prozess. Darum läuft ein lokaler SOCKS5-Server in der App; ausgehende Verbindungen laufen mit einem Privacy-Context, der verschlüsselte Namensauflösung über Cloudflare erzwingt.

**Dateien.** `BrowserDNSProxy.m/.h`; Start in `AppDelegate.m` (`startAndWaitWithTimeout:1.0`) und `SceneDelegate.m` (`sceneWillEnterForeground:` startet neu und setzt neuen Port auf dem Datenspeicher); Schalter `BrowserDNSProxy.enabled` (Standard an, `NSUserDefaults`), Menü `cloudflareDNSMenuItem`.

**Datenfluss.** `nw_listener` auf `127.0.0.1`, Port zufällig → WebKit-Datenspeicher bekommt `setProxyConfigurations:@[nw_proxy_config_create_socksv5(…)]` (in `applyToWebsiteDataStore:`, von `BrowserWebView` und `SceneDelegate` aufgerufen) → je Verbindung eine `BrowserSOCKSSession`, die Ziel (IPv4, IPv6, Domain) liest, `nw_connection` mit `nw_privacy_context` `cloudflare-doh` aufbaut (`nw_privacy_context_require_encrypted_name_resolution`, Resolver `https://cloudflare-dns.com/dns-query` mit festen Adressen 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111/::1001) und Daten in beide Richtungen relayt. Zusätzlich wird der **Standard-Privacy-Context** (`NW_DEFAULT_PRIVACY_CONTEXT`) auf Cloudflare gestellt, damit App-eigene Verbindungen (URLSession, Player, Regel-Downloads) auch DoH nutzen. Kein Rückfall auf Provider-DNS. UDP/QUIC wird nicht proxied (WebKit fällt auf TCP zurück).

**Private/fragile APIs.** `WKWebsiteDataStore setProxyConfigurations:` (per `respondsToSelector`; ohne Selektor keine Proxy-Nutzung), `nw_proxy_config_create_socksv5`, `nw_privacy_context_*`, `nw_resolver_config_*` (C-API, öffentlich, aber jung). Bei `enabled = NO` oder Proxy aus werden die Konfigurationen auf `nil` gesetzt.

**Woran man merkt, dass es kaputt ist.**
| Zeile / Symptom | Bedeutung |
|:--|:--|
| `[DNSProxy] SOCKS5 auf 127.0.0.1:PORT, DNS über Cloudflare` fehlt | Listener startet nicht (`[DNSProxy] Listener beendet (N)`) |
| `[DNSProxy] CONNECT host:port` kommt nicht | WebKit nutzt den Proxy nicht (`setProxyConfigurations:` fehlt oder wurde nicht gesetzt) |
| `[DNSProxy] Verbindungen ok=N fehlgeschlagen=M` (DEBUG, jede 10. Verbindung und bei Fehlern) | `M` wächst: Cloudflare/DoH nicht erreichbar oder Privacy-Context abgelehnt |
| Seiten laden nach Hintergrund nicht | Proxy nach `sceneWillEnterForeground:` nicht neu gestartet |
| Alle Seiten laden nicht, wenn Cloudflare gesperrt | bewusst: kein Rückfall |

**Test.** `https://1.1.1.1/help` im Browser (zeigt „Using DNS over HTTPS (DoH): Yes“, laut PLAN.md noch offen als Test), Menü-Schalter aus/ein, Konsole beobachten. Längere Pausen/Hintergrund sind laut PLAN.md nicht ausführlich getestet.

**Aktualisieren.** Resolver-Adressen in `cloudflareResolver`.

---

## 12. Weitere Eingriffe in Systemklassen

| Eingriff | Datei | Status | Risiko |
|:--|:--|:--|:--|
| `UIApplication sendEvent:` per `method_exchangeImplementations` mit `browser_sendEvent:` (Klasse `+load`) | `UIApplication+BrowserSelectPressForwarding.m` | **aktiv** | hoch |
| `_privacyStance`/`privacyStance` auf `WebCoreNSURLSessionTaskTransactionMetrics` per `class_addMethod` ergänzen (liefert 0), nur wenn nicht vorhanden | `WebCoreNSURLSessionTaskTransactionMetrics+AddPrivacyStance.m` | **aktiv**; Zweck im Code nicht kommentiert, laut Name Absturzschutz gegen fehlende Methode (unklar, siehe Abschnitt 16) | mittel |
| `AVPlayerViewController enterFullScreenAnimated:completionHandler:`/`exit…` tauschen | `AVPlayerViewController+BrowserFullscreenBlock.m` | **aus** (`kBrowserAVKitFullscreenBlockEnabled = NO`) | hoch, falls eingeschaltet |
| `WebAVPlayerViewController` Vollbild-Unteransichten-Hack mit festen Struktur-Offsets (`0x20`, `0x58`) | `WebAVPlayerViewController+FullscreenSubviewHack.m` | **aus** (`kBrowserFullscreenHackEnabled = NO`), Log `[FullscreenHack]` | sehr hoch, falls eingeschaltet |
| `BrowserWKWebViewProofOfConceptViewController`: frühere WebKit-Machbarkeitsstudie (lädt `https://youtube.com`) | `BrowserWKWebViewProofOfConceptViewController.m` | im Code nicht verwendet gefunden (unklar) | niedrig |
| `BrowserFeasibilityProbe`: prüft WebKit-Klassen, Rückkanal, Store, Proxy, DoH | `BrowserFeasibilityProbe.m`, aufgerufen in `AppDelegate` | nur mit `RUN_FEASIBILITY_PROBE` (Umgebung) bzw. `-RunFeasibilityProbe YES`; Ergebnis `Library/Caches/feasibility.json`, Log `[Probe]` | niedrig |

**`UIApplication sendEvent:`-Tausch (aktiv).** Aufgaben: (1) Indirect-Touches (`UITouchTypeIndirect`) für Scrubben im nativen Player auswerten (`scrubByHorizontalDelta:`), (2) im nativen Player Menü, Play/Pause, Auswahl und Links/Rechts-Doppeltipp abfangen (`togglePlayback`, `skipByInterval:`), (3) das Ende eines Auswahl-Drucks als `BrowserGlobalSelectPressEndedNotification` an `ViewController` melden (`handleGlobalSelectPressEndedNotification`). Finden des Players: Suche über alle Fenster/Controller nach der Klasse `BrowserNativeVideoPlayerViewController`. `allTouches`/`allPresses` werden per `respondsToSelector` geprüft. Kaputt: Tasten wirken im Player doppelt oder gar nicht, Klick der Auswahltaste kommt nicht an (`[InputTrace][App] press=… phase=… top=…`, `swallow …`, `post BrowserGlobalSelectPressEndedNotification`).

**Test.** Konsole mit `devicectl … --console`, Tasten am Gerät drücken und `[InputTrace]`-Zeilen lesen; Selbsttest `state` zeigt, ob der Player präsentiert ist.

---

## 13. Start- und Verlaufsansicht, Bedienungsdialog, Tab-Übersicht

Alle rein UIKit, niedriges Update-Risiko. Hier nur die Einhängung.

- **Adresse bearbeiten mit Aufklapp-Bereich** (`BrowserAddressPanelView.m`, ersetzt die Vollbild-Startansicht): Auslöser zweimal oben, Klick auf Adresse oder Kapsel (`beginAddressEditing` in `ViewController.m`). Die Leiste klappt aus und wird zum Diktierfeld (Abschnitt 9); darunter wächst eine Glas-Karte (`UIGlassEffect` klar, Abdunkelung 0,38) in Leistenbreite 14 pt unterhalb aus der Leiste heraus (Federanimation 0,42 s: Höhe, Effekt nil → Glas, Inhalt blendet verzögert ein); die Seite bleibt mit 50 % Schwarz gedimmt sichtbar. Drei Spalten „Favoriten“ (Stern, Icons 136 pt, ohne Namen), „Oft besucht“ und „Zuletzt“ (Icons 96 pt mit Namen darunter), je 2 × 2 Kacheln; leere Plätze als dezente Flächen. „Zuletzt“ meidet Seiten, die schon unter „Oft besucht“ stehen, füllt bei wenig Verlauf aber auf. Kacheln bleiben unter 420 × 140 pt, damit der Zeiger mittig einrastet; die Hervorhebung ist die normale Magnetic-Button-Hervorhebung (Glas, Glow Standardblau). Die Karte ist rein optisch (`userInteractionEnabled = NO`); Ziele liefert `pointerTargetRectsInView:`, Klick `handleSelectionAtPoint:inView:`. Klick auf das Feld bzw. Play/Pause öffnet den Eingabedialog `showAddressDictationInput` (wie `showInputURLorSearchGoogle`, aber Standardtastatur statt Websuche, damit tvOS das Diktat über die Siri-Taste anbietet); Eingabe lädt wie bisher und schließt den Zustand. Menü oder Klick neben die Karte schließt. Logpräfix `[Address]`.
- **Favicons** (`BrowserFaviconCache.m`): Reihenfolge `https://<host>/apple-touch-icon.png`, `/apple-touch-icon-precomposed.png`, `/favicon.ico`, dann `https://www.google.com/s2/favicons?domain=<host>&sz=128`. Erstes Bild ab 48 px gewinnt, kleinere werden nur genommen, wenn nichts Besseres kommt. Speicher (`NSCache`) und Platte (`Library/Caches/Favicons/<host>.img`, Fehlschlag als `.none`, nach 24 h neuer Versuch). Ab 96 px füllt das Icon die Kachel, kleinere sitzen auf hellem Grund; ohne Icon Anfangsbuchstabe auf farbiger Kachel (Farbe aus dem Host). Logpräfix `[Favicon]` (DEBUG).
- **Alte Start-/Verlaufsansicht** (`BrowserStartViewController.m`, nicht mehr eingebunden, `showStartView` bleibt als Rückfall): Suchfeld, „Zuletzt besucht“, „Meistbesucht“, Favoriten; öffnet über `openURLHandler`. Daten aus `BrowserHistoryStore` (`recordVisitWithURL:title:`, `recentEntries:`, `topEntries:`, `favorites`, `addFavoriteWithURL:…`, `isFavoriteURL:`; je Host zusammengefasst, in `NSUserDefaults`; Benachrichtigung `BrowserHistoryStoreDidChangeNotification`). Früher Aufruf über Klick auf die Adresse.
- **Bedienungsdialog** (`BrowserGuideViewController.m`): Glas-Karte mit kurzer Bedienungshilfe, Schalter für den Start-Hinweis (`dontShowHintsOnLaunch`, `toggleHandler`). Aufruf `showHintsAlert` in `ViewController` (beim Start einmal, per Selbsttest `guide`). Der Text sollte mit Abschnitt 8.2 übereinstimmen; bei geänderter Belegung hier und in `README.mdown` nachziehen.
- **Tab-Übersicht** (`BrowserTabOverviewController.m`): Kartenansicht der Tabs; Host-Protokoll `BrowserTabOverviewControllerHost`; Tastenlogik in `BrowserRemoteInputController` (`TabOverviewVisible`, `…DismissTabOverview`, `…HandleTabOverviewAlternateAction`). Offen laut PLAN.md: Konflikte mit Play/Pause und Dialogen prüfen.
- **Sitzung** (`BrowserSessionStore.m`, `BrowserTabCoordinator.m`): offene Tabs und Cookie-Kopie in `NSUserDefaults`; `persistSession` vor Rückgabe an Home. Cookie-Sicherung `saveCookiesToDefaults`/`restoreCookiesFromDefaults` (AppDelegate), aufgerufen von `SceneDelegate`.
- **Formular-Eingabedialog** (`BrowserPageActionCoordinator.m`): Texteingabe und Login in einem Dialog (Benutzername + Passwort), `textContentType` aus `autocomplete` und Feldtyp (`BrowserTextContentType`), Werte über den nativen Setter des Eingabefeldes (React-kompatibel, `Object.getOwnPropertyDescriptor(proto, 'value')`), Absenden nur auf Wunsch über `requestSubmit()`. Test: Selbsttest `fill:` (loggt Titel, Felder, `textContentType`; letzter Wert ist der Index der Aktion).

Test (alle): Selbsttest `guide`, `menu`, `state`; ansonsten manuell mit der Fernbedienung.

---

## 14. Selbsttest und Gerätezyklus

### 14.1 Gerätezyklus (Apple TV)
Zum normalen Aufspielen (Release) genügt ein Doppelklick auf `Installieren.command` im Repo-Stamm: aktualisiert (`git pull`), prüft Xcode, wählt das Apple TV, baut, installiert, startet optional und nennt das Ablaufdatum des Profils (bei kostenlosem Account 7 Tage). Optionen: `--nur-bauen` (unsigniert, ohne Gerät), `--geraete`, `--kein-pull`, `--debug`, `--starten`/`--nicht-starten`, `UDID=…`. Ruft `tools/fetch_whisper_model.sh` und `tools/build_whisper.sh` auf, falls vorhanden. Die Einzelschritte von Hand:

Ein Gerät wird einmal über die App **Device Hub** (Xcode 27) gekoppelt. Danach ohne Xcode-Oberfläche (Projekt `_Project/Browser.xcodeproj`, Schema `Browser`, Bundle-ID `io.github.tvosbrowser.app`):

```bash
xcrun devicectl list devices                                   # UDID ermitteln
# 1. Bauen (Debug, damit der Selbsttest aktiv ist)
xcodebuild -project _Project/Browser.xcodeproj -scheme Browser \
  -destination 'id=<UDID>' -derivedDataPath ../build -allowProvisioningUpdates build
# 2. Installieren (Pfad: <derivedDataPath>/Build/Products/Debug-appletvos/Browser.app)
xcrun devicectl device install app --device <UDID> ../build/Build/Products/Debug-appletvos/Browser.app
# 3. Starten mit Konsole und Selbsttest
DEVICECTL_CHILD_POINTER_SELFTEST='url:https://example.org;300,400;click' \
  xcrun devicectl device process launch --device <UDID> --terminate-existing --console io.github.tvosbrowser.app
# 4. Bildschirmfoto
xcrun devicectl device capture screenshot --device <UDID> --destination bild.png
```

Hinweise: Umgebungsvariablen müssen mit `DEVICECTL_CHILD_` beginnen, damit sie in der App ankommen; Startargumente der Form `-Xyz` lehnt `devicectl` teils ab (daher Umgebung). Im Simulator entsprechend `SIMCTL_CHILD_POINTER_SELFTEST` mit `xcrun simctl launch --console`. Ohne Bezahl-Account läuft die App nach 7 Tagen ab (neu aufspielen). Tatsächlicher Pfad des gebauten `.app` kann abweichen; mit `-showBuildSettings` (`BUILT_PRODUCTS_DIR`) prüfen.

Neue Quelldateien ins Xcode-Projekt eintragen: `tools/add_source.py Name.h Name.m` (Anker `BrowserWebView.m`); Ordner als Ressource: `tools/add_resource.py <Ordner>`.

### 14.2 Selbsttest-Format
Nur **DEBUG**-Builds (`#if DEBUG` in `ViewController.m`, `runPointerSelfTestIfRequested`, aufgerufen aus `viewDidAppear:`). Die Umgebungsvariable `POINTER_SELFTEST` enthält Schritte, getrennt durch `;`. 5 s nach dem Erscheinen werden offene Dialoge geschlossen, dann läuft Schritt *i* nach `i·3 + 1` Sekunden. Danach `viewDidAppear` kommt nach jedem Dialog erneut, der Test startet aber nur einmal (`started`). Ausgabe immer mit Präfix `[SelfTest]`.

| Schritt | Bedeutung | Logzeile / Wirkung |
|:--|:--|:--|
| `x,y` | Zeiger an Punkt setzen (Einrasten greift wie beim Wischen) | `move (x, y) targets=N` |
| `click` | Auswahl-Klick (`browserHandlePrimaryAction`) | `click` |
| `url:<Adresse>` | Adresse laden (Doppelpunkt nach `url` ist Trenner, `;` in der Adresse nicht erlaubt) | `load <URL>` |
| `playpause` | Play/Pause kurz (Video steuern oder Adressdialog) | `playpause overVideo=… playing=…` |
| `left` / `right` | Clickpad links/rechts (Video ±10 s oder Elementsprung) | `left overVideo=…`, danach nach 1,2 s `Zeiger (x, y) scroll=…` |
| `next` / `prev` | Elementsprung direkt (`stepTargetBy:`) | `next cursor=(x, y)` |
| `gestures` | Ring-Erkennung mit künstlichen Bewegungen (`debugRunGestureWithDeltas:`) | `gestures cw1.5=… ccw1=… line=… quarter=…` (Kreise > 0, `line` und `quarter` = 0) |
| `fill:v1\|v2\|…\|i` | aktuellen Eingabedialog (UIAlertController) ausfüllen; letzter Wert *i* ist der Index der zu drückenden Aktion | `fill alert=<Titel> fields=N types=[textContentType…]`, `tap <Aktion>` |
| `dictate:<Text>` | Play/Pause lang (Suchdialog), Text einsetzen (simuliert Diktat) | `dictate field=ok text=…` |
| `siri:<befehl>[\|<arg>]` | Befehl wie aus einem App Intent (Spike, siehe `docs/SIRI_STEUERUNG.md`): back, forward, reload, home, tabs, favorite, newtab, address, reader | `siri <befehl>`, `[Siri] Befehl …` |
| `probe` | JS-Messung: Element `#red`, `scrollY`, `innerHeight/Width`, Treffer bei (20,20), `visualViewport.offsetTop` plus `webFrame`, `contentOffset`, `contentInset` (für Einschub/Versatz; setzt Testseite mit `#red` voraus) | `probe … webFrame=… offset=… inset=…` |
| `label` | Text der Adress-Beschriftung der Leiste | `label <Text>` |
| `views` | Ansichtshierarchie bei (300, 6) (z. B. Streifen hinter der Leiste) | `view <Klasse> frame=… bg=… alpha=…` |
| `menu` | Menütaste (`HandleMenuPress`) | `menu handled=0|1` |
| `address` | wie zweimal oben: Bearbeiten-Zustand mit Aufklapp-Bereich | `address active=1 tiles=N field=…`, Screenshot |
| `dir:up` / `dir:down` / `dir:left` / `dir:right` | Pfeiltaste im Aufklapp-Bereich (`stepTargetInDirection:`) | `dir down cursor=(x, y)` |
| `favorite` | Stern: aktuelle Seite zu den Favoriten (bzw. entfernen) | `favorite <host> = 0|1` |
| `wait` | nichts tun (3 s Pause, z. B. damit eine Seite lädt) | – |
| `guide` | Bedienungsdialog anzeigen | Screenshot |
| `reader` | Reader-Modus umschalten (Knopf der Leiste) | `reader vorher verfügbar=… aktiv=…`, nach 1,5 s `reader nachher …` |
| `clearall` | alle Website-Daten löschen (`resetWebsiteDataWithCompletion:`) | `clearall fertig` |
| `clearsite:<host>` | nur Einträge löschen, deren `displayName` den Host enthält (z. B. gespeicherte Cookie-Einwilligung) | `clearsite <host>: N Einträge gelöscht` |
| `zoom` | Zoom-Zustand (`zoomScale`, `min/max`, `_viewScale`, `contentSize`, `bounds`, `pageZoom`) | `zoom zoomScale=… viewScale=…` |
| `state` | Dialog-/Fenster-/Vollbildzustand | `state presented=… windowRoot=… fs=… keyWindowPresented=…` |
| `js:<Code>` | JavaScript ausführen, Ergebnis loggen | `js <Ergebnis>` |
| `video` | Zustand des ersten `<video>` (Zeit, paused, readyState, networkState, Fehler) plus App-Sicht (Rechtecke, `playing`, `idleTimerDisabled`) | `video t=… paused=… … rects=… playing=… idle=…` |

Zeichen `;` und `|` dürfen in `js:`/`url:`/`fill:` nicht vorkommen (Trenner).

### 14.3 Beispiele
```
# Cookie-Ablehner frisch testen
POINTER_SELFTEST="clearsite:spiegel.de;url:https://www.spiegel.de"
# Einrasten und Glow, danach Screenshot
POINTER_SELFTEST="url:https://de.wikipedia.org;300,400;next;next;click"
# Zoom/Einschub nach Update
POINTER_SELFTEST="url:https://de.wikipedia.org;zoom;probe;views"
# Ring-Erkennung
POINTER_SELFTEST="gestures"
# Aufklapp-Bereich der Adresse mit Daten füllen und öffnen
POINTER_SELFTEST="url:https://www.apple.com/de/;wait;favorite;url:https://de.wikipedia.org/;wait;favorite;url:https://www.heise.de/;wait;address;dir:down;dir:right"
```

---

## 15. Logpräfixe

| Präfix | Quelle | Nur DEBUG? |
|:--|:--|:--|
| `[Load] commit/layout/paint/finish +N ms host` | `BrowserWebView logLoadPhase:` | ja |
| `[DataStore] …` | `BrowserCreatePersistentWebsiteDataStore` | nein |
| `[AdBlock] …` | `BrowserContentBlocker` | nein |
| `[CookieBlock] …` | `BrowserCookieConsentBlocker handleMessageBody:` und Fehlzeile für das Bundle | ja |
| `[Input] Clickpad über GameController`, `[Input] Raten` | `BrowserRemoteInputController` | erste: nein, zweite: ja |
| `[InputTrace][App]`, `[InputTrace][NativePlayer]` | `UIApplication+BrowserSelectPressForwarding`, `BrowserNativeVideoPlayerViewController` | im Code nicht geprüft |
| `[NativeVideoPlayer]`, `[NativeVideoAssetLoader]`, `[YouTubeExtractor]` | Videoteile | im Code nicht geprüft |
| `[NowPlaying]` | `BrowserNowPlayingController` | im Code nicht geprüft |
| `[DNSProxy]` | `BrowserDNSProxy` (Verbindungs-Summary nur DEBUG) | gemischt |
| `[TopBar]` | `BrowserTopBarView` | im Code nicht geprüft |
| `[Reader] check/toggle/exit -> a|y|n|e:…` | `BrowserReaderMode` | ja |
| `[SelfTest]` | `ViewController` | ja |
| `[Probe]` | `BrowserFeasibilityProbe` | nein (nur bei gesetzter Umgebungsvariable) |
| `[FullscreenHack]` | `WebAVPlayerViewController+FullscreenSubviewHack.m` | Hack aus |

---

## 16. Offen/unklar

- Zweck des `_privacyStance`-Shims ist im Code nicht kommentiert; Commit-Historie nennt nur „WIP adding hack for supporting full screen video“. Vor Entfernen mit Konsole testen.
- `BrowserWKWebViewProofOfConceptViewController` scheint ungenutzt (nur Suche nach Verweisen im Code, kein Laufzeitnachweis).
- Für das autoconsent-Bundle gibt es kein Update-Skript; der Ablauf in 5.8 ist aus `THIRD_PARTY_NOTICES.md` abgeleitet. Eine feste Liste von Testseiten für Cookie-Banner existiert nicht im Repo (PLAN.md nennt das Durchtesten als offen).
- Scriptlets/erweiterte Regeln des Werbeblockers sind nicht umgesetzt (PLAN.md, Phase 2, offen).
- Abstimmung von Zeigerempfindlichkeit, Randscrollen, Ring und Play/Pause-Zeiten mit echter Fernbedienung ist laut PLAN.md nicht abgeschlossen.
- Test `https://1.1.1.1/help` und Langzeittests des DNS-Proxys nach Hintergrund sind laut PLAN.md offen.
- Ob `[InputTrace]`, `[NowPlaying]`, `[TopBar]` und die Video-Logzeilen nur in DEBUG erscheinen, wurde nicht für jede Zeile geprüft.
- Genaue Pfade des gebauten `.app` (DerivedData) hängen vom gewählten `-derivedDataPath` ab.
