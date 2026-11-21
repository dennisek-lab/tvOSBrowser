//
//  BrowserIntelligence.h
//  Browser
//
//  Fassade für die intelligenten Funktionen: Zusammenfassen, Spracherkennung,
//  Übersetzen über den Google-Übersetzungs-Proxy (translate.goog). Rein Foundation, ohne UI;
//  Anzeige und Auslöser liegen in BrowserIntelligenceController.
//
//  Anbieter heute: lokal mit NaturalLanguage (Satz-Embedding, Tokenizer, Tagger, Spracherkennung).
//  Apples Sprachmodell (FoundationModels) ist auf tvOS 27.2 gesperrt, siehe docs/APPLE_INTELLIGENCE.md.
//

#import <Foundation/Foundation.h>
#import "BrowserAIProvider.h"

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BrowserIntelligenceErrorDomain;

typedef NS_ENUM(NSInteger, BrowserIntelligenceError) {
    BrowserIntelligenceErrorNoPage = 1,
    BrowserIntelligenceErrorNoText,
    BrowserIntelligenceErrorTooShort,
    BrowserIntelligenceErrorQuestionTooShort,
};

/// Ergebnis des Ähnlichkeitsabgleichs Diktat ↔ Befehlstabelle (nach BrowserCommandParser).
@interface BrowserCommandMatch : NSObject
/// Bester Befehl (Name und Argument wie in BrowserCommand), auch wenn er nicht ausgeführt wird.
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, copy, nullable) NSString *argument;
/// Ähnlichste Beispielphrase.
@property (nonatomic, copy, nullable) NSString *example;
/// Begriffe: IDF-gewichteter Kosinus zur besten Phrase (0…1) und Abstand zum besten anderen Befehl.
@property (nonatomic) double lexicalScore;
@property (nonatomic) double lexicalMargin;
/// Satz-Embedding: Kosinus und Abstand zum besten anderen Befehl, -1 ohne Embedding für die Sprache.
@property (nonatomic) double semanticScore;
@property (nonatomic) double semanticMargin;
/// Befehl laut Embedding (kann vom lexikalisch besten abweichen).
@property (nonatomic, copy, nullable) NSString *semanticName;
/// Inhaltswörter, die in keiner Phrase der Tabelle vorkommen („zukunft“ in „zurück zur Zukunft“).
@property (nonatomic, copy) NSArray<NSString *> *unknownWords;
@property (nonatomic) NSUInteger contentWordCount;
/// YES: oberhalb der Schwelle, Befehl ausführen. NO: Suche bleibt.
@property (nonatomic) BOOL accepted;
/// Kurzer Grund ("Begriffe", "Embedding", "knapp darunter", "unbekannte Wörter", "zu kurz" …).
@property (nonatomic, copy) NSString *reason;
- (NSString *)logDescription;
@end

/// Ergebnis der Prüfung, ob die Seite übersetzt werden sollte (Hinweis „Übersetzen?“).
@interface BrowserPageLanguageInfo : NSObject
/// Erkannte Sprache (NLLanguageRecognizer), nil wenn unsicher.
@property (nonatomic, copy, nullable) NSString *language;
@property (nonatomic) double confidence;
/// lang-Attribut der Seite (kann fehlen oder falsch sein).
@property (nonatomic, copy, nullable) NSString *declaredLanguage;
/// Seite hat ein Passwortfeld oder sieht nach Anmeldung aus.
@property (nonatomic) BOOL hasLogin;
@property (nonatomic) NSUInteger sampleLength;
/// YES, wenn der Hinweis erscheinen soll (fremde Sprache, sicher erkannt, nicht abgelehnt, kein Proxy; Login-Seiten
/// nur, wenn Apples Übersetzung bereitsteht, denn über Google gingen Anmeldung und Cookies verloren).
@property (nonatomic) BOOL shouldOfferTranslation;
/// Kurzer Grund für das Log ("fremd", "gleiche Sprache", "login", "abgelehnt", "proxy", "zu wenig Text" …).
@property (nonatomic, copy) NSString *reason;
@end

@interface BrowserIntelligence : NSObject

@property (class, nonatomic, readonly) BrowserIntelligence *sharedIntelligence;

/// Aktiver Anbieter (heute immer der NaturalLanguage-Anbieter).
@property (nonatomic, readonly) id<BrowserAIProvider> provider;

/// Sprache der Oberfläche/des Systems als Sprachcode ("de"), Ziel für Übersetzungen.
@property (class, nonatomic, readonly) NSString *systemLanguageCode;
/// Anzeigename einer Sprache in der Systemsprache ("en" → "Englisch").
+ (NSString *)displayNameForLanguage:(NSString *)language;

#pragma mark Zusammenfassen

/// Holt den Artikeltext (BrowserReaderMode textForWebView:, ~6.000 Zeichen) und fasst ihn zusammen.
/// info enthält title/site/source/total aus dem Reader. Completion auf dem Hauptthread.
- (void)summarizeWebView:(BrowserWebView *)webView
              completion:(void (^)(BrowserAISummary * _Nullable summary, NSDictionary<NSString *, id> * _Nullable info,
                                   NSError * _Nullable error))completion;

/// Anzahl der Sätze für einen Text mit candidateCount Kandidaten (4 bis 6).
+ (NSUInteger)summaryLengthForCandidateCount:(NSUInteger)candidateCount;

#pragma mark Sprachbefehle (Ähnlichkeit)

/// Zweite Stufe nach BrowserCommandParser: vergleicht den Text mit den Beispielphrasen der Befehlstabelle
/// (Satz-Embedding, Rückfall IDF-gewichtete Begriffe). match.accepted nur oberhalb vorsichtiger Schwellen;
/// match nil, wenn der Text gar nicht in Frage kommt (Adresse, ein Wort, sehr lang). Completion auf dem Hauptthread.
- (void)matchCommandForText:(NSString *)text completion:(void (^)(BrowserCommandMatch * _Nullable match))completion;

#pragma mark Frag die Seite

/// Holt den Seitentext (bis 30.000 Zeichen) und sucht die Sätze, die die Frage am ehesten beantworten (bis zu 3).
- (void)askQuestion:(NSString *)question
          inWebView:(BrowserWebView *)webView
         completion:(void (^)(BrowserAIAnswer * _Nullable answer, NSDictionary<NSString *, id> * _Nullable info,
                              NSError * _Nullable error))completion;

/// Markiert den Satz in der Seite (Glas-/Leucht-Hervorhebung, nach 10 s ausgeblendet) und scrollt hin.
/// result: found (NSNumber), how ("genau", "klein", "anfang+ende", "anfang", "ende"), spans, y; nil ohne Antwort.
- (void)highlightPassage:(NSString *)passage
               inWebView:(BrowserWebView *)webView
              completion:(nullable void (^)(NSDictionary<NSString *, id> * _Nullable result))completion;
/// Entfernt die Hervorhebung (sanft ausblenden).
- (void)clearPassageHighlightInWebView:(nullable BrowserWebView *)webView;

#pragma mark Sprache und Übersetzen

/// Prüft Sprache und Login der aktuellen Seite (kleines Skript, kein Readability).
- (void)languageInfoForWebView:(BrowserWebView *)webView completion:(void (^)(BrowserPageLanguageInfo *info))completion;

/// https://<host-mit-bindestrichen>.translate.goog/<pfad>?…&_x_tr_sl=auto&_x_tr_tl=<ziel>&_x_tr_hl=<ziel>.
/// nil bei Adressen ohne http(s), ohne Host, bei IP-Adressen und wenn die Seite schon über den Proxy läuft.
+ (nullable NSURL *)translationProxyURLForURL:(NSURL *)url targetLanguage:(NSString *)targetLanguage;
/// Läuft die Adresse schon über translate.goog?
+ (BOOL)isTranslationProxyURL:(nullable NSURL *)url;
/// Umkehrung von translationProxyURLForURL: Originaladresse einer translate.goog-Adresse (ohne _x_tr_-Parameter), sonst nil.
+ (nullable NSURL *)originalURLForTranslationProxyURL:(nullable NSURL *)url;
/// Host ohne "www." (Schlüssel für „nicht mehr fragen“).
+ (nullable NSString *)normalizedHostForURL:(nullable NSURL *)url;

/// „Übersetzen?“ für diesen Host nicht mehr anbieten (dauerhaft, NSUserDefaults).
- (void)declineTranslationForHost:(NSString *)host;
- (BOOL)translationDeclinedForHost:(nullable NSString *)host;
/// Liste der abgelehnten Hosts zurücksetzen.
- (void)resetDeclinedTranslations;

#pragma mark Selbsttest

/// Mehrzeilige Beschreibung: Anbieter, Embeddings de/en, Systemsprache.
- (NSString *)diagnosticsDescription;

@end

NS_ASSUME_NONNULL_END
