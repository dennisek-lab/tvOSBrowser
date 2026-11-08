#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ein Untertitel: Text für den Bereich [start, end) in Sekunden Medienzeit (video.currentTime).
@interface BrowserWebSubtitleCue : NSObject <NSCopying>

@property (nonatomic, readonly) NSTimeInterval start;
@property (nonatomic, readonly) NSTimeInterval end;
@property (nonatomic, readonly, copy) NSString *text;

+ (instancetype)cueWithStart:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text;
- (instancetype)initWithStart:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

/// Schmale Schnittstelle zur Spracherkennung für Untertitel (Weg B: Ton aus der Webseite).
///
/// Eingabe immer 16 kHz, mono, Float32 im Bereich −1…1 (das Format, das whisper.cpp erwartet).
/// `startTime` ist die Medienzeit des ersten Werts. Ein Wert entspricht `rate / 16000` Sekunden
/// Medienzeit; bei normaler Geschwindigkeit also 1/16000 s.
///
/// Aufrufe kommen von einer seriellen Hintergrund-Queue (nicht dem Hauptthread). `samples` gilt nur
/// während des Aufrufs: Wer asynchron arbeitet, muss die Werte kopieren. `completion` darf auf einer
/// beliebigen Queue aufgerufen werden, genau einmal, auch bei Fehlern (dann mit leerem Array).
/// Die Zeiten der Cues sind Medienzeit (also `startTime` plus Versatz im Abschnitt).
///
/// Abschnitte überlappen sich (siehe BrowserWebSubtitleController.overlapDuration). Der Aufrufer ersetzt
/// alle bisherigen Cues ab `startTime` durch die neuen; die Erkennung muss sich darum nicht kümmern.
@protocol BrowserSpeechRecognizing <NSObject>

- (void)transcribeSamples:(const float *)samples
                    count:(NSUInteger)count
                startTime:(NSTimeInterval)startTime
               completion:(void (^)(NSArray<BrowserWebSubtitleCue *> *cues))completion;

@optional
/// Bevorzugte Abschnittslänge und Überlappung in Sekunden (z. B. whisper: 3,0 und 0,5).
@property (nonatomic, readonly) NSTimeInterval preferredWindowDuration;
@property (nonatomic, readonly) NSTimeInterval preferredOverlapDuration;
/// Zusammenhang verwerfen (nach Spulen, Seitenwechsel, Videowechsel).
- (void)reset;
/// Kurzname für Logzeilen, z. B. "stub" oder "whisper base.en".
@property (nonatomic, readonly, copy) NSString *recognizerName;

@end

NS_ASSUME_NONNULL_END
