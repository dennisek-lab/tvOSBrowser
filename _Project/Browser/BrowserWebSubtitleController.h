#import <Foundation/Foundation.h>

#import "BrowserSpeechRecognizing.h"
#import "BrowserWebAudioCapture.h"
#import "BrowserWebSubtitleOverlay.h"

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

/// Verbindet Tonabgriff (BrowserWebAudioCapture), Erkennung (BrowserSpeechRecognizing) und Anzeige
/// (BrowserWebSubtitleOverlay) für Videos in der Webseite (Weg B).
///
/// Ablauf: Das Seiten-Skript schickt Blöcke von 0,5 s. Sind `windowDuration − overlapDuration` Sekunden neu
/// dazugekommen, wird der letzte Abschnitt von `windowDuration` Sekunden aus dem Ringpuffer an die Erkennung
/// gegeben (nie zwei gleichzeitig; ist die Erkennung zu langsam, wird übersprungen statt gestaut). Die Cues
/// ersetzen in der Anzeige alle bisherigen ab Abschnittsbeginn. Bei Spulen oder Pause beginnt ein neuer Abschnitt.
@interface BrowserWebSubtitleController : NSObject

/// Standard: BrowserSpeechRecognizerStub. Hier später die whisper-Engine setzen (vor `startForWebView:`).
- (instancetype)initWithRecognizer:(nullable id<BrowserSpeechRecognizing>)recognizer NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

@property (nonatomic, strong) id<BrowserSpeechRecognizing> recognizer;
@property (nonatomic, readonly) BrowserWebAudioCapture *capture;
@property (nonatomic, readonly) BrowserWebSubtitleOverlay *overlay;

/// Abschnittslänge und Überlappung in Sekunden. Standard: Vorgabe der Erkennung, sonst 3,0 und 0,5.
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
