# Sprachsteuerung der App: Siri, Diktat, iPhone (Konzept und Machbarkeit)

Stand: 8. November 2026, tvOS 27.2, Xcode 27.2. Wunsch: Man sagt etwa „Starte den Reader“, und die App führt die Aktion aus, als hätte man den Knopf gedrückt.

Kurz gesagt: **Siri auf dem Apple TV löst nach allem, was belegbar ist, keine eigenen Phrasen von Drittanbieter-Apps aus.** Die Schnittstellen (App Intents, App Shortcuts) gibt es auf tvOS zwar. Sie bauen, und das System registriert sie auch. Apple dokumentiert für Siri auf dem Apple TV aber keine App Shortcuts, und Entwickler berichten, dass Siri sie dort nicht aufruft. Ein Gerätetest (10 Minuten, Anleitung in Abschnitt 3.4) ist mit dem Spike auf diesem Zweig jetzt möglich und klärt die Restunsicherheit. Empfohlen wird ein Weg, der sicher funktioniert: **Sprachbefehle über das Diktat im Adressfeld**, aufgebaut auf einer gemeinsamen Befehlstabelle `BrowserCommand`. Siri und die iPhone-Steuerung hängen sich später an dieselbe Tabelle.

---

## 1. Befund mit Quellen

| Frage | Antwort | Beleg |
|:--|:--|:--|
| Gibt es App Intents (`AppIntent`, `AppShortcutsProvider`, `AppShortcut`, `AppShortcutPhrase`, `openAppWhenRun`) auf tvOS? | **Ja, seit tvOS 16** (API-Verfügbarkeit). `supportedModes` ab tvOS 26. `ShortcutsLink` gibt es auf tvOS **nicht**. | Apple-Doku: [AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider), [AppIntent](https://developer.apple.com/documentation/appintents/appintent), [AppShortcutPhrase](https://developer.apple.com/documentation/appintents/appshortcutphrase), [openAppWhenRun](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun), [ShortcutsLink](https://developer.apple.com/documentation/appintents/shortcutslink) (ohne tvOS) |
| Ruft Siri auf dem Apple TV (Siri-Taste) solche Phrasen auf? | **Nicht dokumentiert, nach Berichten nein.** Apples Siri-Anleitung für tvOS 27 nennt Apps öffnen, Inhalte suchen und abspielen, Live-TV, Musik, Home und Wissensfragen, aber keine Befehle innerhalb von Apps und keine Kurzbefehle. Entwicklerforum: App Intents auf tvOS, `perform()` wird nie aufgerufen (April 2026, ohne Antwort). Live-TV-App: Siri löst eigene Intents und Shortcuts auf tvOS nicht auf (Juli 2026, ohne Apple-Antwort). Der Entwickler von Channels: „Siri Shortcuts do not work on tvOS“. | [Weitere Siri-Befehle auf Apple TV 4K (tvOS 27)](https://support.apple.com/en-ca/guide/tv/atvbb96a3e3f/27/tvos/27), [Siri auf dem Apple TV verwenden](https://support.apple.com/en-euro/105019), [Forum 821708](https://developer.apple.com/forums/thread/821708), [Forum 836636](https://developer.apple.com/forums/thread/836636), [Channels-Forum](https://community.getchannels.com/t/beta-siri-shortcuts/29107) |
| Ab welcher tvOS-Version könnte es gehen? | Keine Version ist belegt. In der tvOS-27.2-Simulator-Laufzeit liegen allerdings `linkd`, `remoteappintentsd`, `siriactionsd`, `VoiceShortcuts.framework`, `WorkflowKit.framework` und das Siri-Plugin `SiriLinkFlowPlugin.bundle` (auf iOS führt es App Shortcuts aus). Die Technik ist also auf dem System. Ob Siri auf dem Apple TV sie für Drittanbieter-Phrasen nutzt, zeigt nur ein Gerätetest. | eigene Prüfung im Simulator-Laufzeitordner (Abschnitt 3) |
| WWDC 2026 | Die Siri-Sessions (App Schemas, Apple Intelligence, „Siri AI“) behandeln iOS. tvOS und Apple TV kommen darin nicht vor. Siri AI ist laut Berichten auf keinem aktuellen Apple TV verfügbar. | [WWDC26 Session 240 „Build intelligent Siri experiences with App Schemas“](https://developer.apple.com/videos/play/wwdc2026/240/) |
| SiriKit auf tvOS: welche Domänen? | **Nur Medien** (ab tvOS 14): `INPlayMediaIntent`, dazu `INSearchForMediaIntent` und `INAddMediaIntent`. Umsetzung über eine Intents-Erweiterung, auf tvOS mit `.continueInApp` (App startet im Vordergrund). Beispiel: „Spiele X in App Y“. Für Browserbefehle ungeeignet: Siri leitet dorthin nur Medienwünsche („spiele …“). Ein Missbrauch als Befehlskanal wäre unzuverlässig und widerspricht der Domäne. Andere Domänen (Nachrichten, Anrufe usw.) gibt es auf tvOS nicht. | [SiriKit](https://developer.apple.com/documentation/sirikit) (tvOS 14), [INPlayMediaIntent](https://developer.apple.com/documentation/intents/inplaymediaintent) (tvOS 14), [WWDC20 „Expand your SiriKit Media Intents to more platforms“](https://developer.apple.com/videos/play/wwdc2020/10061/) |
| Gibt es die Kurzbefehle-App auf tvOS? | **Nein.** Es gibt aber Kurzbefehle **auf dem iPhone**, die ein Apple TV steuern: „Apple TV aufwecken/ruhen“, „Play/Pause“, „App auf Apple TV öffnen“, „Fernbedienung zeigen“. Eigene Befehle in einer App gehören nicht dazu. | [Cassinelli: Apple-TV-Kurzbefehle](https://matthewcassinelli.com/apple-tv-apps-shortcuts/), [Aktion „Wake Apple TV“](https://matthewcassinelli.com/actions/wake-apple-tv/) |
| Siri-Befehle für Medien | Pause, Spulen („10 Sekunden zurück“), Untertitel an und „Was hat er gesagt?“ gelten laut Apple für Videos im **System-Player**. `AVPlayerViewController` unterstützt sie, sofern die Metadaten des `AVPlayerItem` gesetzt sind. Eigene Player bekommen nur das, was über `MPRemoteCommandCenter` läuft. | [AVPlayerViewController](https://developer.apple.com/documentation/avkit/avplayerviewcontroller), [Apple TV: Wiedergabe mit Siri steuern](https://support.apple.com/guide/tv/atvbd4af2c21/tvos), [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter) |
| Hat die App Zugriff auf das Siri-Mikrofon der Fernbedienung? | **Nein.** Apps bekommen nur den fertigen Text: über das Diktat in ein Textfeld (Siri-Taste halten, während ein Feld aktiv ist) oder über Siri-Suchen. Rohes Audio von der Fernbedienung gibt es nicht. `SFSpeechRecognizer` fehlt auf tvOS. Ab tvOS 17 gibt es `AVCaptureDevice` (Kamera und Mikrofon des iPhone per Continuity), ab tvOS 26 `SpeechAnalyzer`. Damit wäre eigene Spracherkennung über das iPhone-Mikrofon denkbar, für Befehle aber viel zu umständlich. | [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer) (ohne tvOS), [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) (tvOS 26), [AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice) (tvOS 17) |
| Objective-C-Projekt und App Intents | App Intents verlangt **Swift**, weil die Metadaten zur Bauzeit aus Swift-Typen gelesen werden (`appintentsmetadataprocessor`). Eine einzelne Swift-Datei im Obj-C-Target genügt. Nötig ist nur `SWIFT_VERSION` im Target, **kein Bridging-Header**: Der Intent schickt eine `NSNotification`, die Obj-C-Seite beobachtet sie. Die Swift-Laufzeit ist ab tvOS 12.2 im System, die App wird dadurch nicht größer (Binary 1,2 MB, keine eingebetteten Swift-Bibliotheken). | Spike, Abschnitt 3 |

**Folgerung:** Eine Siri-Steuerung mit eigenen Phrasen über die Siri-Taste ist auf tvOS **nicht verlässlich möglich**. Wenn überhaupt, dann undokumentiert und erst nach einem Gerätetest. Die Schnittstelle kostet aber wenig (eine Swift-Datei). Sie kann deshalb im Projekt bleiben und bei einem späteren tvOS-Update einfach wieder geprüft werden.

---

## 2. Bewertung der Wege

| Weg | Funktioniert sicher? | Aufwand | Nutzen | Bewertung |
|:--|:--|:--|:--|:--|
| **Siri-Taste mit App Shortcuts** („Reader in tvOS Browser starten“) | nein (siehe oben), Gerätetest offen | Spike fertig, Rest ca. 0,5 Tag | wäre ideal | Spike behalten, Gerätetest machen, sonst ruhen lassen |
| **(a) Diktat im Adressfeld** („Reader“, „zurück“, „neuer Tab“) | **ja**: Das Diktat liefert schon heute Text ins Feld, und die App wertet ganze Sätze sofort aus | 1 bis 1,5 Tage inkl. Befehlstabelle | hoch, ein Griff: Siri-Taste halten, sprechen | **empfohlen, zuerst** |
| **(b) iPhone-Kurzbefehle über das Netzwerk** | ja, solange die App im Vordergrund ist | 2 bis 3 Tage inkl. Kopplung | echte Siri-Phrasen („Hey Siri, Reader am Fernseher“) über das iPhone, Bedienung vom Sofa | später, optional |
| **(c) Medienbefehle über Siri** | ja für den nativen Player, teilweise für Webvideos | klein, das meiste ist schon da | Pause, Spulen, Untertitel, „Was hat er gesagt?“ | parallel prüfen und pflegen |
| SiriKit Media (`INPlayMediaIntent`) | nur für „spiele …“ | 1 Tag plus Erweiterungs-Target | gering für einen Browser | nicht weiterverfolgen |

### (a) Sprachbefehle über das Diktatfeld

Der Weg: Play/Pause halten (heute schon) oder das Adressfeld öffnen, dann die Siri-Taste halten und sprechen. tvOS setzt den erkannten Satz auf einmal ins Feld. `searchFieldDidChange:` in `ViewController.m` und die Startansicht (`BrowserStartViewController.m`) erkennen das bereits und lösen sofort aus. Vor `openAddressOrSearch:` kommt neu ein Abgleich mit der Befehlstabelle:

- **Nur kurze, ganze Sätze** gelten als Befehl („Reader“, „Reader an“, „zurück“, „neuer Tab“, „neu laden“, „Tabs“, „Favorit“). Groß- und Kleinschreibung, Satzzeichen am Ende und Füllwörter wie „bitte“ werden ignoriert. Alles andere bleibt Suche oder Adresse wie bisher.
- **Präfixe** für Eindeutigkeit: „suche [nach] X“ und „google X“ suchen immer, „öffne X“ und „geh zu X“ öffnen immer eine Adresse. Wer wirklich nach dem Wort „Reader“ suchen will, sagt „suche Reader“.
- **Rückmeldung:** kurze Einblendung („Befehl: Reader an“), damit klar ist, dass nicht gesucht wurde.
- Platzhalter im Feld: „Sprechen, um zu diktieren, z. B. ‚Reader‘ oder ‚neuer Tab‘“. Die Leiste wird gerade umgebaut, deshalb mit dem zuständigen Zweig abstimmen.
- Grenzen: Das Diktat muss in den tvOS-Einstellungen an sein. Seine Sprache folgt der Siri-Sprache. Ohne Textfeld gibt es kein Diktat, also immer erst das Feld öffnen. Das bleibt ein Schritt mehr als bei echtem Siri.

### (b) Steuerung vom iPhone (Kurzbefehle → Befehls-Server in der App)

- In der App läuft ein `NWListener` (TCP, kleines HTTP), angekündigt per Bonjour (`_tvbrowser._tcp`) und **nur aktiv, solange die App im Vordergrund ist**. tvOS hält Apps im Hintergrund an, und der DNS-Proxy zeigt das schon (siehe `SceneDelegate.m`).
- Auf dem iPhone ein Kurzbefehl mit „Inhalte von URL abrufen“: `POST http://<AppleTV-Name>.local:<Port>/command` mit `{"command":"reader"}` und dem Token im Header. Siri auf dem iPhone, der Watch oder dem HomePod (persönliche Anfragen) startet den Kurzbefehl mit beliebiger Phrase. Das ist die einzige Variante mit echten eigenen Siri-Phrasen.
- **Sicherheit:** Kopplung per Code oder QR-Code auf dem Fernseher, ein zufälliges Token (32 Byte) im Schlüsselbund, Vergleich in konstanter Zeit, nur Befehle aus der Tabelle (kein beliebiges JavaScript), `address` nur für http/https, Ratenbegrenzung, Antwort ohne Seiteninhalte. Lauscht nur im lokalen Netz, Abschalten im Menü. Info.plist: `NSLocalNetworkUsageDescription` und `NSBonjourServices` vorsehen, je nachdem, was tvOS 27 verlangt.
- Aufwand 2 bis 3 Tage: Server, Kopplungsdialog, fertige Kurzbefehle als iCloud-Links zum Teilen, Tests. Risiko: Die App muss offen sein, und der feste Port kann belegt sein (dann den nächsten nehmen und in der Kopplung anzeigen).
- Nebenbefund: In der tvOS-Laufzeit liegt `remoteappintentsd`. Ob iPhone-Kurzbefehle künftig App Intents einer Apple-TV-App direkt ausführen können, ist nicht dokumentiert. Nach jedem tvOS-Update kurz in der Kurzbefehle-App prüfen, ob unter „Apple TV“ Aktionen der App auftauchen.

### (c) Medienbefehle

- **Nativer Player** (`BrowserNativeVideoPlayerViewController`, `AVPlayerViewController`): Siri-Befehle wie Pause, „30 Sekunden zurück“, „Untertitel an“ und „Was hat er gesagt?“ funktionieren laut Apple dort, wenn `AVPlayerItem.externalMetadata` (Titel usw.) gesetzt ist. Zu tun: Titel und Seite als Metadaten setzen und am Gerät prüfen. Für „Was hat er gesagt?“ braucht es eine Untertitelspur (Phase 3, Whisper).
- **Webvideos** (in der Seite): `BrowserNowPlayingController` meldet Play, Pause, Skip ±, Position, Weiter und Zurück schon an `MPRemoteCommandCenter`. Siri-„Pause“ und „Spul vor“ landen dort, sofern tvOS die App als Now-Playing-App führt. Neu wäre `enableLanguageOptionCommand` für „Untertitel an“ (Webvideos mit Textspuren). „Was hat er gesagt?“ geht für Webvideos nicht zuverlässig, dafür an den nativen Player übergeben.

---

## 3. Spike (auf diesem Zweig)

### 3.1 Was gebaut wurde

- `_Project/Browser/BrowserAppIntents.swift`
  - `ToggleReaderIntent`: „Reader umschalten“, `openAppWhenRun = true`, schickt den Befehl `reader`.
  - `OpenAddressIntent`: Parameter `address` (String), Siri fragt nach, wenn er fehlt. Schickt `address` mit Argument.
  - `BrowserCommandIntent` mit `AppEnum` `BrowserSimpleCommand` (back, forward, reload, newtab, tabs, favorite, home), damit eine Phrase mit Platzhalter für alle einfachen Befehle reicht.
  - `BrowserAppShortcuts: AppShortcutsProvider` mit deutschen Phrasen: „Reader in \(.applicationName) starten“, „Starte den Reader in …“, „Adresse in … öffnen“, „\(\.$command) in …“. App-Shortcut-Phrasen erlauben keine freien String-Parameter, deshalb fragt `OpenAddressIntent` per Dialog nach.
  - Brücke: `NotificationCenter.post(name: "BrowserSiriCommandNotification", userInfo: ["command", "argument", "source"])`, ohne Bridging-Header.
- `_Project/Browser/AppShortcuts.xcstrings`: Phrasen auf Deutsch und Englisch. Die Entwicklungssprache des Projekts ist Englisch, ohne `de` wären die Phrasen nur für englisches Siri registriert. Dafür kam `de` zu `knownRegions` hinzu. **Nebenwirkung:** Das App-Paket hat jetzt `de.lproj` und `en.lproj`. Auf einem deutschen Apple TV nutzt die App deshalb deutsche Systemtexte (z. B. Standardknöpfe von UIKit/AVKit). Die eigenen Texte ändern sich nicht.
- `ViewController.m` (nur hinzugefügt): Beobachter `handleSiriCommandNotification:`. Er bildet `back/forward/reload/home/tabs/favorite` auf `performTopBarAction:` ab, `newtab` auf `browserCreateNewTabLoadingHomePage:` und `address` auf `openAddressOrSearch:` (ohne Argument: Adressdialog). `reader` wird nur geloggt, den Reader-Knopf baut ein anderer Zweig. Dazu der Selbsttest-Schritt `siri:<befehl>` bzw. `siri:<befehl>|<argument>`.
- Projekt: `SWIFT_VERSION = 5.0` im App-Target, Swift-Datei über `tools/add_source.py` eingetragen.

### 3.2 Ergebnisse

| Prüfung | Ergebnis |
|:--|:--|
| Baut das Projekt mit Swift (Debug, Simulator)? | **ja**, ohne neue Warnungen |
| Release für das Gerät (`generic/platform=tvOS`, unsigniert) | **ja**. Binary 1,2 MB, linkt `AppIntents.framework` und die System-Swift-Bibliotheken, nichts eingebettet |
| Metadaten-Extraktion (`appintentsmetadataprocessor`) | **ja**: `Metadata.appintents/extract.actionsdata` mit 3 Actions, 1 Enum und 3 App Shortcuts mit 7 Phrasen. `ValidateAppShortcutStringsMetadata` (`appshortcutstringsprocessor`) prüft die `.xcstrings` ohne Fehler |
| Registriert das System die Shortcuts? (eigener Simulator „Siri-Spike“, Apple TV 4K 3. Gen., tvOS 27.2) | **ja**: `linkd` meldet nach der Installation „Loading metadata … extract.actionsdata“, „Writing combined metadata to index“, „Completed indexing“ und `LNMetadataChangedNotification added: ["io.github.tvosbrowser.app"]` |
| Obj-C-Brücke | **ja**: Selbsttest `url:https://example.org;siri:reader;siri:address\|wikipedia.org;siri:back;siri:newtab;siri:tabs;siri:unbekannt` liefert für jeden Schritt `[Siri] Befehl …`, `reader` mit dem Platzhalter-Log, `unbekannt` mit „unbekannter Befehl“ |
| Auslösung per Siri im Simulator | **nicht prüfbar**. Der tvOS-Simulator hat keine Spracheingabe für Siri, und `simctl` kennt keinen Siri-Befehl. Der Zugriff auf den Simulator per Siri-Taste wurde nicht freigegeben (Nutzer abwesend) |
| Auslösung per Siri am Gerät | **offen**, Anleitung in 3.4 |

### 3.3 Logzeilen

- `[Siri] Intent -> Befehl <name> <arg>`: Swift-Seite, der Intent wurde vom System ausgeführt. **Das ist der Beweis für echte Siri-Auslösung.**
- `[Siri] Befehl <name> arg=<…> quelle=appintent|selftest`: Obj-C-Seite
- `[SelfTest] siri <name>`: Selbsttest-Schritt

### 3.4 Gerätetest (klärt die Kernfrage)

1. Debug-Build aufs Apple TV (`Installieren.command --debug` oder Gerätezyklus aus `docs/ERWEITERUNGEN.md` 14.1). Siri-Sprache Deutsch.
2. App starten und 1 bis 2 Minuten warten, bis `linkd` indiziert hat. Konsole mitlaufen lassen (`devicectl … --console`).
3. In der App die Siri-Taste halten: „Reader in tvOS Browser starten“, dann „Neuer Tab in tvOS Browser“, „tvOS Browser zurück“.
4. Danach außerhalb der App (Home-Bildschirm) dasselbe probieren.
5. **Erfolg** = `[Siri] Intent -> Befehl reader` im Log. **Misserfolg** = Siri sucht, öffnet nur die App oder sagt, es könne das nicht. Ergebnis in diesem Dokument und in `PLAN.md` festhalten.
6. Falls „tvOS Browser“ schlecht erkannt wird: Kurznamen über `INAlternativeAppNames` in der `Info.plist` ergänzen (z. B. „Browser“) und erneut testen.

### 3.5 Spike entfernen (falls gewünscht)

`BrowserAppIntents.swift` und `AppShortcuts.xcstrings` aus Projekt und Ordner nehmen, `SWIFT_VERSION` und `de` in `knownRegions` entfernen. Den Beobachter in `ViewController.m` kann man lassen, er wird dann der Einstieg für die Befehlstabelle (Abschnitt 5).

---

## 4. Befehlsliste

Name = Schlüssel in der Befehlstabelle (auch für Selbsttest, Siri und iPhone). „Vorhanden“ = die Aktion gibt es heute schon in der App.

| Name | Diktat-Phrasen (Beispiele) | Aktion | Argument | Vorhanden |
|:--|:--|:--|:--|:--|
| `reader` | „Reader“, „Reader an/aus“, „Leseansicht“ | Reader umschalten | – | nein (anderer Zweig) |
| `address` | „öffne X“, „geh zu X“ | Adresse laden | Adresse | ja, `openAddressOrSearch:` |
| `search` | „suche [nach] X“, „google X“ | Suche | Begriff | ja, `googleSearchRequestForQuery:` |
| `back` / `forward` | „zurück“, „vor“, „weiter“ | Verlauf | – | ja, `performTopBarAction:` |
| `reload` | „neu laden“, „aktualisieren“ | Neu laden | – | ja |
| `home` | „Startseite“ | Startseite | – | ja |
| `newtab` | „neuer Tab“ | Neuer Tab | – | ja, `browserCreateNewTabLoadingHomePage:` |
| `closetab` | „Tab schließen“ | Tab schließen | – | ja (Tab-Übersicht) |
| `tabs` | „Tabs“, „Tab-Übersicht“ | Tab-Übersicht | – | ja, `browserShowTabOverview` |
| `favorite` | „Favorit“, „merken“ | Favorit umschalten | – | ja, `toggleFavoriteForCurrentPage` |
| `adblock-site-off` / `-on` | „Werbeblocker hier aus/an“ | Werbeblocker für diese Seite | – | ja, Menü (`adBlockMenuItem`) |
| `cookie-site-off` | „Cookie-Blocker hier aus“ | Cookie-Ablehner für diese Seite | – | ja, Menü |
| `nativeplayer` | „im Player abspielen“, „Video groß“ | Video im nativen Player | – | ja, `browserPlayVideoUnderCursorIfAvailable` |
| `subtitles-on` / `-off` | „Untertitel an/aus“ | Untertitel (nativer Player, später Whisper) | – | teilweise |
| `playpause` | „Pause“, „weiter abspielen“ | Video steuern | – | ja, `sendVideoCommand:` |
| `seek` | „30 Sekunden vor/zurück“ | Spulen | Sekunden (±) | ja, `seek:±N` |
| `zoom-in` / `zoom-out` | „größer“, „kleiner“ | Textgröße | – | ja (Menü) |
| `scroll-top` / `scroll-down` | „nach oben“, „runter“ | Scrollen | – | über JS einfach |
| `menu` | „Menü“ | Erweitertes Menü | – | ja, `showAdvancedMenu` |
| `help` | „Hilfe“ | Bedienungsdialog | – | ja, `browserShowHints` |
| `ask` | „frag wann wurde … vorgestellt“, „frage wer …“, „ask when …“ | Frag die Seite: passende Stelle markieren und zeigen | Frage | ja, `docs/ERWEITERUNGEN.md` Abschnitt 19.2 |

Sätze, die der Parser nicht kennt, prüft danach ein vorsichtiger Abgleich mit den Phrasen der Tabelle („geh eine Seite zurück“ → `back`, „lade die Seite nochmal“ → `reload`); ein unbekanntes Wort macht daraus immer eine Suche (`docs/ERWEITERUNGEN.md` Abschnitt 19.1).

---

## 5. Architektur: zentrale Befehlstabelle `BrowserCommand`

```
Siri (App Intent, Swift) ─┐
Diktat (Adressfeld)  ─────┤  Text/Name ─► BrowserCommandParser ─► BrowserCommand ─► BrowserCommandRouter ─► vorhandene Aktionen
Selbsttest cmd:<name>  ───┤                                                         (Host: ViewController)
iPhone (HTTP, Token)  ────┘
```

- **`BrowserCommand.h/.m`** (Obj-C, rein Foundation): eine statische Tabelle mit Einträgen `{name, titel, phrasen[], braucht Argument, nur bei Video, gefährlich}`. Sie ist die einzige Quelle für Namen und Phrasen. Die Siri-Phrasen in `AppShortcuts.xcstrings` müssen wegen der Bauzeit-Extraktion fest im Swift-Code stehen. Ein kleiner Test vergleicht beide.
- **`BrowserCommandParser`**: wandelt Diktattext in `(Befehl, Argument)` oder nil um. Normalisieren (Kleinschreibung, Satzzeichen, „bitte“), dann exakte Phrasen und Präfixe („suche“, „öffne“). Er läuft ohne UI und lässt sich deshalb im Selbsttest prüfen (`parse:<text>` loggt das Ergebnis).
- **`BrowserCommandRouter`** mit Host-Protokoll `BrowserCommandHost`, das der `ViewController` umsetzt (wie die anderen Koordinatoren): `- (BOOL)performCommand:(NSString *)name argument:(nullable NSString *)arg source:(BrowserCommandSource)source;`. Er loggt `[Command] name arg source ok|unbekannt|nicht möglich`, schließt vorher offene Dialoge und blendet eine kurze Rückmeldung ein.
- **Eingänge:**
  - Siri: Der Beobachter aus dem Spike (`handleSiriCommandNotification:`) ruft nur noch den Router auf.
  - Diktat: In `submitSearchAlert` bzw. beim Bestätigen der Startansicht kommt zuerst der Parser, im Treffer-Fall der Router statt der Suche.
  - Selbsttest: `cmd:<name>` bzw. `cmd:<name>|<arg>` (ersetzt `siri:`) und `parse:<text>`.
  - iPhone: Der HTTP-Handler ruft den Router mit `source = remote` auf. Gefährliche oder unbekannte Befehle lehnt er ab.
- Neue Funktionen (z. B. der Reader) melden sich nur mit einem Eintrag in der Tabelle und einem `case` im Host an. Siri, Diktat, Selbsttest und iPhone bekommen sie automatisch.

---

## 6. Aufwand und Schritte (Vorschlag für PLAN.md)

- [ ] Gerätetest Siri mit dem Spike (Abschnitt 3.4), Ergebnis hier und im Plan eintragen (0,5 h)
- [x] `BrowserCommand` (Tabelle), `BrowserCommandRouter` und Host-Protokoll im `ViewController`, Selbsttest `cmd:` (0,5 Tag)
- [x] Spike-Beobachter auf den Router umstellen, `reader` anbinden, sobald der Reader-Knopf auf main ist (1 h)
- [x] `BrowserCommandParser` mit Phrasen und Präfixen („suche“, „öffne“), Selbsttest `parse:` (0,5 Tag)
- [x] Diktat im Adressfeld: zuerst Parser, dann Suche; Rückmeldung einblenden, Platzhaltertext mit Beispielen; Bedienungsdialog ergänzen (0,5 Tag). Die alte Startansicht ist nicht mehr eingebunden und bleibt ohne Parser
- [ ] Am Gerät prüfen: Diktat „Reader“, „zurück“, „neuer Tab“, „suche Reader“, „öffne heise.de“ (1 h)
- [ ] Medien: `externalMetadata` im nativen Player setzen, Siri „Was hat er gesagt?“, „Untertitel an“ und „30 Sekunden zurück“ am Gerät prüfen; `enableLanguageOptionCommand` für Webvideos prüfen (0,5 Tag)
- [ ] Falls Siri am Gerät funktioniert: Phrasen und Intents aus der Tabelle vervollständigen, `INAlternativeAppNames` setzen (0,5 Tag). Falls nicht: Spike-Swift-Datei behalten (kostet nichts) und nach jedem großen tvOS-Update den Gerätetest wiederholen
- [ ] Optional: iPhone-Steuerung (Befehls-Server mit `NWListener` und Bonjour, Kopplung mit Token, fertige Kurzbefehle zum Teilen, Menüschalter) (2 bis 3 Tage)

Gesamt ohne iPhone-Steuerung: etwa 2,5 Tage, mit iPhone-Steuerung etwa 5 Tage.

---

## 7. Umsetzung: Sprachbefehle über das Diktat (Stand 8. November 2026)

Gebaut nach Abschnitt 5. Dateien: `BrowserCommand.m/.h` (Tabelle), `BrowserCommandParser.m/.h`, `BrowserCommandRouter.m/.h` (Router, Host-Protokoll `BrowserCommandHost`, Glas-Rückmeldung), Host und Einstieg `handleEnteredAddressText:` in `ViewController.m`. Siri (`handleSiriCommandNotification:`) geht jetzt ebenfalls über den Router; die Swift-Seite ist unverändert.

**Bedienung:** Adresse öffnen (zweimal oben oder Klick auf die Adresse), Feld anklicken bzw. Play/Pause, Siri-Taste halten und sprechen. Nach 1,5 s (Diktat) oder mit „Suchen“ wertet die App den Text aus. Erkannte Befehle zeigen unten eine Glas-Kapsel, z. B. „Reader eingeschaltet“. Der Platzhalter über der Tastatur lautet „Suchbegriff, Adresse oder z. B. „Reader““ (auf tvOS zeigt die Vollbild-Tastatur den Platzhalter groß an, den Dialogtext nicht). Im Bedienungsdialog steht eine Zeile „Sprachbefehle“.

| Name | Argument | Beispiele (Diktat) | Aktion |
|:--|:--|:--|:--|
| `reader` | an/aus/umschalten | „Reader“, „Lesemodus“, „Reader starten“, „Starte den Reader“, „Öffne den Reader“, „Reader aus“, „reader off“ | Reader-Knopf (`toggleReaderMode`); nicht lesbare Seite: Hinweis statt Aktion |
| `address` | optional Text | „Adresse“, „Favoriten“ | Adress-Bearbeiten mit Aufklapp-Bereich; mit Text (Siri) Adresse oder Suche |
| `search` | Text | „suche Wetter“, „Suche nach Reader“, „google heise.de“, „search for …“ | Google-Suche, auch wenn der Text wie ein Befehl oder eine Adresse aussieht |
| `open` | Text | „öffne heise.de“, „Öffne heise punkt de“, „gehe zu computerbase.de“, „open apple.com“ | Adresse laden (nur wenn X wie eine Adresse klingt, sonst normale Suche mit dem ganzen Satz) |
| `back` / `forward` | – | „zurück“, „geh zurück“, „go back“ / „vor“, „weiter“, „vorwärts“ | Verlauf |
| `reload` | – | „neu laden“, „aktualisieren“, „reload“ | Neu laden |
| `home` | – | „Startseite“, „home“ | Startseite |
| `newtab` / `closetab` | – | „neuer Tab“, „new tab“ / „Tab schließen“, „close tab“ | Tab öffnen bzw. aktuellen Tab schließen |
| `tabs` | – | „Tabs“, „Tab-Übersicht“, „alle Tabs“ | Tab-Übersicht |
| `favorite` | an/aus/umschalten | „Favorit“, „merken“, „zu Favoriten hinzufügen“, „Favorit entfernen“ | Stern der Leiste |
| `adblock-site` | an/aus/umschalten | „Werbeblocker aus“, „Werbeblocker hier an“, „Werbung zulassen“ | Ausnahme wie Menüpunkt „Werbeblocker hier“, danach neu laden |
| `top` / `down` / `up` | – | „nach oben“, „Seitenanfang“ / „runter“, „nach unten“ / „hoch“, „nach oben scrollen“ | Scrollen (Seitenanfang bzw. 80 % der Höhe) |
| `menu` | – | „Menü“, „Einstellungen“ | •••-Menü |
| `help` | – | „Hilfe“, „Bedienung“, „was kann ich sagen“ | Bedienungsdialog |
| `player` | – | „im Player abspielen“, „Video groß“ | Video der Seite im nativen Player (`openPageVideoInNativePlayer`) |
| `playpause` | an/aus/umschalten | „Pause“, „anhalten“ / „abspielen“, „weiter abspielen“ | Webvideo (unter dem Zeiger, sonst erstes sichtbares) |
| `seek` | Sekunden ± | „30 Sekunden zurück“, „spul zehn Sekunden vor“, „eine Minute zurück“, „zurückspulen“ (10 s) | Webvideo spulen |

**Nicht umgesetzt:** Untertitel an/aus (keine passende Aktion vorhanden; Untertitel kommen mit Phase 3), Schriftgröße, Cookie-Ablehner pro Seite.

**Konservativ:** Nur ganze Phrasen zählen. Geprüft (`parse:`) und bleiben Suche: „Reader Test Vergleich“, „Reader Test“, „zurück zur Zukunft“, „Tabs vs Spaces“, „neuer Tab Chrome“, „Hilfe bei Steuern“, „Lesemodus Safari“, „vor 10 Jahren“, „Tab“, „Pause Musik“, „Geh zu Wikipedia“, „open source software“, „Wetter Berlin“. Adressen („heise.de“, „https://example.org“) gehen nie an den Parser. Wer nach einem Befehlswort suchen will, sagt „suche Reader“.

**Test im Simulator** (eigenes Gerät „Cmd-Test“, Apple TV 4K 3. Gen., tvOS 27.2): 62 `parse:`-Fälle wie erwartet, jeder Befehl einmal per `cmd:` ausgelöst (Logzeile `[Command] … ok`), Diktatweg per `enter:` („Starte den Reader“ auf nicht lesbarer Seite → Hinweis, „Neu laden“ → reload, „suche Reader Test“ → Suche). Webvideo-Wiedergabe im Simulator ist unzuverlässig (auch direktes `play()` per JS startet nicht); Befehle kommen an, der native Player startet. Screenshots: `docs/command-screens/`.

**Grenzen:** Das Diktat muss in den tvOS-Einstellungen an sein und folgt der Siri-Sprache (Phrasen sind Deutsch und Englisch). Ein Schritt mehr als echtes Siri: erst das Adressfeld öffnen. „google X“ sucht immer nach X („Google Maps“ wird also „Maps“). Nicht auf dem Gerät mit echter Spracheingabe geprüft (Diktat liefert dort evtl. andere Schreibweisen, z. B. Großschreibung oder Satzzeichen; die Normalisierung fängt die üblichen ab).

## 8. Grenzen

- Apps haben **keinen Zugriff auf das Mikrofon der Siri Remote**. Sprache kommt nur als fertiger Text über das Diktat in ein Textfeld.
- Siri auf dem Apple TV kennt für Drittanbieter-Apps nur: App öffnen, Inhalte suchen und abspielen (SiriKit Media, Video-Partnerprogramm) und Wiedergabesteuerung über den System-Player bzw. Now Playing. Eigene Phrasen sind dort nicht dokumentiert.
- Keine Kurzbefehle-App auf tvOS. Kurzbefehle vom iPhone erreichen eine App nur über das Netzwerk und nur, wenn sie im Vordergrund läuft.
- Diktat und Siri folgen der eingestellten Siri-Sprache. Die Befehlsphrasen brauchen Deutsch und Englisch.
- App-Shortcut-Phrasen erlauben keine freien Texte (nur `AppEntity` oder `AppEnum`). „Öffne heise.de“ ginge per Siri nur mit Rückfrage.
