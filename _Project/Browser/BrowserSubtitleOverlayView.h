#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Untertitelebene für `AVPlayerViewController.contentOverlayView`: unten mittig, groß für den Sofaabstand,
/// halbtransparenter Kasten. Farben, Schrift und Größe folgen den tvOS-Untertitel-Einstellungen
/// (MACaptionAppearance, Einstellungen > Bedienungshilfen > Untertitel).
@interface BrowserSubtitleOverlayView : UIView
/// Untertiteltext (nil/leer blendet aus).
- (void)setSubtitleText:(nullable NSString *)text;
/// Kurzer Hinweis (z. B. „Automatische Untertitel: Modell wird geladen“), verschwindet nach `duration` Sekunden.
- (void)showStatus:(NSString *)status duration:(NSTimeInterval)duration;
@end

NS_ASSUME_NONNULL_END
