#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Aussehen des Zeigers. Wert in `BrowserPreferencesStore.cursorStyle`.
typedef NS_ENUM(NSUInteger, BrowserCursorStyle) {
    /// Pfeil schwarz mit weißem Rand, Hand weiß mit schwarzem Rand (wie macOS).
    BrowserCursorStyleMacDark = 0,
    /// Pfeil weiß mit schwarzem Rand, Hand schwarz mit weißem Rand.
    BrowserCursorStyleMacLight = 1,
    /// SF Symbols (`cursorarrow`, `hand.point.up.left.fill`) mit Kontur und Schatten.
    BrowserCursorStyleSymbol = 2,
};

typedef NS_ENUM(NSUInteger, BrowserCursorKind) {
    BrowserCursorKindArrow,
    BrowserCursorKindHand,
    BrowserCursorKindIBeam,
};

/// Erzeugt die Zeigerbilder als Vektorzeichnung (kein Apple-Bildmaterial). Alle Bilder haben einen Rand für Kontur und
/// Schatten; die Klickspitze liegt in jedem Bild bei `+hotspot` (Bildpunkte).
@interface BrowserCursorRenderer : NSObject

/// Lage der Klickspitze im Bild, für alle Arten und Stile gleich.
+ (CGPoint)hotspot;

+ (UIImage *)imageForKind:(BrowserCursorKind)kind style:(BrowserCursorStyle)style;
/// Mit dem Stil aus den Einstellungen. Im alten Design mit Stil 0 (Standard) die Bitmaps der ursprünglichen Fassung.
+ (UIImage *)imageForKind:(BrowserCursorKind)kind;

@end

/// Bildansicht für den Zeiger: `frame.origin` ist die Klickspitze. Das Bild (mit Rand) wird so versetzt gezeichnet, dass
/// seine Spitze auf dem Ursprung liegt. Rand und Schatten ragen über die Ansichtsgrenzen hinaus (kein Beschneiden).
@interface BrowserCursorImageView : UIImageView
@end

NS_ASSUME_NONNULL_END
