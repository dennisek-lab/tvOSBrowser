//
//  BrowserIntelligence.h
//  Browser
//
//  Fassade für die intelligenten Funktionen (PLAN.md Phase 6): Zusammenfassen, Spracherkennung,
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
};

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
/// YES, wenn der Hinweis erscheinen soll (fremde Sprache, sicher erkannt, kein Login, nicht abgelehnt, kein Proxy).
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

#pragma mark Sprache und Übersetzen

/// Prüft Sprache und Login der aktuellen Seite (kleines Skript, kein Readability).
- (void)languageInfoForWebView:(BrowserWebView *)webView completion:(void (^)(BrowserPageLanguageInfo *info))completion;

/// https://<host-mit-bindestrichen>.translate.goog/<pfad>?…&_x_tr_sl=auto&_x_tr_tl=<ziel>&_x_tr_hl=<ziel>.
/// nil bei Adressen ohne http(s), ohne Host, bei IP-Adressen und wenn die Seite schon über den Proxy läuft.
+ (nullable NSURL *)translationProxyURLForURL:(NSURL *)url targetLanguage:(NSString *)targetLanguage;
/// Läuft die Adresse schon über translate.goog?
+ (BOOL)isTranslationProxyURL:(nullable NSURL *)url;
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
