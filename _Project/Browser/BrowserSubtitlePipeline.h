#import <Foundation/Foundation.h>

#import "BrowserSubtitleAudioSource.h"
#import "BrowserSubtitleEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// Rechnet einen Abschnitt (16 kHz mono float) aus; `completion` genau einmal, auf beliebiger Queue, nil bei Abbruch.
typedef void (^BrowserSubtitleTranscriber)(NSData *samples, NSTimeInterval startTime,
                                           void (^completion)(NSArray<BrowserSubtitleCue *> * _Nullable cues));

/// Neue Untertitel (Hauptthread). `replaceFrom`: vorher gemeldete vorläufige Untertitel ab dieser Zeit ersetzen
/// (NAN = nur hinzufügen). `windowStart`/`windowEnd`: ausgewerteter Abschnitt.
typedef void (^BrowserSubtitlePipelineCueHandler)(NSArray<BrowserSubtitleCue *> *cues, NSTimeInterval replaceFrom,
                                                  NSTimeInterval windowStart, NSTimeInterval windowEnd);

/// Tonquelle → Abschnitte → Erkennung. Gemeinsam für den nativen Player (Weg A) und Videos in der Seite mit direkter
/// Adresse (Weg B). Logpräfix `[Subtitles]`.
///
/// Vorauslesende Quellen (MP4, HLS): Abschnitte von `windowSeconds` mit `overlapSeconds` Überlappung, der erste nach
/// Start/Sprung nur `firstWindowSeconds` (schneller erster Text). Geschnitten wird an der leisesten Stelle in den
/// letzten 1,5 s (Satzpause statt mitten im Wort). Abdeckung im 0,1-s-Raster verhindert Doppelungen.
///
/// Echtzeitquellen (Audio-Tap): Mithören. Alle `liveStepSeconds` wird der ganze noch offene Ton (ab dem letzten
/// fertigen Satz, höchstens `liveMaxWindowSeconds`) neu erkannt. Segmente, die mehr als `liveHoldbackSeconds` vor dem
/// Ende aufhören und nicht die letzten sind, gelten als fertig; der Rest ist vorläufig und wird beim nächsten
/// Durchlauf ersetzt. So erscheint Text etwa 1–1,5 s nach dem Sprechen statt nach Abschnittslänge + Rechenzeit.
///
/// Übersetzung: Untertitel, die die Engine mit `translationTarget` markiert (gesprochene Sprache ≠ Untertitelsprache),
/// gehen je Abschnitt bzw. Durchlauf als ein Stapel an Apple (BrowserSubtitleTranslator), der vorherige Originalsatz
/// als Kontext. Vorauslesend werden die Abschnitte in ihrer Reihenfolge übernommen, sobald ihre Übersetzung da ist.
@interface BrowserSubtitlePipeline : NSObject <BrowserSubtitleAudioSourceDelegate>

- (instancetype)initWithTranscriber:(BrowserSubtitleTranscriber)transcriber NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, copy, nullable) BrowserSubtitlePipelineCueHandler cueHandler;
/// Einmal je Lauf (Start/Sprung), sobald der erste Abschnitt ausgewertet ist (Hauptthread). Für das Startfenster.
@property (nonatomic, copy, nullable) void (^firstWindowHandler)(NSTimeInterval windowStart, NSTimeInterval windowEnd);
/// Quelle meldet einen Fehler (Hauptthread).
@property (nonatomic, copy, nullable) void (^failureHandler)(id<BrowserSubtitleAudioSource> source, NSString *reason);

/// Quelle anschließen (Delegate wird gesetzt, Puffer geleert, Takt nach `source.deliversAhead`).
- (void)attachSource:(id<BrowserSubtitleAudioSource>)source;
/// Quelle lösen, laufende Ergebnisse verfallen.
- (void)detachSource;
/// Angefangenen Abschnitt sofort auswerten (Pause).
- (void)flushPartial;
/// Abdeckung vergessen (z. B. Sprachwechsel: alles neu erkennen).
- (void)clearCoverage;

@property (nonatomic) NSTimeInterval windowSeconds;       // Standard 12 (vorauslesend)
@property (nonatomic) NSTimeInterval overlapSeconds;      // Standard 1,5
@property (nonatomic) NSTimeInterval firstWindowSeconds;  // Standard 4
@property (nonatomic) NSTimeInterval liveStepSeconds;       // Standard 1,0
@property (nonatomic) NSTimeInterval liveMaxWindowSeconds;  // Standard 8
@property (nonatomic) NSTimeInterval liveHoldbackSeconds;   // Standard 1,0
/// Apples Übersetzung (Untertitel mit `translationTarget`, siehe BrowserSubtitleTranslator): Frist vorauslesend
/// (Standard 4 s; whisper rechnet derweil weiter, bei Fehler erkennt whisper den Abschnitt noch einmal und übersetzt
/// selbst) bzw. beim Mithören und an der Live-Kante (Standard 0,5 s; danach Originaltext).
@property (nonatomic) NSTimeInterval translationTimeout;
@property (nonatomic) NSTimeInterval liveTranslationTimeout;

@property (nonatomic, readonly) BOOL live;
/// Kennzahlen (threadsicher gelesen).
@property (nonatomic, readonly) NSUInteger processedWindows;
@property (nonatomic, readonly) NSUInteger droppedWindows;
@property (nonatomic, readonly) NSUInteger pendingWindowCount;

@end

/// Eine Zeile Kennzahlen zu gemessenen Anzeigeversätzen (s): n, Median, min, max, max |Δ|, Anteil ≤ 1 s.
FOUNDATION_EXPORT NSString *BrowserSubtitleOffsetSummary(NSArray<NSNumber *> *offsets);

NS_ASSUME_NONNULL_END
