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
/// Play/Pause gehalten (ab 0,6 s).
- (void)browserRemoteInputControllerHandlePlayPauseLongPress;
/// Einrastziele für den magnetischen Zeiger (Seitenelemente und Knöpfe der oberen Leiste), in Koordinaten von rootView.
- (NSArray<NSValue *> *)browserRemoteInputControllerPointerTargets;
- (void)browserRemoteInputControllerNavigateBack;
/// Zweimal oben gedrückt: Adressleiste öffnen.
- (void)browserRemoteInputControllerOpenAddressBar;
- (void)browserRemoteInputControllerNavigateForward;
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

- (void)handleGlobalSelectPressEndedNotification;
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
#if DEBUG
/// Testet die Kreiserkennung mit künstlichen Bewegungen. Rückgabe: Anzahl der Proben im Kreismodus (0 = kein Kreis).
- (NSInteger)debugRunGestureWithDeltas:(NSArray<NSValue *> *)deltas;
#endif
- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled;
- (void)refreshInteractionState;

@end

NS_ASSUME_NONNULL_END
