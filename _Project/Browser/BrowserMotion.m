//
//  BrowserMotion.m
//

#import "BrowserMotion.h"
#import "BrowserPreferencesStore.h"
#import <objc/runtime.h>

static char kBrowserMotionStoredEffectKey;

typedef struct {
    NSTimeInterval duration;   // Liquid Glass: wahrgenommene Dauer der Feder; schlicht: Kurvendauer
    CGFloat bounce;            // nur Liquid Glass
    UIViewAnimationOptions curve; // nur schlicht
} BrowserMotionParameters;

// Abstimmung. Federwerte nach WWDC23 „Animate with springs“: Bounce 0 = ruhig, ~0,15 = lebendig, > 0,4 übertrieben.
static BrowserMotionParameters BrowserMotionLiquidParameters(BrowserMotionKind kind) {
    switch (kind) {
        case BrowserMotionKindStandard:   return (BrowserMotionParameters){0.42, 0.14, 0};
        case BrowserMotionKindAppear:     return (BrowserMotionParameters){0.48, 0.18, 0};
        case BrowserMotionKindDisappear:  return (BrowserMotionParameters){0.32, 0.0, 0};
        case BrowserMotionKindSnap:       return (BrowserMotionParameters){0.20, 0.10, 0};
        case BrowserMotionKindFade:       return (BrowserMotionParameters){0.30, 0.0, 0};
    }
    return (BrowserMotionParameters){0.42, 0.14, 0};
}

static BrowserMotionParameters BrowserMotionPlainParameters(BrowserMotionKind kind) {
    switch (kind) {
        case BrowserMotionKindStandard:   return (BrowserMotionParameters){0.25, 0.0, UIViewAnimationOptionCurveEaseInOut};
        case BrowserMotionKindAppear:     return (BrowserMotionParameters){0.22, 0.0, UIViewAnimationOptionCurveEaseOut};
        case BrowserMotionKindDisappear:  return (BrowserMotionParameters){0.20, 0.0, UIViewAnimationOptionCurveEaseIn};
        case BrowserMotionKindSnap:       return (BrowserMotionParameters){0.12, 0.0, UIViewAnimationOptionCurveEaseOut};
        case BrowserMotionKindFade:       return (BrowserMotionParameters){0.20, 0.0, UIViewAnimationOptionCurveEaseInOut};
    }
    return (BrowserMotionParameters){0.25, 0.0, UIViewAnimationOptionCurveEaseInOut};
}

static CAMediaTimingFunction *BrowserMotionTimingFunction(UIViewAnimationOptions curve) {
    switch (curve) {
        case UIViewAnimationOptionCurveEaseOut: return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        case UIViewAnimationOptionCurveEaseIn: return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        case UIViewAnimationOptionCurveLinear: return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        default: return [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    }
}

#if DEBUG
static BOOL BrowserMotionLogEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = getenv("MOTION_LOG") != NULL; });
    return enabled;
}
#endif

@implementation BrowserMotion

+ (BOOL)liquidGlassEnabled {
    if (UIAccessibilityIsReduceMotionEnabled()) {
        return NO;
    }
    return [BrowserPreferencesStore new].liquidGlassAnimationsEnabled;
}

+ (BOOL)glowAnimationEnabled {
    if (UIAccessibilityIsReduceMotionEnabled()) {
        return NO;
    }
    return [BrowserPreferencesStore new].glowAnimationEnabled;
}

+ (BOOL)glassMaterialAvailable {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ available = NSClassFromString(@"UIGlassEffect") != Nil; });
    return available;
}

+ (NSTimeInterval)durationForKind:(BrowserMotionKind)kind {
    if (self.liquidGlassEnabled) {
        BrowserMotionParameters p = BrowserMotionLiquidParameters(kind);
        CASpringAnimation *spring = [[CASpringAnimation alloc] initWithPerceptualDuration:p.duration bounce:p.bounce];
        return spring.settlingDuration;
    }
    return BrowserMotionPlainParameters(kind).duration;
}

+ (void)animate:(void (NS_NOESCAPE ^)(void))animations completion:(void (^)(BOOL))completion {
    [self animateKind:BrowserMotionKindStandard delay:0.0 options:0 animations:animations completion:completion];
}

+ (void)animateKind:(BrowserMotionKind)kind
              delay:(NSTimeInterval)delay
            options:(UIViewAnimationOptions)options
         animations:(void (NS_NOESCAPE ^)(void))animations
         completion:(void (^)(BOOL))completion {
    // Kurvenbits des Aufrufers verwerfen, die Kurve gehört zum Stil.
    options &= ~(UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionCurveEaseIn |
                 UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionCurveLinear);
    BOOL liquid = self.liquidGlassEnabled;
#if DEBUG
    if (BrowserMotionLogEnabled()) {
        NSLog(@"[Motion] kind=%ld liquid=%d dauer=%.3f", (long)kind, liquid, [self durationForKind:kind]);
    }
#endif
    if (liquid) {
        BrowserMotionParameters p = BrowserMotionLiquidParameters(kind);
        [UIView animateWithSpringDuration:p.duration bounce:p.bounce initialSpringVelocity:0.0 delay:delay
                                  options:options animations:animations completion:completion];
        return;
    }
    BrowserMotionParameters p = BrowserMotionPlainParameters(kind);
    [UIView animateWithDuration:p.duration delay:delay options:options | p.curve animations:animations completion:completion];
}

+ (CABasicAnimation *)layerAnimationForKind:(BrowserMotionKind)kind {
    if (self.liquidGlassEnabled) {
        BrowserMotionParameters p = BrowserMotionLiquidParameters(kind);
        CASpringAnimation *spring = [[CASpringAnimation alloc] initWithPerceptualDuration:p.duration bounce:p.bounce];
        spring.duration = spring.settlingDuration;
        return spring;
    }
    BrowserMotionParameters p = BrowserMotionPlainParameters(kind);
    CABasicAnimation *animation = [CABasicAnimation animation];
    animation.duration = p.duration;
    animation.timingFunction = BrowserMotionTimingFunction(p.curve);
    return animation;
}

+ (void)animateShadowPathOfLayer:(CALayer *)layer fromPath:(CGPathRef)fromPath kind:(BrowserMotionKind)kind {
    // Läuft schon eine Umriss-Animation, vom sichtbaren Zwischenstand aus weiter (Präsentationsebene).
    CALayer *presentation = [layer animationForKey:@"shadowPath"] != nil ? layer.presentationLayer : nil;
    if (presentation.shadowPath != NULL) {
        fromPath = presentation.shadowPath;
    }
    id fromValue = fromPath != NULL ? (__bridge id)fromPath : nil;
    id toValue = layer.shadowPath != NULL ? (__bridge id)layer.shadowPath : nil;
    [layer removeAnimationForKey:@"shadowPath"];
    if (fromValue == nil || toValue == nil || CGPathEqualToPath(fromPath, layer.shadowPath)) {
        return;
    }
    CABasicAnimation *animation = nil;
    if (self.liquidGlassEnabled) {
        // Dieselbe Feder wie +[UIView animateWithSpringDuration:bounce:…], damit Umriss und Fläche gleich laufen.
        BrowserMotionParameters p = BrowserMotionLiquidParameters(kind);
        CASpringAnimation *spring = [[CASpringAnimation alloc] initWithPerceptualDuration:p.duration bounce:p.bounce];
        spring.duration = spring.settlingDuration;
        animation = spring;
    } else {
        BrowserMotionParameters p = BrowserMotionPlainParameters(kind);
        animation = [CABasicAnimation animation];
        animation.duration = p.duration;
        animation.timingFunction = BrowserMotionTimingFunction(p.curve);
    }
    animation.keyPath = @"shadowPath";
    animation.fromValue = fromValue;
    animation.toValue = toValue;
    [layer addAnimation:animation forKey:@"shadowPath"];
#if DEBUG
    if (BrowserMotionLogEnabled()) {
        for (NSString *key in layer.animationKeys) {
            CAAnimation *running = [layer animationForKey:key];
            if ([running isKindOfClass:CASpringAnimation.class]) {
                CASpringAnimation *s = (CASpringAnimation *)running;
                NSLog(@"[Motion] Ebene %@: Feder Masse=%.2f Steife=%.2f Dämpfung=%.2f Dauer=%.3f", key, s.mass, s.stiffness, s.damping, s.duration);
            } else {
                NSLog(@"[Motion] Ebene %@: %@ Dauer=%.3f", key, NSStringFromClass(running.class), running.duration);
            }
        }
    }
#endif
}

+ (void)glassAppear:(UIVisualEffectView *)view
             effect:(UIVisualEffect *)effect
               kind:(BrowserMotionKind)kind
          alongside:(void (^)(void))extra
         completion:(void (^)(BOOL))completion {
    if (self.liquidGlassEnabled) {
        // Materialisieren: Glas baut Lichtbrechung auf, statt einzublenden (HIG/WWDC25: effect statt alpha).
        [UIView performWithoutAnimation:^{
            view.effect = nil;
            view.alpha = 1.0;
        }];
        [self animateKind:kind delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
               animations:^{
            view.effect = effect;
            if (extra != nil) {
                extra();
            }
        } completion:completion];
        return;
    }
    [UIView performWithoutAnimation:^{
        view.effect = effect;
        view.alpha = 0.0;
    }];
    [self animateKind:kind delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
           animations:^{
        view.alpha = 1.0;
        if (extra != nil) {
            extra();
        }
    } completion:completion];
}

+ (void)glassDisappear:(UIVisualEffectView *)view
                  kind:(BrowserMotionKind)kind
             alongside:(void (^)(void))extra
            completion:(void (^)(BOOL))completion {
    BOOL liquid = self.liquidGlassEnabled;
    [self animateKind:kind delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
           animations:^{
        if (liquid) {
            view.effect = nil;
        } else {
            view.alpha = 0.0;
        }
        if (extra != nil) {
            extra();
        }
    } completion:completion];
}

+ (void)presentCard:(UIView *)card glassEffect:(UIVisualEffect *)effect {
    if (!self.liquidGlassEnabled) {
        return;
    }
    UIVisualEffectView *effectView = [card isKindOfClass:UIVisualEffectView.class] ? (UIVisualEffectView *)card : nil;
    // Nach dismissCard: (effect nil) erscheint dieselbe Karte mit ihrem gemerkten Glas wieder.
    effect = effect ?: objc_getAssociatedObject(card, &kBrowserMotionStoredEffectKey);
    [UIView performWithoutAnimation:^{
        if (effectView != nil && effect != nil) {
            effectView.effect = nil;
        }
        card.transform = CGAffineTransformMakeScale(0.94, 0.94);
    }];
    [self animateKind:BrowserMotionKindAppear delay:0.0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        if (effectView != nil && effect != nil) {
            effectView.effect = effect;
        }
        card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

+ (void)dismissCard:(UIView *)card {
    if (!self.liquidGlassEnabled) {
        return;
    }
    UIVisualEffectView *effectView = [card isKindOfClass:UIVisualEffectView.class] ? (UIVisualEffectView *)card : nil;
    if (effectView.effect != nil) {
        objc_setAssociatedObject(card, &kBrowserMotionStoredEffectKey, effectView.effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self animateKind:BrowserMotionKindDisappear delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        effectView.effect = nil;
        card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:nil];
}

@end
