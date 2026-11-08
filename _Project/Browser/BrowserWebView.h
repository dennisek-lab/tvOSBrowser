#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserWebViewDelegate <NSObject>

@optional
- (BOOL)webView:(id _Nonnull)webView shouldStartLoadWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (BOOL)webView:(id _Nonnull)webView shouldCreateNewTabWithRequest:(NSURLRequest * _Nullable)request navigationType:(NSInteger)navigationType;
- (void)webViewDidStartLoad:(id _Nonnull)webView;
- (void)webViewDidFinishLoad:(id _Nonnull)webView;
- (void)webView:(id _Nonnull)webView didFailLoadWithError:(NSError * _Nonnull)error;

@end

@interface BrowserWebView : UIView

@property (nullable, nonatomic, weak) id<BrowserWebViewDelegate> delegate;
@property (nullable, nonatomic, readonly, strong) NSURLRequest *request;
@property (nullable, nonatomic, readonly, strong) UIScrollView *scrollView;
@property (nullable, nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, getter=canGoBack) BOOL canGoBack;
@property (nonatomic, readonly, getter=canGoForward) BOOL canGoForward;
@property (nonatomic, readonly, getter=isLoading) BOOL loading;
@property (nonatomic) BOOL scalesPageToFit;
/// Wird aufgerufen, wenn die Seite neue klickbare Elemente gemeldet hat (magnetischer Zeiger).
@property (nullable, nonatomic, copy) void (^clickTargetsDidChange)(void);
/// Meldet jede Scrollbewegung: Abstand vom Seitenanfang in Punkten (0 = ganz oben, unter der Leiste).
@property (nullable, nonatomic, copy) void (^scrollOffsetDidChange)(CGFloat offsetFromTop);
/// Ladefortschritt 0…1 (estimatedProgress); 1 bzw. Ende des Ladens blendet die Anzeige aus.
@property (nullable, nonatomic, copy) void (^loadingProgressDidChange)(double progress, BOOL loading);
/// Videoereignisse der Seite (Vollbildwunsch, Videostart), siehe BrowserClickTargetTracker.videoEventHandler.
@property (nullable, nonatomic, copy) void (^videoEventHandler)(NSDictionary * _Nonnull event);
/// Klickbare Elemente im sichtbaren Bereich, in Koordinaten dieser Ansicht.
- (NSArray<NSValue *> * _Nonnull)clickTargetRects;
/// Sichtbare Videos der Seite, in Koordinaten dieser Ansicht.
- (NSArray<NSValue *> * _Nonnull)videoRects;
/// Läuft auf der Seite gerade ein Video?
@property (nonatomic, readonly) BOOL videoPlaying;
/// Videobefehl am Punkt (Koordinaten dieser Ansicht): "toggle", "seek:10", "seek:-10".
- (void)sendVideoCommand:(NSString * _Nonnull)command atPoint:(CGPoint)point;
/// Videobefehl an das aktive Video der Seite (für Systembefehle): zusätzlich "play", "pause", "seekto:S", "action:nexttrack".
- (void)sendVideoCommand:(NSString * _Nonnull)command;
/// Ist auf der Seite gerade etwas im Vollbild (Element-Vollbild oder Video-Vollbild von WebKit)?
@property (nonatomic, readonly) BOOL pageFullscreen;
/// Farbe der Seite für die Umgebung (Hintergrund hinter der oberen Leiste).
@property (nonatomic, readonly, nullable) UIColor *pageBackgroundColor;
/// Titel der Seite laut Seiten-Skript (aktueller als `title` beim Laden).
@property (nonatomic, readonly, copy, nullable) NSString *reportedPageTitle;
/// Name der Website aus den Metadaten, falls vorhanden.
@property (nonatomic, readonly, copy, nullable) NSString *reportedSiteName;
/// Färbt die Flächen der WebView außerhalb des Seiteninhalts (Streifen unter der Leiste, Überscrollen).
- (void)setSurroundingColor:(nonnull UIColor *)color;
/// Bereich oben, den die schwebende Leiste verdeckt. Die Seite beginnt darunter, scrollt aber unter die Leiste
/// (Liquid Glass braucht Inhalt dahinter).
@property (nonatomic) CGFloat topObscuredInset;
/// Verlässt das Vollbild der Seite.
- (void)exitPageFullscreen;
/// Angaben zum aktiven Video für „Now Playing“ (siehe BrowserClickTargetTracker.mediaInfo).
@property (nonatomic, readonly, copy, nullable) NSDictionary *mediaInfo;
/// Bittet die Seite, ihre klickbaren Elemente sofort neu zu melden (asynchron).
- (void)refreshClickTargets;
/// Führt JavaScript aus, ohne auf das Ergebnis zu warten.
- (void)evaluateJavaScriptAsync:(NSString * _Nonnull)script;
/// Führt JavaScript aus und meldet das Ergebnis (oder nil) auf dem Hauptthread.
- (void)evaluateJavaScriptAsync:(NSString * _Nonnull)script completion:(void (^ _Nullable)(id _Nullable result))completion;
/// Grundzoom, wenn scalesPageToFit aus ist (1.0 = 100 %).
@property (nonatomic) double pageZoom;

- (instancetype)initWithUserAgent:(NSString * _Nullable)userAgent
      allowsInlineMediaPlayback:(BOOL)allowsInlineMediaPlayback NS_DESIGNATED_INITIALIZER;

- (void)loadRequest:(NSURLRequest * _Nullable)request;
- (void)reload;
- (void)goBack;
- (void)goForward;
- (nullable NSString *)stringByEvaluatingJavaScriptFromString:(NSString * _Nonnull)script;
- (NSString * _Nonnull)runtimeMediaPreferenceReport;
- (void)setUserAgent:(NSString * _Nullable)userAgent;
- (void)pauseAllMediaPlayback;

/// Gemeinsamer WKWebsiteDataStore aller Tabs (per Laufzeit angesprochen).
+ (nullable id)defaultWebsiteDataStore;
+ (nullable NSData *)cookieDataRepresentation;
+ (NSArray<NSHTTPCookie *> * _Nonnull)allCookies;
+ (void)restoreCookiesFromData:(NSData * _Nullable)cookieData;
+ (void)clearCachedDataWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)clearCookiesWithCompletion:(void (^ _Nullable)(void))completion;
+ (void)resetWebsiteDataWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
