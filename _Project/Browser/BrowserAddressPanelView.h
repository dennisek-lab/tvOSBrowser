//
//  BrowserAddressPanelView.h
//  Aufklapp-Bereich unter der Adressleiste: Glas-Karte mit drei Spalten (Favoriten, Oft besucht, Zuletzt),
//  je 2 × 2 Kacheln mit dem Icon der Seite. Ersetzt die frühere Vollbild-Startansicht.
//  Bedienung über den Zeiger der App: Kacheln sind Einrastziele (Host fragt pointerTargetRects ab).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserAddressPanelView : UIView

/// Klick auf eine Kachel (der Host lädt die Seite und schließt den Zustand).
@property (nonatomic, copy, nullable) void (^openURLHandler)(NSURL *url);

/// Anzahl der Kacheln mit Seite (ohne leere Plätze).
@property (nonatomic, readonly) NSUInteger tileCount;

/// Daten aus BrowserHistoryStore neu lesen und Kacheln aufbauen.
- (void)reloadData;

/// Einblenden: Karte wächst unterhalb von barFrame (eigene Koordinaten) aus der Leiste heraus, Seite wird gedimmt.
- (void)presentBelowBarFrame:(CGRect)barFrame animated:(BOOL)animated;

/// Ausblenden (Karte schrumpft in die Leiste zurück), danach removeFromSuperview.
- (void)dismissAnimated:(BOOL)animated completion:(nullable void (^)(void))completion;

/// Einrastziele (Kacheln mit Seite) in Koordinaten von view.
- (NSArray<NSValue *> *)pointerTargetRectsInView:(UIView *)view;

/// Eckenradius der Kachel, deren Zielrechteck rect ist (Koordinaten von view); negativ, wenn keine Kachel.
- (CGFloat)cornerRadiusForTargetRect:(CGRect)rect inView:(UIView *)view;

/// Adresse der Kachel unter point (Koordinaten von view), sonst nil.
- (nullable NSURL *)URLForTileAtPoint:(CGPoint)point inView:(UIView *)view;

/// Liegt point (Koordinaten von view) auf der Karte?
- (BOOL)cardContainsPoint:(CGPoint)point inView:(UIView *)view;

/// Klick an point (Koordinaten von view): Kachel öffnen. YES, wenn eine Kachel getroffen wurde.
- (BOOL)handleSelectionAtPoint:(CGPoint)point inView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
