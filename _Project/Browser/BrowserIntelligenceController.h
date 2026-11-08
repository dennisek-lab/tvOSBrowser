//
//  BrowserIntelligenceController.h
//  Browser
//
//  Oberfläche der intelligenten Funktionen: Glas-Karte „Zusammenfassung“ und Hinweis-Kapsel „Übersetzen?“.
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

/// Zeigt die Karte mit „Wird zusammengefasst …“ und dann das Ergebnis (oder eine Rückmeldung bei Fehlern).
- (void)summarizeCurrentPage;
/// Öffnet die Seite über translate.goog. NO (mit Rückmeldung), wenn das nicht geht oder schon übersetzt ist.
- (BOOL)translateCurrentPage;

- (void)pageDidStartLoadInWebView:(BrowserWebView *)webView;
/// Prüft nach kurzer Pause die Sprache und blendet bei fremder Sprache „Übersetzen?“ ein.
- (void)pageDidFinishLoadInWebView:(BrowserWebView *)webView;
/// Tabwechsel: Karte und Kapsel schließen.
- (void)activeWebViewDidChange;

/// Menütaste: schließt die Karte bzw. lehnt den Hinweis für diesen Host ab. YES, wenn verbraucht.
- (BOOL)handleMenuPress;
/// Play/Pause: nimmt den Hinweis an (übersetzt). YES, wenn verbraucht.
- (BOOL)handlePlayPausePress;

#if DEBUG
/// Selbsttest-Schritte ai, summarize, translate, translate:hint, translate:reset. YES, wenn erkannt.
- (BOOL)runSelfTestStep:(NSString *)step;
#endif

@end

NS_ASSUME_NONNULL_END
