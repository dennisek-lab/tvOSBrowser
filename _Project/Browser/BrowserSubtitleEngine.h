#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ein erkannter Untertitel mit Zeiten in Sekunden auf der Zeitachse des Videos.
@interface BrowserSubtitleCue : NSObject
@property (nonatomic, readonly) NSTimeInterval start;
@property (nonatomic, readonly) NSTimeInterval end;
@property (nonatomic, copy, readonly) NSString *text;
/// Bis wann der Untertitel sichtbar bleibt (wird von der Anzeige gesetzt, z. B. verlängert, wenn er spät ankam).
@property (nonatomic) NSTimeInterval visibleUntil;
/// Vorläufig (Mithören: Satz noch nicht zu Ende, wird durch den nächsten Durchlauf ersetzt).
@property (nonatomic) BOOL tentative;
/// Medienzeit, zu der der Untertitel zum ersten Mal sichtbar wurde (NAN = noch nie). Für die Versatzmessung.
@property (nonatomic) NSTimeInterval shownAt;
/// Sprache, in der whisper den Text erkannt hat (nil = unbekannt, z. B. Weg B ohne Engine).
@property (nonatomic, copy, nullable) NSString *language;
/// Gesetzt, wenn whisper in der gesprochenen Sprache erkannt hat und der Text noch per Apple in diese Sprache
/// übersetzt werden soll (BrowserSubtitleTranslator, in der Pipeline). nil = Text ist fertig.
@property (nonatomic, copy, nullable) NSString *translationTarget;
/// Bei übersetzten Untertiteln der erkannte Originaltext (Logs, Kontext), sonst nil.
@property (nonatomic, copy, nullable) NSString *originalText;
- (instancetype)initWithStart:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text;
/// Gleiche Zeiten und Zustände, neuer Text; `originalText` = bisheriger Text, `translationTarget` nil.
- (BrowserSubtitleCue *)cueWithTranslatedText:(NSString *)text;
@end

/// Dünne Hülle um whisper.cpp. Nicht threadsicher: alle Aufrufe auf derselben (Hintergrund-)Queue.
/// Logpräfix `[Subtitles]`.
@interface BrowserSubtitleEngine : NSObject

/// YES, wenn die App mit whisper.xcframework gebaut wurde (vendor/whisper.xcframework vorhanden).
+ (BOOL)isCompiledWithWhisper;
/// Ordner WhisperModels im App-Paket, nil wenn er fehlt.
+ (nullable NSString *)modelsDirectory;
/// Pfad des Modells im App-Paket (Ordner WhisperModels) für eine Sprache („auto“, „de“, „en“ …), nil wenn keins da ist.
/// „en“ nimmt bevorzugt ein .en-Modell, alles andere ein mehrsprachiges (notfalls das englische).
+ (nullable NSString *)modelPathForLanguage:(NSString *)language;
/// YES, wenn ein mehrsprachiges Modell im Paket liegt (dann sind „Automatisch“ und andere Sprachen möglich).
+ (BOOL)hasMultilingualModel;
/// Wählbare Sprachen für Menüs: „auto“ zuerst, dann gängige Sprachen (ISO 639-1, wie whisper sie kennt).
+ (NSArray<NSString *> *)selectableLanguages;
/// Deutscher Name: „auto“ → „Automatisch“, „de“ → „Deutsch“, unbekannt → Code.
+ (NSString *)displayNameForLanguage:(NSString *)language;
/// Speicherbedarf der App (phys_footprint) in MB, für Logs.
+ (double)currentMemoryFootprintMB;

- (instancetype)initWithModelPath:(NSString *)modelPath language:(NSString *)language NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Lädt das Modell (blockiert, ~0,3–1 s). Mehrfacher Aufruf ist harmlos.
- (BOOL)loadModel:(NSError * _Nullable * _Nullable)error;
/// Wertet 16-kHz-Mono-Samples aus; Zeiten der Ergebnisse sind `startTime` + Versatz im Abschnitt.
/// Blockiert. Gibt nil bei Fehler oder Abbruch zurück.
- (nullable NSArray<BrowserSubtitleCue *> *)transcribeSamples:(const float *)samples
                                                         count:(NSUInteger)count
                                                     startTime:(NSTimeInterval)startTime;
/// Bricht eine laufende Auswertung ab (threadsicher).
- (void)cancel;

@property (nonatomic, copy, readonly) NSString *modelName;
@property (nonatomic, copy, readonly) NSString *language;
@property (nonatomic, readonly, getter=isLoaded) BOOL loaded;
/// Summe Rechenzeit / Summe Audiodauer seit dem Laden (Echtzeitfaktor; < 1 heißt schneller als Echtzeit).
@property (nonatomic, readonly) double averageRealTimeFactor;
/// Zuletzt erkannte Sprache (bei „auto“), sonst die eingestellte.
@property (nonatomic, copy, readonly) NSString *detectedLanguage;

/// Bei „auto“: die Sprache, auf die sich die Erkennung festgelegt hat (sonst nil). Festgelegt wird einmal, sobald
/// zwei Abschnitte mit Sprache dieselbe Sprache ergeben (spätestens nach sechs: die häufigste); danach rechnet
/// whisper fest in dieser Sprache, damit sie nicht je Abschnitt springt. Threadsicher lesbar.
@property (atomic, copy, readonly, nullable) NSString *lockedLanguage;
/// Festlegung von außen übernehmen (z. B. aus einem früheren Lauf für dasselbe Video). Nur bei „auto“ wirksam.
- (void)lockLanguage:(NSString *)language;
/// Einmal beim Festlegen gerufen, auf der Queue der Auswertung (nicht beim Übernehmen per `lockLanguage:`).
@property (nonatomic, copy, nullable) void (^languageLockHandler)(NSString *language, NSUInteger speechWindows);

@end

NS_ASSUME_NONNULL_END
