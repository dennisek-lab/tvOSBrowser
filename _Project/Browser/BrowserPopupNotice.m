//
//  BrowserPopupNotice.m
//  Browser
//

#import "BrowserPopupNotice.h"

#import "BrowserMotion.h"
#import "BrowserShape.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

/// Sichtbar so lange; jedes weitere Pop-up startet die Zeit neu.
static const NSTimeInterval kPopupNoticeDuration = 6.0;
static const CGFloat kPopupNoticeHeight = 104.0;
static const CGFloat kPopupNoticeMaxWidth = 780.0;
/// Abstand zum rechten und unteren Bildschirmrand (innerhalb des Title-Safe-Bereichs).
static const CGFloat kPopupNoticeRightMargin = 80.0;
static const CGFloat kPopupNoticeBottomMargin = 70.0;
static const CGFloat kPopupNoticePadding = 36.0;
static const CGFloat kPopupNoticeIconSide = 44.0;
static const CGFloat kPopupNoticeIconSpacing = 18.0;

static UIVisualEffect *BrowserPopupNoticeEffect(void) {
    if (!BrowserMotion.glassMaterialAvailable) {
        return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]; // altes Design bzw. vor tvOS 26
    }
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        // Leicht dunkel getönt wie die Rückmeldungen, damit die weiße Schrift über hellen Seiten lesbar bleibt.
        glass.tintColor = [UIColor colorWithWhite:0.0 alpha:0.35];
        return glass;
    }
#endif
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

@interface BrowserPopupNoticeView : UIVisualEffectView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@end

@implementation BrowserPopupNoticeView

- (instancetype)init {
    self = [super initWithEffect:nil];
    if (self) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        BrowserShapeApply(self.layer, BrowserShapeCapsuleRadius(kPopupNoticeHeight));
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
        UIImage *image = [UIImage systemImageNamed:@"macwindow.badge.plus" withConfiguration:config]
            ?: [UIImage systemImageNamed:@"square.on.square" withConfiguration:config];
        _iconView = [[UIImageView alloc] initWithImage:image];
        _iconView.tintColor = UIColor.whiteColor;
        _iconView.contentMode = UIViewContentModeCenter;
        [self.contentView addSubview:_iconView];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_titleLabel];
        _detailLabel = [[UILabel alloc] init];
        _detailLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightRegular];
        _detailLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
        [self.contentView addSubview:_detailLabel];
    }
    return self;
}

- (CGFloat)preferredWidth {
    CGFloat textWidth = MAX([self.titleLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, 40.0)].width,
                            [self.detailLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, 30.0)].width);
    CGFloat width = 2.0 * kPopupNoticePadding + kPopupNoticeIconSide + kPopupNoticeIconSpacing + ceil(textWidth);
    return MIN(kPopupNoticeMaxWidth, width);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = CGRectGetHeight(self.bounds);
    self.iconView.frame = CGRectMake(kPopupNoticePadding, 0.0, kPopupNoticeIconSide, height);
    CGFloat x = kPopupNoticePadding + kPopupNoticeIconSide + kPopupNoticeIconSpacing;
    CGFloat width = MAX(0.0, CGRectGetWidth(self.bounds) - x - kPopupNoticePadding);
    self.titleLabel.frame = CGRectMake(x, 16.0, width, 40.0);
    self.detailLabel.frame = CGRectMake(x, 56.0, width, 30.0);
}

@end

@interface BrowserPopupNotice ()
@property (nonatomic, weak) UIView *containerView;
@property (nonatomic, strong, nullable) BrowserPopupNoticeView *view;
/// Tabs der laufenden Einblendung (Reihenfolge des Öffnens).
@property (nonatomic, strong) NSMutableArray<NSString *> *burstIdentifiers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *displayNames;
@property (nonatomic) BOOL burstAllPopups;
@property (nonatomic) BOOL firstSameSite;
@property (nonatomic) NSUInteger generation;
@end

@implementation BrowserPopupNotice

- (instancetype)initWithContainerView:(UIView *)containerView {
    self = [super init];
    if (self) {
        _containerView = containerView;
        _burstIdentifiers = [NSMutableArray array];
        _displayNames = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)isVisible {
    return self.view != nil;
}

- (NSString *)targetTabIdentifier {
    return self.visible ? self.burstIdentifiers.lastObject : nil;
}

- (CGRect)frameInContainer {
    return self.view != nil ? self.view.frame : CGRectNull;
}

- (CGFloat)cornerRadius {
    return BrowserShapeCapsuleRadius(kPopupNoticeHeight);
}

- (NSString *)text {
    return self.view.titleLabel.text;
}

- (NSString *)currentTitle {
    NSUInteger count = self.burstIdentifiers.count;
    if (count > 1) {
        return self.burstAllPopups ? [NSString stringWithFormat:@"%lu Pop-ups geöffnet", (unsigned long)count]
                                   : [NSString stringWithFormat:@"%lu Tabs im Hintergrund geöffnet", (unsigned long)count];
    }
    NSString *identifier = self.burstIdentifiers.firstObject;
    NSString *name = identifier != nil ? self.displayNames[identifier] : nil;
    if (self.burstAllPopups) {
        if (self.firstSameSite || name.length == 0) {
            return @"Diese Webseite hat soeben ein Pop-up geöffnet";
        }
        return [NSString stringWithFormat:@"Pop-up geöffnet: %@", name];
    }
    return name.length > 0 ? [NSString stringWithFormat:@"Im Hintergrund geöffnet: %@", name] : @"Link im Hintergrund geöffnet";
}

- (void)noteTabWithIdentifier:(NSString *)identifier sameSite:(BOOL)sameSite popup:(BOOL)popup displayName:(NSString *)displayName {
    UIView *container = self.containerView;
    if (container == nil || identifier.length == 0) {
        return;
    }
    if (!self.visible) {
        [self.burstIdentifiers removeAllObjects];
        [self.displayNames removeAllObjects];
        self.burstAllPopups = YES;
        self.firstSameSite = sameSite;
    }
    if (![self.burstIdentifiers containsObject:identifier]) {
        [self.burstIdentifiers addObject:identifier];
    }
    self.displayNames[identifier] = displayName ?: @"";
    self.burstAllPopups = self.burstAllPopups && popup;

    BOOL appearing = self.view == nil;
    if (appearing) {
        self.view = [BrowserPopupNoticeView new];
    }
    self.view.titleLabel.text = [self currentTitle];
    self.view.detailLabel.text = @"Play/Pause: öffnen";
    [self layoutAnimated:!appearing];
    if (appearing) {
        [container addSubview:self.view];
        [self.view layoutIfNeeded];
        BOOL liquid = BrowserMotion.liquidGlassEnabled;
        BrowserPopupNoticeView *view = self.view;
        view.contentView.alpha = 0.0;
        if (liquid) {
            view.transform = CGAffineTransformMakeScale(0.9, 0.9);
        }
        [BrowserMotion glassAppear:view effect:BrowserPopupNoticeEffect() kind:BrowserMotionKindAppear alongside:^{
            view.contentView.alpha = 1.0;
            view.transform = CGAffineTransformIdentity;
        } completion:nil];
        if (self.visibilityHandler != nil) {
            self.visibilityHandler(YES);
        }
    } else {
        [container bringSubviewToFront:self.view];
    }
    NSLog(@"[Popup] Einblendung „%@“ (%lu Tabs)", self.view.titleLabel.text, (unsigned long)self.burstIdentifiers.count);
    [self scheduleHide];
}

- (void)updateDisplayName:(NSString *)displayName forTabWithIdentifier:(NSString *)identifier {
    if (!self.visible || identifier == nil || ![self.burstIdentifiers containsObject:identifier] || displayName.length == 0) {
        return;
    }
    if ([self.displayNames[identifier] isEqualToString:displayName]) {
        return;
    }
    self.displayNames[identifier] = displayName;
    NSString *title = [self currentTitle];
    if ([title isEqualToString:self.view.titleLabel.text]) {
        return;
    }
    self.view.titleLabel.text = title;
    NSLog(@"[Popup] Einblendung „%@“ (Titel geladen)", title);
    [self layoutAnimated:YES];
    if (self.visibilityHandler != nil) {
        self.visibilityHandler(YES); // Rahmen hat sich geändert: Zeigerziel neu melden.
    }
}

- (void)layoutAnimated:(BOOL)animated {
    UIView *container = self.containerView;
    if (self.view == nil || container == nil) {
        return;
    }
    CGRect bounds = container.bounds;
    CGFloat width = MIN([self.view preferredWidth], CGRectGetWidth(bounds) - 2.0 * kPopupNoticeRightMargin);
    CGRect frame = CGRectMake(CGRectGetWidth(bounds) - kPopupNoticeRightMargin - width,
                              CGRectGetHeight(bounds) - kPopupNoticeBottomMargin - kPopupNoticeHeight,
                              width, kPopupNoticeHeight);
    if (!animated) {
        self.view.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(frame), CGRectGetHeight(frame));
        self.view.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        return;
    }
    BrowserPopupNoticeView *view = self.view;
    [BrowserMotion animateKind:BrowserMotionKindStandard delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        view.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(frame), CGRectGetHeight(frame));
        view.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        [view layoutIfNeeded];
    } completion:nil];
}

- (void)scheduleHide {
    NSUInteger generation = ++self.generation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPopupNoticeDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.generation == generation) {
            [weakSelf dismiss];
        }
    });
}

- (void)dismiss {
    BrowserPopupNoticeView *view = self.view;
    if (view == nil) {
        return;
    }
    self.generation++;
    self.view = nil;
    BOOL liquid = BrowserMotion.liquidGlassEnabled;
    [BrowserMotion glassDisappear:view kind:BrowserMotionKindDisappear alongside:^{
        view.contentView.alpha = 0.0;
        if (liquid) {
            view.transform = CGAffineTransformMakeScale(0.92, 0.92);
        }
    } completion:^(__unused BOOL finished) {
        [view removeFromSuperview];
    }];
    if (self.visibilityHandler != nil) {
        self.visibilityHandler(NO);
    }
}

@end
