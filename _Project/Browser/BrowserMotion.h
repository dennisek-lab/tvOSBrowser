//
//  BrowserMotion.h
//
//  Zentrale Stelle für alle Oberflächen-Animationen der App.
//
//  Zwei Stile:
//  - Liquid Glass (Standard): Federn nach Apples Modell „Dauer + Bounce“ (WWDC23 „Animate with springs“),
//    Glas „materialisiert“ (UIVisualEffectView.effect nil → UIGlassEffect im Animationsblock statt Alpha,
//    WWDC25 „Build a UIKit app with the new design“), Formen wachsen aus ihrem Ursprung heraus.
//  - Schlicht: kurze easeInOut-/easeOut-Kurven (0,12–0,25 s), nur Alpha/Frame, kein Bounce, kein Materialisieren.
//
//  Schlicht gilt, wenn die Einstellung „Liquid-Glass-Animationen“ aus ist, die Systemeinstellung
//  „Bewegung reduzieren“ an ist (UIAccessibilityIsReduceMotionEnabled) oder das alte Design gewählt ist.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BrowserMotionKind) {
    /// Layoutwechsel einer sichtbaren Fläche (Leiste kompakt ↔ voll, Bearbeiten-Zustand).
    BrowserMotionKindStandard = 0,
    /// Etwas erscheint (Aufklapp-Karte, Seitenleiste, Dialogkarte).
    BrowserMotionKindAppear,
    /// Etwas verschwindet (ohne Bounce, etwas schneller).
    BrowserMotionKindDisappear,
    /// Kurze Folgebewegung (Einrast-Hervorhebung, Reader-Hervorhebung).
    BrowserMotionKindSnap,
    /// Reines Ein-/Ausblenden oder Fortschritt (Ladelinie, Inhalte), nie mit Bounce.
    BrowserMotionKindFade,
};

@interface BrowserMotion : NSObject

/// YES: Liquid-Glass-Stil (Einstellung an, „Bewegung reduzieren“ aus, altes Design aus).
@property (class, nonatomic, readonly) BOOL liquidGlassEnabled;
/// YES: Glow der Hervorhebung dreht sich und atmet (Einstellung „Glow-Animation“ an und „Bewegung reduzieren“ aus).
/// NO: stehender Farbverlauf. Änderungen von „Bewegung reduzieren“ meldet UIAccessibilityReduceMotionStatusDidChangeNotification.
@property (class, nonatomic, readonly) BOOL glowAnimationEnabled;
/// YES, wenn UIGlassEffect zur Laufzeit vorhanden ist (tvOS 26 und neuer) und das alte Design aus ist.
/// NO: Aufrufer nehmen ihren Rückfall (UIBlurEffect dunkel).
@property (class, nonatomic, readonly) BOOL glassMaterialAvailable;
/// Altes Design (Einstellung „Design: Alt“, NSUserDefaults-Schlüssel „ClassicDesign“): Oberfläche wie die
/// ursprüngliche Fassung, ohne Glas und ohne Liquid-Glass-Animationen.
@property (class, nonatomic, readonly) BOOL classicDesignEnabled;

/// Wirksame Dauer (Feder: Einschwingzeit) der Art im aktuellen Stil.
+ (NSTimeInterval)durationForKind:(BrowserMotionKind)kind;

/// Standard-Layoutanimation (BrowserMotionKindStandard).
+ (void)animate:(void (NS_NOESCAPE ^)(void))animations completion:(nullable void (^)(BOOL finished))completion;

/// Animation einer Art. options: zusätzliche Optionen (BeginFromCurrentState, AllowUserInteraction …);
/// Kurvenoptionen setzt BrowserMotion selbst.
+ (void)animateKind:(BrowserMotionKind)kind
              delay:(NSTimeInterval)delay
            options:(UIViewAnimationOptions)options
         animations:(void (NS_NOESCAPE ^)(void))animations
         completion:(nullable void (^)(BOOL finished))completion;

/// Schattenumriss (wird von UIView-Animationen nicht mitgenommen) mit derselben Kurve wie animateKind:
/// von fromPath auf den aktuellen layer.shadowPath animieren. Läuft schon eine Umriss-Animation, startet sie
/// vom gerade sichtbaren Umriss (kein Sprung bei schnellem Hin und Her).
+ (void)animateShadowPathOfLayer:(CALayer *)layer fromPath:(nullable CGPathRef)fromPath kind:(BrowserMotionKind)kind;

/// Ebenen-Animation (ohne keyPath/Werte) mit derselben Kurve wie animateKind: – für Eigenschaften, die
/// UIView-Animationen nicht mitnehmen (Pfade, Unterebenen).
+ (CABasicAnimation *)layerAnimationForKind:(BrowserMotionKind)kind;

/// Glas erscheinen lassen. Liquid Glass: effect nil → effect im Federblock (Materialisieren), extra wird
/// mitanimiert. Schlicht: effect sofort, Alpha 0 → 1.
+ (void)glassAppear:(UIVisualEffectView *)view
             effect:(nullable UIVisualEffect *)effect
               kind:(BrowserMotionKind)kind
          alongside:(nullable void (^)(void))extra
         completion:(nullable void (^)(BOOL finished))completion;

/// Glas verschwinden lassen. Liquid Glass: effect → nil (Dematerialisieren). Schlicht: Alpha → 0.
+ (void)glassDisappear:(UIVisualEffectView *)view
                  kind:(BrowserMotionKind)kind
             alongside:(nullable void (^)(void))extra
            completion:(nullable void (^)(BOOL finished))completion;

/// Dialogkarte beim Präsentieren (in viewWillAppear: aufrufen, läuft parallel zur Überblendung):
/// Liquid Glass: Karte materialisiert und federt aus 0,94 auf volle Größe. Schlicht: nichts (Überblendung reicht).
+ (void)presentCard:(UIView *)card glassEffect:(nullable UIVisualEffect *)effect;
/// Gegenstück für viewWillDisappear:.
+ (void)dismissCard:(UIView *)card;

@end

NS_ASSUME_NONNULL_END
