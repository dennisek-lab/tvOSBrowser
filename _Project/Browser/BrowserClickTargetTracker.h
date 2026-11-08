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

/// Installiert Skript und Nachrichten-Handler in eine `WKWebViewConfiguration` (per Laufzeit).
- (void)installIntoConfiguration:(id)configuration;

/// Ziele in Koordinaten der WebView. `viewWidth` ist die Breite der WebView in Punkten.
- (NSArray<NSValue *> *)targetRectsForViewWidth:(CGFloat)viewWidth;

/// Leert die Ziele (z. B. beim Start einer neuen Navigation).
- (void)reset;

/// JavaScript, das die Seite zu einer sofortigen neuen Meldung auffordert.
+ (NSString *)refreshScript;

@end

NS_ASSUME_NONNULL_END
