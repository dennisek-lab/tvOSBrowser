#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Sammelt die klickbaren Elemente einer Seite für den magnetischen Zeiger.
/// Ein Seiten-Skript meldet Rechtecke (CSS-Pixel) samt Scrollposition über den Rückkanal
/// `browserTargets`. Der Tracker rechnet sie bei Bedarf in Ansichtskoordinaten um, wobei die
/// aktuelle Scrollposition der WebView berücksichtigt wird, damit die Ziele beim Scrollen mitwandern.
@interface BrowserClickTargetTracker : NSObject

/// Scrollansicht der WebView. Ihr Versatz beim Eintreffen einer Meldung dient als Bezug fürs Mitwandern.
@property (nonatomic, weak, nullable) UIScrollView *scrollView;

/// Meldet sich, wenn die Seite neue Ziele geschickt hat. Läuft auf dem Hauptthread.
@property (nonatomic, copy, nullable) void (^targetsDidChange)(void);

/// Meldet Videoereignisse der Seite: type "fullscreen" (Seite will ein Video im Vollbild zeigen)
/// oder "playing" (sichtbares Video hat zu spielen begonnen), dazu bid (Kennung des Video-Elements).
/// Läuft auf dem Hauptthread.
@property (nonatomic, copy, nullable) void (^videoEventHandler)(NSDictionary *event);

/// Installiert Skript und Nachrichten-Handler in eine `WKWebViewConfiguration` (per Laufzeit).
- (void)installIntoConfiguration:(id)configuration;

/// Ziele in Koordinaten der WebView. `viewWidth` ist die Breite der WebView in Punkten.
- (NSArray<NSValue *> *)targetRectsForViewWidth:(CGFloat)viewWidth;

/// Leuchtfarbe des Ziels unter dem Punkt (Koordinaten der WebView ohne Leisteneinschub), nil = keine eigene Farbe.
- (nullable UIColor *)glowColorAtViewPoint:(CGPoint)point viewWidth:(CGFloat)viewWidth;

/// Sichtbare Videos (mindestens 120 × 80 CSS-Pixel), in Koordinaten der WebView.
- (NSArray<NSValue *> *)videoRectsForViewWidth:(CGFloat)viewWidth;

/// Ob auf der Seite gerade ein Video läuft (auch außerhalb des sichtbaren Bereichs).
@property (nonatomic, readonly) BOOL videoPlaying;

/// Angaben zum aktiven Video für „Now Playing“: title, artist, album, art (URL), dur, t, paused, rate, next, prev.
/// nil, wenn kein Video angespielt wurde.
@property (nonatomic, readonly, copy, nullable) NSDictionary *mediaInfo;

/// Faktor Punkte pro CSS-Pixel, Stand der letzten Meldung.
- (CGFloat)cssScaleForViewWidth:(CGFloat)viewWidth;

/// JavaScript für einen Videobefehl an einem Punkt (CSS-Pixel im Viewport): "toggle", "seek:10", "seek:-10".
/// Liegt dort kein Video, trifft der Befehl das laufende Video der Seite.
+ (NSString *)videoCommandScriptWithCSSPoint:(CGPoint)point command:(NSString *)command;

#pragma mark Player-Brücke (alle Frames, eigene Content World)

/// `WKContentWorld` der Player-Brücke, nil wenn WebKit keine Content Worlds kann (dann läuft die Brücke in der
/// Seitenwelt, ohne Klicks in fremde Frames). Skripte für die Brücke mit dieser Welt im Hauptframe ausführen.
+ (nullable id)playerBridgeContentWorld;

/// Videobefehl über die Brücke (Hauptframe, Shadow DOM, iframes). Punkt in CSS-Pixeln, (-1, -1) = ohne Punkt.
/// strict: nur ein Video/Player am Punkt oder ein laufendes Video. Ergebnis des Skripts: play, pause, seek,
/// click, frame, none bzw. nobridge (Brücke fehlt).
+ (NSString *)playerBridgeCommandScript:(NSString *)command cssPoint:(CGPoint)point strict:(BOOL)strict;

/// Klick über die Brücke: in fremde iframes und Shadow DOM. Ergebnis `page` = Ziel liegt im Hauptdokument,
/// dort klickt der bisherige Weg (`BrowserPageActionCoordinator`).
+ (NSString *)playerBridgeClickScriptAtCSSPoint:(CGPoint)point;

/// Befehl an den Frame mit dieser Adresse (z. B. nach der Übergabe an den nativen Player).
+ (NSString *)playerBridgeScriptForFrameURL:(NSString *)frameURL command:(NSString *)command;

/// Ist auf der Seite gerade ein Element oder Video im Vollbild?
@property (nonatomic, readonly) BOOL pageFullscreen;

/// Farbe der Seite (theme-color, sonst Hintergrund von body/html, sonst Weiß), Stand der letzten Meldung.
@property (nonatomic, readonly, nullable) UIColor *pageBackgroundColor;

/// Titel der Seite, Stand der letzten Meldung (auch nach Änderungen durch Skripte).
@property (nonatomic, readonly, copy, nullable) NSString *pageTitle;
/// Name der Website aus den Metadaten (og:site_name, application-name, apple-mobile-web-app-title).
@property (nonatomic, readonly, copy, nullable) NSString *siteName;

/// JavaScript, das das Vollbild der Seite verlässt.
+ (NSString *)exitFullscreenScript;

/// Leert die Ziele (z. B. beim Start einer neuen Navigation).
- (void)reset;

/// JavaScript, das die Seite zu einer sofortigen neuen Meldung auffordert.
+ (NSString *)refreshScript;

@end

NS_ASSUME_NONNULL_END
