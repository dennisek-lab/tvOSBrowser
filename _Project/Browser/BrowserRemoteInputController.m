#import "BrowserRemoteInputController.h"

static UIImage *BrowserDefaultCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Cursor"];
    });
    return image;
}

static UIImage *BrowserPointerCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Pointer"];
    });
    return image;
}

#pragma mark - Abstimmung

/// Ab hier rastet der Zeiger an einem Ziel ein (Abstand Fingerposition zum Zielrand, Punkte).
static const CGFloat kSnapRadius = 36.0;
/// So weit darf der Finger über das Ziel hinaus, bevor der Zeiger sich wieder löst.
static const CGFloat kReleaseMargin = 28.0;
/// Größere Ziele (Bilder, Karten, breite Felder) werden nur hervorgehoben, der Zeiger springt nicht in die Mitte.
static const CGFloat kMaxCenterSnapWidth = 420.0;
static const CGFloat kMaxCenterSnapHeight = 140.0;
/// Seitenweises Scrollen über den Clickpad-Rand: Anteil der sichtbaren Höhe.
static const CGFloat kPageScrollFraction = 0.8;
/// Nach dieser Zeit ohne Berührung blendet sich der Zeiger aus.
static const NSTimeInterval kCursorIdleHideDelay = 4.0;

@interface BrowserRemoteInputController ()

@property (nonatomic, weak) id<BrowserRemoteInputControllerHost> host;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, readwrite) UIImageView *cursorView;
@property (nonatomic) UIView *highlightView;
@property (nonatomic, readwrite) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readwrite) UITapGestureRecognizer *playPauseDoubleTapRecognizer;
@property (nonatomic, readwrite, getter=isCursorModeEnabled) BOOL cursorModeEnabled;

/// Fingerposition des Zeigers ohne Einrasten (Klickspitze, Koordinaten von rootView).
@property (nonatomic) CGPoint freePoint;
/// Ziel, an dem der Zeiger gerade eingerastet ist (CGRectNull, wenn keins).
@property (nonatomic) CGRect snappedTarget;

@property (nonatomic) CGPoint lastTouchLocation;
@property (nonatomic) NSTimeInterval lastTouchTimestamp;
@property (nonatomic) BOOL pressInProgress;
@property (nonatomic) BOOL revealOnlyTouch;
@property (nonatomic) BOOL cursorIdleHidden;

@property (nonatomic) CADisplayLink *manualScrollDisplayLink;
@property (nonatomic) CGPoint manualScrollVelocity;
@property (nonatomic) CFTimeInterval manualScrollLastTimestamp;
@property (nonatomic) CFTimeInterval manualScrollLastMovementTimestamp;
@property (nonatomic) CFTimeInterval lastDirectSelectPressTimestamp;
@property (nonatomic) BOOL playPauseLongPressFired;
@property (nonatomic) BOOL playPauseSinglePending;
@property (nonatomic) CFTimeInterval lastUpPressTimestamp;

// Kreisgeste am Clickpad-Ring: Drehung der Bewegungsrichtung aufsummieren.
@property (nonatomic) CGPoint rotationSegment;
@property (nonatomic) CGFloat rotationLastHeading;
@property (nonatomic) BOOL rotationHasHeading;
@property (nonatomic) CGFloat rotationAccumulated;
@property (nonatomic) CGFloat rotationStepAccumulated;
@property (nonatomic) BOOL rotationMode;
@property (nonatomic) CGPoint gestureStartPoint;
@property (nonatomic) CGRect gestureStartTarget;

@end

@implementation BrowserRemoteInputController

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView {
    self = [super init];
    if (self) {
        _host = host;
        _rootView = rootView;
        _lastTouchLocation = CGPointMake(-1, -1);
        _cursorModeEnabled = YES;
        _snappedTarget = CGRectNull;

        CGRect screen = [UIScreen mainScreen].bounds;
        _freePoint = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
        _cursorView = [[UIImageView alloc] initWithFrame:CGRectMake(_freePoint.x, _freePoint.y, 64, 64)];
        _cursorView.image = BrowserDefaultCursor();
        _cursorView.userInteractionEnabled = NO;

        _highlightView = [[UIView alloc] initWithFrame:CGRectZero];
        _highlightView.userInteractionEnabled = NO;
        _highlightView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        _highlightView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
        _highlightView.layer.borderWidth = 3.0;
        _highlightView.layer.shadowColor = UIColor.blackColor.CGColor;
        _highlightView.layer.shadowOpacity = 0.35;
        _highlightView.layer.shadowRadius = 10.0;
        _highlightView.layer.shadowOffset = CGSizeZero;
        _highlightView.alpha = 0.0;

        _playPauseDoubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlayPauseDoubleTap:)];
        _playPauseDoubleTapRecognizer.numberOfTapsRequired = 2;
        _playPauseDoubleTapRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        // Kurz, lang und doppelt werden selbst unterschieden (siehe handlePlayPause…), der Erkenner bleibt aus,
        // sonst lösen Doppeltipps zusätzlich die Aktion für den einfachen Druck aus.
        _playPauseDoubleTapRecognizer.enabled = NO;
        [rootView addGestureRecognizer:_playPauseDoubleTapRecognizer];

        _manualScrollPanRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleManualScrollPan:)];
        _manualScrollPanRecognizer.allowedTouchTypes = @[ @(UITouchTypeIndirect) ];
        _manualScrollPanRecognizer.cancelsTouchesInView = NO;
        _manualScrollPanRecognizer.enabled = NO;
        [rootView addGestureRecognizer:_manualScrollPanRecognizer];
    }
    return self;
}

- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled {
    BOOL wasCursorModeEnabled = self.cursorModeEnabled;
    _cursorModeEnabled = cursorModeEnabled;
    self.lastTouchLocation = CGPointMake(-1, -1);
    [self stopManualScrollInertia];
    [self refreshInteractionState];
    if (!wasCursorModeEnabled && cursorModeEnabled) {
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (BOOL)pointerOverlaysSuppressed {
    return !self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerTopBarFocusActive];
}

- (void)refreshInteractionState {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    BOOL topBarFocusActive = [self.host browserRemoteInputControllerTopBarFocusActive];
    BOOL shouldAllowWebInteraction = !self.cursorModeEnabled &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        !topBarFocusActive;
    scrollView.scrollEnabled = shouldAllowWebInteraction;
    self.manualScrollPanRecognizer.enabled = shouldAllowWebInteraction;
    [self.host browserRemoteInputControllerSetWebInteractionEnabled:shouldAllowWebInteraction];
    self.cursorView.hidden = !self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        topBarFocusActive;
    if ([self pointerOverlaysSuppressed]) {
        [self clearSnapAnimated:NO];
    }
}

#pragma mark - Zeigerposition und Einrasten

- (CGRect)pointerBounds {
    CGRect bounds = self.rootView.bounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = [UIScreen mainScreen].bounds;
    }
    return bounds;
}

- (BOOL)targetAllowsCenterSnap:(CGRect)target {
    return CGRectGetWidth(target) <= kMaxCenterSnapWidth && CGRectGetHeight(target) <= kMaxCenterSnapHeight;
}

/// Bestes Ziel für die Fingerposition: das kleinste, das den Punkt enthält, sonst das nächste im Einrastradius.
- (CGRect)bestTargetForPoint:(CGPoint)point {
    NSArray<NSValue *> *targets = [self.host browserRemoteInputControllerPointerTargets];
    CGRect best = CGRectNull;
    CGFloat bestArea = CGFLOAT_MAX;
    CGFloat bestDistance = CGFLOAT_MAX;
    BOOL bestContains = NO;
    for (NSValue *value in targets) {
        CGRect rect = value.CGRectValue;
        if (CGRectIsEmpty(rect)) {
            continue;
        }
        if (CGRectContainsPoint(rect, point)) {
            CGFloat area = CGRectGetWidth(rect) * CGRectGetHeight(rect);
            if (!bestContains || area < bestArea) {
                best = rect;
                bestArea = area;
                bestContains = YES;
            }
            continue;
        }
        if (bestContains) {
            continue;
        }
        CGFloat dx = MAX(MAX(CGRectGetMinX(rect) - point.x, 0.0), point.x - CGRectGetMaxX(rect));
        CGFloat dy = MAX(MAX(CGRectGetMinY(rect) - point.y, 0.0), point.y - CGRectGetMaxY(rect));
        CGFloat distance = hypot(dx, dy);
        if (distance <= kSnapRadius && distance < bestDistance) {
            best = rect;
            bestDistance = distance;
        }
    }
    return best;
}

- (void)updatePointerAnimated:(BOOL)animated {
    if ([self pointerOverlaysSuppressed]) {
        [self placeCursorAtPoint:self.freePoint animated:NO];
        [self clearSnapAnimated:NO];
        return;
    }

    CGRect current = self.snappedTarget;
    BOOL keepCurrent = !CGRectIsNull(current) &&
        CGRectContainsPoint(CGRectInset(current, -kReleaseMargin, -kReleaseMargin), self.freePoint);
    CGRect target = keepCurrent ? [self refreshedTargetMatching:current] : [self bestTargetForPoint:self.freePoint];
    BOOL targetChanged = !CGRectEqualToRect(target, current);
    self.snappedTarget = target;

    if (CGRectIsNull(target)) {
        [self placeCursorAtPoint:self.freePoint animated:NO];
        self.cursorView.image = BrowserDefaultCursor();
        [self setCursorImageVisible:YES];
        [self clearSnapAnimated:animated];
        return;
    }

    BOOL centerSnap = [self targetAllowsCenterSnap:target];
    CGPoint cursorPoint = centerSnap ? CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target)) : self.freePoint;
    [self placeCursorAtPoint:cursorPoint animated:animated && targetChanged];
    // Eingerastet: Pfeil ausblenden, die Hervorhebung ist der Zeiger. Bei großen Zielen bleibt die Hand sichtbar.
    self.cursorView.image = BrowserPointerCursor();
    [self setCursorImageVisible:!centerSnap];
    [self showHighlightForTarget:target animated:animated];
}

/// Nach einer neuen Meldung der Seite das passende Ziel wiederfinden (gleiches Element, neue Lage).
- (CGRect)refreshedTargetMatching:(CGRect)previous {
    NSArray<NSValue *> *targets = [self.host browserRemoteInputControllerPointerTargets];
    for (NSValue *value in targets) {
        if (CGRectEqualToRect(value.CGRectValue, previous)) {
            return previous;
        }
    }
    // Gleich großes Ziel in der Nähe (Seite hat gescrollt) oder neu bestimmen.
    for (NSValue *value in targets) {
        CGRect rect = value.CGRectValue;
        if (fabs(CGRectGetWidth(rect) - CGRectGetWidth(previous)) < 1.0 &&
            fabs(CGRectGetHeight(rect) - CGRectGetHeight(previous)) < 1.0 &&
            CGRectContainsPoint(CGRectInset(rect, -kReleaseMargin, -kReleaseMargin), self.freePoint)) {
            return rect;
        }
    }
    return [self bestTargetForPoint:self.freePoint];
}

- (void)placeCursorAtPoint:(CGPoint)point animated:(BOOL)animated {
    CGRect frame = self.cursorView.frame;
    frame.origin = point;
    if (animated) {
        [UIView animateWithDuration:0.09
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self.cursorView.frame = frame; }
                         completion:nil];
    } else {
        self.cursorView.frame = frame;
    }
}

- (void)setCursorImageVisible:(BOOL)visible {
    CGFloat alpha = (visible && !self.cursorIdleHidden) ? 1.0 : 0.0;
    if (self.cursorView.alpha != alpha) {
        [UIView animateWithDuration:0.12 animations:^{ self.cursorView.alpha = alpha; }];
    }
}

- (void)showHighlightForTarget:(CGRect)target animated:(BOOL)animated {
    UIView *highlight = self.highlightView;
    if (highlight.superview != self.rootView) {
        [highlight removeFromSuperview];
    }
    [self.rootView insertSubview:highlight belowSubview:self.cursorView];
    CGRect frame = CGRectInset(target, -6.0, -6.0);
    CGFloat radius = MIN(16.0, CGRectGetHeight(frame) / 2.0);
    void (^apply)(void) = ^{
        highlight.frame = frame;
        highlight.layer.cornerRadius = radius;
        highlight.alpha = self.cursorIdleHidden ? 0.0 : 1.0;
    };
    if (animated && highlight.alpha > 0.0) {
        [UIView animateWithDuration:0.12
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:apply
                         completion:nil];
    } else {
        [UIView performWithoutAnimation:^{ highlight.frame = frame; highlight.layer.cornerRadius = radius; }];
        [UIView animateWithDuration:animated ? 0.12 : 0.0 animations:^{ highlight.alpha = self.cursorIdleHidden ? 0.0 : 1.0; }];
    }
}

- (void)clearSnapAnimated:(BOOL)animated {
    self.snappedTarget = CGRectNull;
    if (self.highlightView.alpha > 0.0) {
        [UIView animateWithDuration:animated ? 0.12 : 0.0 animations:^{ self.highlightView.alpha = 0.0; }];
    }
    [self setCursorImageVisible:YES];
}

- (void)pointerTargetsDidChange {
    if (self.lastTouchLocation.x != -1 || self.pressInProgress) {
        // Während der Finger wischt, bewertet die nächste Bewegung ohnehin neu.
        return;
    }
    [self updatePointerAnimated:YES];
}

#pragma mark - Zeiger ausblenden bei Nichtbenutzung

- (void)scheduleIdleHide {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideCursorForIdle) object:nil];
    [self performSelector:@selector(hideCursorForIdle) withObject:nil afterDelay:kCursorIdleHideDelay];
}

- (void)hideCursorForIdle {
    if ([self pointerOverlaysSuppressed]) {
        return;
    }
    self.cursorIdleHidden = YES;
    [UIView animateWithDuration:0.35 animations:^{
        self.cursorView.alpha = 0.0;
        self.highlightView.alpha = 0.0;
    }];
}

/// Zeiger wieder einblenden. Gibt YES zurück, wenn er vorher ausgeblendet war.
- (BOOL)revealCursorIfIdle {
    [self scheduleIdleHide];
    if (!self.cursorIdleHidden) {
        return NO;
    }
    self.cursorIdleHidden = NO;
    [self updatePointerAnimated:NO];
    [UIView animateWithDuration:0.15 animations:^{
        if (!CGRectIsNull(self.snappedTarget)) {
            self.highlightView.alpha = 1.0;
        }
    }];
    return YES;
}

#pragma mark - Scrollen

- (BOOL)applyManualScrollDelta:(CGPoint)delta {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    if (scrollView == nil) {
        return NO;
    }

    CGPoint contentOffset = scrollView.contentOffset;
    CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
    CGFloat maxOffsetY = MAX(0.0, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds));
    CGFloat nextOffsetX = MIN(MAX(contentOffset.x + delta.x, 0.0), maxOffsetX);
    CGFloat nextOffsetY = MIN(MAX(contentOffset.y + delta.y, 0.0), maxOffsetY);
    CGPoint nextOffset = CGPointMake(nextOffsetX, nextOffsetY);
    [scrollView setContentOffset:nextOffset animated:NO];
    return !CGPointEqualToPoint(contentOffset, nextOffset);
}

- (void)scrollPageByFraction:(CGFloat)fraction {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    if (scrollView == nil) {
        return;
    }
    CGFloat maxOffsetY = MAX(0.0, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds));
    CGFloat delta = CGRectGetHeight(scrollView.bounds) * fraction;
    CGPoint offset = scrollView.contentOffset;
    offset.y = MIN(MAX(offset.y + delta, 0.0), maxOffsetY);
    [self clearSnapAnimated:YES];
    [UIView animateWithDuration:0.28
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [scrollView setContentOffset:offset animated:NO]; }
                     completion:^(__unused BOOL finished) {
        [self.host browserRemoteInputControllerPersistSession];
        [self updatePointerAnimated:YES];
    }];
}

- (void)stopManualScrollInertia {
    [self.manualScrollDisplayLink invalidate];
    self.manualScrollDisplayLink = nil;
    self.manualScrollVelocity = CGPointZero;
    self.manualScrollLastTimestamp = 0;
    self.manualScrollLastMovementTimestamp = 0;
}

- (void)startManualScrollInertiaWithVelocity:(CGPoint)velocity {
    [self stopManualScrollInertia];
    if (fabs(velocity.x) < 25.0 && fabs(velocity.y) < 25.0) {
        return;
    }

    self.manualScrollVelocity = velocity;
    self.manualScrollLastTimestamp = 0;
    self.manualScrollDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleManualScrollDisplayLink:)];
    [self.manualScrollDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)handleManualScrollDisplayLink:(CADisplayLink *)displayLink {
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerTopBarFocusActive]) {
        [self stopManualScrollInertia];
        return;
    }

    if (self.manualScrollLastTimestamp <= 0) {
        self.manualScrollLastTimestamp = displayLink.timestamp;
        return;
    }

    CFTimeInterval deltaTime = displayLink.timestamp - self.manualScrollLastTimestamp;
    self.manualScrollLastTimestamp = displayLink.timestamp;

    CGPoint step = CGPointMake(self.manualScrollVelocity.x * deltaTime, self.manualScrollVelocity.y * deltaTime);
    BOOL didMove = [self applyManualScrollDelta:step];

    CGFloat decay = pow(0.92, deltaTime * 60.0);
    self.manualScrollVelocity = CGPointMake(self.manualScrollVelocity.x * decay, self.manualScrollVelocity.y * decay);

    if (!didMove ||
        (fabs(self.manualScrollVelocity.x) < 10.0 && fabs(self.manualScrollVelocity.y) < 10.0)) {
        [self stopManualScrollInertia];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)handleManualScrollPan:(UIPanGestureRecognizer *)gestureRecognizer {
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        [self stopManualScrollInertia];
    }

    CGPoint translation = [gestureRecognizer translationInView:self.rootView];
    if (!CGPointEqualToPoint(translation, CGPointZero)) {
        [self applyManualScrollDelta:CGPointMake(-translation.x, -translation.y)];
        [gestureRecognizer setTranslation:CGPointZero inView:self.rootView];
        self.manualScrollLastMovementTimestamp = CACurrentMediaTime();
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        CFTimeInterval timeSinceLastMovement = CACurrentMediaTime() - self.manualScrollLastMovementTimestamp;
        CGPoint velocity = [gestureRecognizer velocityInView:self.rootView];
        if (timeSinceLastMovement < 0.08) {
            [self startManualScrollInertiaWithVelocity:CGPointMake(-velocity.x, -velocity.y)];
        } else {
            [self stopManualScrollInertia];
        }
        [self.host browserRemoteInputControllerPersistSession];
    } else if (gestureRecognizer.state == UIGestureRecognizerStateCancelled ||
               gestureRecognizer.state == UIGestureRecognizerStateFailed) {
        [self stopManualScrollInertia];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

#pragma mark - Klick

- (void)handleGlobalSelectPressEndedNotification {
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }
    // Derselbe Druck kommt auch direkt an. Doppelte Zustellung verwerfen.
    if ((CACurrentMediaTime() - self.lastDirectSelectPressTimestamp) < 0.15) {
        return;
    }
    self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
    [self performSelectAction];
}

/// Klick sofort ausführen. Der frühere Doppelklick (Umschalten in den Scrollmodus) entfällt,
/// damit kein Klick mehr 0,3 Sekunden warten muss.
- (void)performSelectAction {
    self.lastTouchLocation = CGPointMake(-1, -1);
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
        return;
    }
    if ([self revealCursorIfIdle]) {
        // Erster Druck nach einer Pause zeigt nur den Zeiger.
        return;
    }
    [self.host browserRemoteInputControllerHandlePrimaryAction];
}

- (void)handlePlayPauseDoubleTap:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerDismissTabOverview];
        return;
    }
    [self.host browserRemoteInputControllerHandleAdvancedMenuPress];
}

#pragma mark - Play/Pause

static const NSTimeInterval kPlayPauseLongPressDelay = 0.6;
static const NSTimeInterval kPlayPauseDoublePressWindow = 0.3;

- (BOOL)playPauseTimingApplies {
    UIViewController *presented = [self.host browserRemoteInputControllerPresentedViewController];
    if (presented != nil && ![presented isKindOfClass:UIAlertController.class]) {
        return NO;
    }
    return ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        ![self.host browserRemoteInputControllerTopBarFocusActive];
}

- (void)playPausePressBegan {
    self.playPauseLongPressFired = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(firePlayPauseLongPress) object:nil];
    if ([self playPauseTimingApplies]) {
        [self performSelector:@selector(firePlayPauseLongPress) withObject:nil afterDelay:kPlayPauseLongPressDelay];
    }
}

- (void)firePlayPauseLongPress {
    self.playPauseLongPressFired = YES;
    self.playPauseSinglePending = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(firePlayPauseSinglePress) object:nil];
    [self.host browserRemoteInputControllerHandlePlayPauseLongPress];
}

- (void)firePlayPauseSinglePress {
    self.playPauseSinglePending = NO;
    [self.host browserRemoteInputControllerHandlePlayPausePress];
}

- (void)playPausePressEnded {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(firePlayPauseLongPress) object:nil];
    if (self.playPauseLongPressFired) {
        self.playPauseLongPressFired = NO;
        return;
    }
    if (self.playPauseSinglePending) {
        self.playPauseSinglePending = NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(firePlayPauseSinglePress) object:nil];
        [self.host browserRemoteInputControllerHandleAdvancedMenuPress];
        return;
    }
    self.playPauseSinglePending = YES;
    [self performSelector:@selector(firePlayPauseSinglePress) withObject:nil afterDelay:kPlayPauseDoublePressWindow];
}

#pragma mark - Tasten

- (BOOL)isClickpadPress:(UIPress *)press {
    switch (press.type) {
        case UIPressTypeSelect:
        case UIPressTypeUpArrow:
        case UIPressTypeDownArrow:
        case UIPressTypeLeftArrow:
        case UIPressTypeRightArrow:
            return YES;
        default:
            return NO;
    }
}

- (void)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    for (UIPress *press in presses) {
        if (press.type == UIPressTypePlayPause) {
            [self playPausePressBegan];
        }
        if ([self isClickpadPress:press]) {
            // Beim Drücken bewegt sich der Finger minimal. Diese Bewegung soll den Zeiger nicht verschieben.
            self.pressInProgress = YES;
        }
    }
}

- (void)handlePressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)presses;
    (void)event;
    self.pressInProgress = NO;
    self.lastTouchLocation = CGPointMake(-1, -1);
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(firePlayPauseLongPress) object:nil];
    self.playPauseLongPressFired = NO;
}

- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    UIPress *press = presses.anyObject;
    if (press == nil) {
        return NO;
    }
    if ([self isClickpadPress:press]) {
        self.pressInProgress = NO;
        self.lastTouchLocation = CGPointMake(-1, -1);
    }

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypeDownArrow) {
            [self.host browserRemoteInputControllerDeactivateTopBarFocus];
            return YES;
        }
        if (press.type == UIPressTypePlayPause) {
            return YES;
        }
        if (press.type == UIPressTypeSelect ||
            press.type == UIPressTypeLeftArrow ||
            press.type == UIPressTypeRightArrow ||
            press.type == UIPressTypeUpArrow) {
            return NO;
        }
    }

    UIViewController *presentedViewController = [self.host browserRemoteInputControllerPresentedViewController];
    if (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]]) {
        if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
            if (press.type == UIPressTypeMenu) {
                [self.host browserRemoteInputControllerDismissTabOverview];
                return YES;
            }
            if (press.type == UIPressTypePlayPause) {
                [self.host browserRemoteInputControllerHandleTabOverviewAlternateAction];
                return YES;
            }
            return NO;
        }
        if (press.type == UIPressTypeMenu) {
            [presentedViewController dismissViewControllerAnimated:YES completion:nil];
            return YES;
        }
        return YES;
    }

    if (press.type == UIPressTypeSelect) {
        if ((CACurrentMediaTime() - self.lastDirectSelectPressTimestamp) < 0.15) {
            return YES;
        }
        self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
        [self performSelectAction];
        return YES;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
            [self.host browserRemoteInputControllerDismissTabOverview];
            return YES;
        }
        return NO;
    }

    if (presentedViewController == nil && self.cursorModeEnabled) {
        switch (press.type) {
            case UIPressTypeUpArrow:
                [self revealCursorIfIdle];
                // Zweimal kurz hintereinander oben: in die Adressleiste.
                if (CACurrentMediaTime() - self.lastUpPressTimestamp < 0.4) {
                    self.lastUpPressTimestamp = 0;
                    [self.host browserRemoteInputControllerOpenAddressBar];
                    return YES;
                }
                self.lastUpPressTimestamp = CACurrentMediaTime();
                [self scrollPageByFraction:-kPageScrollFraction];
                return YES;
            case UIPressTypeDownArrow:
                [self revealCursorIfIdle];
                [self scrollPageByFraction:kPageScrollFraction];
                return YES;
            case UIPressTypeLeftArrow:
                [self.host browserRemoteInputControllerNavigateBack];
                return YES;
            case UIPressTypeRightArrow:
                [self.host browserRemoteInputControllerNavigateForward];
                return YES;
            default:
                break;
        }
    }

    if (press.type == UIPressTypeMenu) {
        return [self.host browserRemoteInputControllerHandleMenuPress];
    }
    if (press.type == UIPressTypePlayPause) {
        if ([self playPauseTimingApplies]) {
            [self playPausePressEnded];
        } else {
            [self.host browserRemoteInputControllerHandlePlayPausePress];
        }
        return YES;
    }
    return NO;
}

#pragma mark - Wischen

- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }
    self.lastTouchLocation = CGPointMake(-1, -1);
    self.lastTouchTimestamp = 0;
    [self resetRotation];
    self.gestureStartPoint = self.freePoint;
    self.gestureStartTarget = self.snappedTarget;
    // Erste Berührung nach einer Pause zeigt nur den Zeiger, diese Wischbewegung verschiebt ihn nicht.
    self.revealOnlyTouch = [self revealCursorIfIdle];
    return YES;
}

/// Beschleunigung: langsames Wischen bleibt präzise, schnelles Wischen trägt weit.
- (CGFloat)gainForSpeed:(CGFloat)pointsPerSecond {
    CGFloat speedSetting = [[NSUserDefaults standardUserDefaults] objectForKey:@"PointerSpeed"] != nil
        ? [[NSUserDefaults standardUserDefaults] doubleForKey:@"PointerSpeed"]
        : 1.0;
    CGFloat normalized = MIN(MAX((pointsPerSecond - 150.0) / 1600.0, 0.0), 1.0);
    CGFloat gain = 0.75 + normalized * normalized * 1.85;
    return gain * MIN(MAX(speedSetting, 0.3), 3.0);
}

- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return NO;
    }
    BOOL tabOverviewVisible = [self.host browserRemoteInputControllerTabOverviewVisible];
    if (!self.cursorModeEnabled) {
        return NO;
    }

    UITouch *touch = touches.anyObject;
    if (touch == nil) {
        return YES;
    }
    // In Bildschirmkoordinaten messen, nicht in der (scrollenden) WebView.
    CGPoint location = [touch locationInView:self.rootView];
    NSTimeInterval timestamp = touch.timestamp;

    if (self.lastTouchLocation.x == -1 && self.lastTouchLocation.y == -1) {
        self.lastTouchLocation = location;
        self.lastTouchTimestamp = timestamp;
        return YES;
    }

    CGFloat dx = location.x - self.lastTouchLocation.x;
    CGFloat dy = location.y - self.lastTouchLocation.y;
    NSTimeInterval dt = MAX(timestamp - self.lastTouchTimestamp, 1.0 / 240.0);
    self.lastTouchLocation = location;
    self.lastTouchTimestamp = timestamp;

    if (self.pressInProgress || self.revealOnlyTouch) {
        return YES;
    }
    [self scheduleIdleHide];

    if (!tabOverviewVisible && [self trackRotationWithDelta:CGPointMake(dx, dy)]) {
        return YES;
    }

    CGFloat gain = [self gainForSpeed:hypot(dx, dy) / dt];
    CGPoint next = CGPointMake(self.freePoint.x + dx * gain, self.freePoint.y + dy * gain);

    // An die Ränder begrenzen (gemessen an der Klickspitze). Was darüber hinausgeht, scrollt die Seite.
    CGRect bounds = [self pointerBounds];
    CGFloat maxX = CGRectGetMaxX(bounds) - 2.0;
    CGFloat maxY = CGRectGetMaxY(bounds) - 2.0;
    CGPoint overflow = CGPointZero;
    if (next.x < CGRectGetMinX(bounds)) { overflow.x = next.x - CGRectGetMinX(bounds); next.x = CGRectGetMinX(bounds); }
    if (next.x > maxX) { overflow.x = next.x - maxX; next.x = maxX; }
    if (next.y < CGRectGetMinY(bounds)) { overflow.y = next.y - CGRectGetMinY(bounds); next.y = CGRectGetMinY(bounds); }
    if (next.y > maxY) { overflow.y = next.y - maxY; next.y = maxY; }
    self.freePoint = next;

    if (tabOverviewVisible) {
        [self placeCursorAtPoint:next animated:NO];
        self.cursorView.image = [self.host browserRemoteInputControllerTabOverviewContainsPoint:next]
            ? BrowserPointerCursor()
            : BrowserDefaultCursor();
        [self setCursorImageVisible:YES];
        return YES;
    }

    if (!CGPointEqualToPoint(overflow, CGPointZero)) {
        [self applyManualScrollDelta:CGPointMake(overflow.x * 2.0, overflow.y * 2.0)];
    }
    [self updatePointerAnimated:YES];
    return YES;
}

#pragma mark - Kreisgeste (Clickpad-Ring)

static const CGFloat kRotationSegmentLength = 14.0;
static const CGFloat kRotationEnterAngle = 200.0 * M_PI / 180.0;
static const CGFloat kRotationStepAngle = 60.0 * M_PI / 180.0;
static const CGFloat kRotationMaxTurnPerSegment = 1.3;

- (void)resetRotation {
    self.rotationSegment = CGPointZero;
    self.rotationHasHeading = NO;
    self.rotationAccumulated = 0;
    self.rotationStepAccumulated = 0;
    self.rotationMode = NO;
}

/// Sammelt die Drehung der Wischrichtung. YES, solange die Bewegung als Kreisgeste gilt (Zeiger bleibt dann stehen).
- (BOOL)trackRotationWithDelta:(CGPoint)delta {
    CGPoint segment = CGPointMake(self.rotationSegment.x + delta.x, self.rotationSegment.y + delta.y);
    if (hypot(segment.x, segment.y) < kRotationSegmentLength) {
        self.rotationSegment = segment;
        return self.rotationMode;
    }
    self.rotationSegment = CGPointZero;
    CGFloat heading = atan2(segment.y, segment.x);
    if (!self.rotationHasHeading) {
        self.rotationHasHeading = YES;
        self.rotationLastHeading = heading;
        return self.rotationMode;
    }
    CGFloat turn = heading - self.rotationLastHeading;
    while (turn > M_PI) { turn -= 2.0 * M_PI; }
    while (turn < -M_PI) { turn += 2.0 * M_PI; }
    self.rotationLastHeading = heading;

    if (!self.rotationMode) {
        // Knick oder Richtungswechsel: kein Kreis, neu zählen.
        if (fabs(turn) > kRotationMaxTurnPerSegment || (self.rotationAccumulated != 0 && turn * self.rotationAccumulated < 0 && fabs(turn) > 0.35)) {
            self.rotationAccumulated = 0;
            return NO;
        }
        self.rotationAccumulated += turn;
        if (fabs(self.rotationAccumulated) < kRotationEnterAngle) {
            return NO;
        }
        // Kreis erkannt: Zeiger dahin zurück, wo die Geste begann, dann einen Schritt weiter.
        self.rotationMode = YES;
        self.rotationStepAccumulated = 0;
        self.freePoint = self.gestureStartPoint;
        self.snappedTarget = self.gestureStartTarget;
        [self updatePointerAnimated:NO];
        [self stepTargetBy:self.rotationAccumulated > 0 ? 1 : -1];
        return YES;
    }

    self.rotationStepAccumulated += turn;
    if (fabs(self.rotationStepAccumulated) >= kRotationStepAngle) {
        NSInteger direction = self.rotationStepAccumulated > 0 ? 1 : -1;
        self.rotationStepAccumulated -= direction * kRotationStepAngle;
        [self stepTargetBy:direction];
    }
    return YES;
}

/// Zum nächsten (1) bzw. vorherigen (-1) Element in Leserichtung springen.
- (void)stepTargetBy:(NSInteger)direction {
    NSArray<NSValue *> *targets = [[self.host browserRemoteInputControllerPointerTargets] sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGRect ra = a.CGRectValue, rb = b.CGRectValue;
        CGFloat rowA = round(CGRectGetMidY(ra) / 24.0), rowB = round(CGRectGetMidY(rb) / 24.0);
        if (rowA != rowB) {
            return rowA < rowB ? NSOrderedAscending : NSOrderedDescending;
        }
        return CGRectGetMidX(ra) < CGRectGetMidX(rb) ? NSOrderedAscending : NSOrderedDescending;
    }];
    if (targets.count == 0) {
        return;
    }
    NSInteger index = NSNotFound;
    CGFloat bestDistance = CGFLOAT_MAX;
    CGPoint reference = CGRectIsNull(self.snappedTarget) ? self.freePoint
        : CGPointMake(CGRectGetMidX(self.snappedTarget), CGRectGetMidY(self.snappedTarget));
    for (NSUInteger i = 0; i < targets.count; i++) {
        CGRect rect = targets[i].CGRectValue;
        CGFloat distance = hypot(CGRectGetMidX(rect) - reference.x, CGRectGetMidY(rect) - reference.y);
        if (distance < bestDistance) {
            bestDistance = distance;
            index = (NSInteger)i;
        }
    }
    BOOL onTarget = !CGRectIsNull(self.snappedTarget) && bestDistance < 2.0;
    NSInteger next = onTarget ? index + direction : (direction > 0 ? index : index);
    next = MIN(MAX(next, 0), (NSInteger)targets.count - 1);
    CGRect target = targets[next].CGRectValue;
    self.freePoint = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    self.snappedTarget = CGRectNull;
    [self updatePointerAnimated:YES];
}

#if DEBUG
- (NSInteger)debugRunGestureWithDeltas:(NSArray<NSValue *> *)deltas {
    [self resetRotation];
    self.gestureStartPoint = self.freePoint;
    self.gestureStartTarget = self.snappedTarget;
    NSInteger rotatingSamples = 0;
    for (NSValue *value in deltas) {
        if ([self trackRotationWithDelta:value.CGPointValue]) {
            rotatingSamples += 1;
        }
    }
    BOOL mode = self.rotationMode;
    [self resetRotation];
    return mode ? rotatingSamples : 0;
}
#endif

- (void)movePointerToPoint:(CGPoint)point {
    self.cursorIdleHidden = NO;
    self.freePoint = point;
    [self updatePointerAnimated:YES];
    [self scheduleIdleHide];
}

- (void)handleTouchesEnded {
    self.lastTouchLocation = CGPointMake(-1, -1);
    [self resetRotation];
    self.revealOnlyTouch = NO;
    [self scheduleIdleHide];
}

@end
