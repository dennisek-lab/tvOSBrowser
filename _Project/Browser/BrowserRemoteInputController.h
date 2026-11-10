#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserRemoteInputControllerHost <NSObject>

- (nullable UIScrollView *)browserRemoteInputControllerActiveScrollView;
- (nullable UIViewController *)browserRemoteInputControllerPresentedViewController;
- (BOOL)browserRemoteInputControllerTopBarFocusActive;
- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus;
- (void)browserRemoteInputControllerActivateTopBarFocus;
- (void)browserRemoteInputControllerDeactivateTopBarFocus;
- (BOOL)browserRemoteInputControllerTabOverviewVisible;
- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point;
- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point;
- (void)browserRemoteInputControllerDismissTabOverview;
- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction;
- (void)browserRemoteInputControllerHandlePrimaryAction;
/// NO: Taste nicht behandelt, das System darf sie nutzen (z. B. zurück zum Home-Bildschirm).
- (BOOL)browserRemoteInputControllerHandleMenuPress;
- (void)browserRemoteInputControllerHandlePlayPausePress;
- (void)browserRemoteInputControllerHandleAdvancedMenuPress;
@optional
/// Siri-Taste zweimal kurz (erkannt an sehr kurzen „rechts“-Drücken ohne Clickpad-Klick, siehe BrowserRemoteInputController.m).
- (void)browserRemoteInputControllerHandleSiriDoublePress;
@required
/// Play/Pause gehalten (ab 0,6 s).
- (void)browserRemoteInputControllerHandlePlayPauseLongPress;
/// Einrastziele für den magnetischen Zeiger (Seitenelemente und Knöpfe der oberen Leiste), in Koordinaten von rootView.
- (NSArray<NSValue *> *)browserRemoteInputControllerPointerTargets;
/// Clickpad links (Siri Remote, iPhone/iPad-Fernbedienung): über laufendem Video spulen, sonst voriges Element.
- (void)browserRemoteInputControllerNavigateBack;
/// Zweimal oben gedrückt: Adressleiste öffnen.
- (void)browserRemoteInputControllerOpenAddressBar;
/// Zweimal kurz unten: obere Leiste zur Kapsel verkleinern.
- (void)browserRemoteInputControllerCompactTopBar;
/// Clickpad rechts: über laufendem Video spulen, sonst nächstes Element.
- (void)browserRemoteInputControllerNavigateForward;
@optional
/// Ansicht, deren Inhalt die Hervorhebung als Linse vergrößert (WebView); nil = keine Linse. Die Linse ist seit
/// 8. November 2026 aus und nur noch in DEBUG-Vergleichsvarianten zu sehen (MagneticVariant Z/A/C/E).
- (nullable UIView *)browserRemoteInputControllerLensSourceView;
/// Optional: NO, wenn für dieses Ziel keine Linse gezeigt werden soll (z. B. Knöpfe der oberen Leiste,
/// deren Inhalt nicht in der Quellansicht liegt).
- (BOOL)browserRemoteInputControllerLensAllowedForTarget:(CGRect)target;
/// Leuchtfarbe für das Ziel (Koordinaten von rootView); nil = Standardblau.
- (nullable UIColor *)browserRemoteInputControllerGlowColorForTarget:(CGRect)target;
/// Form eines Seitenziels (Koordinaten von rootView) für die Hervorhebung: Eckenradius des sichtbaren Elements in pt,
/// eigene sichtbare Fläche (Hintergrund, Rahmen, Schatten, Bild) und reines Textziel (Textlink, Link im Fließtext).
/// image: das Ziel ist ein Bild (dann Linse mit Kantenbrechung und leichtem Zoom).
/// NO = keine Angabe (z. B. Knöpfe der oberen Leiste), dann gilt die Vorgabe-Rundung.
- (BOOL)browserRemoteInputControllerShapeForTarget:(CGRect)target cornerRadius:(CGFloat *)cornerRadius surface:(BOOL *)surface text:(BOOL *)text image:(BOOL *)image;
/// Ziele für den Sprung von Element zu Element (links/rechts, Ring). Ohne Umsetzung: die Zeigerziele.
- (NSArray<NSValue *> *)browserRemoteInputControllerStepTargets;
/// Adressleiste im Bearbeiten-Zustand mit Aufklapp-Bereich: Pfeiltasten springen räumlich zwischen den Zielen,
/// kein Seitenscrollen, der Zeiger wird nicht ausgeblendet.
- (BOOL)browserRemoteInputControllerAddressPanelActive;
/// Eckenradius der Hervorhebung für ein Ziel (Koordinaten von rootView); negativ = Standard.
- (CGFloat)browserRemoteInputControllerCornerRadiusForTarget:(CGRect)target;
/// Abgedunkelte Karte über der Seite (Zusammenfassung): wirkt wie ein Dialog. Zeiger und Pfeile ruhen,
/// Klick schließt sie (browserRemoteInputControllerDismissOverlayCard), Menü und Play/Pause laufen über den Host.
- (BOOL)browserRemoteInputControllerOverlayCardVisible;
- (void)browserRemoteInputControllerDismissOverlayCard;
/// Darf zweimal rechts (innerhalb 0,35 s) die Seitenleiste öffnen? NO, wenn rechts gerade ein Video spult.
/// Ohne Umsetzung: ja.
- (BOOL)browserRemoteInputControllerRightDoublePressOpensMenu;
@required
- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled;
- (void)browserRemoteInputControllerPersistSession;

@end

@interface BrowserRemoteInputController : NSObject

@property (nonatomic, readonly) UIImageView *cursorView;
@property (nonatomic, readonly) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readonly) UITapGestureRecognizer *playPauseDoubleTapRecognizer;
@property (nonatomic, readonly, getter=isCursorModeEnabled) BOOL cursorModeEnabled;

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Auswahl-Druck aus UIApplication sendEvent: (timestamp = UIPress.timestamp, 0 = unbekannt). Kam derselbe Druck
/// schon direkt an, passiert nichts.
- (void)handleGlobalSelectPressEndedWithTimestamp:(NSTimeInterval)timestamp;
- (void)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)handleTouchesEnded;
- (void)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
/// Die Seite hat neue Klickziele gemeldet oder gescrollt: Einrasten und Hervorhebung neu bewerten.
- (void)pointerTargetsDidChange;
/// Setzt die Fingerposition des Zeigers direkt (Selbsttest, später Schnellmenü). Einrasten greift wie beim Wischen.
- (void)movePointerToPoint:(CGPoint)point;
/// Zum nächsten (1) bzw. vorherigen (-1) Element in Leserichtung springen (wie die Kreisgeste).
- (void)stepTargetBy:(NSInteger)direction;
/// Räumlich zum nächsten Ziel in Richtung direction springen (z. B. (0, 1) = nach unten), ohne zu scrollen.
- (void)stepTargetInDirection:(CGVector)direction;
#if DEBUG
/// Testet die Kreiserkennung mit künstlichen Bewegungen. Rückgabe: Anzahl der Proben im Kreismodus (0 = kein Kreis).
/// Wie ein Druck rechts auf dem Clickpad (gleiche Logik inkl. zweimal rechts → Seitenleiste).
- (void)debugPressRight;
/// Sprungziele in der Reihenfolge, in der links/rechts sie anspringen.
- (NSArray<NSValue *> *)debugSortedStepTargets;
- (NSInteger)debugRunGestureWithDeltas:(NSArray<NSValue *> *)deltas;
/// Synthetisches Wischen auf dem Clickpad (Strecke in Clickpad-Einheiten, ganze Breite = 2) über dieselbe Pipeline
/// wie die echte Fernbedienung (artifacts: Achsen einzeln beim Aufsetzen/Loslassen, Ausreißer am Ende); loggt Messwerte der sichtbaren Zeigerbewegung als „[PointerTest] …“.
- (void)debugRunSwipeWithPadDelta:(CGVector)padDelta duration:(NSTimeInterval)duration flick:(BOOL)flick artifacts:(BOOL)artifacts;
/// Ring-Test: Finger kreist im Uhrzeigersinn auf dem Radius (Clickpad-Einheiten); loggt die Zahl der Elementsprünge.
- (void)debugRunRingWithRadius:(CGFloat)radius degrees:(CGFloat)degrees duration:(NSTimeInterval)duration;
#endif
- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled;
- (void)refreshInteractionState;

@end

NS_ASSUME_NONNULL_END
