#import <GameController/GameController.h>
#import <objc/message.h>
#import "BrowserRemoteInputController.h"
#import "BrowserMotion.h"
#import "BrowserPreferencesStore.h"
#import "BrowserCursorRenderer.h"

static UIImage *BrowserDefaultCursor(void) {
    return [BrowserCursorRenderer imageForKind:BrowserCursorKindArrow];
}

static UIImage *BrowserPointerCursor(void) {
    return [BrowserCursorRenderer imageForKind:BrowserCursorKindHand];
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

/// Glasartige Fläche für die Zielmarkierung: Tönung, Glanzverlauf, helle Lichtkante, dunkle Haarlinie außen.
@interface BrowserGlassHighlightSurfaceView : UIView
@property (nonatomic, strong) CAGradientLayer *glossLayer;
@property (nonatomic, strong) CAGradientLayer *rimLayer;
@property (nonatomic, strong) CAShapeLayer *rimMask;
@end

@implementation BrowserGlassHighlightSurfaceView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
        self.layer.borderWidth = 0.75;
        self.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.18].CGColor;

        _glossLayer = [CAGradientLayer layer];
        _glossLayer.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.34].CGColor,
                               (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        _glossLayer.locations = @[@0.0, @0.55];
        [self.layer addSublayer:_glossLayer];

        // Lichtkante: oben hell, unten schwächer, als 1,5-pt-Ring maskiert.
        _rimLayer = [CAGradientLayer layer];
        _rimLayer.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.95].CGColor,
                             (id)[UIColor colorWithWhite:1.0 alpha:0.35].CGColor];
        _rimMask = [CAShapeLayer layer];
        _rimMask.fillColor = UIColor.clearColor.CGColor;
        _rimMask.strokeColor = UIColor.blackColor.CGColor;
        _rimMask.lineWidth = 3.0;
        _rimLayer.mask = _rimMask;
        [self.layer addSublayer:_rimLayer];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.glossLayer.frame = self.bounds;
    self.rimLayer.frame = self.bounds;
    self.rimMask.frame = self.bounds;
    self.rimMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 0.75, 0.75)
                                                   cornerRadius:MAX(0.0, self.layer.cornerRadius - 0.75)].CGPath;
    [CATransaction commit];
}

@end

/// Leuchten rund um die Form. Einfarbig: weicher Schein über den Ebenenschatten (wie die Tab-Übersicht).
/// Regenbogen (Standard), angelehnt an das Leuchten von Apple Intelligence: ein umlaufender Farbring, der wirklich
/// weichgezeichnet wird (Gauß-Filter des Render-Servers), dazu eine schmale, gesättigte Lichtkante direkt am Rand.
/// Aufbau je Leuchtschicht: Hülle (Weichzeichner, steht still) → Ring (Maske, steht still) → Farbverlauf (dreht sich).
/// So dreht sich nur die Farbe, und der Weichzeichner wirkt auf den fertig maskierten Ring – nicht auf ein Band
/// mit Transparenz. Innen spart die Maske der Ansicht alles aus, damit das Licht nicht durch die Glasfläche fällt.
@interface BrowserGlowView : UIView
@property (nonatomic, strong) CAShapeLayer *maskLayer;
@property (nonatomic) BOOL rainbow;
@property (nonatomic, strong) NSArray<CALayer *> *glowWrappers;      // Hüllen mit Weichzeichner
@property (nonatomic, strong) NSArray<CALayer *> *ringContainers;    // maskierte Ringe
@property (nonatomic, strong) NSArray<CAShapeLayer *> *ringMasks;
@property (nonatomic, strong) NSArray<CAGradientLayer *> *gradients;
@property (nonatomic, strong) NSArray<NSNumber *> *ringWidths;
- (void)setGlowColor:(UIColor *)color;
- (void)setShapeSize:(CGSize)size cornerRadius:(CGFloat)radius animated:(BOOL)animated;
@end

@implementation BrowserGlowView

static CGFloat const kGlowMargin = 90.0;

+ (NSArray *)rainbowColors {
    // Farben angelehnt an das erste Apple-Intelligence-Leuchten: Blau, Violett, Pink, Orange – und zurück.
    NSArray<UIColor *> *colors = @[
        [UIColor colorWithRed:0.20 green:0.60 blue:1.00 alpha:1.0],
        [UIColor colorWithRed:0.62 green:0.40 blue:1.00 alpha:1.0],
        [UIColor colorWithRed:0.98 green:0.36 blue:0.78 alpha:1.0],
        [UIColor colorWithRed:1.00 green:0.45 blue:0.35 alpha:1.0],
        [UIColor colorWithRed:1.00 green:0.70 blue:0.30 alpha:1.0],
        [UIColor colorWithRed:0.98 green:0.36 blue:0.78 alpha:1.0],
        [UIColor colorWithRed:0.20 green:0.60 blue:1.00 alpha:1.0],
    ];
    NSMutableArray *cg = [NSMutableArray array];
    for (UIColor *color in colors) {
        [cg addObject:(id)color.CGColor];
    }
    return cg;
}

/// Gauß-Weichzeichner des Render-Servers (CAFilter, privat; läuft auf der GPU). Nil, falls nicht vorhanden.
static id BrowserGlowBlurFilter(CGFloat radius) {
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL make = NSSelectorFromString(@"filterWithType:");
    if (filterClass == Nil || ![filterClass respondsToSelector:make]) {
        return nil;
    }
    id filter = ((id (*)(id, SEL, id))objc_msgSend)(filterClass, make, @"gaussianBlur");
    [filter setValue:@(radius) forKey:@"inputRadius"];
    return filter;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.layer.shadowColor = [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0].CGColor;
        self.layer.shadowOffset = CGSizeZero;
        self.layer.shadowOpacity = 0.95;
        self.layer.shadowRadius = 17.0;
        _maskLayer = [CAShapeLayer layer];
        _maskLayer.fillRule = kCAFillRuleEvenOdd;
        self.layer.mask = _maskLayer;

        // Schichten von außen nach innen: weiter Lichthof, kräftiger naher Schein, scharfe Lichtkante.
        NSArray<NSArray<NSNumber *> *> *specs = @[
            @[@22.0, @30.0, @0.85],   // Ringbreite, Weichzeichner-Radius, Deckkraft
            @[@8.0, @9.0, @1.0],
            @[@3.0, @0.0, @1.0],
        ];
        NSMutableArray *wrappers = [NSMutableArray array];
        NSMutableArray *containers = [NSMutableArray array];
        NSMutableArray *masks = [NSMutableArray array];
        NSMutableArray *gradients = [NSMutableArray array];
        NSMutableArray *widths = [NSMutableArray array];
        for (NSArray<NSNumber *> *spec in specs) {
            CALayer *wrapper = [CALayer layer];
            CGFloat blur = spec[1].doubleValue;
            id filter = blur > 0.0 ? BrowserGlowBlurFilter(blur) : nil;
            if (filter != nil) {
                wrapper.filters = @[filter];
            }
            wrapper.opacity = spec[2].floatValue;
            CALayer *container = [CALayer layer];
            CAGradientLayer *gradient = [CAGradientLayer layer];
            gradient.type = kCAGradientLayerConic;
            gradient.startPoint = CGPointMake(0.5, 0.5);
            gradient.endPoint = CGPointMake(0.5, 0.0);
            gradient.colors = [BrowserGlowView rainbowColors];
            [container addSublayer:gradient];
            CAShapeLayer *mask = [CAShapeLayer layer];
            mask.fillColor = UIColor.clearColor.CGColor;
            mask.strokeColor = UIColor.blackColor.CGColor;
            mask.lineWidth = spec[0].doubleValue;
            if (filter == nil && blur > 0.0) {
                // Rückfall ohne Weichzeichner: weicher Rand über den Maskenschatten.
                mask.shadowColor = UIColor.blackColor.CGColor;
                mask.shadowOffset = CGSizeZero;
                mask.shadowOpacity = 1.0;
                mask.shadowRadius = blur;
            }
            container.mask = mask;
            [wrapper addSublayer:container];
            [self.layer addSublayer:wrapper];
            [wrappers addObject:wrapper];
            [containers addObject:container];
            [masks addObject:mask];
            [gradients addObject:gradient];
            [widths addObject:spec[0]];
        }
        _glowWrappers = wrappers;
        _ringContainers = containers;
        _ringMasks = masks;
        _gradients = gradients;
        _ringWidths = widths;
        self.rainbow = YES;
    }
    return self;
}

- (void)setRainbow:(BOOL)rainbow {
    _rainbow = rainbow;
    for (CALayer *wrapper in self.glowWrappers) {
        wrapper.hidden = !rainbow;
    }
    // Einfarbig: wie bisher über den Schatten der Ebene. Regenbogen: Schatten aus, die Ringe leuchten selbst.
    self.layer.shadowOpacity = rainbow ? 0.0 : 0.95;
    if (rainbow) {
        [self startRotation];
    } else {
        for (CAGradientLayer *gradient in self.gradients) {
            [gradient removeAnimationForKey:@"spin"];
        }
        [self.glowWrappers.firstObject removeAnimationForKey:@"breathe"];
    }
}

- (void)startRotation {
    for (CAGradientLayer *gradient in self.gradients) {
        if ([gradient animationForKey:@"spin"] != nil) {
            continue;
        }
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0.0;
        spin.toValue = @(M_PI * 2.0);
        spin.duration = 3.6;
        spin.repeatCount = HUGE_VALF;
        spin.removedOnCompletion = NO;
        [gradient addAnimation:spin forKey:@"spin"];
    }
    // Der weite Lichthof atmet leicht, wie beim Original.
    CALayer *halo = self.glowWrappers.firstObject;
    if (halo != nil && [halo animationForKey:@"breathe"] == nil) {
        CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"opacity"];
        breathe.fromValue = @0.6;
        breathe.toValue = @0.95;
        breathe.duration = 1.8;
        breathe.autoreverses = YES;
        breathe.repeatCount = HUGE_VALF;
        breathe.removedOnCompletion = NO;
        breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [halo addAnimation:breathe forKey:@"breathe"];
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    // Nach Hintergrund/Vordergrund entfernt Core Animation Endlosanimationen; beim Zurückkommen neu starten.
    if (self.window != nil && self.rainbow) {
        [self startRotation];
    }
}

- (void)setGlowColor:(UIColor *)color {
    self.layer.shadowColor = color.CGColor;
}

/// Ebeneneigenschaft vom sichtbaren Stand auf den neuen Modellwert federn (wie die Fläche über BrowserMotion).
static void BrowserGlowAnimateKey(CALayer *layer, NSString *key, id fromValue) {
    id toValue = [layer valueForKey:key];
    if (fromValue == nil || toValue == nil || [fromValue isEqual:toValue]) {
        return;
    }
    CABasicAnimation *animation = [BrowserMotion layerAnimationForKind:BrowserMotionKindSnap];
    animation.keyPath = key;
    animation.fromValue = fromValue;
    animation.toValue = toValue;
    [layer addAnimation:animation forKey:key];
}

- (void)setShapeSize:(CGSize)size cornerRadius:(CGFloat)radius animated:(BOOL)animated {
    // Sichtbaren Zwischenstand aller Ebenen merken, damit der Glow beim Einrasten mit der Fläche mitfedert
    // statt sofort auf die neue Größe zu springen.
    NSMutableArray<NSArray *> *before = [NSMutableArray array];
    NSMutableArray<CALayer *> *animatedLayers = [NSMutableArray arrayWithObjects:self.layer, self.maskLayer, nil];
    [animatedLayers addObjectsFromArray:self.glowWrappers];
    [animatedLayers addObjectsFromArray:self.ringContainers];
    [animatedLayers addObjectsFromArray:self.ringMasks];
    [animatedLayers addObjectsFromArray:self.gradients];
    NSArray<NSString *> *keys = @[@"bounds", @"position", @"path", @"shadowPath"];
    if (animated && !self.hidden) {
        for (CALayer *layer in animatedLayers) {
            CALayer *visible = layer.presentationLayer ?: layer;
            NSMutableDictionary *values = [NSMutableDictionary dictionary];
            for (NSString *key in keys) {
                if ([key isEqualToString:@"path"] && ![layer isKindOfClass:CAShapeLayer.class]) {
                    continue;
                }
                if ([key isEqualToString:@"shadowPath"] && layer != self.layer) {
                    continue;
                }
                id value = [visible valueForKey:key];
                if (value != nil) {
                    values[key] = value;
                }
            }
            [before addObject:@[layer, values]];
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGRect shape = CGRectMake(0, 0, size.width, size.height);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:shape cornerRadius:radius];
    self.layer.shadowPath = path.CGPath;
    // Maske: großes Rechteck minus Form (gerade-ungerade Füllung) = nur außen.
    UIBezierPath *outside = [UIBezierPath bezierPathWithRect:CGRectInset(shape, -kGlowMargin, -kGlowMargin)];
    [outside appendPath:path];
    self.maskLayer.path = outside.CGPath;

    // Alle Schichten decken Form plus Rand ab; der Verlauf ist ein Quadrat über die Diagonale,
    // damit beim Drehen keine Ecke frei bleibt. Ringe liegen mittig auf der Formkante (innen schneidet die Maske ab).
    CGRect box = CGRectInset(shape, -kGlowMargin, -kGlowMargin);
    CGRect local = CGRectMake(0, 0, box.size.width, box.size.height);
    CGFloat diagonal = ceil(hypot(box.size.width, box.size.height));
    CGRect inBox = CGRectOffset(shape, kGlowMargin, kGlowMargin);
    for (NSUInteger i = 0; i < self.glowWrappers.count; i++) {
        self.glowWrappers[i].frame = box;
        self.ringContainers[i].frame = local;
        self.ringMasks[i].frame = local;
        CGFloat inset = self.ringWidths[i].doubleValue / 2.0 - 1.0;
        CGRect ring = CGRectInset(inBox, -MAX(0.0, inset), -MAX(0.0, inset));
        CGFloat ringRadius = MIN(radius + MAX(0.0, inset), CGRectGetHeight(ring) / 2.0);
        self.ringMasks[i].path = [UIBezierPath bezierPathWithRoundedRect:ring cornerRadius:ringRadius].CGPath;
        self.gradients[i].bounds = CGRectMake(0, 0, diagonal, diagonal);
        self.gradients[i].position = CGPointMake(CGRectGetMidX(local), CGRectGetMidY(local));
    }
    for (NSArray *entry in before) {
        CALayer *layer = entry[0];
        NSDictionary *values = entry[1];
        for (NSString *key in values) {
            BrowserGlowAnimateKey(layer, key, values[key]);
        }
    }
    [CATransaction commit];
}

@end

@interface BrowserRemoteInputController ()

@property (nonatomic, weak) id<BrowserRemoteInputControllerHost> host;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, readwrite) UIImageView *cursorView;
@property (nonatomic) UIView *highlightView;
@property (nonatomic) UIView *highlightSurfaceView;
@property (nonatomic) BrowserGlowView *highlightGlowView;
/// Linse: Momentaufnahme der Seite unter der Hervorhebung, in der Mitte leicht, am Rand stärker vergrößert.
@property (nonatomic) UIView *lensContainer;
@property (nonatomic) UIView *lensCenterSnapshot;
@property (nonatomic) UIView *lensEdgeSnapshot;
@property (nonatomic) CGRect lensRect;
@property (nonatomic) CAShapeLayer *lensSeam;
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
@property (nonatomic) CFTimeInterval lastDownPressTimestamp;

// Kreisgeste am Clickpad-Ring: Drehung der Bewegungsrichtung aufsummieren.
@property (nonatomic) CGPoint rotationSegment;
@property (nonatomic) CGFloat rotationLastHeading;
@property (nonatomic) BOOL rotationHasHeading;
@property (nonatomic) CGFloat rotationAccumulated;
@property (nonatomic) CGFloat rotationStepAccumulated;
@property (nonatomic) BOOL rotationMode;
@property (nonatomic) CGPoint gestureStartPoint;
@property (nonatomic) CGRect gestureStartTarget;

// Clickpad direkt über GameController (Rohpositionen ohne Fokus-Glättung).
@property (nonatomic) BOOL padTouching;
@property (nonatomic) CGPoint padLastValue;
@property (nonatomic) CFTimeInterval padLastTimestamp;
@property (nonatomic) CFTimeInterval padLastSampleTime;
@property (nonatomic) NSUInteger debugPadSamples;
@property (nonatomic) NSUInteger debugTouchSamples;
@property (nonatomic) CFTimeInterval debugRateWindowStart;

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
        [self observeGameControllers];
        _cursorView = [[BrowserCursorImageView alloc] initWithFrame:CGRectMake(_freePoint.x, _freePoint.y, 64, 64)];
        _cursorView.image = BrowserDefaultCursor();
        _cursorView.userInteractionEnabled = NO;

        _highlightView = [[UIView alloc] initWithFrame:CGRectZero];
        _highlightView.userInteractionEnabled = NO;
        // Auswahl im Glas-Look: helle, halbdurchsichtige Fläche mit Glanz oben, Lichtkante und weichem Schatten.
        // Bewusst ohne echte Glaslinse – die bricht den Text darunter und kostet mehr Leistung.
        _highlightView.backgroundColor = UIColor.clearColor;
        _highlightView.layer.cornerCurve = kCACornerCurveContinuous;
        // Statt Schatten ein Leuchten außen herum (Farbe je Ziel, sonst Systemblau), s. BrowserGlowView.
        BrowserGlowView *glow = [[BrowserGlowView alloc] initWithFrame:CGRectZero];
        [_highlightView addSubview:glow];
        _highlightGlowView = glow;
        _lensContainer = [[UIView alloc] initWithFrame:CGRectZero];
        _lensContainer.userInteractionEnabled = NO;
        _lensContainer.clipsToBounds = YES;
        _lensContainer.layer.cornerCurve = kCACornerCurveContinuous;
        _lensRect = CGRectNull;
        [_highlightView addSubview:_lensContainer];
        UIView *surface = [[BrowserGlassHighlightSurfaceView alloc] initWithFrame:CGRectZero];
        surface.userInteractionEnabled = NO;
        surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        surface.layer.cornerCurve = kCACornerCurveContinuous;
        surface.clipsToBounds = YES;
        [_highlightView addSubview:surface];
        _highlightSurfaceView = surface;
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

- (BOOL)addressPanelActive {
    return [self.host respondsToSelector:@selector(browserRemoteInputControllerAddressPanelActive)] &&
        [self.host browserRemoteInputControllerAddressPanelActive];
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
    // Ecken nach Liquid Glass: Knöpfe, Links und Textzeilen als Kapsel, größere Flächen (Karten, Bilder) mit
    // großer, kontinuierlicher Rundung statt kantiger 16 pt.
    CGFloat height = CGRectGetHeight(frame);
    CGFloat radius = height <= 120.0 ? height / 2.0 : MIN(34.0, height / 2.0);
    if ([self.host respondsToSelector:@selector(browserRemoteInputControllerCornerRadiusForTarget:)]) {
        CGFloat targetRadius = [self.host browserRemoteInputControllerCornerRadiusForTarget:target];
        if (targetRadius >= 0.0) {
            radius = MIN(targetRadius + 6.0, CGRectGetHeight(frame) / 2.0);
        }
    }
    UIView *surface = self.highlightSurfaceView;
    BrowserGlowView *glow = self.highlightGlowView;
    UIColor *glowColor = nil;
    if ([self.host respondsToSelector:@selector(browserRemoteInputControllerGlowColorForTarget:)]) {
        glowColor = [self.host browserRemoteInputControllerGlowColorForTarget:target];
    }
    [glow setGlowColor:glowColor ?: [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0]];
    BOOL rainbow = [BrowserPreferencesStore new].rainbowGlowEnabled;
    if (glow.rainbow != rainbow) {
        glow.rainbow = rainbow;
    }
    BOOL springs = animated && highlight.alpha > 0.0;
    glow.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
    [glow setShapeSize:frame.size cornerRadius:radius animated:springs];
    [self updateLensForFrame:frame radius:radius];
    void (^apply)(void) = ^{
        highlight.frame = frame;
        highlight.layer.cornerRadius = radius;
        surface.layer.cornerRadius = radius;
        highlight.alpha = self.cursorIdleHidden ? 0.0 : 1.0;
    };
    if (animated && highlight.alpha > 0.0) {
        // Liquid Glass: kurze Feder mit leichtem Nachschwingen; schlicht: 0,12 s easeOut (BrowserMotion).
        [BrowserMotion animateKind:BrowserMotionKindSnap delay:0
                           options:UIViewAnimationOptionBeginFromCurrentState
                        animations:apply
                        completion:nil];
    } else {
        [UIView performWithoutAnimation:^{
            highlight.frame = frame;
            highlight.layer.cornerRadius = radius;
            surface.layer.cornerRadius = radius;
            }];
        [UIView animateWithDuration:animated ? 0.12 : 0.0 animations:^{ highlight.alpha = self.cursorIdleHidden ? 0.0 : 1.0; }];
    }
}

/// Linse nur bei neuer Lage oder Größe neu aufnehmen (nicht pro Frame): Seite unter dem Ziel als Snapshot,
/// Mitte ~1,04-fach (Text bleibt lesbar), schmales Randband ~1,13-fach, dazu ein feiner heller Saum am Übergang.
- (void)updateLensForFrame:(CGRect)frame radius:(CGFloat)radius {
    UIView *container = self.lensContainer;
    UIView *source = nil;
    if ([self.host respondsToSelector:@selector(browserRemoteInputControllerLensSourceView)] &&
        (![self.host respondsToSelector:@selector(browserRemoteInputControllerLensAllowedForTarget:)] ||
         [self.host browserRemoteInputControllerLensAllowedForTarget:frame])) {
        source = [self.host browserRemoteInputControllerLensSourceView];
    }
    CGRect inSource = source != nil ? [source convertRect:frame fromView:self.rootView] : CGRectNull;
    BOOL usable = source != nil && source.window != nil && CGRectContainsRect(CGRectInset(source.bounds, -2, -2), inSource)
        && CGRectGetWidth(frame) > 20.0 && CGRectGetHeight(frame) > 12.0;
    if (!usable) {
        container.hidden = YES;
        self.lensRect = CGRectNull;
        return;
    }
    container.hidden = NO;
    container.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
    container.layer.cornerRadius = radius;
    if (CGRectEqualToRect(self.lensRect, frame) && self.lensCenterSnapshot != nil) {
        return;
    }
    self.lensRect = frame;
    // Snapshot der WebView (liegt unter der Hervorhebung, enthält sie also nicht).
    [self.lensCenterSnapshot removeFromSuperview];
    [self.lensEdgeSnapshot removeFromSuperview];
    CGRect bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    CGFloat band = MIN(6.0, CGRectGetHeight(bounds) / 4.0);
    UIView *center = [source resizableSnapshotViewFromRect:inSource afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    UIView *edge = [source resizableSnapshotViewFromRect:inSource afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero];
    if (center == nil || edge == nil) {
        container.hidden = YES;
        self.lensRect = CGRectNull;
        return;
    }
    center.frame = bounds;
    edge.frame = bounds;
    // Rand: kräftigere Vergrößerung, nur im Ring sichtbar -> sichtbarer Sprung wie bei der Kante einer Glaslinse.
    edge.transform = CGAffineTransformMakeScale(1.13, 1.13);
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = bounds;
    ring.fillRule = kCAFillRuleEvenOdd;
    UIBezierPath *ringPath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius];
    [ringPath appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds, band, band) cornerRadius:MAX(2.0, radius - band)]];
    ring.path = ringPath.CGPath;
    UIView *edgeClip = [[UIView alloc] initWithFrame:bounds];
    edgeClip.userInteractionEnabled = NO;
    edgeClip.layer.mask = ring;
    [edgeClip addSubview:edge];
    center.transform = CGAffineTransformMakeScale(1.04, 1.04);
    [container addSubview:center];
    [container addSubview:edgeClip];
    // Feiner heller Saum an der Innenkante des Rings.
    CAShapeLayer *seam = [CAShapeLayer layer];
    seam.frame = bounds;
    seam.fillColor = UIColor.clearColor.CGColor;
    seam.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    seam.lineWidth = 1.0;
    seam.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds, band, band) cornerRadius:MAX(2.0, radius - band)].CGPath;
    [self.lensSeam removeFromSuperlayer];
    [container.layer addSublayer:seam];
    self.lensSeam = seam;
    self.lensCenterSnapshot = center;
    self.lensEdgeSnapshot = edgeClip;
}

- (void)clearSnapAnimated:(BOOL)animated {
    self.snappedTarget = CGRectNull;
    if (self.highlightView.alpha > 0.0) {
        [UIView animateWithDuration:animated ? 0.12 : 0.0 animations:^{ self.highlightView.alpha = 0.0; }];
    }
    [self setCursorImageVisible:YES];
}

- (void)pointerTargetsDidChange {
    // Seite hat sich geändert (Scrollen, Laden, DOM): Linsenbild ist veraltet und wird neu aufgenommen.
    self.lensRect = CGRectNull;
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
    if ([self pointerOverlaysSuppressed] || [self addressPanelActive]) {
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
    // Oben darf der Inhalt bis unter die schwebende Leiste (contentInset), unten bis zum Seitenende.
    CGFloat minOffsetY = -scrollView.contentInset.top;
    CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
    CGFloat maxOffsetY = MAX(minOffsetY, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds) + scrollView.contentInset.bottom);
    CGFloat nextOffsetX = MIN(MAX(contentOffset.x + delta.x, 0.0), maxOffsetX);
    CGFloat nextOffsetY = MIN(MAX(contentOffset.y + delta.y, minOffsetY), maxOffsetY);
    CGPoint nextOffset = CGPointMake(nextOffsetX, nextOffsetY);
    [scrollView setContentOffset:nextOffset animated:NO];
    return !CGPointEqualToPoint(contentOffset, nextOffset);
}

- (void)scrollPageByFraction:(CGFloat)fraction {
    [self scrollPageReturningDeltaByFraction:fraction];
}

/// Scrollt animiert und gibt die tatsächlich gescrollte Strecke zurück (0 am Seitenende).
- (CGFloat)scrollPageReturningDeltaByFraction:(CGFloat)fraction {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    if (scrollView == nil) {
        return 0.0;
    }
    CGFloat minOffsetY = -scrollView.contentInset.top;
    CGFloat maxOffsetY = MAX(minOffsetY, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds) + scrollView.contentInset.bottom);
    CGFloat delta = (CGRectGetHeight(scrollView.bounds) - scrollView.contentInset.top) * fraction;
    CGPoint offset = scrollView.contentOffset;
    CGFloat startOffsetY = offset.y;
    offset.y = MIN(MAX(offset.y + delta, minOffsetY), maxOffsetY);
    [self clearSnapAnimated:YES];
    [UIView animateWithDuration:0.28
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [scrollView setContentOffset:offset animated:NO]; }
                     completion:^(__unused BOOL finished) {
        [self.host browserRemoteInputControllerPersistSession];
        [self updatePointerAnimated:YES];
    }];
    return offset.y - startOffsetY;
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

    if (presentedViewController == nil && [self addressPanelActive]) {
        // Aufklapp-Bereich der Adressleiste: Pfeile bewegen den Fokus zwischen Feld und Kacheln.
        switch (press.type) {
            case UIPressTypeUpArrow:
                [self stepTargetInDirection:CGVectorMake(0.0, -1.0)];
                return YES;
            case UIPressTypeDownArrow:
                [self stepTargetInDirection:CGVectorMake(0.0, 1.0)];
                return YES;
            case UIPressTypeLeftArrow:
                [self stepTargetInDirection:CGVectorMake(-1.0, 0.0)];
                return YES;
            case UIPressTypeRightArrow:
                [self stepTargetInDirection:CGVectorMake(1.0, 0.0)];
                return YES;
            default:
                break;
        }
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
                // Zweimal kurz hintereinander unten: Leiste zur Kapsel verkleinern.
                if (CACurrentMediaTime() - self.lastDownPressTimestamp < 0.4) {
                    self.lastDownPressTimestamp = 0;
                    [self.host browserRemoteInputControllerCompactTopBar];
                    return YES;
                }
                self.lastDownPressTimestamp = CACurrentMediaTime();
                [self scrollPageByFraction:kPageScrollFraction];
                return YES;
            case UIPressTypeLeftArrow:
                [self revealCursorIfIdle];
                [self.host browserRemoteInputControllerNavigateBack];
                return YES;
            case UIPressTypeRightArrow:
                [self revealCursorIfIdle];
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
#if DEBUG
    self.debugTouchSamples += 1;
#endif
    // Liefert das Clickpad gerade Rohwerte über GameController, bewegen nur diese den Zeiger.
    if (CACurrentMediaTime() - self.padLastSampleTime < 0.25) {
        return YES;
    }
    [self applyPointerDelta:CGPointMake(dx, dy) interval:dt];
    return YES;
}

/// Gemeinsamer Bewegungskern für UIKit-Berührungen und GameController-Rohwerte.
- (void)applyPointerDelta:(CGPoint)delta interval:(NSTimeInterval)dt {
    CGFloat dx = delta.x, dy = delta.y;
    BOOL tabOverviewVisible = [self.host browserRemoteInputControllerTabOverviewVisible];
    if (self.pressInProgress || self.revealOnlyTouch) {
        return;
    }
    [self scheduleIdleHide];

    if (!tabOverviewVisible && [self trackRotationWithDelta:CGPointMake(dx, dy)]) {
        return;
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
        return;
    }

    if (!CGPointEqualToPoint(overflow, CGPointZero) && ![self addressPanelActive]) {
        // Sanft: Überhang 1:1, damit es am Seitenrand nicht davonschießt.
        [self applyManualScrollDelta:CGPointMake(overflow.x * 0.9, overflow.y * 0.9)];
    }
    [self updatePointerAnimated:YES];
    return;
}

#pragma mark - Clickpad über GameController

- (void)observeGameControllers {
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(gameControllerDidConnect:)
                                               name:GCControllerDidConnectNotification object:nil];
    for (GCController *controller in GCController.controllers) {
        [self attachToGameController:controller];
    }
}

- (void)gameControllerDidConnect:(NSNotification *)notification {
    [self attachToGameController:notification.object];
}

- (void)attachToGameController:(GCController *)controller {
    GCMicroGamepad *pad = controller.microGamepad;
    if (pad == nil) {
        return;
    }
    pad.reportsAbsoluteDpadValues = YES;
    pad.allowsRotation = NO;
    __weak typeof(self) weakSelf = self;
    pad.dpad.valueChangedHandler = ^(__unused GCControllerDirectionPad *dpad, float xValue, float yValue) {
        [weakSelf handlePadValue:CGPointMake(xValue, yValue)];
    };
    NSLog(@"[Input] Clickpad über GameController: %@", controller.vendorName ?: @"Fernbedienung");
}

/// Ein Clickpad-Weg von Rand zu Rand (2 Einheiten) entspricht so vielen Punkten, vor der Beschleunigung.
static const CGFloat kPadPointsPerUnit = 640.0;

- (void)handlePadValue:(CGPoint)value {
    CFTimeInterval now = CACurrentMediaTime();
    BOOL touching = !(value.x == 0.0f && value.y == 0.0f);
    if (!touching) {
        if (self.padTouching) {
            self.padTouching = NO;
            [self handleTouchesEnded];
        }
        return;
    }
    self.padLastSampleTime = now;
#if DEBUG
    self.debugPadSamples += 1;
    if (now - self.debugRateWindowStart > 2.0) {
        if (self.debugRateWindowStart > 0) {
            NSLog(@"[Input] Raten: GameController %.0f/s, UIKit-Berührungen %.0f/s",
                  self.debugPadSamples / (now - self.debugRateWindowStart), self.debugTouchSamples / (now - self.debugRateWindowStart));
        }
        self.debugRateWindowStart = now;
        self.debugPadSamples = 0;
        self.debugTouchSamples = 0;
    }
#endif
    if (!self.padTouching) {
        self.padTouching = YES;
        self.padLastValue = value;
        self.padLastTimestamp = now;
        if ([self.host browserRemoteInputControllerTopBarFocusActive] || !self.cursorModeEnabled ||
            [self.host browserRemoteInputControllerPresentedViewController] != nil) {
            return;
        }
        [self resetRotation];
        self.gestureStartPoint = self.freePoint;
        self.gestureStartTarget = self.snappedTarget;
        self.revealOnlyTouch = [self revealCursorIfIdle];
        return;
    }
    CGPoint delta = CGPointMake((value.x - self.padLastValue.x) * kPadPointsPerUnit,
                                -(value.y - self.padLastValue.y) * kPadPointsPerUnit);
    NSTimeInterval dt = MAX(now - self.padLastTimestamp, 1.0 / 240.0);
    self.padLastValue = value;
    self.padLastTimestamp = now;
    if ([self.host browserRemoteInputControllerTopBarFocusActive] || !self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }
    [self applyPointerDelta:delta interval:dt];
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
/// Sprungziele in Leserichtung (Zeilen à 24 pt, darin von links nach rechts).
- (NSArray<NSValue *> *)sortedStepTargets {
    NSArray<NSValue *> *candidates = [self.host respondsToSelector:@selector(browserRemoteInputControllerStepTargets)]
        ? [self.host browserRemoteInputControllerStepTargets]
        : [self.host browserRemoteInputControllerPointerTargets];
    return [candidates sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGRect ra = a.CGRectValue, rb = b.CGRectValue;
        CGFloat rowA = round(CGRectGetMidY(ra) / 24.0), rowB = round(CGRectGetMidY(rb) / 24.0);
        if (rowA != rowB) {
            return rowA < rowB ? NSOrderedAscending : NSOrderedDescending;
        }
        return CGRectGetMidX(ra) < CGRectGetMidX(rb) ? NSOrderedAscending : NSOrderedDescending;
    }];
}

- (void)stepTargetBy:(NSInteger)direction {
    [self stepTargetBy:direction allowScroll:![self addressPanelActive]];
}

/// Räumlicher Sprung (wie die Fokus-Engine): Kandidaten in Blickrichtung, gewichtet nach Abstand und seitlichem Versatz.
- (void)stepTargetInDirection:(CGVector)direction {
    [self revealCursorIfIdle];
    NSArray<NSValue *> *targets = [self.host respondsToSelector:@selector(browserRemoteInputControllerStepTargets)]
        ? [self.host browserRemoteInputControllerStepTargets]
        : [self.host browserRemoteInputControllerPointerTargets];
    CGPoint reference = CGRectIsNull(self.snappedTarget) ? self.freePoint
        : CGPointMake(CGRectGetMidX(self.snappedTarget), CGRectGetMidY(self.snappedTarget));
    CGFloat length = hypot(direction.dx, direction.dy);
    if (length <= 0.0) {
        return;
    }
    CGVector unit = CGVectorMake(direction.dx / length, direction.dy / length);
    NSValue *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    for (NSValue *value in targets) {
        CGRect rect = value.CGRectValue;
        CGFloat vx = CGRectGetMidX(rect) - reference.x, vy = CGRectGetMidY(rect) - reference.y;
        CGFloat along = vx * unit.dx + vy * unit.dy;
        CGFloat across = fabs(vx * unit.dy - vy * unit.dx);
        // Breite Ziele (z. B. das Diktierfeld) zählen seitlich ab ihrer Kante, nicht ab der Mitte.
        CGFloat halfExtent = fabs(unit.dx) > 0.5 ? CGRectGetHeight(rect) / 2.0 : CGRectGetWidth(rect) / 2.0;
        across = MAX(0.0, across - halfExtent);
        if (along < 2.0) {
            continue;
        }
        CGFloat score = along + across * 2.0;
        if (score < bestScore) {
            bestScore = score;
            best = value;
        }
    }
    if (best == nil) {
        return;
    }
    CGRect target = best.CGRectValue;
    self.freePoint = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    self.snappedTarget = CGRectNull;
    [self updatePointerAnimated:YES];
}

- (void)stepTargetBy:(NSInteger)direction allowScroll:(BOOL)allowScroll {
    [self revealCursorIfIdle];
    NSArray<NSValue *> *targets = [self sortedStepTargets];
    if (targets.count == 0) {
        if (allowScroll) {
            [self scrollThenStep:direction];
        }
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
    NSInteger next = onTarget ? index + direction : index;
    if ((next < 0 || next >= (NSInteger)targets.count) && allowScroll) {
        // Am Rand des sichtbaren Bereichs: Seite weiterscrollen und dort weiterspringen.
        [self scrollThenStep:direction];
        return;
    }
    next = MIN(MAX(next, 0), (NSInteger)targets.count - 1);
    CGRect target = targets[next].CGRectValue;
    self.freePoint = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    self.snappedTarget = CGRectNull;
    [self updatePointerAnimated:YES];
}

- (void)scrollThenStep:(NSInteger)direction {
    CGPoint reference = CGRectIsNull(self.snappedTarget) ? self.freePoint
        : CGPointMake(CGRectGetMidX(self.snappedTarget), CGRectGetMidY(self.snappedTarget));
    NSArray<NSValue *> *before = [self sortedStepTargets];
    CGFloat scrolled = [self scrollPageReturningDeltaByFraction:direction > 0 ? 0.6 : -0.6];
    if (fabs(scrolled) < 1.0) {
        return; // Seitenanfang oder -ende: Zeiger bleibt auf dem letzten Element.
    }
    // Wo das bisherige Element nach dem Scrollen steht; von dort aus das nächste in Leserichtung.
    CGFloat anchorY = reference.y - scrolled;
    CGFloat anchorX = reference.x;
    // Neue Ziele meldet die Seite erst nach dem Scrollen.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Erstes Ziel, das in Leserichtung hinter (bzw. vor) dem bisherigen Element liegt.
        CGFloat anchorRow = round(anchorY / 24.0);
        NSArray<NSValue *> *targets = [self sortedStepTargets];
        if (targets.count > 0 && [targets isEqualToArray:before]) {
            // Festes Overlay (z. B. Dialog): Ziele bewegen sich nicht mit, also am letzten Element bleiben.
            self.freePoint = reference;
            self.snappedTarget = CGRectNull;
            [self updatePointerAnimated:YES];
            return;
        }
        NSValue *chosen = nil;
        for (NSValue *value in (direction > 0 ? targets : targets.reverseObjectEnumerator.allObjects)) {
            CGRect rect = value.CGRectValue;
            CGFloat row = round(CGRectGetMidY(rect) / 24.0);
            BOOL beyond = row != anchorRow ? (row - anchorRow) * (CGFloat)direction > 0
                                           : (CGRectGetMidX(rect) - anchorX) * (CGFloat)direction > 2.0;
            if (beyond) {
                chosen = value;
                break;
            }
        }
        if (chosen == nil) {
            return;
        }
        CGRect target = chosen.CGRectValue;
        self.freePoint = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        self.snappedTarget = CGRectNull;
        [self updatePointerAnimated:YES];
    });
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
