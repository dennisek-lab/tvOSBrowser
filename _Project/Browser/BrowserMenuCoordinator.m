#import "BrowserMenuCoordinator.h"
#import "BrowserHistoryStore.h"
#import "BrowserMotion.h"
#import "BrowserShape.h"
#import "BrowserPreferencesStore.h"
#import "BrowserDNSProxy.h"
#import "BrowserContentBlocker.h"
#import "BrowserFilterListUpdater.h"
#import "BrowserCookieConsentBlocker.h"
#import "BrowserSubtitleEngine.h"
#import "BrowserWebView.h"

static UIColor *MenuTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

static NSString * const kBrowserMediaDiagnosticsLogPrefix = @"[MediaDiagnostics]";
static NSString * const kBrowserWebKitMediaPrefsLogPrefix = @"[WebKitMediaPrefs]";

typedef void (^BrowserAdvancedMenuItemHandler)(void);

/// SF Symbol je Menüeintrag (nach Titel). Unbekannte Titel bekommen einen Punkt.
static NSString *BrowserMenuSymbolForTitle(NSString *title) {
    static NSDictionary<NSString *, NSString *> *symbols;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        symbols = @{
            @"Zusammenfassen": @"list.bullet.rectangle",
            @"Übersetzen": @"translate",
            @"Neu laden": @"arrow.clockwise",
            @"Seitenzoom": @"plus.magnifyingglass",
            @"Werbeblocker hier": @"hand.raised",
            @"Cookie-Banner hier ablehnen": @"checkmark.shield",
            @"Startseite öffnen": @"house",
            @"Startseite festlegen": @"house.and.flag",
            @"Favoriten": @"star",
            @"Verlauf": @"clock.arrow.circlepath",
            @"Tabs anzeigen": @"square.on.square",
            @"Neuer Tab": @"plus.square.on.square",
            @"Unbenutzte Tabs nach 30 Min. schließen": @"clock.badge.xmark",
            @"Werbeblocker": @"hand.raised.fill",
            @"Werbeblocker bei Sperre automatisch pausieren": @"pause.circle",
            @"Filterlisten aktualisieren": @"arrow.triangle.2.circlepath",
            @"Cookie-Banner ablehnen": @"checkmark.shield.fill",
            @"Bezahlschranken zustimmen": @"eurosign.circle",
            @"Native Player automatisch": @"play.rectangle",
            @"Automatische Untertitel": @"captions.bubble",
            @"Untertitelsprache": @"character.bubble",
            @"Untertitel (Webseite)": @"text.bubble",
            @"Cloudflare-DNS": @"network",
            @"Obere Leiste": @"rectangle.topthird.inset.filled",
            @"Regenbogen-Leuchten": @"sparkles",
            @"Liquid-Glass-Animationen": @"drop",
            @"Glow-Animation": @"arrow.clockwise.circle",
            @"Zeiger": @"cursorarrow",
            @"Zeigertempo": @"speedometer",
            @"Zeiger gleitet aus": @"cursorarrow.motionlines",
            @"Vollbild-Player": @"arrow.up.left.and.arrow.down.right",
            @"Seite an Breite anpassen": @"arrow.left.and.right",
            @"Browser-Kennung": @"desktopcomputer",
            @"Schrift größer": @"textformat.size.larger",
            @"Schrift kleiner": @"textformat.size.smaller",
            @"Schriftgröße zurücksetzen": @"textformat",
            @"Cache leeren": @"trash",
            @"Cookies löschen": @"xmark.bin",
            @"Bedienung": @"questionmark.circle",
            @"Was ist neu": @"gift",
            @"Einrichtung": @"wand.and.stars",
            @"Medien-Diagnose": @"waveform.path.ecg",
            @"WebKit-Medieneinstellungen": @"slider.horizontal.3",
        };
    });
    return symbols[title] ?: @"circle.fill";
}

/// Farbe der Symbolkreise je Abschnitt.
static UIColor *BrowserMenuTintForSection(NSString *title) {
    static NSDictionary<NSString *, UIColor *> *tints;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tints = @{
            @"Diese Seite": UIColor.systemBlueColor,
            @"Navigation": UIColor.systemIndigoColor,
            @"Erweiterungen": UIColor.systemGreenColor,
            @"Ansicht & Wiedergabe": UIColor.systemOrangeColor,
            @"Daten": UIColor.systemRedColor,
            @"Hilfe": UIColor.systemTealColor,
            @"Erweitert": UIColor.systemGrayColor,
        };
    });
    return tints[title] ?: UIColor.systemGrayColor;
}

// Zwei Spalten großer Schaltflächen. Kachelradius konzentrisch zum Panel (50 − 14 = 36).
// Panelbreite wie die frühere einspaltige Liste (38 % der Bildschirmbreite, 480–700 pt). Kacheln hochkant:
// Symbol oben links, Schalter oben rechts, Titel und Wert darunter.
static CGFloat const kMenuTileHeight = 150.0;
static CGFloat const kMenuTilePadding = 20.0;
static CGFloat const kMenuTileSpacing = 18.0;
static CGFloat const kMenuIconSide = 50.0;
static CGFloat const kMenuSwitchWidth = 64.0;
static CGFloat const kMenuSwitchHeight = 38.0;

@interface BrowserAdvancedMenuItem : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic) UIAlertActionStyle style;
@property (nonatomic, copy) BrowserAdvancedMenuItemHandler handler;

+ (instancetype)itemWithTitle:(NSString *)title
                        style:(UIAlertActionStyle)style
                      handler:(BrowserAdvancedMenuItemHandler)handler;

@end

@implementation BrowserAdvancedMenuItem

+ (instancetype)itemWithTitle:(NSString *)title
                        style:(UIAlertActionStyle)style
                      handler:(BrowserAdvancedMenuItemHandler)handler {
    BrowserAdvancedMenuItem *item = [BrowserAdvancedMenuItem new];
    item.title = title ?: @"";
    item.style = style;
    item.handler = handler;
    return item;
}

@end

@interface BrowserAdvancedMenuSection : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuItem *> *items;

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserAdvancedMenuItem *> *)items;

@end

@implementation BrowserAdvancedMenuSection

+ (instancetype)sectionWithTitle:(NSString *)title items:(NSArray<BrowserAdvancedMenuItem *> *)items {
    BrowserAdvancedMenuSection *section = [BrowserAdvancedMenuSection new];
    section.title = title ?: @"";
    section.items = [items copy] ?: @[];
    return section;
}

@end

/// Schaltfläche der Seitenleiste: Kachel mit farbigem Symbolkreis, Titel, darunter der Wert, rechts ggf. ein
/// Schalter. Ruhend dezente Glasfläche, im Fokus heller mit Lichtkante, angehoben und mit Schatten.
@interface BrowserAdvancedMenuTile : UICollectionViewCell
- (void)configureWithItem:(BrowserAdvancedMenuItem *)item tint:(UIColor *)tint;
@end

@implementation BrowserAdvancedMenuTile {
    UIView *_platter;
    UIView *_iconCircle;
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
    UIStackView *_texts;
    UIView *_switchTrack;
    UIView *_switchKnob;
    NSLayoutConstraint *_knobLeading;
    BOOL _destructive;
    BOOL _switchOn;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.clipsToBounds = NO;
        self.clipsToBounds = NO;
        CGFloat radius = BrowserShapeConcentricRadius(BrowserShapePanelRadius, BrowserShapePanelInset);
        CGFloat inset = kMenuTilePadding;

        _platter = [UIView new];
        _platter.translatesAutoresizingMaskIntoConstraints = NO;
        _platter.layer.borderWidth = 1.5;
        _platter.layer.shadowColor = UIColor.blackColor.CGColor;
        _platter.layer.shadowRadius = 18.0;
        _platter.layer.shadowOffset = CGSizeMake(0.0, 10.0);
        BrowserShapeApply(_platter.layer, radius);
        [self.contentView addSubview:_platter];

        _iconCircle = [UIView new];
        _iconCircle.translatesAutoresizingMaskIntoConstraints = NO;
        BrowserShapeApply(_iconCircle.layer, kMenuIconSide / 2.0);
        [self.contentView addSubview:_iconCircle];
        _iconView = [UIImageView new];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeCenter;
        _iconView.tintColor = UIColor.whiteColor;
        [_iconCircle addSubview:_iconView];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:25.0 weight:UIFontWeightSemibold];
        _titleLabel.numberOfLines = 2;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.85;
        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightRegular];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.adjustsFontSizeToFitWidth = YES;
        _detailLabel.minimumScaleFactor = 0.75;
        _texts = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _detailLabel]];
        _texts.translatesAutoresizingMaskIntoConstraints = NO;
        _texts.axis = UILayoutConstraintAxisVertical;
        _texts.spacing = 0.0;
        [self.contentView addSubview:_texts];

        _switchTrack = [UIView new];
        _switchTrack.translatesAutoresizingMaskIntoConstraints = NO;
        BrowserShapeApply(_switchTrack.layer, kMenuSwitchHeight / 2.0);
        [self.contentView addSubview:_switchTrack];
        _switchKnob = [UIView new];
        _switchKnob.translatesAutoresizingMaskIntoConstraints = NO;
        _switchKnob.backgroundColor = UIColor.whiteColor;
        BrowserShapeApply(_switchKnob.layer, (kMenuSwitchHeight - 6.0) / 2.0);
        _switchKnob.layer.shadowColor = UIColor.blackColor.CGColor;
        _switchKnob.layer.shadowOpacity = 0.2;
        _switchKnob.layer.shadowRadius = 3.0;
        _switchKnob.layer.shadowOffset = CGSizeMake(0.0, 1.0);
        [_switchTrack addSubview:_switchKnob];

        _knobLeading = [_switchKnob.leadingAnchor constraintEqualToAnchor:_switchTrack.leadingAnchor constant:3.0];
        [NSLayoutConstraint activateConstraints:@[
            [_platter.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_platter.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_platter.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_platter.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],

            [_iconCircle.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:inset],
            [_iconCircle.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:inset - 2.0],
            [_iconCircle.widthAnchor constraintEqualToConstant:kMenuIconSide],
            [_iconCircle.heightAnchor constraintEqualToConstant:kMenuIconSide],
            [_iconView.centerXAnchor constraintEqualToAnchor:_iconCircle.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:_iconCircle.centerYAnchor],

            [_texts.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:inset + 2.0],
            [_texts.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-inset],
            [_texts.topAnchor constraintEqualToAnchor:_iconCircle.bottomAnchor constant:8.0],
            [_texts.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-12.0],

            [_switchTrack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-inset],
            [_switchTrack.centerYAnchor constraintEqualToAnchor:_iconCircle.centerYAnchor],
            [_switchTrack.widthAnchor constraintEqualToConstant:kMenuSwitchWidth],
            [_switchTrack.heightAnchor constraintEqualToConstant:kMenuSwitchHeight],
            [_switchKnob.centerYAnchor constraintEqualToAnchor:_switchTrack.centerYAnchor],
            [_switchKnob.widthAnchor constraintEqualToConstant:kMenuSwitchHeight - 6.0],
            [_switchKnob.heightAnchor constraintEqualToConstant:kMenuSwitchHeight - 6.0],
            _knobLeading,
        ]];
        [self applyFocused:NO];
    }
    return self;
}

- (void)configureWithItem:(BrowserAdvancedMenuItem *)item tint:(UIColor *)tint {
    BOOL destructive = item.style == UIAlertActionStyleDestructive;
    _titleLabel.text = item.title;
    _destructive = destructive;
    _iconCircle.backgroundColor = destructive ? UIColor.systemRedColor : tint;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:23.0 weight:UIImageSymbolWeightSemibold];
    _iconView.image = [UIImage systemImageNamed:BrowserMenuSymbolForTitle(item.title) withConfiguration:config]
        ?: [UIImage systemImageNamed:@"circle.fill" withConfiguration:config];

    // „An“/„Aus“ als Schalter, sonst der Wert unter dem Titel.
    BOOL isSwitch = [item.detail isEqualToString:@"An"] || [item.detail isEqualToString:@"Aus"];
    BOOL isOn = [item.detail isEqualToString:@"An"];
    _switchTrack.hidden = !isSwitch;
    _detailLabel.text = item.detail;
    _detailLabel.hidden = isSwitch || item.detail.length == 0;
    _switchOn = isOn;
    _knobLeading.constant = isOn ? kMenuSwitchWidth - kMenuSwitchHeight + 3.0 : 3.0;
    [self applyFocused:self.isFocused];
}

- (void)applyFocused:(BOOL)focused {
    // Ruhend: eigene, klar abgegrenzte Glasfläche mit Kante. Fokus wie in tvOS üblich: helle Fläche,
    // dunkle Schrift, angehoben mit Schatten – so ist die gewählte Kachel sofort zu erkennen.
    _platter.backgroundColor = focused ? [UIColor colorWithWhite:0.96 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:0.13];
    _platter.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:focused ? 0.0 : 0.16].CGColor;
    _platter.layer.shadowOpacity = focused ? 0.45 : 0.0;
    _titleLabel.textColor = _destructive ? UIColor.systemRedColor
        : (focused ? [UIColor colorWithWhite:0.08 alpha:1.0] : UIColor.whiteColor);
    _switchTrack.backgroundColor = _switchOn ? UIColor.systemGreenColor
        : (focused ? [UIColor colorWithWhite:0.0 alpha:0.16] : [UIColor colorWithWhite:1.0 alpha:0.22]);
    _detailLabel.textColor = focused ? [UIColor colorWithWhite:0.08 alpha:0.6] : [UIColor colorWithWhite:1.0 alpha:0.6];
    self.contentView.transform = focused ? CGAffineTransformMakeScale(1.05, 1.05) : CGAffineTransformIdentity;
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    BOOL focused = self.isFocused;
    [coordinator addCoordinatedAnimations:^{
        [BrowserMotion animateKind:BrowserMotionKindSnap delay:0.0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            [self applyFocused:focused];
        } completion:nil];
    } completion:nil];
}

@end

/// Abschnittsüberschrift über beide Spalten.
@interface BrowserAdvancedMenuHeader : UICollectionReusableView
@property (nonatomic, readonly) UILabel *label;
@end

@implementation BrowserAdvancedMenuHeader
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _label = [UILabel new];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];
        _label.textColor = UIColor.secondaryLabelColor;
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:BrowserShapePanelInset + 24.0],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24.0],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10.0],
        ]];
    }
    return self;
}
@end

@interface BrowserAdvancedMenuViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>

- (instancetype)initWithTitle:(NSString *)title
                     sections:(NSArray<BrowserAdvancedMenuSection *> *)sections
                   footerText:(NSString *)footerText;

@end

@interface BrowserAdvancedMenuViewController ()

@property (nonatomic, copy) NSString *menuTitle;
@property (nonatomic, copy) NSArray<BrowserAdvancedMenuSection *> *sections;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic) UIView *dimView;
@property (nonatomic) UIVisualEffectView *panelView;
@property (nonatomic) UICollectionView *collectionView;
@property (nonatomic) NSLayoutConstraint *panelTrailingConstraint;
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) BOOL didAnimateIn;
@property (nonatomic) BOOL dismissalInProgress;
@property (nonatomic) BOOL usingNativeGlassEffect;

@end

@implementation BrowserAdvancedMenuViewController

- (UIVisualEffect *)panelEffect {
    Class glassEffectClass = BrowserMotion.glassMaterialAvailable ? NSClassFromString(@"UIGlassEffect") : Nil;
    if (glassEffectClass != Nil) {
        id effect = [[glassEffectClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) {
            return (UIVisualEffect *)effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

- (instancetype)initWithTitle:(NSString *)title
                     sections:(NSArray<BrowserAdvancedMenuSection *> *)sections
                   footerText:(NSString *)footerText {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _menuTitle = [title copy] ?: @"Menu";
        _sections = [sections copy] ?: @[];
        _footerText = [footerText copy] ?: @"";
        self.modalPresentationStyle = UIModalPresentationOverCurrentContext;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.panelWidth = MIN(MAX(CGRectGetWidth(UIScreen.mainScreen.bounds) * 0.38, 480.0), 700.0);
    self.usingNativeGlassEffect = BrowserMotion.glassMaterialAvailable;

    UIView *dimView = [UIView new];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:self.usingNativeGlassEffect ? 0.25 : 0.45];
    dimView.alpha = 0.0;
    [self.view addSubview:dimView];
    self.dimView = dimView;

    UIVisualEffectView *panelView = [[UIVisualEffectView alloc] initWithEffect:[self panelEffect]];
    panelView.translatesAutoresizingMaskIntoConstraints = NO;
    panelView.backgroundColor = UIColor.clearColor;
    BrowserShapeApply(panelView.layer, BrowserShapePanelRadius);
    panelView.layer.masksToBounds = YES;
    panelView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self.view addSubview:panelView];
    self.panelView = panelView;

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = self.menuTitle;
    titleLabel.font = [UIFont systemFontOfSize:38.0 weight:UIFontWeightBold];
    titleLabel.textColor = UIColor.labelColor;
    [panelView.contentView addSubview:titleLabel];

    UILabel *footerLabel = [UILabel new];
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    footerLabel.text = self.footerText;
    footerLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightRegular];
    footerLabel.textColor = UIColor.tertiaryLabelColor;
    [panelView.contentView addSubview:footerLabel];

    CGFloat contentWidth = self.panelWidth - 2.0 * BrowserShapePanelInset;
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = kMenuTileSpacing;
    layout.minimumLineSpacing = kMenuTileSpacing;
    layout.itemSize = CGSizeMake(floor((contentWidth - kMenuTileSpacing) / 2.0), kMenuTileHeight);
    layout.headerReferenceSize = CGSizeMake(contentWidth, 64.0);
    layout.sectionInset = UIEdgeInsetsMake(0.0, BrowserShapePanelInset, 6.0, BrowserShapePanelInset);

    UICollectionView *collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    collectionView.backgroundColor = UIColor.clearColor;
    collectionView.dataSource = self;
    collectionView.delegate = self;
    // Beschnitten, damit gescrollte Kacheln nicht über den Titel laufen; die Ränder (Abschnittsabstand
    // seitlich, Inset oben) lassen der vergrößerten Fokus-Kachel Platz.
    collectionView.clipsToBounds = YES;
    collectionView.remembersLastFocusedIndexPath = YES;
    collectionView.showsVerticalScrollIndicator = NO;
    collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    collectionView.contentInset = UIEdgeInsetsMake(8.0, 0.0, 24.0, 0.0);
    [collectionView registerClass:BrowserAdvancedMenuTile.class forCellWithReuseIdentifier:@"tile"];
    [collectionView registerClass:BrowserAdvancedMenuHeader.class
       forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"header"];
    [panelView.contentView addSubview:collectionView];
    self.collectionView = collectionView;

    self.panelTrailingConstraint = [panelView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                                                             constant:self.panelWidth + 32.0];
    [NSLayoutConstraint activateConstraints:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.widthAnchor constraintEqualToConstant:self.panelWidth],
        [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16.0],
        [panelView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16.0],
        self.panelTrailingConstraint,

        [titleLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:BrowserShapePanelInset + 24.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panelView.topAnchor constant:30.0],
        [footerLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-(BrowserShapePanelInset + 28.0)],
        [footerLabel.lastBaselineAnchor constraintEqualToAnchor:titleLabel.lastBaselineAnchor],

        [collectionView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:0.0],
        [collectionView.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor],
        [collectionView.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor],
        [collectionView.bottomAnchor constraintEqualToAnchor:panelView.bottomAnchor],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didAnimateIn) {
        return;
    }
    self.didAnimateIn = YES;
    self.panelTrailingConstraint.constant = -16.0;
    // Liquid Glass: Glas materialisiert beim Hereinfedern; schlicht: einblenden und gleiten (BrowserMotion).
    [BrowserMotion glassAppear:self.panelView effect:self.panelView.effect kind:BrowserMotionKindAppear alongside:^{
        self.dimView.alpha = 1.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (!self.isBeingDismissed || self.dismissalInProgress) {
        return;
    }

    self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (coordinator != nil) {
        [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            self.dimView.alpha = 0.0;
            [self.view layoutIfNeeded];
        } completion:nil];
        return;
    }

    [BrowserMotion animateKind:BrowserMotionKindDisappear delay:0.0 options:0 animations:^{
        self.dimView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)dismissMenuWithCompletion:(void (^)(void))completion {
    if (self.dismissalInProgress) {
        return;
    }
    self.dismissalInProgress = YES;
    self.panelTrailingConstraint.constant = self.panelWidth + 32.0;
    [BrowserMotion glassDisappear:self.panelView kind:BrowserMotionKindDisappear alongside:^{
        self.dimView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:completion];
    }];
}

- (NSInteger)numberOfSectionsInCollectionView:(__unused UICollectionView *)collectionView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)collectionView:(__unused UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return 0;
    }
    return (NSInteger)self.sections[(NSUInteger)section].items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BrowserAdvancedMenuTile *tile = [collectionView dequeueReusableCellWithReuseIdentifier:@"tile" forIndexPath:indexPath];
    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    [tile configureWithItem:section.items[(NSUInteger)indexPath.item] tint:BrowserMenuTintForSection(section.title)];
    return tile;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    BrowserAdvancedMenuHeader *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"header" forIndexPath:indexPath];
    header.label.text = [self.sections[(NSUInteger)indexPath.section].title uppercaseString];
    return header;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
referenceSizeForHeaderInSection:(NSInteger)section {
    return CGSizeMake(CGRectGetWidth(collectionView.bounds), section == 0 ? 52.0 : 72.0);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.item];
    BrowserAdvancedMenuItemHandler handler = item.handler;
    [self dismissMenuWithCompletion:^{
        if (handler != nil) {
            handler();
        }
    }];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.collectionView];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && press.type == UIPressTypeMenu) {
        [self dismissMenuWithCompletion:nil];
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

@end

@interface BrowserMenuCoordinator ()

@property (nonatomic, weak) id<BrowserMenuCoordinatorHost> host;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;

@end

@implementation BrowserMenuCoordinator

- (instancetype)initWithHost:(id<BrowserMenuCoordinatorHost>)host
            preferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _host = host;
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
    }
    return self;
}

- (void)showAdvancedMenu {
    BrowserAdvancedMenuViewController *menuViewController = [[BrowserAdvancedMenuViewController alloc] initWithTitle:@"tvOS Browser"
                                                                                                            sections:[self advancedMenuSections]
                                                                                                          footerText:[self advancedMenuFooterText]];
    [self.host browserPresentViewController:menuViewController];
}

- (UIAlertController *)browserAlertControllerWithTitle:(NSString *)title message:(NSString *)message {
    return [UIAlertController alertControllerWithTitle:title
                                               message:message
                                        preferredStyle:UIAlertControllerStyleAlert];
}

- (UIAlertAction *)browserActionWithTitle:(NSString *)title
                                    style:(UIAlertActionStyle)style
                                  handler:(void (^ __nullable)(UIAlertAction *action))handler {
    return [UIAlertAction actionWithTitle:title style:style handler:handler];
}

- (BrowserAdvancedMenuItem *)advancedMenuItemWithTitle:(NSString *)title
                                                  style:(UIAlertActionStyle)style
                                                handler:(BrowserAdvancedMenuItemHandler)handler {
    return [BrowserAdvancedMenuItem itemWithTitle:title style:style handler:handler];
}

- (BrowserAdvancedMenuItem *)advancedMenuItemWithTitle:(NSString *)title
                                                 detail:(NSString *)detail
                                                handler:(BrowserAdvancedMenuItemHandler)handler {
    BrowserAdvancedMenuItem *item = [BrowserAdvancedMenuItem itemWithTitle:title style:UIAlertActionStyleDefault handler:handler];
    item.detail = detail ?: @"";
    return item;
}

- (UIAlertAction *)browserCancelAction {
    return [self browserActionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil];
}

- (BOOL)stringHasVisibleContent:(NSString *)string {
    NSString *trimmedString = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmedString.length > 0;
}

- (NSString *)displayTitleForStoredTitle:(NSString *)storedTitle
                               URLString:(NSString *)URLString
                              includeURL:(BOOL)includeURL {
    NSString *displayTitle = [self stringHasVisibleContent:storedTitle] ? storedTitle : URLString;
    if (includeURL && [self stringHasVisibleContent:storedTitle] && [self stringHasVisibleContent:URLString]) {
        return [NSString stringWithFormat:@"%@ - %@", storedTitle, URLString];
    }
    return displayTitle ?: @"";
}

- (void)loadStoredURLString:(NSString *)URLString {
    if (![self stringHasVisibleContent:URLString]) {
        return;
    }
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    NSString *userAgent = self.preferencesStore.userAgent;
    if (userAgent.length > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
    [[self.host browserWebView] loadRequest:request];
}

- (void)saveFavoritesArray:(NSArray *)favorites {
    [[NSUserDefaults standardUserDefaults] setObject:favorites forKey:@"FAVORITES"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)presentDeleteFavoriteMenu {
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Favorit löschen"
                                                                       message:@"Welchen Favoriten möchtest du löschen?"];
    __weak typeof(self) weakSelf = self;
    
    [favorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        if (![weakSelf stringHasVisibleContent:URLString]) {
            return;
        }
        
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:NO];
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            NSMutableArray *updatedFavorites = [favorites mutableCopy];
            [updatedFavorites removeObjectAtIndex:index];
            [weakSelf saveFavoritesArray:updatedFavorites];
        }]];
    }];
    
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentAddFavoritePrompt {
    NSString *pageTitle = [[self.host browserWebView] title];
    NSURLRequest *request = [[self.host browserWebView] request];
    NSString *currentURL = request.URL.absoluteString ?: @"";
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Favorit benennen"
                                                                       message:currentURL];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alertController;  // Aktion im Dialog: schwach, sonst Zyklus
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeDefault;
        textField.placeholder = @"Name des Favoriten";
        textField.text = pageTitle;
        textField.textColor = MenuTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];
    
    [alertController addAction:[self browserActionWithTitle:@"Sichern"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
        UITextField *titleTextField = weakAlert.textFields.firstObject;
        NSString *savedTitle = titleTextField.text;
        if (![weakSelf stringHasVisibleContent:savedTitle]) {
            savedTitle = currentURL;
        }
        
        NSArray *favoriteEntry = @[currentURL, savedTitle ?: @""];
        NSMutableArray *favorites = [[[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"] mutableCopy];
        if (favorites == nil) {
            favorites = [NSMutableArray array];
        }
        [favorites addObject:favoriteEntry];
        [weakSelf saveFavoritesArray:favorites];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentFavoritesMenu {
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Favoriten" message:@""];
    __weak typeof(self) weakSelf = self;
    
    [favorites enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:NO];
        if (![weakSelf stringHasVisibleContent:displayTitle]) {
            return;
        }
        
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }];
    
    if (favorites.count > 0) {
        [alertController addAction:[self browserActionWithTitle:@"Favorit löschen"
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentDeleteFavoriteMenu];
        }]];
    }
    
    [alertController addAction:[self browserActionWithTitle:@"Diese Seite zu Favoriten hinzufügen"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf presentAddFavoritePrompt];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentHistoryMenu {
    NSArray *historyEntries = [[NSUserDefaults standardUserDefaults] arrayForKey:@"HISTORY"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Verlauf" message:@""];
    __weak typeof(self) weakSelf = self;
    
    if (historyEntries.count > 0) {
        [alertController addAction:[self browserActionWithTitle:@"Verlauf löschen"
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"HISTORY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }]];
    }
    
    [historyEntries enumerateObjectsUsingBlock:^(NSArray *entry, NSUInteger index, BOOL *stop) {
        NSString *URLString = entry.count > 0 ? entry[0] : @"";
        NSString *title = entry.count > 1 ? entry[1] : @"";
        NSString *displayTitle = [weakSelf displayTitleForStoredTitle:title URLString:URLString includeURL:YES];
        if (![weakSelf stringHasVisibleContent:displayTitle]) {
            return;
        }
        
        [alertController addAction:[weakSelf browserActionWithTitle:displayTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            [weakSelf loadStoredURLString:URLString];
        }]];
    }];
    
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)applyUserAgent:(NSString *)userAgent mobileMode:(BOOL)mobileMode {
    self.preferencesStore.userAgent = userAgent;
    self.preferencesStore.mobileModeEnabled = mobileMode;
    
    NSURLRequest *request = [[self.host browserWebView] request];
    if (request != nil && [self stringHasVisibleContent:request.URL.absoluteString]) {
        [self.host browserCaptureSnapshotForCurrentTab];
    }
    
    __weak typeof(self) weakSelf = self;
    [BrowserWebView resetWebsiteDataWithCompletion:^{
        [weakSelf.host browserRecreateActiveWebViewPreservingCurrentURL];
        [weakSelf.host browserBringCursorToFront];
    }];
}

- (void)setPageScalingEnabled:(BOOL)enabled {
    self.preferencesStore.scalePagesToFit = enabled;
    [[self.host browserWebView] setScalesPageToFit:enabled];
    if (enabled) {
        [[self.host browserWebView] setContentMode:UIViewContentModeScaleAspectFit];
    }
    [[self.host browserWebView] reload];
}

- (void)clearCacheAndReload {
    __weak typeof(self) weakSelf = self;
    [BrowserWebView clearCachedDataWithCompletion:^{
        weakSelf.host.browserPreviousURL = @"";
        [[weakSelf.host browserWebView] reload];
    }];
}

- (void)clearCookiesAndReload {
    __weak typeof(self) weakSelf = self;
    [BrowserWebView clearCookiesWithCompletion:^{
        weakSelf.host.browserPreviousURL = @"";
        [[weakSelf.host browserWebView] reload];
    }];
}

- (NSString *)mediaDiagnosticsJavaScript {
    return @"(function(){"
            "function canPlay(type){"
                "try {"
                    "var video=document.createElement('video');"
                    "if (!video || typeof video.canPlayType!=='function') { return 'n/a'; }"
                    "var value=video.canPlayType(type);"
                    "return value ? String(value) : '';"
                "} catch (error) { return 'error'; }"
            "}"
            "function mse(type){"
                "try {"
                    "if (typeof MediaSource==='undefined' || typeof MediaSource.isTypeSupported!=='function') { return 'n/a'; }"
                    "return MediaSource.isTypeSupported(type) ? 'yes' : 'no';"
                "} catch (error) { return 'error'; }"
            "}"
            "function probeGlobal(name){"
                "try {"
                    "var value=window[name];"
                    "if (typeof value==='undefined') { return 'undefined'; }"
                    "if (value === null) { return 'null'; }"
                    "return typeof value;"
                "} catch (error) { return 'error'; }"
            "}"
            "var video=document.querySelector('video');"
            "var result={"
                "href:(window.location && window.location.href) ? String(window.location.href) : '',"
                "title:(document && document.title) ? String(document.title) : '',"
                "userAgent:(navigator && navigator.userAgent) ? String(navigator.userAgent) : '',"
                "platform:(navigator && navigator.platform) ? String(navigator.platform) : '',"
                "mediaSource:(typeof MediaSource!=='undefined') ? 'yes' : 'no',"
                "managedMediaSource:(typeof ManagedMediaSource!=='undefined') ? 'yes' : 'no',"
                "mediaCapabilities:(typeof navigator.mediaCapabilities!=='undefined') ? 'yes' : 'no',"
                "videoElement:video ? 'yes' : 'no',"
                "videoSrc:video ? String(video.currentSrc||video.src||'') : '',"
                "globalMediaSource:probeGlobal('MediaSource'),"
                "globalManagedMediaSource:probeGlobal('ManagedMediaSource'),"
                "globalWebKitMediaSource:probeGlobal('WebKitMediaSource'),"
                "globalSourceBuffer:probeGlobal('SourceBuffer'),"
                "globalManagedSourceBuffer:probeGlobal('ManagedSourceBuffer'),"
                "globalWebKitSourceBuffer:probeGlobal('WebKitSourceBuffer'),"
                "hls:canPlay('application/vnd.apple.mpegurl'),"
                "mp4H264:canPlay('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"'),"
                "mp4Hevc:canPlay('video/mp4; codecs=\"hvc1.1.6.L93.B0, mp4a.40.2\"'),"
                "webmVp9:canPlay('video/webm; codecs=\"vp9\"'),"
                "mp4Av1:canPlay('video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"'),"
                "webmAv1:canPlay('video/webm; codecs=\"av01.0.05M.08\"'),"
                "mseMp4H264:mse('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"'),"
                "mseWebmVp9:mse('video/webm; codecs=\"vp9\"'),"
                "mseMp4Av1:mse('video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"'),"
                "mseWebmAv1:mse('video/webm; codecs=\"av01.0.05M.08\"')"
            "};"
            "return JSON.stringify(result);"
           "})()";
}

- (NSDictionary *)mediaDiagnosticsDictionary {
    NSString *resultString = [[self.host browserWebView] stringByEvaluatingJavaScriptFromString:[self mediaDiagnosticsJavaScript]];
    if (![self stringHasVisibleContent:resultString]) {
        return nil;
    }

    NSData *resultData = [resultString dataUsingEncoding:NSUTF8StringEncoding];
    if (resultData == nil) {
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:resultData options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return object;
}

- (NSString *)stringValueForDiagnosticsKey:(NSString *)key dictionary:(NSDictionary *)dictionary fallback:(NSString *)fallback {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSString class]] && [self stringHasVisibleContent:value]) {
        return value;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *stringValue = [value stringValue];
        if ([self stringHasVisibleContent:stringValue]) {
            return stringValue;
        }
    }
    return fallback;
}

- (void)presentMediaDiagnostics {
    NSDictionary *diagnostics = [self mediaDiagnosticsDictionary];
    if (diagnostics == nil) {
        UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Medien-Diagnose"
                                                                           message:@"Die Seite hat keine Diagnosedaten geliefert."];
        [alertController addAction:[self browserCancelAction]];
        [self.host browserPresentViewController:alertController];
        return;
    }

    BOOL mobileModeEnabled = self.preferencesStore.mobileModeEnabled;
    NSString *message = [NSString stringWithFormat:
                         @"Mode: %@\n"
                          "URL: %@\n"
                          "UA: %@\n\n"
                          "MediaSource: %@\n"
                          "ManagedMediaSource: %@\n"
                          "MediaCapabilities: %@\n"
                          "Video Element: %@\n"
                          "Video Src: %@\n\n"
                          "Global MediaSource: %@\n"
                          "Global ManagedMediaSource: %@\n"
                          "Global WebKitMediaSource: %@\n"
                          "Global SourceBuffer: %@\n"
                          "Global ManagedSourceBuffer: %@\n"
                          "Global WebKitSourceBuffer: %@\n\n"
                          "canPlay HLS: %@\n"
                          "canPlay MP4 H.264: %@\n"
                          "canPlay MP4 HEVC: %@\n"
                          "canPlay WebM VP9: %@\n"
                          "canPlay MP4 AV1: %@\n"
                          "canPlay WebM AV1: %@\n\n"
                          "MSE MP4 H.264: %@\n"
                          "MSE WebM VP9: %@\n"
                          "MSE MP4 AV1: %@\n"
                          "MSE WebM AV1: %@",
                         mobileModeEnabled ? @"Mobile" : @"Desktop",
                         [self stringValueForDiagnosticsKey:@"href" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"userAgent" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"mediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"managedMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mediaCapabilities" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"videoElement" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"videoSrc" dictionary:diagnostics fallback:@"Unavailable"],
                         [self stringValueForDiagnosticsKey:@"globalMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalManagedMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalWebKitMediaSource" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalManagedSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"globalWebKitSourceBuffer" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"hls" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4H264" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4Hevc" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"webmVp9" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mp4Av1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"webmAv1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseMp4H264" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseWebmVp9" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseMp4Av1" dictionary:diagnostics fallback:@"n/a"],
                         [self stringValueForDiagnosticsKey:@"mseWebmAv1" dictionary:diagnostics fallback:@"n/a"]];

    NSLog(@"%@ %@", kBrowserMediaDiagnosticsLogPrefix, message);

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Medien-Diagnose"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentWebKitRuntimeMediaPreferences {
    NSString *report = [[self.host browserWebView] runtimeMediaPreferenceReport];
    if (![self stringHasVisibleContent:report]) {
        report = @"Es wurden keine WebKit-Medieneinstellungen geliefert.";
    }

    NSLog(@"%@ %@", kBrowserWebKitMediaPrefsLogPrefix, report);

    NSString *message = report;
    if (message.length > 1800) {
        message = [[message substringToIndex:1800] stringByAppendingString:@"\n\nDer vollständige Bericht steht in der Konsole."];
    }

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"WebKit-Medieneinstellungen"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (BrowserAdvancedMenuItem *)topNavigationVisibilityMenuItem {
    return [self advancedMenuItemWithTitle:@"Obere Leiste"
                                    detail:self.host.browserTopMenuShowing ? @"An" : @"Aus"
                                   handler:^{
        if (self.host.browserTopMenuShowing) {
            UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Obere Leiste ausblenden?"
                                                                               message:@"Das Menü öffnest du weiterhin mit doppeltem Druck auf Play/Pause."];
            [alertController addAction:[self browserActionWithTitle:@"Abbrechen"
                                                              style:UIAlertActionStyleCancel
                                                            handler:nil]];
            [alertController addAction:[self browserActionWithTitle:@"Ausblenden"
                                                              style:UIAlertActionStyleDestructive
                                                            handler:^(__unused UIAlertAction *action) {
                [self.host browserHideTopNav];
            }]];
            [self.host browserPresentViewController:alertController];
        } else {
            [self.host browserShowTopNav];
        }
    }];
}

- (BrowserAdvancedMenuItem *)homePageMenuItem {
    return [self advancedMenuItemWithTitle:@"Startseite öffnen"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserLoadHomePage];
    }];
}

/// „Zusammenfassen“ und „Übersetzen“ (BrowserIntelligenceController); nach dem Schließen des Menüs ausgeführt.
- (NSArray<BrowserAdvancedMenuItem *> *)intelligenceMenuItems {
    NSMutableArray<BrowserAdvancedMenuItem *> *items = [NSMutableArray array];
    if ([self.host respondsToSelector:@selector(browserSummarizePage)]) {
        [items addObject:[self advancedMenuItemWithTitle:@"Zusammenfassen" detail:nil handler:^{
            [self.host browserSummarizePage];
        }]];
    }
    if ([self.host respondsToSelector:@selector(browserTranslatePage)]) {
        [items addObject:[self advancedMenuItemWithTitle:@"Übersetzen" detail:@"Google" handler:^{
            [self.host browserTranslatePage];
        }]];
    }
    return items;
}

/// Startseite festlegen: Auswahl aus Google, Favoriten, aktueller Seite oder eingetippter Adresse.
/// Der Wert rechts zeigt die aktuelle Startseite (Name des Favoriten, sonst die Domain).
- (BrowserAdvancedMenuItem *)homePageSettingMenuItem {
    return [self advancedMenuItemWithTitle:@"Startseite festlegen"
                                    detail:[self homePageDisplayName]
                                   handler:^{
        [self presentHomePageChooser];
    }];
}

/// Favoriten für die Startseiten-Auswahl: zuerst die mit dem Stern gesetzten (BrowserHistoryStore), dann die
/// aus dem Menü „Favoriten“ (FAVORITES), ohne doppelte Adressen. Je Eintrag @[Adresse, Name].
- (NSArray<NSArray<NSString *> *> *)homePageFavoriteCandidates {
    NSMutableArray<NSArray<NSString *> *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (BrowserSiteEntry *entry in BrowserHistoryStore.sharedStore.favorites) {
        if (entry.urlString.length > 0 && ![seen containsObject:entry.urlString]) {
            [seen addObject:entry.urlString];
            [result addObject:@[entry.urlString, entry.name.length > 0 ? entry.name : (entry.host ?: entry.urlString)]];
        }
    }
    for (NSArray *entry in [[NSUserDefaults standardUserDefaults] arrayForKey:@"FAVORITES"]) {
        if (![entry isKindOfClass:NSArray.class] || entry.count == 0 || ![entry[0] isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *URLString = entry[0];
        NSString *title = entry.count > 1 && [entry[1] isKindOfClass:NSString.class] ? entry[1] : @"";
        NSString *displayTitle = [self displayTitleForStoredTitle:title URLString:URLString includeURL:NO];
        if (URLString.length > 0 && ![seen containsObject:URLString] && [self stringHasVisibleContent:displayTitle]) {
            [seen addObject:URLString];
            [result addObject:@[URLString, displayTitle]];
        }
    }
    return result;
}

- (NSString *)homePageDisplayName {
    NSString *current = self.preferencesStore.homePageURLString;
    if (![self stringHasVisibleContent:current]) {
        return @"Google";
    }
    for (NSArray<NSString *> *candidate in [self homePageFavoriteCandidates]) {
        if ([candidate[0] isEqualToString:current]) {
            return candidate[1];
        }
    }
    NSString *host = [NSURL URLWithString:current].host ?: current;
    return [host hasPrefix:@"www."] ? [host substringFromIndex:4] : host;
}

- (void)setHomePageURLStringAndRefresh:(NSString *)URLString {
    self.preferencesStore.homePageURLString = URLString ?: @"";
}

- (void)presentHomePageChooser {
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Startseite"
                                                                       message:[NSString stringWithFormat:@"Aktuell: %@", [self homePageDisplayName]]];
    __weak typeof(self) weakSelf = self;

    [alertController addAction:[self browserActionWithTitle:@"Google"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf setHomePageURLStringAndRefresh:@""];
    }]];

    for (NSArray<NSString *> *candidate in [self homePageFavoriteCandidates]) {
        NSString *URLString = candidate[0];
        [alertController addAction:[self browserActionWithTitle:candidate[1]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf setHomePageURLStringAndRefresh:URLString];
        }]];
    }

    NSString *currentURL = [[self.host browserWebView] request].URL.absoluteString;
    if ([self stringHasVisibleContent:currentURL] && [currentURL hasPrefix:@"http"]) {
        NSString *host = [NSURL URLWithString:currentURL].host ?: currentURL;
        [alertController addAction:[self browserActionWithTitle:[NSString stringWithFormat:@"Diese Seite (%@)", host]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf setHomePageURLStringAndRefresh:currentURL];
        }]];
    }

    [alertController addAction:[self browserActionWithTitle:@"Adresse eingeben …"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf presentHomePageAddressPrompt];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentHomePageAddressPrompt {
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Startseite" message:@"Adresse der Startseite"];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alertController;  // Aktion im Dialog: schwach, sonst Zyklus
    NSString *current = self.preferencesStore.homePageURLString;
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeURL;
        textField.placeholder = @"z. B. google.com";
        textField.text = current;
        textField.textColor = MenuTextColor();
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        [textField setReturnKeyType:UIReturnKeyDone];
    }];
    [alertController addAction:[self browserActionWithTitle:@"Sichern"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        NSString *text = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length == 0) {
            [weakSelf setHomePageURLStringAndRefresh:@""];
            return;
        }
        if ([text rangeOfString:@"://"].location == NSNotFound) {
            text = [@"https://" stringByAppendingString:text];
        }
        if ([NSURL URLWithString:text].host.length > 0) {
            [weakSelf setHomePageURLStringAndRefresh:text];
        }
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (BrowserAdvancedMenuItem *)usageGuideMenuItem {
    return [self advancedMenuItemWithTitle:@"Bedienung"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowHints];
    }];
}

- (BrowserAdvancedMenuItem *)setupMenuItem {
    return [self advancedMenuItemWithTitle:@"Einrichtung"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowSetup];
    }];
}

- (BrowserAdvancedMenuItem *)whatsNewMenuItem {
    return [self advancedMenuItemWithTitle:@"Was ist neu"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowWhatsNew];
    }];
}

- (UIAlertAction *)wkWebViewProofOfConceptAction {
    return [self browserActionWithTitle:@"WKWebView-Test öffnen"
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction *action) {
        Class proofOfConceptControllerClass = NSClassFromString(@"BrowserWKWebViewProofOfConceptViewController");
        UIViewController *viewController = nil;
        if (proofOfConceptControllerClass != Nil) {
            viewController = [proofOfConceptControllerClass new];
            viewController.modalPresentationStyle = UIModalPresentationFullScreen;
        } else {
            viewController = [UIAlertController alertControllerWithTitle:@"WKWebView-Test fehlt"
                                                                 message:@"Der Test-Controller ist in diesem Build nicht enthalten."
                                                          preferredStyle:UIAlertControllerStyleAlert];
            [(UIAlertController *)viewController addAction:[self browserCancelAction]];
        }
        [self.host browserPresentViewController:viewController];
    }];
}

- (BrowserAdvancedMenuItem *)showTabsMenuItem {
    return [self advancedMenuItemWithTitle:@"Tabs anzeigen"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowTabOverview];
    }];
}

- (BrowserAdvancedMenuItem *)newTabMenuItem {
    return [self advancedMenuItemWithTitle:@"Neuer Tab"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserCreateNewTabLoadingHomePage:YES];
    }];
}

/// Pop-ups und im Hintergrund geöffnete Links, die der Nutzer nie angesehen hat, schließen sich nach 30 Minuten.
- (BrowserAdvancedMenuItem *)closeUnusedTabsMenuItem {
    BOOL enabled = self.preferencesStore.closeUnusedTabsEnabled;
    return [self advancedMenuItemWithTitle:@"Unbenutzte Tabs nach 30 Min. schließen"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.closeUnusedTabsEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)favoritesMenuItem {
    return [self advancedMenuItemWithTitle:@"Favoriten"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentFavoritesMenu];
    }];
}

- (BrowserAdvancedMenuItem *)historyMenuItem {
    return [self advancedMenuItemWithTitle:@"Verlauf"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self presentHistoryMenu];
    }];
}

- (BrowserAdvancedMenuItem *)userAgentModeMenuItem {
    BOOL mobileModeEnabled = self.preferencesStore.mobileModeEnabled;
    NSString *detail = mobileModeEnabled ? @"Mobil" : @"Desktop";
    NSString *userAgent = mobileModeEnabled ? BrowserPreferencesStore.desktopUserAgent : BrowserPreferencesStore.mobileUserAgent;
    BOOL mobileMode = !mobileModeEnabled;
    
    return [self advancedMenuItemWithTitle:@"Browser-Kennung"
                                    detail:detail
                                   handler:^{
        [self applyUserAgent:userAgent mobileMode:mobileMode];
    }];
}

- (BrowserAdvancedMenuItem *)cloudflareDNSMenuItem {
    BOOL enabled = BrowserDNSProxy.isEnabled;
    return [self advancedMenuItemWithTitle:@"Cloudflare-DNS"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        BrowserDNSProxy.enabled = !enabled;
        BrowserDNSProxy *proxy = [BrowserDNSProxy sharedProxy];
        [proxy startAndWaitWithTimeout:1.0];
        [proxy applyToWebsiteDataStore:[BrowserWebView defaultWebsiteDataStore]];
        [[self.host browserWebView] reload];
    }];
}

- (BrowserAdvancedMenuItem *)adBlockMenuItem {
    BOOL enabled = self.preferencesStore.adBlockEnabled;
    return [self advancedMenuItemWithTitle:@"Werbeblocker"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.adBlockEnabled = !enabled;
        [[BrowserContentBlocker sharedBlocker] preferencesDidChange];
        [[self.host browserWebView] reload];
    }];
}

/// Erkennt Adblock-Sperren („Bitte Werbeblocker deaktivieren“) und pausiert den Werbeblocker dann für diese Seite.
- (BrowserAdvancedMenuItem *)adBlockAutoPauseMenuItem {
    BOOL enabled = self.preferencesStore.adBlockAutoPauseOnWall;
    return [self advancedMenuItemWithTitle:@"Werbeblocker bei Sperre automatisch pausieren"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.adBlockAutoPauseOnWall = !enabled;
        [[BrowserContentBlocker sharedBlocker] preferencesDidChange];
    }];
}

/// Zeigt den Stand der Werbeblocker-Listen und prüft auf Wunsch sofort auf neue (BrowserFilterListUpdater).
- (BrowserAdvancedMenuItem *)filterListUpdateMenuItem {
    BrowserFilterListUpdater *updater = [BrowserFilterListUpdater sharedUpdater];
    NSString *detail = updater.isChecking ? @"Prüft …"
        : [@"Stand " stringByAppendingString:[BrowserFilterListUpdater displayStringForDate:updater.activeListsDate]];
    return [self advancedMenuItemWithTitle:@"Filterlisten aktualisieren"
                                    detail:detail
                                   handler:^{
        [updater checkNowWithCompletion:^(BOOL updated, NSString *message) {
            UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Filterlisten" message:message];
            [alertController addAction:[self browserActionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self.host browserPresentViewController:alertController];
            if (updated) {
                [[self.host browserWebView] reload];
            }
        }];
    }];
}

/// Schaltet den Werbeblocker für den Host der aktuellen Seite aus bzw. wieder ein.
- (BrowserAdvancedMenuItem *)adBlockSiteMenuItem {
    NSURL *url = [[self.host browserWebView] request].URL;
    NSString *host = [BrowserContentBlocker exceptionKeyForURL:url];
    BOOL excepted = [[BrowserContentBlocker sharedBlocker] isExceptionForURL:url];
    BOOL automatic = excepted && [[BrowserContentBlocker sharedBlocker] isAutoExceptionForURL:url];
    return [self advancedMenuItemWithTitle:@"Werbeblocker hier"
                                    detail:host == nil ? @"–" : (automatic ? @"Pausiert (Sperre)" : (excepted ? @"Aus" : @"An"))
                                   handler:^{
        if (host == nil) {
            return;
        }
        [[BrowserContentBlocker sharedBlocker] setException:!excepted forURL:url];
        [[self.host browserWebView] reload];
    }];
}

- (BrowserAdvancedMenuItem *)cookieBannerMenuItem {
    BOOL enabled = self.preferencesStore.cookieBannerBlockEnabled;
    return [self advancedMenuItemWithTitle:@"Cookie-Banner ablehnen"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.cookieBannerBlockEnabled = !enabled;
        [[BrowserCookieConsentBlocker sharedBlocker] preferencesDidChange];
        [[self.host browserWebView] reload];
    }];
}

/// Bezahlschranken („Mit Werbung lesen oder Abo“) lassen sich nicht ablehnen: auf Wunsch zustimmen, damit nie ein Banner stehen bleibt.
- (BrowserAdvancedMenuItem *)rainbowGlowMenuItem {
    BOOL enabled = self.preferencesStore.rainbowGlowEnabled;
    return [self advancedMenuItemWithTitle:@"Regenbogen-Leuchten"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.rainbowGlowEnabled = !enabled;
    }];
}

/// Design: Liquid Glass (Standard) oder das alte Design der ursprünglichen Fassung (graue Leiste, Originalsymbole,
/// volle Adresse, kein Glas). Wirkt sofort: BrowserTopBarView folgt der Einstellung über NSUserDefaultsDidChangeNotification,
/// alle übrigen Flächen fragen BrowserMotion beim nächsten Öffnen.
- (BrowserAdvancedMenuItem *)designMenuItem {
    BOOL classic = self.preferencesStore.classicDesignEnabled;
    return [self advancedMenuItemWithTitle:@"Design"
                                    detail:classic ? @"Alt" : @"Liquid Glass"
                                   handler:^{
        self.preferencesStore.classicDesignEnabled = !classic;
        [self.host browserBringCursorToFront];
    }];
}

/// Glow-Animation: Regenbogen dreht sich und atmet, aus = stehender Verlauf (bei „Bewegung reduzieren“ immer stehend).
- (BrowserAdvancedMenuItem *)glowAnimationMenuItem {
    BOOL enabled = self.preferencesStore.glowAnimationEnabled;
    return [self advancedMenuItemWithTitle:@"Glow-Animation"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.glowAnimationEnabled = !enabled;
    }];
}

/// Liquid-Glass-Animationen (Federn, materialisierendes Glas) oder schlichte Überblendungen, s. BrowserMotion.
- (BrowserAdvancedMenuItem *)liquidGlassAnimationsMenuItem {
    BOOL enabled = self.preferencesStore.liquidGlassAnimationsEnabled;
    return [self advancedMenuItemWithTitle:@"Liquid-Glass-Animationen"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.liquidGlassAnimationsEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)cookiePayWallMenuItem {
    BOOL enabled = self.preferencesStore.cookieBannerAcceptPayWalls;
    return [self advancedMenuItemWithTitle:@"Bezahlschranken zustimmen"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.cookieBannerAcceptPayWalls = !enabled;
        [[BrowserCookieConsentBlocker sharedBlocker] preferencesDidChange];
        [[self.host browserWebView] reload];
    }];
}

/// Lässt Cookie-Banner für den Host der aktuellen Seite zu bzw. lehnt sie wieder ab.
- (BrowserAdvancedMenuItem *)cookieBannerSiteMenuItem {
    NSURL *url = [[self.host browserWebView] request].URL;
    NSString *host = [BrowserCookieConsentBlocker exceptionKeyForURL:url];
    BOOL excepted = [[BrowserCookieConsentBlocker sharedBlocker] isExceptionForURL:url];
    return [self advancedMenuItemWithTitle:@"Cookie-Banner hier ablehnen"
                                    detail:host == nil ? @"–" : (excepted ? @"Aus" : @"An")
                                   handler:^{
        if (host == nil) {
            return;
        }
        [[BrowserCookieConsentBlocker sharedBlocker] setException:!excepted forURL:url];
        // Das Neuladen ist eine Hauptframe-Navigation und setzt das Skript passend zur Ausnahme
        [[self.host browserWebView] reload];
    }];
}

/// Schaltet den Grundzoom reihum durch feste Stufen und merkt ihn sich für alle Tabs.
- (BrowserAdvancedMenuItem *)pageZoomMenuItem {
    NSArray<NSNumber *> *steps = @[@1.0, @1.25, @1.5, @1.75, @2.0, @2.5];
    double current = self.preferencesStore.pageZoom;
    double next = steps.firstObject.doubleValue;
    for (NSNumber *step in steps) {
        if (step.doubleValue > current + 0.01) {
            next = step.doubleValue;
            break;
        }
    }
    return [self advancedMenuItemWithTitle:@"Seitenzoom"
                                    detail:[NSString stringWithFormat:@"%.0f %% → %.0f %%", current * 100.0, next * 100.0]
                                   handler:^{
        self.preferencesStore.pageZoom = next;
        [[self.host browserWebView] setPageZoom:next];
    }];
}

- (BrowserAdvancedMenuItem *)pageScalingMenuItem {
    BOOL scalesPageToFit = [[self.host browserWebView] scalesPageToFit];
    return [self advancedMenuItemWithTitle:@"Seite an Breite anpassen"
                                    detail:scalesPageToFit ? @"An" : @"Aus"
                                   handler:^{
        [self setPageScalingEnabled:!scalesPageToFit];
    }];
}

- (UIAlertAction *)playVideoUnderCursorAction {
    return [self browserActionWithTitle:@"Aktives Video abspielen"
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.host browserPlayVideoUnderCursorIfAvailable];
        });
    }];
}

- (BrowserAdvancedMenuItem *)fullscreenVideoPlaybackToggleMenuItem {
    BOOL enabled = self.host.browserFullscreenVideoPlaybackEnabled;
    return [self advancedMenuItemWithTitle:@"Vollbild-Player"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.host.browserFullscreenVideoPlaybackEnabled = !enabled;
    }];
}

- (BrowserAdvancedMenuItem *)autoSubtitlesMenuItem {
    BOOL enabled = self.preferencesStore.autoSubtitlesEnabled;
    return [self advancedMenuItemWithTitle:@"Automatische Untertitel"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.autoSubtitlesEnabled = !enabled;
    }];
}

/// Sprache der automatischen Untertitel durchschalten: Automatisch → Deutsch → Englisch → … (gilt für den nativen
/// Player und die Webseite). Ohne mehrsprachiges Modell geht nur Englisch.
- (BrowserAdvancedMenuItem *)autoSubtitlesLanguageMenuItem {
    NSString *current = self.preferencesStore.autoSubtitlesLanguage;
    if (![BrowserSubtitleEngine hasMultilingualModel]) {
        return [self advancedMenuItemWithTitle:@"Untertitelsprache" detail:@"Nur Englisch (Modell)" handler:^{}];
    }
    NSArray<NSString *> *languages = [BrowserSubtitleEngine selectableLanguages];
    NSUInteger index = [languages indexOfObject:current];
    NSString *next = languages[index == NSNotFound ? 0 : (index + 1) % languages.count];
    return [self advancedMenuItemWithTitle:@"Untertitelsprache"
                                    detail:[BrowserSubtitleEngine displayNameForLanguage:current]
                                   handler:^{
        self.preferencesStore.autoSubtitlesLanguage = next;
    }];
}

- (BrowserAdvancedMenuItem *)webSubtitlesMenuItem {
    BOOL enabled = self.preferencesStore.webSubtitlesEnabled;
    return [self advancedMenuItemWithTitle:@"Untertitel (Webseite)"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        [self.host browserSetWebSubtitlesEnabled:!enabled];
    }];
}

/// Zeigertempo durchschalten: Langsam → Normal → Schnell → Sehr schnell.
- (BrowserAdvancedMenuItem *)pointerSpeedMenuItem {
    NSArray<NSNumber *> *speeds = @[@0.7, @1.0, @1.4, @2.0];
    NSArray<NSString *> *names = @[@"Langsam", @"Normal", @"Schnell", @"Sehr schnell"];
    double current = self.preferencesStore.pointerSpeed;
    NSUInteger index = 1;
    double best = DBL_MAX;
    for (NSUInteger i = 0; i < speeds.count; i++) {
        double distance = fabs(speeds[i].doubleValue - current);
        if (distance < best) { best = distance; index = i; }
    }
    return [self advancedMenuItemWithTitle:@"Zeigertempo"
                                    detail:names[index]
                                   handler:^{
        self.preferencesStore.pointerSpeed = speeds[(index + 1) % speeds.count].doubleValue;
    }];
}

/// Auslaufen des Zeigers nach schnellem Wischen.
- (BrowserAdvancedMenuItem *)pointerGlideMenuItem {
    BOOL enabled = self.preferencesStore.pointerGlideEnabled;
    return [self advancedMenuItemWithTitle:@"Zeiger gleitet aus"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.pointerGlideEnabled = !enabled;
    }];
}

/// Zeigerstil durchschalten: macOS dunkel → macOS hell → SF Symbols.
- (BrowserAdvancedMenuItem *)cursorStyleMenuItem {
    NSUInteger style = self.preferencesStore.cursorStyle % 3;
    NSArray<NSString *> *names = @[@"Dunkel", @"Hell", @"Symbol"];
    return [self advancedMenuItemWithTitle:@"Zeiger"
                                    detail:names[style]
                                   handler:^{
        self.preferencesStore.cursorStyle = (style + 1) % 3;
        [self.host browserBringCursorToFront];
    }];
}

- (BrowserAdvancedMenuItem *)autoOpenNativePlayerMenuItem {
    BOOL enabled = self.preferencesStore.autoOpenVideosInNativePlayer;
    return [self advancedMenuItemWithTitle:@"Native Player automatisch"
                                    detail:enabled ? @"An" : @"Aus"
                                   handler:^{
        self.preferencesStore.autoOpenVideosInNativePlayer = !enabled;
    }];
}

/// Einträge des Abschnitts „Erweiterungen“. Neue Erweiterungen hängen ihre Schalter hier an.
- (NSArray<BrowserAdvancedMenuItem *> *)extensionMenuItems {
    return @[
        [self adBlockMenuItem],
        [self adBlockAutoPauseMenuItem],
        [self filterListUpdateMenuItem],
        [self cookieBannerMenuItem],
        [self cookiePayWallMenuItem],
        [self autoOpenNativePlayerMenuItem],
        [self autoSubtitlesMenuItem],
        [self autoSubtitlesLanguageMenuItem],
        [self webSubtitlesMenuItem],
        [self cloudflareDNSMenuItem],
    ];
}

- (NSArray<BrowserAdvancedMenuSection *> *)advancedMenuSections {
    BrowserAdvancedMenuItem *increaseFontSizeItem = [self advancedMenuItemWithTitle:@"Schrift größer"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        self.host.browserTextFontSize += 5;
        [self.host browserUpdateTextFontSize];
    }];
    BrowserAdvancedMenuItem *decreaseFontSizeItem = [self advancedMenuItemWithTitle:@"Schrift kleiner"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        self.host.browserTextFontSize -= 5;
        [self.host browserUpdateTextFontSize];
    }];
    BrowserAdvancedMenuItem *resetFontSizeItem = [self advancedMenuItemWithTitle:@"Schriftgröße zurücksetzen"
                                                                            style:UIAlertActionStyleDefault
                                                                          handler:^{
        self.host.browserTextFontSize = 100;
        [self.host browserUpdateTextFontSize];
    }];
    BrowserAdvancedMenuItem *mediaDiagnosticsItem = [self advancedMenuItemWithTitle:@"Medien-Diagnose"
                                                                               style:UIAlertActionStyleDefault
                                                                             handler:^{
        [self presentMediaDiagnostics];
    }];
    BrowserAdvancedMenuItem *webkitMediaPrefsItem = [self advancedMenuItemWithTitle:@"WebKit-Medieneinstellungen"
                                                                                style:UIAlertActionStyleDefault
                                                                              handler:^{
        [self presentWebKitRuntimeMediaPreferences];
    }];
    BrowserAdvancedMenuItem *clearCacheItem = [self advancedMenuItemWithTitle:@"Cache leeren"
                                                                         style:UIAlertActionStyleDestructive
                                                                       handler:^{
        [self clearCacheAndReload];
    }];
    BrowserAdvancedMenuItem *clearCookiesItem = [self advancedMenuItemWithTitle:@"Cookies löschen"
                                                                           style:UIAlertActionStyleDestructive
                                                                         handler:^{
        [self clearCookiesAndReload];
    }];

    BrowserAdvancedMenuItem *reloadItem = [self advancedMenuItemWithTitle:@"Neu laden"
                                                                     style:UIAlertActionStyleDefault
                                                                   handler:^{
        [[self.host browserWebView] reload];
    }];

    return @[
        [BrowserAdvancedMenuSection sectionWithTitle:@"Diese Seite"
                                               items:[[self intelligenceMenuItems] arrayByAddingObjectsFromArray:@[
            reloadItem,
            [self pageZoomMenuItem],
            [self adBlockSiteMenuItem],
            [self cookieBannerSiteMenuItem],
        ]]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Navigation"
                                               items:@[
            [self homePageMenuItem],
            [self homePageSettingMenuItem],
            [self favoritesMenuItem],
            [self historyMenuItem],
            [self showTabsMenuItem],
            [self newTabMenuItem],
            [self closeUnusedTabsMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Erweiterungen"
                                               items:[self extensionMenuItems]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Ansicht & Wiedergabe"
                                               items:@[
            [self topNavigationVisibilityMenuItem],
            [self rainbowGlowMenuItem],
            [self designMenuItem],
            [self glowAnimationMenuItem],
            [self liquidGlassAnimationsMenuItem],
            [self cursorStyleMenuItem],
            [self pointerSpeedMenuItem],
            [self pointerGlideMenuItem],
            [self fullscreenVideoPlaybackToggleMenuItem],
            [self pageScalingMenuItem],
            [self userAgentModeMenuItem],
            increaseFontSizeItem,
            decreaseFontSizeItem,
            resetFontSizeItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Daten"
                                               items:@[
            clearCacheItem,
            clearCookiesItem,
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Hilfe"
                                               items:@[
            [self usageGuideMenuItem],
            [self whatsNewMenuItem],
            [self setupMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Erweitert"
                                               items:@[
            mediaDiagnosticsItem,
            webkitMediaPrefsItem,
        ]],
    ];
}

- (NSString *)advancedMenuFooterText {
    NSDictionary *infoDictionary = NSBundle.mainBundle.infoDictionary;
    NSString *version = infoDictionary[@"CFBundleShortVersionString"];
    BOOL hasVersion = [self stringHasVisibleContent:version];

    if (hasVersion) {
        return [NSString stringWithFormat:@"Version %@", version];
    }
    return @"";
}

@end
