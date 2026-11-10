#import <Foundation/Foundation.h>

#import "BrowserSpeechRecognizing.h"
#import "BrowserWebAudioCapture.h"
#import "BrowserWebSubtitleOverlay.h"

@class BrowserWebView;
@class BrowserAppleSpeechTranscriber;

NS_ASSUME_NONNULL_BEGIN

/// Verbindet Tonquelle, Erkennung (BrowserSpeechRecognizing, über BrowserSubtitlePipeline) und Anzeige
/// (BrowserWebSubtitleOverlay) für Videos in der Webseite (Weg B).
///
/// Zwei Tonquellen:
/// - Vorausquelle (bevorzugt): Meldet das Seiten-Skript eine ladbare Medienadresse (http/https, kein blob:),
///   lädt die App den Ton selbst – MP4/MOV über BrowserSubtitleProgressiveAudioSource, HLS (auch live) über
///   BrowserSubtitleHLSAudioSource, mit Cookies, Referer und User-Agent der Seite – gekoppelt an `currentTime`
///   des Seitenvideos (Live-HLS mit Datum: `getStartDate()` + `currentTime`). Text liegt vor dem Sprechen bereit.
///   Das geht auch, wenn Web Audio nichts liefert (natives HLS, fremde Herkunft ohne CORS, Seite nutzt Web Audio
///   selbst, kein Web Audio); die Hinweise dazu entfallen dann. Nur Kopierschutz bleibt „nicht möglich“.
/// - Mithören über Web Audio (Rückfall, z. B. MSE-Player mit blob:-Adresse): Blöcke von 0,5 s, die Pipeline
///   rechnet jede Sekunde den offenen Satz neu (vorläufiger Text wird ersetzt), Text ≈ 1–1,5 s nach dem Sprechen.
@interface BrowserWebSubtitleController : NSObject

/// Standard: BrowserSpeechRecognizerStub. Hier später die whisper-Engine setzen (vor `startForWebView:`).
- (instancetype)initWithRecognizer:(nullable id<BrowserSpeechRecognizing>)recognizer NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

@property (nonatomic, strong) id<BrowserSpeechRecognizing> recognizer;
/// Apples Spracherkennung statt whisper (SubtitlesRecognizer=apple, docs/ERWEITERUNGEN.md 10.10); `recognizer`
/// (whisper) bestimmt dann nur die Sprache und ist Rückfall. nil = whisper erkennt.
@property (atomic, strong, nullable) BrowserAppleSpeechTranscriber *appleSpeech;
@property (nonatomic, readonly) BrowserWebAudioCapture *capture;
@property (nonatomic, readonly) BrowserWebSubtitleOverlay *overlay;

/// Abschnittslänge und Überlappung der Erkennung (Vorgabe von BrowserSpeechRecognizing). Nur noch zur Auskunft;
/// den Takt bestimmt BrowserSubtitlePipeline (Mithören: Schritt 1 s, Vorausquelle: 12-s-Abschnitte).
@property (nonatomic) NSTimeInterval windowDuration;
@property (nonatomic) NSTimeInterval overlapDuration;

/// Zustandswechsel mit deutschem Hinweistext für die Oberfläche (nil = nichts anzeigen). Hauptthread.
@property (nonatomic, copy, nullable) void (^statusHandler)(BrowserWebAudioCaptureStatus status, NSString *detail, NSString * _Nullable message);
/// Hinweise (kein Ton, kein Video, DRM) im Overlay einblenden. Standard: ja.
@property (nonatomic) BOOL showsStatusHints;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, weak, nullable) BrowserWebView *webView;

/// Startet ohne „Kein Video“-Hinweis (für automatisches Starten bei Tabwechsel/App-Start).
- (void)startForWebView:(BrowserWebView *)webView;
/// `userInitiated`: Nutzer hat gerade eingeschaltet; dann erscheint auch „Kein Video auf der Seite“ (nur in den
/// ersten Sekunden). Hinweise zu CORS/DRM/HLS/Stille erscheinen immer.
- (void)startForWebView:(BrowserWebView *)webView userInitiated:(BOOL)userInitiated;
- (void)stop;

/// Deutscher Hinweis zum Zustand, nil wenn alles läuft.
+ (nullable NSString *)messageForStatus:(BrowserWebAudioCaptureStatus)status detail:(NSString *)detail;

/// Kennzahlen als eine Zeile (Blöcke, Pegel, Wege, Erkennungszeit, Verzug bis zur Anzeige).
- (NSString *)statisticsSummary;

@end

NS_ASSUME_NONNULL_END
