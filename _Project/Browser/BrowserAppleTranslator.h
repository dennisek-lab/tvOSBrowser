//
//  BrowserAppleTranslator.h
//  Browser
//
//  Apples Übersetzung (Translation.framework) über die privaten ObjC-Klassen (_LT…), weil die öffentliche
//  Swift-API (TranslationSession) auf tvOS gesperrt ist. Die App ist privat, private APIs sind erlaubt.
//
//  Am Gerät geprüft (tvOS 27.2, siehe docs/ERWEITERUNGEN.md Abschnitt 19): translationd läuft, aus der App-Sandbox
//  ist nur dessen Textdienst com.apple.translation.text erreichbar (com.apple.translationd verweigert die Sandbox).
//  Über ihn gehen Sprachpaare, Spracherkennung und _LTParagraphTranslationRequest (online über Apples Server,
//  Offline-Modelle sind nicht installiert). Ein Absatz wird mit Bereichen (_LTTranslationRange, je Textknoten)
//  geschickt; die Antwort ordnet jedem Bereich seinen übersetzten Text zu (_LTAlignment).
//
//  BrowserPageTranslation übersetzt damit eine Seite direkt im DOM (PageTranslation/page-translation.js in eigener
//  WKContentWorld): Cookies und Anmeldung bleiben, „Übersetzung beenden“ stellt ohne Neuladen wieder her.
//

#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const BrowserAppleTranslatorErrorDomain;

typedef NS_ENUM(NSInteger, BrowserAppleTranslatorError) {
    BrowserAppleTranslatorErrorUnavailable = 1,   ///< Framework oder Textdienst fehlt
    BrowserAppleTranslatorErrorUnsupportedPair,   ///< Apple kann das Sprachpaar nicht
    BrowserAppleTranslatorErrorUnknownLanguage,   ///< Quellsprache nicht erkannt
    BrowserAppleTranslatorErrorNoText,            ///< Seite ohne übersetzbaren Text
    BrowserAppleTranslatorErrorTimeout,
    BrowserAppleTranslatorErrorPageGone,          ///< Seite gewechselt, Skript weg
};

@interface BrowserAppleTranslator : NSObject

@property (class, nonatomic, readonly) BrowserAppleTranslator *sharedTranslator;

/// YES, sobald der Textdienst Sprachpaare geliefert hat (prepareWithCompletion:). Vorher und ohne Dienst NO.
@property (nonatomic, readonly) BOOL available;

/// Holt einmal die Sprachpaare vom Textdienst (danach gemerkt). completion auf dem Hauptthread.
- (void)prepareWithCompletion:(nullable void (^)(BOOL available))completion;

/// Locales [Quelle, Ziel] für Sprachcodes ("en", "pt-BR", "zh-Hant"), nil wenn Apple das Paar nicht anbietet.
- (nullable NSArray<NSLocale *> *)localesForSourceLanguage:(NSString *)source targetLanguage:(NSString *)target;

/// Apples Spracherkennung, liefert den Sprachcode der vorherrschenden Sprache ("en") oder nil. Hauptthread.
- (void)detectLanguageOfTexts:(NSArray<NSString *> *)texts completion:(void (^)(NSString * _Nullable language))completion;

/// Übersetzt einen Absatz aus Teilen (je Textknoten ein Bereich). translated hat dieselbe Länge wie parts.
/// usedAlignment NO: Apple lieferte die Bereiche nicht vollständig, der ganze Satz steht im längsten Teil.
/// completion auf einer Hintergrundwarteschlange.
- (void)translateParts:(NSArray<NSString *> *)parts
                source:(NSLocale *)source
                target:(NSLocale *)target
            completion:(void (^)(NSArray<NSString *> * _Nullable translated, BOOL usedAlignment, NSError * _Nullable error))completion;

#if DEBUG
/// Selbsttest `ltprobe` (`ltprobe:dump` mit Klassen): Klassen und Schnittstellen am Gerät auslesen, Dienst prüfen,
/// en → de übersetzen. Alles ins Log mit Präfix "[LTProbe]".
- (void)runProbeDumpingClasses:(BOOL)dumpClasses;
#endif

@end

/// Übersetzung einer Seite im DOM (eine je WebView). Holt laufend Absätze aus der Seite (sichtbare zuerst,
/// nachgeladene über MutationObserver), übersetzt sie in Stapeln und schreibt die Texte zurück.
@interface BrowserPageTranslation : NSObject

/// source nil: Apple erkennt die Sprache an den ersten Absätzen.
- (instancetype)initWithWebView:(BrowserWebView *)webView
                 sourceLanguage:(nullable NSString *)sourceLanguage
                 targetLanguage:(NSString *)targetLanguage NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, readonly, nullable) BrowserWebView *webView;
/// Läuft (gestartet und nicht beendet, Seite noch da).
@property (nonatomic, readonly) BOOL active;
/// Tatsächlich verwendete Quellsprache (nach Erkennung), z. B. "en".
@property (nonatomic, copy, readonly, nullable) NSString *sourceLanguage;
@property (nonatomic, copy, readonly) NSString *targetLanguage;
/// Übersetzte und fehlgeschlagene Absätze bisher.
@property (nonatomic, readonly) NSUInteger translatedParagraphs;
@property (nonatomic, readonly) NSUInteger failedParagraphs;

/// Startet. firstBatch: ok YES, sobald der erste Stapel in der Seite steht; NO mit Fehler (dann ist alles
/// zurückgesetzt und die Übersetzung beendet, Rückfall Google möglich). Hauptthread.
- (void)startWithFirstBatchHandler:(void (^)(BOOL ok, NSError * _Nullable error))firstBatch;
/// Beendet die Übersetzung; restore YES setzt die Originaltexte zurück. completion(Anzahl zurückgesetzter Knoten).
- (void)stopRestoringOriginal:(BOOL)restore completion:(nullable void (^)(NSUInteger restored))completion;

#if DEBUG
/// Zustand aus der Seite für das Log (Absätze, Warteschlange, übersetzt, Fehler).
- (void)debugStateWithCompletion:(void (^)(NSString *state))completion;
- (void)debugBisect;
/// Selbsttest: auch Einzelteile mit Bereichen anfragen (alter Weg, der translationd auf github.com/login abstürzen ließ).
extern BOOL BrowserLTDebugForceRanges;
#endif

@end

NS_ASSUME_NONNULL_END
