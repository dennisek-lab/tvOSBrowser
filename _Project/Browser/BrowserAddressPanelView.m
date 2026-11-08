//
//  BrowserAddressPanelView.m
//

#import "BrowserAddressPanelView.h"
#import "BrowserTabCoordinator.h"
#import "BrowserFaviconCache.h"
#import "BrowserHistoryStore.h"
#import "BrowserMotion.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

// Aufbau, hier leicht änderbar. Kacheln bleiben unter 420 × 140 pt, damit der Zeiger mittig einrastet.
static NSUInteger const kPanelTilesPerSection = 4;          // 2 × 2
static CGFloat const kPanelGapBelowBar = 14.0;
static CGFloat const kPanelCornerRadius = 40.0;
static CGFloat const kPanelSideInset = 40.0;
static CGFloat const kPanelTopInset = 26.0;
static CGFloat const kPanelBottomInset = 32.0;
static CGFloat const kPanelHeaderHeight = 44.0;
static CGFloat const kPanelHeaderGap = 18.0;
static CGFloat const kPanelRowGap = 22.0;
static CGFloat const kPanelColumnGap = 28.0;
static CGFloat const kPanelFavoriteIconSize = 136.0;       // Spalte A: etwas größer, ohne Namen
static CGFloat const kPanelSmallIconSize = 96.0;           // Spalten B und C: mit Namen darunter
static CGFloat const kPanelSmallTileWidth = 190.0;
static CGFloat const kPanelNameGap = 8.0;
static CGFloat const kPanelNameHeight = 30.0;
static CGFloat const kPanelIconCornerFraction = 0.24;
/// Ab dieser Pixelgröße füllt das Icon die Kachel, kleinere Favicons sitzen mittig auf hellem Grund.
static CGFloat const kPanelFullBleedPixelSize = 96.0;

static NSString *BrowserAddressPanelDisplayName(BrowserSiteEntry *entry) {
    // Gleicher Kurzname wie in der Leiste („Apple TV – Wikipedia“ → „Wikipedia“, Guardian → „The Guardian“).
    NSString *name = entry.host.length > 0 ? BrowserShortSiteName(nil, entry.name, entry.host) : entry.name;
    // Name wie eine Domain („tagesschau.de“): ohne Endung, damit er unter die Kachel passt.
    BOOL domainLike = name.length > 0 && [name rangeOfString:@" "].location == NSNotFound &&
        [entry.host hasSuffix:name.lowercaseString];
    if (name.length == 0 || name.length > 22 || domainLike) {
        // Langer Seitentitel: lieber der Hauptteil des Hostnamens.
        NSArray<NSString *> *parts = [entry.host componentsSeparatedByString:@"."];
        NSString *base = parts.count >= 2 ? parts[parts.count - 2] : entry.host;
        return base.length > 0 ? base.capitalizedString : entry.host;
    }
    return name;
}

static UIColor *BrowserAddressPanelColorForHost(NSString *host) {
    NSUInteger hash = 5381;
    for (NSUInteger i = 0; i < host.length; i++) {
        hash = hash * 33 + [host characterAtIndex:i];
    }
    return [UIColor colorWithHue:(hash % 360) / 360.0 saturation:0.55 brightness:0.62 alpha:1.0];
}

#pragma mark - Kachel

@interface BrowserAddressTileView : UIView
@property (nonatomic, nullable) BrowserSiteEntry *entry;
@property (nonatomic) CGFloat iconSize;
@property (nonatomic) BOOL showsName;
@property (nonatomic) UIView *iconBackgroundView;
@property (nonatomic) UIImageView *iconImageView;
@property (nonatomic) UILabel *letterLabel;
@property (nonatomic) UILabel *nameLabel;
@property (nonatomic, copy, nullable) NSString *loadingHost;
@property (nonatomic) BOOL fullBleed;
@end

@implementation BrowserAddressTileView

- (instancetype)initWithEntry:(nullable BrowserSiteEntry *)entry iconSize:(CGFloat)iconSize showsName:(BOOL)showsName {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _entry = entry;
        _iconSize = iconSize;
        _showsName = showsName;
        self.userInteractionEnabled = NO;

        _iconBackgroundView = [UIView new];
        _iconBackgroundView.layer.cornerRadius = iconSize * kPanelIconCornerFraction;
        _iconBackgroundView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconBackgroundView.clipsToBounds = YES;
        [self addSubview:_iconBackgroundView];

        _letterLabel = [UILabel new];
        _letterLabel.textAlignment = NSTextAlignmentCenter;
        _letterLabel.textColor = UIColor.whiteColor;
        _letterLabel.font = [UIFont systemFontOfSize:iconSize * 0.42 weight:UIFontWeightBold];
        [_iconBackgroundView addSubview:_letterLabel];

        _iconImageView = [UIImageView new];
        _iconImageView.contentMode = UIViewContentModeScaleAspectFill;
        _iconImageView.clipsToBounds = YES;
        [_iconBackgroundView addSubview:_iconImageView];

        _nameLabel = [UILabel new];
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _nameLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.82];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _nameLabel.hidden = !showsName;
        [self addSubview:_nameLabel];

        [self applyEntry];
    }
    return self;
}

- (void)applyEntry {
    BrowserSiteEntry *entry = self.entry;
    if (entry == nil) {
        // Leerer Platz: dezente Fläche, damit das 2 × 2-Raster erkennbar bleibt.
        self.iconBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        self.iconBackgroundView.layer.borderWidth = 1.0;
        self.iconBackgroundView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
        self.letterLabel.text = nil;
        self.iconImageView.image = nil;
        self.nameLabel.text = nil;
        return;
    }
    NSString *name = BrowserAddressPanelDisplayName(entry);
    self.nameLabel.text = name;
    self.letterLabel.text = name.length > 0 ? [[name substringToIndex:1] uppercaseString] : @"?";
    self.iconBackgroundView.backgroundColor = BrowserAddressPanelColorForHost(entry.host);
    self.iconBackgroundView.layer.borderWidth = 0.0;
    self.accessibilityLabel = name;
    self.isAccessibilityElement = YES;

    UIImage *cached = [BrowserFaviconCache.sharedCache cachedIconForHost:entry.host];
    if (cached != nil) {
        [self applyIcon:cached];
        return;
    }
    self.loadingHost = entry.host;
    __weak typeof(self) weakSelf = self;
    [BrowserFaviconCache.sharedCache loadIconForHost:entry.host completion:^(UIImage *image) {
        if (image != nil && [weakSelf.loadingHost isEqualToString:entry.host]) {
            [UIView transitionWithView:weakSelf.iconBackgroundView duration:0.2
                               options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                            animations:^{ [weakSelf applyIcon:image]; } completion:nil];
        }
    }];
}

- (void)applyIcon:(UIImage *)image {
    CGFloat pixels = MAX(image.size.width, image.size.height) * image.scale;
    BOOL fullBleed = pixels >= kPanelFullBleedPixelSize;
    self.iconImageView.image = image;
    self.iconImageView.contentMode = fullBleed ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    self.iconImageView.layer.magnificationFilter = fullBleed ? kCAFilterLinear : kCAFilterTrilinear;
    // Kleine Favicons auf hellem Grund wie in Safari, große (Touch-Icons) füllen die Kachel.
    self.iconBackgroundView.backgroundColor = fullBleed ? UIColor.clearColor : [UIColor colorWithWhite:0.95 alpha:1.0];
    self.letterLabel.hidden = YES;
    self.fullBleed = fullBleed;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGRect iconFrame = CGRectMake(floor((width - self.iconSize) / 2.0), 0.0, self.iconSize, self.iconSize);
    self.iconBackgroundView.frame = iconFrame;
    self.letterLabel.frame = self.iconBackgroundView.bounds;
    CGFloat inset = self.fullBleed ? 0.0 : floor(self.iconSize * 0.22);
    self.iconImageView.frame = CGRectInset(self.iconBackgroundView.bounds, inset, inset);
    self.nameLabel.frame = CGRectMake(0.0, CGRectGetMaxY(iconFrame) + kPanelNameGap, width, kPanelNameHeight);
}

@end

#pragma mark - Karte

@interface BrowserAddressPanelView ()
@property (nonatomic) UIView *dimView;
@property (nonatomic) UIVisualEffectView *cardView;
@property (nonatomic) UIView *cardTintView;
@property (nonatomic) UIView *contentHostView;
@property (nonatomic) NSArray<UIView *> *columnViews;
@property (nonatomic) NSMutableArray<BrowserAddressTileView *> *tiles;
@property (nonatomic) CGRect barFrame;
@property (nonatomic) BOOL dismissing;
@end

@implementation BrowserAddressPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO; // Bedienung läuft über den Zeiger der App
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _tiles = [NSMutableArray array];

        _dimView = [[UIView alloc] initWithFrame:self.bounds];
        _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
        _dimView.alpha = 0.0;
        [self addSubview:_dimView];

        _cardView = [[UIVisualEffectView alloc] initWithEffect:nil];
        _cardView.clipsToBounds = YES;
        _cardView.layer.cornerRadius = kPanelCornerRadius;
        _cardView.layer.cornerCurve = kCACornerCurveContinuous;
        _cardView.layer.borderWidth = 1.0;
        _cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
        _cardView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [self addSubview:_cardView];

        // Liquid Glass: das Glas selbst trägt die Fläche (Seite scheint durch). Nur ein Hauch Tönung für die Lesbarkeit
        // der hellen Schrift; die Abdunkelung der Seite dahinter (dimView) übernimmt den Rest.
        _cardTintView = [UIView new];
        _cardTintView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.10];
        _cardTintView.alpha = 0.0;
        [_cardView.contentView addSubview:_cardTintView];

        _contentHostView = [UIView new];
        _contentHostView.alpha = 0.0;
        [_cardView.contentView addSubview:_contentHostView];
    }
    return self;
}

- (UIVisualEffect *)glassEffect {
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        return glass;
    }
#endif
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

#pragma mark Daten

- (NSArray<BrowserSiteEntry *> *)recentEntriesAvoiding:(NSArray<BrowserSiteEntry *> *)frequent {
    // Zuletzt besucht: möglichst Seiten, die nicht schon unter „Oft besucht“ stehen; bei wenig Verlauf auffüllen.
    NSArray<BrowserSiteEntry *> *recent = [BrowserHistoryStore.sharedStore recentEntries:12];
    NSMutableSet<NSString *> *frequentHosts = [NSMutableSet set];
    for (BrowserSiteEntry *entry in frequent) {
        [frequentHosts addObject:entry.host];
    }
    NSMutableArray<BrowserSiteEntry *> *result = [NSMutableArray array];
    for (BrowserSiteEntry *entry in recent) {
        if (result.count < kPanelTilesPerSection && ![frequentHosts containsObject:entry.host]) {
            [result addObject:entry];
        }
    }
    for (BrowserSiteEntry *entry in recent) {
        if (result.count < kPanelTilesPerSection && ![result containsObject:entry]) {
            [result addObject:entry];
        }
    }
    return result;
}

- (void)reloadData {
    for (UIView *view in self.columnViews) {
        [view removeFromSuperview];
    }
    [self.tiles removeAllObjects];

    BrowserHistoryStore *store = BrowserHistoryStore.sharedStore;
    NSArray<BrowserSiteEntry *> *favorites = store.favorites;
    if (favorites.count > kPanelTilesPerSection) {
        favorites = [favorites subarrayWithRange:NSMakeRange(0, kPanelTilesPerSection)];
    }
    NSArray<BrowserSiteEntry *> *frequent = [store topEntries:kPanelTilesPerSection];
    NSArray<BrowserSiteEntry *> *recent = [self recentEntriesAvoiding:frequent];

    NSArray *sections = @[
        @[@"Favoriten", @"star.fill", UIColor.systemYellowColor, favorites, @NO],
        @[@"Oft besucht", @"chart.bar.fill", [UIColor colorWithWhite:1.0 alpha:0.7], frequent, @YES],
        @[@"Zuletzt", @"clock.fill", [UIColor colorWithWhite:1.0 alpha:0.7], recent, @YES],
    ];
    NSMutableArray<UIView *> *columns = [NSMutableArray array];
    for (NSArray *section in sections) {
        UIView *column = [UIView new];
        UILabel *header = [UILabel new];
        header.tag = 100;
        UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]
                                                                                                scale:UIImageSymbolScaleSmall];
        UIImage *symbol = [[UIImage systemImageNamed:section[1] withConfiguration:configuration]
                           imageWithTintColor:section[2] renderingMode:UIImageRenderingModeAlwaysOriginal];
        NSMutableAttributedString *title = [NSMutableAttributedString new];
        if (symbol != nil) {
            [title appendAttributedString:[NSAttributedString attributedStringWithAttachment:[NSTextAttachment textAttachmentWithImage:symbol]]];
            [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
        }
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:section[0] attributes:@{
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.92],
        }]];
        header.font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline].pointSize weight:UIFontWeightSemibold];
        header.attributedText = title;
        [column addSubview:header];

        NSArray<BrowserSiteEntry *> *entries = section[3];
        BOOL small = [section[4] boolValue];
        for (NSUInteger i = 0; i < kPanelTilesPerSection; i++) {
            BrowserSiteEntry *entry = i < entries.count ? entries[i] : nil;
            BrowserAddressTileView *tile = [[BrowserAddressTileView alloc] initWithEntry:entry
                                                                                iconSize:small ? kPanelSmallIconSize : kPanelFavoriteIconSize
                                                                               showsName:small];
            tile.tag = (NSInteger)i;
            [column addSubview:tile];
            if (entry != nil) {
                [self.tiles addObject:tile];
            }
        }
        if (entries.count == 0) {
            UILabel *empty = [UILabel new];
            empty.tag = 101;
            empty.numberOfLines = 2;
            empty.textAlignment = NSTextAlignmentCenter;
            empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
            empty.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
            empty.text = small ? @"Noch kein Verlauf" : @"Stern in der Leiste\nmerkt eine Seite vor";
            [column addSubview:empty];
        }
        [self.contentHostView addSubview:column];
        [columns addObject:column];
    }
    // Feine Trennlinien zwischen den Spalten.
    for (NSUInteger i = 0; i < 2; i++) {
        UIView *separator = [UIView new];
        separator.tag = 200 + (NSInteger)i;
        separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        [self.contentHostView addSubview:separator];
        [columns addObject:separator];
    }
    self.columnViews = columns;
    [self setNeedsLayout];
}

- (NSUInteger)tileCount {
    return self.tiles.count;
}

#pragma mark Layout

- (CGFloat)rowHeight {
    return MAX(kPanelFavoriteIconSize, kPanelSmallIconSize + kPanelNameGap + kPanelNameHeight);
}

- (CGFloat)cardHeight {
    return kPanelTopInset + kPanelHeaderHeight + kPanelHeaderGap + 2.0 * [self rowHeight] + kPanelRowGap + kPanelBottomInset;
}

- (CGRect)cardFrameExpanded:(BOOL)expanded {
    CGRect bar = self.barFrame;
    if (!expanded && BrowserMotion.liquidGlassEnabled) {
        // Liquid Glass: Die Karte beginnt als schmale Kapsel in der unteren Hälfte der Leiste (dort verdeckt)
        // und tropft aus ihr heraus. Nur die untere Hälfte, damit nichts quer durch das klare Glas der Leiste läuft.
        CGFloat half = floor(CGRectGetHeight(bar) / 2.0);
        return CGRectMake(CGRectGetMinX(bar) + half, CGRectGetMaxY(bar) - half, CGRectGetWidth(bar) - 2.0 * half, half);
    }
    CGFloat top = CGRectGetMaxY(bar) + kPanelGapBelowBar;
    // Zusammengeklappt: flacher Streifen direkt unter der Leiste, aus dem die Karte herauswächst.
    CGFloat height = expanded ? [self cardHeight] : kPanelCornerRadius * 2.0;
    CGFloat inset = expanded ? 0.0 : 40.0;
    return CGRectMake(CGRectGetMinX(bar) + inset, expanded ? top : CGRectGetMaxY(bar) - kPanelCornerRadius,
                      CGRectGetWidth(bar) - 2.0 * inset, height);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.cardTintView.frame = self.cardView.bounds;
    CGFloat width = CGRectGetWidth(self.barFrame);
    // Inhalt mit fester Größe; die Karte schneidet ihn beim Auf- und Zuklappen ab.
    self.contentHostView.frame = CGRectMake((CGRectGetWidth(self.cardView.bounds) - width) / 2.0, 0.0, width, [self cardHeight]);

    NSUInteger columnCount = 3;
    CGFloat columnWidth = floor((width - 2.0 * kPanelSideInset) / columnCount);
    CGFloat rowHeight = [self rowHeight];
    NSUInteger columnIndex = 0;
    for (UIView *view in self.columnViews) {
        if (view.tag >= 200) {
            NSInteger separatorIndex = view.tag - 200;
            CGFloat x = kPanelSideInset + columnWidth * (separatorIndex + 1);
            view.frame = CGRectMake(x, kPanelTopInset + 6.0, 1.0, [self cardHeight] - kPanelTopInset - kPanelBottomInset - 12.0);
            continue;
        }
        view.frame = CGRectMake(kPanelSideInset + columnWidth * columnIndex, 0.0, columnWidth, [self cardHeight]);
        BOOL small = columnIndex > 0;
        CGFloat tileWidth = small ? kPanelSmallTileWidth : kPanelFavoriteIconSize;
        CGFloat gridWidth = 2.0 * tileWidth + kPanelColumnGap;
        CGFloat gridX = floor((columnWidth - gridWidth) / 2.0);
        CGFloat gridY = kPanelTopInset + kPanelHeaderHeight + kPanelHeaderGap;
        for (UIView *subview in view.subviews) {
            if ([subview isKindOfClass:BrowserAddressTileView.class]) {
                NSInteger i = subview.tag;
                CGFloat x = gridX + (i % 2) * (tileWidth + kPanelColumnGap);
                CGFloat y = gridY + (i / 2) * (rowHeight + kPanelRowGap);
                CGFloat height = small ? kPanelSmallIconSize + kPanelNameGap + kPanelNameHeight : kPanelFavoriteIconSize;
                subview.frame = CGRectMake(x, y + floor((rowHeight - height) / 2.0), tileWidth, height);
            } else if (subview.tag == 100) {
                subview.frame = CGRectMake(gridX, kPanelTopInset, columnWidth - gridX, kPanelHeaderHeight);
            } else if (subview.tag == 101) {
                subview.frame = CGRectMake(gridX, gridY, gridWidth, 2.0 * rowHeight + kPanelRowGap);
            }
        }
        columnIndex += 1;
    }
}

#pragma mark Ein- und Ausblenden

- (void)presentBelowBarFrame:(CGRect)barFrame animated:(BOOL)animated {
    self.barFrame = barFrame;
    if (self.columnViews == nil) {
        [self reloadData];
    }
    [UIView performWithoutAnimation:^{
        self.cardView.frame = [self cardFrameExpanded:NO];
        self.cardView.layer.cornerRadius = [self cardCornerRadiusExpanded:NO];
        self.cardView.alpha = 0.0;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }];
    void (^expand)(void) = ^{
        self.dimView.alpha = 1.0;
        self.cardTintView.alpha = 1.0;
        self.cardView.frame = [self cardFrameExpanded:YES];
        self.cardView.layer.cornerRadius = kPanelCornerRadius;
        [self layoutIfNeeded];
    };
    if (!animated) {
        expand();
        self.cardView.alpha = 1.0;
        self.cardView.effect = [self glassEffect];
        self.contentHostView.alpha = 1.0;
        return;
    }
    // Liquid Glass: Glas materialisiert (effect nil → Glas) und federt aus der Leiste; schlicht: Alpha und Höhe.
    [BrowserMotion glassAppear:self.cardView effect:[self glassEffect] kind:BrowserMotionKindAppear alongside:expand completion:nil];
    [BrowserMotion animateKind:BrowserMotionKindFade delay:0.12 options:0 animations:^{
        self.contentHostView.alpha = 1.0;
    } completion:nil];
}

/// Zusammengeklappt in Liquid Glass: Kapselform der Leiste, damit die Karte nahtlos aus ihr herauswächst.
- (CGFloat)cardCornerRadiusExpanded:(BOOL)expanded {
    if (!expanded && BrowserMotion.liquidGlassEnabled) {
        return floor(CGRectGetHeight(self.barFrame) / 2.0) / 2.0;
    }
    return kPanelCornerRadius;
}

- (void)dismissAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if (self.dismissing) {
        return;
    }
    self.dismissing = YES;
    void (^finish)(void) = ^{
        [self removeFromSuperview];
        if (completion != nil) {
            completion();
        }
    };
    if (!animated) {
        finish();
        return;
    }
    [BrowserMotion animateKind:BrowserMotionKindSnap delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.contentHostView.alpha = 0.0;
    } completion:nil];
    // Liquid Glass: zurück in die Leiste, Glas dematerialisiert; schlicht: ausblenden und einklappen.
    [BrowserMotion glassDisappear:self.cardView kind:BrowserMotionKindDisappear alongside:^{
        self.dimView.alpha = 0.0;
        self.cardTintView.alpha = 0.0;
        self.cardView.frame = [self cardFrameExpanded:NO];
        self.cardView.layer.cornerRadius = [self cardCornerRadiusExpanded:NO];
        [self layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        finish();
    }];
}

#pragma mark Zeiger

- (CGRect)targetRectForTile:(BrowserAddressTileView *)tile inView:(UIView *)view {
    return [tile convertRect:tile.bounds toView:view];
}

- (NSArray<NSValue *> *)pointerTargetRectsInView:(UIView *)view {
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    if (self.dismissing) {
        return rects;
    }
    for (BrowserAddressTileView *tile in self.tiles) {
        [rects addObject:[NSValue valueWithCGRect:[self targetRectForTile:tile inView:view]]];
    }
    return rects;
}

- (BrowserAddressTileView *)tileAtPoint:(CGPoint)point inView:(UIView *)view {
    for (BrowserAddressTileView *tile in self.tiles) {
        if (CGRectContainsPoint(CGRectInset([self targetRectForTile:tile inView:view], -4.0, -4.0), point)) {
            return tile;
        }
    }
    return nil;
}

- (CGFloat)cornerRadiusForTargetRect:(CGRect)rect inView:(UIView *)view {
    for (BrowserAddressTileView *tile in self.tiles) {
        CGRect tileRect = [self targetRectForTile:tile inView:view];
        if (CGRectEqualToRect(CGRectIntegral(tileRect), CGRectIntegral(rect))) {
            return tile.iconSize * kPanelIconCornerFraction;
        }
    }
    return -1.0;
}

- (NSURL *)URLForTileAtPoint:(CGPoint)point inView:(UIView *)view {
    BrowserAddressTileView *tile = [self tileAtPoint:point inView:view];
    return tile.entry.urlString.length > 0 ? [NSURL URLWithString:tile.entry.urlString] : nil;
}

- (BOOL)cardContainsPoint:(CGPoint)point inView:(UIView *)view {
    return CGRectContainsPoint([self.cardView convertRect:self.cardView.bounds toView:view], point);
}

- (BOOL)handleSelectionAtPoint:(CGPoint)point inView:(UIView *)view {
    NSURL *url = [self URLForTileAtPoint:point inView:view];
    if (url == nil) {
        return NO;
    }
    if (self.openURLHandler != nil) {
        self.openURLHandler(url);
    }
    return YES;
}

@end
