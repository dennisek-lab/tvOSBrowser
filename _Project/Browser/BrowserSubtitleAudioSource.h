#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserSubtitleAudioSource;

/// Empfänger der Tonquelle (BrowserSubtitleController). Aufrufe kommen auf beliebigen Hintergrund-Queues.
@protocol BrowserSubtitleAudioSourceDelegate <NSObject>
/// 16 kHz, mono, float32. `mediaTime` ist die Videozeit des ersten Samples. `discontinuity`: Lücke/Sprung davor.
- (void)audioSource:(id<BrowserSubtitleAudioSource>)source
   didProduceSamples:(NSData *)samples
              atTime:(NSTimeInterval)mediaTime
       discontinuity:(BOOL)discontinuity;
/// Quelle kann nicht (mehr) liefern, `reason` ist für Nutzer und Log gedacht.
- (void)audioSource:(id<BrowserSubtitleAudioSource>)source didFailWithReason:(NSString *)reason;
@optional
/// Wie viele Sekunden Ton noch auf Auswertung warten (für Gegendruck bei vorausladenden Quellen).
- (NSTimeInterval)audioSourcePendingSeconds:(id<BrowserSubtitleAudioSource>)source;
/// YES, wenn der Zeitbereich schon ausgewertet ist (Quelle kann ihn überspringen).
- (BOOL)audioSource:(id<BrowserSubtitleAudioSource>)source isRangeCoveredFrom:(NSTimeInterval)start to:(NSTimeInterval)end;
@end

/// Tonquelle für die automatischen Untertitel. Umsetzungen:
/// - BrowserSubtitleAudioTapSource: MTAudioProcessingTap über AVAudioMix (Dateien wie MP4), liefert in Echtzeit.
/// - BrowserSubtitleHLSAudioSource: lädt und dekodiert Audio-Segmente der HLS-Playlist vor der Abspielposition.
@protocol BrowserSubtitleAudioSource <NSObject>
@property (nonatomic, weak, nullable) id<BrowserSubtitleAudioSourceDelegate> delegate;
/// YES: liefert vor der Abspielposition (größere Abschnitte sinnvoll). NO: liefert, was gerade läuft.
@property (nonatomic, readonly) BOOL deliversAhead;
/// Kurzname für Logs („tap“, „hls“).
@property (nonatomic, copy, readonly) NSString *kindName;
- (void)start;
- (void)stop;
/// Aktuelle Abspielposition (vom Hauptthread, etwa alle 0,25 s).
- (void)updatePlaybackTime:(NSTimeInterval)time rate:(float)rate;
@end

NS_ASSUME_NONNULL_END
