//
//  BrowserCommand.h
//  Browser
//
//  Zentrale Befehlstabelle (siehe docs/SIRI_STEUERUNG.md, Abschnitt 5): Name, Titel, Symbol,
//  Argumentart und Sprachphrasen (Deutsch und Englisch). Einzige Quelle für Befehlsnamen und
//  Phrasen; Siri (BrowserAppIntents.swift), Diktat, Selbsttest und später das iPhone nutzen sie.
//  Rein Foundation, ohne UI.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Woher ein Befehl kommt (für Log und Rückmeldung).
typedef NS_ENUM(NSInteger, BrowserCommandSource) {
    BrowserCommandSourceDictation,
    BrowserCommandSourceSiri,
    BrowserCommandSourceSelfTest,
    BrowserCommandSourceRemote,
};

/// Welche Art Argument ein Befehl nimmt.
typedef NS_ENUM(NSInteger, BrowserCommandArgument) {
    /// Kein Argument.
    BrowserCommandArgumentNone,
    /// Optional "on" oder "off"; ohne Argument wird umgeschaltet.
    BrowserCommandArgumentToggle,
    /// Freier Text (Suchbegriff, Adresse).
    BrowserCommandArgumentText,
    /// Sekunden mit Vorzeichen (z. B. "-10", "30").
    BrowserCommandArgumentSeconds,
};

@interface BrowserCommand : NSObject

/// Schlüssel, z. B. "reader", "adblock-site".
@property (nonatomic, readonly, copy) NSString *name;
/// Kurzer deutscher Titel (Log, Doku).
@property (nonatomic, readonly, copy) NSString *title;
/// SF Symbol für die Rückmeldung.
@property (nonatomic, readonly, copy) NSString *symbolName;
@property (nonatomic, readonly) BrowserCommandArgument argumentKind;
/// Nur sinnvoll, wenn die Seite ein Video hat.
@property (nonatomic, readonly) BOOL requiresVideo;
/// Ganze Phrasen (normalisiert, siehe BrowserCommandParser) → Argument ("" = keins).
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *phrases;
/// Präfixe für Befehle mit Textargument ("suche nach", "google"); normalisiert, längste zuerst.
@property (nonatomic, readonly, copy) NSArray<NSString *> *prefixes;

/// Alle Befehle in fester Reihenfolge.
+ (NSArray<BrowserCommand *> *)allCommands;
+ (nullable BrowserCommand *)commandNamed:(NSString *)name;

+ (NSString *)nameForSource:(BrowserCommandSource)source;

@end

NS_ASSUME_NONNULL_END
