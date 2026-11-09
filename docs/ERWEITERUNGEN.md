# Eigene Erweiterungen und Eigenbauten (Entwicklerdokumentation)

Zweck: Wenn nach einem Update von tvOS/WebKit oder einer Drittbibliothek (autoconsent, Filterlisten) etwas kaputtgeht, soll man hier schnell den passenden Baustein, die betroffenen Selektoren, das Symptom und den Test finden.

Stand: 8. November 2026, gegen den Code auf Commit `0f216e6` geprüft. Projektordner: `_Project/Browser/`, Werkzeuge: `tools/`, Plan und Historie: `PLAN.md`, Lizenzen: `THIRD_PARTY_NOTICES.md`.

Grundprinzip der App: WebKit ist **nicht gelinkt**. `BrowserWebView.m` lädt es per `dlopen` (`BrowserEnsureWebKitRuntimeLoaded`) und spricht alles über `NSClassFromString`/`NSSelectorFromString`/`objc_msgSend` an. Fehlt ein Selektor, passiert fast immer **nichts** (kein Absturz), die Funktion fällt still aus. Deshalb zählen die Logzeilen und der Selbsttest.

Menübeschriftungen ändern sich. Deshalb wird hier auf Methoden verwiesen (`extensionMenuItems`, `cookieBannerMenuItem`, `adBlockMenuItem` usw. in `BrowserMenuCoordinator.m`), nicht auf Menütexte.

## Inhalt

1. [Übersicht und Risiko](#1-übersicht-und-risiko)
2. [Checkliste nach einem tvOS-/WebKit-Update](#2-checkliste-nach-einem-tvos-webkit-update)
3. [WKWebView per Laufzeit](#3-wkwebview-per-laufzeit-browserwebview) (mit 3.1 [Beendeter Seitenprozess](#31-beendeter-seitenprozess-speichergrenze-am-apple-tv))
4. [Nutzerskripte und die userScripts-Falle](#4-nutzerskripte-und-die-userscripts-falle)
5. [Cookie-Ablehner (autoconsent) und Bezahlschranken](#5-cookie-ablehner-autoconsent-und-bezahlschranken)
6. [Werbeblocker](#6-werbeblocker-browsercontentblocker) (mit 6.10 [Filterlisten ohne App-Update aktualisieren](#610-filterlisten-ohne-app-update-aktualisieren-browserfilterlistupdater))
7. [Klickziele, Seitenfarbe, Glow-Farbe](#7-klickziele-seitenfarbe-glow-farbe-browserclicktargettracker) (mit 7.1 [Player-Brücke](#71-player-brücke-eigene-player-fremde-iframes-shadow-dom))
8. [Fernbedienung](#8-fernbedienung-browserremoteinputcontroller)
9. [Obere Leiste](#9-obere-leiste-browsertopbarview) (mit 9.1 [Reader-Modus](#91-reader-modus-browserreadermode))
10. [Video: Hooks, nativer Player, Asset-Loader, YouTube, automatische Untertitel](#10-video)
11. [DNS-Proxy (Cloudflare)](#11-dns-proxy-browserdnsproxy)
12. [Weitere Eingriffe in Systemklassen](#12-weitere-eingriffe-in-systemklassen)
13. [Start-/Verlaufsansicht, Bedienungsdialog, Tab-Übersicht](#13-start-und-verlaufsansicht-bedienungsdialog-tab-übersicht)
14. [Selbsttest und Gerätezyklus](#14-selbsttest-und-gerätezyklus)
15. [Alle Logpräfixe](#15-logpräfixe)
16. [Offen/unklar](#16-offenunklar)
17. [App-Icon und Top Shelf](#17-app-icon-und-top-shelf)
18. [Animationen (Liquid Glass / schlicht)](#18-animationen-browsermotion)
19. [Intelligente Funktionen: Zusammenfassen, Übersetzen, Sprachbefehle sinngemäß, Frag die Seite](#19-intelligente-funktionen-browserintelligence)
20. [Formen und Eckenradien](#20-formen-und-eckenradien-browsershape)
21. [Leistung: Messung, Optimierungen, Befunde](#21-leistung-messung-optimierungen-befunde)
22. [Ersteinrichtung](#22-ersteinrichtung-browsersetupviewcontroller)
23. [Altes Design](#23-altes-design)
24. [Pop-ups und unbenutzte Tabs](#24-pop-ups-und-unbenutzte-tabs-browserpopupnotice)

---

## 1. Übersicht und Risiko

Risiko bei Updates: **hoch** = nutzt private/undokumentierte APIs oder Layout-Interna, bricht erfahrungsgemäß; **mittel** = öffentliche API mit Laufzeitzugriff oder Drittcode mit fester Schnittstelle; **niedrig** = reines UIKit/Foundation.

| Baustein | Dateien | Risiko |
|:--|:--|:--:|
| WKWebView per Laufzeit, private Prefs, Zoom, Insets, Rendering-Ereignisse, eigener Datenspeicher | `BrowserWebView.m/.h` | hoch |
| Nutzerskripte, `userScripts`-Handling | `BrowserCookieConsentBlocker.m` (`refreshController:…`), `BrowserWebView.m`, `BrowserClickTargetTracker.m` | hoch |
| Cookie-Ablehner (autoconsent) + Bezahlschranken | `BrowserCookieConsentBlocker.m/.h`, `Autoconsent/bridge.js`, `Autoconsent/autoconsent.standalone.js` | mittel (Drittcode) bis hoch (Brücke hängt an Interna des Bundles) |
| Werbeblocker | `BrowserContentBlocker.m/.h`, `ContentBlocker/*`, `tools/build_adblock_rules.py`, `tools/validate_adblock_rules.swift` | hoch (Store-Pfad, Regelformat) |
| Werbeblocker, erweiterte Regeln (Scriptlets, prozedurales CSS) | `BrowserScriptletInjector.m/.h`, `Scriptlets/*`, `tools/build_scriptlets.py`, `tools/scriptlets_convert.mjs`, `tools/scriptlets-extra/` | mittel (Drittcode) bis hoch (YouTube ändert laufend, `_removeUserScript:` privat) |
| Klickziele, Seitenfarbe, Glow-Farbe, Videomeldungen | `BrowserClickTargetTracker.m/.h` | mittel |
| Fernbedienung (GameController, Presses, Ring, Magnetic Buttons) | `BrowserRemoteInputController.m/.h`, `UIApplication+BrowserSelectPressForwarding.m`, Host-Methoden in `ViewController.m` | hoch (GameController-Verhalten, `sendEvent:`-Tausch) |
| Obere Leiste | `BrowserTopBarView.m/.h`, `BrowserTabCoordinator.m` (`updateTopNavAndWebView`) | mittel (`UIGlassEffect`) |
| Nativer Videoplayer, Handover | `BrowserVideoPlaybackCoordinator.m`, `BrowserNativeVideoPlayerViewController.m`, `BrowserNativeVideoAssetLoader.m` | mittel |
| Automatische Untertitel (whisper.cpp) | `BrowserSubtitle*.m/.h`, `vendor/whisper.xcframework`, `tools/build_whisper.sh`, `tools/fetch_whisper_model.sh` | mittel (MTAudioProcessingTap, eigener HLS-Leser, Drittcode) |
| Video-Hooks, Media-Session | `BrowserClickTargetTracker.m` (`BrowserVideoHookScript`, `BrowserMediaSessionHookScript`), `BrowserNowPlayingController.m` | mittel |
| Untertitel in der Webseite (Web-Audio-Abgriff, Weg B) | `WebSubtitles/web_audio_tap.js`, `BrowserWebAudioCapture.m`, `BrowserWebSubtitleController.m`, `BrowserWebSubtitleOverlay.m` | mittel (Web Audio, CORS/DRM) |
| YouTube-Erfassung/-Extraktor | `BrowserWebView.m` (`BrowserYouTubeRequestCaptureScript`), `BrowserYouTubeExtractor.m` | hoch (Extraktion ist abgeschaltet) |
| DNS-Proxy (Cloudflare DoH) | `BrowserDNSProxy.m/.h`, `SceneDelegate.m`, `AppDelegate.m` | hoch (`nw_*`-Privacy-Context, `proxyConfigurations`) |
| Eingabedialog für Formulare (Passwörter) | `BrowserPageActionCoordinator.m`, `BrowserDOMInteractionService.m` | niedrig bis mittel |
| Adress-Bearbeiten mit Aufklapp-Bereich (Favoriten, Oft, Zuletzt), Favicons | `BrowserAddressPanelView.m`, `BrowserFaviconCache.m`, `BrowserHistoryStore.m` (alte Vollbild-Startansicht `BrowserStartViewController.m` liegt noch im Projekt, wird aber nirgends mehr aufgerufen) | niedrig |
| Adresseingabe mit Systemtastatur unter der Leiste (Diktat ohne Extraklick) | `BrowserAddressInputController.m/.h` (`UISearchController` in `UISearchContainerViewController`), Einhängung `showAddressKeyboard` in `ViewController.m` | mittel (Aufbau der Systemsuche, Abschnitt 13.1) |
| Bedienungsdialog | `BrowserGuideViewController.m` | niedrig |
| Sprachbefehle (Befehlstabelle, Parser, Router, Rückmeldung) | `BrowserCommand.m/.h`, `BrowserCommandParser.m/.h`, `BrowserCommandRouter.m/.h`, Host in `ViewController.m` | niedrig |
| Tab-Übersicht, Sitzung | `BrowserTabOverviewController.m`, `BrowserTabCoordinator.m`, `BrowserSessionStore.m` | niedrig |
| Systemklassen-Hacks | `WebCoreNSURLSessionTaskTransactionMetrics+AddPrivacyStance.m` (aktiv), `AVPlayerViewController+BrowserFullscreenBlock.m` und `WebAVPlayerViewController+FullscreenSubviewHack.m` (beide per Schalter aus) | hoch |
| Machbarkeitstest | `BrowserFeasibilityProbe.m` | niedrig |
| Animationen (Liquid Glass / schlicht) | `BrowserMotion.m/.h`, Aufrufer in Leiste, Aufklapp-Karte, Seitenleiste, Dialogen, Hervorhebung | niedrig bis mittel (`UIGlassEffect`-Materialisieren) |
| Selbsttest | `ViewController.m` (`runPointerSelfTestIfRequested`, nur DEBUG) | niedrig |

---

## 2. Checkliste nach einem tvOS-/WebKit-Update

Reihenfolge nach Wahrscheinlichkeit, dass etwas bricht. Geräteablauf siehe [Abschnitt 14](#14-selbsttest-und-gerätezyklus).

**Nach jedem tvOS-Update** (Apple TV und Xcode) die App neu aufspielen (`Installieren.command`), starten und diese Liste zumindest bis Punkt 7 durchgehen: Die App nutzt private APIs, die ein Update ohne Vorwarnung ändern kann.

1. **Startet die App überhaupt?** Abstürze beim Start: UIScene-Pflicht (`SceneDelegate`, Scene-Manifest in `Info.plist`, siehe PLAN.md), Konsole nach `UIApplicationEvaluateRuntimeIssue…` durchsuchen.
2. **Lädt eine Seite?** Logzeilen `[Load] commit/layout/paint/finish +N ms`. Fehlen `layout`/`paint`: `_webView:renderingProgressDidChange:` kommt nicht mehr an (Abschnitt 3).
3. **Datenspeicher:** Log `[DataStore] eigener Speicher in Caches, N Verzeichnisse gesetzt, store=ok`. Bei `nicht verfügbar` oder `store=nil` gehen Logins/LocalStorage nach Neustart verloren. Verzeichnisanzahl mit dem Vorwert vergleichen (aktuell bis zu 14 Selektoren, nicht alle müssen greifen).
4. **Zoom und Layout:** Selbsttest `zoom` (loggt `_viewScale`), Wikipedia öffnen (Überzoom-Fix), Klickziele bei 150 % treffen.
5. **Werbeblocker:** Logzeilen `[AdBlock] … aus Store` bzw. `kompiliert`; `Fehler`/`nicht lesbar` heißt Regelformat oder Store defekt. Danach Testseite mit Werbung. Scriptlets: `[Scriptlets] geladen: …` beim Start, im DEBUG-Build je Seite `[Scriptlets] <host> N Regeln`; YouTube-Test aus 6.9.
6. **Cookie-Ablehner:** Selbsttest mit `clearsite:`/`clearall` und `url:`, dann `[CookieBlock] …`-Zeilen. Prüfen, dass andere Nutzerskripte (Zeiger-Ziele, Video-Hooks) nach dem Umschalten noch laufen (Abschnitt 4).
7. **Fernbedienung:** Log `[Input] Clickpad über GameController: …` beim Start; sonst läuft nur der UIKit-Fallback. Mit echter Fernbedienung Zeiger, oben/unten, links/rechts, Ring, Play/Pause, Menü prüfen.
8. **Magnetic Buttons:** Zeiger auf Knöpfe und Links ziehen, Hervorhebung/Glow prüfen (liegt eng an und folgt der Rundung des Knopfs, Log `[Magnet] Ziel … Form …`, 8.3), von Link zu Link wischen (springt ein Ziel weiter, Hervorhebung ploppt am neuen Ziel auf).
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

**Objekte erzeugen: `alloc`/`new` nie über objc_msgSend.** Unter ARC gilt ein Rückgabewert aus einem Funktionszeiger als nicht besessen (+0); `alloc`/`new` liefern aber +1. `((id (*)(id, SEL))objc_msgSend)(cls, @selector(alloc))` lässt deshalb jedes Objekt am Leben (bis 8. November 2026 blieb so jede WKWebView geschlossener Tabs samt Konfiguration im Speicher, ebenso jedes `WKUserScript` der Scriptlets je Navigation). Richtig: `[cls alloc]` bzw. `[cls new]` als normale Nachricht, danach `init…` gern über objc_msgSend (das ist ausgeglichen). Gleiches gilt für `copy`/`mutableCopy`.

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
| Seite plötzlich weiß oder schwarz, Zeiger rastet noch auf alten Flächen ein, `js:` liefert für jeden Ausdruck Fehler 5 („unsupported type“), `[Reader] check -> (null)` | Seitenprozess beendet: `[WebProcess] Seitenprozess beendet (Grund …)`, Abschnitt 3.1 |

**Test.** Selbsttest-Schritte `url:`, `zoom`, `probe`, `state`, `js:`, `label`; Logzeilen `[Load]`, `[DataStore]`. Beispiel: `POINTER_SELFTEST="url:https://de.wikipedia.org;zoom;probe"`.

### 3.1 Beendeter Seitenprozess (Speichergrenze am Apple TV)
- **Befund (bild.de, 8. November 2026):** Mit frischen Cookies blieb bild.de am Gerät weiß; im Simulator nicht. Nach „Alle akzeptieren“ lädt die Seite in derselben Seite ihren kompletten Werbe-/Tracking-Bestand nach (Höhe 617 → 27.000 px, viele iframes). Rund 1 s danach beendet Jetsam `com.apple.WebKit.WebContent` wegen der Speichergrenze (`JetsamEvent-*.ips`: Grund `highwater`, 91.076 Seiten à 16 KB ≈ 1,5 GB, größter Prozess). WebKit meldet das als Absturz (Grund 3). Ohne Reaktion stand danach nur die leere WebView da; alle `evaluateJavaScript`-Aufrufe (auch `1+1`, auch in einer eigenen Inhaltswelt) liefern WKErrorDomain 5, `[Load] paint` kommt nie. Ein erneutes Laden mit gespeicherter Einwilligung bleibt unter der Grenze (geprüft mit Scrollen über 5.000 px). Der Simulator kennt die Grenze nicht. Gleiches passiert unabhängig von Ablehnen/Akzeptieren und ohne Zeiger-/Videoskripte; Ursache ist die Seite, nicht ein Eigenbau.
- **Reaktion:** `BrowserWebView` implementiert `webViewWebContentProcessDidTerminate:` und die private Variante `_webView:webContentProcessDidTerminateWithReason:` (WebKit ruft nur diese, wenn vorhanden; `_WKProcessTerminationReason`: 0 Speichergrenze von WebKit, 1 CPU, 2 von der App verlangt, 3 Absturz/Jetsam). `handleWebContentProcessTerminationWithReason:` lädt nach 0,3 s neu (wie Safari), einmal je Host innerhalb von 60 s; beim zweiten Mal Fehlermeldung über `webView:didFailLoadWithError:` (Domäne `BrowserWebContentProcess`, Dialog mit „Neu laden“). Grund 2 löst nichts aus.
- **Log (immer):** `[WebProcess] Seitenprozess beendet (Grund 3) www.bild.de -> neu laden` bzw. `-> wiederholt, kein Neuladen`.
- **Prüfen am Gerät:** `xcrun devicectl device info files --device <UDID> --domain-type systemCrashLogs` listet `JetsamEvent-…ips` (Zeitstempel = Abbruch), kopieren mit `xcrun devicectl device copy from --device <UDID> --domain-type systemCrashLogs --source <Datei> --destination x.ips`; im JSON unter `processes` den Eintrag mit `reason` suchen. Jetsam-Berichte werden gedrosselt, nicht jeder Abbruch erzeugt eine Datei.
- **Test:** `POINTER_SELFTEST="url:about:blank;clearall;wait;wait;url:https://www.bild.de;wait;js:document.readyState+' '+document.documentElement.scrollHeight;wait;wait;wait;wait"` – erwartet `payWallAccepted`, `[WebProcess] … -> neu laden`, danach `js interactive|complete … ` mit Höhe ~28.000 und sichtbarer Startseite.

### 3.2 Seitenprozesse, Tab schließen, Dateilimit
- **Mehrere WebContent-Prozesse bei einem Tab sind normal.** Jede `BrowserWebView` hat einen eigenen `WKProcessPool`. WebKit wechselt bei Navigation den Prozess (`processSwapsOnNavigation`), behält bis zu 2 ausgesetzte Seiten im Back-Forward-Cache (`_maximumSuspendedPageCount=2`, `pageCacheEnabled=1`) und wärmt 1 Prozess vor (`_prewarmedProcessCountLimit=1`, `usesWebProcessCache=0`). Ein Tab kommt so auf bis zu 4 Seitenprozesse. Eine Speicherwarnung der App gibt sie nicht frei. Stellschrauben, falls das am Gerät zu viel Speicher kostet (Zurück wird dann langsamer): `_WKProcessPoolConfiguration setPageCacheEnabled:`, `setPrewarmsProcessesAutomatically:`, `setSuspendsWebProcessesAggressivelyOnMemoryPressure:`, `WKPreferences _setUsesPageCache:`. Prüfen mit den Selbsttest-Schritten `procs` und `mem` (14.2).
- **Tab schließen:** `BrowserTabCoordinator closeTabAtIndex:` und `recreateActiveWebViewPreservingCurrentURL` rufen `-[BrowserWebView closePage]` (privat `-[WKWebView _close]`). Ohne das blieb eine WKWebView, deren Tab während des Ladens geschlossen wurde, samt Seitenprozess am Leben. Test: `mem` nach `closetab` muss `geschlossene WebViews lebend=0` zeigen.
- **Dateilimit:** Jede Verbindung über den DNS-Proxy kostet die App zwei Sockets. `BrowserDNSProxy raiseOpenFileLimit` hebt das Limit beim Start von 256 auf 4096 (Log `[DNSProxy] Limit offener Dateien 256 -> 4096`). Ohne das scheiterten nach einigen großen Seiten neue Verbindungen (Network-Fehler -24 = EMFILE, WebKit zeigt „bad URL“, -1000). Offene Dateien zählen: `lsof -p <PID> | wc -l`.

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
| `BrowserFrameVideoScript` (Manifeste und Videos in eingebetteten Frames) | document-start, alle Frames (überspringt den Hauptframe selbst) | ebenda |
| `BrowserMediaSessionHookScript` | document-start, Hauptframe | ebenda |
| `WebSubtitles/web_audio_tap.js` (nur wenn Untertitel in der Webseite an) | document-start, **alle** Frames | `BrowserWebAudioCapture installIntoUserContentController:` (in `commonInit` nach dem Cookie-Ablehner oder beim Einschalten) |
| Scriptlets (`Scriptlets/runtime.js` plus Regeln der Seite) | document-start, **alle** Frames, Seitenwelt; wird **je Navigation getauscht** | `BrowserScriptletInjector updateUserContentController:forNavigationToURL:mainFrame:` (Abschnitt 6.9) |

Nachrichten-Handler (Rückkanal, `addScriptMessageHandler:name:`): `browserTargets`, `browserVideo` (beide Tracker), `browserAutoconsent` (Cookie-Ablehner), `browserWebAudio` (Untertitel in der Webseite, Abschnitt 10.6). Die Handler-Klassen (`BrowserClickTargetMessageProxy`, `BrowserVideoMessageProxy`, `BrowserCookieConsentMessageProxy`, `BrowserWebAudioMessageProxy`) bekommen das Protokoll `WKScriptMessageHandler` per `class_addProtocol` zur Laufzeit angehängt, weil WebKit nicht gelinkt ist. Das Protokoll wird per `objc_getProtocol("WKScriptMessageHandler")` gesucht; fehlt es, wird nicht angehängt und WebKit lehnt den Handler eventuell ab.

**Die Falle.** `WKUserContentController userScripts` ist eine **Live-Ansicht** auf die interne Liste. Der Cookie-Ablehner muss sein Skript ein- und ausbauen (Schalter, Ausnahme pro Seite), WebKit kennt aber kein Einzel-Entfernen, nur `removeAllUserScripts`. Deshalb in `BrowserCookieConsentBlocker refreshController:exception:force:`:

```objc
NSArray *scripts = [NSArray arrayWithArray:((NSArray *(*)(id, SEL))objc_msgSend)(controller, scriptsGetter)];
removeAll(controller);
for (id script in scripts) { if (script != oldScript) addScript(controller, script); }
```

`[… copy]` wäre falsch: `copy` auf der Live-Ansicht gibt dieselbe Ansicht zurück, die nach `removeAllUserScripts` leer ist; dann würden **alle** anderen Skripte (Zeigerziele, Video-Hooks, Viewport-Fix, YouTube-Erfassung) verloren gehen. Symptom: Nach Umschalten von Cookie-Ablehner oder Seitenwechsel auf eine Ausnahme-Seite rasten Zeiger nicht mehr ein, Videos werden nicht mehr erkannt, Wikipedia überzoomt. Ändert Apple den Rückgabetyp von `userScripts` (z. B. `NSArray` zu Proxy-Objekt), muss die Kopie weiterhin eine echte `NSArray` mit eigenem Speicher sein.

Auch für anderen Code, der Skripte ändert: neue Nutzerskripte immer **vor** dem ersten Umschalten des Cookie-Ablehners installieren oder zusätzlich in dieser Routine berücksichtigen (sie fasst nur das eigene Skript an, lässt die übrigen aber stehen).

Der Scriptlet-Einspieler (6.9) tauscht sein Skript bei vielen Hauptframe-Navigationen. Er entfernt nur das eigene Skript mit dem privaten `_removeUserScript:` (vorhanden unter tvOS 27) und fällt sonst auf dasselbe Muster zurück (`[NSArray arrayWithArray:]`, alle übrigen Skripte neu anhängen). Die Routine des Cookie-Ablehners nimmt das Scriptlet-Skript wie jedes andere mit.

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

### 5.4a Nachlauf-Ablehnen, iframe-Signal und Störer (`bridge.js`)
- **Ablehnen-Nachlauf (`rejectScan`)**, unabhängig vom Bezahlschranken-Schalter: Alle 2 s (ab 3 s, bis 30 s) wird nach einem sichtbaren Knopf gesucht, dessen Beschriftung zu `REJECT` passt (Reject/Reject Non-Essential, Ablehnen, Nur notwendige …) und der in einem Dialog mit Cookie-/Datenschutz-Text liegt. Gründe: autoconsent erkennt manchmal das falsche CMP (The Verge: Regel `pmc-privacy-banner` statt OneTrust, meldet `optOutResult ergebnis=ja`, der OneTrust-Banner bleibt). Nie „Manage/Einstellungen“, nie „Accept“. Log: `rejectClicked`, `rejectSkip`.
- **Bezahl-Signal an iframes:** Der Zustimmen-Knopf steckt oft in einem fremden iframe (Golem: Sourcepoint `cmp-cdn.golem.de`), der Abo-Text („Golem pur bestellen“) im umgebenden Dokument. `ownPaySignal()` prüft Dokument (kurze Seite < 6000 Zeichen oder Dialog/Consent-Container mit `PAY`-Text, inkl. Knopf-/Linktexte) und sendet per `postMessage({browserPaySignal:1})` an Kindframes; diese setzen `parentPay` und scannen sofort. Log: `payWallAccepted … (Signal vom Elterndokument)`.
- **Bezahl-zuerst-Hosts (`PAY_FIRST_HOSTS`, Bild-Familie):** Dort führt Ablehnen in eine Sackgasse (Tracking-Block → Seite hält es für einen Werbeblocker, bleibt weiß/Sperrseite `adblockwall.html`). Bei aktivem `__browserAcceptPayWalls` setzt `bridge.js` `autoconsentStandalone.instance.config.autoAction = null`: autoconsent erkennt dann nur noch (Log `popupFound`, kein `optOutResult`), und die Bezahlschranken-Logik klickt „Alle akzeptieren“ im Sourcepoint-iframe (`cmp2.bild.de`, Signal vom Elterndokument; `PAY` enthält `bild plus`). Neue Hosts dieser Art in `PAY_FIRST_HOSTS` eintragen. Schalter aus → normales Ablehnen. Akzeptieren und Ablehnen schließen sich pro Frame aus (`accepted`/`rejected`). Am Apple TV sprengt bild.de direkt nach der Einwilligung die Speichergrenze des Seitenprozesses; die Seite erscheint erst durch das automatische Neuladen aus Abschnitt 3.1 (rund 10 s nach dem Klick). Nicht mit einem Fehler der Brücke verwechseln: `payWallAccepted` kam, danach `[WebProcess]`.
- **Störer:** Eigener Abschnitt am Anfang von `bridge.js`, immer aktiv, solange der Cookie-Ablehner an ist. Blendet Google One Tap (`#credential_picker_container`, `#credential_picker_iframe`, `#g_id_onload`, iframes `accounts.google.com/gsi/iframe/select`) per CSS aus, im One-Tap-iframe selbst per `html,body{display:none}`. Der normale „Mit Google anmelden“-Knopf bleibt unberührt. Neue Störer nur mit eindeutig harmlosen Selektoren ergänzen.

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
- Einstellungen: `adBlockEnabled` (Standard an), `adBlockExceptionHosts`; Menü: `adBlockMenuItem`, `adBlockSiteMenuItem`, `filterListUpdateMenuItem`
- Aktualisierung ohne App-Update: `BrowserFilterListUpdater.m/.h`, Workflow im öffentlichen Repo `dennisek-lab/tvos-browser-filterlisten`, `tools/publish_filterlists.py` (6.10)

### 6.3 Datenfluss
1. `BrowserWebView commonInit` → `applyToUserContentController:` → `prepare` (einmal): holt den Listenstand von `BrowserFilterListUpdater preferredContentBlockerSet` (mitgeliefertes `ContentBlocker/manifest.json` oder, wenn neuer, den heruntergeladenen Stand, 6.10), legt `Library/Caches/ContentRuleLists` an, erzeugt `WKContentRuleListStore storeWithURL:` und startet `startWithSet:`.
2. `processNextEntry` arbeitet die Listen **nacheinander** ab: `lookUpContentRuleListForIdentifier:completionHandler:` mit Kennung `adblock-<name>-<hash>`; nicht gefunden → `compileEntry:` entpackt die `.json.z` auf einer eigenen Queue (`decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib`, entspricht raw deflate) und ruft `compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:`.
3. Jede fertige Liste → `listBecameReady:` → `refreshAllControllersForce:NO` setzt auf allen Tabs `removeAllContentRuleLists` + `addContentRuleList:` für alle fertigen Listen. Danach `removeStaleLists` entfernt Stände mit anderem Hash. Die Signatur je Controller enthält `generation` (Zähler je Listenstand), damit ein Wechsel auf gleich viele neue Listen trotzdem neu bestückt.
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
Log beim Start lesen (`devicectl … --console`), dann Nachrichtenseite mit Werbung öffnen. Im Content-Blocker nicht umgesetzt sind `$redirect`, `$removeparam`, `$replace`, HTML-Filter (`##^`) u. a. (Zahlen in `manifest.json`, Abschnitt `sources`). Scriptlets und prozedurale Kosmetik übernimmt `BrowserScriptletInjector` (6.9).

### 6.7 Aktualisieren
```
python3 tools/build_adblock_rules.py            # lädt Listen (Cache tools/.adblock-cache), schreibt Regeln und manifest.json
python3 tools/build_adblock_rules.py --refresh  # Listen neu herunterladen
python3 tools/build_adblock_rules.py --no-register   # ohne Eintrag im Xcode-Projekt
swiftc -O tools/validate_adblock_rules.swift -o /tmp/validate_adblock
/tmp/validate_adblock _Project/Browser/ContentBlocker   # kompiliert jeden Satz mit echtem WebKit, sucht bei Fehlern per Halbierung die Regel
```
Ohne App-Update übernimmt das der Workflow `filterlisten.yml` täglich (6.10); die Schritte hier braucht es nur noch, um die **mitgelieferten** Listen (Rückfall, Stand beim ersten Start) aufzufrischen. Die Listenauswahl steht in `LISTS` am Anfang von `build_adblock_rules.py` (aus `gorhill/uBlock`, `platform/mv3/rulesets.json`, Gruppen „default“ und „malware“, dazu EasyList Germany). Nach einem Lauf ändern sich die Hashes im `manifest.json`; die App kompiliert beim nächsten Start neu und räumt alte Stände weg. Ergebnisdateien committen. `tools/add_resource.py ContentBlocker` trägt den Ordner nur einmalig als Ordnerreferenz ein; neue Dateien darin brauchen keine Projektänderung.

### 6.8 Automatische Ausnahme bei Adblock-Sperre
- **Zweck:** Seiten wie bild.de zeigen „Aufgrund Ihres Blockers zeigen wir BILD.de nicht an“. Die App erkennt solche Sperren und pausiert den Werbeblocker für diese Seite.
- **Dateien:** `ContentBlocker/adblock-wall.js` (Erkennung), Logik in `BrowserContentBlocker.m` (`handleWallMessage:`, `refreshWallController:`). Handler `browserAdblockWall`. Einstellungen: `adBlockAutoPauseOnWall` (Standard an), `adBlockAutoExceptionHosts` (Teilmenge von `adBlockExceptionHosts`). Menü: `adBlockAutoPauseMenuItem`; `adBlockSiteMenuItem` zeigt „Pausiert (Sperre)“.
- **Erkennung:** Nutzerskript document-end, alle Frames, nur im Controller, wenn Werbeblocker und Automatik an sind und die Seite keine Ausnahme hat (Ein-/Ausbau mit der Live-Ansicht-Kopie wie in Abschnitt 4). Prüft alle 1,5 s bis zu 10-mal. Treffer nur bei Blocker-Wort (Adblocker, Werbeblocker, „Ihres Blockers“, ad blocker …) **und** Aufforderung (deaktivieren, whitelist, disable …) im selben Text, und nur in einem großen sichtbaren fixierten/modalen Container, einem ganzen Sperr-iframe, einer fast leeren Seite, einer Seite mit „adblock/blocker“ im Pfad (bild.de: `/adblockwall.html`) oder einer kurzen Seite mit passender Überschrift.
- **Reaktion:** Host der Hauptseite (aus `message.webView.URL`) wird per `setException:YES` ausgenommen, in `adBlockAutoExceptionHosts` vermerkt, Seite einmal neu geladen. Schleifenschutz: pro Host einmal je App-Lauf. Eine Menüentscheidung des Nutzers (`setException:`) entfernt den Auto-Vermerk.
- **Log (DEBUG):** `[AdBlockWall] host … erkannt → Ausnahme, neu laden`.
- **Keine eingebaute Hostliste:** Die Filterliste „Adblock Warning Removal List“ (EasyList, antiadblockfilters) ist gepflegt, besteht aber aus Netzwerk-/Kosmetikregeln, nicht aus einer Liste von Sperr-Seiten. Eine Vorab-Ausnahme würde unnötig Werbung zeigen, daher nur Erkennung.
- **Hinweis:** `adBlockAutoExceptionHosts`/`adBlockExceptionHosts` überstehen `clearall` (liegen in `NSUserDefaults`, nicht im Datenspeicher). Am Gerät ist bild.de nach dem ersten Treffer dauerhaft ausgenommen, eine Sperrseite erscheint dann nicht mehr. Nachsehen: `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier io.github.tvosbrowser.app --source Library/Preferences/io.github.tvosbrowser.app.plist --destination p.plist` und `plutil -p p.plist`.
- **Test:** `POINTER_SELFTEST="clearall;url:https://www.bild.de;wait;wait;wait;wait;wait;wait;wait;wait"`. Gegenprobe ohne Treffer: spiegel.de, heise.de, `de.wikipedia.org/wiki/Werbeblocker`. Sperrtexte fehlen? `BLOCKER`/`ACTION` in `adblock-wall.js` ergänzen.

### 6.9 Erweiterte Regeln: Scriptlets und prozedurales CSS (`BrowserScriptletInjector`)

**Zweck.** Regeln, die der WebKit-Content-Blocker nicht kann, als JavaScript in die Seite: uBO-Scriptlets (`##+js(...)`), AdGuard-Scriptlets (`#%#//scriptlet(...)`), prozedurale Kosmetik (`:has-text`, `:upward`, `:xpath`, `:remove()`, `:style()`, `:matches-css`, `#?#`, `#$#`-CSS) und Kosmetik mit Platzhalter-Domains (`google.*##…`) bzw. gemischten Domains (`a.com,~b.a.com##…`). Wichtigster Fall: YouTube-Werbung (`set-constant` auf `ytInitialPlayerResponse.adPlacements/playerAds/adSlots`, `json-prune-fetch-response`/`json-prune-xhr-response` auf `/youtubei/v1/player`, `trusted-replace-fetch-response` „adSlots“ → „no_ads“ auf `get_watch`, uBOs `serverContract`-Skript per `trusted-replace-node-text`).

**Dateien.**
- `_Project/Browser/BrowserScriptletInjector.m/.h`: Singleton `sharedInjector`, lädt die Daten, baut je Seite das Skript, tauscht es aus.
- `_Project/Browser/Scriptlets/` (Ordnerreferenz): `scriptlets.json.z` (raw deflate, erzeugt), `manifest.json` (Zahlen, Gründe für Verworfenes), `extended-css.min.js` (AdGuard ExtendedCss, unverändert), `LICENSE-GPL-3.0.txt`, `runtime.js` (**handgeschrieben**, nicht vom Build-Skript erzeugt).
- `tools/build_scriptlets.py`: liest dieselben Listen wie `build_adblock_rules.py` (gleicher Cache `tools/.adblock-cache`, `LISTS` von dort), wertet die uBO-Vorverarbeitung `!#if …` aus (`ENV`: Safari, kein HTML-Filter, `ext_ubol` aus), sammelt alle Regeln, die der Content-Blocker verwirft, und schreibt die Domain→Regeln-Zuordnung.
- `tools/scriptlets_convert.mjs`: Node-Hilfsskript, wandelt mit dem Konverter aus `@adguard/scriptlets` uBO-Syntax ins AdGuard-Format und prüft die Namen.
- `tools/scriptlets-extra/`: `eigene-regeln.txt` (eigene Ergänzungen in uBO-Syntax, derzeit: `get_watch` auf YouTube von `adPlacements`/`playerAds` befreien) und eigene Scriptlets für uBO-Namen, die AdGuard nicht hat (derzeit `trusted-prevent-dom-bypass.js`: YouTube holt sich sonst aus einem leeren iframe ein unverändertes `fetch`).
- Bibliotheken (GPL-3.0, siehe `THIRD_PARTY_NOTICES.md`): `@adguard/scriptlets` (nur `dist/scriptlets.corelibs.json`, jedes Scriptlet als eigenständige Funktion `function(source, args)`), `@adguard/extended-css`. Das Build-Skript installiert beide per `npm install --ignore-scripts` nach `tools/vendor-download/scriptlets-npm` (nicht im Repo).

**Datenformat** (`scriptlets.json.z`): `names`/`fn` (Scriptlet-Name und Funktionsquelltext), `rules` (`[Funktionsindex, Argumente]`), `css` (`[Text, prozedural 0/1, Pfadbedingung?]`), `hosts` (`host` oder `name.*` → `{s: [Regelindizes], c: [CSS-Indizes]}`), `generic` (Scriptlets ohne Domain, derzeit keine), `except` (Host → abgeschaltete Indizes, `-1` = alle Scriptlets; aus `#@#+js(...)` und `~domain`).

**Datenfluss.**
1. `BrowserWebView commonInit` → `prepare`: entpackt die Daten auf einer eigenen Queue (Simulator ~25 ms; gehalten werden ~26.000 Host-Schlüssel). Kommt eine Navigation vorher, wartet sie per `dispatch_sync`.
2. `decidePolicyForNavigationAction` ruft für **jede** erlaubte Navigation (Haupt- und Unterframes) `updateUserContentController:forNavigationToURL:mainFrame:`. Einhängepunkt in `BrowserWebView.m` direkt hinter den Aufrufen von Werbeblocker und Cookie-Ablehner.
3. Hauptframe: aktiv nur, wenn `BrowserContentBlocker.isEnabled` und keine Ausnahme für die Seite (`isExceptionForURL:`). Damit gelten dieselben Einstellungen wie beim Werbeblocker (`AdBlockEnabled`, `AdBlockExceptionHosts`); das Menü lädt nach dem Umschalten neu, dadurch greift es beim nächsten `decidePolicy…`. Regeln für den Host: alle Oberdomains und `name.*`-Varianten nachschlagen, generische dazu, Ausnahmen ab.
4. Unterframe: Sein Host wird ergänzt, wenn für ihn Regeln existieren (z. B. `accounts.google.com` auf YouTube, `sp-spiegel-de.spiegel.de`). Ohne Regeln bleibt das Skript stehen.
5. Das Skript enthält nur die Funktionen und Regeln der Hosts dieser Seite (YouTube ~185 KB mit ExtendedCss, Spiegel ~13 KB). Ändert sich die Regelmenge nicht (Signatur), wird nichts getauscht. `runtime.js` läuft in jedem Frame, nimmt den Eintrag für `location.hostname` (bei `about:blank` den des Elternframes) und ruft jede Funktion mit `{name, args, engine:'corelibs', verbose:false}` auf. CSS ohne Prozedur kommt als `<style>`, prozedurales über ExtendedCss (`new ExtendedCss({cssRules}).apply()`, jede Regel vorher mit `ExtendedCss.validate` geprüft).

**Private/fragile Punkte.** `_removeUserScript:` (privat; sonst Rückfall auf `removeAllUserScripts` mit echter Kopie, Abschnitt 4). Die Aufrufkonvention der AdGuard-corelibs (`source`, `args`) und die ExtendedCss-Schnittstelle (`validate`, Konfiguration `cssRules`/`styleSheet`; `cssText` gibt es in 2.x nicht mehr). Vor allem aber die YouTube-Regeln: uBO ändert sie oft, die Liste muss regelmäßig neu gebaut werden. uBO-Scriptlets ohne AdGuard-Gegenstück fallen weg (Zahlen unter `skipped` in `Scriptlets/manifest.json`, u. a. `trusted-edit-inbound-object` für YouTube-Anfragen, `trusted-json-edit*`, `trusted-create-html`, `nobab`; HTML-Filter `##^` gehen grundsätzlich nicht). Einige uBO-Namen ordnet das Build-Skript selbst zu (`UBO_FALLBACK`, `rpnt` → `trusted-replace-node-text`, `trusted-replace-argument` mit `condition`).

**Woran man merkt, dass es kaputt ist.**

| Logzeile | Bedeutung |
|:--|:--|
| `[Scriptlets] geladen: N Scriptlets, M CSS-Regeln, H Hosts, Stand <hash> (x ms)` | Start in Ordnung (auch Release) |
| `[Scriptlets] nicht verfügbar (Daten …, Laufzeit …)` | Datei fehlt im Paket, Entpacken scheitert oder der Platzhalter `/*BROWSER_SCRIPTLET_DATA*/` fehlt in `runtime.js` |
| `[Scriptlets] <hosts> N Regeln (x KB)` | (DEBUG) Skript für die Seite eingespielt |
| `[Scriptlets] keine Regeln für diese Seite` / `aus (Schalter oder Ausnahme)` | (DEBUG) kein Skript |

Im DEBUG-Build setzt `runtime.js` je Frame `window.__browserScriptlets = {host, scriptlets, failed, css, extended, rejected, error}` (`failed`: Scriptlets, die geworfen haben; `rejected`: von ExtendedCss abgelehnte Selektoren; `error`: ExtendedCss-Fehler) und `window.__browserExtendedCss`. Im Release-Build entstehen keine globalen Namen.

**Test** (Simulator oder Gerät, Selbsttest aus Abschnitt 14):
```
# Einstiegsseite: Werbedaten im Player-Response müssen fehlen
POINTER_SELFTEST='url:https://www.youtube.com/watch?v=dQw4w9WgXcQ;wait;wait;wait;wait;js:[JSON.stringify(window.__browserScriptlets), String(ytInitialPlayerResponse.adPlacements), String(document.querySelector("#movie_player").getPlayerResponse().adPlacements), !!document.querySelector(".ad-showing")].join(" ")'
# erwartet: {"host":"www.youtube.com","scriptlets":23,…} undefined undefined false
```
Gegenprobe ohne Scriptlets: Ausnahme setzen (`xcrun simctl spawn <udid> defaults write io.github.tvosbrowser.app AdBlockExceptionHosts -array youtube.com`); dann liefert dieselbe Zeile `[object Object]`, und im Simulator lief ein 15-s-Werbeclip (`.ad-showing`). Navigation innerhalb von YouTube: `js:document.querySelector("ytd-app").dispatchEvent(new CustomEvent("yt-navigate", {bubbles: true, composed: true, detail: {endpoint: {watchEndpoint: {videoId: "kJQP7kiw5Fk"}, commandMetadata: {webCommandMetadata: {url: "/watch?v=kJQP7kiw5Fk", webPageType: "WEB_PAGE_TYPE_WATCH", rootVe: 3832}}}}}))`, danach wie oben `getPlayerResponse()` prüfen (Stand 8. November 2026: ohne Scriptlets zwei `adPlacements`, mit Scriptlets `undefined`). Prozedurales CSS: auf heise.de `<p>=== Anzeige / Sponsorenhinweis ===</p>` an `body` hängen; ExtendedCss blendet ihn und den folgenden Absatz aus.

Im Simulator spielt YouTube das Hauptvideo beim ersten Laden **auch ohne** Scriptlets nicht ab („Dieses Video kann in deinem Browser nicht abgespielt werden“). Ob Werbung wirklich wegfällt und das Video läuft, nur am Gerät beurteilen.

**Aktualisieren.**
```
python3 tools/build_adblock_rules.py --refresh   # Listen neu laden (gemeinsamer Cache)
python3 tools/build_scriptlets.py                # erzeugt Scriptlets/, trägt den Ordner bei Bedarf ins Projekt ein
python3 tools/build_scriptlets.py --refresh      # alternativ: Listen hier neu laden
```
Bibliotheksversionen stehen in `SCRIPTLETS_VERSION`/`EXTCSS_VERSION` am Anfang von `build_scriptlets.py`; nach einer Änderung neu bauen und `THIRD_PARTY_NOTICES.md` anpassen. Neue Dateien im Ordner `Scriptlets/` brauchen keine Projektänderung. `scriptlets.json.z` kommt auch per Aktualisierung (6.10), `runtime.js` und `extended-css.min.js` nur mit der App: Wer an deren Schnittstelle etwas ändert, muss `MIN_APP_FORMAT` in `publish_filterlists.py` und `kFilterListAppFormat` in `BrowserFilterListUpdater.m` erhöhen.

### 6.10 Filterlisten ohne App-Update aktualisieren (`BrowserFilterListUpdater`)

**Zweck.** Regelsätze (6.1 bis 6.7) und Scriptlets (6.9) veralten schnell, vor allem die YouTube-Regeln. Ein GitHub-Workflow baut sie täglich neu und veröffentlicht sie; die App lädt höchstens einmal am Tag den neuen Stand. Kein eigener Server, keine Kennungen, kein Tracking.

**Server-Seite (GitHub Actions).**
- **Wo:** Der Workflow liegt im eigenen, öffentlichen Repo **`dennisek-lab/tvos-browser-filterlisten`** (nur Bau-Skripte, kein App-Code). Grund: Dieses App-Repo ist privat, und Release-Dateien privater Repos lädt GitHub nur mit Zugangsschlüssel (anonym 404); einen Schlüssel baut die App nicht ein. Das Listen-Repo enthält Kopien von `tools/build_adblock_rules.py`, `build_scriptlets.py`, `scriptlets_convert.mjs`, `scriptlets-extra/`, `validate_adblock_rules.swift` und `publish_filterlists.py`. **Wer diese Skripte hier ändert, kopiert sie dorthin** (sonst baut der tägliche Lauf mit dem alten Stand).
- `.github/workflows/filterlisten.yml` (im Listen-Repo): täglich 03:17 UTC (`schedule`) und von Hand (`workflow_dispatch`, Schalter „force“ veröffentlicht auch ohne Änderung). Läuft auf `macos-latest`, weil `tools/validate_adblock_rules.swift` jeden Regelsatz mit dem echten WebKit kompiliert (gibt es nur auf macOS; für öffentliche Repos kostenlos). Schritte: `build_adblock_rules.py --refresh --out-dir out/contentblocker` → WebKit-Prüfung (bricht bei einer abgelehnten Regel ab, dann wird nichts veröffentlicht) → `build_scriptlets.py --out-dir out/scriptlets` (Node 22 für `scriptlets_convert.mjs` und `npm install` der AdGuard-Pakete) → bisheriges Manifest vom Release holen → `tools/publish_filterlists.py` → hochladen, nur wenn sich der Inhalt geändert hat.
- **Veröffentlichung:** GitHub-Release **`filterlisten-latest`** (Vorabversion, nie „Latest“), keine Dateien in `main`, kein Force-Push, keine Git-Historie mit Binärdateien. Feste Adresse der App: `https://github.com/dennisek-lab/tvos-browser-filterlisten/releases/download/filterlisten-latest/manifest.json` (GitHub leitet auf `release-assets.githubusercontent.com` um).
- **Atomar für Leser:** Dateinamen tragen einen SHA-256-Präfix (`network-1-<sha16>.json.z`, `scriptlets-<sha16>.json.z`), zuerst werden die Daten hochgeladen, das Manifest zuletzt. Dateien des vorigen Stands bleiben einen Lauf lang liegen (`keep.txt`), ältere werden gelöscht.
- `tools/publish_filterlists.py`: stellt Dateien und Gesamtmanifest zusammen, erkennt unveränderte Stände (`changed=false` → kein Upload). `build_adblock_rules.py` und `build_scriptlets.py` haben dafür `--out-dir` (impliziert `--no-register`) und schreiben `generatedAt` (Unix-Sekunden) und `date` ins Manifest.
- **Rechte:** Der Workflow verlangt selbst `contents: write` (Release) und `actions: write` (siehe unten). Er läuft nur von `main` aus (zeitgesteuerte Workflows immer vom Standard-Branch).
- **60-Tage-Regel:** GitHub schaltet zeitgesteuerte Workflows in öffentlichen Repos nach 60 Tagen ohne Repo-Aktivität ab. Der letzte Schritt aktiviert den Workflow per API erneut (`PUT …/actions/workflows/filterlisten.yml/enable`), das setzt die Frist zurück. Kommt trotzdem eine Mail „scheduled workflow disabled“: unter *Actions → Filterlisten → Enable workflow* wieder einschalten.

**Manifest** (`manifest.json` am Release):

| Feld | Bedeutung |
|:--|:--|
| `format` | Formatversion der Dateien (derzeit 1) |
| `minAppFormat` | kleinste App-Formatversion, die den Stand versteht. Die App kennt `kFilterListAppFormat` (derzeit 1) und lässt Stände mit größerem Wert liegen. Erhöhen (in `publish_filterlists.py`, `MIN_APP_FORMAT`), wenn ältere Apps die Dateien nicht mehr verstehen, z. B. wenn `Scriptlets/runtime.js` oder `extended-css.min.js` (beide nur im App-Paket) zu neuen Regeln passen müssen. |
| `version`, `generatedAt`, `date` | Gesamtstand (`JJJJMMTT-HHMM-<Regelsätze>-<Scriptlets>`), Zeitpunkt |
| `contentBlocker` | `{version, generatedAt, date, lists: [{name, file, hash, sha256, bytes, rules, jsonBytes}]}`; `hash` = SHA-256-Präfix (12) des entpackten JSON wie im mitgelieferten Manifest (Kennung `adblock-<name>-<hash>` im Store), `sha256`/`bytes` der geladenen Datei |
| `scriptlets` | `{version, generatedAt, date, library, file, sha256, bytes}` |

**App-Seite.**
- `_Project/Browser/BrowserFilterListUpdater.m/.h` (Singleton). Auslöser: `BrowserWebView webView:didFinishNavigation:` → `pageDidFinishLoading` → wenn fällig (letzte erfolgreiche Prüfung ≥ 23 h her **und** letzter Versuch ≥ 1 h her) 10 s später prüfen. Also nicht blockierend, nach dem ersten Seitenaufbau, höchstens einmal am Tag; ein langer laufender App-Prozess prüft am nächsten Tag beim nächsten Seitenaufbau.
- Verbindung: eigene `NSURLSession` (ephemeral, ohne Cookies, Cache, Zugangsdaten; User-Agent `tvOS-Browser-Filterlisten`, keine weiteren Kopfzeilen oder Parameter). Namensauflösung wie bei allen App-Verbindungen über Cloudflare-DoH (`BrowserDNSProxy` setzt das für `NW_DEFAULT_PRIVACY_CONTEXT`). Weiterleitungen nur auf HTTPS; Dateinamen aus dem Manifest nur `[A-Za-z0-9._-]`, relativ zur Manifest-Adresse. Größenbremse: Manifest 512 KB, Datei 64 MB.
- Ablauf: Manifest laden → `minAppFormat` prüfen → je Bestandteil nur, wenn `generatedAt` neuer ist als der aktuell gültige Stand (der neuere aus mitgeliefert und heruntergeladen) und die Version abweicht → Dateien laden, **Größe, SHA-256 der Datei und Inhaltskennung** (`hash`) prüfen → in einen Staging-Ordner schreiben → umbenennen → Regelsätze mit `installListSetAtDirectory:manifest:completion:` **vollständig kompilieren**, erst dann alle Tabs in einem Schritt umschalten (`generation` in der Signatur erzwingt das Neubestücken); Scriptlets mit `scriptletDataFromPackedData:` entpacken und den Aufbau samt aller Indizes prüfen, dann `activateScriptletData:` (ab der nächsten Navigation). Erst danach wird der neue Stand in `NSUserDefaults` als aktiv vermerkt und alte Ordner gelöscht. Jeder Fehler (Netz, HTTP-Status, Größe, Prüfsumme, Entpacken, WebKit-Fehler) verwirft nur den neuen Stand; die bisherigen Listen bleiben.
- Ablage: `Library/Caches/FilterLists/contentblocker/<generatedAt>-<version>/` (`manifest.json` + Regelsätze) und `…/scriptlets/<…>/`. **Caches statt Application Support**, weil tvOS Apps dauerhaftes lokales Schreiben außerhalb von `Caches` nicht zusichert (wie beim WebKit-Regelspeicher und Datenspeicher, 3. und 6.4). Räumt tvOS die Caches auf, fehlen die Dateien: beim nächsten Start gelten die mitgelieferten Listen, und kompiliert wird ohnehin neu.
- Welcher Stand beim Start gilt: `preferredContentBlockerSet` bzw. `preferredScriptletsFileURLDownloaded:` nehmen den heruntergeladenen Stand nur, wenn er vollständig da ist **und** `generatedAt` neuer ist als beim mitgelieferten. Bringt ein App-Update neuere Listen mit, gewinnen diese; der überholte heruntergeladene Stand wird bei der nächsten Prüfung gelöscht. Lässt sich ein heruntergeladener Regelsatz beim Start nicht lesen oder kompilieren, verwirft `fallBackToBundledListsAfterProblem:` den Stand und beginnt mit den mitgelieferten; die nächste Prüfung kommt dann sofort statt erst morgen.
- `NSUserDefaults`: `FilterListLastCheck`, `FilterListLastAttempt`, `FilterListContentBlockerDirectory`, `FilterListScriptletsDirectory`.
- Seitenleiste, Abschnitt *Erweiterungen*, direkt unter „Werbeblocker bei Sperre automatisch pausieren“: **„Filterlisten aktualisieren“** mit Detail „Stand TT.MM.JJJJ“ (Stand der aktiven Regelsätze; während einer Prüfung „Prüft …“). Auswählen prüft sofort ohne Tagesgrenze und meldet das Ergebnis in einem Hinweis; bei neuen Listen wird die Seite neu geladen.

**Woran man merkt, dass es kaputt ist** (alle Zeilen auch im Release):

| Logzeile | Bedeutung |
|:--|:--|
| `[AdBlock] Listenstand <version> vom <Datum> (mitgeliefert\|heruntergeladen)` | Start: welcher Stand gilt |
| `[FilterLists] prüfe <URL>` / `Server <version>: Regelsätze … (neuer\|nicht neuer), Scriptlets …` | Prüfung läuft, Vergleich |
| `[FilterLists] <name> geladen und geprüft` → `[AdBlock] umgeschaltet auf Listenstand …` → `[FilterLists] Regelsätze umgeschaltet auf …` | erfolgreich |
| `[FilterLists] <name> verworfen: Prüfsumme (SHA-256) stimmt nicht` (oder Dateigröße, Entpacken, Inhaltskennung) | Datei kaputt oder Manifest/Datei passen nicht zusammen; alter Stand bleibt |
| `[AdBlock] neuer Listenstand … verworfen: <name>: WebKit-Fehler N` | Regelsatz lässt sich auf tvOS nicht kompilieren (Workflow-Prüfung lief auf macOS-WebKit) |
| `[FilterLists] Aktualisierung nicht möglich: Server nicht erreichbar (…)` / `Server antwortet mit 404` | Netz oder Release fehlt (Workflow noch nie gelaufen?) |
| `[FilterLists] Neue Listen brauchen eine neuere App-Version` | `minAppFormat` größer als `kFilterListAppFormat` |
| `[AdBlock] heruntergeladene Listen unbrauchbar (…), nehme mitgelieferte` / `[Scriptlets] heruntergeladene Regeln unbrauchbar, nehme mitgelieferte` | Start mit kaputtem Stand, Rückfall |
| `[FilterLists] <bestandteil>: mitgelieferte Listen gelten (neuer nach App-Update oder heruntergeladene unvollständig), heruntergeladene entfernt` | App-Update hat neuere Listen gebracht (oder tvOS hat Caches geleert) |

**Test** (DEBUG, eigener Simulator, lokaler Server als Quelle):
```
python3 -m http.server 8000 --directory <ordner>   # mit <ordner>/good/manifest.json usw. aus publish_filterlists.py
SIMCTL_CHILD_FILTERLIST_URL=http://127.0.0.1:8000/good/manifest.json \
SIMCTL_CHILD_FILTERLIST_CHECK_NOW=1 \
SIMCTL_CHILD_POINTER_SELFTEST='wait;wait;wait;wait;wait;wait;url:http://127.0.0.1:8000/test.html;wait;wait;js:…' \
  xcrun simctl launch --console-pty --terminate-running-process <udid> io.github.tvosbrowser.app
```
`FILTERLIST_URL` ersetzt die Quelle (nur DEBUG, auch `http://`), `FILTERLIST_CHECK_NOW=1` prüft 2 s nach dem ersten Seitenaufbau ohne Tagesgrenze. Geprüft am 8. November 2026 (tvOS-27.2-Simulator) mit einem Teststand, der zusätzlich `flt-testwerbung\.js` blockt, `#flt-testbanner` per Regelsatz und `#flt-scriptletbanner` per Scriptlet-CSS für `127.0.0.1` ausblendet:

| Fall | Ergebnis |
|---|---|
| Server nicht erreichbar | `Aktualisierung nicht möglich`, mitgelieferte Listen bleiben, Testbanner sichtbar |
| falsche Prüfsumme (network-2, Scriptlets) | Datei verworfen (`Prüfsumme (SHA-256) stimmt nicht`), kein Rest in `Caches/FilterLists`, bisherige Listen bleiben |
| neuerer Stand | 4 Listen geladen und geprüft, `umgeschaltet auf Listenstand …`, Scriptlets umgeschaltet; Testseite: beide Banner weg, `flt-testwerbung.js` nicht angefragt |
| Neustart / danach offline | heruntergeladener Stand wird ohne Prüfung (nicht fällig) bzw. trotz Fehler weiter genutzt, weiterhin geblockt |
| Menüeintrag | „Filterlisten aktualisieren“ unter „…pausieren“ mit „Stand 08.11.2026“, Meldung „Die Filterlisten sind aktuell …“ |
| App-Update mit neueren mitgelieferten Listen | mitgelieferte gelten, heruntergeladene Ordner entfernt, Serverstand „nicht neuer“; nach Rückbau wieder Umschaltung auf den Serverstand |


---

## 7. Klickziele, Seitenfarbe, Glow-Farbe (`BrowserClickTargetTracker`)

**Zweck.** Ein Seitenskript meldet klickbare Elemente, Videos, Medieninfos, Seitenfarbe, Titel/Sitename an die App. Grundlage für magnetischen Zeiger, Leistenfarbe, Glow-Farbe, Now Playing und Bildschirmschoner-Sperre.

**Dateien.** `BrowserClickTargetTracker.m/.h`; Anbindung in `BrowserWebView.m` (`clickTargetRects`, `glowColorAtPoint:`, `videoRects`, `pageBackgroundColor`, `reportedSiteName`, `mediaInfo`), Verbraucher in `ViewController.m` (`observeClickTargetsOfWebView:`, `applyPageColorOfWebView:`).

**Datenfluss.**
- `BrowserClickTargetScript` (document-end, Hauptframe, Rückkanal `browserTargets`) sammelt per `querySelectorAll` (Links, Knöpfe, Felder, `role=button|link|tab|…`, `[onclick]`, `[tabindex]`, `contenteditable`), filtert auf sichtbar/erreichbar (`elementFromPoint`) und meldet bis zu 500 Rechtecke `[x, y, w, h, fixed, glow, text, radius, surface]` plus `v` (Videos), `p` (spielt), `m` (Medieninfo), `fs` (Vollbild), `bg` (Seitenfarbe), `ti` (Titel), `sn` (Sitename), `w` (`innerWidth`), `sx/sy`. Neu bei Scrollen/DOM-Änderungen (gedrosselt); `window.__browserTargets.report()` erzwingt (`refreshScript`).
- Seitenfarbe (`pageColor()`): oberen Rand abtasten (`elementsFromPoint` bei y=2, Overlays und iframes überspringen), sonst `meta[name=theme-color]`, sonst `body`/`html`, sonst Weiß.
- Glow-Farbe (`glow()`): Hintergrundfarbe, sonst Textfarbe des Ziels; Weiß, Schwarz, Grau und Durchsichtiges zählen als „keine“ (`-1`), dann nimmt `BrowserRemoteInputController` Standardblau. Ergebnis packt RGB in eine Zahl (`entry[5]`), `glowColorAtViewPoint:` wählt das kleinste Ziel unter dem Punkt.
- Textziel (`textLike()`, Feld 7): 1 bei reinen Textzielen (Textlink, Link im Fließtext, Navigationslink): kein Feld/Knopf/`role` außer `link`, kein `img`/`svg`/`picture`/`video`/`canvas` darin, keine eigene Hintergrundfarbe (Alpha ≤ 0,2) oder -grafik, nicht leerer Text. Hat das Ziel eine eigene Fläche (Feld 9), ist es nie Textziel.
- Form (Felder 8 und 9, seit 8. November 2026): `radius` = größter der vier Eckenradien des sichtbaren Elements in CSS-px (`getComputedStyle().border*Radius`, Prozentwerte auf die kürzere Seite umgerechnet, auf die halbe kürzere Seite begrenzt), `surface` = 1, wenn es eine eigene sichtbare Fläche hat (`surf()`: `img`/`video`/`canvas`/`picture`; Hintergrundfarbe mit Alpha > 0,1, die sich vom Hintergrund darunter unterscheidet; Verlauf oder `background-size: cover`; `box-shadow`; Rahmen an mindestens drei Seiten). Sichtbares Element (`visual()`): das Ziel selbst, wenn es Fläche hat; sonst ein eng anliegender Vorfahre mit Fläche (höchstens 3 Ebenen, höchstens 32 × 24 CSS-px größer, ≤ 120 px hoch, ohne weiteres Ziel darin, z. B. `<li class=chip><a>`); sonst ein Nachfahre mit Fläche, der ≥ 80 % des Ziels füllt (z. B. Vorschaubild in einem Link; dessen Radius ist der größte aus dem Nachfahren und seinen Hüllen bis zum Ziel, die höchstens 25 % größer sind, weil die Rundung oft an einer Hülle mit `overflow:hidden` sitzt). Dessen Rechteck ersetzt das des Ziels, die Glow-Farbe kommt dann aus seinem Stil.
- Innere Ziele (`collect()`): Liegt ein Ziel in einem schon gesammelten Ziel (`closest(SEL)`), das höchstens 40 × 24 CSS-px größer ist, entfällt es (z. B. `span[tabindex]` oder `img[role=button]` im `button`). Sonst gewann das innere als kleinstes Ziel unter dem Zeiger, und die Hervorhebung saß auf dem inneren Element statt auf dem Knopf.
- Abfrage ohne JavaScript: `shapeForViewRect:viewWidth:cornerRadius:surface:text:` (kleinstes gemeldetes Ziel, das das Rechteck enthält, Radius in pt umgerechnet) → `BrowserWebView clickTargetShapeForRect:…` → Host `browserRemoteInputControllerShapeForTarget:cornerRadius:surface:text:` (8.3).
- Zielrechteck (`boxOf()`): bei `display:inline`/`contents` mit Kind-Elementen die Vereinigung aus `getBoundingClientRect` und den sichtbaren Nachfahren (höchstens 24, je höchstens 120 CSS-px über das eigene Rechteck hinaus, ohne `visibility:hidden`/`position:fixed`). Grund: Ein Inline-`<a>` mit Block-Kindern meldet nur die eigenen Zeilenkästen. Beispiel Google-Treffer (Stand 8. November 2026): `a.zReHs` ist inline, meldet 104,179 217×45, die Kinder (Kopfzeile mit Favicon/Seitenname/`cite` und `<h3>`) liegen aber bei 104,166 bis 104,237; die Hervorhebung saß deshalb nur auf der `cite`-Zeile und überdeckte Favicon und Titel halb. Fällt das vereinigte Rechteck bei `usable()` durch, gilt das ursprüngliche. Vorher/nachher: `docs/magnetic-varianten/google-vorher.png`, `google-nachher.png`.
- Umrechnung CSS → Punkte: `viewWidth / innerWidth` (`cssViewportWidth`); seit der Meldung gescrollte Ziele wandern mit (`contentOffsetAtReport`), `fixed`/`sticky` nicht. Dazu der Einschub aus Abschnitt 3.
- `reset` bei `didStartProvisionalNavigation`.

**Fragile Stellen.** Rein JavaScript/DOM, also anfällig für seitenseitige Änderungen (Shadow DOM wird nicht durchsucht, laut Code nur `querySelectorAll`), ansonsten nur die Nutzerskript-APIs aus Abschnitt 4. Nachrichtenformat ist stillschweigend vertraut: Einträge mit weniger als 5 (Ziele) bzw. 6 (Videos) Feldern werden verworfen.

**Woran man merkt, dass es kaputt ist.** Zeiger rastet nirgends ein (Selbsttest `move`: loggt `targets=N`; bei 0 meldet das Skript nichts), Glow immer blau, Leiste bleibt weiß/schwarz. `js:` mit `typeof window.__browserTargets`.

**Test.** `POINTER_SELFTEST="url:https://de.wikipedia.org;300,400;click"`; `move`-Zeilen zeigen die Zielzahl, `label` den Seitennamen, `[TopBar] Seitenfarbe …` die erkannte Farbe.

**Aktualisieren.** Nur das Skript in `BrowserClickTargetScript()` anpassen (Selektorliste `SEL`, Farblogik, Filter).

### 7.1 Player-Brücke (eigene Player, fremde iframes, Shadow DOM)

**Zweck.** Seiten mit eigenem Player (Vimeo-/YouTube-Einbettung, Video.js, Mediathek-Player, Web Components) starten und steuern, auch wenn das Video in einem **fremden iframe** oder im **Shadow DOM** liegt oder erst beim Klick entsteht. Vorher (Stand bis c616710) landete ein Klick auf einen eingebetteten Player nur auf dem `<iframe>`-Element des Hauptdokuments (nichts passierte), und Play/Pause kannte nur Videos des Hauptdokuments, sonst öffnete es die Adresseingabe.

**Dateien.** `BrowserClickTargetTracker.m` (`BrowserPlayerBridgeScript`, `+playerBridgeContentWorld`, `+playerBridgeCommandScript:cssPoint:strict:`, `+playerBridgeClickScriptAtCSSPoint:`, `+playerBridgeScriptForFrameURL:command:`), `BrowserWebView.m` (`sendVideoCommand:…`, `playerCommand:atPoint:strict:`, `playerBridgeClickAtCSSPoint:`, `sendVideoCommand:toFrameURL:`), Verbraucher `BrowserPageActionCoordinator.m` (Klick), `ViewController.m` (Play/Pause), `BrowserVideoPlaybackCoordinator.m` (Frame-Handover). Bewusst keine neue Quelldatei (Projektdatei).

**Aufbau.**
- Nutzerskript in **allen Frames** (`forMainFrameOnly NO`), document-start, in einer **eigenen Content World** `BrowserPlayerBridge` (`WKContentWorld worldWithName:`, `initWithSource:injectionTime:forMainFrameOnly:inContentWorld:`, Aufruf per `evaluateJavaScript:inFrame:inContentWorld:completionHandler:`). Ohne Content World (ältere WebKit-Version) läuft es in der Seitenwelt, dann aber **ohne** Klicks in fremde Frames (Log `Content World nicht verfügbar …`, Klickergebnis `noiso`).
- `window.__bpb.cmd(c, x, y, strict)` / `.click(x, y)`: sucht am Punkt (CSS-Pixel des Hauptframes) mit `elementFromPoint`, steigt in **offene Shadow Roots** (Viewport-Koordinaten bleiben gleich) und in **gleich-herkünftige iframes** ab; an einem **fremden iframe** wird der Befehl mit lokalen Koordinaten (Rahmen und Innenabstand abgezogen) per `postMessage({__bpb:<Token>, c, x, y})` weitergereicht. Das Token ist pro App-Prozess zufällig (`arc4random`) und nur in der isolierten Welt sichtbar; der Empfänger prüft es und ruft `stopImmediatePropagation`.
- Klick = vollständige Ereignisfolge `pointerover/mouseover/pointerdown/mousedown/focus/pointerup/mouseup/click` am getroffenen Element (Player reagieren oft nur auf `pointerdown`/`pointerup`).
- Befehle `toggle`, `play`, `pause`, `seek:±S`, `seekto:S`: am Video unter dem Punkt (auch im Shadow DOM), sonst laufendes Video, sonst Play-Knopf des Players in der Nähe (`playish`: `aria-label`/`title`/`data-testid`/Klasse/id/kurzer Text passt auf Play, nicht auf „Playlist“ o. ä.). Hat das Video noch keine Quelle oder lehnt `play()` ab (Gestenpflicht, lazy Player), wird der Play-Knopf geklickt. `strict` (Play/Pause ohne erkanntes Video): nur wenn am Punkt wirklich ein Player oder ein laufendes Video ist, sonst `none`.
- Ergebnisse: `play`, `pause`, `seek`, `click` (Play-Knopf geklickt), `frame` (an iframe weitergereicht), `none`; Klick: `page` (Ziel im Hauptdokument, bisheriger Klickweg läuft weiter), `frame`, `shadow`, `click`, `noiso`, `none`; `nobridge` = Skript fehlt (dann bisheriger Weg).
- Zustand nach oben: Frames melden `{__bpbState: v (Video), p (läuft), b (Play-Knopf)}` an den Elternframe; der Hauptframe markiert das iframe mit `data-browser-player="1|2"`. `BrowserClickTargetScript` zählt markierte iframes als Video-Rechtecke (2 = läuft), d. h. `videoRects`/`videoPlaying` kennen jetzt auch eingebettete Player.

**Fragil.** `evaluateJavaScript:inFrame:inContentWorld:` und `WKContentWorld` werden per Laufzeit angesprochen. Geschlossene Shadow Roots sind nicht erreichbar. Seiten, die synthetische Ereignisse ablehnen (`isTrusted`), reagieren nicht auf den Klick; dann hilft meist `play()` direkt (Befehl statt Klick). Der Play-Knopf-Erkenner ist eine Heuristik (Wörter in `BrowserPlayerBridgeScript`, Regex `PLAY`/`NOPLAY`).

**Kaputt?** `[PlayerBridge] Content World eigene` fehlt beim Start; `[PlayerBridge] Klick (x, y) -> …` erscheint beim Klick auf einen eingebetteten Player nicht; Play/Pause über einem Player öffnet wieder die Adresseingabe (`[PlayerBridge] toggle … -> none`). Selbsttest `fvideo` (Videos aller Frames) und `pcmd:<Befehl>` (14.2).

**Test (Simulator, 8. November 2026).** Lokale Testseite mit sechs Playern (Hauptdokument, gleich-herkünftiges iframe, fremdes iframe, lazy Player im fremden iframe, Shadow DOM, direkt), dazu echte Einbettungen:
```
POINTER_SELFTEST="url:http://localhost:18923/yt.html;w;w;750,517;w;click;w;w;fvideo;playpause;w;fvideo;playpause;w;fvideo"
# erwartet: [PlayerBridge] Klick (500, 267) -> frame, fvideo … youtube-nocookie.com/embed/…: … paused=false,
# danach toggle -> frame, paused=true, wieder paused=false
```
| Seite | vorher | nachher |
|:--|:--|:--|
| lokal: Player im Hauptdokument | Klick und Play/Pause gehen | unverändert |
| lokal: gleich-herkünftiges iframe | Klick geht, Play/Pause → Adresseingabe | Klick und Play/Pause gehen |
| lokal: fremdes iframe | Klick ohne Wirkung, Play/Pause → Adresseingabe | Klick und Play/Pause gehen (`frame`) |
| lokal: lazy Player (Video erst nach Klick) im fremden iframe | nichts | Klick und Play/Pause gehen (`click` auf den Play-Knopf) |
| lokal: Shadow-DOM-Player | Klick ohne Wirkung (Koordinaten falsch umgerechnet), Play/Pause → Adresseingabe | Klick und Play/Pause gehen (`shadow`) |
| YouTube-Einbettung (youtube-nocookie) | Klick ohne Wirkung, `t=0 paused=true` | spielt (`t=7.9 paused=false`), Play/Pause hält an und startet |
| Vimeo-Einbettung (player.vimeo.com) | Klick ohne Wirkung | Wiedergabe startet (`paused=false`), Play/Pause schaltet; Bild bleibt im Simulator aus (`err=3`, Dekodierfehler, auch auf vimeo.com selbst) |
| plyr.io (Video.js 10, Web Components) | Klick startet, Play/Pause ohne Wirkung (Video nicht erkannt) | Play/Pause schaltet über den Play-Knopf (`click`); Medien laden im Simulator nicht (kein MSE) |
| tagesschau.de (ARD-Player, lazy) | Klick → nativer Player, Position zurück | unverändert |
| Dailymotion-Einbettung | `Forbidden` (Geo/Bot-Sperre), nicht prüfbar | – |

---

## 8. Fernbedienung (`BrowserRemoteInputController`)

**Zweck.** Zeigerbedienung der Siri Remote mit Einrasten (Magnetic Buttons), Scrollen, Sprung von Element zu Element, Ring-Geste, Play/Pause-Varianten und Menütaste.

**Dateien.** `BrowserRemoteInputController.m/.h` (Logik, Hervorhebung, Linse), `UIApplication+BrowserSelectPressForwarding.m` (globale Tastenweiterleitung), Host-Implementierung in `ViewController.m` (Methoden `browserRemoteInputController…`), `BrowserPageActionCoordinator.m` (Klick), `BrowserDOMInteractionService.m` (DOM-Koordinaten).

### 8.1 Eingabewege
- **GameController (bevorzugt):** `GCControllerDidConnectNotification` → `attachToGameController:` setzt `microGamepad.reportsAbsoluteDpadValues = YES`, `allowsRotation = NO` und `dpad.valueChangedHandler` → `handlePadValue:`. Rohwerte −1…1, `(0,0)` = Finger weg. Bewegung nur aus Differenzen (`kPadPointsPerUnit = 480` Rohpunkte je Einheit, bis 9. November 2026 640), Einzelheiten in 8.8. Log: `[Input] Clickpad über GameController: <Name>`.
- **UIKit-Fallback:** `handleTouchesBegan/Moved/Ended:` mit Indirect-Touches (iPhone/iPad-Fernbedienung). Bewegt nur, wenn der GameController-Weg die Geste nicht hat (`gameControllerOwnsTouch`: Finger liegt auf dem Clickpad oder letzte Probe < `kTouchFallbackQuietTime` 0,3 s); ist ein GameController verbunden, wartet der Rückfall zu Beginn 50 ms, ob von dort Proben kommen. Beide Wege speisen dieselbe Pipeline (8.8), nie gleichzeitig. Ignorierte UIKit-Proben zählt das Gestenlog (`UIKit ignoriert N`).
- **Presses** (`handlePressesBegan/Ended`, weitergeleitet aus `ViewController`; `UIApplication browser_sendEvent:` sieht alle Tasten vorab, greift aber nur beim Rest eines Menü-Drucks nach dem Schließen des nativen Players ein, Abschnitt 12).

### 8.2 Belegung (im Code)
| Eingabe | Aktion |
|:--|:--|
| Wischen | Zeiger bewegen (8.8), rastet ein bei `kSnapEnterRadius` 24 pt vom Zielrand; aus einem kleinen Ziel heraus springt er zum nächsten Ziel in Bewegungsrichtung (ein Ziel pro Wischgeste, 8.3 „Magnet“), frei wird er erst bei `kSnapReleaseRadius` 80 pt ohne Nachbarn; Ziele größer als 420 × 140 werden nur hervorgehoben; Randscrollen am Bildschirmrand (nur der Finger, nicht das Gleiten) |
| Auswahl (Mitte) | Klick (`performSelectAction` → Host `browserRemoteInputControllerHandlePrimaryAction`); jeder Druck kommt zweimal an (direkt über `pressesEnded:` und als Benachrichtigung aus `UIApplication browser_sendEvent:`, Abschnitt 12); die Kopie wird am gleichen `UIPress.timestamp` erkannt und verworfen (`lastDirectSelectPressEventTime`), zusätzlich bleibt die 0,15-s-Sperre |
| Oben/unten | eine Seite scrollen (`kPageScrollFraction` 0,8); **oben zweimal** (< 0,4 s) → `browserRemoteInputControllerOpenAddressBar` (Leiste ausklappen, Bearbeiten-Zustand mit Aufklapp-Bereich und sofort offener Systemtastatur, Abschnitt 13); **unten zweimal** → `browserRemoteInputControllerCompactTopBar` |
| Links/rechts | `browserRemoteInputControllerNavigateBack/Forward`: Zeiger auf laufendem Video → ±10 s (`sendVideoCommand:… seek:±10`), sonst `stepTargetBy:∓1` (Element-zu-Element; **ein Druck = genau ein Ziel**; Reihenfolge nach Zeilen, dann links→rechts – eine Zeile sind Ziele, deren Oberkante höchstens `MAX(12, halbe Höhe des kleinsten)` pt von der des ersten Zeilenziels abweicht, früher feste 24-pt-Raster, die oben bündige Knöpfe verschiedener Höhe auf zwei Zeilen verteilten; Bezugspunkt ist das zuletzt angesprungene Ziel (`lastStepTarget`), solange der Zeiger dort steht, nicht ein größerer eingerasteter Container; am Ende des Sichtbaren `scrollThenStep:` scrollt weiter und springt zum nächsten Ziel, nach 0,45 s Wartezeit auf die neue Meldung). Ziele: `browserRemoteInputControllerStepTargets` (Zeigerziele plus Videos ohne eigene Bedienelemente, obere Leiste nur am Seitenanfang) |
| Links/rechts halten | erste Wiederholung nach 0,5 s (`kArrowRepeatDelay`), dann alle 0,25 s (`kArrowRepeatInterval`) ein Sprung (`fireArrowRepeat`, nur im Zeigermodus ohne Dialog, Leistenfokus, Tab-Übersicht, Karte oder Aufklapp-Bereich); beim Loslassen nach einer Wiederholung kein zusätzlicher Sprung. Doppelt zugestellte Beginn-/Ende-Ereignisse (gleicher `UIPress.timestamp`, wie beim Auswahl-Druck) wirken nur einmal (`arrowPressBegan:`, `arrowPressEndedShouldStep:`). `UIApplication browser_sendEvent:` leitet Pfeile nicht weiter (nur Auswahl), eine zweite Zustellung über diesen Weg gibt es für Pfeile also nicht |
| Rechts zweimal (< 0,35 s, `kRightDoublePressWindow`) | Seitenleiste •••. Der erste Druck wirkt sofort (Sprung bzw. Scrollen); der zweite nimmt ihn zurück (`undoRightStep`: Zeigerposition und Scrollstand von vorher, ein noch wartendes `scrollThenStep:` wird über `stepGeneration` verworfen) und ruft `…HandleAdvancedMenuPress`. Über laufendem Video gilt das nicht (Host `browserRemoteInputControllerRightDoublePressOpensMenu` → NO, dort bleibt es bei 2 × 10 s). Unverändert: Tab-Übersicht, Aufklapp-Bereich der Adresse, Karten, Dialoge (eigene Zweige vor dem Zeigermodus) und nativer Player (Pfeile fängt `browser_sendEvent:` ab, Doppeltipp ±5 s). Im Reader (Seite in der WebView) wirkt es wie auf jeder Seite. Log `[Input] rechts doppelt: Sprung zurückgenommen, Seitenleiste` |
| Siri-Taste (kurz gedrückt) | **indirekt erkennbar** (Eingabesonde `PROBE_INPUT=1`, 9. November 2026): Ein kurzer Siri-Druck kommt außerhalb von Textfeldern als `UIPressTypeRightArrow` an, nur etwa 5 ms lang und **ohne** `buttonA`-Ereignis des GameControllers; ein echter Klick rechts dauert 100–150 ms und kommt mit `buttonA`. `rightPressIsSiriPressWithBeganTime:` erkennt daran Siri (≤ 0,04 s, kein `buttonA` in den letzten 0,3 s), `handleSiriPress` wertet zwei solche Drücke innerhalb 0,6 s als Doppeldruck → Host `browserRemoteInputControllerHandleSiriDoublePress`: Pop-up-Hinweis sichtbar → zum Pop-up-Tab springen, sonst Seite übersetzen bzw. Übersetzung beenden; offener Dialog → nichts. Ein einzelner Siri-Druck macht nichts (kein Schritt nach rechts). Im Textfeld ist Siri Diktat (privater Typ 18). Log `[Keys] Siri-Taste …` |
| TV-/Home-Taste, Lautstärke, Siri gehalten | **nicht abfangbar.** Geprüft im SDK AppleTVOS 27.2: `UIPressType` kennt nur Pfeile, Auswahl, Menü, Play/Pause, Seite auf/ab und die Tasten fremder Fernbedienungen; `GCMicroGamepad`/`GCDirectionalGamepad` liefern Clickpad, `buttonA`, `buttonX` (Play/Pause) und `buttonMenu`; `MPRemoteCommandCenter` und `UIKeyCommand` haben keine Siri-Taste. DEBUG: `attachToGameController:` loggt alle Tasten aus `physicalInputProfile` (`[Input] Tasten der Fernbedienung: …`) und jeden Druck (`[Input] GameController-Taste … gedrückt`) – am Gerät lässt sich so nachprüfen, dass die Siri-Taste nicht dabei ist |
| Play/Pause | kurz (nach 0,3 s Doppeltipp-Fenster): Video steuern, sonst Schnellmenü; lang (≥ 0,6 s): `…HandlePlayPauseLongPress` (`beginAddressEditing`, wie ein Druck auf die Leiste); doppelt: `…HandleAdvancedMenuPress` (•••-Menü, schließt vorher den Aufklapp-Bereich der Adresse). Ist ein Dialog oder die Zusammenfassung offen, schließt jede Variante nur diese Ebene (`closeDialogForPlayPause` in `ViewController.m`) Kurz im Detail (`browserRemoteInputControllerHandlePlayPausePress`): läuft ein Video oder steht der Zeiger auf einem (auch markiertes iframe, 7.1), geht das Video **vor** dem Hinweis „Seite übersetzen?“; bleibt nichts erkannt, fragt die Player-Brücke synchron am Zeiger (`playerCommand:@"toggle" atPoint: strict:YES`, Shadow DOM, fremde iframes, Play-Knopf lazy Player); erst bei `none` kommt die Adresseingabe; davor springt Play/Pause zum Pop-up-Tab, solange die Pop-up-Einblendung steht und kein Video läuft (Abschnitt 24) |
| Menü/Zurück | `browserRemoteInputControllerHandleMenuPress`, oberste Ebene zuerst: Dialog schließen → Karte „Zusammenfassung“/„Frag die Seite“ schließen bzw. „Übersetzen?“ ablehnen → Seitenvollbild verlassen → Aufklapp-Bereich → Reader → Seite zurück → sonst `NO` (System geht zum Home-Bildschirm, vorher Sitzung sichern) |
| Im Aufklapp-Bereich der Adresse | optionale Host-Methode `browserRemoteInputControllerAddressPanelActive`: Pfeile → `stepTargetInDirection:` (räumlicher Sprung: Kandidaten in Blickrichtung, Wertung Abstand + 2 × seitlicher Versatz ab Zielkante), kein Seiten- oder Randscrollen, Zeiger wird nicht ausgeblendet; Select → `browserHandlePrimaryAction` → `handleAddressEditingSelectionAtPoint:` (Feld: Tastatur wieder öffnen, `showAddressKeyboard`); Play/Pause → Tastatur wieder öffnen; Menü → schließen. Solange die Tastatur offen ist, gehören Pfeile, Klick und Menü dem tvOS-Fokus der Systemsuche (Abschnitt 13.1). Eckenradius der Hervorhebung per `browserRemoteInputControllerCornerRadiusForTarget:` (Feld: Kapselform, Kacheln: Radius des Icons), keine Linse |
| Offener Dialog (Stand 8. November 2026, Selbsttest `press:`) | **UIAlertController** (Schnellmenü, Eingabe, Favoriten, Verlauf …): Fokus von tvOS, Menü schließt (Alert selbst bzw. Host), Play/Pause kurz/lang/doppelt schließt, Klick und Zeiger wirken nicht auf die Seite (`performSelectAction`, `handlePadValue:` prüfen `PresentedViewController`). **Seitenleiste •••, Bedienungs-/„Was ist neu“-Dialog**: Menü schließt (eigene `pressesEnded`/`pressesBegan`), Play/Pause ohne Wirkung (`handlePressesEnded:` verschluckt), Pfeile und Klick gehören dem Fokus. **Tab-Übersicht**: Menü schließt, Play/Pause schließt den fokussierten Tab, ein zweiter Druck innerhalb 0,4 s wird verworfen (sonst schlösse ein Doppeldruck zwei Tabs). **Zusammenfassungs-Karte** (abgedunkelt, optionale Host-Methoden `…OverlayCardVisible`/`…DismissOverlayCard`): Klick, Menü und Play/Pause schließen, Pfeile und Wischen ruhen. **Antwort-Karte und „Übersetzen?“**: Seite bleibt bedienbar, Play/Pause gehört der Karte (nächste Stelle) bzw. der Kapsel (übersetzen). **Nativer Player** (`AVPlayerViewController`, Stand 2026-11-08): alle Tasten und Wischgesten gehören AVKit (Klick = Pause/Weiter bzw. Knopf wählen, Links/Rechts = ±10 s, oben = Knopfreihe der Transportleiste mit Untertitel-, Audio- und eigenen Menüs, Menü schließt erst Menü bzw. Leiste, dann den Player, Abschnitt 10.2). Der Rest eines Menü-Drucks, der den Player geschlossen hat, wird verworfen (`sBrowserMenuPressBeganInNativePlayer`, Abschnitt 12) |
| Ring (Kreisbewegung) | GameController: `trackRingWithPadPosition:` über die **absolute** Fingerlage: Finger am Rand (Abstand zur Mitte ≥ `kRingMinRadius` 0,8) und ≥ 110° um die Mitte (`kRingEnterAngle`), danach je 60° (`kRingStepAngle`) ein Schritt, Ringmodus bis zum Abheben (oder Finger < 0,55). Gerades Wischen kann das nicht auslösen. UIKit-Rückfall: wie bisher `trackRotationWithDelta:` (Drehung der Wischrichtung, ≥ 200°). Im Uhrzeigersinn vor, dagegen zurück; Zeiger kehrt zum Gestenstart zurück |

### 8.3 Magnetic Buttons (Hervorhebung)
Ziele (Rechtecke in `rootView`-Koordinaten) liefert der Host: `browserRemoteInputControllerPointerTargets` (Seitenziele aus Abschnitt 7 plus Knöpfe der oberen Leiste per `enumeratePointerTargetsUsingBlock:`; was unter der Leiste liegt, wird verworfen). Darstellung in `BrowserRemoteInputController`:
Eine Hervorhebung ist eine `BrowserMagneticHighlightView` (Fläche = Ziel plus Rand je nach Form, siehe „Form“) mit diesen Bausteinen (Struktur `BrowserMagneticStyle`, Werte in `BrowserMagneticStyleStandard()`):
- **Glow** (`BrowserGlowView`): Regenbogen-Ring außen (drei weichgezeichnete Schichten, Drehung 3,6 s, Atmen des Lichthofs 1,8 s), einfarbig über den Ebenenschatten, Farbe vom Host (`browserRemoteInputControllerGlowColorForTarget:`, Fallback Systemblau `0.23/0.57/1.0`). Steht still bei „Glow-Animation“ aus oder „Bewegung reduzieren“ (Abschnitt 18).
- **Refraktion** (Kantenbrechung), **seit 8. November 2026 aus** (Nutzerwunsch: überall Variante B; die Linse verdoppelte am Rand Inhalte, im Fließtext Buchstaben, bei Google-Treffern einen schmalen Streifen am linken Rand). Nur noch in den DEBUG-Varianten Z, A, C, E: `updateLensForFrame:radius:style:` nimmt per `resizableSnapshotViewFromRect:afterScreenUpdates:` einen Schnappschuss der WebView (`browserRemoteInputControllerLensSourceView`) und zeigt ihn 1,13-fach nur im 6-pt-Randband. **Kein Zoom** (seit 8. November 2026, Nutzer: „der Zoom ist verwirrend“): Die Mitte war 1,04-fach vergrößert, jetzt 1,0 und ausgeblendet (die Seite selbst ist sichtbar). Nur bei neuer Lage/Größe, nicht pro Frame.
- **Highlights**: Lichtkante der Fläche (`BrowserGlassHighlightSurfaceView`, 2-pt-Ring, oben 75 %, unten 25 % Weiß) und heller Saum der Linse (1 pt, 35 %, nur mit Linse). Keine Tönung, kein Glanzverlauf (abgeschaltet), kein Schatten, kein Abdunkeln/Aufhellen des Inhalts.
- **Erscheinen ohne Gleiten:** Der Controller hält zwei Hervorhebungen (`highlightView`, `spareHighlightView`). Bei einem neuen Ziel blendet die alte an ihrem Ort aus (0,18 s bzw. schlicht 0,12 s), die andere erscheint am neuen Ziel: Liquid Glass aus 0,92 mit der Feder `Snap`, schlicht nur Einblenden (`BrowserMotion`, auch bei „Bewegung reduzieren“). Früher glitt eine Fläche vom alten zum neuen Ziel (z. B. kam die Markierung eines Textlinks scheinbar aus dem Bild daneben). Dasselbe Ziel an neuer Stelle (Seite gescrollt, gleiche Größe nach `pointerTargetsDidChange`) folgt ohne Animation. Beide Glows laufen im gemeinsamen Takt (`BrowserGlowClockStart`), alte und neue Hervorhebung zeigen dieselbe Farbstellung.
- **Magnet** (`targetWithHysteresisFor:`, Nutzerwunsch 8. November 2026: „man kommt zu leicht raus, überspringt leicht Buttons“): In einem kleinen Ziel (≤ 420 × 140) läuft die Fingerposition höchstens bis zur Lösegrenze über den Rand (Rohlage begrenzt, keine aufsummierte Bewegung). Ist sie `kSnapHandoffDistance` 28 pt draußen oder liegt sie in einem anderen Ziel, wechselt der Zeiger zum nächsten Ziel in Bewegungsrichtung (`neighborTargetOf:towardPoint:`: Kegel ±60° ab der Austrittsstelle, Lücke ≤ `kSnapHandoffReach` 220 pt, Wertung Abstand + 2 × seitlich) und steht in dessen Mitte (`hopToTarget:`). Pro Wischgeste ein Wechsel; ein weiterer nur, wenn seit dem letzten Wechsel `kSnapRepeatTravel` 160 pt Zeigerweg zurückgelegt sind und der Zeiger gerade ≥ `kSnapRepeatMinSpeed` 1400 pt/s schnell ist (lange, schnelle Wischer); sonst hält das Ziel den Zeiger (`holdPointerAtTarget:margin:`). Ohne Nachbarn wird der Zeiger erst bei `kSnapReleaseRadius` 80 pt frei. Zeigertempo wirkt weiter (Weg und Geschwindigkeit sind nach der Beschleunigung gemessen). Große Ziele, Sprünge per links/rechts und Selbsttest-Punkte verhalten sich wie bisher.

| Wert | vorher | jetzt |
|:--|:--|:--|
| Lösen (`kSnapReleaseRadius`) | 48 pt | 80 pt (nur ohne Nachbarn) |
| Wechsel zum Nachbarn | sobald der Finger in einem anderen Ziel liegt, beliebig oft | ab 28 pt über den Rand bzw. im Nachbarn, Ziel in Bewegungsrichtung ≤ 220 pt |
| Wechsel pro Wischgeste | unbegrenzt (Bewegung lief frei weiter) | 1; weitere nur nach je 160 pt bei ≥ 1400 pt/s |
| Bewegung im Ziel | sammelte sich in der Fingerposition an | begrenzt auf Ziel + 82 pt, nach Wechsel Mitte des neuen Ziels |
| Mitte der Linse | 1,04-fach | 1,0 (kein Zoom) |
| Zielwechsel der Hervorhebung | Fläche gleitet (Feder) | alte blendet aus, neue ploppt auf |

Gemessen im Simulator (`swipe:`, heise.de-Navigation ab „Security“, Wikipedia ab „iTunes“), siehe 8.6.

**Standard seit 8. November 2026 (zweite Fassung):** alle Ziele wie Variante B, also ohne Refraktion, mit Lichtkante und Glow (`BrowserMagneticStyleStandard()`, `lens = NO`). Die erste Fassung wollte Textlinks eng (Variante F) und Knöpfe mit Linse (A), erkannte Textziele aber nur, wenn eine DEBUG-Textvariante gesetzt war; Textlinks hatten deshalb 6 pt Rand und Linse.

**Form (formgenaue Hervorhebung).** `showHighlightForTarget:animated:` fragt pro Zielwechsel die Form ab (Zwischenspeicher, kein JavaScript):
1. Ziele der eigenen Oberfläche: `browserRemoteInputControllerCornerRadiusForTarget:` ≥ 0 (Aufklapp-Bereich, Adressfeld, Pop-up-Einblendung) → Rand 6 pt, Ecken `Radius + 6`, unverändert. Knöpfe der oberen Leiste liefern keine Form (Host-Methode gibt NO) → Rand 6 pt, Kapsel/Kreis wie bisher (`BrowserMagneticDefaultRadius`).
2. Seitenziele: `browserRemoteInputControllerShapeForTarget:cornerRadius:surface:text:` (Abschnitt 7, Felder 7–9).
   - **Eigene Rundung** (`border-radius` > 0,5 pt): Die Hervorhebung übernimmt sie dynamisch, Ecken = Element-Radius + Rand (höchstens halbe kürzere Seite). Pille bleibt Pille, Kreis bleibt Kreis, 4-px-Ecken bleiben knapp (konzentrisch, die Knopfecke bleibt innerhalb des Rands). Bei einem Vorschaubild zählt auch die Rundung der umschließenden Hülle (YouTube: `img` eckig, Hülle mit `overflow:hidden` 12 px).
   - **Eckige Fläche** (sichtbarer Hintergrund, Radius 0, z. B. eckige Knöpfe und Bilder): konzentrisch anliegend, Ecken = Rand 2,5 + `kMagneticSquareExtraRadius` 4 pt; die Knopfecke bleibt innerhalb (Grenze: Ecken ≤ Rand × 3,4). Am 9. November 2026 kurz mit Kapsel bzw. 40 pt versucht: Die Knopfecken ragten in Lichtkante und Glow, der Nutzer wollte bei Knöpfen mit Fläche Anschmiegen statt Rundung.
   - **Keine eigene Fläche und keine Rundung** (Textlinks, Symbole, Google-Treffer, Karten ohne Hintergrund): wie Bedienelemente seit iOS 26 bis `kMagneticCapsuleMaxHeight` 80 pt Höhe als **Kapsel**, höhere Ziele mit einer Rundung von einem knappen Drittel der Höhe (`kMagneticCornerHeightFraction` 0,32, mindestens `kMagneticDefaultCornerRadius` 22 pt, höchstens `kMagneticMaxCornerRadius` 40 pt; ein 130 pt hoher Knopf bei Seitenzoom 175 % bekommt 40 pt), kontinuierliche Kurve. Vorher bekamen eckige Flächen nur Rand + 4 pt (≈ 6,5 pt Ecken); der Nutzer fand die Linse zu eckig.
   - **Rand:** Knöpfe mit eigener Fläche oder Rundung `kMagneticTightPadding` 2,5 pt (liegt eng an), Textlinks 3 pt, sonst 6 pt.
   Kontinuierliche Kurve überall: `cornerCurve = kCACornerCurveContinuous` auf Hervorhebung, Fläche und Linsenbehälter; Glow und Lichtkante zeichnen mit `UIBezierPath bezierPathWithRoundedRect:cornerRadius:` (ebenfalls kontinuierlich).
   Früher lieferte der Host für Seitenziele immer −1, und jedes Ziel unter 80 pt Höhe wurde zur Kapsel mit 6 pt Abstand, auch ein eckiger Knopf mit 4 px Rundung.
   DEBUG-Log pro neuem Ziel: `[Magnet] Ziel x,y w×h Form Seite|App|unbekannt Radius r Fläche 0/1 Text 0/1 → Rand p Ecken e`.

Gemessen am Gerät (Apple TV 4K, 8. November 2026, Selbsttest mit `x,y`-Schritten, Bildschirmfotos während des Laufs), vorher (main ff073fc) → nachher:

| Seite, Ziel | Form laut Seite (pt) | vorher | nachher |
|:--|:--|:--|:--|
| github.com „Sign up“ | Radius 10,5, Fläche | Kapsel, 6 pt Rand, Linse | Ecken 13, Rand 2,5 |
| wikipedia.org Suchknopf | Radius 3,5, Fläche | Kapsel (Oval), Linse | Ecken 6, Rand 2,5 |
| google.com „Anmelden“ | Pille (35), Fläche | Kapsel, 6 pt Rand, Linse | Kapsel, Rand 2,5 |
| google.com Apps-Knopf | Kreis (35), ohne Fläche | Kreis, 6 pt Rand | Kreis, Rand 2,5 |
| youtube.com Chip „Shorts“ | Radius 14, Fläche | Kapsel, Linse | Ecken 16,5, Rand 2,5 |
| youtube.com Vorschaubild | Hülle 21, Bild | Ecken 34, 6 pt Rand, Linse | Ecken 23,5, Rand 2,5 |
| google.com Reiter „Videos“ | Textlink, 84 hoch | Kapsel (Oval), Linse | Squircle 12, Rand 3 |
| google.com Treffer | keine Fläche, 124 hoch | Ecken 34, Linse (Doppelstreifen am linken Rand) | Squircle 12, ohne Linse |
| de.wikipedia.org Textlink „Fernsehgerät“ | Radius 3,5 | Kapsel, Linse verdoppelt Buchstaben am Rand | Ecken 6,5, Rand 3 |
| obere Leiste „Zurück“ | (App) | Kreis | Kreis (unverändert) |

Bilder: `docs/magnetic-varianten/form-*.png` (je links vorher, rechts nachher): `form-github-knopf`, `form-wikipedia-suchknopf`, `form-google-pille`, `form-google-kreis`, `form-youtube-chip`, `form-youtube-vorschau`, `form-google-reiter`, `form-google-treffer`, `form-wikipedia-textlink`, `form-leiste-unveraendert`.

**Varianten zum Vergleich (nur DEBUG).** Schlüssel `MagneticVariant` (Selbsttest `pref:MagneticVariant=B`, leer = Standard); ein Wechsel baut die Hervorhebung sofort neu auf. Z alte Linse mit Mitte 1,04-fach, A alte Linse ohne Zoom, B ohne Refraktion (Text mit 6 pt Rand), C Linse ohne Highlights, D nur Glow (Z/A/B/C/D auch für Text mit 6 pt Rand); die Form-Geometrie (Rand, Ecken) gilt in allen Varianten; nur für Textziele (Abschnitt 7, Feld 7): E Fläche 3 statt 6 pt, F 3 pt ohne Refraktion, G getönte Fläche (Linkfarbe 16 %), H 2-pt-Kontur, I Unterstreichung (3 pt). Glow in allen gleich. Bilder: `docs/magnetic-varianten/` (`kontaktabzug.png`, je Fall `fall-text.png`, `fall-nav.png`, `fall-knopf.png`, `fall-bild.png`). Aufnahme: eigener Simulator, Selbsttest pro Seite `pref:MagneticVariant=<V>;<x,y>;pref:Shot=<V>_<fall>` im Abstand 2 s, Screenshot nach jeder `pref Shot`-Logzeile (Hilfsskripte im Scratchpad, nicht im Repo).

- **Zeigerbilder:** `BrowserCursorRenderer` (eigene Vektorzeichnung per `UIBezierPath`/`UIGraphicsImageRenderer`, 3-fach gerastert, kein Apple-Bildmaterial; die alten PNGs `Cursor`/`Pointer` im Asset-Katalog sind ungenutzt). Arten: Pfeil, Hand (Zeigefinger, nur bei großen Zielen oder in der Tabübersicht sichtbar, sonst ersetzt die Hervorhebung den Zeiger), I-Beam (noch ohne Aufrufer). Stile in `BrowserPreferencesStore.cursorStyle` (Schlüssel `CursorStyle`, additiv, kein Menüeintrag): 0 macOS-Stil (Pfeil schwarz mit weißem Rand, Hand weiß mit schwarzem Rand, Standard), 1 invertiert, 2 SF Symbols (`cursorarrow`, `hand.point.up.left.fill`, Kontur durch 16 versetzte Kopien, Spitze per Pixelsuche). Höhe etwa 44 pt.
  **Hotspot:** `BrowserCursorImageView` (Unterklasse von `UIImageView`, in `BrowserRemoteInputController` als `cursorView` angelegt) zeichnet das Bild in einer inneren Ansicht, versetzt um `+[BrowserCursorRenderer hotspot]` (30/14 pt Rand für Kontur, Schatten, Daumen). So bleibt `cursorView.frame.origin` die Klickspitze, und alle Hosts (`DOMPointForCursorOrigin:` usw.) bleiben unverändert. Wichtig: `image` der Oberklasse bleibt leer (Setter überschrieben, Getter nicht), sonst zeichnet UIImageView zusätzlich ein zweites, verkleinertes Bild.
  **Test:** `POINTER_SELFTEST="url:https://de.wikipedia.org/wiki/Apple_TV;wait;wait;wait;672,910;wait"` plus Stil per `xcrun simctl spawn <udid> defaults write io.github.tvosbrowser.app CursorStyle -int N`; `770,566;click` trifft den Link „Bildschirm“ (Seite lädt neu). Screenshots in `docs/cursor-screens/` (`zeiger-varianten.png` Kontaktbogen; Zeiger verschwindet nach kurzer Ruhe, Screenshot direkt nach dem `move`-Log aufnehmen).

### 8.4 Private/fragile Punkte
- GameController: Verhalten von `GCMicroGamepad` mit absoluten Werten (Wertebereich, Nullwert beim Loslassen als „nicht berührt“: `handlePadValue:` wertet `(0,0)` als Loslassen). Ohne `respondsToSelector`-Fallback, aber der UIKit-Fallback übernimmt, wenn keine Proben kommen.
- Hängt von `UIPress`-Typen und davon ab, dass die Taste sowohl über `pressesEnded` als auch global ankommt (Doppelzustellung, Entprellung 0,15 s).
- Kantenbrechung (nur DEBUG-Varianten) nutzt öffentliche UIKit-API, ist aber layoutabhängig (`source.window`, Rechteck innerhalb der Quelle).
- Formerkennung rein über `getComputedStyle`: Knöpfe, deren sichtbare Form aus `::before`/`::after`, `clip-path`, SVG-Hintergründen oder `mask` stammt, gelten als „unbekannte Form“ (Vorgabe-Kapsel).
- Abstimmungswerte (`kSnapEnterRadius`/`kSnapReleaseRadius`, `kPadPointsPerUnit`, Beschleunigung, `kRingMinRadius`, Gleiten) sind nur synthetisch geprüft, noch nicht mit echter Fernbedienung abgestimmt.
- Annahmen über die Hardware, die das Gestenlog am Gerät bestätigen oder widerlegen soll: Achsen kommen beim Aufsetzen/Abheben einzeln (`Achsen einzeln N`), Ausreißer beim Abheben (`Ausreißer verworfen N`), Wertebereich am Ring (`Radius max`).

### 8.5 Woran man merkt, dass es kaputt ist
| Symptom | Ursache |
|:--|:--|
| Zeiger ruckelt/träge | kein `[Input] Clickpad über GameController`-Log → UIKit-Fallback; Gestenlog `[Pointer] Geste …`: Proben/s, `Δt` max (Hauptschleife blockiert), `Alter Fingerlage` |
| Zeiger hüpft zurück | Gestenlog `Rückschritte` > 0; `Ausreißer verworfen`/`Achsen einzeln` prüfen; Selbsttest `swipe:` (`zurück nach Loslassen` muss 0 sein) |
| Ring löst nie aus | `Radius max` im Gestenlog < 0,8 → `kRingMinRadius` senken |
| Zeiger springt beim Drücken | `pressInProgress`-Unterdrückung greift nicht (Presses kommen nicht an) |
| Doppelte Klicks | Entprellung/`lastDirectSelectPressTimestamp` |
| Kein Einrasten | `move`-Selbsttest meldet `targets=0` (Abschnitt 7) |
| Hervorhebung als Kapsel statt in Knopfform | `[Magnet]`-Log: `Form unbekannt` (kein Ziel passt zum Rechteck) oder `Radius 0 Fläche 0` (Seite zeichnet die Form anders, 8.4) |
| Zeiger springt mehrere Ziele weit / hängt fest | `[Pointer] Magnet: Wechsel zu … (Wechsel in dieser Geste: N)`; Werte `kSnapHandoff…`/`kSnapRepeat…` |
| Ring springt nie / immer | Selbsttest `gestures` (siehe unten) |
| Tasten kommen im nativen Player doppelt an | `[InputTrace][App] …`-Zeilen, Abschnitt 12 |

### 8.6 Test
- Selbsttest (ohne Fernbedienung, DEBUG): `press:<taste>[@ms]` (Taste über die Responder-Kette, auch bei offenem Dialog, Abschnitt 14.2), `x,y` (Zeiger setzen, loggt `move … targets=N`), `click`, `left`/`right` (loggt `overVideo`, danach `Zeiger … scroll=…`), `next`/`prev` (Sprung), `gestures` (loggt `cw1.5`, `ccw1`, `line`, `quarter`; erwartet: Kreise > 0, Gerade und Viertelkreis = 0), `swipe:dx,dy,ms[,flick|clean|flickclean]` und `ring:radius,grad,ms` (8.8), `playpause`, `menu`.
- Magnet: `POINTER_SELFTEST="url:https://www.heise.de/;wait;wait;wait;wait;478,227;swipe:0.15,0,300;478,227;swipe:0.6,0,1200;478,227;swipe:0.8,0,250"` mit `POINTER_SELFTEST_INTERVAL=3`. `[PointerTest] Ziel danach …` nennt das Ziel nach dem Wischen und die Zahl der Wechsel. Erwartet (8. November 2026): kurz → „IT & Tech“ (1 Wechsel), lang langsam → „IT & Tech“ (1), lang schnell → mehrere (6 bis zum Ende der Leiste).
- Echte Fernbedienung: Zeigerbewegung, oben/unten, links/rechts über Video, Ring, Play/Pause kurz/doppelt/lang, Menü.

### 8.7 Aktualisieren
Kein externer Teil. Werte in `#pragma mark - Abstimmung` und `#pragma mark - Abstimmung Zeigerpipeline` (oben in der Datei) sowie in den Konstanten der Abschnitte „Ring über die absolute Fingerlage“ und „Kreisgeste“ anpassen.

### 8.8 Zeiger-Pipeline

**Warum.** Rückmeldung vom Gerät (8. November 2026): Zeiger „nicht flüssig, verzögert, springt, hüpft zurück“. Gefundene Ursachen in der alten Fassung (jede Probe bewegte sofort, Beschleunigung pro Probe):
1. Beschleunigung aus dem Abstand zweier Proben (`dx/dt` mit der Uhrzeit beim Eintreffen): gebündelt eintreffende Proben ergeben winzige `dt`, die Verstärkung springt von Probe zu Probe zwischen etwa 0,9 und 2,6.
2. Ausreißer beim Abheben (Fingerkuppe rollt ab) wurde voll angewandt und durch (1) noch verstärkt: synthetisch 75–83 pt Rücksprung.
3. Achsen, die beim Abheben einzeln auf 0 fallen (`(0, y)` vor `(0, 0)`), galten als Bewegung zur Mitte: synthetisch bis 357 pt Rücksprung. Ebenso beim Aufsetzen (`(x, 0)` vor `(x, y)`): Sprung.
4. Kreiserkennung über die Drehung der Wischrichtung: lange, leicht krumme Bewegungen summieren Rauschen auf; bei 200° setzte sie den Zeiger an den Gestenstart zurück.
5. Einrasten: Sprung zur Zielmitte (animiert 0,09 s) und beim Lösen Sprung zur Fingerposition; Lösen (28 pt) enger als Einrasten (36 pt), also keine Hysterese.
6. Nach 4 s Ruhe schluckte die ganze erste Wischbewegung (nur Einblenden); das fühlte sich wie Verzögerung an (`kRevealConsumesFirstSwipe`, jetzt NO; der erste Klick nach Ruhe zeigt weiterhin nur den Zeiger).
7. Ungleichmäßig: pro Bild mal keine, mal zwei Proben (synthetisch Schwankung der Schrittweite 60–86 %, 2–3 von 8 Bildern ohne Bewegung).

Nicht die Ursache: Hit-Tests per JavaScript während der Bewegung (Ziele kommen aus dem Zwischenspeicher von `BrowserClickTargetTracker`; synchrones JS nur beim Klick). Rechenzeit pro Bild gemessen 0,1–0,3 ms.

**Ablauf.**
1. *Eingabe:* GameController-Probe → `handlePadValue:`. Aufsetzen setzt nur den Bezugspunkt. Proben mit genau einer Achse 0 bewegen nichts (Übergang), der Bezugspunkt bleibt. Sprünge > `kPadMaxSampleJump` (0,35) werden verworfen. Verdächtige Proben (entgegen der Bewegung oder > 3 × übliche Schrittweite) hält `padHeldDelta` zurück, bis die nächste sie bestätigt (höchstens `kPadHoldMaxAge` 25 ms); kommt das Abheben, werden sie verworfen. UIKit-Rückfall: `enqueueRawPointerDelta:…`.
2. *Proben:* `acceptRawDelta:atTime:` speichert Ankunftszeit und aufsummierte Rohbewegung (Ring mit 32 Einträgen).
3. *Bildtakt:* `CADisplayLink` (`pointerFrame:`, 60–120 Hz, läuft nur bei Bedarf). Nachabtastung: Fingerlage zum Zeitpunkt „jetzt − `kResampleFactor` × mittlerer Probenabstand“ (4–12 ms), linear zwischen den umgebenden Proben, **nie extrapoliert** (kein Vorauslaufen, kein Zurückfedern).
4. *Beschleunigung:* Verstärkung aus der Fingergeschwindigkeit über `kSpeedWindow` (35 ms), S-Kurve `kGainMin` 0,8 … `kGainMax` 1,9 zwischen 150 und 2200 Rohpunkten/s (bis 9. November 2026 2,6 ab 1700 bei 640 Rohpunkten je Einheit und 140 pt Auslauf, jetzt 100 pt: ein kurzer schneller Wisch lief über den halben Bildschirm; schnelles Wischen trägt jetzt etwa halb so weit, langsames Führen etwa drei Viertel), mal Zeigertempo (`BrowserPreferencesStore.pointerSpeed`, Schlüssel `PointerSpeed`, 0,3–3, Standard 1; kein Menüeintrag).
5. *Glättung:* 1-€-Filter (`kFilterMinCutoff` 20 Hz + `kFilterBeta` × Geschwindigkeit) von `rawPoint` nach `freePoint`; Tiefpass erster Ordnung, schießt nie über.
6. *Einrasten:* `targetWithHysteresisFor:` (Magnet mit Weiterreichen, 8.3). Kleine Ziele ziehen den sichtbaren Punkt Richtung Mitte (`kSnapPull` 0,85, im Ziel geklemmt); die Anziehung nimmt mit dem Abstand der Fingerposition vom Zielrand stufenlos ab und ist an der Lösegrenze null (`visiblePointForTarget:emergence:`). Lösen also ohne Sprung, der Pfeil taucht ab halbem Weg wieder auf. Zielwechsel und Sprünge (links/rechts, Ring) gleiten mit `kSnapEaseTimeConstant` 45 ms. Liegt der Finger in einem anderen Ziel, wechselt es sofort (dicht stehende Links).
7. *Zeigerebene:* `placeCursorAtPoint:` setzt `cursorView.frame` in `CATransaction setDisableActions:YES`, keine UIView-Animation. Die Hervorhebung wird nur bei neuem Ziel neu aufgebaut (`highlightShownTarget`), Ziele einmal pro Bild geholt (`frameTargets`).
8. *Gleiten:* Hebt der Finger in Fahrt ab (letzte Bewegung ≤ 40 ms vorher, ≥ `kGlideMinSpeed` 600 pt/s), läuft der Zeiger exponentiell aus (`kGlideTimeConstant` 90 ms, höchstens `kGlideMaxDistance` 140 pt). Endet am Bildschirmrand (scrollt nie) und wenn ein kleines Ziel ihn fängt. Abschaltbar: `BrowserPreferencesStore.pointerGlideEnabled` (Schlüssel `PointerGlideEnabled`, Standard an; kein Menüeintrag). Neue Berührung oder Klick hält sofort an der sichtbaren Stelle an (`discardPendingMotion`).
9. *Klick:* `commitPointerForClick` beendet Gleiten und Übergang und setzt die Zeigerebene in einem eingerasteten Ziel auf den angezogenen Punkt im Ziel, damit `cursorView.frame.origin` es sicher trifft.

**Messung (DEBUG).** Nach jeder Geste: `[Pointer] Geste GameController|UIKit: Dauer, Proben (N/s, Abstand ms, UIKit ignoriert N), Bilder (Δt mittel/max), Alter Fingerlage beim Anzeigen mittel/max ms, Rechenzeit, größter Schritt, Sprünge (Schritt > 20 pt und > 2,5 × vorheriger), Rückschritte (Schritt > 1 pt gegen die Bewegungsrichtung), Achsen einzeln, Sprünge verworfen, Ausreißer verworfen, Auslauf pt, Radius max`.

**Selbsttest.** `swipe:dx,dy,ms[,flick|clean|flickclean]` speist künstliche Clickpad-Werte (Einheiten, ganze Breite = 2) über `handlePadValue:` ein, Proben im Wechsel 7/15 ms. Ohne `clean` mit nachgebildeten Hardware-Eigenheiten (Achsen einzeln beim Aufsetzen und Abheben, Ausreißer 0,05 entgegen der Richtung vor dem Abheben); `flick` hebt in voller Fahrt ab. Gemessen wird die sichtbare Zeigerebene (`presentationLayer`) pro Bild: `[PointerTest] … Schritt (CV = Schwankung der Schrittweite im mittleren Abschnitt), Rücksprünge, Weg bis Loslassen, Auslauf, zurück nach Loslassen, Ende`. `ring:radius,grad,ms` kreist im Uhrzeigersinn: `ring:0.9,300,700` → 4 Schritte, `ring:0.5,300,700` → 0. Beispiel:
`POINTER_SELFTEST="url:about:blank;500,600;swipe:0.6,0,300;500,600;swipe:0.6,0,300,flick;960,700;ring:0.9,300,700"`

| Messung (Simulator, synthetisch) | alt | neu |
|:--|:--|:--|
| Rücksprung nach Loslassen, mit Hardware-Eigenheiten | 75–357 pt | 0 pt |
| Rücksprung ohne Eigenheiten | 0 pt | 0 pt |
| Schwankung der Schrittweite (CV), gleichmäßiges Wischen | 60–86 % | 35–45 % |
| Bilder ohne Bewegung, während der Finger wischt | 2–3 von 8 | 0 |
| Alter der gezeigten Fingerlage beim Anzeigen | sofort beim Eintreffen, dann bis zum nächsten Bild (ungleichmäßig) | ~26 ms, davon 16,7 ms Bildaufbau |
| Ring bei Kreis im inneren Bereich (r 0,5) | (Richtungs-Erkennung, rauschanfällig) | 0 Schritte |
| Rechenzeit pro Bild | – | 0,1–0,3 ms |

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
- Bearbeiten-Zustand: `setAddressEditing:animated:` (eigener Abschnitt am Ende von `BrowserTopBarView.m`, eigene Subviews `dictationFieldView`/`dictationIconView`/`dictationLabel`). Die Kapsel zeigt mittig Mikrofon `mic.fill` und „Sprechen, um zu diktieren“ (halbtransparent), alle Knöpfe, Name und Kreisel auf Alpha 0. Einziges Zeigerziel ist dann `addressFieldFrame` (Aktion `BrowserTopBarActionURL`); `setCompact:YES` wird solange ignoriert. Die eigentliche Eingabe ist die Systemtastatur direkt darunter (`BrowserAddressInputController`, Abschnitt 13.1); die Leiste selbst nimmt keinen Text an.
- Jeder Druck auf Adresse oder Kapsel (`performTopBarAction:` mit `BrowserTopBarActionURL`, auch im Fokusmodus) geht an `beginAddressEditing`; es gibt keinen zweiten Weg in eine andere Eingabe mehr.
- Kanteneffekt des Systems: `attachToScrollView:`.
- Zeigerziele: `enumeratePointerTargetsUsingBlock:`; Fokusmodus (tvOS-Fokus statt Zeiger) für die Knöpfe über `BrowserTopBarFocusButton`.
- Altes Design (graue Kapsel, Originalsymbole, volle Adresse, kein Glas): `applyDesign`, siehe Abschnitt 23.

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

**Text ohne Overlay** (für Zusammenfassen, Abschnitt 19). `+[BrowserReaderMode textForWebView:maxLength:completion:]` ruft `window.__browserReader.text(max)` auf: Readability auf einer Kopie des Dokuments, Ergebnis per `DOMParser` (inert, lädt keine Bilder) zerlegt, nur `p`/`li`/`blockquote`/`dd` ohne `nav`/`table`/`figure`/`sup`/Formulare, Fußnotenzeichen `[1]` entfernt, Absätze mit Leerzeile, auf `BrowserReaderDefaultTextLength` (6.000 Zeichen) gekürzt. Ohne Readability-Ergebnis Rückfall auf `article`/`main`/`body` (`source` = `body` bzw. `…-raw`). Rückgabe JSON `{title, site, lang, source, text, total}`; die Seite bleibt unverändert, ein laufender Reader bleibt an.

**Private/fragile Stellen.** Kein privates API. Anfällig: (a) das Ausblenden per `html.__rd > body > *:not(#__reader)` bei Seiten, die Inhalt außerhalb des Body oder nach dem Einschalten neu einfügen (dann erscheint er unter/über dem Reader), (b) Seitenstile, die den Container trotz `all: initial` verändern (selten), (c) Readability kann bei Nicht-Artikeln `null` liefern: dann bleibt die Seite unverändert und der Knopf verschwindet (`toggle` gibt `n` zurück), (d) lange Seiten: `parse()` läuft synchron im Seitenthread (Sekundenbruchteile bis wenige Sekunden), (e) `loadHTMLString`-Alternative wäre der Rückfall, falls Apple Skriptausführung im Seitenkontext einschränkt.

**Woran man merkt, dass es kaputt ist.** Knopf erscheint nie: `[Reader] check -> n` bzw. `e:…` in der Konsole (DEBUG), `js:typeof window.__browserReader`; `Datei fehlt: Reader/…js` heißt Ordner nicht im Paket. Reader zeigt Seite doppelt oder halb: Seitenstil schlägt durch. Links im Reader rasten nicht ein: `window.__browserTargets` prüfen (Abschnitt 4).

**Test.** `POINTER_SELFTEST="url:https://de.wikipedia.org/wiki/Apple_TV;js:1;js:1;reader;js:1;next;next;click"` (Schritt `reader` schaltet um und loggt `reader vorher/nachher verfügbar=… aktiv=…`; `[Reader] check/toggle -> a|y|n`). Geprüft mit heise.de-Artikel, theguardian.com-Artikel, de.wikipedia.org (Screenshots in `docs/reader-screens/`).

**Aktualisieren.** Readability: neue Version aus npm holen (`npm view @mozilla/readability version`, Tarball), die beiden Dateien und `LICENSE.md` unverändert ersetzen, Version in `THIRD_PARTY_NOTICES.md` und hier ändern. Stil: nur `css()` in `reader.js`.

---

## 10. Video

Gliederung: 10.1 Video-Hooks im Seitenkontext, 10.2 Übergabe an den nativen Player, 10.3 Asset-Loader, 10.4 Now Playing, 10.5 YouTube, 10.6 Bild-in-Bild, 10.7 Untertitel, 10.8 Einhängepunkt für Erweiterungen, 10.9 Automatische Untertitel (whisper.cpp).
Gliederung: 10.1 Video-Hooks im Seitenkontext, 10.2 Übergabe an den nativen Player, 10.3 Asset-Loader, 10.4 Now Playing, 10.5 YouTube, 10.6 Untertitel in der Webseite (Weg B).

### 10.1 Video-Hooks und Medienmeldungen
**Zweck.** Vollbild-Wünsche und Videostarts der Seite abfangen, HLS/DASH-Manifeste für MSE-Videos (`blob:`) finden und melden, Media-Session-Handler der Seite sichern.

**Dateien.** `BrowserClickTargetTracker.m`: `BrowserManifestObserverJS` (gemeinsamer Teil), `BrowserVideoHookScript` (Hauptframe), `BrowserFrameVideoScript` (eingebettete Frames), beide document-start, Rückkanal `browserVideo`; `BrowserMediaSessionHookScript`, Teil von `BrowserClickTargetScript`. Weitergabe `BrowserWebView.videoEventHandler` → `ViewController observeClickTargetsOfWebView:` (nur aktueller Tab) → `BrowserVideoPlaybackCoordinator handlePageVideoEvent:`.

**Ablauf.**
- Manifest-Beobachter: überschreibt `fetch` und `XMLHttpRequest.prototype.open`. Erkannt wird an der Adresse (`.m3u8`, `.mpd`, `format=m3u8|mpd`, `/manifest/dash/`) **und** am Content-Type der Antwort (`…mpegurl`, `dash+xml`, über `response.headers`/`getResponseHeader`, beide CORS-frei lesbar). Ergebnis in `window.__browserManifests` (`hls`, `dash`, `all` mit bis zu 20 Adressen). HLS: die erste Playlist (Hauptplaylist) bleibt; Teil-Playlists (Name mit chunk/media_/…, oder im Ordner unter der Hauptplaylist) ersetzen sie nicht, eine Playlist in einem fremden Ordner gilt als neuer Stream. Jede neue Hauptadresse geht als `{type:'manifest', kind:'hls'|'dash', url, top}` an die App.
- Hauptframe: überschreibt `HTMLVideoElement.prototype.webkitEnterFullscreen`/`webkitEnterFullScreen` und `Element.prototype.requestFullscreen`/`webkitRequestFullscreen`/`webkitRequestFullScreen`; bei Video meldet es `{type:'fullscreen', bid}` und unterdrückt das Vollbild. Ebenfalls Ereignis `webkitbeginfullscreen`.
- Hauptframe: `playing`-Ereignis (nur Videos ≥ 320 × 180 CSS-Pixel, keine stummen Loops/Autoplay-Vorschauen) → `{type:'playing', bid}`; die App öffnet den nativen Player, wenn `autoOpenVideosInNativePlayer` (Standard ja) gesetzt ist (Menü „Native Player automatisch“, `autoOpenNativePlayerMenuItem` im Abschnitt Erweiterungen).
- Frames (eingebettete Player, `forMainFrameOnly NO`, überspringt den Hauptframe): Manifeste wie oben, dazu `{type:'framevideo', src, t, paused, hls, dash, frame}` bei `playing`/`pause` und `{type:'framefullscreen', …}` beim Vollbildwunsch. **Kein** automatisches Öffnen beim Abspielen in Frames (Werbung läuft oft in Frames).
- Media-Session: `navigator.mediaSession.setActionHandler` wird gewrappt, Handler landen in `window.__browserMediaHandlers` (für nächster/voriger Titel).
- Befehle an das Video: `videoCommandScriptWithCSSPoint:command:` mit `toggle`, `seek:±S`, `play`, `pause`, `seekto:S`, `action:<name>`. `sendVideoCommand:` schickt sie zuerst über die Player-Brücke (7.1, erreicht iframes und Shadow DOM); nur ohne Brücke (`nobridge`) dieses Skript im Hauptframe, `action:` immer hier (Seitenwelt).

**Fragil.** Überschreibt Prototypen der Seite; Seiten, die Referenzen früh sichern, umgehen die Hooks. Video-Vollbild kann tvOS-WebKit ohnehin nicht (`feature is not supported`), deshalb der Umweg über den nativen Player. Im **Simulator** gibt es kein MSE (`typeof MediaSource` = `undefined`), hls.js- und YouTube-Seiten spielen dort gar nicht; der Manifest-Weg lässt sich dort nur mit `js:`-Abrufen nachstellen (Beispiel unten).

**Kaputt?** Vollbildknopf tut nichts oder öffnet Systemfehler; kein automatischer Player. Selbsttest `video` (loggt Zeit, `paused`, `readyState`, `rects`, `playing`, `idle`), `js:` mit `JSON.stringify(window.__browserManifests)`, Logzeilen `[NativeVideoPlayer] Manifest hls|dash <Adresse> top=1|0`.

### 10.2 Nativer Player und Handover
**Zweck.** Videos der Seite in `AVPlayerViewController` (4K/HDR, Transportleiste, Siri, Bild-in-Bild) abspielen und danach die Position zurückgeben.

**Dateien.** `BrowserVideoPlaybackCoordinator.m/.h`, `BrowserNativeVideoPlayerViewController.m/.h`.

**Datenfluss.** `openPageVideoWithID:trigger:` (Trigger: Fullscreen/Automatic/Menu) → `BrowserPageVideoProbeScript` wählt das Video (Kennung, Zeigerposition, laufendes, aktives, größtes), merkt es als `window.__browserHandoverVideo` und liefert JSON (`currentSrc`, `src`, `source`-Kinder, `hls`, `dash`, Position, Dauer, User-Agent, Seiten-URL, Titel, `<track>`-Spuren, eingeblendete Untertitelsprache, Vorschaubild aus Media Session/`poster`/`og:image`, Beschreibung) → `nativeURLFromProbe:unsupportedReason:` (Reihenfolge: direkte Adresse, HLS der Seite, per Rückkanal gemeldetes HLS; DASH (`isDASHURL:`), `.webm`, `.ogv`, `.ogg`, `.flv`, `.mkv`, `.avi`, `.f4v` werden ausgeschlossen, Grund wird bei Menü/Vollbild gemeldet: YouTube, DASH, Format, „setzt Video selbst zusammen“ (blob ohne Manifest), keine Adresse; beim automatischen Öffnen still). Findet die Probe kein Video im Hauptframe, aber ein Frame-Video wurde gemeldet → `openFrameVideoWithTrigger:`.
→ `pauseAndPresentPlayerForURL:probe:webView:` pausiert (`kBrowserHandoverPauseScript`, hängt dazu einen `play`-Wächter an, der das Video angehalten hält, solange der Player läuft), baut Header (`requestHeadersForPageURL:userAgent:`: User-Agent der Seite, `Referer`, `Origin`) und Cookies der WebView (`webViewCookiesForURL:`, aus dem WebKit-Datenspeicher, passend zu Host, Pfad, `secure`, Ablauf) und präsentiert den Player (`playerForURL:…`: Titel aus Media Session/Seitentitel, Sitename als zweite Zeile, Beschreibung, Vorschaubild) mit `initialPlaybackTime` (am Ende der Seite: 0).
→ Der Player springt **vor** dem Abspielen an die Startposition (`playWhenReady`/`initialSeekInFlight`), nicht bei Livestreams (Dauer unbestimmt) oder hinter dem Ende.
→ Sitzungsende (`endSession`: Menütaste, Schließen, Ende des Bild-in-Bild-Fensters) ruft `dismissHandler` einmalig mit der Position (`NAN` bei Livestreams) → Wächter lösen, Position in die Seite schreiben, Video bleibt pausiert. Bei Fehlern (`AVPlayerItemStatusFailed`): `failureHandler` → zurück zur Seite (`kBrowserHandoverResumeScript`) plus Hinweis.
- Frame-Videos: `evaluateJavaScript` erreicht Frames nicht. Pausiert wird über WebKit (`pauseAllMediaPlayback`), Position = letzte Meldung plus verstrichene Zeit, Header mit der Frame-Adresse als Referer. Seit der Player-Brücke (7.1) geht die Position am Ende per `seekto:S` an den Frame zurück (`sendVideoCommand:toFrameURL:`); schlägt der Player fehl, bekommt der Frame `play` und spielt in der Seite weiter. Steht der Zeiger auf einem markierten iframe (`data-browser-player`), nimmt „Im Player öffnen“ das Frame-Video statt eines Videos im Hauptdokument.
- **Startwächter** (`armStartWatchdog` in `BrowserNativeVideoPlayerViewController.m`, `kBrowserNativePlayerStartTimeout` 15 s ab `viewDidAppear`): beginnt die Wiedergabe nicht (Stream hängt, `timeControlStatus` nie „playing“, kein `AVPlayerItemStatusFailed`), gilt die Übergabe als gescheitert → `failureHandler` (Fehler `BrowserNativeVideoPlayer` −1 „Wiedergabe startet nicht“) → zurück in den Seitenplayer. Vorher blieb das Seitenvideo dann pausiert, der Player schwarz. Nicht bei Bild-in-Bild, beendeter Sitzung oder schon gemeldetem Fehler. Log `[NativeVideoPlayer] Startwächter: …`.
- Der alte Weg „Vollbild-Videowiedergabe“ (`handleSelectPressForVideoAtCursor`) zeigt kein „Nativer Player nicht verfügbar“ mehr über dem Seitenplayer, sondern loggt und lässt die Seite spielen.
- Ältere Wege mit Schalter „Vollbild-Videowiedergabe“ (`playVideoUnderCursorIfAvailable`, `handleSelectPressForVideoAtCursor`) geben jetzt ebenfalls Header und Cookies der Seite mit.
- Ein laufender Player (auch im Bild-in-Bild) wird vom Koordinator stark gehalten (`activePlayer`, `currentNativePlayer`). Ein neuer ausdrücklicher Wunsch (Menü, Vollbild) beendet ein Bild-in-Bild-Video und öffnet das neue; automatische Starts werden dann ignoriert.

**Fernbedienung im Player** (Stand 2026-11-08). Bedient wird ausschließlich von AVKit, wie in der TV-App: Klick pausiert/spielt und blendet die Transportleiste ein; oben (Taste oder Wischen) führt in die Knopfreihe über der Zeitleiste: eigene Menüs aus `transportBarCustomMenuItems` („Automatische Untertitel“, „Untertitel der Seite“), der Untertitel-Knopf des Systems (nur wenn der Stream Untertitel hat) und Audio („Laute Töne reduzieren“, Audiospur); Klick öffnet das Menü. Menü schließt Menü → Leiste → Player. Links/Rechts springen ±10 s, Wischen auf der Zeitleiste spult. **Ursache des alten Fehlers:** `UIApplication+BrowserSelectPressForwarding.m` hat im Player Klick (→ eigenes Pause/Weiter), Links/Rechts (→ nur Doppeltipp ±5 s), horizontales Wischen (→ eigenes Spulen) und den Beginn von Menü (→ Player sofort zu) abgefangen, bevor AVKit sie bekam. Die Transportleiste bekam so nie den Fokus, Untertitel- und Audio-Menü waren unerreichbar.

**Fragil/Grenzen.** DASH und DRM (FairPlay) gehen nicht. Der Player-Controller-Typ wird in `UIApplication+BrowserSelectPressForwarding.m` per `NSClassFromString(@"BrowserNativeVideoPlayerViewController")` gesucht (nur noch für den Rest eines Menü-Drucks und die Klick-Mitteilung, Abschnitt 12). Asset-Option `AVURLAssetHTTPHeaderFieldsKey` ist nicht dokumentiert (wird seit Jahren geduldet).

**Kaputt?** Logzeilen mit `[NativeVideoPlayer]` (`asset hls=… loader=… headers=… cookies=…`, Status, `Startposition … gesetzt`, `Sitzung endet t=…`, `Position zurück in die Seite: …`, `keine Adresse: cs=… hls=… dash=…`), `[NativeVideoPlayer] Wiedergabe fehlgeschlagen, zurück zur Seite: …`. `[InputTrace][NativePlayer]` loggt Tasten im Player. Selbsttest `native`, `nplayer` (mit `fokus=` und `oben=`: fokussiertes Element bzw. offenes Menü, z. B. `AVxOverlayToolCell`, `AVUnifiedPlayerContextMenuContainerViewController`), `nseek:S`, `nclose`, `hid:<tasten>` (Tasten über den echten Weg `sendEvent:` → Fokus → AVKit) (Abschnitt 14.2).

### 10.3 Asset-Loader (`BrowserNativeVideoAssetLoader`)
**Zweck.** Reicht Header und Cookies je Anfrage an HLS-Playlists weiter, sonst verweigern manche Server den Stream.

**Ablauf.** Nur für HLS (`.m3u8`) und nur, wenn Header oder Cookies da sind. `assetURLForPlaybackURL:` ersetzt `https`/`http` durch ein eigenes Schema; `attachToAsset:` setzt sich per `resourceLoader setDelegate:queue:` als Delegate; Anfragen laufen mit `NSURLSession` und den Original-Headern/Cookies (für `googlevideo.com` ohne `Origin`). Playlists werden umgeschrieben (`rewrittenPlaylistDataFromData:responseURL:`, relativ zur Adresse **nach** Weiterleitungen):
- **Über den Loader** (eigenes Schema): Teil-Playlists der Hauptplaylist, `URI=` in `#EXT-X-MEDIA` (Audio, Untertitel), `#EXT-X-I-FRAME-STREAM-INF`, Schlüssel `#EXT-X-KEY`/`#EXT-X-SESSION-KEY`.
- **Direkt `https`** (absolut gemacht): Mediensegmente, `#EXT-X-MAP` (Init-Segment), WebVTT-Segmente. AVFoundation lehnt Segmentdaten aus einem Resource-Loader bei HLS ab (`CoreMediaErrorDomain -12881`, so war HLS vorher kaputt). Segmente lädt AVFoundation selbst mit den Asset-Optionen `AVURLAssetHTTPHeaderFieldsKey`, `AVURLAssetHTTPUserAgentKey`, `AVURLAssetHTTPCookiesKey`.
- Dateien (MP4/MOV) laufen ohne Loader direkt mit diesen Asset-Optionen.

Besonderheiten in `fillContentInfoForLoadingRequest:…`:
- **UTI statt MIME:** `contentInformationRequest.contentType` erwartet einen UTI (`public.mpeg-4`), nicht `video/mp4`. Umwandlung über `UTType typeWithMIMEType:` bzw. Dateiendung; HLS-Playlists werden als `application/vnd.apple.mpegurl` erkannt (`isPlaylistResponse:`).
- **Content-Range:** Bei Teilantworten (206) steht die Gesamtlänge hinter dem `/` in `Content-Range` (`bytes 0-1/788493`); sonst `expectedContentLength`, sonst Datengröße. `byteRangeAccessSupported` aus `Accept-Ranges`/206.

**Kaputt?** Player bleibt schwarz oder meldet Status „failed“; `[NativeVideoAssetLoader]`-Zeilen (Anfrage, Antwort, Fehler). `-12881` heißt: Segment lief doch über den Loader (Umschreiben prüfen). Typische weitere Ursachen: UTI nicht ermittelbar, falsche Länge, Server verlangt Header.

### 10.4 Now Playing
`BrowserNowPlayingController.m`: `MPRemoteCommandCenter` (Play, Pause, Toggle, ±10 s, Position, nächster/voriger Titel) → Befehle werden als `sendVideoCommand:` an die Seite gegeben; Angaben kommen aus `mediaInfo` (Abschnitt 7). Im nativen Player meldet AVKit selbst (aus `externalMetadata`: Titel, Untertitel, Beschreibung, Vorschaubild), die Seitenmeldung schweigt dann: `BrowserNativePlayerDidAppearNotification` schaltet sie stumm, `BrowserNativePlayerWillDisappearNotification` kommt erst mit dem Sitzungsende (also nicht beim Wechsel in Bild-in-Bild). Log `[NowPlaying] <Titel> t=…/… paused=…`, Fehler `[NowPlaying] category error`/`activate error`. Bildschirmschoner: `ViewController` setzt `idleTimerDisabled` aus `videoPlaying`.

### 10.5 YouTube
- `BrowserYouTubeRequestCaptureScript` (Nutzerskript, alle Frames, document-start, wird zusätzlich nach `didFinishNavigation` erneut ausgeführt) fängt `fetch`/XHR zu `/youtubei/v1/player` ab und merkt PoToken, Client-Name/-Version, erste/letzte Anfrage in `window.__browserYouTubeIntegrity`.
- `BrowserYouTubeExtractor` baut daraus eine Wiedergabeadresse. **Bleibt abgeschaltet:** `kBrowserYouTubeNativeExtractionEnabled = NO` in `BrowserVideoPlaybackCoordinator.m`. Im Menü meldet der Koordinator für YouTube-Seiten (auch eingebettet) einen eigenen Hinweis.
- **Prüfung am 8. November 2026** (Anfragen an `youtubei/v1/player` vom Mac, Video `aqz-KE-bpKQ`): Client `WEB` → „Video unavailable“, `TVHTML5` → „Sign in to confirm you're not a bot“, `IOS 19.09.3` (Stand im Extraktor) → HTTP 400. `IOS 20.10.4` liefert Formate, aber **nur getrennte Video- und Tonspuren** (DASH-artig, kein gemischtes MP4, kein `hlsManifestUrl` bei Abrufvideos) und einen SABR-Stream; die Tonspur antwortet ab 5 MB mit **403** (PoToken-Pflicht auf googlevideo). Die Webseite selbst lädt per SABR in MSE, es gibt kein Manifest zum Abgreifen.
- Für einen funktionierenden Weg bräuchte es: aktuellen IOS-Client nachführen, aus den getrennten Spuren selbst eine HLS-Playlist bauen (`sidx` der fMP4-Dateien lesen, `#EXT-X-MAP`/`#EXT-X-BYTERANGE`), ein gültiges PoToken (BotGuard) erzeugen und bei jeder Änderung von YouTube nachziehen; Qualität wäre auf H.264 bis 1080p begrenzt (4K nur VP9/AV1). Das ist kein vertretbarer Aufwand, YouTube bleibt in der Webseite.
- Logpräfix `[YouTubeExtractor]`.

### 10.6 Bild-in-Bild
`allowsPictureInPicturePlayback = YES`, Audio-Session `playback`/`moviePlayback` (`BrowserNowPlayingController activateAudioSession`), Hintergrundmodus `audio` (`UIBackgroundModes` in `Info.plist`). Der Player ist sein eigener `AVPlayerViewControllerDelegate`:
- `…WillStartPictureInPicture` → beim folgenden automatischen Schließen (`…ShouldAutomaticallyDismissAtPictureInPictureStart` = YES) läuft das Video weiter, die Sitzung bleibt offen, der Browser ist bedienbar.
- `restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:` präsentiert den Player wieder auf dem Controller, der ihn zuerst gezeigt hat (`restoreHost`, über offene Dialoge hinweg).
- `…DidStopPictureInPicture` ohne Rückkehr → `endSession` (Position in die Seite).
- **Nicht geprüft:** Der Simulator kann kein Bild-in-Bild (`isPictureInPictureSupported` = NO, Selbsttest `nplayer` zeigt `pipSupported=0`). Am Gerät prüfen: Knopf in der Transportleiste, Browser bedienen, zurück ins Vollbild, Fenster schließen → Position in der Seite.

### 10.7 Untertitel
- **Stream-Spuren** (HLS `#EXT-X-MEDIA TYPE=SUBTITLES`, CEA-608, eingebettete Spuren): bietet AVKit selbst im Untertitel-Menü an; Auswahl sonst nach Systemeinstellung. Waren in der Seite Untertitel eingeblendet (`textTracks[i].mode == 'showing'`), wählt `selectStreamSubtitlesIfNeeded` die passende Sprache (`preferredSubtitleLanguage`), sonst die erste nicht erzwungene Spur. Log `Stream-Untertitel: <Liste>`, `Stream-Untertitel gewählt: …`.
- **WebVTT der Seite** (`<track kind=subtitles|captions src=…>`, nur wenn der Stream keine eigenen Spuren hat, also typischerweise MP4): die App lädt die Datei selbst (Header/Cookies der Seite, kein CORS nötig), liest sie mit `cuesFromWebVTT:` (Zeitzeilen, Text, Tags entfernt; keine Positionierung/Stile) und zeigt sie als `UILabel` im `subtitleOverlayView` (Zeitbeobachter 0,2 s). Eingeblendet, wenn die Spur in der Seite an oder `default` war; Auswahl/Aus über das Transportleisten-Menü „Untertitel der Seite“ (`transportBarCustomMenuItems`, tvOS 15+). Log `WebVTT <Datei> cues=N`.

### 10.8 Einhängepunkt für Erweiterungen (automatische Untertitel)
Der Player bietet in `BrowserNativeVideoPlayerViewController.h` (Abschnitt „Einhängepunkt“) alles, ohne dass man die Datei ändern muss:

| Was | Wo |
|:--|:--|
| Zeitpunkt „Player steht“ | `BrowserNativePlayerDidCreatePlayerItemNotification`, `object` = Player-Controller (aus `viewDidLoad`, Player und Element existieren, noch nicht angezeigt) |
| Zeitpunkt „Sitzung endet“ | `BrowserNativePlayerWillEndSessionNotification` (vor dem Pausieren; auch wenn Bild-in-Bild endet). Hier Zeitbeobachter entfernen |
| `AVPlayer` | `player.player` (geerbt von `AVPlayerViewController`) |
| `AVPlayerItem` | `player.playerItem` (= `player.player.currentItem`) |
| Anzeigeebene | `player.subtitleOverlayView`: Unteransicht von `contentOverlayView`, ganze Fläche, über dem Bild, unter der Transportleiste, `userInteractionEnabled = NO`. Eigene Labels hier einhängen. Liegt dort schon die WebVTT-Anzeige der Seite (unten, 90 pt Abstand) |
| Quelle | `player.videoURL` (http/https, nicht die Loader-Adresse), `player.isStreamingPlaylist` (HLS → kein Audio-Tap, Segmente selbst laden; sonst Datei → `MTAudioProcessingTap` über `AVAudioMix` am `playerItem`) |
| Netz | `player.requestHeaders` (User-Agent, Referer, Origin), `player.requestCookies` – für eigenes Laden von HLS-Audiosegmenten |
| Schon Untertitel? | `player.isShowingExistingSubtitles` (Stream-Spur gewählt oder WebVTT der Seite an): dann keine automatische Erkennung starten |
| Bild-in-Bild | `player.isPictureInPictureActive` (im Bild-in-Bild ist `contentOverlayView` nicht sichtbar) |

Beispiel (z. B. im `+load` bzw. Initialisierer des Untertitel-Controllers):
```objc
[NSNotificationCenter.defaultCenter addObserverForName:BrowserNativePlayerDidCreatePlayerItemNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
    BrowserNativeVideoPlayerViewController *player = note.object;
    // Controller anlegen, z. B. per objc_setAssociatedObject(player, …) am Player festhalten,
    // [player.player addPeriodicTimeObserverForInterval:…], Labels in player.subtitleOverlayView.
}];
```

**Test.** Alle Videoteile: `POINTER_SELFTEST="url:<Seite mit Video>;x,y;click;video;playpause;left;right;state"` – die Zeilen `video`, `playpause overVideo=… playing=…`, `state presented=BrowserNativeVideoPlayerViewController` zeigen, ob der Player geöffnet wurde. Gezielt (Simulator, Stand 8. November 2026 alle grün):
```
# HLS direkt (Auto-Öffnen beim Start, Sprung, Position zurück)
url:https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8;wait;wait;nplayer;nseek:120;wait;nplayer;nclose;wait;video
# MP4 mit Startposition 4 s, Vorschaubild (og:image), Titel/Sitename
url:https://www.w3schools.com/html/html5_video.asp;wait;js:(window.vv=document.querySelector('video'),vv.muted=false,vv.currentTime=4,vv.play(),'ok');wait;nplayer;nclose
# MSE nachgestellt: Manifest per fetch/XHR, Video mit blob:-Adresse → Hauptplaylist im Player
url:https://hlsjs.video-dev.org/demo/;wait;js:(fetch('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),'f');js:(document.querySelector('video').src=URL.createObjectURL(new Blob(['x'])),'b');native;wait;nplayer;nclose
# DASH → Hinweis, bleibt in der Seite
url:https://hlsjs.video-dev.org/demo/;wait;js:(fetch('https://dash.akamaized.net/envivio/EnvivioDash3/manifest.mpd'),document.querySelector('video').src=URL.createObjectURL(new Blob(['x'])),'ok');native
# WebVTT der Seite (Track anhängen, abspielen → Untertitel im Player)
url:https://www.w3schools.com/html/html5_video.asp;wait;js:(window.vv=document.querySelector('video'),window.tr=document.createElement('track'),tr.src='https://interactive-examples.mdn.mozilla.net/media/examples/friday.vtt',tr.srclang='en',tr.label='English',tr.default=true,vv.appendChild(tr),vv.play(),'ok')
# Video in einem Frame (Manifest top=0, Frame-Video mit Position)
url:https://example.org/;wait;js:(window.f=document.createElement('iframe'),f.srcdoc='<video src=https://www.w3schools.com/html/mov_bbb.mp4 width=400 height=300></video>',document.body.prepend(f),'ok');wait;js:(f.contentDocument.querySelector('video').play(),'p');wait;native;wait;nplayer
```

### 10.9 Automatische Untertitel (whisper.cpp)
**Zweck.** Untertitel für Videos ohne eigene Untertitelspur, lokal auf dem Apple TV erzeugt (`SFSpeechRecognizer` gibt es unter tvOS nicht; Apples neuer `SpeechTranscriber` ist ab tvOS 26 verfügbar, am Gerät geprüft, aber noch nicht als Erkennung angebunden, siehe unten „SpeechTranscriber“). Weg A: nur im nativen Player.

**Dateien.**
| Datei | Aufgabe |
|:--|:--|
| `BrowserSubtitleController.m/.h` | Einhängen in den Player, Schalter in der Transportleiste, Wahl der Tonquelle, Startwarten, Anzeige-Takt (rollend), Versatzmessung |
| `BrowserSubtitlePipeline.m/.h` | Tonquelle → Abschnitte → Erkennung, gemeinsam für Weg A und B: vorauslesend (12-s-Abschnitte, Schnitt in Sprechpausen, Abdeckung) oder Mithören (jede Sekunde neu, vorläufiger Text); `BrowserSubtitleOffsetSummary` |
| `BrowserSubtitleProgressiveAudioSource.m/.h` | MP4/MOV/M4A über HTTP(S): `moov` lesen (Anfang oder Ende), Audio-Pakete per Range-Anfrage vor der Abspielposition laden, AAC/MP3/AC-3 mit `AudioConverter` dekodieren |
| `BrowserSubtitleEngine.m/.h` | whisper.cpp-Hülle (Modell laden, `whisper_full`, Stille- und Rauschfilter, Echtzeitfaktor, Speicher), `BrowserSubtitleCue` |
| `BrowserSubtitleAudioSource.h` | Protokoll der Tonquellen (16 kHz mono float, Videozeit des ersten Samples) |
| `BrowserSubtitleAudioTapSource.m/.h` | Dateien (MP4/MOV/M4A): `MTAudioProcessingTap` über `AVAudioMix`, Abwärtsmischung im Audio-Thread, Umrechnung auf 16 kHz mit `AVAudioConverter` |
| `BrowserSubtitleHLSAudioSource.m/.h` | HLS (VOD und live): Playlist selbst lesen (live nachladen), Audio-Segmente vor der Abspielposition laden und dekodieren |
| `BrowserSubtitleOverlayView.m/.h` | Ebene in `contentOverlayView`, Stil nach `MACaptionAppearance` |
| `vendor/whisper.xcframework` | whisper.cpp v1.9.5, statisch, tvOS arm64 + Simulator arm64, Metal + Accelerate (committet, ≈12 MB) |
| `vendor/whisper-metal/appletvos/default.metallib` | vorkompilierte Metal-Kernel fürs Gerät (committet, ≈15 MB) |
| `tools/build_whisper.sh`, `tools/fetch_whisper_model.sh` | Framework bauen, Modell laden |
| `_Project/Browser/WhisperModels/` | Ordnerreferenz im App-Paket; Modelle `ggml-*.bin` sind nicht im Repo |

**Bauen.**
```bash
tools/build_whisper.sh            # nur nötig für eine neue whisper.cpp-Version (Ergebnis ist committet)
tools/fetch_whisper_model.sh      # Pflicht: lädt ggml-base-q5_1.bin (mehrsprachig, 57 MB) nach _Project/Browser/WhisperModels/
tools/fetch_whisper_model.sh base.en-q5_1   # optional: nur für „Englisch“, dort etwas genauer (57 MB)
```
- `build_whisper.sh` holt die Quelle nach `vendor/whisper.cpp` (nicht im Repo), lädt bei Bedarf CMake per pip nach `vendor/tools-venv`, baut beide Slices mit dem Xcode-Generator, fasst `libwhisper`, `libggml*` (base, cpu, blas, metal) und `libparakeet` per `libtool` zu einem statischen `whisper.framework` zusammen und erzeugt `vendor/whisper.xcframework`. Version: `WHISPER_TAG=v1.9.5`, Mindest-tvOS: `TVOS_MIN=17.0`.
- Einbindung ins Projekt ohne Framework-Eintrag: `FRAMEWORK_SEARCH_PATHS[sdk=appletvos*]` bzw. `[sdk=appletvsimulator*]` zeigen auf die Slices, gelinkt wird per Modul-Autolink (`#import <whisper/whisper.h>`, Modulkarte mit `link framework "whisper"`, `c++`, Accelerate, Metal, MetalKit). Fehlt das Framework, kompiliert `BrowserSubtitleEngine.m` ohne whisper (`__has_include`), die App baut, der Player meldet „nicht verfügbar“.
- Metal-Kernel: `build-xcframework.sh` von whisper.cpp kann tvOS (Gerät + Simulator), wir bauen aber nur die tvOS-Teile mit eigenem Skript. **Gerät** (Stand 2026-11-08): mit installierter Metal-Toolchain vorkompiliert für tvOS (`GGML_METAL_TARGET_OS=tvos`) nach `vendor/whisper-metal/appletvos/default.metallib` (committet, ≈15 MB); die Build-Phase „Whisper-Metal-Kernel kopieren“ legt sie als `default.metallib` ins App-Paket (dort sucht ggml). Das Geräte-Framework enthält dann keinen Kernel-Quelltext mehr: fehlt die Datei, kann ggml auf dem Gerät kein Metal (Hinweis in der Build-Phase; `tools/build_whisper.sh` ausführen). Ohne Toolchain (oder `WHISPER_METAL_EMBED=ON`) wird der Quelltext eingebettet und beim ersten Laden zur Laufzeit übersetzt. **Simulator**: immer eingebettet (`WHISPER_METAL_SIM_EMBED=ON`); ggml übersetzt die Kernel dort beim ersten Laden im Prozess auch bei `use_gpu = NO` (≈16 s nach Neuinstallation, danach aus dem Metal-Cache 0,06 s).
- Im **Simulator** rechnet whisper auf der CPU (`use_gpu = NO`; die Simulator-GPU ist `MTLGPUFamilyApple2` ohne SIMD-Group-Reduktion). Auf dem Gerät Metal; abschaltbar mit `defaults write io.github.tvosbrowser.app AutoSubtitlesCPUOnly -bool YES`.

**Modell.** Reihenfolge in `+[BrowserSubtitleEngine modelCandidatesForLanguage:]`: für „en“ `base.en-q5_1`, `base.en-q8_0`, `base.en`, `tiny.en-q5_1` …, danach mehrsprachige; für „auto“ und alle anderen Sprachen zuerst mehrsprachige (`base-q5_1`, `base-q8_0`, `base`, `small-q5_1`, `tiny-q5_1`, `tiny`), notfalls ein `.en`-Modell. `.en`-Modelle können nur Englisch (die Engine rechnet dann fest in „en“, das Player-Menü zeigt „Sprache: nur Englisch (Modell)“, die Seitenleiste „Nur Englisch (Modell)“). Größen (ggml q5_1): `tiny` ≈ 31 MB, `base` ≈ 57 MB (mehrsprachig gleich groß wie `.en`), `small` ≈ 181 MB (genauer, etwa dreimal langsamer, am Gerät ungetestet). Im Haupt-Checkout liegen `base-q5_1` und `base.en-q5_1`; früher war „en“ Standard, deshalb wurde trotz vorhandenem mehrsprachigem Modell immer `base.en` geladen und deutscher Ton als englisches Kauderwelsch ausgegeben.

**Sprache** (`autoSubtitlesLanguage`, Stand 2026-11-08). Standard „auto“. Wählbar im Player-Menü („Automatische Untertitel“ → „Sprache: …“) und in der Seitenleiste („Untertitelsprache“, reihum): Automatisch, Deutsch, Englisch, Französisch, Spanisch, Italienisch, Niederländisch, Polnisch, Türkisch, Portugiesisch, Russisch (`+[BrowserSubtitleEngine selectableLanguages]`, Namen über `NSLocale de_DE`). Feste Sprache: whisper rechnet immer in ihr. **Automatisch:** whisper erkennt die Sprache (`params.language = "auto"`, `whisper_full_lang_id`) nur so lange, bis sie feststeht. Jeder Abschnitt mit behaltenen Segmenten (nicht Stille/Musik) gibt eine Stimme; hat eine Sprache zwei Stimmen (spätestens nach sechs Abschnitten die häufigste), legt `BrowserSubtitleEngine` sie fest (`lockedLanguage`) und rechnet danach fest in ihr, statt je Abschnitt neu zu raten (sonst springt die Sprache, und kurze Abschnitte werden in die falsche Sprache übersetzt). Der Controller merkt sich die Sprache je Video (`sessionLanguage`): ein Neustart der Erkennung (Tonquellenwechsel, Pause wegen vorhandener Untertitel) übernimmt sie per `lockLanguage:`; wer im Menü wieder „Automatisch“ wählt, lässt neu erkennen. Anzeige: kurz „Sprache erkannt: Deutsch“ im Bild, im Menü „Sprache: Auto · Deutsch“ (vorher „Sprache: Auto …“), im Untermenü „Automatisch (Deutsch)“.

Gemessen im Simulator (2026-11-08, „tagesschau in 100 Sekunden“, `base-q5_1`, CPU): MP4 über den Tap nach 2 × 5 s Abschnitten auf `de` festgelegt, RTF Ø ≈ 0,10, Speicher ≈ 240 MB; HLS nach 2 × 12 s (RTF ≈ 0,08). Text z. B. „Willkommen zur Tagesschau in 100 Sekunden.“ Vorher mit `base.en`: englisch klingender Unsinn.

**Umstellung alter Einstellungen.** Früher war „en“ Standard (nicht gespeichert). Gespeichert wurde „en“ nur durch eine Wahl im Player-Menü (zurück von „Sprache automatisch“, das damals je Abschnitt sprang), durch Selbsttests (`pref:`) oder `defaults write`; ob das bewusst war, ist nicht erkennbar. Regel in `BrowserPreferencesStore`: Beim ersten Lesen wird ein gespeichertes „en“ einmalig zu „auto“ (Schlüssel `AutoSubtitlesLanguageMigratedToAuto`, Log `[Subtitles] Sprache: gespeichertes „en“ (alter Standard) auf „auto“ umgestellt`); später gewählte Werte, auch „Englisch“, bleiben. Begründung: Der gemeldete Fehler war genau ein falsches Englisch; eine unnötige Umstellung kostet eine Auswahl im Menü, und „Automatisch“ erkennt Englisch ohnehin. „auto“ wird ausdrücklich gesetzt (nicht gelöscht), damit kein „en“ aus einer anderen Ebene durchscheint (im Simulator landet `simctl spawn … defaults write` außerhalb des App-Containers).

**Einhängepunkt.** Keine Änderung am Player nötig: `+[BrowserSubtitleController load]` meldet sich für `BrowserNativePlayerDidCreatePlayerItemNotification` an (Abschnitt 10.8), legt je Player einen Controller an (assoziiertes Objekt am Player, `attachToPlayerViewController:playbackURL:requestHeaders:cookies:` mit `videoURL`, `requestHeaders`, `requestCookies`) und hängt die Anzeige in `subtitleOverlayView`. `BrowserNativePlayerWillEndSessionNotification` ruft `detach` (Erkennung stoppen, Zeitbeobachter, Ebene und Menüeintrag entfernen, Modell freigeben); Bild-in-Bild mit Rückkehr in denselben Player läuft also weiter. HLS-Erkennung über `isStreamingPlaylist`. Zeigt der Player schon Untertitel (`isShowingExistingSubtitles`: Stream-Spur oder WebVTT der Seite), startet die Erkennung nicht bzw. pausiert (Prüfung alle 2 s), außer sie wurde im Player-Menü ausdrücklich eingeschaltet. Schaltet der Nutzer die eigenen Untertitel des Videos danach im Untertitel-Menü des Systems auf „Aus“, bleiben auch die automatischen aus (bis 9. November 2026 sprang die Erkennung dann wieder an); Log `vorhandene Untertitel ausgeschaltet – automatische bleiben aus`.

**Ausschalten im Player** (Stand 2026-11-09). „Aus“ im Menü „Automatische Untertitel“ stoppt Tonquelle und whisper und leert die Anzeige sofort (`cuesVisible` = NO; `updateOverlayAtTime:` zeigt dann nichts). **Alter Fehler:** Das Menü stoppte nur die Erkennung, die Liste der schon erkannten Sätze blieb, und der Zeitbeobachter blendete sie weiter ein – mit der Vorausquelle (MP4/HLS liest bis 100 s voraus) liefen die Untertitel also scheinbar ungerührt weiter, auch nach Spulen. Jetzt bleiben die Sätze nur im Speicher („An“ zeigt sie sofort wieder), werden aber nicht mehr eingeblendet, auch nicht Nachzügler einer gerade laufenden Auswertung. Das Häkchen im Menü folgt `cuesVisible` (zeigt also „Aus“ auch neben eigenen Untertiteln des Videos); An/Aus ist eine Einzelauswahl (`UIMenuOptionsSingleSelection`), das System setzt das Häkchen beim Auswählen sofort. „Aus“ schreibt `autoSubtitlesEnabled` = NO, der nächste Player startet also aus. Im Simulator geprüft (Selbsttest `nsubs`, `nsubs:aus`, `nsubs:an` löst den Menüeintrag aus und loggt Häkchen und sichtbaren Text; `nlegible:en` / `nlegible:aus` wählt die Stream-Untertitel): nach „Aus“ kein `Anzeige Δ` mehr, `sichtbar []` über Spulen (`nseek:40`), Schließen und neu Öffnen (`eingehängt, an=0`); „An“ zeigt nach 1,8 s wieder Untertitel.

**Ablauf.**
1. `attach`: Ebene in `subtitleOverlayView` (sonst `contentOverlayView`), Menü „Automatische Untertitel“ (Symbol `waveform.and.mic`, damit es sich vom Untertitel-Knopf des Systems unterscheidet; An/Aus und Untermenü „Sprache: …“, siehe **Sprache**) in `transportBarCustomMenuItems` (vorhandene Einträge wie „Untertitel der Seite“ bleiben; der Player setzt sein Menü teils neu, deshalb prüft der Controller alle 2 s und hängt sich wieder an), `addPeriodicTimeObserverForInterval` 0,1 s. Ist `autoSubtitlesEnabled` an: Modell auf der whisper-Queue laden, dann Tonquelle starten.
2. Tonquelle (Reihenfolge in `startNextSource`): Adresse sieht nach HLS aus → HLS-Quelle; Datei über HTTP(S) → MP4-Vorausquelle; scheitert sie (kein `moov`, fragmentiertes MP4, HTTP-Fehler) → Audio-Tap; findet der Tap keine Audiospur → noch einmal HLS. Vorausquellen liefern Ton bis 60 s vor der Abspielposition; nur der Tap liefert in Echtzeit. Test/Messung: `pref:SubtitlesForceTap=YES` erzwingt den Tap.
3. **Startwarten:** Bei einer Vorausquelle hält der Controller den ersten `play` des Players höchstens 1,0 s an (`holdPlaybackStart:timeout:` in `BrowserNativeVideoPlayerViewController`, Log `Start wartet auf Untertitel (höchstens 1.0 s)` / `Start nach 0.27 s Warten (frei)`), bis der erste, nur 4 s lange Abschnitt erkannt ist (`firstWindowHandler`). Am Gerät dauert das 0,3–1,0 s (moov/Playlist laden 0,1–0,9 s, 4-s-Abschnitt 0,2–0,4 s); damit steht der erste Satz ab Sekunde 0 da. Begründung für 1 s statt sofort: Der erste Satz einer Sendung fängt oft bei 0 s an, ohne Warten fehlte er (Weg B kann nicht warten, die Seite spielt selbst; dort erscheint der erste Satz ≈ 0,5–1,5 s spät, die folgenden pünktlich). Mehr als 1 s fällt als Hänger auf; läuft die Zeit ab, startet der Player trotzdem (`Zeit abgelaufen`). Nur vor dem allerersten `play`, nicht nach Spulen.
4. Pipeline (`BrowserSubtitlePipeline`, eigene Queue): **vorauslesend** Abschnitte von 12 s mit 1,5 s Überlappung, der erste nach Start/Sprung 4 s. Geschnitten wird an der leisesten 50-ms-Stelle der letzten 1,5 s (Satzpause statt mitten im Wort). Ein Abschnitt übernimmt nur Segmente, deren Mitte in seinem Annahmebereich liegt; die Abdeckung im 0,1-s-Raster verhindert Doppelungen und überspringt Erkanntes (Quellen laden solche Stellen gar nicht erst). Gegendruck: Quellen laden nicht weiter, solange mehr als 25 s Ton auf Auswertung warten. **Mithören** (Tap, Weg B über Web Audio): jede Sekunde wird der offene Ton ab dem letzten fertigen Satz (höchstens 8 s) neu erkannt; Segmente, die mehr als 1 s vor dem Ende aufhören und nicht die letzten sind, gelten als fertig, der Rest ist vorläufig (`tentative`) und wird beim nächsten Durchlauf ersetzt. 3 s nichts erkannt → bis 1 s vor dem Ende als erledigt. Pause: angefangener Abschnitt sofort.
5. whisper (`engineQueue`): greedy, `no_context`, `temperature_inc = 0`, `token_timestamps`, `audio_ctx` passend zur Abschnittslänge (≤ 7 s → 384, 12 s → 704), Stille (RMS < 0,004) wird übersprungen, Texte in Klammern/ohne Buchstaben, mit 8 gleichen Zeichen in Folge („Sssss…“) und `no_speech_prob > 0,8` verworfen (Log `Segment verworfen (no_speech …, N Tokens): …`), gleicher Text innerhalb 15 s ebenfalls. `max_tokens` = max(32, 12 × Abschnittslänge) je Durchlauf. **Satzkontext:** die Untertitel, die direkt vor dem Abschnitt enden (≤ 200 Zeichen, aus den letzten 12 s), gehen als `initial_prompt` mit (Log `Kontext N Z.`; abschaltbar für Vergleiche mit `pref:SubtitlesNoContext=YES`). Das hilft Abschnitten, die mitten im Gedanken beginnen. **Nicht beim Übersetzen:** Bei fest eingestellter Untertitelsprache bestimmt `whisper_lang_auto_detect` auf den ersten Abschnitten (zusätzlicher Encoder-Lauf, bis zwei gleiche Ergebnisse, höchstens sechs) die gesprochene Sprache (Log `gesprochene Sprache en … ≠ de: whisper übersetzt, ohne Satzkontext`); weicht sie ab oder steht sie noch nicht fest, geht kein Kontext mit. Bei „Automatisch“ erst, wenn die Sprache festgelegt ist (sonst trug der Kontext ein erfundenes „Thank you.“ des ersten kurzen Abschnitts über Musik in jeden weiteren), und nie, wenn er nur aus gleichen Sätzen besteht. Sätze, die vollständig im Kontext stehen, verwirft die Engine (`aus dem Kontext abgeschrieben, verworfen: …`; whisper schreibt den Prompt gern ab, auch das Überlappungsstück). Gemessen im Simulator (Tears of Steel englisch, Untertitel Deutsch, 130 s): mit Kontext verfiel whisper in Schleifen („… nicht mehr hier“, ab 71 s nur noch „Und“), 12 Untertitel; ohne Kontext 16 Untertitel mit deutlich mehr Inhalt („Du hast einen Robotik …“, „Warum nicht? Weil du …“). **Wiederholungen:** Schleifen in einem Segment („und seiner Schwiegereltern und seiner Schwiegereltern …“, 2–8 Wörter ab zwei Wiederholungen, ein Wort ab drei) werden auf ein Vorkommen gekürzt, ebenso Bindestrich-Ketten („Palästinenserflagge-Palästinenserflagge-…“); Stücke, deren Text schon im vorigen steht, verworfen (Log `Wiederholung gekürzt/verworfen`). Nach dem Zusammenlegen kurzer Stücke wird noch einmal gekürzt (sonst „Wir. Wir. Wir. …“). **Nachzügler:** Ein Satz, der nie gezeigt wurde und dessen Ende schon über 1 s zurückliegt (verspätet angekommen und von neueren verdrängt, gespult), wird nicht mehr eingeblendet; vorher tauchte er Sekunden später außer der Reihe auf (Mithören im Simulator: max +10,4 s → +3,1 s, Median +0,88 → +0,15 s). Im Overlay von Weg B gilt dasselbe ab Ende + `holdDuration` + 0,5 s.
6. **Zeiten und Teilen:** Untertitel beginnen am Segmentanfang laut whisper. Segmente über 84 Zeichen (zwei Zeilen) oder 7 s werden an Satzenden (ab 24 Zeichen), sonst an Kommas oder Wortgrenzen geteilt, jedes Stück mit eigener Zeit aus den Token-Zeitmarken; ein Satz wird nicht mitten im Wort getrennt. **Zeilen auffüllen:** kurze Stücke (< 2 s oder < 28 Zeichen) werden mit dem nächsten zusammengelegt, solange beides in zwei Zeilen passt und höchstens 8 s dauert; das zweite Stück steht dadurch höchstens ≈ 2 s vor seinem Sprechbeginn da, der Anfang bleibt exakt.
7. Anzeige (Zeitbeobachter alle 0,05 s): ein Untertitel erscheint, sobald `start ≤ t + 0,05`, und steht bis zum Ende + 0,8 s, mindestens aber 2–4 s (1 s + 0,05 s je Zeichen). **Rollend wie Live-Untertitel:** Beginnt der nächste, rückt er unten ein und der vorige bleibt darüber stehen, bis seine Mindestdauer um ist; höchstens zwei Untertitel und zusammen ≤ 120 Zeichen (drei Zeilen), sonst nur der neue. Kommt ein Untertitel zu spät (Mithören), bleibt er ab Ankunft mindestens eine Lesezeit (1,2–4 s). Pause und Spulen ergeben sich aus dem Zeitbeobachter, Untertitel bleiben gespeichert.

**HLS-Quelle.** Master: AAC-Varianten bevorzugt, kleinste Bandbreite; hat sie eine `AUDIO`-Gruppe mit `URI`, wird die Rendition genommen (Sprache der Einstellung, sonst `DEFAULT=YES`), sonst der gemuxte Ton der Variante (auch reine Audio-Varianten). Segmente: MPEG-TS (eigener Demuxer PAT → PMT → PES, Stream-Typ 0x0F AAC/ADTS, 0x03/0x04 MP3, 0x81 AC-3) → `ExtAudioFile`; gepacktes Audio (`.aac` mit ID3) → `ExtAudioFile`; fMP4 (`#EXT-X-MAP`, Init + Segment als Datei) → `AVAssetReader` mit 16 kHz mono. `#EXT-X-BYTERANGE` und AES-128 (CommonCrypto, IV aus Playlist oder Sequenznummer) gehen. Lädt bis 60 s voraus, höchstens 25 s unausgewerteter Ton im Stau. Header und Cookies der Seite werden mitgeschickt.
- **Zeitbezug VOD:** Zeit = Summe der `#EXTINF` ab Playlist-Anfang. Das ist auch die `currentTime` von AVPlayer und Safari bei VOD (beide beginnen am ersten Segment bei 0, unabhängig vom PTS-Startwert der TS-Segmente). Am Gerät mit Tears of Steel (TS, 4-s-Segmente) gemessen: Anzeige −0,05…0,00 s gegenüber whispers Sprechbeginn. `#EXT-X-DISCONTINUITY` wird gezählt (Log `Brüche N`) und ändert nichts: die EXTINF-Summe läuft durch, wie bei AVPlayer.
- **Live** (ohne `#EXT-X-ENDLIST`): Playlist nach einer Zielzeit (`#EXT-X-TARGETDURATION`) neu laden, ohne Neues nach der halben; neue Segmente über die Sequenznummer anhängen, höchstens 400 behalten. Haben alle Segmente `#EXT-X-PROGRAM-DATE-TIME`, ist die Zeitachse das Datum (`usesDateTimeline`): die Quelle bekommt die Position als Datum (`AVPlayerItem.currentDate` bzw. im Web `video.getStartDate()` + `currentTime`) und die Untertitel tragen Datumszeiten. Ohne Datum: Zeit ab dem ersten Segment der ersten Playlist (Player lädt sie fast gleichzeitig, geschätzt). Vor der ersten Position liest die Quelle drei Zielzeiten vor der Kante (dort steigen AVPlayer und Safari ein). Ende der Sendung (`ENDLIST` taucht auf) → weiter wie VOD. **An der Kante** (alles geladen, wartet auf das nächste Segment) meldet die Quelle `audioSourceDidReachLiveEdge:`; die Pipeline wertet dann ab 3 s Angefangenes sofort aus (Satzpause in der letzten Sekunde), statt auf 12 s zu warten – der Vorsprung vor der Wiedergabe ist live nur ~3 Zielzeiten. Simulator, Weg B tagesschau24-Livestream (Ziel 2 s): vorher Median +0,9 s, max +6,2 s (nur 60 % ≤ 1 s); mit Kantenschnitt Median −0,01 s, max 1,8 s, 90–93 % ≤ 1 s (n = 22–30).
- Nur SAMPLE-AES/FairPlay (Kopierschutz) bleibt „nicht möglich“ (`HLS: verschlüsselt (SAMPLE-AES/FairPlay), Ton nicht lesbar`).

**MP4-Quelle** (`BrowserSubtitleProgressiveAudioSource`, Log `[Subtitles][MP4]`). Erste 256 KB laden, Boxen der obersten Ebene durchgehen; liegt `moov` am Ende, gezielt nachladen (höchstens 16 MB). Erste `soun`-Spur: `mdhd`-Zeitbasis, `elst` (Startversatz und leere Edits), `stts/stsc/stsz/stco/co64`, Codec aus `stsd` (`mp4a` mit `esds`, auch in QuickTime-`wave`; HE-AAC über `kAudioFormatProperty_FormatList`; `.mp3`, `ac-3`, `ec-3`). Fragmentiertes MP4 (`moof`) → Rückfall auf den Tap. Laden in Läufen (erster 4 s, dann 10 s): die Bytebereiche der Pakete werden zu wenigen Range-Anfragen zusammengefasst (Lücken < 2 KB schließen, an den größten Lücken teilen; spart Teilen weniger als die Hälfte, eine einzige Anfrage über alles), parallel, bis zu 3 Wiederholungen. Weil Ton und Bild verzahnt liegen, lädt das fast so viel wie das Video selbst (tagesschau: ≈ 0,9 MB je 10 s, 11,6 MB für 62 s Wiedergabe + 60 s Vorlauf bei 11,7 MB Datei). Spulen: neuer Lauf ab der Position (zwei Pakete Vorlauf für den Decoder). Am Mac gegen `AVAssetReader` geprüft: Korrelation 0,99, Versatz 0–0,1 ms, auch nach einem Sprung. Server ohne Range (Antwort 200 und > 4 MB) → Abbruch, Rückfall auf den Tap.

**Grenzen.**
- Bild-in-Bild: `contentOverlayView` ist im PiP-Fenster nicht sichtbar; die Erkennung läuft weiter, nach der Rückkehr stimmen die Untertitel sofort.
- SAMPLE-AES/FairPlay, LATM-AAC: nicht unterstützt (Hinweis im Player). DASH geht im nativen Player ohnehin nicht. Live-HLS geht (siehe HLS-Quelle).
- Tap (nur noch Rückfall, z. B. fragmentiertes MP4, Server ohne Range, lokale Datei): Mithören, Text ≈ 1–2 s nach dem Sprechen (vorher 5–6 s).
- MP4-Vorauslesen kostet fast die Datenmenge des Videos ein zweites Mal (Ton und Bild verzahnt).
- Feste Untertitelsprache ≠ gesprochene Sprache: whisper `base` übersetzt nur behelfsmäßig (keine eigene Übersetzung in der App; whisper kann eigentlich nur ins Englische übersetzen, „Deutsch“ erzwingt die Ausgabesprache). Satzkontext schadet hier und ist deshalb aus; ganze Sätze (vorauslesend 12 s) helfen mehr als Mithören. Für gute Übersetzungen bräuchte es Erkennen in der gesprochenen Sprache plus Textübersetzung.
- Mehrere Audiospuren in einer Datei: nur die erste.
- Beobachtung außerhalb dieser Teile (Stand 2026-11-08, nach Merge mit main): Die Hauptplaylist `…/tears-of-steel.ism/.m3u8` (Dateiname nur „.m3u8“) öffnet der Player nicht (`AVFoundationErrorDomain -11828`), die Untertitel-Quelle liest sie aber; die Varianten-Playlist desselben Streams läuft samt Untertiteln (über den Asset-Loader).

**Seitenleiste** (Abschnitt „Erweiterungen“, `BrowserMenuCoordinator.m`): „Automatische Untertitel“ (An/Aus, `autoSubtitlesMenuItem`) und darunter „Untertitelsprache“ (`autoSubtitlesLanguageMenuItem`, Klick schaltet reihum Automatisch → Deutsch → Englisch → …, Symbol `character.bubble`; ohne mehrsprachiges Modell „Nur Englisch (Modell)“). Der Player liest beides beim Öffnen; im Player selbst schaltet das Menü der Transportleiste sofort. Die Einrichtung (Schritt „Videos“) hat nur den Schalter, keine Sprache.

**Logs** (`[Subtitles]`, `[Subtitles][Tap]`, `[Subtitles][HLS]`, `[Subtitles][whisper]` = Warnungen/Fehler von whisper/ggml, beim Laden alles):
- `eingehängt, an=…, Sprache …, whisper=1, Modell …` – Einstellung und gefundenes Modell.
- `Erkennung mit base-q5_1, Sprache auto (eingestellt auto)`, `Sprache erkannt: de (Abschnitt 1, noch nicht festgelegt)`, `Sprache festgelegt: de nach 2 Abschnitten mit Sprache (Stimmen …)`, `Sprache übernommen: de` (Neustart der Erkennung), `Menü: Sprache de` – Spracherkennung.
- `Modell base.en-q5_1 geladen in 0.20 s, … Speicher 38 → 164 MB, System: …` – Ladezeit, Speicherzuwachs, ggml-Fähigkeiten.
- `Abschnitt 5.0 s @ 23.9 s: 1 Segmente in 0.31 s (RTF 0.06, Schnitt 0.06), ctx 384, …, Speicher 233 MB – <Text>` – je Abschnitt Echtzeitfaktor (Rechenzeit/Audiodauer) und Speicher.
- `Stand t=…: N Untertitel, N Abschnitte, N verworfen, N wartend, RTF Schnitt …, Speicher … MB, Versatz: n=…, Median …, min …, max …, max |Δ| …, ≤ 1 s: … (… %)` – alle 30 s, dazu beim Stoppen und Aushängen.
- `Anzeige Δ=-0.03 s (Sprechbeginn 3.08, eingeblendet 3.05, Ende 6.88, mp4[, vorläufig]) „…“` – je Untertitel: Medienzeit beim Einblenden minus Sprechbeginn laut whisper (positiv = zu spät).
- `[Subtitles][MP4] moov @ 32 (63 KB), Datei 11.7 MB, Audiospur AAC 48000 Hz 2 ch, 5182 Pakete, 110.5 s, elst …, bereit in 0.39 s`, `Lauf N @ t: P Pakete (KB), R Anfragen (KB) in … s → … s Ton`, `gestoppt: … Läufe, … Anfragen, … MB geladen`.
- `[Subtitles][HLS] Audio-Playlist …: N Segmente, … s, Ziel 2 s, …, Brüche 0, Live, Zeitachse PROGRAM-DATE-TIME`, `Live-Playlist #N: +K Segmente, Kante …`.
- `[NativeVideoPlayer] Start wartet auf Untertitel (höchstens 1.0 s)`, `Start nach … s Warten (frei | Zeit abgelaufen: Untertitel)`.
- `[Subtitles][Tap] prepare rate=44100 ch=2 …`, `[Subtitles][HLS] Audio-Rendition …`, `Audio-Playlist …: N Segmente, … fMP4=…, AES=…`, `Segment @ … s: … KB → … s Ton in … s`.
- `Segment verworfen (no_speech 0.51, 4 Tokens): ♪` – vom Rausch-/Musikfilter verworfene Segmente (Text gekürzt; `(null)` = an der Token-Grenze abgeschnittenes UTF-8).
- `Modell freigegeben, Speicher … MB` beim Schließen.

**Messwerte Simulator** (Mac mit Apple Silicon, CPU, 4 Threads, base.en-q5_1): Tap 5-s-Abschnitte 0,30–0,41 s (RTF ≈ 0,06), HLS 12-s-Abschnitte 0,55–1,5 s (RTF 0,05–0,13). Modell laden 0,1–0,2 s (+≈14 s Metal-Übersetzung beim allerersten Laden, wenn Metal genutzt wird). Speicher der App 38 MB → 164 MB nach dem Laden, 230–265 MB während der Erkennung, nach dem Schließen ≈ 73 MB.

**Messwerte Gerät (Apple TV 4K 3. Gen., A15, tvOS 27.2, Debug-Build, `base.en-q5_1`, Tears of Steel 720p .mov über den Audio-Tap, je ≈ 100–135 s Wiedergabe, Stand 2026-11-08):**

| | Metal (Standard) | nur CPU (`AutoSubtitlesCPUOnly`) |
|:--|:--|:--|
| Beleg | `use gpu = 1`, `GPU name: MTL0 (Apple A15 GPU)`, `GPU family: MTLGPUFamilyApple8`, `using MTL0 backend` | `use gpu = 0` (ggml legt das Metal-Gerät trotzdem an, rechnet aber auf der CPU) |
| Metal-Kernel | `ggml_metal_library_init: loading '…/Browser.app/default.metallib'` – `loaded in 0.003 sec`, auch direkt nach Neuinstallation: keine Übersetzung zur Laufzeit | – |
| Modell laden | 0,30 s | 0,18 s |
| Speicher der App (vor → nach Laden) | 72 → 178 MB | 76 → 179 MB |
| Speicher während der Erkennung | 146–150 MB | 158–162 MB |
| Nach dem Schließen (Modell freigegeben) | 44 MB | 40 MB |
| Rechenzeit je 5-s-Abschnitt | 0,12–0,57 s (Ø 0,20 s; 33 Abschnitte); erster Abschnitt im ersten Lauf nach der Installation 0,57 s (Pipelines anlegen), sonst ≤ 0,36 s | 0,14–0,24 s (Ø 0,17 s; 25 Abschnitte) |
| RTF | 0,02–0,11, Schnitt 0,04 | 0,03–0,05, Schnitt 0,03–0,04 |
| Abschnitte mit Sprache | 0,30–0,36 s | 0,23–0,24 s |
| Verworfen / wartend | 0 / 0 | 0 / 0 |

Befund: Weg A läuft am Gerät klar in Echtzeit (RTF ≤ 0,11, weit unter 0,8), ohne Jetsam oder Speicherwarnung; Text erscheint wie im Simulator (z. B. „Look Celia, we have to follow our passions.“, „and I just want to be awesome in space.“, „Robots memory, synced, and...“; Musikstellen: „directional“ mehrfach). Bei 5-s-Abschnitten mit `audio_ctx` 384 ist die CPU (4 Threads, NEON/Accelerate) sogar etwas schneller als Metal (kleine Graphen, Decoder-Schritte mit vielen kleinen Kernels); Metal bleibt Standard: es braucht etwa 10 MB weniger Speicher und hält vermutlich die CPU für Video und WebKit frei (CPU-Last am Gerät nicht gemessen). Beide Wege sind ausreichend schnell; `tiny.en` ist nicht nötig. Screenshot mit Untertitel: Untertitel unten im Bild, zweizeilig, halbtransparenter Hintergrund (lokal erstellt, nicht im Repo).

**SpeechTranscriber (Apple, tvOS 26).** Alternative zu whisper, noch nicht angebunden. Gerätetest (2026-11-08, Selbsttest `speech`, `BrowserSpeechProbe.swift`): kompiliert für tvOS (im SDK nur watchOS gesperrt, `DictationTranscriber` ist auf tvOS gesperrt), `SpeechTranscriber.isAvailable = true` auf dem A15, 45 unterstützte Sprachen, keine installiert; `en-US` → `en_US` und `de-DE` → `de_DE` mit `AssetInventory.status` = `supported` (Sprachpaket ladbar, aber nicht vorhanden). Nächster Schritt: Paket per `AssetInventory.assetInstallationRequest(supporting:)` laden und mit `SpeechAnalyzer` am Audio-Tap gegen whisper vergleichen (Qualität, Verzug, Speicher, Deutsch ohne eigenes Modell).

**Test.**
```bash
xcrun simctl spawn <SIM> defaults write io.github.tvosbrowser.app AutoSubtitlesEnabled -bool YES
SIMCTL_CHILD_POINTER_SELFTEST='url:https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov;state' \
  xcrun simctl launch --console --terminate-running-process <SIM> io.github.tvosbrowser.app | grep Subtitles
```
Die .mov wird als Video-Dokument geladen, der Player öffnet automatisch; „Tears of Steel“ hat ab ≈ 20 s englische Dialoge. HLS mit Sprache: `https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/tears-of-steel-audio_eng=128002-video_eng=751000.m3u8` (TS, Ton gemuxt; Selbsttest mit `;wait;…;nplayer`), fMP4: `https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8` (nur Pieptöne). Gerät: `DEVICECTL_CHILD_…` wie in 14.1, Einstellung per Player-Menü, Seitenmenü oder Selbsttest-Schritt `pref:` (14.2), z. B.
```bash
DEVICECTL_CHILD_POINTER_SELFTEST='pref:AutoSubtitlesEnabled=YES;pref:AutoSubtitlesCPUOnly=NO;url:https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov;wait;nplayer;wait;…;nplayer;nclose' \
  xcrun devicectl device process launch --device <UDID> --terminate-existing --console io.github.tvosbrowser.app
```
(ein `wait` = 3 s; für ≈ 100 s Wiedergabe gut 30 Schritte).

Deutsch und Menü (Simulator, 2026-11-08): MP4 bzw. HLS der aktuellen „tagesschau in 100 Sekunden“ (Adressen wechseln täglich, z. B. `https://tagesschau-progressive.ard-mcdn.de/video/2026/1108/TV-20261108-2105-0000.webm.h264.mp4`; HLS mit einer CC-Spur unter `adaptive.tagesschau.de/…/master.m3u8`):
```bash
SIMCTL_CHILD_POINTER_SELFTEST='pref:AutoSubtitlesEnabled=YES;pref:AutoSubtitlesLanguage=auto;url:<mp4>;wait;wait;wait;wait;wait;nplayer;hid:select;hid:up;hid:select;wait;nplayer' \
  xcrun simctl launch --console-pty --terminate-running-process <SIM> io.github.tvosbrowser.app | grep -E 'Subtitles|nplayer|InputTrace'
```
Erwartet: `Sprache festgelegt: de …`, nach `hid:select` eingeblendete Leiste, nach `hid:up` `fokus=AVxOverlayToolCell`, nach dem zweiten `select` `oben=AVUnifiedPlayerContextMenuContainerViewController` (Menü offen). Welcher Knopf fokussiert ist, zeigt ein Screenshot (`xcrun simctl io <SIM> screenshot …`).

**Kaputt?** Keine `[Subtitles]`-Zeilen: Einhängepunkt fehlt. `whisper=0`: Framework nicht gefunden (Suchpfad). `Modell –`: `tools/fetch_whisper_model.sh` nicht ausgeführt bzw. Ordner nicht im Paket. Tap ohne `prepare`: Audio-Mix nicht angenommen (z. B. HLS, dann sollte die HLS-Quelle übernehmen). RTF > 0,8 auf dem Gerät: `tiny-q5_1` nehmen (bzw. `tiny.en-q5_1` nur für Englisch) oder Metal prüfen (`[Subtitles][whisper]`-Zeilen beim Laden). Deutscher Ton ergibt englischen Unsinn: Sprache steht auf „Englisch“ oder nur ein `.en`-Modell im Paket (Log `Erkennung mit base.en-…`, Menü „nur Englisch (Modell)“). Sprache falsch festgelegt (lange Musik, Mischsprache): im Player-Menü die Sprache fest wählen.

### 10.6 Untertitel für Videos in der Webseite (Weg B: Tonabgriff per Web Audio)
**Zweck.** Untertitel für Videos, die in der Seite bleiben (eigener Player der Seite, DASH/MSE, „Native Player automatisch“ aus), als native Ebene über der WebView. Zwei Tonquellen (Stand 2026-11-09):
- **Vorausquelle (bevorzugt):** Meldet das Seiten-Skript eine ladbare Medienadresse (`currentSrc` mit http/https, kein `blob:`), lädt die App den Ton selbst, mit denselben Quellen wie Weg A (MP4: `BrowserSubtitleProgressiveAudioSource`, HLS auch live: `BrowserSubtitleHLSAudioSource`), mit Cookies (`+[BrowserWebView allCookies]`), User-Agent der Seite (`navigator.userAgent`), Referer/Origin des Frames, in dem das Video liegt. Gekoppelt an `currentTime` des Seitenvideos (Live-HLS mit Datum: `getStartDate()` + `currentTime`). Text liegt vor dem Sprechen bereit. Das geht gerade dann, wenn Web Audio nichts liefert: natives HLS im `<video>` (Safari-HLS, z. B. tagesschau.de, ARD), fremde Herkunft ohne CORS, Seite nutzt Web Audio selbst (`source:InvalidStateError`), kein Web Audio, gesperrter AudioContext. Die Hinweise dazu entfallen dann (Log `Hinweis „…“ entfällt, Ton kommt aus der Medienadresse`). Geladen wird erst, wenn das Video spielt (sonst lüde ein Vorschauvideo 60 s Ton für nichts).
- **Mithören über Web Audio (Rückfall):** `blob:`-Quellen (MSE-Player), oder wenn die Vorausquelle scheitert. Die Blöcke gehen als Echtzeitquelle in dieselbe Pipeline wie in Weg A (`BrowserSubtitlePipeline`): jede Sekunde wird der offene Satz neu erkannt, vorläufiger Text ersetzt.
- „Untertitel für dieses Video nicht möglich“ bzw. „… kopiergeschützt“ erscheint nur noch bei echten Grenzen: DRM (`mediaKeys`, `encrypted`, SAMPLE-AES/FairPlay in der Playlist) oder wenn weder Web Audio noch die eigene Quelle Ton liefern (z. B. `blob:` und stumm, Server verweigert die Adresse).

**Dateien.**

| Datei | Aufgabe |
|:--|:--|
| `WebSubtitles/web_audio_tap.js` (Ordnerreferenz, Ressource) | Seiten-Skript: Web Audio ans Video, 16 kHz mono, Blöcke, Zeit/Rechteck, Zustände |
| `BrowserWebAudioCapture.m/.h` | Rückkanal `browserWebAudio`, Base64 → Float32, Ringpuffer 30 s, Rechteck-Umrechnung, Status |
| `BrowserSpeechRecognizing.h/.m` | Protokoll `BrowserSpeechRecognizing`, Cue-Typ `BrowserWebSubtitleCue` (start, end, text) |
| `BrowserWhisperSpeechRecognizer.m/.h` | Erkennung mit whisper.cpp: Adapter um `BrowserSubtitleEngine` (Weg A), eigene Queue, Modell nach `autoSubtitlesLanguage`, Filter für Überlappung und Wiederholungen |
| `BrowserSpeechRecognizerStub.m/.h` | Platzhalter-Erkennung: „[Ton erkannt: 1,0 s · −18 dB]“ (nur ohne whisper/Modell oder im Selbsttest) |
| `BrowserWebSubtitleController.m/.h` | Verbindung: Wahl der Tonquelle (eigene Vorausquelle oder Web Audio), Pipeline, Cues ins Overlay (Datum → Medienzeit), Hinweise nur für echte Grenzen, Versatzmessung, Kennzahlen |
| `BrowserWebSubtitleOverlay.m/.h` | native Untertitel-Ebene (Unteransicht der `BrowserWebView`), Stil nach `MACaptionAppearance` |
| `BrowserPreferencesStore` | `webSubtitlesEnabled` (Schlüssel `WebSubtitlesEnabled`, Standard aus) |
| `BrowserWebView` | `userContentController` (neu, öffentlich); in `commonInit` Skript und Rückkanal früh installieren, wenn `webSubtitlesEnabled` |
| `ViewController.m` | `browserSetWebSubtitlesEnabled:` (Menüschalter „Untertitel (Webseite)“ in `BrowserMenuCoordinator`), `startWebSubtitlesIfEnabled` (App-Start in `viewDidAppear:`, Tabwechsel in `activeWebViewChangedFrom:`), `prepareWebSubtitleControllerUsingStub:language:` (Erkennung wählen), Selbsttest `websubs` |

**Datenfluss.**
1. `startForWebView:` registriert (einmal je `WKUserContentController`, per assoziiertem Objekt) den Rückkanal `browserWebAudio` mit schwachem Vermittler (`class_addProtocol` wie in Abschnitt 4), fügt das Nutzerskript hinzu (document-start, **alle Frames**) und spielt Skript plus Startbefehl sofort in die aktuelle Seite (`evaluateJavaScriptAsync:`). iframes der aktuellen Seite bekommen das Skript erst nach dem nächsten Laden; ist `webSubtitlesEnabled` beim Anlegen der WebView schon an, sofort. Nach jeder Navigation meldet das Skript `ready`, die App schickt den Startbefehl erneut.
2. Skript (`window.__browserWebAudio.start({block,silence,mode,force})`): wählt jede Sekunde das Video (spielend vor hörbar vor größter sichtbarer Fläche; springt nicht hin und her). Ohne Video im Hauptframe gibt es den Befehl per `postMessage` an alle iframes weiter.
3. Vorabprüfung, **bevor** das Video angefasst wird (sonst wäre es stumm): DRM (`mediaKeys`/`webkitKeys`) → `blocked drm`; natives HLS (`.m3u8` direkt als `src`, kein MSE) → `blocked hls`; fremde Herkunft ohne `crossorigin` → `blocked cors`. `blob:`-Quellen (MSE) laufen durch.
4. `AudioContext` anlegen und `resume()`; `createMediaElementSource()` erst, wenn der Kontext `running` ist. Gesperrt → Zustand `suspended gesture`, Fortsetzen beim nächsten `pointerdown`/`click`/`keydown`/`play`. Im Simulator (tvOS 27.2) lief der Kontext ohne Geste nach wenigen Millisekunden, vermutlich weil die WebView `mediaTypesRequiringUserActionForPlayback = 0` setzt.
5. Kette: `source → destination` (Ton zu den Lautsprechern, bleibt für immer) und `source → Abgriff → Gain 0 → destination`. Abgriff = `AudioWorkletNode` (Modul als `blob:`-URL), sonst `ScriptProcessorNode(4096)` (wenn Worklet fehlt oder CSP `blob:` verbietet). Im Abgriff: Downmix auf mono (Kanalzahl 2, `speakers`, Mitte geht mit ein), Butterworth-Tiefpass 7 kHz, Mittelung auf 16 kHz.
6. Je Block (Standard 0,5 s = 8000 Werte): RMS/Spitze, `t` = Medienzeit des ersten Werts (aus `video.currentTime` minus Verzug im Graphen), Base64 der Float32-Bytes (reine Nullen ohne Daten, `zero:1`). Bei Pause, Spulen, Puffern keine Blöcke. Alle 250 ms und bei `play/pause/seeking/seeked/ratechange` eine `time`-Meldung mit `currentTime`, Rate, Pause, Rechteck (CSS-Pixel), `innerWidth`, fixiert, Vollbild. iframes melden das Rechteck an den Elternframe, der es um die Lage des iframes verschiebt.
7. App: Blöcke auf der seriellen `sampleQueue` dekodieren → Ringpuffer (30 s) mit zusammenhängenden Abschnitten (neuer Abschnitt bei mehr als 0,3 s Abweichung, `segmentGeneration`) → `sampleHandler`. Rechteck wie die übrigen Video-Rechtecke umrechnen: `× viewWidth / innerWidth`, `+ topObscuredInset`, plus seit der Meldung gescrollte Strecke (KVO auf `contentOffset`, nicht bei fixierten Videos).
8. Medienadresse: Skript meldet in `state` (blocked, silent, error, unsupported, suspended, running) und bei Änderung in `time` die Felder `src` (`currentSrc`), `page` (Adresse des Frames), `ua`, bei Live-HLS `sd` (`getStartDate()` in ms). Ohne DRM beobachtet das Skript ein abgelehntes Video trotzdem („nur Zeit“, `observeOnly`): Zeit, Rechteck und Adresse gehen an die App, Web Audio wird nicht angehängt (Video bleibt hörbar). `BrowserWebAudioCapture` reicht die Adresse per `mediaSourceHandler` weiter (vor dem Zustand, damit der Controller den Hinweis unterdrücken kann).
9. `BrowserWebSubtitleController`: ladbare Adresse und Video spielt → Vorausquelle (`.m3u8` → HLS, `.mp4/.m4v/.mov/.m4a` → MP4, ohne Endung erst MP4, dann HLS); schlägt sie fehl, nächste Art, dann Mithören über Web Audio (Adresse merken, nicht erneut versuchen). Neue Adresse im selben Tab, Navigation (`ready`) oder „kein Video“ beenden die Quelle. Wiedergabestand (`time`, alle 250 ms) → `updatePlaybackTime:date:rate:`; Pause → angefangenen Abschnitt auswerten. Bei Datumszeitachse werden die Untertitelzeiten um `getStartDate()` verschoben (fehlt es, werden sie verworfen, Log). Test/Messung: `pref:SubtitlesForceTap=YES` = nur Mithören.
10. Overlay: Zeit = letzte gemeldete `currentTime` + vergangene Zeit × Rate (höchstens 1,5 s ohne Meldung weiterzählen), `CADisplayLink` mit 10–15 Hz. Rollend wie im nativen Player (10.9 Ablauf 7): neuester begonnener Untertitel unten, der vorige darüber bis zu seiner Mindestdauer (2–4 s), höchstens zwei, ≤ 120 Zeichen; ohne Nachfolger bis `holdDuration` nach dem Ende (Vorausquelle 0,8 s, Mithören 2 s). Bei Pause bleibt der Text stehen. Position: unten im sichtbaren Teil des Video-Rechtecks (6 % Abstand), zentriert, höchstens 90 % Breite, 3 Zeilen. Größe: 6,2 % der Videohöhe, 34–72 pt, mal `MACaptionAppearanceGetRelativeCharacterSize`. Farben, Schrift, Kantenstil aus `MACaptionAppearance` (Domäne Nutzer), Hintergrund halbtransparent (0,6), außer in den Einstellungen ist ausdrücklich eine Deckkraft gewählt. Bei Element-Vollbild legt sich das Overlay über das oberste Fenster der Szene (nicht getestet).
11. Hinweise im Untertitel-Stil (6 s): DRM; CORS, HLS, Stille, stumm, Klick nötig und Fehler nur, wenn die App den Ton nicht selbst laden kann; „Kein Video“ nur direkt nach dem Einschalten (`startForWebView:userInitiated:YES`).

**Zustände** (`BrowserWebAudioCaptureStatus`, Detail in Klammern): `Starting`, `WaitingForInteraction` (gesture), `Running`, `Silent` (cors, muted, hls, silence; nach 4 s reiner Nullen bei laufendem Video), `NoVideo` (iframes:N), `Blocked` (cors, hls, drm), `Unsupported`, `Error` (source:InvalidStateError = Seite hängt das Video selbst an Web Audio; script), `Stopped`.

**Ausschalten.** `stop` trennt nur den Abgriff (`source.disconnect(tap)`, sonst alles trennen und wieder an `destination`). Die Quelle bleibt an den Lautsprechern, der `AudioContext` wird nie angehalten: `createMediaElementSource` geht pro Element nur einmal, danach hört man das Video nur noch über Web Audio.

**Erkennung (whisper, `BrowserWhisperSpeechRecognizer`).** Erfüllt `BrowserSpeechRecognizing` und nutzt die Engine aus Weg A unverändert (gleiche Modelle, Parameter, Stille-/Rauschfilter, Logs `[Subtitles] Abschnitt …`); nichts davon ist doppelt.
- Auswahl in `ViewController prepareWebSubtitleControllerUsingStub:language:` (aufgerufen von `browserSetWebSubtitlesEnabled:`, `startWebSubtitlesIfEnabled` und dem Selbsttest): Sprache = `autoSubtitlesLanguage` (dieselbe Einstellung wie im Player-Menü; „en“ → `base.en-q5_1`, „auto“ und andere Sprachen → mehrsprachiges `base-q5_1`, Reihenfolge `+[BrowserSubtitleEngine modelCandidatesForLanguage:]`). Bei „auto“ legt die Engine die Sprache wie in Weg A nach zwei Abschnitten mit Sprache fest (10.9 **Sprache**); die Festlegung gilt je Engine, also bis zum Sprachwechsel oder zum Freigeben des Modells nach Leerlauf, danach wird neu erkannt. Gleiche Sprache: Erkennung (und geladenes Modell) bleibt; andere Sprache: Controller stoppen, neue Erkennung. Fehlt whisper im Build oder ein Modell, läuft der Platzhalter weiter, mit Log `[WebSubs] whisper nicht verfügbar (…)` und Hinweis „Untertitel: kein Sprachmodell in der App, es wird nur der Tonpegel angezeigt“.
- Abschnitt 3,0 s, Überlappung 0,5 s (`preferredWindowDuration`/`preferredOverlapDuration`); `audio_ctx` 384 (Mindestwert der Engine).
- Eigene serielle Queue (`…websubtitles.whisper`, QoS user-initiated): `transcribeSamples:…` kopiert die Werte und kehrt sofort zurück, `completion` kommt genau einmal von dieser Queue. Das Modell wird beim Anlegen im Hintergrund geladen. Ein Abschnitt, der länger als eine Abschnittslänge auf das Laden gewartet hat, wird verworfen (Log `Abschnitt @ … verworfen, … auf das Modell gewartet`), sonst käme der erste Text viele Sekunden zu spät.
- `reset` (Spulen, Pause, Seitenwechsel): Generation erhöhen, laufendes `whisper_full` abbrechen (`cancel`, threadsicher), Zusammenhang leeren.
- Nachbearbeitung der Engine-Cues: (1) gleiche Segmente hintereinander und Wiederholungsschleifen in einem Segment („I'm gonna be I'm gonna be …“, Periode 1–8 Wörter, mindestens dreimal) auf ein Vorkommen kürzen; (2) Wörter am Anfang, die wegen der Überlappung schon am Ende des letzten Abschnitts standen, entfernen (Controller ersetzt nur Cues ab Abschnittsbeginn; ein einzelnes kurzes Wort wie „I“ bleibt); (3) gleicher Text innerhalb 15 s wird verworfen (wie Weg A; trifft Sätze, die in zwei Abschnitten stecken, und erfundene Wörter bei Musik).
- Speicher: nach 90 s ohne Abschnitt (`idleUnloadDelay`) wird das Modell freigegeben (`[WebSubs][whisper] 90 s ohne Abschnitt …`), z. B. während das Video pausiert oder der native Player mit eigener Engine läuft; der nächste Abschnitt lädt es neu (0,15 s).
- Logs: `[WebSubs] Start: Erkennung whisper base.en-q5_1 (en) …`, `[WebSubs][whisper] Modell … bereit in … s, Speicher … MB`, `[WebSubs][whisper] Überlappung: N Wort/Wörter entfernt`, `… Wiederholungsschleife: …`, `… Wiederholung innerhalb 15 s verworfen`, dazu die Engine-Zeilen `[Subtitles] Abschnitt 3.0 s @ … s: N Segmente in … s (RTF …)`.

**Metal (Gerät).** `tools/build_whisper.sh` kompiliert die ggml-Kernel jetzt mit der Metal-Toolchain für tvOS vor (`-DGGML_METAL_TARGET_OS=tvos`, vorher wurde für macOS übersetzt) nach `vendor/whisper-metal/appletvos/default.metallib` (≈15 MB, committet); das Geräte-Framework enthält keinen Kernel-Quelltext mehr (8,5 → 3,3 MB). Die Build-Phase „Whisper-Metal-Kernel kopieren“ legt die Datei ins App-Paket, ggml lädt sie dort (`ggml_metal_library_init: loading '…/default.metallib'`) statt beim ersten Start alles zu übersetzen. Simulator-Teil unverändert mit eingebetteten Kernels (rechnet ohnehin auf der CPU). `ggml-tensor.metallib` wird nicht übernommen (ggml nutzt die Tensor-API erst ab A19/M5).

**Fragil/Grenzen.**
- Fremde Herkunft ohne CORS, DRM und natives HLS liefern über Web Audio nur Nullen (im Simulator für CORS und HLS nachgewiesen). Vorab abgefangen; außer bei DRM lädt die App den Ton dann selbst. Greift die Prüfung nicht (Umleitung auf einen anderen Server), ist das Video stumm, bis die Seite neu geladen wird.
- Vorausquelle: Adressen mit kurzlebigem Token, Cookies mit `HttpOnly` aus fremden Frames, Server, die auf den TLS-Fingerabdruck oder Header prüfen, könnten die App-Anfrage ablehnen → Rückfall Web Audio bzw. Hinweis. Doppelte Datenmenge bei MP4 (siehe 10.9).
- Seiten, die ihr Video selbst an Web Audio hängen: `createMediaElementSource` wirft, Zustand `Error source:…`.
- Lippensynchronität: Der Ton läuft durch den Web-Audio-Graphen (Simulator: `baseLatency` 2,7 ms; Gerät: `baseLatency` 2,7 ms, `outputLatency` 80 ms über HDMI); mit Auge/Ohr noch nicht geprüft.
- Ist „Native Player automatisch“ an, übernimmt bei MP4/HLS der native Player (Weg A); Weg B betrifft dann nur Videos, die in der Seite bleiben.
- Im tvOS-Simulator (27.2) gibt es weder `MediaSource` noch `ManagedMediaSource` (die dash.js-Beispielseite lädt nicht). MSE-Seiten (Mediatheken, DASH) sind also nur auf dem Gerät testbar. `blob:`-Quellen werden wie gleiche Herkunft behandelt.
- Zeitzuordnung: In der ersten Sekunde nach dem Anhängen weichen Blockzeiten um bis zu 0,3 s ab (gepufferter Ton), danach stabil (Abstand 0,50 s).
- Nur der aktive Tab.
- Mithören (Web Audio): whisper sieht den offenen Satz bis 8 s und rechnet ihn jede Sekunde neu; der fertige Satz ersetzt den vorläufigen. Bei Musik ohne Sprache erfindet whisper gelegentlich Wörter („directional“, „Aah!“). Die früheren festen 3-s-Abschnitte (Text Ø 2,4 s spät, Sätze an Abschnittsgrenzen geteilt) gibt es nicht mehr; `windowDuration`/`overlapDuration` sind nur noch Auskunft.
- Speicher: Läuft der native Player (Weg A, eigene Engine) während Weg B ein Modell hält, liegen kurz zwei Modelle im Speicher (je ≈ 130–160 MB); Weg B gibt seins nach 90 s ohne Abschnitt frei.

**Kaputt?** Logzeilen `[WebAudio] Zustand …`, `[WebAudio] Medienadresse … (Frame …)`, `[WebSubs] Medienadresse bekannt, Ton wird beim Abspielen geladen`, `[WebSubs] Tonquelle mp4|hls (App lädt selbst, Referer …, N Cookies) für …`, `[WebSubs] Tonquelle … geht nicht: …`, `[WebSubs] Hinweis „…“ entfällt, …`, `[WebAudio] Block #N 0.50 s t=… rms=…` (DEBUG, jeder Block), `[WebSubs] Abschnitt a–b s (mp4|hls|webaudio, bei t=…): …` (DEBUG), `[WebSubs] Anzeige Δ=+0.11 s (Sprechbeginn …, eingeblendet …, hls) „…“`, Versatz-Zusammenfassung in `websubs:status` und beim Stoppen. Im Skript: `js:window.__browserWebAudio.status()` (JSON mit Zustand, Modus, `ctx`, Abtastrate, Latenzen, Blöcke, Video). `[WebAudio] Startbefehl ohne Erfolg: missing` = Skript fehlt im Paket (Ordnerreferenz `WebSubtitles`).

**Test.** Selbsttest-Schritt `websubs` (Abschnitt 14.2). Für Tests „Native Player automatisch“ ausschalten. Beispiele (kein `;` in `js:`, Komma-Ausdrücke nutzen):
```
# gleiche Herkunft: Block-Log, Overlay (Screenshot nach ~20 s)
POINTER_SELFTEST='url:<Seite mit MP4 gleicher Herkunft>;js:document.querySelector("video").play()&&1;websubs;wait;wait;websubs:status'
# Fallback ScriptProcessor, Pause, Spulen, Ausschalten (Video läuft weiter)
… websubs:sp;wait;js:document.querySelector("video").pause()||1;wait;js:(document.querySelector("video").currentTime=20)&&document.querySelector("video").play()&&1;websubs:status;websubs:off;video
# CORS: erst blocked cors, mit force die Stille-Erkennung (silent cors nach 4 s)
… websubs;wait;websubs:force;wait;wait;websubs:status
# whisper-ähnlicher Takt (3 s Abschnitt, 0,5 s Überlappung, 1,2 s Rechenzeit)
… websubs:slow;wait;wait;wait;websubs:status
# whisper mit Sprache: lokale Testseite (Video gleicher Herkunft, Server mit Range-Anfragen; python3 -m http.server
# kann kein Range, dann spielt WebKit das MP4 nicht), Simulator erreicht 127.0.0.1 des Macs
url:http://127.0.0.1:8765/;wait;js:(document.querySelector('video').currentTime=15,document.querySelector('video').play(),1);websubs;wait;…;websubs:status;websubs:stub;wait;…;websubs:status;websubs:off
```
Messwerte im Simulator (Mac, tvOS 27.2, Stub): Weg Skript → App 0,7–1,6 ms je Block, Base64 im Skript 0,05–0,09 ms, Dekodieren in der App 0,2 ms, Verzug im Graphen 0–9 ms. Anzeige-Verzug = Abschnittslänge + Rechenzeit (Stub 1 s: Ø 0,9–1,1 s; 3 s + 1,2 s Rechenzeit: rund 4,3 s nach Abschnittsbeginn). CPU (ps): App etwa +0,7, WebContent etwa +1,1 Prozentpunkte gegenüber Wiedergabe ohne Abgriff.

Messwerte mit whisper (Simulator auf Mac mit Apple Silicon, tvOS 27.2, CPU, 4 Threads, `base.en-q5_1`, Tears of Steel 720p als MP4 gleicher Herkunft über lokalen Server, Stand 2026-11-08): Modell laden 0,15 s (nach Neuinstallation einmalig ≈16 s Metal-Übersetzung, siehe 10.9), Speicher der App 32 → 192 MB nach dem Laden, 176–184 MB während der Erkennung, 61 MB nach dem Freigeben. Rechenzeit je 3-s-Abschnitt 0,27–0,42 s (RTF ≈ 0,1–0,13), nichts übersprungen. Text sichtbar Ø 2,6–3,5 s nach Beginn des Abschnitts (Spanne 0,7–3,6 s; Abschnitt 3 s + Rechenzeit + Blocktakt 0,5 s). CPU der App (kumulierte CPU-Zeit): whisper ≈ 17 % eines Kerns, Platzhalter ≈ 1,5 %. Erkannt z. B. „You're a jerk tongue.“ (gesprochen: „You're a jerk, Thom“), „Look, Celia, we have to follow our passions.“, „just admit that you're freaked out by my...“, „I'm having nightmares that I'm being chased by these guys.“, „Robots memory?“/„synced, and locked.“.

Messwerte Gerät (Apple TV 4K 3. Gen., A15, tvOS 27.2, Debug, Metal, `base.en-q5_1`, Stand 2026-11-08): Testseite ist die .mov selbst als Video-Dokument (gleiche Herkunft, kein Server nötig), „Native Player automatisch“ per `pref:AutoOpenVideosInNativePlayer=NO` aus:
```
pref:AutoOpenVideosInNativePlayer=NO;url:https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov;wait;wait;js:(window.v=document.querySelector('video'),v.currentTime=18,v.play(),1);websubs;wait;…;websubs:status;websubs:off;pref:AutoOpenVideosInNativePlayer=
```
- Web Audio: `suspended gesture` → `running` nach 26 ms ohne Klick (wie im Simulator), AudioWorklet, 48 kHz, `baseLatency` 2,7 ms, `outputLatency` 80 ms. Blöcke ohne Nullen, Weg Skript → App 1,0–1,3 ms, Dekodieren 0,6–0,7 ms.
- Modell laden 0,20 s, Speicher der App 31 → 136 MB, während der Erkennung 135–145 MB (WebContent-Prozess nicht gemessen). Kein Jetsam, kein Absturz des Seitenprozesses.
- Rechenzeit je 3-s-Abschnitt 0,10–0,29 s (Ø 0,15–0,18 s, RTF ≈ 0,04–0,10), 33–35 Abschnitte je Lauf, nichts übersprungen. Vor der Token-Grenze (siehe 10.9, Ablauf 4) zwei Ausreißer bei Musik mit 2,1 s (RTF 0,7, „Sssss…“ bzw. verworfener Text), danach höchstens 0,39 s.
- Text sichtbar Ø 2,4 s nach Abschnittsbeginn (Spanne 0,6–3,3 s), Overlay unten im Video (Screenshot geprüft). Erkannt wie im Simulator („Look, Celia, we have to follow...“, „and I just want to be awesome in space.“, „just admit that you're freaked out by my...“, „synced and locked.“); bei Musik „directional“ (Wiederholung innerhalb 15 s verworfen).
- Offen: MSE-Seite (Mediathek, DASH), Lippensynchronität mit Auge/Ohr (Web-Audio-Ausgabe meldet 80 ms `outputLatency`; ob WebKit das Bild darauf abstimmt, ist ungeprüft).

**Menüeintrag.** „Untertitel (Webseite)“ in `BrowserMenuCoordinator.m` (ruft `browserSetWebSubtitlesEnabled:`), Einstellung `webSubtitlesEnabled` bleibt gespeichert.

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

**`UIApplication sendEvent:`-Tausch (aktiv, Stand 2026-11-08).** Gibt jedes Ereignis unverändert weiter (Berührungen und Tasten, auch im nativen Player) und hat nur noch zwei Aufgaben: (1) Begann ein Menü-Druck im nativen Player und ist der Player danach zu (AVKit hat ihn geschlossen), werden die restlichen Phasen dieses Drucks verworfen (`sBrowserMenuPressBeganInNativePlayer`, Log `swallow Menu Ended after native player`); sonst käme das Ende bei der Seite an und blätterte zurück. (2) Ist kein nativer Player offen, wird das Ende eines Auswahl-Drucks als `BrowserGlobalSelectPressEndedNotification` an `ViewController` gemeldet (`handleGlobalSelectPressEndedNotification`), mit `userInfo[@"timestamp"]` = `press.timestamp` (`BrowserRemoteInputController handleGlobalSelectPressEndedWithTimestamp:`). Derselbe Druck erreicht meist auch `pressesEnded:`; die Kopie wird über den gleichen Zeitstempel verworfen (DEBUG-Log `[Keys] Auswahl doppelt (sendEvent), verworfen`). Finden des Players: Suche über alle Fenster/Controller nach der Klasse `BrowserNativeVideoPlayerViewController`.

**Früher** (aus dem Original übernommen): Der Tausch fing im Player Klick (→ `togglePlayback`), Links/Rechts (→ nur Doppeltipp ±5 s, `skipByInterval:`), Indirect-Touches (→ `scrubByHorizontalDelta:`) und den Beginn von Menü (→ Player schließen) ab. Damit kam AVKit nie an die Tasten: keine Transportleiste per Fokus, Untertitel- und Audio-Menü unerreichbar, Menü schloss den Player statt eines Menüs. **Nicht wieder einbauen**, AVKit macht das selbst (10.2 „Fernbedienung im Player“).

**Kaputt?** Im Player öffnet Klick auf einen Knopf der Leiste kein Menü oder Menü schließt den Player sofort: `[InputTrace][App] press=… phase=… top=…` muss jede Taste zeigen, `swallow …` nur nach dem Schließen. Seite blättert nach dem Schließen zurück: Menü-Rest wird nicht verworfen.

**Test.** Selbsttest `hid:select,up,select` (14.2) schickt Tasten über den echten Weg (`sendEvent:` → Fokus → AVKit), `nplayer` zeigt Fokus und offenes Menü; `state` zeigt, ob der Player präsentiert ist. Am Gerät: Konsole mit `devicectl … --console`, Tasten drücken und `[InputTrace]`-Zeilen lesen.

---

## 13. Start- und Verlaufsansicht, Bedienungsdialog, Tab-Übersicht

Alle rein UIKit, niedriges Update-Risiko. Hier nur die Einhängung.

- **Adresse bearbeiten mit Aufklapp-Bereich** (`BrowserAddressPanelView.m`, ersetzt die Vollbild-Startansicht): Einziger Einstieg ist `beginAddressEditing` in `ViewController.m`. Auslöser: Klick auf Adresse oder Kapsel (auch im Fokusmodus der Leiste), zweimal oben, Play/Pause lang, Schnellmenü und Ladefehler-Dialog „Adresse oder Suche“, Sprachbefehl/Siri `address` („Suche“). Ist die Tab-Übersicht offen, wird sie vorher geschlossen. Die Leiste klappt aus und wird zum Diktierfeld (Abschnitt 9), direkt darunter öffnet sich sofort die Systemtastatur mit Fokus (Abschnitt 13.1); darunter wächst eine Glas-Karte (`UIGlassEffect` klar, Abdunkelung 0,38) in Leistenbreite 14 pt unterhalb aus der Leiste heraus (über `BrowserMotion`, Abschnitt 17: mit Liquid Glass als Kapsel aus der unteren Hälfte der Leiste, Glas materialisiert, Feder mit leichtem Bounce; schlicht Alpha und Höhe; Inhalt blendet verzögert ein); die Seite bleibt mit 50 % Schwarz gedimmt sichtbar. Drei Spalten „Favoriten“ (Stern, Icons 136 pt, ohne Namen), „Oft besucht“ und „Zuletzt“ (Icons 96 pt mit Namen darunter), je 2 × 2 Kacheln; leere Plätze als dezente Flächen. „Zuletzt“ meidet Seiten, die schon unter „Oft besucht“ stehen, füllt bei wenig Verlauf aber auf. Kacheln bleiben unter 420 × 140 pt, damit der Zeiger mittig einrastet; die Hervorhebung ist die normale Magnetic-Button-Hervorhebung (Glas, Glow Standardblau). Die Karte ist rein optisch (`userInteractionEnabled = NO`); Ziele liefert `pointerTargetRectsInView:`, Klick `handleSelectionAtPoint:inView:`. Die Karte rückt um `keyboardSpace` (Platz der Tastaturkarte, `BrowserAddressInputController keyboardAreaHeight` 204 pt, mit Knopf „Los“ mehr) nach unten und beim Wechsel zu den Kacheln wieder hoch (`setKeyboardSpace:animated:`, Feder „Snap“ aus `BrowserMotion`). Klick auf das Feld bzw. Play/Pause öffnet die Tastatur wieder (`showAddressKeyboard`). Eingabe lädt wie bisher und schließt den Zustand. Menü oder Klick neben die Karte schließt. Die früheren Eingabedialoge (`showAddressDictationInput`, `showInputURLorSearchGoogle`, `UIAlertController` mit Vollbild-Tastatur) und `showStartView` sind entfernt. Logpräfix `[Address]`.
- **Favicons** (`BrowserFaviconCache.m`): Reihenfolge `https://<host>/apple-touch-icon.png`, `/apple-touch-icon-precomposed.png`, `/favicon.ico`, dann `https://www.google.com/s2/favicons?domain=<host>&sz=128`. Erstes Bild ab 48 px gewinnt, kleinere werden nur genommen, wenn nichts Besseres kommt. Speicher (`NSCache`) und Platte (`Library/Caches/Favicons/<host>.img`, Fehlschlag als `.none`, nach 24 h neuer Versuch). Ab 96 px füllt das Icon die Kachel, kleinere sitzen auf hellem Grund; ohne Icon Anfangsbuchstabe auf farbiger Kachel (Farbe aus dem Host). Logpräfix `[Favicon]` (DEBUG).
- **Alte Start-/Verlaufsansicht** (`BrowserStartViewController.m`, liegt noch im Projekt, wird aber nirgends mehr aufgerufen; `showStartView` ist entfernt): Suchfeld, „Zuletzt besucht“, „Meistbesucht“, Favoriten; öffnet über `openURLHandler`. Daten aus `BrowserHistoryStore` (`recordVisitWithURL:title:`, `recentEntries:`, `topEntries:`, `favorites`, `addFavoriteWithURL:…`, `isFavoriteURL:`; je Host zusammengefasst, in `NSUserDefaults`; Benachrichtigung `BrowserHistoryStoreDidChangeNotification`). Früher Aufruf über Klick auf die Adresse.
- **Sprachbefehle** (`BrowserCommand.m`, `BrowserCommandParser.m`, `BrowserCommandRouter.m`; Konzept `docs/SIRI_STEUERUNG.md`): Text aus dem Adressfeld (Diktat oder Tastatur) geht in `handleEnteredAddressText:` (`ViewController.m`) zuerst an `BrowserCommandParser parseText:`. Treffer → `BrowserCommandRouter performCommandNamed:argument:source:`, sonst wie bisher `openAddressOrSearch:`. Die Tabelle `BrowserCommand allCommands` enthält Name, Titel, Symbol, Argumentart (keins, an/aus/umschalten, Text, Sekunden) und Phrasen als Muster mit Alternativen (`"(starte|start) (den |)reader"`). Der Parser normalisiert (klein, Satzzeichen weg, Bindestrich = Leerzeichen, Füllwörter wie „bitte“ weg) und akzeptiert **nur ganze Phrasen**; danach „30 Sekunden zurück“ und die Präfixe „suche [nach] X“/„google X“ (Suche) und „öffne X“/„gehe zu X“ (nur, wenn X wie eine Adresse klingt, „heise punkt de“ wird `heise.de`). Der Router ruft das Host-Protokoll `BrowserCommandHost` (im `ViewController`, Abschnitt „BrowserCommandHost“) und blendet eine Glas-Kapsel unten mittig ein (`BrowserCommandToastView`, im Fenster, 1,8 s; keine Einblendung bei `address`, `tabs`, `menu`, `help`, die selbst etwas öffnen). Siri (`handleSiriCommandNotification:`) nutzt denselben Router. Neue Funktion anbinden: Eintrag in `allCommands`, Zweig in `performCommandNamed:`, Methode im Host. Debug-Build meldet doppelte Phrasen (`[Command] Phrase doppelt`). Screenshots in `docs/command-screens/`.
- **Bedienungsdialog** (`BrowserGuideViewController.m`): Glas-Karte mit kurzer Bedienungshilfe, Schalter für den Start-Hinweis (`dontShowHintsOnLaunch`, `toggleHandler`). Aufruf `showHintsAlert` in `ViewController` (beim Start einmal, per Selbsttest `guide`). Der Text sollte mit Abschnitt 8.2 übereinstimmen; bei geänderter Belegung hier und in `README.mdown` nachziehen.
  Stand 8. November 2026: sechs Zeilen (Zeigen/Klicken, Scrollen und Adresse, Knopf zu Knopf, Play/Pause, Zurück, Reader und mehr) plus Fußzeile (Kreisbewegung, iPhone/iPad); Abstände so gewählt, dass eine siebte Zeile (z. B. „Sprachbefehle“) noch auf den Bildschirm passt (Test mit Platzhalterzeile: `docs/guide-screens/guide-7-zeilen-test.png`, aktueller Stand `guide.png`). Der Dialog erscheint beim Start, bis „Nicht mehr anzeigen“ gewählt wird (Standard: anzeigen, also beim ersten Start automatisch); im ••• Menü unter „Hilfe → Bedienung“ jederzeit abrufbar. Startseite bleibt die einstellbare Webseite (`homePageURLString`, Vorgabe google.com); eine eigene HTML-Startseite gibt es nicht. Alle Dialogtexte sind deutsch (alte Sitzungen mit dem Tabtitel „New Tab“ werden beim Laden umbenannt).
- **Was ist neu** (`BrowserGuideViewController.m` mit `whatsNew = YES`): gleiche Glas-Karte wie der Bedienungsdialog, Titel „Was ist neu“, 14 Neuerungen dieser Fassung gegenüber dem Original in zwei Spalten (`+whatsNewItems`: Symbol, Titel, eine Zeile Text; höchstens 14, sonst passt die Karte nicht mehr auf den Bildschirm). Knöpfe „Weiter“ und „Bedienung ansehen“ (`showGuideHandler` öffnet danach den Bedienungsdialog). Erscheint einmal beim Start, wenn `WhatsNewSeenVersion` in den Defaults nicht `+whatsNewVersion` entspricht (dann statt des Bedienungsdialogs); neue Punkte → Liste ergänzen und `whatsNewVersion` hochzählen. Jederzeit unter ••• → Hilfe → „Was ist neu“ (`browserShowWhatsNew`), Selbsttest `whatsnew`. Hinweis: `xcrun simctl spawn … defaults delete` erreicht den App-Container nicht; zum Testen App deinstallieren oder den Selbsttest nutzen.
- **Seitenleiste (•••)** (`BrowserMenuCoordinator.m`, `BrowserAdvancedMenuViewController`, Kachel `BrowserAdvancedMenuTile`, Überschrift `BrowserAdvancedMenuHeader`): Glas-Panel rechts, so breit wie früher die einspaltige Liste (38 % der Bildschirmbreite, 480–700 pt; Radius `BrowserShapePanelRadius`). Inhalt ist ein `UICollectionView` mit `UICollectionViewFlowLayout` in zwei Spalten: Kacheln hochkant, 150 pt hoch, 18 pt Abstand, Abschnittsüberschrift über beide Spalten. Kachelradius konzentrisch zum Panel (`BrowserShapeConcentricRadius(PanelRadius, PanelInset)` = 36). Jede Kachel: oben links farbiger Symbolkreis 50 pt (Farbe je Abschnitt, `BrowserMenuTintForSection`; Symbol je Titel, `BrowserMenuSymbolForTitle`, unbekannte Titel bekommen einen Punkt), oben rechts bei „An“/„Aus“ ein Schalter (grün/grau), darunter Titel (bis zwei Zeilen) und Wert. Ruhend eigene Glasfläche (Weiß 13 %) mit Kante (1,5 pt, Weiß 16 %), damit die Kacheln klar getrennt sind. Im Fokus wie in tvOS üblich hell (Weiß 96 %) mit dunkler Schrift, Schatten und Anhebung 1,05 (Feder über `BrowserMotion` Snap); ausgeschaltete Schalter werden dabei dunkel getönt, damit sie auf der hellen Fläche sichtbar bleiben. Die Liste ist beschnitten und läuft über die volle Panelbreite; seitlich 14 pt Abschnittsrand und oben 8 pt Inset lassen der vergrößerten Fokus-Kachel Platz. Neuer Eintrag: Titel in `BrowserMenuSymbolForTitle` eintragen, sonst erscheint der Platzhalterpunkt. Selbsttest `scrollend` scrollt die Liste im obersten Dialog ans Ende (für Screenshots). **Offen bleiben** (seit 9. November 2026): Wertkacheln (Schalter und Einstellwerte wie Seitenzoom, Zeigertempo, Untertitelsprache) und die Schriftgröße lassen die Leiste offen; die Kacheln werden an Ort und Stelle neu befüllt (`refreshSections`, `sectionsProvider`), der Fokus bleibt. Was navigiert, einen Dialog öffnet oder die Webansicht neu baut (Zusammenfassen, Übersetzen/Übersetzung beenden, Startseite festlegen, Filterlisten aktualisieren, Obere Leiste, Browser-Kennung, alle Aktionen ohne Wert), schließt sie wie bisher (`BrowserMenuItemKeepsMenuOpen`). Log `[Menu] Auswahl „…“: Leiste bleibt offen`. **Öffnen:** Hereinfedern startet in `viewWillAppear:` parallel zur Überblendung (vorher erst nach ihr in `viewDidAppear:`), Messung am Gerät 52 ms vom Druck bis zum Beginn (`[Perf] Seitenleiste: …`).
- **Tab-Übersicht** (`BrowserTabOverviewController.m`): Kartenansicht der Tabs, selbst ein modaler Dialog (`BrowserTabOverviewViewController`); Host-Protokoll `BrowserTabOverviewControllerHost`. Menü und Play/Pause behandelt der Controller in `pressesEnded:` selbst (Menü schließt, Play/Pause schließt den fokussierten Tab, zweiter Druck innerhalb 0,4 s verworfen), Klick über den Fokus; die Zweige in `BrowserRemoteInputController` (`TabOverviewVisible`, `…DismissTabOverview`, `…HandleTabOverviewAlternateAction`) greifen nur, wenn eine Taste doch dort ankommt. Seitenleiste und Übersicht können nicht gleichzeitig offen sein (beide modal); `browserShowTabOverview` schließt einen anderen offenen Dialog vorher, sonst schlüge die Präsentation still fehl und die Übersicht gälte als offen. Tastenverhalten bei offenen Dialogen: Abschnitt 8.2.
- **Sitzung** (`BrowserSessionStore.m`, `BrowserTabCoordinator.m`; je Tab zusätzlich `openedAt` und `used`, Abschnitt 24): offene Tabs und Cookie-Kopie in `NSUserDefaults`; `persistSession` vor Rückgabe an Home. **Startseite beim Start:** Nach einer wiederhergestellten Sitzung (`launchHomePagePending`) zeigt `webViewDidAppear` einmalig die eingestellte Startseite (`showHomePageAfterLaunch`): steht sie schon in einem Tab (gleicher Host ohne „www.“ und Pfad), kommt dieser nach vorn; ein leerer aktiver Tab lädt sie; sonst öffnet sie in einem neuen Tab, die übrigen bleiben im Hintergrund; sind alle 5 Tabs belegt, lädt der aktive Tab sie (Zurück führt zur vorigen Seite). Eine gemerkte Wiederöffnen-Adresse (`consumeSavedURLToReopenRequest…`) hat Vorrang. Vorher lud der Start nur den zuletzt aktiven Tab. Log `[Tabs] Start: Startseite …`. Cookie-Sicherung `saveCookiesToDefaults`/`restoreCookiesFromDefaults` (AppDelegate), aufgerufen von `SceneDelegate`.
- **Formular-Eingabedialog** (`BrowserPageActionCoordinator.m`): Texteingabe und Login in einem Dialog (Benutzername + Passwort), `textContentType` aus `autocomplete` und Feldtyp (`BrowserTextContentType`), Werte über den nativen Setter des Eingabefeldes (React-kompatibel, `Object.getOwnPropertyDescriptor(proto, 'value')`), Absenden nur auf Wunsch über `requestSubmit()`. Test: Selbsttest `fill:` (loggt Titel, Felder, `textContentType`; letzter Wert ist der Index der Aktion).

Test (alle): Selbsttest `guide`, `menu`, `state`; ansonsten manuell mit der Fernbedienung.

### 13.1 Adresseingabe und Diktat (`BrowserAddressInputController`)

**Zweck.** Ein Druck auf die Leiste soll reichen, um loszusprechen: Die Systemtastatur liegt sofort offen und fokussiert unter der Leiste, die Siri-Taste diktiert ohne weiteren Klick, die Aufklapp-Karte mit Favoriten bleibt darunter sichtbar.

**Was tvOS 26/27 erlaubt (Stand 8. November 2026, im Simulator mit tvOS 27 geprüft).**
- Apps bekommen **keinen Zugriff auf das Mikrofon der Siri Remote**. Es gibt kein „Mikrofon an, App hört zu“. Diktieren geht nur über die Systemtastatur: Siri-Taste halten, sprechen, loslassen. Das System setzt dann den ganzen Satz auf einmal ins Feld.
- Ein eigenes `UITextField` mit `becomeFirstResponder` und das Textfeld eines `UIAlertController` öffnen die **Vollbild-Tastatur**, die alles verdeckt. Das war die alte Eingabe.
- Nur die **Systemsuche** (`UISearchController` in `UISearchContainerViewController`) zeigt eine **einzeilige Tastatur im Layout der App**. Der Fokus liegt sofort auf der Tastatur (`UIKeyboard`), und tvOS blendet selbst den Hinweis „zum Diktieren … halten“ ein. Deshalb nutzt die Eingabe diesen Weg.
- Spracheingabe ohne Tastatur gibt es nur über Siri und App Intents (`docs/SIRI_STEUERUNG.md`), also „Hey Siri, …“ statt Siri-Taste in der App.

**Aufbau.** `BrowserAddressInputController` ist ein durchsichtiger Controller (`UIModalPresentationOverFullScreen`, Überblendung, dunkle Darstellung). Er enthält:
- eine Glaskarte (`UIGlassEffect` regulär, sonst Blur dunkel, Radius 40) 14 pt unter der Leiste in Leistenbreite, 190 pt hoch;
- darin den `UISearchContainerViewController`, so breit wie die Leiste. Bei voller Bildschirmbreite würde der Diktat-Hinweis aus der Karte ragen.
- `obscuresBackgroundDuringPresentation = NO`, keine Einstellungen für Tastaturtyp, Großschreibung oder Autokorrektur. Mit diesen Einstellungen wird die Tastatur dreizeilig.
- einen Ergebnis-Controller mit dem Knopf „Los: „…““ (erscheint bei Text, die Karte wächst mit, das Panel rückt über `keyboardAreaHeightHandler` nach) und einem unsichtbaren Fokusfänger darunter.

**Ablauf.**

| Was | Ergebnis |
|:--|:--|
| Druck auf die Leiste (und alle anderen Auslöser, Abschnitt 13) | `beginAddressEditing`: Leiste klappt aus, Panel erscheint mit Platz für die Tastatur, `showAddressKeyboard` präsentiert die Eingabe. Fokus auf der Tastatur, sofort diktierbar |
| Diktat (leeres Feld, auf einen Schlag ≥ 3 Zeichen) | wird nach 1,5 s automatisch bestätigt (Log `[Address] Diktat erkannt: … bestätige in 1,5 s`). Jede weitere Änderung in dieser Zeit (Tippen, Löschen) bricht die automatische Bestätigung ab, dann gilt „Los“. Getippte Zeichen kommen einzeln und lösen nichts aus |
| Tastatur „Suchen“ oder Knopf „Los“ | bestätigen |
| Wischen nach unten aus der Tastatur | Fokus landet auf dem Fokusfänger: Tastatur zu, Karte rückt hoch, Zeiger auf der ersten Kachel (`addressKeyboardDidLeaveToTiles`) |
| Menü | Systemsuche schließt sich, `didDismissSearchController` bzw. `viewDidDisappear` melden „abgebrochen“, der Host schließt Tastatur und Karte in einem Schritt |
| Klick aufs Feld oder Play/Pause bei Kachelmodus | Tastatur wieder auf (`showAddressKeyboard`) |

Bestätigter Text geht über `submitAddressInputText:` an `handleEnteredAddressText:`. Dort wird er wie gehabt ausgewertet: Sprachbefehle („Reader aus“, „zurück“, „suche Wetter“), Adressen („heise punkt de“) und sonst Websuche.

**Gegen Doppel-Dialoge.** `endHandler` wird genau einmal gerufen (`finished`). Der Host prüft, ob der Rückruf noch zur aktuellen Eingabe gehört (`self.addressInput == weakInput`). Eine zweite Eingabe wird nie geöffnet, solange `addressInput` gesetzt ist. Schließt die alte gerade, versucht es der Host 0,15 s später erneut. `endAddressEditingAnimated:` schließt die Eingabe still (`closeSilentlyAnimated:`) vor dem Panel.

**Fragile Stellen.**
- Die Haarlinie, die die Systemsuche über den Ergebnissen zeichnet, wird über die Form erkannt: schlichte `UIView`, höchstens 1,5 pt hoch, breiter als 200 pt, ohne Subviews (`hideSearchSeparator`). Ändert Apple den Aufbau, ist die Linie wieder da (rein optisch).
- Die Höhe der Tastaturkarte (190 pt) ist im Simulator gemessen (Tastaturzeile bei y ≈ 228, Ergebnisbereich ab ≈ 369). Andere tvOS-Versionen können sie verschieben.
- Die Diktat-Erkennung ist eine Heuristik (Sprung von leer auf ≥ 3 Zeichen). Fügt tvOS das Diktat stückweise ein, wird nichts automatisch bestätigt, dann bleibt „Los“.
- Die Menü-Taste schließt die Systemsuche über deren eigenen Gestenerkenner. `didDismissSearchController` und `viewDidDisappear` sind das Sicherheitsnetz.

**Woran man merkt, dass es kaputt ist.**
- Vollbild-Tastatur statt Zeile unter der Leiste: Präsentation oder Container ist kaputt.
- Kein Fokus auf der Tastatur: Log `[Address] Tastatur offen … Fokus=…` zeigt etwas anderes als `UIKeyboard`.
- Die Karte bleibt nach dem Menü stehen: `[Address] Tastatur zu: abgebrochen` fehlt.

**Test.** Selbsttest `address`, `dictate:heise.de`, `dictate:suche Wetter`, `dictate:he` (Knopf „Los“), `addrtiles`, `addrstate`, `selectdup` (Abschnitt 14). Dazu Screenshots. Am Gerät: Siri-Taste in der offenen Tastatur halten und sprechen.

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
Nur **DEBUG**-Builds (`#if DEBUG` in `ViewController.m`, `runPointerSelfTestIfRequested`, aufgerufen aus `viewDidAppear:`). Die Umgebungsvariable `POINTER_SELFTEST` enthält Schritte, getrennt durch `;`. 5 s nach dem Erscheinen werden offene Dialoge geschlossen, dann läuft Schritt *i* nach `i·3 + 1` Sekunden. `POINTER_SELFTEST_INTERVAL=<s>` ändert den Abstand (z. B. `1` für schnelle Stresstests, auch Bruchteile); nach dem letzten Schritt erscheint `[SelfTest] fertig N Schritte`. Danach `viewDidAppear` kommt nach jedem Dialog erneut, der Test startet aber nur einmal (`started`). Ausgabe immer mit Präfix `[SelfTest]`.

| Schritt | Bedeutung | Logzeile / Wirkung |
|:--|:--|:--|
| `x,y` | Zeiger an Punkt setzen (Einrasten greift wie beim Wischen) | `move (x, y) targets=N` |
| `click` | Auswahl-Klick (`browserHandlePrimaryAction`) | `click` |
| `url:<Adresse>` | Adresse laden (Doppelpunkt nach `url` ist Trenner, `;` in der Adresse nicht erlaubt) | `load <URL>` |
| `playpause` | Play/Pause kurz (Video steuern oder Adressdialog) | `playpause overVideo=… playing=…` |
| `left` / `right` | Clickpad links/rechts (Video ±10 s oder Elementsprung) | `left overVideo=…`, danach nach 1,2 s `Zeiger (x, y) scroll=…` |
| `next` / `prev` | Elementsprung direkt (`stepTargetBy:`) | `next cursor=(x, y)` |
| `gestures` | Ring-Erkennung mit künstlichen Bewegungen (`debugRunGestureWithDeltas:`) | `gestures cw1.5=… ccw1=… line=… quarter=…` (Kreise > 0, `line` und `quarter` = 0) |
| `swipe:dx,dy,ms[,flick/clean/flickclean]` | Synthetisches Wischen auf dem Clickpad durch die echte Pipeline (Abschnitt 8.8) | `[PointerTest] wisch …` bzw. `flick …`, dazu `[Pointer] Geste …` |
| `ring:radius,grad,ms` | Kreis im Uhrzeigersinn auf dem Clickpad (Ring über absolute Lage) | `[PointerTest] ring r=… …°: Schritte N` |
| `fill:v1\|v2\|…\|i` | aktuellen Eingabedialog (UIAlertController) ausfüllen; letzter Wert *i* ist der Index der zu drückenden Aktion | `fill alert=<Titel> fields=N types=[textContentType…]`, `tap <Aktion>` |
| `dictate:<Text>` | Adresseingabe öffnen (`beginAddressEditing`, falls nicht offen), nach 1 s Text auf einmal einsetzen wie ein Diktat (`insertDictatedText:`); ab 3 Zeichen nach 1,5 s automatisch bestätigt und ausgewertet | `dictate field=ok text=…`, `[Address] Diktat erkannt …`, `[Address] Tastatur zu: bestätigt` |
| `siri:<befehl>[\|<arg>]` | Befehl wie aus einem App Intent (Notification, dann Router), siehe `docs/SIRI_STEUERUNG.md` | `siri <befehl>`, `[Siri] Befehl …`, `[Command] …` |
| `press:right2`, `press:rightdup`, `press:leftdup` | zweimal rechts (Abstand Haltezeit + 0,12 s) bzw. ein Druck, dessen Beginn und Ende je zweimal mit gleichem Zeitstempel ankommen | `[Keys] … doppelt zugestellt (gleicher Zeitstempel), verworfen` |
| `rightpress`, `rightright[:ms]` | rechts einmal bzw. zweimal im Abstand *ms* (Vorgabe 150) direkt über `handleRightPress` | `rightright zweiter Druck: Zeiger … presented=…` |
| `steporder` | Reihenfolge der Sprungziele (Zeilen) ausgeben | `steporder <Rechtecke in Sprungreihenfolge>` |
| `tabinfo` | Tabs mit `benutzt`, Alter, Titel, Adresse; Ablaufzeit und Einblendung | `tabinfo N Tabs, aktiv i, Ablauf s, Einblendung …` |
| `tab:N`, `closetab` | zu Tab *N* wechseln (zählt als benutzt) bzw. aktiven Tab schließen | `wechsle zu Tab N`, `closetab tabs=N` |
| `tabexpire` | Ablaufprüfung sofort ausführen | `[Tabs] unbenutzten Tab automatisch geschlossen …` |
| `popuppoint`, `popupjump` | Zeiger auf die Pop-up-Einblendung setzen (danach `click`) bzw. direkt zum Pop-up-Tab springen | `popuppoint {{x, y}, {w, h}}`, `[Popup] Sprung zum Hintergrund-Tab N` |
| `cmd:<name>[\|<arg>]` | Befehl direkt über den Router (alle Namen aus `BrowserCommand`, z. B. `cmd:reader\|on`, `cmd:seek\|-10`, `cmd:open\|heise.de`) | `cmd …`, `[Command] <name> arg=… quelle=selbsttest ok\|nicht möglich\|unbekannt („Rückmeldung“)` |
| `parse:<text>[\|<text>…]` | Parser prüfen, ohne auszuführen (mehrere Texte mit `\|`); ohne Parser-Treffer zusätzlich der sinngemäße Abgleich (Abschnitt 19.1) | `parse "<text>" -> reader\|on ("starte den reader")` bzw. `keine -> Suche`/`keine -> Adresse`, dann `parse "<text>" ähnlich: ausführen\|Suche -> <befehl> (Begriffe … Abstand …, Embedding …, unbekannt=…, Beispiel "…", <Grund>)` |
| `enter:<text>` | Text wie aus dem Adressfeld bestätigt (Parser, dann sinngemäßer Abgleich, dann Befehl oder Suche) | `enter …`, `[Command] Diktat "…" -> …` bzw. `[Command] Diktat "…" ähnlich: …` |
| `probe` | JS-Messung: Element `#red`, `scrollY`, `innerHeight/Width`, Treffer bei (20,20), `visualViewport.offsetTop` plus `webFrame`, `contentOffset`, `contentInset` (für Einschub/Versatz; setzt Testseite mit `#red` voraus) | `probe … webFrame=… offset=… inset=…` |
| `label` | Text der Adress-Beschriftung der Leiste | `label <Text>` |
| `views` | Ansichtshierarchie bei (300, 6) (z. B. Streifen hinter der Leiste) | `view <Klasse> frame=… bg=… alpha=…` |
| `anims` | alle Ebenen der Fenster (mit Masken) mit laufenden Core-Animation-Animationen, z. B. um zu prüfen, ob der Glow unsichtbar weiterläuft (Abschnitt 21) oder bei „Glow-Animation“ aus steht (Abschnitt 18) | `anim <View> (<Ebene>) sichtbar=0\|1 keys=… speed=… drehung=…`, `anims N Ebenen mit Animationen (Glow-Animation=0\|1, Bewegung reduzieren=0\|1)` |
| `menu` | Menütaste (`HandleMenuPress`) | `menu handled=0|1` |
| `press:<taste>[@ms]` | Taste wie von der Fernbedienung: `menu`, `playpause`, `playpause2` (doppelt, 120 ms Abstand), `select`, `up`, `down`, `left`, `right`; `@ms` hält sie so lange (Vorgabe 80, lang: `playpause@900`). Geht an das fokussierte Element (sonst den obersten Controller) und läuft die Responder-Kette hoch, also auch durch offene Dialoge, Seitenleiste und Tab-Übersicht. Gestenerkenner (Menü im UIAlertController) und `UIApplication sendEvent:` sehen sie nicht | `press <taste> an <Responder> (oben <Controller>)`, nach 1,2 s `press <taste> danach presented=… tabs=… karte=… adresse=… url=… zurück=… tabzahl=…`; dazu `[Keys] Ende Typ=…` |
| `address` | wie zweimal oben: Bearbeiten-Zustand mit Aufklapp-Bereich und offener Tastatur | `address active=1 tiles=N field=…`, Screenshot |
| `addrtiles` | Fokus wie Wischen nach unten aus der Tastatur auf den Fokusfänger (Tastatur zu, Zeiger auf die Kacheln) | `addrtiles tastatur=1`, `[Address] Tastatur zu: zu den Kacheln` |
| `addrstate` | Zustand der Adresseingabe ausgeben | `addrstate tabs=… kompakt=… karte=… tastatur=… presented=… text="…" fokus=… zeiger=… leisteEdit=…` |
| `selectdup`, `selectdup:alt` | Auswahl-Druck direkt (`handlePressesEnded:`) und 0,3 s später nochmal als `sendEvent:`-Benachrichtigung mit gleichem Zeitstempel (`:alt` ohne Zeitstempel, altes Verhalten); danach `addrstate` | `selectdup direkt`, `[Keys] Auswahl doppelt (sendEvent), verworfen` |
| `dir:up` / `dir:down` / `dir:left` / `dir:right` | Pfeiltaste im Aufklapp-Bereich (`stepTargetInDirection:`) | `dir down cursor=(x, y)` |
| `favorite` | Stern: aktuelle Seite zu den Favoriten (bzw. entfernen) | `favorite <host> = 0|1` |
| `wait` | nichts tun (3 s Pause, z. B. damit eine Seite lädt) | – |
| `guide` | Bedienungsdialog anzeigen | Screenshot |
| `reader` | Reader-Modus umschalten (Knopf der Leiste) | `reader vorher verfügbar=… aktiv=…`, nach 1,5 s `reader nachher …` |
| `clearall` | alle Website-Daten löschen (`resetWebsiteDataWithCompletion:`) | `clearall fertig` |
| `clearsite:<host>` | nur Einträge löschen, deren `displayName` den Host enthält (z. B. gespeicherte Cookie-Einwilligung) | `clearsite <host>: N Einträge gelöscht` |
| `zoom` | Zoom-Zustand (`zoomScale`, `min/max`, `_viewScale`, `contentSize`, `bounds`, `pageZoom`) | `zoom zoomScale=… viewScale=…` |
| `state` | Dialog-/Fenster-/Vollbildzustand | `state presented=… windowRoot=… fs=… keyWindowPresented=…` |
| `js:<Code>` | JavaScript ausführen, Ergebnis loggen. Ausdruck, kein `return` auf oberster Ebene (sonst Syntaxfehler); für Anweisungen `(function(){try{…}catch(e){return 'ERR '+e}})()`, Zeilenumbrüche statt `;` | `js <Ergebnis>` bzw. `js Fehler <Code>: <Text> <Ausnahme>` (4 Ausnahme/Syntax, 5 Ergebnis nicht übertragbar oder Seitenprozess weg, siehe 3.1) |
| `websubs[:opt,…]` | Untertitel in der Webseite fürs aktuelle Video starten (whisper, Sprache aus `autoSubtitlesLanguage`; ohne Modell Platzhalter). Optionen: `en`/`auto` (Sprache für diesen Test), `stub` (Platzhalter-Erkennung), `sp` (ScriptProcessor statt AudioWorklet), `force` (ohne Herkunftsprüfung), `slow` (Stub mit 3 s Abschnitt, 0,5 s Überlappung, 1,2 s Rechenzeit), `status`, `off` | `websubs start …`, `websubs Zustand=… Blöcke=… Abschnitte=… Anzeige-Verzug=… skript={…}`, `websubs aus`; dazu `[WebAudio]`/`[WebSubs]` |
| `pref:<Schlüssel>=<Wert>` | Einstellung in `NSUserDefaults.standardUserDefaults` schreiben (am Gerät gibt es kein `simctl … defaults write`). `YES`/`NO` → Bool, Zahl → Zahl, sonst Zeichenkette, leerer Wert löscht den Schlüssel. Beispiele: `pref:AutoSubtitlesEnabled=YES`, `pref:GlowAnimationEnabled=NO` (Glow steht, wirkt sofort), `pref:MagneticVariant=B` (DEBUG-Varianten der Hervorhebung, 8.3, wirkt sofort), `pref:AutoSubtitlesCPUOnly=YES`, `pref:AutoOpenVideosInNativePlayer=NO`, `pref:AutoSubtitlesLanguage=en`. Wirkt ab dem nächsten Lesen der Einstellung (z. B. beim Öffnen des Players), bleibt nach dem Test gespeichert | `pref <Schlüssel> = <Wert> (<Klasse>)` |
| `speech` | Apples `SpeechTranscriber` (Speech, tvOS 26) prüfen: Verfügbarkeit, Sprachen, Sprachpakete (`BrowserSpeechProbe.swift`, keine Erkennung) | `speech isAvailable=… supported=N installed=[…] en-US->… Paket=…` |
| `wait` (jeder unbekannte Schritt) | nichts tun, 3 s warten | – |
| `video` | Zustand des ersten `<video>` (Zeit, paused, readyState, networkState, Fehler) plus App-Sicht (Rechtecke, `playing`, `idleTimerDisabled`) | `video t=… paused=… … rects=… playing=… idle=…` |
| `fvideo` | alle `<video>` in **allen Frames** (auch fremden iframes, per `_frames:` und `evaluateJavaScript:inFrame:…`), je Frame Host/Pfad, Größe, Zeit, `paused`, `readyState`, Fehler, dazu markierte iframes (7.1) | `fvideo <host/pfad>: 800x450 t=… paused=… ready=… [markiert: 2] \|\| <frame>: …` |
| `pcmd:<Befehl>` | Befehl über die Player-Brücke am Zeiger, `strict` (wie Play/Pause ohne erkanntes Video): `toggle`, `play`, `pause`, `seek:±S`, `seekto:S` | `pcmd toggle -> play\|pause\|click\|frame\|none` |
| `native` | Video der Seite im nativen Player öffnen (wie Menü „Im Player öffnen“, Zeigerposition zählt) | `native hasVideo=…`, danach `[NativeVideoPlayer]`-Zeilen |
| `nplayer` | Zustand des nativen Players (`debugStateLine`) | `nplayer t=… dur=… rate=… status=… live=… hls=… loader=… pipAllowed=… pipSupported=… pip=… legible=N/<Spur> audible=N sidecar=… cues=… meta=… art=… fokus=<Klasse> menüs=[eigene Menüs] oben=<präsentiertes Menü>` oder `kein Player` |
| `hid:<t1>,<t2>,…` | Tasten wie von der Fernbedienung über den echten UIKit-Weg (`_pressesEventForWindow:` + `_prepareButtonEvent:…` mit angehängtem IOHIDEvent → `sendEvent:` → Fokus, im Player also AVKit), 0,7 s Abstand. Tasten `up`, `down`, `left`, `right`, `select`, `menu`, `playpause`, `@ms` hält (Vorgabe 90 ms). Anders als `press:` geht es durch `browser_sendEvent:` und das Fokussystem. Private Methoden, nur DEBUG | `hid <taste>`, dazu `[InputTrace]`-Zeilen |
| `nseek:<S>` | nativen Player auf Sekunde *S* setzen | wie `nplayer` (Zustand davor) |
| `nclose` | nativen Player schließen (Position geht zurück in die Seite) | wie `nplayer`, dann `Sitzung endet t=…`, `Position zurück in die Seite: …` |
| `ai` | Intelligente Funktionen: Anbieter, Embeddings de/en, Systemsprache, abgelehnte Hosts, Sprache und Login der aktuellen Seite (Abschnitt 19) | `ai Anbieter=lokal … de: Satz-Embedding=ja\|nein …`, `ai Seite <host>: Sprache=… -> <Grund> (Hinweis=0\|1)` |
| `summarize` | Seite zusammenfassen (wie Menü „Zusammenfassen“), Karte bleibt offen | `summarize <URL>`, dann `[Reader] text -> …`, `[AI] Satz #…`, `[AI] zusammenfassen: ok …`, `[AI] Karte: …` |
| `translate` | Seite über translate.goog öffnen (wie Sprachbefehl „Übersetzen“) | `translate <URL> -> <Proxy-URL>`, `[AI] übersetzen …` |
| `translate:hint` / `translate:reset` | Kapsel „Übersetzen?“ erzwingen (für Screenshots) / abgelehnte Hosts und Sitzungsliste leeren | `translate:hint <host>` / `translate:reset` |
| `ask:<frage>` | „Frag die Seite“ (Abschnitt 19.2): Stelle suchen, markieren, Karte zeigen | `ask <frage>`, `[Reader] text -> …`, `[AI] Fundstelle #…`, `[AI] frag "…": N Treffer …`, `[AI] markieren: …`, `[AI] Antwort 1/N markiert=0\|1 …` |
| `ask:next` | nächste Fundstelle (wie Play/Pause bei offener Karte) | `[AI] Antwort 2/N …` |
| `mem` | Speicher und Lebenszeit: Footprint der App (`phys_footprint`), Tabs, wie viele WebViews geschlossener Tabs noch leben (schwache Liste, gefüllt von `closetab`), offene DNS-Proxy-Sitzungen, Seitenprozesse des Prozesspools (`_webProcessCount`, ohne vorgewärmte/zwischengespeicherte) | `mem footprint=… MB tabs=N geschlossene WebViews lebend=N [Klassen] Proxy-Sitzungen=N Seitenprozesse=N (ohne vorgewärmte N) presented=… url=…` |
| `memwarn` | Speicherwarnung auslösen (`UIApplication _performMemoryWarning`, sonst nur die Notification) | `memwarn vorher=… MB nachher=… MB` |
| `newtab` / `closetab` | neuen Tab öffnen / aktiven Tab schließen (wie Menü); `closetab` merkt sich die WebView für `mem` | `newtab tabs=N`, `closetab tabs=N` |
| `back` / `forward` | Zurück / Vor über den Router | `back ok=0\|1`, `forward ok=0\|1` |
| `stop` | Laden abbrechen (`stopLoading`) | `stop loading=0\|1 url=…` |
| `procs` | Prozesspool: Zahl der Seitenprozesse und Einstellungen (Back-Forward-Cache, Vorwärmen, Prozesswechsel, `maximumProcessCount`) | `procs pool=<Adresse> webProcessCount=… maximumSuspendedPageCount=… prewarmedProcessCountLimit=… pageCacheEnabled=… usesWebProcessCache=… …` |
| `wkprobe` | wie `procs`, dazu private Methoden der WebKit-Klassen zu Cache, Vorwärmen, Prozessen und Speicher (zum Suchen neuer Stellschrauben) | `wkprobe <Klasse>: <Selektoren>` |

Zeichen `;` und `|` dürfen in `js:`/`url:`/`fill:` nicht vorkommen (Trenner).

Zusätzliche Umgebungsvariable `PERF_STALLS=1` (nur DEBUG, unabhängig vom Selbsttest): Wächter auf dem Hauptthread, loggt Blockaden über 50 ms und alle 10 s eine Summe (Abschnitt 21).

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
# Sprachbefehle: Parser und Aktionen
POINTER_SELFTEST="parse:Reader|Starte den Reader|zurück|suche Wetter|Reader Test Vergleich;url:https://de.wikipedia.org/wiki/Apple_TV;wait;wait;cmd:reader;enter:Reader aus"
# Aufklapp-Bereich der Adresse mit Daten füllen und öffnen
POINTER_SELFTEST="url:https://www.apple.com/de/;wait;favorite;url:https://de.wikipedia.org/;wait;favorite;url:https://www.heise.de/;wait;address;dir:down;dir:right"
# Zusammenfassen und Übersetzen (Abschnitt 19)
POINTER_SELFTEST="translate:reset;url:https://en.wikipedia.org/wiki/Apple_TV_(device);wait;wait;ai;summarize;wait;menu;translate"
# Frag die Seite und sinngemäße Befehle (Abschnitt 19.1, 19.2)
POINTER_SELFTEST="url:https://de.wikipedia.org/wiki/Apple_TV;wait;wait;enter:frag wann wurde das Apple TV 4K vorgestellt;wait;ask:next;wait;enter:lade die Seite nochmal"
```

---

## 15. Logpräfixe

| Präfix | Quelle | Nur DEBUG? |
|:--|:--|:--|
| `[Load] commit/layout/paint/finish +N ms host` | `BrowserWebView logLoadPhase:` | ja |
| `[Load] Fehler <Domäne> <Code> <URL> (<Text>)` | `ViewController webView:didFailLoadWithError:` (vor dem Filter, also auch abgebrochene Ladevorgänge -999) | ja |
| `[DataStore] …` | `BrowserCreatePersistentWebsiteDataStore` | nein |
| `[WebProcess] Seitenprozess beendet (Grund N) <host> -> …` | `BrowserWebView handleWebContentProcessTerminationWithReason:` (3.1) | nein |
| `[AdBlock] …` | `BrowserContentBlocker` | nein |
| `[Scriptlets] geladen/nicht verfügbar` bzw. `[Scriptlets] <host> N Regeln` | `BrowserScriptletInjector` | erste nein, zweite ja |
| `[FilterLists] …` | `BrowserFilterListUpdater` (6.10) | nein |
| `[CookieBlock] …` | `BrowserCookieConsentBlocker handleMessageBody:` und Fehlzeile für das Bundle | ja |
| `[Input] Clickpad über GameController`, `[Pointer] Geste …`, `[PointerTest] …` | `BrowserRemoteInputController` | erste: nein, die anderen: ja |
| `[InputTrace][App]`, `[InputTrace][NativePlayer]` | `UIApplication+BrowserSelectPressForwarding`, `BrowserNativeVideoPlayerViewController` | im Code nicht geprüft |
| `[NativeVideoPlayer]`, `[NativeVideoAssetLoader]`, `[YouTubeExtractor]` | Videoteile | im Code nicht geprüft |
| `[PlayerBridge] Content World eigene\|nicht verfügbar …`, `[PlayerBridge] <Befehl> -> <Ergebnis>`, `[PlayerBridge] Klick (x, y) -> frame\|shadow\|click\|…`, `[PlayerBridge] Skriptfehler: …` | `BrowserClickTargetTracker`, `BrowserWebView` (Abschnitt 7.1) | nein |
| `[Subtitles]`, `[Subtitles][Tap]`, `[Subtitles][HLS]`, `[Subtitles][whisper]` | `BrowserSubtitle*` (Abschnitt 10.9) | nein |
| `[NowPlaying]` | `BrowserNowPlayingController` | im Code nicht geprüft |
| `[DNSProxy]` | `BrowserDNSProxy` (Verbindungs-Summary und `Limit offener Dateien … -> …` nur DEBUG) | gemischt |
| `[TopBar]` | `BrowserTopBarView` | im Code nicht geprüft |
| `[Reader] check/toggle/exit -> a|y|n|e:…`, `[Reader] text -> <Quelle> N Zeichen (Seite M)` | `BrowserReaderMode` | ja |
| `[AI] zusammenfassen: …`, `[AI] Karte: …`, `[AI] Übersetzen-Hinweis <host>: <Grund> …`, `[AI] übersetzen …`, `[AI] Übersetzen abgelehnt für …`, `[AI] kontextuelles Embedding …`, `[AI] frag "…": N Treffer …`, `[AI] markieren: …`, `[AI] Antwort i/N markiert=…` | `BrowserIntelligence`, `BrowserIntelligenceController` | nein (nur `[AI] Satz #…` und `[AI] Fundstelle #…` sind DEBUG) |
| `[WebAudio] Zustand …`, `[WebAudio] Block #N …` | `BrowserWebAudioCapture` | Zustand: nein, Blöcke: ja (`logsBlocks`) |
| `[WebSubs] Start/Stopp/Abschnitt/Anzeige …` | `BrowserWebSubtitleController` | Start/Stopp: nein, Abschnitt/Anzeige: ja |
| `[SelfTest]` | `ViewController` | ja |
| `[Popup] Pop-up/Link im Hintergrund-Tab N geöffnet: <URL> (gleiche Website 0/1)`, `[Popup] nicht geöffnet, schon 5 Tabs`, `[Popup] Einblendung „…“`, `[Popup] Sprung zum Hintergrund-Tab N` | `ViewController`, `BrowserPopupNotice` | nein |
| `[Tabs] Tab benutzt: <URL>`, `[Tabs] unbenutzten Tab automatisch geschlossen nach N s: <URL>` | `BrowserTabCoordinator` | nein |
| `[Keys] links/rechts Beginn`, `[Keys] … Ende nach N ms[, gehalten: kein weiterer Sprung]`, `[Keys] Sprung ±1 (Taste rechts\|Taste links\|Wiederholung\|Ring\|Drehung): Ziel i -> j von n`, `[Keys] Rand …, scrollen`, `[Keys] … doppelt zugestellt (gleicher Zeitstempel), verworfen` | `BrowserRemoteInputController` | Beginn/Ende ja, Sprung und doppelt nein |
| `[Perf] main/didFinishLaunching/viewDidLoad/viewDidAppear/erste Seite … (+N ms seit Prozessstart)`, `[Perf] Cookies …`, `[Perf] WebView angelegt …`, `[Perf] Werbeblocker: N von M Listen bereit`, `[Perf] JS synchron N ms …` (ab 20 ms), `[Perf] BrowserWebView freigegeben`, `[Perf] scene…`, `[Perf] Hauptthread …` (nur mit `PERF_STALLS=1`) | `BrowserPerf.h`, `main.m`, `AppDelegate`, `SceneDelegate`, `ViewController`, `BrowserWebView`, `BrowserContentBlocker` (Abschnitt 21) | ja |
| `[Keys] Ende Typ=… presented=… tabs=…` (jede Taste, die `ViewController pressesEnded:` erreicht), `[Tabs] Play/Pause: Fokus=…` | `ViewController`, `BrowserTabOverviewController` | ja |
| `[Keys] Auswahl doppelt (sendEvent), verworfen`, `[Keys] Auswahl über sendEvent bei offenem Dialog, ignoriert` | `BrowserRemoteInputController handleGlobalSelectPressEndedWithTimestamp:` | ja |
| `[Address] Bearbeiten an/aus`, `[Address] Tastatur offen, Leiste=… Tastatur=… Fokus=…`, `[Address] Diktat erkannt: "…", bestätige in 1,5 s`, `[Address] Suche vom System beendet`, `[Address] Tastatur zu: bestätigt\|zu den Kacheln\|abgebrochen` | `ViewController`, `BrowserAddressInputController` | ja |
| `[Command] <name> arg=… quelle=diktat\|siri\|selbsttest ok\|nicht möglich\|unbekannt`, `[Command] Diktat "…" -> …`, `[Command] Diktat "…" ähnlich: ausführen\|Suche -> …` | `BrowserCommandRouter`, `ViewController handleEnteredAddressText:` | nein |
| `[Siri] Befehl …`, `[Siri] Intent -> Befehl …` | `ViewController`, `BrowserAppIntents.swift` | nein |
| `[Probe]` | `BrowserFeasibilityProbe` | nein (nur bei gesetzter Umgebungsvariable) |
| `[FullscreenHack]` | `WebAVPlayerViewController+FullscreenSubviewHack.m` | Hack aus |

---

## 16. Offen/unklar

- Zweck des `_privacyStance`-Shims ist im Code nicht kommentiert; Commit-Historie nennt nur „WIP adding hack for supporting full screen video“. Vor Entfernen mit Konsole testen.
- `BrowserWKWebViewProofOfConceptViewController` scheint ungenutzt (nur Suche nach Verweisen im Code, kein Laufzeitnachweis).
- Für das autoconsent-Bundle gibt es kein Update-Skript; der Ablauf in 5.8 ist aus `THIRD_PARTY_NOTICES.md` abgeleitet. Eine feste Liste von Testseiten für Cookie-Banner existiert nicht im Repo (PLAN.md nennt das Durchtesten als offen).
- Scriptlets/erweiterte Regeln: am Gerät noch nicht geprüft, ob YouTube-Werbung wirklich wegfällt und das Video danach normal läuft (im Simulator spielt YouTube grundsätzlich nicht ab). uBOs `trusted-edit-inbound-object`-Regeln für YouTube fehlen (kein AdGuard-Gegenstück).
- Abstimmung von Zeigerempfindlichkeit, Randscrollen, Ring und Play/Pause-Zeiten mit echter Fernbedienung ist laut PLAN.md nicht abgeschlossen.
- Test `https://1.1.1.1/help` und Langzeittests des DNS-Proxys nach Hintergrund sind laut PLAN.md offen.
- Ob `[InputTrace]`, `[NowPlaying]`, `[TopBar]` und die Video-Logzeilen nur in DEBUG erscheinen, wurde nicht für jede Zeile geprüft.
- Genaue Pfade des gebauten `.app` (DerivedData) hängen vom gewählten `-derivedDataPath` ab.

---

## 17. App-Icon und Top Shelf

Das Icon (Liquid-Glass-Stil: Glasscheibe mit Kompassnadel und Umlaufbahn vor einem Verlauf in den Glow-Farben der App) wird vollständig von `tools/make_app_icon.swift` gezeichnet (Core Graphics, Core Image für Weichzeichnen und Linsenbrechung). Die PNGs im Katalog nie von Hand bearbeiten, sondern das Skript ändern und neu laufen lassen.

```sh
swift tools/make_app_icon.swift                    # Standardvariante „nadel“ in den Katalog, Vorschauen nach docs/icon/
swift tools/make_app_icon.swift --variant globus   # Alternative „globus“ in den Katalog schreiben
swift tools/make_app_icon.swift --preview-only     # nur docs/icon/ neu erzeugen
```

- Ziel: `_Project/Browser/Assets.xcassets/App Icon & Top Shelf Image.brandassets/`. Das Skript schreibt die Bildstapel `App Icon - Small` (400×240 und 800×480 @2x) und `App Icon - Large` (1280×768, App Store) mit je drei Ebenen (`Back` Verlauf, `Middle` Glasscheibe, `Front` Symbol) sowie `Top Shelf Image` (1920×720/3840×1440) und `Top Shelf Image Wide` (2320×720/4640×1440) – ohne Schriftzug, Emblem mittig (seit 8. November 2026; der App-Name steht ohnehin unter dem Icon) samt `Contents.json` neu.
- Vorschau: `docs/icon/preview.png` (Variante im Katalog: Icon groß, Fokus-Simulation, Ebenen einzeln, Top Shelf), `docs/icon/variante-<name>.png` für die jeweils andere Variante, `docs/icon/simulator-home.png` Home-Bildschirm im Simulator.
- Die Ausgabe ist reproduzierbar (Software-Renderer von Core Image, keine Zufallswerte): zweimal laufen lassen ergibt dieselben Bytes.
- Icon Composer (`.icon`) unterstützt laut Apple nur iOS, iPadOS, macOS und watchOS; tvOS braucht weiter den Bildstapel im Asset-Katalog. Den Glas-Effekt backt das Skript deshalb selbst in die Ebenen; Parallax und Glanz beim Fokussieren macht tvOS.
- Prüfen: `xcodebuild … build` darf beim Schritt `CompileAssetCatalog` keine Warnungen zeigen; streng geht es mit `xcrun actool --compile <tmp> --platform appletvos --target-device tv --minimum-deployment-target 17.0 --app-icon "App Icon & Top Shelf Image" --output-partial-info-plist <tmp>/info.plist --warnings --notices _Project/Browser/Assets.xcassets`.
## 18. Animationen (`BrowserMotion`)

**Zweck.** Eine Stelle für alle Oberflächen-Animationen. Zwei Stile, umschaltbar unter •••, „Ansicht & Wiedergabe“, „Liquid-Glass-Animationen“ (`liquidGlassAnimationsMenuItem`, Einstellung `BrowserPreferencesStore.liquidGlassAnimationsEnabled`, Schlüssel `LiquidGlassAnimationsEnabled`, Standard an). Bei der Systemeinstellung „Bewegung reduzieren“ (`UIAccessibilityIsReduceMotionEnabled`) und im alten Design (Abschnitt 23) gilt immer der schlichte Stil.

**Glow-Animation.** Eigener Schalter „Glow-Animation“ in derselben Gruppe (`glowAnimationMenuItem`, `BrowserPreferencesStore.glowAnimationEnabled`, Schlüssel `GlowAnimationEnabled`, Standard an). `BrowserMotion.glowAnimationEnabled` ist NO, wenn der Schalter aus ist oder „Bewegung reduzieren“ an ist (gleiche Regel wie `liquidGlassEnabled`). Dann ist der Regenbogen-Glow ein stehender Verlauf: gleiche Farben, Drehung 0 (Blau oben), Lichthof mit fester Deckkraft 0,85 statt Atmen 0,6–0,95 (`BrowserGlowView motionEnabled`, Animationen `spin`/`breathe` entfernt). `BrowserRemoteInputController` stellt beide Hervorhebungen sofort um (`UIAccessibilityReduceMotionStatusDidChangeNotification`, `NSUserDefaultsDidChangeNotification`) und liest den Wert bei jedem Einrasten. Der einfarbige Glow (Regenbogen-Leuchten aus) war schon unbewegt. Geprüft im Simulator (apple.com, Knopf „Weitere Infos“): aus → `anims` ohne Glow-Ebenen, zwei Screenshots im Abstand von 2 s im Ausschnitt pixelgleich (Abweichung 0); an → `spin`/`breathe` laufen, dieselben Screenshots weichen ab (17 % der Pixel); Bild `docs/magnetic-varianten/glow-stehend.png`. „Bewegung reduzieren“ im Simulator: `xcrun simctl spawn <udid> defaults write com.apple.Accessibility ReduceMotionEnabled -bool YES`, dann App starten; `anims` meldet `Glow-Animation=0, Bewegung reduzieren=1`, Glow steht (pixelgleich).

**Dateien.** `_Project/Browser/BrowserMotion.h/.m`.

**Arten und Werte** (`BrowserMotionKind`, abstimmbar in `BrowserMotionLiquidParameters`/`BrowserMotionPlainParameters`):

| Art | Liquid Glass (Feder: Dauer/Bounce, Einschwingzeit) | Schlicht |
|:--|:--|:--|
| `Standard` (Leiste kompakt ↔ voll, Bearbeiten) | 0,42 s / 0,14 (0,61 s) | 0,25 s easeInOut |
| `Appear` (Karte, Seitenleiste, Dialog) | 0,48 s / 0,18 (0,73 s) | 0,22 s easeOut |
| `Disappear` | 0,32 s / 0 (0,50 s) | 0,20 s easeIn |
| `Snap` (Einrast-Hervorhebung, Reader-Hervorhebung) | 0,20 s / 0,10 (0,28 s) | 0,12 s easeOut |
| `Fade` (Ladelinie, Inhalte) | 0,30 s / 0 (0,50 s) | 0,20 s easeInOut |

**Bausteine.**
- `animateKind:delay:options:animations:completion:` – Liquid Glass über `+[UIView animateWithSpringDuration:bounce:initialSpringVelocity:…]` (tvOS 17+), schlicht über `animateWithDuration:` mit Kurve. Kurvenbits des Aufrufers werden verworfen.
- `animateShadowPathOfLayer:fromPath:kind:` – Schattenumriss mit derselben Feder (`CASpringAnimation initWithPerceptualDuration:bounce:`, `duration = settlingDuration`) bzw. Kurve. Startet bei laufender Animation vom sichtbaren Umriss (Präsentationsebene). Mit `MOTION_LOG` geprüft: Position, Größe, Eckenradius und Schattenumriss laufen mit identischer Feder (Masse 1, Steife 223,8, Dämpfung 25,7, 0,614 s).
- `glassAppear:` / `glassDisappear:` – Liquid Glass: `effect` nil → Glas bzw. Glas → nil im Animationsblock (Materialisieren/Dematerialisieren, Apple: „effect statt alpha“); schlicht: Alpha.
- `presentCard:glassEffect:` / `dismissCard:` – Dialogkarten (in `viewWillAppear:`/`viewWillDisappear:`, parallel zur Überblendung): Liquid Glass materialisiert und federt aus 0,94; schlicht nichts zusätzlich. Der Effekt wird beim Ausblenden gemerkt (assoziiertes Objekt) und beim erneuten Erscheinen wieder gesetzt.

**Aufrufer.** Leiste (`BrowserTopBarView`: `animateChromeLayoutAlongside:` für `setCompact:animated:` und `setAddressEditing:animated:` inklusive Schattenumriss; Ladelinie; Reader-Knopf und blaue Hervorhebung, die mit Liquid Glass aus 0,82 auffedert; `URLLabel.contentMode = Center`, damit der Seitenname beim Breitenwechsel nicht abgeschnitten oder gestreckt wird), Aufklapp-Karte (`BrowserAddressPanelView present…/dismiss…`), Seitenleiste (`BrowserAdvancedMenuViewController viewDidAppear:`/`dismissMenuWithCompletion:`), Bedienungsdialog (`BrowserGuideViewController`), Tab-Übersicht (`BrowserTabOverviewViewController`), Einrast-Hervorhebung (`BrowserRemoteInputController showHighlightForTarget:animated:`, nur das Aufploppen am Ziel, kein Gleiten mehr zwischen Zielen, Abschnitt 8.3). Bewusst nicht umgestellt: Seitenscrollen (`scrollPageReturningDeltaByFraction:`, Bounce wäre beim Lesen störend), Zeigerbewegung und -alpha, Überblendung alte/neue Seite (`BrowserWebView endPageTransitionAnimated:`), Seitenfarbe, Favicon-Überblendung, Fokus-Animationen (laufen über den `UIFocusAnimationCoordinator` des Systems), `BrowserGlowView`.

**Was tvOS 26/27 bietet (SDK 27.2 geprüft).** `UIGlassEffect` (`interactive`, `tintColor`, Stil regular/clear) und `UIGlassContainerEffect` (`spacing`) sind `API_AVAILABLE(ios(26.0))` ohne tvOS-Ausschluss, also ab tvOS 26 vorhanden. Ebenfalls ab tvOS 26: `UIScrollEdgeEffect`/`topEdgeEffect`, `UIScrollEdgeElementContainerInteraction` (nutzt die Leiste schon), `UIBackgroundExtensionView`, `UICornerConfiguration`, `UIViewAnimationOptionFlushUpdates`, Glas-Knopfkonfigurationen (`glassButtonConfiguration` u. a.). Federn mit Dauer/Bounce (`animateWithSpringDuration:bounce:…`, `UISpringTimingParameters initWithDuration:bounce:`, `CASpringAnimation initWithPerceptualDuration:bounce:`) ab tvOS 17. `UIFocusEffect`/`UIFocusHaloEffect` sind auf tvOS **nicht** verfügbar. Quellen: WWDC25 „Meet Liquid Glass“ (219), „Build a UIKit app with the new design“ (284), WWDC23 „Animate with springs“ (10158), HIG Materials und Motion.

**Grenzen.** Echtes Verschmelzen von Leiste und Karte per `UIGlassContainerEffect` bräuchte beide Glasflächen im selben `contentView`; die Leiste (`BrowserTopBarView` ist selbst ein `UIVisualEffectView`) und die Karte liegen in getrennten Hierarchien. Deshalb wächst die Karte als Kapsel aus der unteren Leistenhälfte heraus. Ist eine Hervorhebung ausgeblendet (Alpha 0, nach dem Lösen, Zielwechsel oder Leerlauf-Ausblendung), sind Drehung und Atmen ihres Glows entfernt (`BrowserGlowView animationsPaused`); beim Einblenden laufen sie im gemeinsamen Takt weiter (Abschnitt 21).

**Test.** Simulator, eigenes Gerät: `defaults write io.github.tvosbrowser.app LiquidGlassAnimationsEnabled -bool NO|YES` (per `xcrun simctl spawn <udid> …`), dann `SIMCTL_CHILD_MOTION_LOG=1` und `SIMCTL_CHILD_POINTER_SELFTEST="url:https://de.wikipedia.org/wiki/Apple_TV;wait;js:window.scrollTo(0,1500);js:window.scrollTo(0,0);address;menu;advmenu;menu;guide;menu"` mit `xcrun simctl launch --console-pty`. DEBUG-Logzeilen `[Motion] kind=… liquid=0|1 dauer=…` und `[Motion] Ebene <Schlüssel>: Feder …`. Glätte: `xcrun simctl io <udid> recordVideo`, Einzelbilder per AVFoundation auswerten (Bildabstände, eingefrorene Bilder, Kontaktabzüge).

---

## 19. Intelligente Funktionen (`BrowserIntelligence`)

**Zweck.** Punkte aus `PLAN.md` Phase 6: Artikel zusammenfassen (lokal, extraktiv) und Seiten übersetzen (Google-Übersetzungs-Proxy), dazu ein Hinweis „Übersetzen?“ bei fremdsprachigen Seiten; Sprachbefehle sinngemäß erkennen (19.1) und „Frag die Seite“ (19.2). Hintergrund: Apples Sprachmodell, Translation und Writing Tools sind auf tvOS 27.2 für Apps gesperrt, `NaturalLanguage` ist verfügbar (`docs/APPLE_INTELLIGENCE.md`). Modelle lesen hier nur und schlagen vor; sie klicken nie und senden nichts ab.

**Dateien.**
- `_Project/Browser/BrowserAIProvider.h`: Protokoll `BrowserAIProvider` (`providerName`, `available`, `dominantLanguageForText:confidence:`, `summarizeText:title:maxSentences:completion:`, `diagnosticsDescription`) und Ergebnis `BrowserAISummary` (Sätze, Sprache, Verfahren, Dauer, Kandidaten). Spätere Anbieter (Mac im Heimnetz, Cloud, `SystemLanguageModel`) kommen hinter dieselbe Schnittstelle.
- `_Project/Browser/BrowserIntelligence.h/.m`: Fassade `BrowserIntelligence` (`sharedIntelligence`, Textabruf und Zusammenfassen, Sprachprüfung der Seite, Proxy-Adresse, abgelehnte Hosts) und darin der Anbieter `BrowserNLProvider` (NaturalLanguage, eigene serielle Queue). Rein Foundation.
- `_Project/Browser/BrowserIntelligenceController.h/.m`: Oberfläche. `BrowserSummaryCardView` (Glas-Karte), `BrowserTranslateHintView` (Glas-Kapsel), Tasten, Seitenereignisse, Selbsttest.
- Text: `BrowserReaderMode textForWebView:` und `reader.js` `text(max)` (Abschnitt 9.1).
- Anschlüsse (additiv): `ViewController.m` (Eigenschaft `intelligenceController`, Selbsttest-Weiche, Menütaste, Play/Pause, `webViewDidStartLoad`/`DidFinishLoad`, Tabwechsel, Host-Methoden), `BrowserMenuCoordinator` (`intelligenceMenuItems` oben in „Diese Seite“, optionale Host-Methoden `browserSummarizePage`/`browserTranslatePage`), `BrowserCommand.m` (Befehle `summarize`, `translate`), `BrowserCommandRouter` (optionale Host-Methoden `browserCommandSummarize`/`browserCommandTranslate`).

**Zusammenfassen: Ablauf.**
1. Auslöser: Menü •••, „Diese Seite“, „Zusammenfassen“; Sprachbefehl („Zusammenfassen“, „Fasse (die Seite) zusammen“, „Worum geht es“, „summarize (this page)“, „summary“); Selbsttest `summarize`. Die Karte erscheint sofort mit „Wird zusammengefasst …“.
2. Text: `textForWebView:` (Readability, 6.000 Zeichen, etwa 1.500 Tokens). Unter 200 Zeichen: Rückmeldung „Zu wenig Text zum Zusammenfassen“, Karte zu.
3. Anbieter (Hintergrund-Queue): Sprache (`NLLanguageRecognizer`), Sätze (`NLTokenizer`, danach deutsche Ordnungszahlen und Abkürzungen wie „am 13. September“, „z. B.“, „Nr.“ wieder zusammenfügen), Inhaltswörter als Lemma (`NLTagger`, Nomen/Verben/Adjektive). Kandidaten: 40 bis 420 Zeichen, mindestens 6 Wörter, Satzzeichen am Ende, überwiegend Buchstaben, keine Seitenbausteine (Folgen, Abo, Newsletter …).
4. Bewertung je Satz (jeweils auf 0…1 normiert): **Zentralität** = Kosinus zum Mittelwert aller Satzvektoren (`NLEmbedding sentenceEmbeddingForLanguage:`; fehlt es, ersatzweise `NLContextualEmbedding` mit gemittelten Token-Vektoren, sofern die Modelldaten auf dem Gerät liegen), **TF-IDF-Zentroid** = Summe aus Häufigkeit im Text mal IDF der Begriffe (nur Begriffe, die mindestens zweimal vorkommen), geteilt durch Begriffszahl hoch 0,75, **Position** = 1/(1 + i/4) plus Bonus für Absatzanfänge. Gewichte 0,40/0,38/0,22 (ohne Embedding 0,68 TF-IDF/0,32 Position), Abschlag für sehr kurze Sätze, erster Satz +0,2.
5. Auswahl: 4 Sätze (unter 14 Satzzeichen im Text), 5 (unter 30) oder 6; MMR gegen Wiederholung (Ähnlichkeit = Maximum aus 2 × Jaccard der Begriffe und Kosinus oberhalb des Durchschnitts); Sätze unter 30 % des besten Werts fallen weg, wenn noch 3 übrig bleiben; Ausgabe in Originalreihenfolge.
6. Karte: Titel und Host, Sätze als Liste in New York (Reader-Schrift, 32 pt, bei Bedarf bis 24 pt verkleinert, bis alles passt), Fußzeile „Lokal auf dem Apple TV · N von M Sätzen · Sprache · Dauer · Zurück-Taste schließt“. Menütaste schließt (auch während der Berechnung, das Ergebnis wird dann verworfen), ebenso Klick und Play/Pause (die Karte wirkt wie ein Dialog: kein Klick auf die verdeckte Seite, kein Video dahinter, Pfeile und Zeiger ruhen); neue Seite und Tabwechsel schließen ebenfalls.

**Glas und Bewegung.** Karte und Kapsel sind `UIVisualEffectView` mit `UIGlassEffect` (Rückfall Dunkel-Blur), dunkle Tönung 0,42 bzw. 0,38, Rand 1 pt weiß 16 %, `cornerCurve` kontinuierlich, Karte 56 pt Radius, Kapsel halbe Höhe. Auf- und Abbau über `BrowserMotion glassAppear:`/`glassDisappear:` (Liquid Glass: Glas materialisiert, Karte federt aus 0,94, Kapsel aus 0,9; schlicht: Alpha). Wechsel Laden → Ergebnis: Inhalt sofort an die Endposition, Glasfläche federt mit `BrowserMotionKindStandard` auf die neue Höhe, Inhalt blendet mit `Fade` ein.

**Übersetzen.** Adresse `https://<host>.translate.goog/<pfad>?<query>&_x_tr_sl=auto&_x_tr_tl=<sys>&_x_tr_hl=<sys>&_x_tr_pto=wapp` (Host: Bindestriche verdoppeln, Punkte zu Bindestrichen; bei `http` zusätzlich `_x_tr_sch=http`; keine IP-Adressen). Zielsprache ist die Systemsprache (`NSLocale.preferredLanguages`, Rückfall `de`). Auslöser: Menü „Übersetzen“, Sprachbefehl („Übersetzen“, „Übersetze (die Seite)“, „auf Deutsch übersetzen“, „translate (this page)“), Kapsel, Selbsttest `translate`. Bei Menü und Sprachbefehl wird vorher die Sprache geprüft: Seiten in der Systemsprache werden nicht übersetzt („Seite ist schon auf Deutsch“); auf translate.goog selbst „Seite ist schon übersetzt“.

**Übersetzung beenden.** Läuft die Seite über translate.goog, zeigt die Seitenleiste unter „Diese Seite“ statt „Übersetzen“ den Eintrag **„Übersetzung beenden“** (Detail „Original“, Symbol `character.book.closed`); Sprachbefehl „Übersetzung beenden“, „Original (anzeigen)“, „ohne Übersetzung“, „show original“; Selbsttest `cmd:original`. `+[BrowserIntelligence originalURLForTranslationProxyURL:]` kehrt das Host-Schema um („--“ → „-“, „-“ → „.“), entfernt alle `_x_tr_`-Parameter und nimmt `_x_tr_sch` als Schema; `-[BrowserIntelligenceController showOriginalOfCurrentPage]` lädt die Adresse (Log `[AI] Übersetzung beenden <proxy> -> <original>`). Vorher ging das nur mit Zurück, und Links auf der übersetzten Seite blieben übersetzt.

**Apples Übersetzung statt Google?** Geprüft im SDK AppleTVOS 27.2: `Translation.framework` ist vorhanden, aber `TranslationSession` und `LanguageAvailability` sind `@available(tvOS, unavailable)`; die Safari-Übersetzung ist keine öffentliche WebKit-API. Auf tvOS bleibt deshalb der Weg über translate.goog.

**Hinweis „Übersetzen?“.** 1,5 s nach `webViewDidFinishLoad` (nur aktiver Tab, Adresse unverändert, nicht mehr ladend) liefert ein kleines Skript: Passwortfeld, Anmelde-Adresse (`login`, `signin`, `anmelden`, `oauth`, `sso` …), `lang`-Attribut und 2.500 Zeichen Text aus `article`/`main`/`body`. Die Kapsel erscheint nur, wenn: kein Proxy, Host nicht abgelehnt, kein Login, mindestens 200 Zeichen, Sprache sicher (≥ 0,65) und ungleich der Systemsprache; pro Host höchstens einmal je App-Sitzung. Play/Pause übersetzt, die Zurück-Taste lehnt für den Host dauerhaft ab (`NSUserDefaults` `TranslateDeclinedHosts`, Rückmeldung „Für <host> nicht mehr fragen“), nach 10 s blendet sie ohne Ablehnung aus. Logzeile immer: `[AI] Übersetzen-Hinweis <host>: <Grund> (Sprache=… lang=… Text=… Login=…)`.

**Messwerte (Simulator „AI-Test“, Apple TV 4K 3. Gen., tvOS 27.2, auf dem Mac, 8. November 2026).**

| Seite | Text (Zeichen) | Sätze | Verfahren | Textabruf | Rechnen |
|:--|:--|:--|:--|:--|:--|
| de.wikipedia.org/wiki/Apple_TV | 6.000 von 18.620 | 6 von 41 | TF-IDF (kein deutsches Satz-Embedding) | 16–23 ms | 9–85 ms |
| heise.de-Meldung (TU Dresden, Reaktor) | 2.321 | 5 von 15 | TF-IDF | 19 ms | 67 ms |
| en.wikipedia.org/wiki/Apple_TV_(device) | 6.000 von 47.845 | 6 von 46 | Satz-Embedding + TF-IDF | 50 ms | 518 ms (erster Aufruf, lädt das Embedding) |
| theverge.com, Hands-on (Halskette) | 6.000 von 7.644 | 6 von 47 | Satz-Embedding + TF-IDF | 14 ms | 479 ms |
| theverge.com, Kurzmeldung (Apple, Steuern) | 508 | 3 von 3 (Baustein „Follow topics …“ gefiltert) | Satz-Embedding + TF-IDF | 10 ms | 221 ms |

Embeddings im Simulator (Schritt `ai`): Englisch Satz-Embedding ja (dim 512) und Wort-Embedding ja (dim 300); Deutsch weder Satz- noch Wort-Embedding; `NLContextualEmbedding` für beide vorhanden (dim 512), aber ohne Modelldaten („Download nötig“), eine Anforderung kam im Test nicht zurück. **Am Apple TV messen** bleibt offen (Embeddings de/en, Dauer, Speicher).

**Bewertung.** Lexika und Nachrichten (Wikipedia, heise): brauchbar bis gut; Definition, Kernaussage und zwei, drei Fakten stehen in der Karte, auf Deutsch auch ohne Embedding, weil Meldungen die Kernaussage vorne haben. Erzählende Texte (Hands-on, Kolumnen): schwach, die Sätze stehen ohne Zusammenhang da, die eigentliche Wertung fehlt oft. Lange Artikel werden nur über die ersten 6.000 Zeichen zusammengefasst. Die Zusammenfassung wird nicht übersetzt (englische Seite → englische Sätze). Screenshots: `docs/ai-screens/`.

**Grenzen und Fallen.**
- Deutsch hat im Simulator kein Satz-Embedding; dann nur TF-IDF und Position. Ob das Gerät eines hat oder die kontextuellen Modelldaten lädt, ist offen.
- translate.goog: Google sieht die Seite; Logins und Cookies der Originalseite gelten dort nicht (deshalb kein Hinweis auf Login-Seiten). Manche Seiten sperren den Proxy (heise.de leitet auf `tollbit-heise-de.translate.goog` um, eine Bot-Bezahlschranke). Google übersetzt nachladend; eine übersetzte Seite zusammenzufassen liefert gemischte Sprachen.
- Readability liefert bei Teaser- und Abo-Seiten nur den sichtbaren Teil (Kolumne auf theverge.com: 1.643 Zeichen).
- Solange die Kapsel sichtbar ist (10 s), gehört Play/Pause ihr, auch wenn der Zeiger auf einem Video steht.

**Woran man merkt, dass es kaputt ist.** `[Reader] text -> (null)` bzw. `e:…`: Reader-Skripte fehlen oder die Seite blockiert Skripte. `[AI] zusammenfassen: fehlgeschlagen … Kandidaten=0`: Text zu kurz oder Satzfilter zu streng (Sätze ohne Satzzeichen am Ende zählen nicht). Kapsel erscheint nie: Grund in `[AI] Übersetzen-Hinweis …`; `abgelehnt` mit `translate:reset` zurücksetzen. Proxy-Seite leer oder Fehlerseite: Google hat das Adressschema geändert, `translationProxyURLForURL:targetLanguage:` prüfen.

**Test.** Eigener Simulator, Build mit `-derivedDataPath ../build-sim-ai`, Start mit `-AppleLanguages "(de)" -AppleLocale de_DE` (sonst ist die Systemsprache Englisch und der Hinweis erscheint auf deutschen Seiten):
```
SIMCTL_CHILD_POINTER_SELFTEST='url:https://de.wikipedia.org/wiki/Apple_TV;wait;wait;ai;summarize'
# Hinweis annehmen
SIMCTL_CHILD_POINTER_SELFTEST='translate:reset;url:https://en.wikipedia.org/wiki/Apple_TV_(device);wait;wait;playpause'
SIMCTL_CHILD_POINTER_SELFTEST='parse:Fasse zusammen|summarize this page|Übersetze die Seite;url:https://www.heise.de/;wait;enter:Fasse zusammen'
```
Screenshots mit `xcrun simctl io <UDID> screenshot …` (nie `booted`, wenn mehrere Simulatoren laufen).

**Aktualisieren.** Gewichte und Schwellen stehen in `summarySyncForText:` (Kommentare 4a bis 5), Satzlängen und Bausteinfilter in `BrowserNLSentenceLooksUsable`, Abkürzungen in `BrowserNLShouldJoinSentences`, Befehlsphrasen in `BrowserCommand.m`. Neuer Anbieter: Klasse mit `BrowserAIProvider`, in `+[BrowserIntelligence sharedIntelligence]` wählen.

### 19.1 Sprachbefehle sinngemäß erkennen (Diktat-Abgleich)

**Zweck.** Diktat und Adressfeld: Findet `BrowserCommandParser` nichts, prüft `BrowserIntelligence matchCommandForText:completion:`, ob der Satz sinngemäß einer Phrase aus der Befehlstabelle entspricht („geh eine Seite zurück“, „lade die Seite nochmal“, „zeig mir alle Tabs“). Ausgeführt wird nur über einer vorsichtigen Schwelle, alles andere bleibt Suche. Suchbegriffe wie „Reader Test Vergleich“, „zurück zur Zukunft“ oder „Tabs vs Spaces“ dürfen nie Befehle werden.

**Ablauf.** `ViewController handleEnteredAddressText:` → Parser. Kein Treffer und keine Adresse → asynchron `matchCommandForText:` → bei `accepted` `BrowserCommandRouter performCommandNamed:argument:source:feedbackNote:` mit dem Zusatz „sinngemäß erkannt“ in der Rückmeldung („Neu laden · sinngemäß erkannt“, Screenshot `docs/ai-screens/befehl-sinngemaess.png`), sonst `openAddressOrSearch:` wie bisher. Der Index wird beim ersten Aufruf einmal aufgebaut; das Satz-Embedding wird nur gefragt, wenn es für die erkannte Sprache eines gibt (im Simulator nur Englisch), und auch dann nur fürs Log, solange unbekannte Wörter im Satz sind.

**Verfahren.**
- Vergleichsmenge: die Phrasen der Befehlstabelle je Befehl und Argument. Die Begriffe laufen gegen alle ausgeschriebenen Phrasen, das Satz-Embedding gegen `BrowserCommand.examplePhrases` (jede Alternative eines Musters einmal, `BrowserCommandExpandPatternLinear`, kein Kreuzprodukt). Befehle, die nur über ein Präfix mit freiem Text laufen (Suche, Adresse, Frag die Seite), nehmen nicht teil.
- Wörter: klein, Umlaute behalten, Stoppwörter (de/en Funktionswörter, „bitte“, „mal“, „kannst du“, „mir“ …) raus, leichter Stammformer (`BrowserCommandStem`, Endungen -en/-e/-s/-er/-ing/-ed …). `NLTagger`-Lemma gibt es im tvOS-Simulator weder für de noch en, deshalb kein Lemma. Synonyme vorher: „nochmal/nochmals/erneut“ → „neu“.
- Begriffsvektor je Befehlsklasse (Name|Argument), IDF über Klassen (`log(1 + C/df)`), Wörter, die in keiner Phrase vorkommen, bekommen das höchste Gewicht und zählen als **unbekannt**. Ähnlichkeit = IDF-gewichteter Kosinus zur besten Phrase der Klasse, Abstand = Differenz zur besten anderen Klasse.
- Satz-Embedding (`NLEmbedding sentenceEmbeddingForLanguage:`, Sprache per `NLLanguageRecognizer` auf de/en beschränkt) nur als **Bestätigung**: allein ist es zu ungenau (Simulator: „neuer Tab Chrome“ 0,86 zu „new tab“, „scroll ganz nach unten“ landete auf „top“).

**Regeln (`BrowserIntelligence.m`, Konstanten `kCommand…`).**

| Bedingung | Ergebnis |
|:--|:--|
| Adresse, unter 2 oder über 10 Wörter | kommt nicht in Frage → Suche |
| ein unbekanntes Wort | Suche („unbekannte Wörter“) – schützt alle Suchbegriffe mit Eigennamen oder Themen |
| Begriffe ≥ 0,80 und Abstand ≥ 0,12 | ausführen („Begriffe“) |
| Begriffe ≥ 0,62, Abstand ≥ 0,12 und Satz-Embedding wählt denselben Befehl mit ≥ 0,75 und Abstand ≥ 0,05 | ausführen („Begriffe + Embedding en“) |
| bis 0,12 unter der Schwelle | Suche („knapp darunter“), nur Log |
| sonst | Suche („zu unähnlich“) |

Auf Deutsch gibt es im Simulator kein Satz-Embedding, dort entscheidet nur die erste Regel (Log: „kein Satz-Embedding (de)“).

**Ergebnisse (`parse:`-Selbsttest, Simulator „Ask-Test“).** Alle Regressionsfälle bleiben Suche: „Reader Test Vergleich“, „Reader Test“, „zurück zur Zukunft“, „Tabs vs Spaces“, „neuer Tab Chrome“, „Hilfe bei Steuern“, „Lesemodus Safari“, „vor 10 Jahren“, „Pause Musik“, „Geh zu Wikipedia“, „open source software“, „Wetter Berlin“, „back to the future“, „help with taxes“, „new tab chrome“, „bring mich zur Startseite“, „Frage der Woche“, „ask jeeves“ (jeweils „unbekannte Wörter“); „Tab“ und „heise.de“ kommen gar nicht in Frage. Neu erkannt:

| Satz | Befehl | Werte |
|:--|:--|:--|
| geh eine Seite zurück | `back` | Begriffe 0,94, Abstand 0,47 |
| lade die Seite nochmal | `reload` | 1,00 / 0,54 |
| kannst du die Seite neu laden | `reload` | 1,00 / 0,54 |
| zeig mir alle Tabs | `tabs` | 1,00 / 0,55 |
| scroll ganz nach unten | `down` | 0,81 / 0,23 |
| please reload this page | `reload` | 1,00 / 0,85, Embedding 0,83 |
| go back to the previous page | `back` | 0,76 / 0,44 + Embedding en 0,76 |
| mach den Lesemodus an | `reader\|on` | schon über den Parser |

**Grenzen.** Ein einziges fremdes Wort macht jeden Satz zur Suche, auch harmlose Füllwörter, die nicht in der Stoppliste stehen („bring mich zur Startseite“ bleibt Suche, weil „bring“ unbekannt ist). Das ist gewollt vorsichtig. Neue Formulierungen kommen am besten als Präfix in `BrowserCommand.m` dazu; sie erweitern automatisch die Beispielphrasen.

### 19.2 „Frag die Seite“

**Zweck.** „frag wann wurde das Apple TV 4K vorgestellt“ sucht die passende Stelle im Artikel, markiert sie in der Seite, scrollt hin und zeigt den Satz in einer Glas-Karte. Kein Sprachmodell: die Antwort ist immer ein wörtlicher Satz der Seite.

**Auslöser.** Befehl `ask` (Titel „Frag die Seite“, Symbol `text.magnifyingglass`) mit Präfixen „frag (die Seite)“, „frage (die Seite)“, „ask (the|this page)“. Bei „frage“ und „ask“ muss ein Fragewort folgen (wer, was, wann, wo, wie, warum, welche …, who, what, when …), sonst bleibt es Suche („Frage der Woche“, „ask jeeves“). Selbsttest `ask:<frage>`, `ask:next`.

**Ablauf.**
1. `BrowserIntelligenceController askCurrentPage:` schließt Zusammenfassung, Übersetzen-Hinweis und alte Antwort, dann `BrowserIntelligence askQuestion:inWebView:completion:`.
2. Text: `BrowserReaderMode textForWebView:` mit bis zu 30.000 Zeichen (Readability, ohne Tabellen).
3. Anbieter (`findPassagesForQuestion:inText:maxResults:completion:`): Sätze wie beim Zusammenfassen (gemeinsame Funktion `sentencesOfText:…`, hier mit Zahlen), Fragebegriffe ohne Frage- und Füllwörter (`BrowserNLQuestionStopTerms`), Fragetyp aus dem Fragewort (Datum, Zahl, Ort, Person).
4. Bewertung je Satz: Begriffsabdeckung mit IDF über die Sätze (0,7 eigener Satz, 0,15 Nachbarsätze, 0,15 Schwerpunkt = seltenster Begriff), Fragetyp-Treffer (Jahreszahl/Datum, Zahl mit Einheit, Ort, Name) als Bonus; Satz-Embedding nur für Sätze mit Abdeckung ≥ 0,25 (spart etwa 1 s pro Artikel). Wert = 0,58 Begriffe + 0,27 Embedding + 0,15 Art (ohne Embedding 0,85/0,15), über 45 Wörter × 0,88.
5. Relevanz: Abdeckung ≥ 0,45, oder ≥ 0,25 wenn das Embedding ≥ 0,65 stützt; unter 0,30 Embedding braucht es ≥ 0,80 Abdeckung. Bis zu 3 Stellen mit mindestens 55 % des besten Werts, keine Teilstring-Dubletten.
6. Andere Sprache als die Seite (deutsche Frage, englische Seite): kleines Wörterbuch de↔en (`BrowserNLTranslations`, Frageverben und Technikwörter mit gebeugten Formen, z. B. „vorgestellt“ → announced/introduced/unveiled). Kein Übersetzer.
7. Markieren (`highlightPassage:inWebView:`, Skript `kAskHighlightScript`): TreeWalker über sichtbare Textknoten (bei aktivem Reader in `#__reader`, ohne `sup`, `script`, `.mw-editsection`), Leerraum normalisiert, Suche exakt, dann ohne Groß/Klein, dann Anfang+Ende; die Textstücke werden in `span.__bask` gehüllt. Wirkung: weißer Ring und blauer Glow, der in eine gelbe Markierung übergeht (CSS-Keyframes), nach 9 s Ausblenden, nach 10 s wieder entfernt. `scrollIntoView({block: 'center', behavior: 'smooth'})`. `window.__browserAsk.clear()/fade()`.
8. Karte `BrowserAnswerCardView`: Glas unten mittig (bis 1.500 pt breit), „Frage: …“, der Satz in der Reader-Schrift (30 pt, bis 4 Zeilen), Fußzeile „Stelle 1 von 3 · Play/Pause: nächste · Zurück-Taste schließt · Lokal · 0,1 s“ (bzw. „in der Seite nicht markiert“, wenn das Skript den Satz nicht fand). Play/Pause springt zur nächsten Stelle (Karte federt auf die neue Höhe), Zurück-Taste schließt und nimmt die Markierung weg, nach 25 s blendet sie aus. Neue Seite, Tabwechsel und Zusammenfassen schließen sie.
9. Kein Treffer: Rückmeldung „Keine passende Stelle gefunden“ (bzw. „Frage zu kurz“, „Kein Text auf der Seite“).

**Messwerte (Simulator „Ask-Test“, Apple TV 4K, tvOS 27.2, 8. November 2026).**

| Seite / Frage | Ergebnis | Verfahren | Abruf / Rechnen |
|:--|:--|:--|:--|
| de.wikipedia.org/wiki/Apple_TV, „frag wann wurde das Apple TV 4K vorgestellt“ | 1: „Am 12. September 2017 wurde das Apple TV 4K vorgestellt.“ (0,97), 2: 2021, 3: 2022; genau markiert | Begriffe (IDF), kein de-Embedding | 21 ms / 83 ms |
| en.wikipedia.org/wiki/Apple_TV_(device), „ask when was the Apple TV 4K announced“ | 1: Ankündigung 4. Generation 2026, 2: 2017 – die Frage ist mehrdeutig | Begriffe + Satz-Embedding (23 Sätze eingebettet) | 48 ms / 408 ms |
| dieselbe Seite, deutsche Frage „frag wann wurde das Apple TV 4K vorgestellt“ | 2026, 2017, 2021 („announced“) | Begriffe + Wörterbuch | 48 ms / 72 ms |
| „what is the capital of France“, „frag wie heißt der Hund“ | keine Stelle (richtig) | – | – |
| „how much storage does the Apple TV 4K have“ | schwach: Formfaktor-Sätze; die Speicherangaben stehen in Tabellen, die Readability nicht liefert | | |

Screenshots: `docs/ai-screens/frag-die-seite-de.png` (Antwort 1), `frag-die-seite-de-naechste.png` (Play/Pause → Stelle 2), `frag-die-seite-en.png` (Glow-Phase), `frag-die-seite-de-auf-en.png` (deutsche Frage auf englischer Seite), `frag-die-seite-kein-treffer.png`.

**Bewertung.** Für Faktenfragen zu Lexikon- und Nachrichtentexten („wann“, „wie viel“, „wer“) gut: der richtige Satz steht meist auf Platz 1, sonst auf 2 oder 3, und Markieren plus Hinscrollen macht ihn sofort sichtbar. Unsinnsfragen werden abgelehnt. Schwach bei mehrdeutigen Fragen (welches Modell?), bei Antworten, die über zwei Sätze verteilt sind, und bei Fakten in Tabellen oder Infoboxen. „Warum“- und Meinungsfragen beantwortet es nicht im eigentlichen Sinn, es zeigt höchstens den Satz mit den meisten Begriffen.

**Grenzen und Fallen.**
- Nur die ersten 30.000 Zeichen des Readability-Textes; Tabellen und Infoboxen fehlen.
- Deutsch ohne Satz-Embedding und ohne Lemma (Simulator): „vorgestellt“ findet „vorstellen“ nur über den Stammformer und das Wörterbuch. Am Gerät messen.
- Markierung: Ein Satz über mehrere Links wird in mehrere `span` geteilt; an den Nahtstellen sieht man kleine Lücken im Glow. Fixe Banner (Wikipedia-Spendenbanner) können den Satz nach dem Scrollen teilweise verdecken.
- Steht der Satz nur im Readability-Text, aber anders im DOM (Silbentrennung, `&shy;`, umgestellte Zitate), meldet die Karte „in der Seite nicht markiert“.

**Woran man merkt, dass es kaputt ist.** `[AI] frag "…": 0 Treffer … Begriffe=[]`: Stoppliste schluckt alles. `[AI] markieren: {"found":false,"why":…}`: Seite ändert den DOM oder der Text weicht ab. Karte erscheint, aber kein Glow: Seiten-CSS überschreibt `.__bask` (Stil steht in `#__bask_style`, im Web-Inspector prüfen).

**Test.**
```
POINTER_SELFTEST="url:https://de.wikipedia.org/wiki/Apple_TV;wait;wait;enter:frag wann wurde das Apple TV 4K vorgestellt;wait;ask:next"
POINTER_SELFTEST="url:https://en.wikipedia.org/wiki/Apple_TV_(device);wait;wait;ask:when was the Apple TV 4K announced;wait;wait;ask:what is the capital of France"
POINTER_SELFTEST="parse:geh eine Seite zurück|lade die Seite nochmal|Tabs vs Spaces|frag wer hat das erfunden|Frage der Woche"
```

**Aktualisieren.** Schwellen `kAsk…` und `kCommand…` oben in den jeweiligen Blöcken von `BrowserIntelligence.m`, Stoppwörter `BrowserNLQuestionStopTerms`/`BrowserCommandStopWords`, Wörterbuch `BrowserNLTranslations`, Markier-Skript `kAskHighlightScript`. Wer Schwellen ändert, lässt den `parse:`-Selbsttest oben laufen: alle Suchbegriffe müssen „-> Suche“ bleiben.

---

## 20. Formen und Eckenradien (`BrowserShape`)

**Regeln** (Apple, Liquid Glass / tvOS 26): Ecken immer mit kontinuierlicher Kurve (`kCACornerCurveContinuous`, „Squircle“); Knöpfe, Zeilen, Leisten und Hervorhebungen in Leisten als Kapsel (Radius = halbe Höhe); verschachtelte Formen konzentrisch, also innerer Radius = äußerer Radius − Abstand zum Rand.

**Umsetzung.** `_Project/Browser/BrowserShape.h` (nur Header, nicht im Projekt eingetragen nötig) mit den Stufen und Helfern:

| Stufe | Wert | Wo |
|:--|:--|:--|
| `BrowserShapeCardRadius` / `…CardInset` | 84 / 44 | Bedienungsdialog, Was ist neu, Zusammenfassungs-Karte; Knöpfe 80 pt hoch (Kapsel) mit 44 pt Abstand → konzentrisch |
| `BrowserShapePanelRadius` / `…PanelInset` | 50 / 14 | Seitenleiste, Tab-Übersicht; Kacheln darin mit Radius 36 (36 + 14 = 50) |
| `BrowserShapeTileRadius` | 32 | Tab-Karten, Kacheln der alten Startansicht (Icon darin `BrowserShapeConcentricRadius(32, Abstand)`) |
| `BrowserShapeSmallRadius` | 16 | Untertitel-Kästen (Player und Webseite), Hinweise im Player |
| Kapsel | Höhe/2 | Leiste, Diktierfeld, Reader-Hervorhebung, Schalter, Symbolkreise, Befehls-Einblendung, Ladelinie |

Helfer: `BrowserShapeApply(layer, radius)` (Radius + kontinuierliche Kurve), `BrowserShapeCapsuleRadius(height)`, `BrowserShapeConcentricRadius(outer, inset)`. Eigene Radien weiter in Gebrauch, weil an Inhalt gebunden: Aufklapp-Karte 40 (wächst aus der Kapsel-Leiste, gleiche Stufe wie die halbe Leistenhöhe), Favicon-Kacheln `iconSize × 0,24` (App-Icon-Form), Einrast-Hervorhebung/Glow (Kapsel bis 80 pt Höhe, sonst `MIN(34, Höhe/2)`, folgt dem Seitenelement; bis 8. November 2026 Kapsel bis 120 pt, das schnitt bei mehrzeiligen Zielen wie Google-Treffern Favicon und Titelanfang an), Antwort-Karte „Frag die Seite“ 44.

**Neue Fläche:** Stufe aus `BrowserShape.h` nehmen, nicht frei wählen; liegt etwas mit Abstand in einer runden Fläche, Radius mit `BrowserShapeConcentricRadius` ableiten.

---

## 21. Leistung: Messung, Optimierungen, Befunde

**Messweg (Simulator, Apple TV 4K 3. Generation, tvOS 27.2).** DEBUG-Build, Start mit `xcrun simctl launch --console-pty --terminate-running-process <udid> io.github.tvosbrowser.app` und Selbsttest (Abschnitt 14.2). Zeitmarken aus `[Perf]`-Zeilen (`BrowserPerf.h`, Millisekunden seit Prozessstart über `sysctl KERN_PROC_PID`), CPU mit `top -l` auf die Mac-Prozesse des Simulators (App, `com.apple.WebKit.WebContent`, `backboardd` als Render-Server), Speicher mit `footprint -p`, Hauptthread-Blockaden mit `PERF_STALLS=1`. Simulatorwerte schwanken stark (Pre-main 240–790 ms); Aussagen daher nur aus mehreren Läufen und immer A/B im selben Simulator.

**Ergebnisse (Mittel aus 5 Starts, gespeicherte Cookies vorhanden, ms nach `main`):**

| Messung | vorher | nachher |
|:--|--:|--:|
| Cookie-Wiederherstellung in `didFinishLaunching` | 598–1420 | 9 |
| erste Seite `didStartProvisionalNavigation` | 788 (min 652) | 421 (min 357) |
| erste Seite commit | 1112 (min 934) | 794 (min 692) |
| erste Seite paint | 1662 (min 1477) | 1358 (min 1207) |
| erste Seite finish | 2185 (min 1777) | 1662 (min 1479) |
| `backboardd` bei ausgeblendetem Glow (Leerlauf) | 0,8–0,9 % | < 0,2 % |

**Optimierung 1: Cookies beim Start nicht abwarten** (`BrowserWebView restoreCookiesFromData:`). Früher wurde jeder `setCookie:completionHandler:` per `BrowserPumpRunLoopUntil` abgewartet; die Bestätigung kommt erst, wenn der Netzwerkprozess läuft, also hing `didFinishLaunching` und die erste Seite startete später. WebKit reiht die Cookies vor dem Netzwerkprozess-Start ein und setzt sie vor der ersten Anfrage. Geprüft mit einem lokalen Server: die erste Anfrage nach dem Start (WebKit-Cookiedatei vorher gelöscht) trägt das wiederhergestellte Cookie; Gegenprobe ohne gespeicherte Cookies kommt ohne Cookie.

**Optimierung 2: Glow pausiert, wenn unsichtbar** (`BrowserGlowView animationsPaused`, `BrowserRemoteInputController`). Drehung (`spin`) und Atmen (`breathe`) liefen nach dem Lösen der Hervorhebung bei Alpha 0 weiter und kosteten den Render-Server dauerhaft Zeit. Jetzt werden sie nach dem Ausblenden entfernt (`pauseGlowIfHighlightHidden` im Abschluss der Ausblend-Animation von `clearSnapAnimated:` und `hideCursorForIdle`, beim Zielwechsel im Abschluss der ausblendenden Hervorhebung) und vor dem Einblenden neu angelegt (`showHighlightForTarget:animated:`, `revealCursorIfIdle`), mit `beginTime` auf dem gemeinsamen Nullpunkt `BrowserGlowClockStart`, sodass die Drehung stets dieselbe Stellung hat wie bei durchlaufender Animation. Bis 8. November 2026 über Ebenen-`speed` 0 (lief an derselben Stelle weiter); mit zwei Hervorhebungen (Abschnitt 8.3) hätten die beiden Glows dann verschiedene Farbstellungen. Mit `anims` geprüft: nach einem Zielwechsel laufen nur die Animationen der sichtbaren Hervorhebung (4 Glow-Ebenen).

**Untersucht, ohne Handlungsbedarf:**
- Synchrones JavaScript (`stringByEvaluatingJavaScriptFromString:`, 3–7 Aufrufe je Seite, Wartezeit bis 890 ms): der Pump lässt den Run-Loop weiterlaufen; ein asynchroner Umbau änderte die Hauptthread-Blockaden nicht messbar (vorher 407–520 ms, nachher 369–523 ms über fünf Seiten) und wurde verworfen.
- Schriftgrößen-Durchlauf (`updateTextFontSize`): lief früher bei jedem Laden auch bei 100 % über alle Elemente (`getComputedStyle`, dann `font-size !important` festgeschrieben). Am Apple TV wartete der Main-Thread darauf bis 710 ms (spiegel.de), und die Seite konnte ihre Schriftgrößen danach nicht mehr selbst ändern. Seit 8. November 2026 fasst er bei 100 % nur Elemente mit `data-browser-original-font-size` an (früher vergrößert, werden zurückgesetzt); Gerät danach meist 21–24 ms, Ausreißer 108–351 ms, wenn der Seitenprozess noch lädt (Wartezeit, nicht Rechenzeit).
- Klickziele (`collect()`): heise 3 ms (407 Ziele), spiegel 6 ms (787), YouTube 0,6 ms; im Leerlauf 0–3 Aufrufe in 33 s.
- Leerlauf-CPU: App 0,0–0,1 %, Seitenprozess 0,8–2,7 % (Seiteninhalt); `backboardd` 3,4 % auf about:blank kommt aus dem UIKit-Glas (`UISDFElementView`, System).
- Zeiger: 0,1–0,3 ms je Bild ohne JavaScript (Abschnitt 8.8).
- WebView-Anlage 29–89 ms (Datenspeicher und `WKWebView`-Init in WebKit); Werbeblocker aus dem Speicher 160–320 ms nach `main` bereit, vor Navigationsbeginn; Scriptlets asynchron; Intelligenz und whisper werden erst bei Gebrauch geladen.
- Geschlossene Tabs: `BrowserWebView` wird freigegeben (`[Perf] BrowserWebView freigegeben`); Seitenprozesse hält WebKit als Cache, ihr Speicher sinkt.
- Speicher: App 39–46 MB, Seitenprozess 130–590 MB je nach Seite.
- Schatten ohne `shadowPath` (Bedienungsdialog, Menüschalter, Tab-Karten, Untertitel): nur in Dialogen sichtbar, nicht im Leerlauf oder beim Lesen; Seitenwechsel-Schnappschuss nur einmal je Navigation (`afterScreenUpdates:NO`).

**Sonde am Gerät** (`BrowserPerfProbe.m`, nur DEBUG): mit `DEVICECTL_CHILD_PERF_LOG=1` schreibt die App „[Perf] Start bis aktiv … ms“ und alle 5 s „[Perf] t=…s Speicher … MB CPU … %“ (eigener Prozess, ohne Seitenprozesse). Seitenprozesse zählen: `xcrun devicectl device info processes --device <UDID> | grep -c WebKit.WebContent`. Instruments „App Launch“ hängt am Apple TV beim Start, deshalb diese Sonde. Ergebnisse: `docs/BERICHT-STABILITAET-LEISTUNG.md`.

**Am Gerät messen.** Start mehrfach mit `DEVICECTL_CHILD_POINTER_SELFTEST=wait` und die `[Perf]`-Zeilen vergleichen; `DEVICECTL_CHILD_PERF_STALLS=1` für Blockaden beim Laden; Glow-Kosten mit Instruments (Core Animation/Energie) mit und ohne eingerastetes Ziel; Schriftgrößen-Durchlauf mit dem `js:`-Schritt auf großen Seiten.

## 22. Ersteinrichtung (`BrowserSetupViewController`)

Erscheint beim Start, solange `BrowserPreferencesStore.setupCompleted` (Schlüssel `SetupCompleted`) nicht gesetzt ist – also beim ersten Start und einmal bei bestehenden Installationen, die die Einrichtung noch nicht kannten. Eine Glas-Karte (1500 pt breit, wie die Bedienungshilfe) mit sechs Schritten, bedient über den tvOS-Fokus:

| Schritt | Inhalt | Speichert |
|:--|:--|:--|
| Willkommen | Überblick, „Überspringen“ (übernimmt die Vorbelegung) oder „Einrichten“ | – |
| 1 Favoriten | „Welche Seiten willst du über diesen Browser öfter besuchen?“ 12 Vorschläge (nichts vorausgewählt), „Eigene Seite“ (bis 7 eigene Adressen) | `BrowserHistoryStore` Favoriten (Stern) |
| 2 Startseite | „Welche Seite soll beim Starten der App als Erstes geöffnet werden?“ Google, gewählte Favoriten, „Andere Seite“ | `homePageURLString` (leer = Google) |
| 3 Schutz | Werbeblocker, Cloudflare-DNS („für freies Internet“), Cookie-Banner ablehnen (soweit möglich) | `adBlockEnabled`, `BrowserDNSProxy.enabled`, `cookieBannerBlockEnabled` |
| 4 Videos | Videos im Apple-Player, automatische Untertitel, Untertitel in der Webseite | `autoOpenVideosInNativePlayer`, `autoSubtitlesEnabled`, `webSubtitlesEnabled` |
| 5 Design | Liquid Glass oder altes Design | `classicDesignEnabled` |

Vorbelegung: aktuelle Werte; bei einer frischen Installation (kein `WhatsNewSeenVersion`) sind alle Schalter an, Design Liquid Glass. Vorhandene Favoriten sind vorausgewählt, Abwählen entfernt sie beim Abschluss. Wird eine als Startseite gewählte Seite als Favorit abgewählt, fällt die Startseite auf Google zurück. Menü-Taste: ein Schritt zurück, im ersten Schritt bleibt die Karte offen.

Nach „Fertig“ (`ViewController applySetupResultWithHomePageChanged:`): Werbe- und Cookie-Blocker laden ihre Einstellungen neu, die DNS-Weiterleitung wird gestartet bzw. vom Datenspeicher genommen, Webseiten-Untertitel an/aus, Benachrichtigung `BrowserDesignDidChangeNotification`, dann Startseite laden (falls geändert, sonst Seite neu laden) und die Bedienungshilfe zeigen. „Was ist neu“ wird für diese Fassung als gesehen markiert. Alles bleibt in der Seitenleiste änderbar.

Import aus anderen Browsern gibt es nicht: tvOS gibt Apps keinen Zugriff auf Safari-Daten oder Daten anderer Apps; die Vorschläge im Favoriten-Schritt ersetzen das für den Einstieg.

Selbsttest (DEBUG): `setup` zeigt die Karte, `setup:N` Schritt N, `setupopt:i` betätigt die i-te Auswahl des Schritts, `setupnext` Weiter/Fertig. Log `[Setup]`.

---

## 23. Altes Design

**Zweck.** Oberfläche wie die ursprüngliche Fassung (jvanakker/tvOSBrowser, Stand 2.0.0, Vorlage `screen01.png` bis `screen03.png` im Repo-Wurzelordner) statt Liquid Glass. Umschalten unter •••, „Ansicht & Wiedergabe“, „Design“ (`designMenuItem` in `BrowserMenuCoordinator.m`, Detail „Liquid Glass“ / „Alt“). Einstellung `BrowserPreferencesStore.classicDesignEnabled`, Schlüssel `ClassicDesign`, Standard aus. Abfrage überall über `BrowserMotion.classicDesignEnabled`.

**Was sich ändert.**
- **Obere Leiste** (`BrowserTopBarView.m`, Abschnitt „Altes Design“, `applyDesign`): graue halbtransparente Kapsel 1760 × 86 pt, 8 pt unter dem Rand. Kein Glas: dunkler `UIBlurEffect` mit grauer Tönung (`glassDimmingView` Weiß 0,54 / Alpha 0,62, ergibt auf weißer Seite Grau 155 wie `screen01.png`), keine Kante, kein Schatten. Symbole sind die weißen Originalbilder aus `Icons/MenuIcons` (`go-back-left-arrow`, `refresh-button`, `right-arrow-forward`, `house-outline`, `multi-tab`, `resize-arrows`, `menu-2`; als Template in Weiß, eingepasst in 52 pt). Links Zurück, Neu laden, Vor, Startseite, Tabs; mittig die volle Adresse in Weiß 0,72 (`setDisplayURLString:`, geliefert von `BrowserTabCoordinator refreshActiveTabUI`); rechts Ladekreisel, Vollbild (`BrowserTopBarActionFullscreen`, Dialog „Obere Leiste ausblenden?“) und Menü. Symbole und Schrift bleiben auf jeder Seitenfarbe weiß.
- **Weggelassen bzw. schlicht, mit Grund:** Kapsel beim Scrollen (`setCompact:` wird ignoriert, das Original blieb voll; „zweimal unten“ schließt dann nur den Bearbeiten-Zustand), Ladelinie (das Original hatte nur den Kreisel), Kanteneffekt `topEdgeEffect` (ausgeblendet), Seitenname mit grünem HTTPS-Namen (ersetzt durch die volle Adresse). Der Favoriten-Stern macht wieder der Startseite Platz, wie im Original; Favoriten bleiben über ••• „Favoriten“ und Sprachbefehle erreichbar. Reader bleibt, weil er sonst nur per Sprachbefehl erreichbar wäre: Er erscheint links vom Vollbild-Knopf nur auf lesbaren Seiten (dann rückt der Kreisel nach links), auf anderen Seiten sieht die Leiste aus wie das Original.
- **Glas aus:** `BrowserMotion.glassMaterialAvailable` liefert NO; Adressfeld-Karte, Seitenleiste, Bedienungsdialog (Karte und Knöpfe), Karten der intelligenten Funktionen und Rückmeldungen der Sprachbefehle nehmen ihren dunklen Blur-Rückfall. Systemdialoge (`UIAlertController`) bleiben, wie tvOS sie zeichnet.
- **Animationen:** `BrowserMotion.liquidGlassEnabled` liefert NO, es gilt der schlichte Stil (Abschnitt 18), unabhängig vom Schalter „Liquid-Glass-Animationen“.
- **Zeiger:** Mit Zeigerstil 0 (Standard „Dunkel“) nimmt `BrowserCursorRenderer imageForKind:` die 64-pt-Bitmaps des Originals (Assets `Cursor` und `Pointer`, `classicImageForKind:`), versetzt auf die gemeinsame Klickspitze (`+hotspot`; Pfeilspitze bei (1, 1), Fingerspitze bei (10, 2) im Bild). Stil 1 und 2 sowie die Texteinfügemarke bleiben unverändert.

**Umschalten wirkt sofort.** Die Leiste beobachtet `NSUserDefaultsDidChangeNotification` (Seitenleiste, Ersteinrichtung, Selbsttest-Schritt `pref:`) und `UISceneDidActivateNotification` (Änderung aus einem anderen Prozess) und ruft bei echtem Wechsel `applyDesign` auf: Symbole, Fläche, Vordergrund (mit der gemerkten Seitenfarbe), Fokusknöpfe (Vollbild nur im alten Design, „Startseite“ statt „Favorit“), Layout. Seitenleiste, Dialoge und Karten fragen `BrowserMotion` beim nächsten Öffnen, der Zeiger beim nächsten Bildwechsel.

**Woran man merkt, dass es kaputt ist.** Leiste bleibt nach dem Umschalten im alten Look: DEBUG-Zeile `[TopBar] Design alt|Liquid Glass` fehlt. Symbole fehlen: `Icons/MenuIcons/*.png` nicht mehr im Ressourcen-Build (Gruppe „MenuIcons“ im Projekt, Pfad `../../Icons/MenuIcons`); dann greifen die SF Symbols als Rückfall. Im alten Design erscheint Glas: ein neuer Aufrufer prüft `@available(tvOS 26.0, *)` statt `BrowserMotion.glassMaterialAvailable`.

**Test.** Eigener tvOS-Simulator, `SIMCTL_CHILD_POINTER_SELFTEST="pref:ClassicDesign=1;url:https://www.apple.com/apple-tv-4k/;wait;wait"` mit `xcrun simctl launch --console-pty --terminate-running-process <udid> io.github.tvosbrowser.app`, Screenshot per `xcrun simctl io <udid> screenshot` und mit `screen01.png` vergleichen. Zurück: `pref:ClassicDesign=0` (die Leiste ist danach bildgleich mit einem Start im neuen Design). Klicks: `360,50;click` (Startseite), `1712,50;click` (Vollbild-Dialog), `label` zeigt die Adresse. Zeiger sichtbar: Schritt `x,y` als letzten Schritt (nach 4 s Leerlauf blendet der Zeiger aus).

---

## 24. Pop-ups und unbenutzte Tabs (`BrowserPopupNotice`)

**Zweck.** Pop-ups unterbrechen nicht mehr: Alles, was die Seite in einem neuen Fenster öffnen will, landet als Hintergrund-Tab. Der sichtbare Tab bleibt, es kommt kein Dialog. Tabs, die nie angesehen wurden, schließen sich nach 30 Minuten von selbst.

### 24.1 Pop-ups als Hintergrund-Tab

**Wege.** Alle drei enden in `ViewController openBackgroundTabWithRequest:popup:` → `BrowserTabCoordinator createBackgroundTabWithRequest:` → `BrowserViewModel addBackgroundTab` (hängt hinten an, aktiver Tab bleibt):
- `window.open(…)` und `<a target="_blank">`, die die Seite selbst auslöst: `BrowserWebView` (UIDelegate `createWebViewWithConfiguration…`) → Host `webView:shouldCreateNewTabWithRequest:navigationType:`. `navigationType` 0 (`WKNavigationTypeLinkActivated`) gilt als Link, alles andere als Pop-up.
- Klick des Nutzers auf einen `target=_blank`-Link: `BrowserPageActionCoordinator handleTargetBlankLinkAtDOMPoint` → `browserPageActionCoordinatorCreateNewTabWithRequest`.

**Bewusst geklickte `target=_blank`-Links öffnen ebenfalls im Hintergrund.** Das ist so gewollt und nicht zu unterscheiden: Viele Seiten öffnen Werbe-Pop-ups über einen unsichtbaren `target=_blank`-Link über dem ganzen Inhalt, ein „echter“ Klick sieht für den Browser genauso aus. Einheitlich gilt deshalb: Neue Fenster gehen in den Hintergrund. Die Einblendung (24.2) zeigt den Titel. Mit Klick darauf oder Play/Pause ist man mit einem Druck dort.

Die WebView für den neuen Tab entsteht wie jede andere (`createConfiguredWebView`, gleiche Werbeblocker-/Nutzerskript-Konfiguration). Sie wird in `thumbnailStagingView` geparkt (`parkWebViewForThumbnailing:`) und lädt dort. Medien werden nach dem Laden angehalten wie bei jedem Hintergrund-Tab. Der neue Tab hat `userInteracted = NO`, `openedAt = jetzt` und als Titel bis zum Laden den Host.

**Nur http/https.** Andere Schemata (`about:blank`, `javascript:`, Apps) werden ignoriert. Bei 5 Tabs (`kMaximumTabCount`) wird nichts geöffnet. Es gibt eine kurze Rückmeldung „Pop-up nicht geöffnet: höchstens fünf Tabs“ (`commandRouter showFeedback`), keinen Dialog. Log: `[Popup] nicht geöffnet, schon 5 Tabs`.

**Einschränkungen (bewusst).**
- `createWebViewWithConfiguration` gibt `nil` zurück, die Seite bekommt für `window.open` also `null`, und `window.opener` fehlt im neuen Tab. Anmeldefenster, die per `postMessage` an den Opener zurückmelden (manche OAuth-Abläufe, Zahlungsfenster), funktionieren deshalb im Pop-up-Tab nicht. Gegen eine echte Kind-WebView mit Opener spricht, dass sie im selben Prozess wie die Seite hängen und ohne Nutzerinteraktion weiterlaufen würde.
- Seiten, die bei `null` auf `location.href = …` zurückfallen, navigieren den sichtbaren Tab um. Das ist das Verhalten der Seite.
- `window.open` ohne Nutzergeste blockiert WebKit selbst (`javaScriptCanOpenWindowsAutomatically` ist unter tvOS standardmäßig NO). Solche Pop-ups kommen gar nicht erst an, Testseite „Auto-Pop-up“ liefert `null`. Klicks über die Fernbedienung gelten als Geste.

### 24.2 Einblendung unten rechts

`BrowserPopupNotice` (eigene Klasse, `initWithContainerView:`): Kapsel 104 pt hoch, höchstens 780 pt breit, 80 pt vom rechten und 70 pt vom unteren Rand.
- **Darstellung:** Mit Liquid Glass ist das ein getöntes `UIGlassEffect`. Liefert `BrowserMotion.glassMaterialAvailable` NO (altes Design, ältere Systeme), ist es ein dunkler Blur. Erscheinen und Verschwinden laufen über `BrowserMotion glassAppear/glassDisappear`.
- **Texte:**
  - gleiche Website (`BrowserSiteKeyForHost`: letzte zwei Namensteile, drei bei `co.uk` u. ä.): „Diese Webseite hat soeben ein Pop-up geöffnet“;
  - fremde Website: „Pop-up geöffnet: <Titel>“, bis der Titel geladen ist mit dem Host (ohne `www.`);
  - Link: „Im Hintergrund geöffnet: <Titel>“;
  - darunter „Play/Pause: öffnen“.
  - Den Titel aktualisiert `webViewDidFinishLoad` (`updateDisplayName:forTabWithIdentifier:` mit `BrowserShortSiteName`).
- **Zusammenfassen:** Ein weiteres Pop-up, solange die Einblendung steht, ersetzt den Text („3 Pop-ups geöffnet“ bzw. „3 Tabs im Hintergrund geöffnet“) und startet die 6 s neu. Gestapelt wird nicht. Ziel ist dann der zuletzt geöffnete Tab.
- **Dauer:** 6 s ab dem letzten Pop-up. Ein Generationszähler verhindert, dass ein altes Ausblenden ein neues abschneidet.
- **Zum Tab springen:** Die Einblendung ist ein Zeigerziel (ohne Linse, eigener Eckenradius). Seitenziele, die sie verdeckt, fallen weg. Ein Klick darauf (`browserHandlePrimaryAction`, vor der Prüfung der oberen Leiste) ruft `jumpToPopupTab` auf. Play/Pause kurz springt ebenfalls dorthin, solange sie sichtbar ist, kein Dialog und keine Adressleiste offen ist und kein Video läuft (`browserRemoteInputControllerHandlePlayPausePress`, vor dem Hinweis „Übersetzen?“). Läuft ein Video, steuert Play/Pause weiter das Video.
- Schließt sich der Tab der Einblendung (automatisch, 24.3), wird sie ausgeblendet.

**Siri-Taste.** Ursprünglich gewünscht war „Siri-Taste öffnet das Pop-up“. Direkt bekommen Apps die Siri-Taste nicht, ein kurzer Druck lässt sich aber am 5-ms-Rechtsdruck ohne `buttonA` erkennen (Abschnitt 8.2, Zeile „Siri-Taste“). Seit 9. November 2026 springt **Siri zweimal** zum Pop-up-Tab, solange der Hinweis sichtbar ist. Dazu der Klick auf die Einblendung und Play/Pause.

### 24.3 Unbenutzte Tabs automatisch schließen

- **Zustand je Tab** (`BrowserTabViewModel`):
  - `openedAt` (Wanduhr, Sekunden seit 1970) und `userInteracted`, in der Sitzung als `openedAt`/`used` gespeichert.
  - Normal geöffnete Tabs und Tabs aus alten Sitzungen ohne `used` gelten als benutzt.
  - Nur Hintergrund-Tabs aus 24.1 starten mit `used = NO`.
- **Benutzt** wird ein Tab für immer, sobald er angezeigt wird (`attachActiveWebView` → `markTabUsed:`, Log `[Tabs] Tab benutzt: <URL>`). Klicken, Scrollen und Laden einer Adresse passieren immer im angezeigten Tab und sind damit abgedeckt.
- **Prüfung** (`ViewController closeExpiredUnusedTabs` → `BrowserTabCoordinator closeUnusedTabsOlderThan:`):
  - **Wann:** per Timer (`startUnusedTabTimer`, jede Minute; bei kurzer Testzeit `MIN(60, MAX(2, Ablauf/4))` s), bei `UIApplicationDidBecomeActiveNotification` (Rückkehr in den Vordergrund, auch beim Start).
  - **Ablauf:** läuft rückwärts durch die Tabs und schließt unbenutzte, die älter als die Ablaufzeit sind. Nie den aktiven, nie den letzten Tab.
  - Bei offener Tab-Übersicht wird nicht geprüft.
  - Log `[Tabs] unbenutzten Tab automatisch geschlossen nach N s: <URL>`.
- **Einstellung:** Seitenleiste, Abschnitt „Navigation“, letzter Eintrag „Unbenutzte Tabs nach 30 Min. schließen“ (An/Aus, Symbol `clock.badge.xmark`, Schlüssel `CloseUnusedTabs`, Standard an; `BrowserPreferencesStore closeUnusedTabsEnabled`/`unusedTabExpiryInterval`). Die übrigen Einträge behalten ihre Reihenfolge.
- **Testzeit:** Im DEBUG-Build überschreibt die Umgebungsvariable `TAB_EXPIRY_SECONDS` die 1800 s.

### 24.4 Woran man merkt, dass es kaputt ist

- Pop-up wechselt doch den Tab oder öffnet nichts: `[Popup] … im Hintergrund-Tab N geöffnet` fehlt. Dann prüfen, ob `createWebViewWithConfiguration` den Host noch erreicht (WebKit-Update, Abschnitt 3).
- Einblendung ohne Glas im neuen Design: `glassMaterialAvailable` prüfen.
- Tabs verschwinden, die man gesehen hat: Fehlt `[Tabs] Tab benutzt` beim Anzeigen, wurde `attachActiveWebView` umgangen.

### 24.5 Test

Eigener Simulator, lokale Testseite mit Pop-up-Knöpfen (`window.open`, `target=_blank` auf andere Website, drei Pop-ups, Auto-Pop-up ohne Geste), `python3 -m http.server`:

```sh
# Pop-ups, Zusammenfassen, Titel, 5-Tab-Grenze
SIMCTL_CHILD_POINTER_SELFTEST="url:http://127.0.0.1:8765/index.html;js:document.getElementById('pop').click(),1;tabinfo" …
# Klick auf die Einblendung und Play/Pause (Schritte im Abstand 1,5 s, damit es in die 6 s passt)
SIMCTL_CHILD_POINTER_SELFTEST_INTERVAL=1.5 SIMCTL_CHILD_POINTER_SELFTEST="…;js:…pop…click(),1;popuppoint;click;tabinfo" …
# Ablauf mit 20 s: unbenutzter Tab schließt nach ~23 s, angezeigter (tab:2) bleibt
SIMCTL_CHILD_TAB_EXPIRY_SECONDS=20 SIMCTL_CHILD_POINTER_SELFTEST="…;js:…pop…;tab:2;tab:0;w;w;w;w;w;w;w;w;tabinfo" …
```

Stand 8. November 2026 (Simulator tvOS 27.2) bestanden:
- **Pop-ups:** Pop-up und Link landen im Hintergrund, mehrere werden zusammengefasst, der Titel wird nachgeladen. Bei 5 Tabs kommt die Rückmeldung, kein Dialog. Das Auto-Pop-up blockiert WebKit.
- **Sprung:** Klick auf die Einblendung und Play/Pause springen zum Tab.
- **Ablauf:** Der unbenutzte Tab schließt nach 23 s. Ein angezeigter Tab bleibt nach 33 s offen. Beim Start schließen abgelaufene Tabs aus der Sitzung, der letzte bleibt.
