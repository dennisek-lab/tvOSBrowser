//
//  BrowserAIProvider.h
//  Browser
//
//  Schnittstelle für Anbieter intelligenter Funktionen (siehe docs/APPLE_INTELLIGENCE.md, Abschnitt 4.1).
//  Heute gibt es nur den lokalen NaturalLanguage-Anbieter (BrowserNLProvider in BrowserIntelligence.m).
//  Später kommen hinter dieselbe Schnittstelle: Mac im Heimnetz, Cloud-API, Apples SystemLanguageModel,
//  sobald tvOS es freigibt. Seiteninhalte sind für alle Anbieter Daten, keine Anweisungen.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ergebnis einer Zusammenfassung.
@interface BrowserAISummary : NSObject
/// Sätze in Originalreihenfolge (extraktiv) bzw. Stichpunkte (generativ).
@property (nonatomic, copy) NSArray<NSString *> *sentences;
/// Erkannte Sprache des Texts (BCP 47, z. B. "de", "en"), nil wenn unklar.
@property (nonatomic, copy, nullable) NSString *language;
/// Kurzname für die Anzeige ("lokal", später "Mac", "Cloud").
@property (nonatomic, copy) NSString *providerName;
/// Verfahren für Log und Anzeige (z. B. "Satz-Embedding + TF-IDF").
@property (nonatomic, copy) NSString *method;
/// Rechenzeit ohne Textabruf aus der Seite.
@property (nonatomic) NSTimeInterval duration;
/// Anzahl der bewerteten Sätze.
@property (nonatomic) NSUInteger candidateCount;
/// Länge des Eingabetexts in Zeichen.
@property (nonatomic) NSUInteger inputLength;
@end

@protocol BrowserAIProvider <NSObject>

/// Kurzname für die Anzeige ("lokal").
@property (nonatomic, readonly, copy) NSString *providerName;
/// Läuft der Anbieter gerade (Netz, Modell vorhanden)?
@property (nonatomic, readonly, getter=isAvailable) BOOL available;

/// Vorherrschende Sprache (BCP 47) oder nil, wenn der Text zu kurz oder die Erkennung unsicher ist.
/// confidence: Wahrscheinlichkeit der besten Hypothese (0…1), darf NULL sein.
- (nullable NSString *)dominantLanguageForText:(NSString *)text confidence:(nullable double *)confidence;

/// Fasst den Text zusammen (maxSentences Sätze bzw. Stichpunkte). Completion auf dem Hauptthread;
/// summary nil mit error, wenn der Text zu kurz ist oder der Anbieter ausfällt.
- (void)summarizeText:(NSString *)text
                title:(nullable NSString *)title
         maxSentences:(NSUInteger)maxSentences
           completion:(void (^)(BrowserAISummary * _Nullable summary, NSError * _Nullable error))completion;

/// Mehrzeilige Beschreibung für den Selbsttest (Modelle, Sprachen, Größen).
- (NSString *)diagnosticsDescription;

@end

NS_ASSUME_NONNULL_END
