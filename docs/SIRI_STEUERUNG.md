# Sprachsteuerung der App: Siri, Diktat, iPhone (Konzept und Machbarkeit)

Stand: 8. November 2026, tvOS 27.2, Xcode 27.2. Wunsch: Man sagt etwa „Starte den Reader“, und die App führt die Aktion aus, als hätte man den Knopf gedrückt.

Kurz gesagt: **Siri auf dem Apple TV löst nach allem, was belegbar ist, keine eigenen Phrasen von Drittanbieter-Apps aus.** Die Schnittstellen (App Intents, App Shortcuts) gibt es auf tvOS zwar. Sie bauen, und das System registriert sie auch. Apple dokumentiert für Siri auf dem Apple TV aber keine App Shortcuts, und Entwickler berichten, dass Siri sie dort nicht aufruft. Die App enthält die App Intents trotzdem. Ob Siri sie am Gerät auslöst, zeigt der Gerätetest in Abschnitt 3.4. Umgesetzt ist der Weg, der sicher funktioniert: **Sprachbefehle über das Diktat im Adressfeld**, aufgebaut auf einer gemeinsamen Befehlstabelle `BrowserCommand` (Abschnitt 6). Die Siri-Intents laufen über dieselbe Tabelle.

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
| Objective-C-Projekt und App Intents | App Intents verlangt **Swift**, weil die Metadaten zur Bauzeit aus Swift-Typen gelesen werden (`appintentsmetadataprocessor`). Eine einzelne Swift-Datei im Obj-C-Target genügt. Nötig ist nur `SWIFT_VERSION` im Target, **kein Bridging-Header**: Der Intent schickt eine `NSNotification`, die Obj-C-Seite beobachtet sie. Die Swift-Laufzeit ist ab tvOS 12.2 im System, die App wird dadurch nicht größer (Binary 1,2 MB, keine eingebetteten Swift-Bibliotheken). | Abschnitt 3 |

**Folgerung:** Eine Siri-Steuerung mit eigenen Phrasen über die Siri-Taste ist auf tvOS **nicht verlässlich möglich**. Wenn überhaupt, dann undokumentiert und erst nach einem Gerätetest. Die Schnittstelle kostet aber wenig (eine Swift-Datei). Sie bleibt deshalb im Projekt und lässt sich nach jedem tvOS-Update erneut prüfen.

---

## 2. Bewertung der Wege

| Weg | Funktioniert sicher? | Nutzen | Stand in der App |
|:--|:--|:--|:--|
| **Siri-Taste mit App Shortcuts** („Reader in tvOS Browser starten“) | nein (siehe oben), am Gerät nicht belegt | wäre ideal | App Intents im Projekt (Abschnitt 3), Auslösung per Siri nicht belegt |
| **(a) Diktat im Adressfeld** („Reader“, „zurück“, „neuer Tab“) | **ja**: Das Diktat liefert Text ins Feld, und die App wertet ganze Sätze sofort aus | hoch, ein Griff: Siri-Taste halten, sprechen | **umgesetzt** (Abschnitt 6) |
| **(b) iPhone-Kurzbefehle über das Netzwerk** | ja, solange die App im Vordergrund ist | echte Siri-Phrasen („Hey Siri, Reader am Fernseher“) über das iPhone, Bedienung vom Sofa | nicht umgesetzt |
| **(c) Medienbefehle über Siri** | ja für den nativen Player, teilweise für Webvideos | Pause, Spulen, Untertitel, „Was hat er gesagt?“ | teilweise (Now Playing, Metadaten im nativen Player) |
| SiriKit Media (`INPlayMediaIntent`) | nur für „spiele …“ | gering für einen Browser | nicht umgesetzt |

### (a) Sprachbefehle über das Diktatfeld

Der Weg: Play/Pause halten (heute schon) oder das Adressfeld öffnen, dann die Siri-Taste halten und sprechen. tvOS setzt den erkannten Satz auf einmal ins Feld. Die Adresseingabe (`BrowserAddressInputController`) erkennt das und löst sofort aus. Vor `openAddressOrSearch:` steht ein Abgleich mit der Befehlstabelle:

- **Nur kurze, ganze Sätze** gelten als Befehl („Reader“, „Reader an“, „zurück“, „neuer Tab“, „neu laden“, „Tabs“, „Favorit“). Groß- und Kleinschreibung, Satzzeichen am Ende und Füllwörter wie „bitte“ werden ignoriert. Alles andere bleibt Suche oder Adresse wie bisher.
- **Präfixe** für Eindeutigkeit: „suche [nach] X“ und „google X“ suchen immer, „öffne X“ und „geh zu X“ öffnen immer eine Adresse. Wer wirklich nach dem Wort „Reader“ suchen will, sagt „suche Reader“.
- **Rückmeldung:** kurze Einblendung („Befehl: Reader an“), damit klar ist, dass nicht gesucht wurde.
- Grenzen: Das Diktat muss in den tvOS-Einstellungen an sein. Seine Sprache folgt der Siri-Sprache. Ohne Textfeld gibt es kein Diktat, also immer erst das Feld öffnen. Das bleibt ein Schritt mehr als bei echtem Siri.

### (b) Steuerung vom iPhone (Kurzbefehle → Befehls-Server in der App)

Nicht umgesetzt. Der Weg sähe so aus:

- In der App läuft ein `NWListener` (TCP, kleines HTTP), angekündigt per Bonjour (`_tvbrowser._tcp`) und **nur aktiv, solange die App im Vordergrund ist**. tvOS hält Apps im Hintergrund an, und der DNS-Proxy zeigt das schon (siehe `SceneDelegate.m`).
- Auf dem iPhone ein Kurzbefehl mit „Inhalte von URL abrufen“: `POST http://<AppleTV-Name>.local:<Port>/command` mit `{"command":"reader"}` und dem Token im Header. Siri auf dem iPhone, der Watch oder dem HomePod (persönliche Anfragen) startet den Kurzbefehl mit beliebiger Phrase. Das ist die einzige Variante mit echten eigenen Siri-Phrasen.
- **Sicherheit:** Kopplung per Code oder QR-Code auf dem Fernseher, ein zufälliges Token (32 Byte) im Schlüsselbund, Vergleich in konstanter Zeit, nur Befehle aus der Tabelle (kein beliebiges JavaScript), `address` nur für http/https, Ratenbegrenzung, Antwort ohne Seiteninhalte. Lauscht nur im lokalen Netz, Abschalten im Menü. In der Info.plist wären `NSLocalNetworkUsageDescription` und `NSBonjourServices` nötig.
- Grenzen: Die App muss offen sein, und ein fester Port kann belegt sein.
- Nebenbefund: In der tvOS-Laufzeit liegt `remoteappintentsd`. Ob iPhone-Kurzbefehle App Intents einer Apple-TV-App direkt ausführen können, ist nicht dokumentiert. Erkennbar wäre es daran, dass in der Kurzbefehle-App unter „Apple TV“ Aktionen der App auftauchen.

### (c) Medienbefehle

- **Nativer Player** (`BrowserNativeVideoPlayerViewController`, `AVPlayerViewController`): Siri-Befehle wie Pause, „30 Sekunden zurück“, „Untertitel an“ und „Was hat er gesagt?“ funktionieren laut Apple dort, wenn `AVPlayerItem.externalMetadata` (Titel usw.) gesetzt ist. Der Player setzt diese Metadaten. „Was hat er gesagt?“ braucht eine Untertitelspur.
- **Webvideos** (in der Seite): `BrowserNowPlayingController` meldet Play, Pause, Skip ±, Position, Weiter und Zurück schon an `MPRemoteCommandCenter`. Siri-„Pause“ und „Spul vor“ landen dort, sofern tvOS die App als Now-Playing-App führt. `enableLanguageOptionCommand` für „Untertitel an“ meldet die App nicht. „Was hat er gesagt?“ geht für Webvideos nicht zuverlässig, dafür an den nativen Player übergeben.

---

## 3. App Intents für Siri

### 3.1 Was gebaut wurde

- `_Project/Browser/BrowserAppIntents.swift`
  - `ToggleReaderIntent`: „Reader umschalten“, `openAppWhenRun = true`, schickt den Befehl `reader`.
  - `OpenAddressIntent`: Parameter `address` (String), Siri fragt nach, wenn er fehlt. Schickt `address` mit Argument.
  - `BrowserCommandIntent` mit `AppEnum` `BrowserSimpleCommand` (back, forward, reload, newtab, tabs, favorite, home), damit eine Phrase mit Platzhalter für alle einfachen Befehle reicht.
  - `BrowserAppShortcuts: AppShortcutsProvider` mit deutschen Phrasen: „Reader in \(.applicationName) starten“, „Starte den Reader in …“, „Adresse in … öffnen“, „\(\.$command) in …“. App-Shortcut-Phrasen erlauben keine freien String-Parameter, deshalb fragt `OpenAddressIntent` per Dialog nach.
  - Brücke: `NotificationCenter.post(name: "BrowserSiriCommandNotification", userInfo: ["command", "argument", "source"])`, ohne Bridging-Header.
- `_Project/Browser/AppShortcuts.xcstrings`: Phrasen auf Deutsch und Englisch. Die Entwicklungssprache des Projekts ist Englisch, ohne `de` wären die Phrasen nur für englisches Siri registriert. Dafür kam `de` zu `knownRegions` hinzu. **Nebenwirkung:** Das App-Paket hat jetzt `de.lproj` und `en.lproj`. Auf einem deutschen Apple TV nutzt die App deshalb deutsche Systemtexte (z. B. Standardknöpfe von UIKit/AVKit). Die eigenen Texte ändern sich nicht.
- `ViewController.m`: Beobachter `handleSiriCommandNotification:` gibt den Befehl an den Router (Abschnitt 6). Dazu der Selbsttest-Schritt `siri:<befehl>` bzw. `siri:<befehl>|<argument>`.
- Projekt: `SWIFT_VERSION = 5.0` im App-Target, Swift-Datei über `tools/add_source.py` eingetragen.

### 3.2 Ergebnisse

| Prüfung | Ergebnis |
|:--|:--|
| Baut das Projekt mit Swift (Debug, Simulator)? | **ja**, ohne neue Warnungen |
| Release für das Gerät (`generic/platform=tvOS`, unsigniert) | **ja**. Binary 1,2 MB, linkt `AppIntents.framework` und die System-Swift-Bibliotheken, nichts eingebettet |
| Metadaten-Extraktion (`appintentsmetadataprocessor`) | **ja**: `Metadata.appintents/extract.actionsdata` mit 3 Actions, 1 Enum und 3 App Shortcuts mit 7 Phrasen. `ValidateAppShortcutStringsMetadata` (`appshortcutstringsprocessor`) prüft die `.xcstrings` ohne Fehler |
| Registriert das System die Shortcuts? (eigener Simulator „Siri-Spike“, Apple TV 4K 3. Gen., tvOS 27.2) | **ja**: `linkd` meldet nach der Installation „Loading metadata … extract.actionsdata“, „Writing combined metadata to index“, „Completed indexing“ und `LNMetadataChangedNotification added: ["<Bundle-ID>"]` |
| Obj-C-Brücke | **ja**: Selbsttest `url:https://example.org;siri:reader;siri:address\|wikipedia.org;siri:back;siri:newtab;siri:tabs;siri:unbekannt` liefert für jeden Schritt `[Siri] Befehl …`, `unbekannt` mit „unbekannter Befehl“ |
| Auslösung per Siri im Simulator | **nicht prüfbar**. Der tvOS-Simulator hat keine Spracheingabe für Siri, und `simctl` kennt keinen Siri-Befehl. |
| Auslösung per Siri am Gerät | **nicht belegt**, Prüfanleitung in 3.4 |

### 3.3 Logzeilen

- `[Siri] Intent -> Befehl <name> <arg>`: Swift-Seite, der Intent wurde vom System ausgeführt. **Das ist der Beweis für echte Siri-Auslösung.**
- `[Siri] Befehl <name> arg=<…> quelle=appintent|selftest`: Obj-C-Seite
- `[SelfTest] siri <name>`: Selbsttest-Schritt

### 3.4 Gerätetest

1. Debug-Build aufs Apple TV (`Installieren.command --debug` oder Gerätezyklus aus `docs/ERWEITERUNGEN.md` 14.1). Siri-Sprache Deutsch.
2. App starten und 1 bis 2 Minuten warten, bis `linkd` indiziert hat. Konsole mitlaufen lassen (`devicectl … --console`).
3. In der App die Siri-Taste halten: „Reader in tvOS Browser starten“, dann „Neuer Tab in tvOS Browser“, „tvOS Browser zurück“.
4. Danach außerhalb der App (Home-Bildschirm) dasselbe probieren.
5. **Erfolg** = `[Siri] Intent -> Befehl reader` im Log. **Misserfolg** = Siri sucht, öffnet nur die App oder sagt, es könne das nicht.
6. Falls „tvOS Browser“ schlecht erkannt wird: Kurznamen über `INAlternativeAppNames` in der `Info.plist` ergänzen (z. B. „Browser“) und erneut testen.

### 3.5 App Intents entfernen

`BrowserAppIntents.swift` und `AppShortcuts.xcstrings` aus Projekt und Ordner nehmen, `SWIFT_VERSION` und `de` in `knownRegions` entfernen. Den Beobachter in `ViewController.m` kann man lassen.

---

## 4. Befehlsliste

Name = Schlüssel in der Befehlstabelle (auch für Selbsttest, Siri und iPhone). „Vorhanden“ = die Aktion gibt es heute schon in der App.

| Name | Diktat-Phrasen (Beispiele) | Aktion | Argument | Vorhanden |
|:--|:--|:--|:--|:--|
| `reader` | „Reader“, „Reader an/aus“, „Leseansicht“ | Reader umschalten | – | ja, `toggleReaderMode` |
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
| `subtitles-on` / `-off` | „Untertitel an/aus“ | Untertitel (nativer Player, Whisper) | – | teilweise |
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
iPhone (Konzept)  ────────┘
```

- **`BrowserCommand.h/.m`** (Obj-C, rein Foundation): eine statische Tabelle mit Einträgen `{name, titel, phrasen[], braucht Argument, nur bei Video, gefährlich}`. Sie ist die einzige Quelle für Namen und Phrasen. Die Siri-Phrasen in `AppShortcuts.xcstrings` müssen wegen der Bauzeit-Extraktion fest im Swift-Code stehen. Ein kleiner Test vergleicht beide.
- **`BrowserCommandParser`**: wandelt Diktattext in `(Befehl, Argument)` oder nil um. Normalisieren (Kleinschreibung, Satzzeichen, „bitte“), dann exakte Phrasen und Präfixe („suche“, „öffne“). Er läuft ohne UI und lässt sich deshalb im Selbsttest prüfen (`parse:<text>` loggt das Ergebnis).
- **`BrowserCommandRouter`** mit Host-Protokoll `BrowserCommandHost`, das der `ViewController` umsetzt (wie die anderen Koordinatoren): `- (BOOL)performCommand:(NSString *)name argument:(nullable NSString *)arg source:(BrowserCommandSource)source;`. Er loggt `[Command] name arg source ok|unbekannt|nicht möglich`, schließt vorher offene Dialoge und blendet eine kurze Rückmeldung ein.
- **Eingänge:**
  - Siri: Der Beobachter `handleSiriCommandNotification:` ruft nur noch den Router auf.
  - Diktat: `handleEnteredAddressText:` fragt zuerst den Parser, im Treffer-Fall den Router statt der Suche.
  - Selbsttest: `cmd:<name>` bzw. `cmd:<name>|<arg>`, `siri:<name>` und `parse:<text>`.
  - iPhone (nicht umgesetzt, Weg 2(b)): Ein HTTP-Handler riefe den Router mit `source = remote` auf. Gefährliche oder unbekannte Befehle würde er ablehnen.
- Neue Funktionen (z. B. der Reader) melden sich nur mit einem Eintrag in der Tabelle und einem `case` im Host an. Siri, Diktat und Selbsttest bekommen sie automatisch.

---

## 6. Umsetzung: Sprachbefehle über das Diktat (Stand 8. November 2026)

Gebaut nach Abschnitt 5. Dateien: `BrowserCommand.m/.h` (Tabelle), `BrowserCommandParser.m/.h`, `BrowserCommandRouter.m/.h` (Router, Host-Protokoll `BrowserCommandHost`, Glas-Rückmeldung), Host und Einstieg `handleEnteredAddressText:` in `ViewController.m`. Siri (`handleSiriCommandNotification:`) geht jetzt ebenfalls über den Router; die Swift-Seite ist unverändert.

**Bedienung:** Einmal auf die Leiste drücken (oder zweimal oben, Play/Pause halten). Die Systemtastatur öffnet sich direkt unter der Leiste und ist schon fokussiert. Dann die Siri-Taste halten und sprechen, kein weiterer Klick nötig. Nach 1,5 s (Diktat) oder mit „Suchen“ bzw. „Los“ wertet die App den Text aus. Erkannte Befehle zeigen unten eine Glas-Kapsel, z. B. „Reader eingeschaltet“. Der Platzhalter in der Suchzeile lautet „Suchbegriff oder Adresse“. Technik und Grenzen: `docs/ERWEITERUNGEN.md`, Abschnitt 13.1. Im Bedienungsdialog steht eine Zeile „Sprachbefehle“.

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

**Nicht umgesetzt:** Untertitel an/aus per Sprachbefehl, Schriftgröße, Cookie-Ablehner pro Seite.

**Konservativ:** Nur ganze Phrasen zählen. Geprüft (`parse:`) und bleiben Suche: „Reader Test Vergleich“, „Reader Test“, „zurück zur Zukunft“, „Tabs vs Spaces“, „neuer Tab Chrome“, „Hilfe bei Steuern“, „Lesemodus Safari“, „vor 10 Jahren“, „Tab“, „Pause Musik“, „Geh zu Wikipedia“, „open source software“, „Wetter Berlin“. Adressen („heise.de“, „https://example.org“) gehen nie an den Parser. Wer nach einem Befehlswort suchen will, sagt „suche Reader“.

**Test im Simulator** (eigenes Gerät „Cmd-Test“, Apple TV 4K 3. Gen., tvOS 27.2): 62 `parse:`-Fälle wie erwartet, jeder Befehl einmal per `cmd:` ausgelöst (Logzeile `[Command] … ok`), Diktatweg per `enter:` („Starte den Reader“ auf nicht lesbarer Seite → Hinweis, „Neu laden“ → reload, „suche Reader Test“ → Suche). Webvideo-Wiedergabe im Simulator ist unzuverlässig (auch direktes `play()` per JS startet nicht); Befehle kommen an, der native Player startet. Screenshots: `docs/command-screens/`.

**Grenzen:** Das Diktat muss in den tvOS-Einstellungen an sein und folgt der Siri-Sprache (Phrasen sind Deutsch und Englisch). Ein Schritt mehr als echtes Siri: erst das Adressfeld öffnen. „google X“ sucht immer nach X („Google Maps“ wird also „Maps“). Geprüft im Simulator mit eingesetztem Text. Echtes Diktat kann andere Schreibweisen liefern (Großschreibung, Satzzeichen), die Normalisierung fängt die üblichen ab.

## 7. Grenzen

- Apps haben **keinen Zugriff auf das Mikrofon der Siri Remote**. Sprache kommt nur als fertiger Text über das Diktat in ein Textfeld.
- Siri auf dem Apple TV kennt für Drittanbieter-Apps nur: App öffnen, Inhalte suchen und abspielen (SiriKit Media, Video-Partnerprogramm) und Wiedergabesteuerung über den System-Player bzw. Now Playing. Eigene Phrasen sind dort nicht dokumentiert.
- Keine Kurzbefehle-App auf tvOS. Kurzbefehle vom iPhone erreichen eine App nur über das Netzwerk und nur, wenn sie im Vordergrund läuft.
- Diktat und Siri folgen der eingestellten Siri-Sprache. Die Befehlsphrasen brauchen Deutsch und Englisch.
- App-Shortcut-Phrasen erlauben keine freien Texte (nur `AppEntity` oder `AppEnum`). „Öffne heise.de“ ginge per Siri nur mit Rückfrage.
