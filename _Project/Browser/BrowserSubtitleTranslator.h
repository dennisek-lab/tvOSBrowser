#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Apples Übersetzung (BrowserAppleTranslator, online) für die automatischen Untertitel.
///
/// Ist die Untertitelsprache fest eingestellt und spricht das Video eine andere Sprache, erkennt whisper in der
/// gesprochenen Sprache, und die fertigen Sätze eines Abschnitts gehen hier gesammelt (ein Absatz mit einem Bereich je
/// Untertitel, der vorige Satz als Kontext davor) an Apple. Scheitert das oder dauert es zu lange, gilt ein Rückfall:
/// whisper übersetzt eine Weile wieder selbst (alter Weg), der Abschnitt bekommt den Originaltext bzw. wird neu
/// erkannt (Pipeline). Logpräfix `[Subtitles]` mit „Apple-Übersetzung“ bzw. „Rückfall whisper“.
///
/// Abschalten (Vergleichsmessung): `defaults write io.github.tvosbrowser.app SubtitlesNoAppleTranslation -bool YES`
/// bzw. Selbsttest `pref:SubtitlesNoAppleTranslation=YES`. Ohne Kontext: `SubtitlesTranslateNoContext`.
@interface BrowserSubtitleTranslator : NSObject

@property (class, nonatomic, readonly) BrowserSubtitleTranslator *sharedTranslator;

/// Holt einmal Apples Sprachpaare (asynchron über den Hauptthread). Mehrfacher Aufruf ist harmlos.
- (void)prepare;

/// Threadsicher. YES, wenn Apple von `source` nach `target` übersetzen kann, nicht abgeschaltet ist und gerade kein
/// Rückfall gilt. Sprachcodes wie whisper sie liefert („en“, „de“).
- (BOOL)canTranslateFrom:(NSString *)source to:(NSString *)target;

/// YES, solange nach einem Fehler whisper selbst übersetzt (threadsicher).
@property (atomic, readonly, getter=isSuspended) BOOL suspended;

/// Übersetzt die Texte in einer Anfrage (je Text ein Bereich, `context` als vorheriger Satz davor, nicht zurückgegeben).
/// `completion` genau einmal, auf einer beliebigen Queue: `translated` gleich lang wie `texts`, nie mit leeren Texten
/// (einzeln nicht übersetzbare bleiben im Original), oder nil mit `failure` (Fehler, offline, Zeit abgelaufen). Bei
/// nil gilt der Rückfall (siehe oben): nach einem Fehler sofort 60 s, nach verpasster Frist erst ab der zweiten in
/// Folge 20 s (eine einzelne liefert nil, Apple bleibt an). Verdächtig kurze oder fehlende Bereiche werden einzeln
/// nachgefragt; läuft die Frist dabei ab, kommt das Ergebnis der Hauptanfrage mit diesen Sätzen im Original.
- (void)translateTexts:(NSArray<NSString *> *)texts
                  from:(NSString *)source
                    to:(NSString *)target
               context:(nullable NSString *)context
               timeout:(NSTimeInterval)timeout
            completion:(void (^)(NSArray<NSString *> * _Nullable translated, NSString * _Nullable failure))completion;

/// Kennzahlen für die Stand-Zeile: „Apple-Übersetzung: N Anfragen, Ø … s, max … s, F Fehler/zu spät“.
- (NSString *)summary;

@end

NS_ASSUME_NONNULL_END
