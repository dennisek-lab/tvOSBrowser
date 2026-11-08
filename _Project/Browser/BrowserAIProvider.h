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

/// Eine Fundstelle für „Frag die Seite“ (ein Satz aus dem Seitentext).
@interface BrowserAIPassage : NSObject
@property (nonatomic, copy) NSString *text;
/// Laufende Nummer des Satzes im Text.
@property (nonatomic) NSUInteger index;
/// Gesamtwert (0…1, zum Sortieren).
@property (nonatomic) double score;
/// Anteil der Fragebegriffe (IDF-gewichtet), die im Satz oder knapp daneben stehen (0…1).
@property (nonatomic) double lexicalScore;
/// Kosinus Frage ↔ Satz im Satz-Embedding, -1 ohne Embedding.
@property (nonatomic) double semanticScore;
/// Satz passt zur Frageart (Datum bei „wann“, Zahl bei „wie viel“, Ort bei „wo“, Name bei „wer“).
@property (nonatomic) BOOL typeMatch;
@end

/// Ergebnis von „Frag die Seite“: Fundstellen, beste zuerst (leer, wenn nichts passt).
@interface BrowserAIAnswer : NSObject
@property (nonatomic, copy) NSString *question;
@property (nonatomic, copy) NSArray<BrowserAIPassage *> *passages;
/// Fragebegriffe (Lemmata, Zahlen) für das Log.
@property (nonatomic, copy) NSArray<NSString *> *questionTerms;
/// "datum", "zahl", "ort", "person" oder "allgemein".
@property (nonatomic, copy) NSString *questionType;
@property (nonatomic, copy, nullable) NSString *language;
@property (nonatomic, copy, nullable) NSString *questionLanguage;
@property (nonatomic, copy) NSString *method;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSUInteger candidateCount;
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

@optional

/// „Frag die Seite“: die Sätze des Texts, die die Frage am ehesten beantworten (höchstens maxResults, beste zuerst).
/// Leeres passages-Feld, wenn nichts passt; error nur bei zu kurzer Frage oder zu wenig Text. Completion auf dem Hauptthread.
- (void)findPassagesForQuestion:(NSString *)question
                         inText:(NSString *)text
                     maxResults:(NSUInteger)maxResults
                     completion:(void (^)(BrowserAIAnswer * _Nullable answer, NSError * _Nullable error))completion;

/// Kosinus des Satz-Embeddings zwischen text und jedem Beispiel (gleiche Reihenfolge). nil, wenn die Sprache des Texts
/// kein Satz-Embedding hat. cacheKey: Vektoren der Beispiele zwischenspeichern (z. B. "commands"). Completion auf dem Hauptthread.
- (void)sentenceSimilaritiesOfText:(NSString *)text
                        toExamples:(NSArray<NSString *> *)examples
                          cacheKey:(nullable NSString *)cacheKey
                        completion:(void (^)(NSArray<NSNumber *> * _Nullable similarities, NSString * _Nullable language))completion;

@end

NS_ASSUME_NONNULL_END
