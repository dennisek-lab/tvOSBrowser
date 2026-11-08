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

/// Einrasten mit Hysterese: Ab diesem Abstand der Fingerposition zum Zielrand rastet der Zeiger ein (Punkte) …
static const CGFloat kSnapEnterRadius = 24.0;
/// … und löst sich erst, wenn die Fingerposition so weit über den Zielrand hinaus ist. Dazwischen zieht das Ziel den
/// sichtbaren Zeiger stufenlos an; an der Lösegrenze ist die Anziehung null, deshalb springt beim Lösen nichts.
static const CGFloat kSnapReleaseRadius = 48.0;
/// So stark zieht ein kleines Ziel den sichtbaren Zeiger zur Mitte (1 = genau Mitte), solange der Finger darin ist.
static const CGFloat kSnapPull = 0.85;
/// Zeitkonstante des weichen Übergangs zu einem neuen Ziel (Einrasten, Zielwechsel, Sprung per links/rechts), s.
static const CFTimeInterval kSnapEaseTimeConstant = 0.045;
/// Größere Ziele (Bilder, Karten, breite Felder) werden nur hervorgehoben, der Zeiger springt nicht in die Mitte.
static const CGFloat kMaxCenterSnapWidth = 420.0;
static const CGFloat kMaxCenterSnapHeight = 140.0;
/// Seitenweises Scrollen über den Clickpad-Rand: Anteil der sichtbaren Höhe.
static const CGFloat kPageScrollFraction = 0.8;
/// Nach dieser Zeit ohne Berührung blendet sich der Zeiger aus.
static const NSTimeInterval kCursorIdleHideDelay = 4.0;
/// NO: Die erste Wischbewegung nach dem Ausblenden zeigt den Zeiger und bewegt ihn sofort (wie ein Trackpad).
/// YES: altes Verhalten, die ganze erste Wischbewegung zeigt nur den Zeiger (fühlte sich wie Verzögerung an).
static const BOOL kRevealConsumesFirstSwipe = NO;

#pragma mark - Abstimmung Zeigerpipeline

// Ablauf: Eingabe (GameController-Rohwerte, sonst UIKit-Berührungen) sammelt Rohbewegung; ein CADisplayLink wendet sie
// pro Bildschirmbild an: Beschleunigung (aus der Geschwindigkeit der letzten kSpeedWindow s), Glättung (1-€-Filter),
// Einrasten, Setzen der Zeigerebene ohne Animation. Nach dem Loslassen optional kurzes Gleiten.

/// Ein Clickpad-Weg von Rand zu Rand (2 Einheiten) entspricht so vielen Punkten, vor der Beschleunigung.
static const CGFloat kPadPointsPerUnit = 640.0;
/// Beschleunigungskurve wie bei einem Trackpad: bis kGainSlowSpeed (Rohpunkte/s) gilt kGainMin (präzise),
/// ab kGainFastSpeed kGainMax (trägt weit), dazwischen weicher S-Verlauf. Mal Zeigertempo (Einstellung, 0,3…3).
static const CGFloat kGainMin = 0.8;
static const CGFloat kGainMax = 2.6;
static const CGFloat kGainSlowSpeed = 150.0;
static const CGFloat kGainFastSpeed = 1700.0;
/// Zeitfenster für die Geschwindigkeit, aus der die Beschleunigung bestimmt wird (s). Ein Fenster statt Abstand
/// zweier Proben: Proben kommen gebündelt an, sonst schwankt die Verstärkung von Probe zu Probe (Sprünge).
static const CFTimeInterval kSpeedWindow = 0.035;
/// Nachabtastung: Pro Bild wird die Fingerlage von „jetzt minus kResampleFactor × Probenabstand“ gezeigt
/// (interpoliert, nie extrapoliert). Gleicht unregelmäßig eintreffende Proben aus; begrenzt auf 4…12 ms.
static const CGFloat kResampleFactor = 1.0;
static const CFTimeInterval kResampleMaxLatency = 0.012;
/// 1-€-Filter auf die Zeigerlage: Grenzfrequenz in Ruhe (Hz) plus Anteil je pt/s Geschwindigkeit. Dämpft nur
/// Sensorrauschen bei langsamer Bewegung, schnell kaum Nachlauf. Tiefpass erster Ordnung: schießt nie über.
static const CGFloat kFilterMinCutoff = 20.0;
static const CGFloat kFilterBeta = 0.05;
static const CGFloat kFilterDerivativeCutoff = 5.0;
/// Größter plausibler Sprung zwischen zwei Rohproben (Clickpad-Einheiten); größer = Störung, wird nicht bewegt.
static const CGFloat kPadMaxSampleJump = 0.35;
/// Verdächtige Proben (entgegen der Bewegung oder viel größer als üblich) werden zurückgehalten, bis die nächste
/// sie bestätigt, höchstens so lange (s). Kommt vorher das Abheben, war es das Abrollen der Fingerkuppe: verworfen.
static const CFTimeInterval kPadHoldMaxAge = 0.025;
/// „Viel größer“: so viel mal die zur aktuellen Geschwindigkeit passende Schrittweite (mindestens 8 Rohpunkte).
static const CGFloat kLiftOutlierFactor = 3.0;
/// UIKit-Berührungen bewegen den Zeiger nur, wenn so lange keine GameController-Probe kam (s).
static const CFTimeInterval kTouchFallbackQuietTime = 0.3;
/// Gleiten nach dem Loslassen: nur wenn der Finger in Fahrt abhebt (Bildschirm-pt/s, letzte Bewegung höchstens
/// kGlideMaxRestBeforeLift s vor dem Abheben). Auslauf exponentiell mit kGlideTimeConstant, höchstens kGlideMaxDistance pt.
static const CGFloat kGlideMinSpeed = 600.0;
static const CFTimeInterval kGlideMaxRestBeforeLift = 0.04;
static const CFTimeInterval kGlideTimeConstant = 0.09;
static const CGFloat kGlideMaxDistance = 140.0;

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

/// Abstand eines Punkts zum Rechteck (0 innerhalb).
static CGFloat BrowserDistanceToRect(CGPoint point, CGRect rect) {
    CGFloat dx = MAX(MAX(CGRectGetMinX(rect) - point.x, 0.0), point.x - CGRectGetMaxX(rect));
    CGFloat dy = MAX(MAX(CGRectGetMinY(rect) - point.y, 0.0), point.y - CGRectGetMaxY(rect));
    return hypot(dx, dy);
}

#if DEBUG
/// Messhilfe für den Selbsttest: ruft pro Bildschirmbild einen Block (eigener Takt, unabhängig von der Zeigerpipeline).
@interface BrowserDebugFrameSampler : NSObject
@property (nonatomic, copy) void (^tick)(CFTimeInterval now);
@property (nonatomic) CADisplayLink *link;
- (void)start;
- (void)stop;
@end

@implementation BrowserDebugFrameSampler
- (void)start {
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
    self.link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)step:(CADisplayLink *)link {
    // targetTimestamp: Zeitpunkt, zu dem das gerade entstehende Bild sichtbar wird.
    if (self.tick != nil) {
        self.tick(link.timestamp);
    }
}
- (void)stop {
    [self.link invalidate];
    self.link = nil;
    self.tick = nil;
}
@end
#endif

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
@property (nonatomic) BOOL padBaselineValidX;
@property (nonatomic) BOOL padBaselineValidY;
@property (nonatomic) CFTimeInterval padLastSampleTime;
/// Zurückgehaltene letzte Probe (Rohpunkte), s. kPadHoldMaxAge.
@property (nonatomic) BOOL padHasHeld;
@property (nonatomic) CGPoint padHeldDelta;
@property (nonatomic) CFTimeInterval padHeldTime;
// Ring über die absolute Fingerlage (nur GameController).
@property (nonatomic) BOOL ringHasAngle;
@property (nonatomic) CGFloat ringLastAngle;
@property (nonatomic) CGFloat ringAccumulated;
@property (nonatomic) CGFloat ringStepAccumulated;
@property (nonatomic) BOOL ringMode;

// Zeigerpipeline: ein Takt pro Bildschirmbild.
@property (nonatomic) CADisplayLink *pointerLink;
@property (nonatomic) CFTimeInterval pointerLinkLastTimestamp;
/// Ungeglättete Fingerposition (Ziel des Filters); freePoint ist die geglättete.
@property (nonatomic) CGPoint rawPoint;
@property (nonatomic) CGPoint filterVelocity;
/// Sichtbare Lage der Klickspitze (= Ursprung von cursorView).
@property (nonatomic) CGPoint visiblePoint;
@property (nonatomic) BOOL easingActive;
@property (nonatomic) BOOL gliding;
@property (nonatomic) CGPoint glideVelocity;
@property (nonatomic) CGFloat glideTravelled;
@property (nonatomic) BOOL liftPending;
@property (nonatomic) BOOL touchSourceActive;
@property (nonatomic) CFTimeInterval touchGestureStartTime;
@property (nonatomic) CFTimeInterval lastMovementSampleTime;
@property (nonatomic) CFTimeInterval liftTime;
@property (nonatomic) CGFloat pointerSpeedSetting;
@property (nonatomic) BOOL glideEnabledSetting;
/// Ziele nur einmal pro Bild vom Host holen.
@property (nonatomic, nullable) NSArray<NSValue *> *frameTargets;
/// Zuletzt gezeigte Hervorhebung; unverändert = nicht neu aufbauen (Glow-Pfade, Schatten).
@property (nonatomic) CGRect highlightShownTarget;
#if DEBUG
@property (nonatomic) NSInteger debugRingSteps;
#endif

@end

/// Messwerte einer Geste (nur DEBUG geloggt, gezählt wird immer – kostet nichts).
typedef struct {
    CFTimeInterval start;
    NSUInteger samples, touchSamplesIgnored, frames, latencyCount, suddenSteps, backSteps;
    NSUInteger axisSkips, jumpSkips, outliersDropped;
    double frameDtSum, frameDtMax, latencySum, latencyMax, workSum, workMax;
    CGFloat maxStep, lastStep, glideDistance, maxRadius;
    BOOL active, viaGameController;
} BrowserPointerGestureStats;

enum { kHistoryCount = 32 };

@implementation BrowserRemoteInputController {
    // Angenommene Proben: Ankunftszeit und aufsummierte Rohbewegung (Rohpunkte, vor der Beschleunigung).
    CFTimeInterval _sampleTime[kHistoryCount];
    CGPoint _sampleCum[kHistoryCount];
    NSUInteger _sampleCount;
    CGPoint _inputCum;
    /// Bis hierhin ist die Rohbewegung schon auf den Zeiger angewandt.
    CGPoint _outputCum;
    CFTimeInterval _lastSampleArrival;
    /// Geschätzter Probenabstand (s), bestimmt die Verzögerung der Nachabtastung.
    CFTimeInterval _sampleIntervalEstimate;
    BrowserPointerGestureStats _stats;
}

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
        _rawPoint = _freePoint;
        _visiblePoint = _freePoint;
        _highlightShownTarget = CGRectNull;
        _pointerSpeedSetting = 1.0;
        _glideEnabledSetting = YES;
        _sampleIntervalEstimate = 1.0 / 90.0;
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

- (NSArray<NSValue *> *)currentPointerTargets {
    // Pro Bildschirmbild nur einmal vom Host holen (Umrechnen aller Seitenziele kostet bei langen Seiten).
    return self.frameTargets ?: [self.host browserRemoteInputControllerPointerTargets];
}

/// Bestes Ziel für die Fingerposition: das kleinste, das den Punkt enthält, sonst das nächste im Einrastradius.
- (CGRect)bestTargetForPoint:(CGPoint)point {
    NSArray<NSValue *> *targets = [self currentPointerTargets];
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
        CGFloat distance = BrowserDistanceToRect(point, rect);
        if (distance <= kSnapEnterRadius && distance < bestDistance) {
            best = rect;
            bestDistance = distance;
        }
    }
    return best;
}

/// Hält das aktuelle Ziel (Hysterese) oder bestimmt ein neues. Gelöst wird erst jenseits von kSnapReleaseRadius,
/// oder wenn der Finger in einem anderen Ziel liegt (dicht beieinander liegende Links bleiben erreichbar).
- (CGRect)targetWithHysteresisFor:(CGPoint)point {
    CGRect current = self.snappedTarget;
    if (CGRectIsNull(current)) {
        return [self bestTargetForPoint:point];
    }
    CGRect refreshed = [self refreshedTargetMatching:current];
    if (CGRectIsNull(refreshed)) {
        return [self bestTargetForPoint:point];
    }
    CGRect best = [self bestTargetForPoint:point];
    if (CGRectContainsPoint(refreshed, point)) {
        // Liegt im aktuellen Ziel ein kleineres (verschachtelte Ziele), gewinnt das kleinere.
        return (!CGRectIsNull(best) && CGRectContainsRect(refreshed, best)) ? best : refreshed;
    }
    if (BrowserDistanceToRect(point, refreshed) > kSnapReleaseRadius) {
        return best;
    }
    if (!CGRectIsNull(best) && CGRectContainsPoint(best, point)) {
        return best;
    }
    return refreshed;
}

/// Angezogene Lage im Ziel: Richtung Mitte, mindestens 4 pt innerhalb des Rands (ein Klick trifft das Ziel).
- (CGPoint)clickPointForTarget:(CGRect)target {
    CGPoint finger = self.freePoint;
    CGPoint center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    CGPoint pulled = CGPointMake(finger.x + (center.x - finger.x) * kSnapPull, finger.y + (center.y - finger.y) * kSnapPull);
    CGRect inner = CGRectInset(target, MIN(4.0, CGRectGetWidth(target) / 2.0 - 0.5), MIN(4.0, CGRectGetHeight(target) / 2.0 - 0.5));
    pulled.x = MIN(MAX(pulled.x, CGRectGetMinX(inner)), CGRectGetMaxX(inner));
    pulled.y = MIN(MAX(pulled.y, CGRectGetMinY(inner)), CGRectGetMaxY(inner));
    return pulled;
}

/// Sichtbare Lage für ein eingerastetes kleines Ziel: angezogen (clickPointForTarget:); mit wachsendem Abstand der
/// Fingerposition vom Zielrand lässt die Anziehung stufenlos nach und ist an der Lösegrenze null.
/// emergence: 0 = ganz angezogen, 1 = frei.
- (CGPoint)visiblePointForTarget:(CGRect)target emergence:(CGFloat *)emergence {
    CGPoint finger = self.freePoint;
    CGPoint pulled = [self clickPointForTarget:target];
    CGFloat w = MIN(MAX(BrowserDistanceToRect(finger, target) / kSnapReleaseRadius, 0.0), 1.0);
    w = w * w * (3.0 - 2.0 * w);
    if (emergence != NULL) {
        *emergence = w;
    }
    return CGPointMake(pulled.x + (finger.x - pulled.x) * w, pulled.y + (finger.y - pulled.y) * w);
}

/// Bewertet Einrasten, Hervorhebung und Zeigerbild und gibt die gewünschte sichtbare Lage zurück.
/// animated: Zielwechsel weich überblenden (easingActive, läuft im Bildtakt), sonst direkt.
- (CGPoint)evaluatePointerAnimated:(BOOL)animated {
    if ([self pointerOverlaysSuppressed]) {
        [self clearSnapAnimated:NO];
        self.easingActive = NO;
        return self.freePoint;
    }

    CGRect current = self.snappedTarget;
    CGRect target = [self targetWithHysteresisFor:self.freePoint];
    BOOL targetChanged = !CGRectEqualToRect(target, current);
    self.snappedTarget = target;
    if (animated && targetChanged) {
        self.easingActive = YES;
    }

    if (CGRectIsNull(target)) {
        self.cursorView.image = BrowserDefaultCursor();
        [self setCursorImageVisible:YES];
        [self clearSnapAnimated:animated];
        return self.freePoint;
    }

    BOOL centerSnap = [self targetAllowsCenterSnap:target];
    CGFloat emergence = 1.0;
    CGPoint cursorPoint = centerSnap ? [self visiblePointForTarget:target emergence:&emergence] : self.freePoint;
    // Eingerastet: Pfeil ausblenden, die Hervorhebung ist der Zeiger. Bei großen Zielen bleibt die Hand sichtbar.
    // Zieht der Finger aus dem Ziel heraus, taucht der Zeiger schon vor dem Lösen wieder auf.
    self.cursorView.image = BrowserPointerCursor();
    [self setCursorImageVisible:!centerSnap || emergence >= 0.5];
    // Hervorhebung nur bei neuem Ziel neu aufbauen, nicht in jedem Bild.
    if (!CGRectEqualToRect(self.highlightShownTarget, target) || self.highlightView.alpha <= 0.0) {
        self.highlightShownTarget = target;
        [self showHighlightForTarget:target animated:animated];
    }
    return cursorPoint;
}

- (void)updatePointerAnimated:(BOOL)animated {
    CGPoint desired = [self evaluatePointerAnimated:animated];
    if (self.easingActive) {
        // Der Übergang läuft im Bildtakt (pointerFrame:).
        [self ensurePointerLink];
        return;
    }
    self.visiblePoint = desired;
    [self placeCursorAtPoint:desired animated:NO];
}

/// Nach einer neuen Meldung der Seite das passende Ziel wiederfinden (gleiches Element, neue Lage); CGRectNull, wenn weg.
- (CGRect)refreshedTargetMatching:(CGRect)previous {
    NSArray<NSValue *> *targets = [self currentPointerTargets];
    for (NSValue *value in targets) {
        if (CGRectEqualToRect(value.CGRectValue, previous)) {
            return previous;
        }
    }
    // Gleich großes Ziel in der Nähe (Seite hat gescrollt).
    for (NSValue *value in targets) {
        CGRect rect = value.CGRectValue;
        if (fabs(CGRectGetWidth(rect) - CGRectGetWidth(previous)) < 1.0 &&
            fabs(CGRectGetHeight(rect) - CGRectGetHeight(previous)) < 1.0 &&
            BrowserDistanceToRect(self.freePoint, rect) <= kSnapReleaseRadius) {
            return rect;
        }
    }
    return CGRectNull;
}

/// Setzt die Zeigerebene direkt, ohne implizite oder laufende Animation (jede Animation wäre Nachlauf).
- (void)placeCursorAtPoint:(CGPoint)point animated:(__unused BOOL)animated {
    CGRect frame = self.cursorView.frame;
    frame.origin = point;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.cursorView.layer removeAnimationForKey:@"position"];
    self.cursorView.frame = frame;
    [CATransaction commit];
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
    self.highlightShownTarget = CGRectNull;
    if (self.highlightView.alpha > 0.0) {
        [UIView animateWithDuration:animated ? 0.12 : 0.0 animations:^{ self.highlightView.alpha = 0.0; }];
    }
    [self setCursorImageVisible:YES];
}

- (void)pointerTargetsDidChange {
    // Seite hat sich geändert (Scrollen, Laden, DOM): Linsenbild ist veraltet und wird neu aufgenommen.
    self.lensRect = CGRectNull;
    self.highlightShownTarget = CGRectNull;
    if (self.lastTouchLocation.x != -1 || self.pressInProgress || self.padTouching || self.pointerLink != nil) {
        // Während der Finger wischt (oder der Zeiger noch gleitet), bewertet das nächste Bild ohnehin neu.
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
    [self commitPointerForClick];
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
            [self discardPendingMotion];
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

#pragma mark - Wischen (UIKit-Berührungen, nur Rückfallweg)

/// Liefert das Clickpad gerade Rohwerte über GameController, gehört die Geste diesem Weg (keine Doppelung).
- (BOOL)gameControllerOwnsTouch {
    return self.padTouching || (CACurrentMediaTime() - self.padLastSampleTime) < kTouchFallbackQuietTime;
}

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
    self.touchGestureStartTime = CACurrentMediaTime();
    self.touchSourceActive = NO;
    if (![self gameControllerOwnsTouch]) {
        [self beginPointerGestureViaGameController:NO];
    }
    return YES;
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
    self.lastTouchLocation = location;
    self.lastTouchTimestamp = timestamp;
    if ([self gameControllerOwnsTouch]) {
        _stats.touchSamplesIgnored += 1;
        return YES;
    }
    // Die Siri Remote meldet sich auch über GameController; kurz abwarten, ob von dort Proben kommen.
    if (!self.touchSourceActive && GCController.controllers.count > 0 &&
        CACurrentMediaTime() - self.touchGestureStartTime < 0.05) {
        _stats.touchSamplesIgnored += 1;
        return YES;
    }
    self.touchSourceActive = YES;
    _stats.samples += 1;
    [self enqueueRawPointerDelta:CGPointMake(dx, dy) sampleTime:CACurrentMediaTime() viaGameController:NO];
    return YES;
}

- (void)handleTouchesEnded {
    self.lastTouchLocation = CGPointMake(-1, -1);
    if (self.touchSourceActive) {
        self.touchSourceActive = NO;
        [self pointerGestureDidLift];
    } else if (!self.padTouching) {
        [self resetRotation];
        self.revealOnlyTouch = NO;
        [self scheduleIdleHide];
    }
}

#pragma mark - Zeigerpipeline

/// Gemeinsamer Anfang einer Wischgeste (GameController oder UIKit).
- (void)beginPointerGestureViaGameController:(BOOL)viaGameController {
    [self resetRotation];
    [self resetRing];
    self.gestureStartPoint = self.freePoint;
    self.gestureStartTarget = self.snappedTarget;
    // Neue Berührung hält ein Gleiten sofort an der sichtbaren Stelle an.
    [self discardPendingMotion];
    [self resetSampleHistoryAt:CACurrentMediaTime()];
    BrowserPreferencesStore *preferences = [BrowserPreferencesStore new];
    self.pointerSpeedSetting = preferences.pointerSpeed;
    self.glideEnabledSetting = preferences.pointerGlideEnabled;
    BOOL revealed = [self revealCursorIfIdle];
    self.revealOnlyTouch = revealed && kRevealConsumesFirstSwipe;
    memset(&_stats, 0, sizeof(_stats));
    _stats.active = YES;
    _stats.viaGameController = viaGameController;
    _stats.start = CACurrentMediaTime();
}

- (void)pointerGestureDidLift {
    [self resetRotation];
    [self resetRing];
    self.revealOnlyTouch = NO;
    [self scheduleIdleHide];
    self.liftTime = CACurrentMediaTime();
    self.liftPending = YES;
    [self ensurePointerLink];
}

/// Verwirft noch nicht angewandte Bewegung und Gleiten; der Zeiger bleibt, wo er sichtbar ist.
- (void)discardPendingMotion {
    _outputCum = _inputCum;
    self.padHasHeld = NO;
    self.gliding = NO;
    self.liftPending = NO;
    self.rawPoint = self.freePoint;
    self.filterVelocity = CGPointZero;
}

/// Setzt die Fingerposition hart (Sprung zu einem Element, Selbsttest), ohne Nachlauf des Filters.
- (void)setPointerPositionDirectly:(CGPoint)point {
    self.freePoint = point;
    [self discardPendingMotion];
}

- (void)commitPointerForClick {
    // Gleiten und Übergänge beenden; ein Klick zählt dort, wo der Zeiger zu sehen ist bzw. im eingerasteten Ziel.
    [self discardPendingMotion];
    self.easingActive = NO;
    CGPoint point = self.freePoint;
    if (!CGRectIsNull(self.snappedTarget) && [self targetAllowsCenterSnap:self.snappedTarget]) {
        point = [self clickPointForTarget:self.snappedTarget];
    }
    self.visiblePoint = point;
    [self placeCursorAtPoint:point animated:NO];
}

#pragma mark Proben und Nachabtastung

// Jede angenommene Probe wird mit Ankunftszeit und aufsummierter Rohbewegung gespeichert. Pro Bild wird die Lage zum
// Zeitpunkt „jetzt minus etwa ein Probenabstand“ zwischen den beiden umgebenden Proben interpoliert (wie die
// Berührungs-Nachabtastung unter Android). So kommt pro Bild gleich viel Bewegung an, auch wenn die Proben
// unregelmäßig oder gebündelt eintreffen. Es wird nie extrapoliert: kein Vorauslaufen, also kein Zurückfedern.

- (void)resetSampleHistoryAt:(CFTimeInterval)time {
    _sampleCount = 0;
    _inputCum = CGPointZero;
    _outputCum = CGPointZero;
    _lastSampleArrival = time;
    [self pushSampleAt:time];
}

- (void)pushSampleAt:(CFTimeInterval)time {
    NSUInteger index = _sampleCount % kHistoryCount;
    _sampleTime[index] = time;
    _sampleCum[index] = _inputCum;
    _sampleCount += 1;
}

/// Aufsummierte Rohbewegung zum Zeitpunkt t (linear zwischen Proben, außerhalb geklemmt).
- (CGPoint)inputCumAtTime:(CFTimeInterval)t {
    if (_sampleCount == 0) {
        return _inputCum;
    }
    NSUInteger available = MIN(_sampleCount, (NSUInteger)kHistoryCount);
    NSUInteger newest = (_sampleCount - 1) % kHistoryCount;
    if (t >= _sampleTime[newest]) {
        return _sampleCum[newest];
    }
    for (NSUInteger k = 1; k < available; k++) {
        NSUInteger older = (_sampleCount - 1 - k) % kHistoryCount;
        NSUInteger newer = (_sampleCount - k) % kHistoryCount;
        if (t >= _sampleTime[older]) {
            CFTimeInterval span = _sampleTime[newer] - _sampleTime[older];
            CGFloat f = span > 0.0 ? (CGFloat)((t - _sampleTime[older]) / span) : 1.0;
            return CGPointMake(_sampleCum[older].x + (_sampleCum[newer].x - _sampleCum[older].x) * f,
                               _sampleCum[older].y + (_sampleCum[newer].y - _sampleCum[older].y) * f);
        }
    }
    return _sampleCum[(_sampleCount - available) % kHistoryCount];
}

/// Fingergeschwindigkeit (Rohpunkte/s) über das Fenster kSpeedWindow bis t.
- (CGPoint)inputVelocityAtTime:(CFTimeInterval)t {
    CGPoint now = [self inputCumAtTime:t];
    CGPoint before = [self inputCumAtTime:t - kSpeedWindow];
    return CGPointMake((now.x - before.x) / kSpeedWindow, (now.y - before.y) / kSpeedWindow);
}

- (void)acceptRawDelta:(CGPoint)delta atTime:(CFTimeInterval)time {
    _lastSampleArrival = time;
    _inputCum = CGPointMake(_inputCum.x + delta.x, _inputCum.y + delta.y);
    [self pushSampleAt:time];
    // Mittlerer Probenabstand über die letzten bis zu 8 Abstände (robust gegen gebündelt eintreffende Proben).
    NSUInteger span = MIN(_sampleCount - 1, (NSUInteger)8);
    if (span >= 2) {
        CFTimeInterval newest = _sampleTime[(_sampleCount - 1) % kHistoryCount];
        CFTimeInterval oldest = _sampleTime[(_sampleCount - 1 - span) % kHistoryCount];
        CFTimeInterval mean = (newest - oldest) / span;
        if (mean > 0.0 && mean < 0.05) {
            _sampleIntervalEstimate = mean;
        }
    }
    self.lastMovementSampleTime = time;
    [self ensurePointerLink];
}

/// Rohbewegung aus dem UIKit-Weg (Rückfall) annehmen.
- (void)enqueueRawPointerDelta:(CGPoint)delta sampleTime:(CFTimeInterval)sampleTime viaGameController:(BOOL)viaGameController {
    if (self.pressInProgress || self.revealOnlyTouch) {
        return;
    }
    BOOL tabOverviewVisible = [self.host browserRemoteInputControllerTabOverviewVisible];
    if (!viaGameController && !tabOverviewVisible && [self trackRotationWithDelta:delta]) {
        return;
    }
    [self acceptRawDelta:delta atTime:sampleTime];
}

/// Verdächtige Probe (zeigt entgegen der Bewegung oder ist viel größer als die vorigen): erst mit der nächsten Probe
/// annehmen. Kommt stattdessen das Abheben, war es das Abrollen der Fingerkuppe und wird verworfen.
- (BOOL)padDeltaIsSuspicious:(CGPoint)delta atTime:(CFTimeInterval)time {
    CGFloat length = hypot(delta.x, delta.y);
    CGPoint velocity = [self inputVelocityAtTime:time];
    CGFloat speed = hypot(velocity.x, velocity.y);
    CGFloat typicalStep = speed * MAX(_sampleIntervalEstimate, 0.004);
    BOOL backwards = speed > 40.0 && (delta.x * velocity.x + delta.y * velocity.y) < 0.0 && length > 1.5;
    BOOL oversized = length > MAX(8.0, typicalStep * kLiftOutlierFactor);
    return backwards || oversized;
}

- (void)releaseHeldPadDelta {
    if (!self.padHasHeld) {
        return;
    }
    self.padHasHeld = NO;
    if (self.pressInProgress || self.revealOnlyTouch) {
        return;
    }
    [self acceptRawDelta:self.padHeldDelta atTime:self.padHeldTime];
}

/// Beschleunigung: langsames Wischen bleibt präzise, schnelles Wischen trägt weit.
- (CGFloat)gainForSpeed:(CGFloat)pointsPerSecond {
    CGFloat t = MIN(MAX((pointsPerSecond - kGainSlowSpeed) / (kGainFastSpeed - kGainSlowSpeed), 0.0), 1.0);
    t = t * t * (3.0 - 2.0 * t);
    return (kGainMin + (kGainMax - kGainMin) * t) * self.pointerSpeedSetting;
}

#pragma mark Bildtakt

- (void)ensurePointerLink {
    if (self.pointerLink != nil) {
        return;
    }
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(pointerFrame:)];
    link.preferredFrameRateRange = CAFrameRateRangeMake(60.0, 120.0, 120.0);
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.pointerLink = link;
    self.pointerLinkLastTimestamp = 0;
}

- (void)stopPointerLink {
    [self.pointerLink invalidate];
    self.pointerLink = nil;
}

static CGFloat BrowserLowPassAlpha(CGFloat cutoff, CFTimeInterval dt) {
    CGFloat tau = 1.0 / (2.0 * M_PI * cutoff);
    return 1.0 / (1.0 + tau / dt);
}

/// 1-€-Filter: freePoint folgt rawPoint; die Grenzfrequenz steigt mit der Geschwindigkeit.
- (void)filterTowardRawPointWithInterval:(CFTimeInterval)dt previousRaw:(CGPoint)previousRaw {
    CGPoint raw = self.rawPoint;
    CGPoint velocity = CGPointMake((raw.x - previousRaw.x) / dt, (raw.y - previousRaw.y) / dt);
    CGFloat dAlpha = BrowserLowPassAlpha(kFilterDerivativeCutoff, dt);
    CGPoint smoothed = CGPointMake(self.filterVelocity.x + (velocity.x - self.filterVelocity.x) * dAlpha,
                                   self.filterVelocity.y + (velocity.y - self.filterVelocity.y) * dAlpha);
    self.filterVelocity = smoothed;
    CGFloat cutoff = kFilterMinCutoff + kFilterBeta * hypot(smoothed.x, smoothed.y);
    CGFloat alpha = BrowserLowPassAlpha(cutoff, dt);
    CGPoint free = self.freePoint;
    free.x += (raw.x - free.x) * alpha;
    free.y += (raw.y - free.y) * alpha;
    if (hypot(raw.x - free.x, raw.y - free.y) < 0.2) {
        free = raw;
    }
    self.freePoint = free;
}

- (void)beginGlideIfEligible {
    if (!self.glideEnabledSetting || self.liftTime - self.lastMovementSampleTime > kGlideMaxRestBeforeLift) {
        return;
    }
    if (!CGRectIsNull(self.snappedTarget) && [self targetAllowsCenterSnap:self.snappedTarget]) {
        return; // eingerastet: der Magnet hält
    }
    // Fingergeschwindigkeit kurz vor dem Abheben, mit derselben Beschleunigung wie die Bewegung.
    CGPoint velocity = [self inputVelocityAtTime:self.lastMovementSampleTime];
    CGFloat rawSpeed = hypot(velocity.x, velocity.y);
    CGFloat gain = [self gainForSpeed:rawSpeed];
    velocity = CGPointMake(velocity.x * gain, velocity.y * gain);
    CGFloat speed = rawSpeed * gain;
    if (speed < kGlideMinSpeed) {
        return;
    }
    CGFloat distance = speed * kGlideTimeConstant;
    if (distance > kGlideMaxDistance) {
        velocity = CGPointMake(velocity.x * kGlideMaxDistance / distance, velocity.y * kGlideMaxDistance / distance);
    }
    self.glideVelocity = velocity;
    self.glideTravelled = 0.0;
    self.gliding = YES;
}

/// Ein Takt pro Bildschirmbild: Bewegung nachabtasten, beschleunigen, glätten, einrasten, Zeigerebene setzen.
- (void)pointerFrame:(CADisplayLink *)link {
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = self.pointerLinkLastTimestamp > 0 ? link.timestamp - self.pointerLinkLastTimestamp
                                                          : link.targetTimestamp - link.timestamp;
    self.pointerLinkLastTimestamp = link.timestamp;
    dt = MIN(MAX(dt, 1.0 / 240.0), 1.0 / 15.0);
    if (self.padHasHeld && now - self.padHeldTime > kPadHoldMaxAge) {
        [self releaseHeldPadDelta];
    }

    BOOL tabOverviewVisible = [self.host browserRemoteInputControllerTabOverviewVisible];
    self.frameTargets = [self.host browserRemoteInputControllerPointerTargets];

    // Fingerlage zum Zeitpunkt „jetzt minus etwa ein Probenabstand“; nach dem Abheben die letzte Probe.
    BOOL fingerDown = self.padTouching || self.touchSourceActive;
    CFTimeInterval resampleLatency = MIN(MAX(_sampleIntervalEstimate * kResampleFactor, 0.004), kResampleMaxLatency);
    CFTimeInterval sampleTime = fingerDown ? now - resampleLatency : DBL_MAX;
    CGPoint cum = [self inputCumAtTime:sampleTime];
    CGPoint raw = CGPointMake(cum.x - _outputCum.x, cum.y - _outputCum.y);
    _outputCum = cum;

    CGPoint move = CGPointZero;
    BOOL fingerDriven = NO;
    if (!CGPointEqualToPoint(raw, CGPointZero)) {
        // Alter der gezeigten Fingerlage, wenn das Bild auf dem Schirm erscheint.
        double latency = link.targetTimestamp - (fingerDown ? sampleTime : _lastSampleArrival);
        _stats.latencySum += latency;
        _stats.latencyMax = MAX(_stats.latencyMax, latency);
        _stats.latencyCount += 1;
        CGPoint velocity = [self inputVelocityAtTime:MIN(sampleTime, _lastSampleArrival)];
        CGFloat gain = [self gainForSpeed:hypot(velocity.x, velocity.y)];
        move = CGPointMake(raw.x * gain, raw.y * gain);
        fingerDriven = YES;
        [self scheduleIdleHide];
    } else if (self.gliding) {
        move = CGPointMake(self.glideVelocity.x * dt, self.glideVelocity.y * dt);
        CGFloat decay = exp(-dt / kGlideTimeConstant);
        self.glideVelocity = CGPointMake(self.glideVelocity.x * decay, self.glideVelocity.y * decay);
        self.glideTravelled += hypot(move.x, move.y);
        _stats.glideDistance += hypot(move.x, move.y);
        if (hypot(self.glideVelocity.x, self.glideVelocity.y) < 40.0 || self.glideTravelled >= kGlideMaxDistance) {
            self.gliding = NO;
        }
    }

    CGPoint previousRaw = self.rawPoint;
    if (!CGPointEqualToPoint(move, CGPointZero)) {
        CGPoint next = CGPointMake(self.rawPoint.x + move.x, self.rawPoint.y + move.y);
        // An die Ränder begrenzen (gemessen an der Klickspitze). Was der Finger darüber hinaus schiebt, scrollt die Seite.
        CGRect bounds = [self pointerBounds];
        CGFloat maxX = CGRectGetMaxX(bounds) - 2.0;
        CGFloat maxY = CGRectGetMaxY(bounds) - 2.0;
        CGPoint overflow = CGPointZero;
        if (next.x < CGRectGetMinX(bounds)) { overflow.x = next.x - CGRectGetMinX(bounds); next.x = CGRectGetMinX(bounds); }
        if (next.x > maxX) { overflow.x = next.x - maxX; next.x = maxX; }
        if (next.y < CGRectGetMinY(bounds)) { overflow.y = next.y - CGRectGetMinY(bounds); next.y = CGRectGetMinY(bounds); }
        if (next.y > maxY) { overflow.y = next.y - maxY; next.y = maxY; }
        if (!CGPointEqualToPoint(overflow, CGPointZero)) {
            if (fingerDriven && !tabOverviewVisible && ![self addressPanelActive]) {
                // Sanft: Überhang knapp 1:1, damit es am Seitenrand nicht davonschießt.
                [self applyManualScrollDelta:CGPointMake(overflow.x * 0.9, overflow.y * 0.9)];
            }
            self.gliding = NO; // Gleiten scrollt nie, es endet am Rand.
        }
        self.rawPoint = next;
    }
    if (self.liftPending && !fingerDown) {
        self.liftPending = NO;
        [self beginGlideIfEligible];
    }
    [self filterTowardRawPointWithInterval:dt previousRaw:previousRaw];

    CGPoint previousVisible = self.visiblePoint;
    CGPoint visible;
    if (tabOverviewVisible) {
        visible = self.freePoint;
        self.easingActive = NO;
        self.cursorView.image = [self.host browserRemoteInputControllerTabOverviewContainsPoint:visible]
            ? BrowserPointerCursor()
            : BrowserDefaultCursor();
        [self setCursorImageVisible:YES];
    } else {
        CGPoint desired = [self evaluatePointerAnimated:YES];
        visible = desired;
        if (self.easingActive) {
            CGFloat k = 1.0 - exp(-dt / kSnapEaseTimeConstant);
            visible = CGPointMake(previousVisible.x + (desired.x - previousVisible.x) * k,
                                  previousVisible.y + (desired.y - previousVisible.y) * k);
            if (hypot(desired.x - visible.x, desired.y - visible.y) < 0.3) {
                visible = desired;
                self.easingActive = NO;
            }
        }
        if (self.gliding && !CGRectIsNull(self.snappedTarget) && [self targetAllowsCenterSnap:self.snappedTarget]) {
            self.gliding = NO; // Der Magnet fängt den gleitenden Zeiger.
        }
    }
    self.visiblePoint = visible;
    [self placeCursorAtPoint:visible animated:NO];
    self.frameTargets = nil;

    // Messwerte: Bildabstand, Schrittweite, plötzliche Sprünge, Schritte gegen die Bewegungsrichtung.
    _stats.frames += 1;
    _stats.frameDtSum += dt;
    _stats.frameDtMax = MAX(_stats.frameDtMax, dt);
    CGPoint step = CGPointMake(visible.x - previousVisible.x, visible.y - previousVisible.y);
    CGFloat stepLength = hypot(step.x, step.y);
    _stats.maxStep = MAX(_stats.maxStep, stepLength);
    if (stepLength > 20.0 && stepLength > _stats.lastStep * 2.5) {
        _stats.suddenSteps += 1;
    }
    CGPoint direction = self.filterVelocity;
    CGFloat speed = hypot(direction.x, direction.y);
    if (speed > 50.0 && (step.x * direction.x + step.y * direction.y) / speed < -1.0) {
        _stats.backSteps += 1;
    }
    _stats.lastStep = stepLength;
    double work = CACurrentMediaTime() - now;
    _stats.workSum += work;
    _stats.workMax = MAX(_stats.workMax, work);

    BOOL settled = CGPointEqualToPoint(self.rawPoint, self.freePoint) && CGPointEqualToPoint(_outputCum, _inputCum);
    if (!self.gliding && !self.easingActive && !self.liftPending && !self.padHasHeld && settled) {
        // Nichts mehr zu tun: Takt anhalten (läuft beim nächsten Ereignis wieder an).
        [self stopPointerLink];
        if (!fingerDown) {
            [self finishGestureStats];
        }
    }
}

- (void)finishGestureStats {
    if (!_stats.active) {
        return;
    }
    _stats.active = NO;
#if DEBUG
    if (_stats.frames == 0) {
        return;
    }
    CFTimeInterval duration = CACurrentMediaTime() - _stats.start;
    NSLog(@"[Pointer] Geste %@: %.2f s, Proben %lu (%.0f/s, Abstand %.1f ms, UIKit ignoriert %lu), Bilder %lu (Δt %.1f/%.1f ms), "
          @"Alter Fingerlage beim Anzeigen %.1f/%.1f ms, Rechenzeit %.2f/%.2f ms, größter Schritt %.0f pt, Sprünge %lu, "
          @"Rückschritte %lu, Achsen einzeln %lu, Sprünge verworfen %lu, Ausreißer verworfen %lu, Auslauf %.0f pt, Radius max %.2f",
          _stats.viaGameController ? @"GameController" : @"UIKit", duration,
          (unsigned long)_stats.samples, duration > 0 ? _stats.samples / duration : 0.0, _sampleIntervalEstimate * 1000.0,
          (unsigned long)_stats.touchSamplesIgnored,
          (unsigned long)_stats.frames, _stats.frameDtSum / _stats.frames * 1000.0, _stats.frameDtMax * 1000.0,
          _stats.latencyCount > 0 ? _stats.latencySum / _stats.latencyCount * 1000.0 : 0.0, _stats.latencyMax * 1000.0,
          _stats.workSum / _stats.frames * 1000.0, _stats.workMax * 1000.0, _stats.maxStep,
          (unsigned long)_stats.suddenSteps, (unsigned long)_stats.backSteps,
          (unsigned long)_stats.axisSkips, (unsigned long)_stats.jumpSkips, (unsigned long)_stats.outliersDropped,
          _stats.glideDistance, _stats.maxRadius);
#endif
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

/// Eine Probe des Clickpads (absolute Lage −1…1, (0,0) = kein Finger). Bewegung entsteht nur aus Differenzen,
/// Aufsetzen setzt nur den Bezugspunkt (kein Sprung). Proben, in denen genau eine Achse 0 ist, sind der Übergang beim
/// Aufsetzen oder Abheben (die Achsen kommen einzeln): sie bewegen nichts, sonst springt der Zeiger Richtung Mitte.
- (void)handlePadValue:(CGPoint)value {
    CFTimeInterval now = CACurrentMediaTime();
    BOOL xZero = value.x == 0.0;
    BOOL yZero = value.y == 0.0;
    if (xZero && yZero) {
        if (self.padTouching) {
            self.padTouching = NO;
            [self padDidLift];
        }
        return;
    }
    self.padLastSampleTime = now;
    BOOL blocked = [self.host browserRemoteInputControllerTopBarFocusActive] || !self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerPresentedViewController] != nil;
    if (!self.padTouching) {
        self.padTouching = YES;
        self.padLastValue = value;
        self.padBaselineValidX = !xZero;
        self.padBaselineValidY = !yZero;
        self.padHasHeld = NO;
        if (blocked) {
            return;
        }
        [self beginPointerGestureViaGameController:YES];
        _stats.samples = 1;
        [self trackRingWithPadPosition:value];
        return;
    }
    _stats.samples += 1;
    if (xZero || yZero) {
        // Übergang: nichts bewegen, Bezugspunkt behalten (verpasste Bewegung kommt mit der nächsten vollen Probe).
        _stats.axisSkips += 1;
        return;
    }
    CGPoint last = self.padLastValue;
    CGFloat dx = self.padBaselineValidX ? value.x - last.x : 0.0;
    CGFloat dy = self.padBaselineValidY ? value.y - last.y : 0.0;
    self.padLastValue = value;
    self.padBaselineValidX = YES;
    self.padBaselineValidY = YES;
    if (fabs(dx) > kPadMaxSampleJump || fabs(dy) > kPadMaxSampleJump) {
        _stats.jumpSkips += 1;
        return;
    }
    if (blocked) {
        return;
    }
    if ([self trackRingWithPadPosition:value]) {
        return;
    }
    if (dx == 0.0 && dy == 0.0) {
        return;
    }
    if (self.pressInProgress || self.revealOnlyTouch) {
        return;
    }
    // Clickpad-y zeigt nach oben, Bildschirm-y nach unten.
    CGPoint delta = CGPointMake(dx * kPadPointsPerUnit, -dy * kPadPointsPerUnit);
    // Eine zurückgehaltene Probe ist durch diese bestätigt.
    [self releaseHeldPadDelta];
    if ([self padDeltaIsSuspicious:delta atTime:now]) {
        self.padHeldDelta = delta;
        self.padHeldTime = now;
        self.padHasHeld = YES;
        [self ensurePointerLink];
        return;
    }
    [self acceptRawDelta:delta atTime:now];
}

- (void)padDidLift {
    if (self.padHasHeld) {
        // Letzte Probe vor dem Abheben war verdächtig: Abrollen der Fingerkuppe, verwerfen.
        self.padHasHeld = NO;
        _stats.outliersDropped += 1;
    }
    if (_stats.active) {
        [self pointerGestureDidLift];
    }
}

#pragma mark - Ring über die absolute Fingerlage (GameController)

/// Der Ring der Siri Remote ist der äußere Rand des Clickpads. Ein Kreis zählt nur, wenn der Finger dort bleibt
/// (Abstand zur Mitte mindestens kRingMinRadius) und um die Mitte wandert. Gerades Wischen kann das nicht auslösen;
/// die frühere Erkennung über die Drehung der Wischrichtung schlug bei langen, leicht krummen Bewegungen an und setzte
/// den Zeiger an den Gestenstart zurück.
static const CGFloat kRingMinRadius = 0.8;
/// Im Ringmodus bleibt es, bis der Finger weiter als bis hierhin zur Mitte rutscht.
static const CGFloat kRingKeepRadius = 0.55;
/// So weit (Grad) muss der Finger am Rand um die Mitte wandern, bevor der Ringmodus beginnt.
static const CGFloat kRingEnterAngle = 110.0 * M_PI / 180.0;
/// Danach je so viel Grad ein Schritt (wie bei der Kreisgeste).
static const CGFloat kRingStepAngle = 60.0 * M_PI / 180.0;

- (void)resetRing {
    self.ringHasAngle = NO;
    self.ringAccumulated = 0.0;
    self.ringStepAccumulated = 0.0;
    self.ringMode = NO;
}

/// YES, solange die Geste als Ring gilt (der Zeiger bewegt sich dann nicht).
- (BOOL)trackRingWithPadPosition:(CGPoint)position {
    CGFloat radius = hypot(position.x, position.y);
    _stats.maxRadius = MAX(_stats.maxRadius, radius);
    CGFloat angle = atan2(position.y, position.x);
    if (self.ringMode) {
        if (radius < kRingKeepRadius) {
            self.ringHasAngle = NO;
            return YES;
        }
        if (!self.ringHasAngle) {
            self.ringHasAngle = YES;
            self.ringLastAngle = angle;
            return YES;
        }
        CGFloat turn = angle - self.ringLastAngle;
        while (turn > M_PI) { turn -= 2.0 * M_PI; }
        while (turn < -M_PI) { turn += 2.0 * M_PI; }
        self.ringLastAngle = angle;
        // Clickpad-y zeigt nach oben: im Uhrzeigersinn ist der Winkel negativ, das heißt vorwärts.
        self.ringStepAccumulated -= turn;
        if (fabs(self.ringStepAccumulated) >= kRingStepAngle) {
            NSInteger direction = self.ringStepAccumulated > 0 ? 1 : -1;
            self.ringStepAccumulated -= direction * kRingStepAngle;
            [self ringStepBy:direction];
        }
        return YES;
    }
    if (radius < kRingMinRadius) {
        self.ringHasAngle = NO;
        self.ringAccumulated = 0.0;
        return NO;
    }
    if (!self.ringHasAngle) {
        self.ringHasAngle = YES;
        self.ringLastAngle = angle;
        return NO;
    }
    CGFloat turn = angle - self.ringLastAngle;
    while (turn > M_PI) { turn -= 2.0 * M_PI; }
    while (turn < -M_PI) { turn += 2.0 * M_PI; }
    self.ringLastAngle = angle;
    if (self.ringAccumulated != 0.0 && turn * self.ringAccumulated < 0.0 && fabs(turn) > 0.15) {
        self.ringAccumulated = 0.0;
    }
    self.ringAccumulated += turn;
    if (fabs(self.ringAccumulated) < kRingEnterAngle) {
        return NO;
    }
    // Ring erkannt: Zeiger dahin zurück, wo die Geste begann, dann einen Schritt weiter.
    self.ringMode = YES;
    self.ringStepAccumulated = 0.0;
    [self setPointerPositionDirectly:self.gestureStartPoint];
    self.snappedTarget = self.gestureStartTarget;
    [self updatePointerAnimated:NO];
    [self ringStepBy:self.ringAccumulated < 0.0 ? 1 : -1];
    return YES;
}

- (void)ringStepBy:(NSInteger)direction {
#if DEBUG
    self.debugRingSteps += direction;
#endif
    [self stepTargetBy:direction];
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
        [self setPointerPositionDirectly:self.gestureStartPoint];
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
    [self setPointerPositionDirectly:CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target))];
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
    [self setPointerPositionDirectly:CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target))];
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
            [self setPointerPositionDirectly:reference];
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
        [self setPointerPositionDirectly:CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target))];
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

#if DEBUG
#pragma mark - Selbsttest: synthetisches Wischen

/// Speist künstliche Clickpad-Rohwerte (absolute Lage −1…1) über die Zeit in denselben Weg wie die echte
/// Fernbedienung (handlePadValue:) und misst, was auf dem Bildschirm ankommt: Lage der sichtbaren Zeigerebene
/// (presentationLayer) pro Bildschirmbild. Nachgebildete Eigenheiten echter Hardware: unregelmäßige Abstände der
/// Proben (7/15 ms im Wechsel, ~90 Hz), Achsen kommen beim Aufsetzen und Loslassen einzeln an, letzter Wert vor dem
/// Loslassen als Ausreißer entgegen der Bewegungsrichtung (Fingerkuppe rollt ab).
- (void)debugRunSwipeWithPadDelta:(CGVector)padDelta duration:(NSTimeInterval)duration flick:(BOOL)flick artifacts:(BOOL)artifacts {
    self.cursorIdleHidden = NO;
    [self scheduleIdleHide];
    // Leicht neben der Mitte, damit keine Achse zufällig genau 0 ist (das kommt nur beim Aufsetzen/Abheben vor).
    CGPoint start = CGPointMake(-padDelta.dx / 2.0 + 0.04, -padDelta.dy / 2.0 + 0.12);
    CGFloat length = hypot(padDelta.dx, padDelta.dy);
    // Bildschirmrichtung: Clickpad-y nach oben = Bildschirm-y nach oben.
    CGVector unit = length > 0 ? CGVectorMake(padDelta.dx / length, -padDelta.dy / length) : CGVectorMake(1, 0);
    NSMutableArray<NSArray<NSNumber *> *> *schedule = [NSMutableArray array]; // [t, x, y]
    CFTimeInterval t = 0.0;
    void (^add)(CFTimeInterval, CGFloat, CGFloat) = ^(CFTimeInterval at, CGFloat x, CGFloat y) {
        [schedule addObject:@[@(at), @(x), @(y)]];
    };
    // Aufsetzen: erst x, dann y.
    if (artifacts) {
        add(t, start.x, 0.0f);
        t += 0.004;
    }
    add(t, start.x, start.y);
    NSUInteger index = 0;
    while (t < duration) {
        t += (index++ % 2 == 0) ? 0.007 : 0.015;
        CGFloat p = MIN(t / duration, 1.0);
        // Normal: weich an- und auslaufen (Finger kommt zur Ruhe). Flick: nur anlaufen, Loslassen in voller Fahrt.
        CGFloat s = flick ? p * p : p * p * (3.0 - 2.0 * p);
        add(t, start.x + padDelta.dx * s, start.y + padDelta.dy * s);
    }
    NSArray<NSNumber *> *last = schedule.lastObject;
    CGFloat lx = last[1].doubleValue, ly = last[2].doubleValue;
    if (artifacts) {
        // Ausreißer beim Abrollen: 0,05 Einheiten zurück.
        t += 0.009;
        add(t, lx - padDelta.dx / MAX(length, 0.001) * 0.05, ly - padDelta.dy / MAX(length, 0.001) * 0.05);
    }
    CFTimeInterval liftTime = t + 0.004;
    if (artifacts) {
        // Loslassen: erst x auf 0, dann beide.
        add(liftTime, 0.0f, ly);
    }
    add(liftTime + 0.003, 0.0f, 0.0f);

    NSMutableArray<NSValue *> *frames = [NSMutableArray array];     // (t, x/y der Klickspitze)
    NSMutableArray<NSNumber *> *frameTimes = [NSMutableArray array];
    CFTimeInterval origin = CACurrentMediaTime() + 0.1;
    BrowserDebugFrameSampler *sampler = [BrowserDebugFrameSampler new];
    __weak typeof(self) weakSelf = self;
    sampler.tick = ^(CFTimeInterval now) {
        CALayer *layer = weakSelf.cursorView.layer.presentationLayer ?: weakSelf.cursorView.layer;
        CGPoint tip = CGPointMake(layer.position.x - layer.bounds.size.width * layer.anchorPoint.x,
                                  layer.position.y - layer.bounds.size.height * layer.anchorPoint.y);
        [frames addObject:[NSValue valueWithCGPoint:tip]];
        [frameTimes addObject:@(now - origin)];
    };
    [sampler start];
    for (NSArray<NSNumber *> *sample in schedule) {
        CFTimeInterval at = sample[0].doubleValue;
        CGPoint value = CGPointMake(sample[1].doubleValue, sample[2].doubleValue);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.1 + at) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf handlePadValue:value];
        });
    }
    NSUInteger sampleCount = schedule.count;
    NSArray<NSValue *> *targets = [self.host browserRemoteInputControllerPointerTargets];
    NSMutableArray<NSString *> *targetList = [NSMutableArray array];
    for (NSValue *value in targets) {
        CGRect r = value.CGRectValue;
        [targetList addObject:[NSString stringWithFormat:@"%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.size.width, r.size.height]];
    }
    NSLog(@"[PointerTest] Start %@, Ziele: %@", NSStringFromCGPoint(self.freePoint), [targetList componentsJoinedByString:@" | "]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.1 + liftTime + 0.9) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [sampler stop];
        NSLog(@"[PointerTest] %@%@", artifacts ? @"" : @"sauber ", [BrowserRemoteInputController debugSummaryForFrames:frames times:frameTimes unit:unit
                                                                         fingerDuration:duration liftTime:liftTime
                                                                            sampleCount:sampleCount flick:flick]);
    });
}

/// Ring-Test: Finger wandert auf dem Radius radius (Clickpad-Einheiten) im Uhrzeigersinn um degrees Grad.
- (void)debugRunRingWithRadius:(CGFloat)radius degrees:(CGFloat)degrees duration:(NSTimeInterval)duration {
    self.cursorIdleHidden = NO;
    self.debugRingSteps = 0;
    CGPoint before = self.freePoint;
    NSUInteger count = MAX((NSUInteger)(duration / 0.011), 2);
    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i <= count; i++) {
        CGFloat angle = M_PI_2 - (degrees * M_PI / 180.0) * i / count + 0.05;
        CGPoint value = CGPointMake(radius * cos(angle), radius * sin(angle));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.05 + duration * i / count) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf handlePadValue:value];
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.06 + duration + 0.01) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf handlePadValue:CGPointZero];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.06 + duration + 0.8) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[PointerTest] ring r=%.2f %.0f°: Schritte %ld, Zeiger von %@ nach %@", radius, degrees,
              (long)weakSelf.debugRingSteps, NSStringFromCGPoint(before), NSStringFromCGPoint(weakSelf.freePoint));
    });
}

+ (NSString *)debugSummaryForFrames:(NSArray<NSValue *> *)frames times:(NSArray<NSNumber *> *)times unit:(CGVector)unit
                     fingerDuration:(NSTimeInterval)duration liftTime:(CFTimeInterval)liftTime
                        sampleCount:(NSUInteger)sampleCount flick:(BOOL)flick {
    if (frames.count < 3) {
        return @"zu wenige Bilder";
    }
    CGPoint first = frames.firstObject.CGPointValue;
    NSUInteger n = frames.count;
    CGFloat *s = calloc(n, sizeof(CGFloat));
    CGFloat *lateral = calloc(n, sizeof(CGFloat));
    for (NSUInteger i = 0; i < n; i++) {
        CGPoint p = frames[i].CGPointValue;
        s[i] = (p.x - first.x) * unit.dx + (p.y - first.y) * unit.dy;
        lateral[i] = -(p.x - first.x) * unit.dy + (p.y - first.y) * unit.dx;
    }
    double dtSum = 0, dtMax = 0;
    for (NSUInteger i = 1; i < n; i++) {
        double dt = times[i].doubleValue - times[i - 1].doubleValue;
        dtSum += dt;
        dtMax = MAX(dtMax, dt);
    }
    // Stand beim Loslassen und Endstand.
    CGFloat atLift = 0, final = s[n - 1];
    NSUInteger liftIndex = 0;
    for (NSUInteger i = 0; i < n; i++) {
        if (times[i].doubleValue <= liftTime) {
            atLift = s[i];
            liftIndex = i;
        }
    }
    CGFloat maxForward = 0;
    for (NSUInteger i = 0; i < n; i++) {
        maxForward = MAX(maxForward, s[i]);
    }
    // Gleichmäßigkeit im mittleren Abschnitt (30–70 % der Fingerzeit, gleichmäßigste Phase).
    double sum = 0, sumSq = 0;
    NSUInteger count = 0;
    CGFloat maxStep = 0, maxBack = 0, maxLateralStep = 0;
    NSUInteger backSteps = 0, zeroSteps = 0;
    for (NSUInteger i = 1; i < n; i++) {
        CGFloat step = s[i] - s[i - 1];
        maxStep = MAX(maxStep, fabs(step));
        maxLateralStep = MAX(maxLateralStep, fabs(lateral[i] - lateral[i - 1]));
        if (step < -0.5) {
            backSteps += 1;
            maxBack = MAX(maxBack, -step);
        }
        double tt = times[i].doubleValue;
        if (tt > duration * 0.3 && tt < duration * 0.7) {
            sum += step;
            sumSq += step * step;
            count += 1;
            if (fabs(step) < 0.25) {
                zeroSteps += 1;
            }
        }
    }
    double mean = count > 0 ? sum / count : 0;
    double variance = count > 0 ? MAX(0.0, sumSq / count - mean * mean) : 0;
    double cv = mean > 0 ? sqrt(variance) / mean * 100.0 : 0;
    // Nachlauf: Zeit, bis der Zeiger 50 % seines Wegs bis zum Loslassen hat, minus Zeit des Fingers für 50 %.
    double fingerHalf;
    if (flick) {
        fingerHalf = duration * sqrt(0.5);
    } else {
        fingerHalf = duration * 0.5;
    }
    double cursorHalf = -1;
    for (NSUInteger i = 0; i < n; i++) {
        if (atLift > 0 && s[i] >= atLift * 0.5) {
            cursorHalf = times[i].doubleValue;
            break;
        }
    }
    // Nach dem Loslassen: Rückwärtsbewegung gegenüber dem weitesten Stand.
    CGFloat backAfterLift = 0;
    CGFloat peakAfterLift = atLift;
    for (NSUInteger i = liftIndex; i < n; i++) {
        peakAfterLift = MAX(peakAfterLift, s[i]);
        backAfterLift = MAX(backAfterLift, peakAfterLift - s[i]);
    }
    NSString *summary = [NSString stringWithFormat:
        @"%@ %.0f ms: Proben %lu, Bilder %lu (Δt %.1f/%.1f ms), Schritt %.1f pt (CV %.0f %%, Stillstände %lu/%lu), "
        @"größter Schritt %.1f pt, quer %.1f pt, Rücksprünge %lu (max %.1f pt), Nachlauf 50 %% %.0f ms, "
        @"Weg bis Loslassen %.0f pt, Auslauf %.0f pt, zurück nach Loslassen %.1f pt, Ende %.0f pt (Spitze %.0f)",
        flick ? @"flick" : @"wisch", duration * 1000.0, (unsigned long)sampleCount, (unsigned long)n,
        dtSum / (n - 1) * 1000.0, dtMax * 1000.0, mean, cv, (unsigned long)zeroSteps, (unsigned long)count,
        maxStep, maxLateralStep, (unsigned long)backSteps, maxBack,
        cursorHalf >= 0 ? (cursorHalf - fingerHalf) * 1000.0 : -1.0,
        atLift, final - atLift, backAfterLift, final, maxForward];
    free(s);
    free(lateral);
    return summary;
}
#endif

- (void)movePointerToPoint:(CGPoint)point {
    self.cursorIdleHidden = NO;
    [self setPointerPositionDirectly:point];
    [self updatePointerAnimated:YES];
    [self scheduleIdleHide];
}

@end
