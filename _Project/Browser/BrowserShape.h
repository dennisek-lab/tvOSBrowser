#import <UIKit/UIKit.h>

// Eckenradien nach Apples Gestaltungsregeln (Liquid Glass, tvOS 26):
// - immer kontinuierliche Kurve (Squircle), nie Kreisbögen,
// - Knöpfe, Zeilen und Leisten als Kapsel (Radius = halbe Höhe),
// - verschachtelte Formen konzentrisch: innerer Radius = äußerer Radius − Abstand zum Rand.
// Alle Flächen der App nehmen ihre Radien von hier, damit die Stufen zueinander passen.

NS_ASSUME_NONNULL_BEGIN

/// Große Karten und Dialoge (Bedienung, Was ist neu, Zusammenfassung). Konzentrisch zu den Kapsel-Knöpfen
/// am unteren Rand: Abstand 44 + Knopfhöhe 80 / 2.
static const CGFloat BrowserShapeCardRadius = 84.0;
/// Innenabstand großer Karten, aus dem sich die konzentrischen Radien ergeben.
static const CGFloat BrowserShapeCardInset = 44.0;
/// Seitenleiste (•••) und Tab-Übersicht: Kacheln mit 14 pt Abstand zum Rand, Radius konzentrisch 36.
static const CGFloat BrowserShapePanelRadius = 50.0;
static const CGFloat BrowserShapePanelInset = 14.0;
/// Kacheln (Favoriten, Tabs): mittlere Stufe; Inhalte darin konzentrisch.
static const CGFloat BrowserShapeTileRadius = 32.0;
/// Kleine Flächen (Untertitel-Kästen, Hinweise im Player).
static const CGFloat BrowserShapeSmallRadius = 16.0;

/// Radius einer Form, die mit `inset` Abstand in einer Form mit Radius `outer` liegt.
static inline CGFloat BrowserShapeConcentricRadius(CGFloat outer, CGFloat inset) {
    return MAX(outer - inset, 6.0);
}

/// Kapsel-Radius für eine Höhe.
static inline CGFloat BrowserShapeCapsuleRadius(CGFloat height) {
    return MAX(height, 0.0) / 2.0;
}

/// Setzt Radius und kontinuierliche Kurve auf einer Ebene.
static inline void BrowserShapeApply(CALayer *layer, CGFloat radius) {
    layer.cornerRadius = radius;
    layer.cornerCurve = kCACornerCurveContinuous;
}

NS_ASSUME_NONNULL_END
