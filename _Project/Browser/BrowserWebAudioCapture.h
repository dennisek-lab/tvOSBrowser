#import <UIKit/UIKit.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

/// Zustand des Tonabgriffs aus der Webseite.
typedef NS_ENUM(NSInteger, BrowserWebAudioCaptureStatus) {
    BrowserWebAudioCaptureStatusIdle = 0,
    /// Befehl an die Seite geschickt, noch keine Antwort.
    BrowserWebAudioCaptureStatusStarting,
    /// AudioContext gesperrt, wartet auf Klick oder Abspielen (detail "gesture").
    BrowserWebAudioCaptureStatusWaitingForInteraction,
    /// Blöcke mit Ton kommen an.
    BrowserWebAudioCaptureStatusRunning,
    /// Seit einigen Sekunden nur Nullen. detail: "cors" (fremde Herkunft ohne Freigabe), "muted", "hls", "silence".
    BrowserWebAudioCaptureStatusSilent,
    /// Kein Video auf der Seite. detail "iframes:N", wenn Videos in iframes liegen könnten.
    BrowserWebAudioCaptureStatusNoVideo,
    /// Vorab abgelehnt, das Video wurde nicht angefasst. detail: "cors", "hls" (natives HLS ohne MSE) oder "drm".
    BrowserWebAudioCaptureStatusBlocked,
    /// Kein Web Audio in dieser WebKit-Version.
    BrowserWebAudioCaptureStatusUnsupported,
    /// Fehler, z. B. "source:InvalidStateError" (Seite nutzt das Video schon selbst mit Web Audio) oder "script".
    BrowserWebAudioCaptureStatusError,
    BrowserWebAudioCaptureStatusStopped,
};

/// Wiedergabestand des abgegriffenen Videos, wie ihn die Seite zuletzt gemeldet hat.
typedef struct {
    /// video.currentTime zum Zeitpunkt `hostTime`.
    NSTimeInterval mediaTime;
    /// CACurrentMediaTime() beim Eintreffen der Meldung (Bezug fürs Weiterzählen).
    CFTimeInterval hostTime;
    double rate;
    BOOL paused;
    BOOL seeking;
    BOOL fullscreen;
    /// Video-Rechteck in Koordinaten der BrowserWebView (Leisteneinschub und Scrollen berücksichtigt),
    /// CGRectNull, wenn unbekannt.
    CGRect videoRect;
} BrowserWebAudioPlaybackState;

/// Ein dekodierter Block: 16 kHz mono Float32, `mediaTime` = Medienzeit des ersten Werts.
typedef void (^BrowserWebAudioSampleHandler)(const float *samples, NSUInteger count, NSTimeInterval mediaTime);
typedef void (^BrowserWebAudioStatusHandler)(BrowserWebAudioCaptureStatus status, NSString *detail);
typedef void (^BrowserWebAudioPlaybackHandler)(BrowserWebAudioPlaybackState state);

/// Greift den Ton eines Videos in der Webseite ab (Web Audio im Seiten-Skript `WebSubtitles/web_audio_tap.js`,
/// Rückkanal `browserWebAudio`), dekodiert die Base64-Blöcke und führt einen Ringpuffer (30 s).
/// Eine Instanz bedient eine WebView zur Zeit; `startForWebView:` mit einer anderen WebView wechselt.
@interface BrowserWebAudioCapture : NSObject

/// Name des Rückkanals im Seiten-Skript.
@property (class, nonatomic, readonly) NSString *messageHandlerName;
/// Abtastrate der gelieferten Werte (16000).
@property (class, nonatomic, readonly) double sampleRate;

/// Installiert Nutzerskript und Rückkanal schon beim Anlegen einer WebView (dann gehen auch Videos in iframes
/// sofort). Ohne diesen Aufruf erledigt `startForWebView:` das nachträglich; iframes greifen dann erst nach dem
/// nächsten Laden. Mehrfachaufruf ist harmlos.
+ (void)installIntoUserContentController:(nullable id)userContentController;

/// Läuft auf `sampleQueue` (seriell, nicht Hauptthread). Zeiger gilt nur während des Aufrufs.
@property (nonatomic, copy, nullable) BrowserWebAudioSampleHandler sampleHandler;
/// Läuft auf dem Hauptthread.
@property (nonatomic, copy, nullable) BrowserWebAudioStatusHandler statusHandler;
/// Läuft auf dem Hauptthread, etwa alle 250 ms, bei Pause/Spulen sofort, beim Scrollen mit neuem Rechteck.
@property (nonatomic, copy, nullable) BrowserWebAudioPlaybackHandler playbackHandler;

@property (nonatomic, readonly) dispatch_queue_t sampleQueue;
@property (nonatomic, readonly, weak, nullable) BrowserWebView *webView;
@property (nonatomic, readonly) BrowserWebAudioCaptureStatus status;
@property (nonatomic, readonly, copy) NSString *statusDetail;
@property (nonatomic, readonly) BrowserWebAudioPlaybackState playbackState;
@property (nonatomic, readonly, getter=isActive) BOOL active;

/// Blocklänge im Skript in Sekunden (Standard 0,5; 0,1 bis 1,0). Vor dem Start setzen.
@property (nonatomic) NSTimeInterval blockDuration;
/// Nach wie vielen Sekunden reiner Nullen „Stille“ gemeldet wird (Standard 4).
@property (nonatomic) NSTimeInterval silenceThreshold;
/// Test: ScriptProcessorNode statt AudioWorklet.
@property (nonatomic) BOOL forceScriptProcessor;
/// Test: Herkunftsprüfung überspringen (das Video wird bei fremder Herkunft dann stumm!).
@property (nonatomic) BOOL ignoreCrossOriginCheck;
/// Jeden Block loggen ([WebAudio] Block …). Standard: in DEBUG an.
@property (nonatomic) BOOL logsBlocks;

- (void)startForWebView:(BrowserWebView *)webView;
/// Trennt den Abgriff. Die Quelle im Seiten-Skript bleibt an den Lautsprechern (Ton läuft weiter).
- (void)stop;

/// Kopiert die letzten bis zu `maxCount` Werte des aktuellen zusammenhängenden Abschnitts (ohne Sprung
/// durch Spulen/Pause) nach `buffer` und liefert die Medienzeit des ersten kopierten Werts. Threadsicher.
- (NSUInteger)copyLatestSamples:(float *)buffer maxCount:(NSUInteger)maxCount startTime:(nullable NSTimeInterval *)startTime;
/// Länge des aktuellen zusammenhängenden Abschnitts im Puffer (höchstens 30 s).
@property (nonatomic, readonly) NSTimeInterval bufferedDuration;
/// Zählt bei jedem neuen zusammenhängenden Abschnitt (Spulen, Pause, Seitenwechsel) hoch. Threadsicher.
@property (nonatomic, readonly) NSUInteger segmentGeneration;

/// Kennzahlen für Logs und Selbsttest.
@property (nonatomic, readonly) NSUInteger receivedBlocks;
@property (nonatomic, readonly) NSUInteger silentBlocks;
@property (nonatomic, readonly) float lastRMS;
@property (nonatomic, readonly) float lastPeak;
/// Mittlere Zeit vom Abschicken im Skript bis zum Eintreffen in der App (ms).
@property (nonatomic, readonly) double averageTransportMilliseconds;
/// Mittlere Dekodierzeit je Block in der App (ms).
@property (nonatomic, readonly) double averageDecodeMilliseconds;
/// Fragt den Zustand im Skript ab (JSON-Text) und meldet ihn auf dem Hauptthread.
- (void)fetchScriptStatus:(void (^)(NSString * _Nullable json))completion;

+ (NSString *)nameForStatus:(BrowserWebAudioCaptureStatus)status;

@end

NS_ASSUME_NONNULL_END
