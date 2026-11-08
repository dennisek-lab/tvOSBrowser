//
//  BrowserAppIntents.swift
//  Browser
//
//  Spike Siri-Steuerung (siehe docs/SIRI_STEUERUNG.md): App Intents und App Shortcuts.
//  Die Intents führen nichts selbst aus, sondern schicken einen Befehlsnamen per
//  NSNotificationCenter an die Obj-C-Seite (ViewController, Beobachter auf
//  "BrowserSiriCommandNotification", userInfo "command" und optional "argument").
//  So braucht das Projekt keinen Bridging-Header: Swift sieht nur Foundation.
//

import AppIntents
import Foundation

/// Name und Schlüssel müssen mit ViewController.m übereinstimmen.
enum BrowserSiriBridge {
    static let notificationName = Notification.Name("BrowserSiriCommandNotification")
    static let commandKey = "command"
    static let argumentKey = "argument"
    static let sourceKey = "source"

    @MainActor
    static func send(_ command: String, argument: String? = nil) {
        var info: [String: Any] = [commandKey: command, sourceKey: "appintent"]
        if let argument, !argument.isEmpty {
            info[argumentKey] = argument
        }
        NSLog("[Siri] Intent -> Befehl %@ %@", command, argument ?? "")
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: info)
    }
}

/// Reader an/aus. Die eigentliche Funktion baut ein anderer Zweig; hier nur der Befehlsname.
struct ToggleReaderIntent: AppIntent {
    static let title: LocalizedStringResource = "Reader umschalten"
    static let description = IntentDescription("Schaltet die Leseansicht der aktuellen Seite an oder aus.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        BrowserSiriBridge.send("reader")
        return .result()
    }
}

/// Adresse oder Suchbegriff öffnen. Ohne Wert fragt Siri nach (requestValueDialog).
struct OpenAddressIntent: AppIntent {
    static let title: LocalizedStringResource = "Adresse öffnen"
    static let description = IntentDescription("Öffnet eine Adresse oder sucht nach einem Begriff.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Adresse oder Suchbegriff",
               requestValueDialog: IntentDialog("Welche Adresse oder welcher Suchbegriff?"))
    var address: String

    @MainActor
    func perform() async throws -> some IntentResult {
        BrowserSiriBridge.send("address", argument: address)
        return .result()
    }
}

/// Einfache Befehle ohne Parameter über eine feste Auswahl (AppEnum), damit eine einzige
/// Phrase mit Platzhalter reicht: „Zurück in tvOS Browser“, „Neuer Tab in …“.
enum BrowserSimpleCommand: String, AppEnum {
    case back, forward, reload, newtab, tabs, favorite, home

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Browser-Befehl"
    static let caseDisplayRepresentations: [BrowserSimpleCommand: DisplayRepresentation] = [
        .back: "Zurück",
        .forward: "Vor",
        .reload: "Neu laden",
        .newtab: "Neuer Tab",
        .tabs: "Tab-Übersicht",
        .favorite: "Favorit",
        .home: "Startseite",
    ]
}

struct BrowserCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Browser-Befehl ausführen"
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Befehl")
    var command: BrowserSimpleCommand

    @MainActor
    func perform() async throws -> some IntentResult {
        BrowserSiriBridge.send(command.rawValue)
        return .result()
    }
}

struct BrowserAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleReaderIntent(),
                    phrases: ["Reader in \(.applicationName) starten",
                              "Starte den Reader in \(.applicationName)",
                              "\(.applicationName) Reader"],
                    shortTitle: "Reader",
                    systemImageName: "doc.plaintext")
        AppShortcut(intent: OpenAddressIntent(),
                    phrases: ["Adresse in \(.applicationName) öffnen",
                              "In \(.applicationName) suchen"],
                    shortTitle: "Adresse öffnen",
                    systemImageName: "globe")
        AppShortcut(intent: BrowserCommandIntent(),
                    phrases: ["\(\.$command) in \(.applicationName)",
                              "\(.applicationName) \(\.$command)"],
                    shortTitle: "Browser-Befehl",
                    systemImageName: "command")
    }
}
