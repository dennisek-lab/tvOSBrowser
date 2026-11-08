#import <UIKit/UIKit.h>

#import "BrowserSpeechRecognizing.h"
#import "BrowserWebAudioCapture.h"

NS_ASSUME_NONNULL_BEGIN

/// Native Untertitel-Ebene über der WebView (Weg B). Wird als oberste Unteransicht in die BrowserWebView
/// gelegt und richtet sich unten am Video-Rechteck aus, das das Seiten-Skript meldet (umgerechnet in
/// BrowserWebAudioCapture: CSS-Faktor, Leisteneinschub `topObscuredInset`, Scrollen).
/// Stil nach den tvOS-Untertitel-Einstellungen (`MACaptionAppearance`), Größe für Sofaabstand.
/// Taktung: Medienzeit aus der letzten Meldung plus vergangene Zeit × Rate; bei Pause/Spulen steht sie.
@interface BrowserWebSubtitleOverlay : UIView

/// Legt die Ebene über `webView` (oder entfernt sie mit nil).
- (void)attachToWebView:(nullable UIView *)webView;

/// Neuer Wiedergabestand (Zeit, Pause, Rate, Rechteck, Vollbild).
- (void)updatePlaybackState:(BrowserWebAudioPlaybackState)state;

/// Fügt Cues hinzu und ersetzt dabei alle bisherigen, die bei oder nach `start` beginnen (überlappende Abschnitte).
- (void)addCues:(NSArray<BrowserWebSubtitleCue *> *)cues replacingFrom:(NSTimeInterval)start;
- (void)removeAllCues;

/// Kurzer Hinweis im Untertitel-Stil (z. B. „Kein Ton: Video von fremdem Server“), verschwindet nach `duration`.
- (void)showHint:(NSString *)text duration:(NSTimeInterval)duration;

/// Wie lange ein Cue nach seinem Ende stehen bleibt, solange kein neuerer kommt. Die Erkennung liefert einen
/// Abschnitt erst nach seinem Ende (Verzug ≥ Abschnittslänge); ohne Nachlauf wäre der Text schon abgelaufen,
/// wenn er ankommt. Standard 3 s; der Controller setzt Abschnittslänge + 1,5 s.
@property (nonatomic) NSTimeInterval holdDuration;
/// Pausiert laut letzter Meldung.
@property (nonatomic, readonly) BOOL currentPlaybackPaused;
/// Hochgerechnete Medienzeit jetzt.
@property (nonatomic, readonly) NSTimeInterval currentMediaTime;
@property (nonatomic, readonly, nullable) BrowserWebSubtitleCue *displayedCue;
@property (nonatomic, readonly) NSUInteger cueCount;
/// Eine Zeile für Logs: Elternansicht, Rahmen, Untertitelfeld.
@property (nonatomic, readonly) NSString *layoutSummary;
/// Wird gerufen, wenn ein Cue sichtbar wird, mit der Medienzeit in diesem Moment (für Verzugsmessung).
@property (nonatomic, copy, nullable) void (^cueDidAppear)(BrowserWebSubtitleCue *cue, NSTimeInterval mediaTime);

@end

NS_ASSUME_NONNULL_END
