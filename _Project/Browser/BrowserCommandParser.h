//
//  BrowserCommandParser.h
//  Browser
//
//  Erkennt Sprachbefehle im diktierten oder getippten Text des Adressfelds (Deutsch, Englisch, Spanisch, Französisch;
//  immer alle Sprachen, unabhängig von der Oberflächensprache).
//  Konservativ: Nur ganze Phrasen aus der Befehlstabelle (BrowserCommand) gelten als Befehl,
//  dazu Präfixe für erzwungene Suche („suche X“, „google X“) und Adresse („öffne X“, „gehe zu X“)
//  sowie „30 Sekunden zurück“. Alles andere bleibt Suche oder Adresse. Ohne UI, im Selbsttest
//  mit parse:<text> prüfbar.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserParsedCommand : NSObject
@property (nonatomic, readonly, copy) NSString *name;
/// Argument ("on", "off", Suchbegriff, Adresse, Sekunden) oder nil.
@property (nonatomic, readonly, copy, nullable) NSString *argument;
/// Woran erkannt (Phrase oder Präfix), für das Log.
@property (nonatomic, readonly, copy) NSString *matchedPhrase;
@end

@interface BrowserCommandParser : NSObject

/// Befehl im Text oder nil (dann normal suchen bzw. Adresse laden).
+ (nullable BrowserParsedCommand *)parseText:(NSString *)text;

/// Kleinbuchstaben, Satzzeichen und Füllwörter („bitte“) weg, Bindestriche als Leerzeichen.
+ (NSString *)normalizedText:(NSString *)text;

/// Sieht der Text wie eine Adresse aus (ein Wort mit Punkt, Schema, localhost)? Adressen gehen nie an den Parser.
+ (BOOL)textLooksLikeAddress:(NSString *)text;

/// Wörter des Textes nach der Normalisierung, ohne Füllwörter.
+ (NSArray<NSString *> *)normalizedWordsOfText:(NSString *)text;

/// Gesprochene Adresse („heise punkt de“) als Adresse („heise.de“), sonst nil.
+ (nullable NSString *)addressFromSpokenText:(NSString *)text;

/// Eine Zeile für das Log: "reader|on (\"starte den reader\")" bzw. "keine -> Suche".
+ (NSString *)describeParseOfText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
