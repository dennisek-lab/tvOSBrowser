//
//  BrowserIntelligenceController.h
//  Browser
//
//  Oberfläche der intelligenten Funktionen: Glas-Karte „Zusammenfassung“, Hinweis-Kapsel „Übersetzen?“ und
//  die Antwort-Karte von „Frag die Seite“ (gefundener Satz, in der Seite hervorgehoben).
//  Die Logik (Text, NaturalLanguage, translate.goog) liegt in BrowserIntelligence. ViewController reicht
//  Seitenereignisse, Menütaste und Play/Pause durch; Auslöser sind das Seitenmenü („Diese Seite“) und die
//  Sprachbefehle "summarize" und "translate" (BrowserCommand).
//

#import <UIKit/UIKit.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserIntelligenceController : NSObject

/// container: Ansicht für Karte und Kapsel (Fenster). webView: aktive Seite. feedback: kurze Rückmeldung (Glas-Toast).
- (instancetype)initWithContainerProvider:(UIView * _Nullable (^)(void))containerProvider
                          webViewProvider:(BrowserWebView * _Nullable (^)(void))webViewProvider
                          feedbackHandler:(void (^)(NSString *text, NSString * _Nullable symbolName, BOOL success))feedbackHandler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) BOOL summaryVisible;
@property (nonatomic, readonly) BOOL translationHintVisible;
@property (nonatomic, readonly) BOOL answerVisible;

/// Zeigt die Karte mit „Wird zusammengefasst …“ und dann das Ergebnis (oder eine Rückmeldung bei Fehlern).
- (void)summarizeCurrentPage;
/// Öffnet die Seite über translate.goog. NO (mit Rückmeldung), wenn das nicht geht oder schon übersetzt ist.
- (BOOL)translateCurrentPage;
/// „Frag die Seite“: passendste Stelle suchen, in der Seite hervorheben, hinscrollen, Antwort-Karte unten.
/// Kein Treffer: Rückmeldung „Keine passende Stelle gefunden“.
- (void)askCurrentPage:(NSString *)question;
/// Karte „Zusammenfassung“ schließen (Klick, Play/Pause oder Menü bei offener Karte).
- (void)dismissSummary;

- (void)pageDidStartLoadInWebView:(BrowserWebView *)webView;
/// Prüft nach kurzer Pause die Sprache und blendet bei fremder Sprache „Übersetzen?“ ein.
- (void)pageDidFinishLoadInWebView:(BrowserWebView *)webView;
/// Tabwechsel: Karte und Kapsel schließen.
- (void)activeWebViewDidChange;

/// Menütaste: schließt Karte bzw. Antwort oder lehnt den Hinweis für diesen Host ab. YES, wenn verbraucht.
- (BOOL)handleMenuPress;
/// Play/Pause: nimmt den Hinweis an (übersetzt) bzw. zeigt die nächste Fundstelle. YES, wenn verbraucht.
- (BOOL)handlePlayPausePress;

#if DEBUG
/// Selbsttest-Schritte ai, summarize, translate, translate:hint, translate:reset, ask:<frage>, ask:next. YES, wenn erkannt.
- (BOOL)runSelfTestStep:(NSString *)step;
#endif

@end

NS_ASSUME_NONNULL_END
