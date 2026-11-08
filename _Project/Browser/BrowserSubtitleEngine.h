#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ein erkannter Untertitel mit Zeiten in Sekunden auf der Zeitachse des Videos.
@interface BrowserSubtitleCue : NSObject
@property (nonatomic, readonly) NSTimeInterval start;
@property (nonatomic, readonly) NSTimeInterval end;
@property (nonatomic, copy, readonly) NSString *text;
/// Bis wann der Untertitel sichtbar bleibt (wird von der Anzeige gesetzt, z. B. verlängert, wenn er spät ankam).
@property (nonatomic) NSTimeInterval visibleUntil;
- (instancetype)initWithStart:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text;
@end

/// Dünne Hülle um whisper.cpp. Nicht threadsicher: alle Aufrufe auf derselben (Hintergrund-)Queue.
/// Logpräfix `[Subtitles]`.
@interface BrowserSubtitleEngine : NSObject

/// YES, wenn die App mit whisper.xcframework gebaut wurde (vendor/whisper.xcframework vorhanden).
+ (BOOL)isCompiledWithWhisper;
/// Pfad des Modells im App-Paket (Ordner WhisperModels) für „en“ oder „auto“, nil wenn keins da ist.
+ (nullable NSString *)modelPathForLanguage:(NSString *)language;
/// YES, wenn ein mehrsprachiges Modell im Paket liegt (dann ist „Sprache automatisch“ möglich).
+ (BOOL)hasMultilingualModel;
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

@end

NS_ASSUME_NONNULL_END
