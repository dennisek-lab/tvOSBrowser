#import "BrowserTopBarView.h"
#import "BrowserShape.h"
#import "BrowserMotion.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif
#import "BrowserLocalization.h"

static CGFloat const kTopBarHorizontalInset = 40.0;
/// Luft über der ausgeklappten Leiste (die Ansicht ist 116 pt hoch: 18 oben, 86 Leiste, 12 unten).
static CGFloat const kTopBarVerticalInset = 18.0;
static CGFloat const kTopBarCompactVerticalInset = 12.0;
static CGFloat const kTopBarHeight = 86.0;
static CGFloat const kTopBarMaxWidth = 1760.0;
static CGFloat const kTopBarIconSize = 52.0;
static CGFloat const kTopBarLeadingPadding = 28.0;
static CGFloat const kTopBarTrailingPadding = 26.0;
static CGFloat const kTopBarIconSpacing = 24.0;
static CGFloat const kTopBarLabelSpacing = 28.0;
static CGFloat const kTopBarSpinnerSpacing = 22.0;
static CGFloat const kTopBarFocusHighlightInset = 10.0;
static CGFloat const kTopBarUniformFocusHeight = 72.0;
static CGFloat const kTopBarCompactHeight = 58.0;
static CGFloat const kTopBarCompactWidth = 560.0;
static CGFloat const kTopBarCompactLabelScale = 0.8;
/// Altes Design: Abstand oben wie im Original (Leiste 8 pt unter dem Bildschirmrand).
static CGFloat const kTopBarClassicVerticalInset = 8.0;

@interface BrowserTopBarFocusButton : UIButton

@property (nonatomic) BrowserTopBarAction topBarAction;

@end

@implementation BrowserTopBarFocusButton

- (BOOL)canBecomeFocused {
    return self.enabled && !self.hidden && self.alpha > 0.01;
}

- (UIFocusSoundIdentifier)soundIdentifierForFocusUpdateInContext:(__unused UIFocusUpdateContext *)context {
    return UIFocusSoundIdentifierDefault;
}

@end

@interface BrowserTopBarView ()

@property (nonatomic) UIView *chromeContainerView;
@property (nonatomic) UIVisualEffectView *chromeEffectView;
@property (nonatomic) UIImageView *backImageView;
@property (nonatomic) UIImageView *refreshImageView;
@property (nonatomic) UIImageView *forwardImageView;
@property (nonatomic) UIImageView *homeImageView; // zeigt den Favoriten-Stern
@property (nonatomic) UIImageView *tabsImageView;
@property (nonatomic) UIImageView *fullscreenImageView;
@property (nonatomic) UIImageView *menuImageView;
@property (nonatomic) UIImageView *readerImageView;
@property (nonatomic) UIView *readerHighlightView;
@property (nonatomic) BrowserTopBarFocusButton *readerFocusButton;
@property (nonatomic, readwrite) BOOL readerAvailable;
@property (nonatomic, readwrite) BOOL readerActive;
@property (nonatomic) UILabel *URLLabel;
@property (nonatomic) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic) UIView *focusGlowView;
@property (nonatomic) UIView *focusHighlightView;
@property (nonatomic) NSArray<BrowserTopBarFocusButton *> *focusButtons;
@property (nonatomic) BrowserTopBarFocusButton *backFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *refreshFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *forwardFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *homeFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *tabsFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *URLFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *fullscreenFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *menuFocusButton;
@property (nonatomic) BrowserTopBarFocusButton *lastFocusedButton;
@property (nonatomic, getter=isFocusModeActive) BOOL focusModeActive;
@property (nonatomic, readwrite, getter=isCompact) BOOL compact;
@property (nonatomic) BOOL lightPage;
@property (nonatomic) BOOL colorfulPage;
@property (nonatomic, nullable) UIColor *pageForegroundColor;
@property (nonatomic, strong, nullable) id scrollEdgeInteraction;
@property (nonatomic) UIView *glassDimmingView;
@property (nonatomic) UIView *progressView;
@property (nonatomic) double loadingProgress;
@property (nonatomic) CGRect URLTargetFrame;
@property (nonatomic) BOOL progressVisible;
@property (nonatomic, copy, nullable) NSString *displayTitle;
@property (nonatomic, copy, nullable) NSString *displayDomain;
@property (nonatomic) BOOL displaySecure;
// Adresse bearbeiten (Diktierfeld), siehe Abschnitt am Ende der Datei.
@property (nonatomic, readwrite, getter=isAddressEditing) BOOL addressEditing;
@property (nonatomic) UIView *dictationFieldView;
@property (nonatomic) UIImageView *dictationIconView;
@property (nonatomic) UILabel *dictationLabel;
// Altes Design, siehe Abschnitt „Altes Design“.
@property (nonatomic, readwrite, getter=isClassicDesign) BOOL classicDesign;
@property (nonatomic, nullable) UIColor *pageColor;
@property (nonatomic, copy, nullable) NSString *displayURLString;

@end

@implementation BrowserTopBarView

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithEffect:(UIVisualEffect *)effect {
    self = [super initWithEffect:effect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];

    for (UIView *subview in [self.contentView.subviews copy]) {
        if (subview != self.chromeContainerView) {
            [subview removeFromSuperview];
        }
    }
}

- (void)commonInit {
    self.effect = nil;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.userInteractionEnabled = YES;
    self.contentView.clipsToBounds = NO;

    self.chromeContainerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.chromeContainerView.backgroundColor = UIColor.clearColor;
    self.chromeContainerView.userInteractionEnabled = YES;
    self.chromeContainerView.clipsToBounds = NO;
    [self.contentView addSubview:self.chromeContainerView];

    self.chromeEffectView = [[UIVisualEffectView alloc] initWithEffect:nil];
    self.chromeEffectView.userInteractionEnabled = YES;
    self.chromeEffectView.clipsToBounds = YES;
    [self.chromeContainerView addSubview:self.chromeEffectView];

    self.focusGlowView = [[UIView alloc] initWithFrame:CGRectZero];
    self.focusGlowView.backgroundColor = UIColor.clearColor;
    self.focusGlowView.userInteractionEnabled = NO;
    self.focusGlowView.hidden = YES;
    self.focusGlowView.layer.shadowColor = [UIColor colorWithRed:0.23 green:0.57 blue:1.0 alpha:1.0].CGColor;
    self.focusGlowView.layer.shadowOffset = CGSizeZero;
    self.focusGlowView.layer.shadowOpacity = 0.0;
    self.focusGlowView.layer.shadowRadius = 18.0;
    [self.chromeContainerView insertSubview:self.focusGlowView belowSubview:self.chromeEffectView];

    // Klares Glas lässt die Farben der Seite durchscheinen; eine leichte Abdunkelung bzw. Aufhellung hält Schrift lesbar (HIG).
    self.glassDimmingView = [[UIView alloc] initWithFrame:CGRectZero];
    self.glassDimmingView.userInteractionEnabled = NO;
    [self.chromeEffectView.contentView addSubview:self.glassDimmingView];

    self.progressView = [[UIView alloc] initWithFrame:CGRectZero];
    self.progressView.userInteractionEnabled = NO;
    self.progressView.backgroundColor = UIColor.systemBlueColor;
    BrowserShapeApply(self.progressView.layer, 1.5);
    self.progressView.alpha = 0.0;
    [self.chromeEffectView.contentView addSubview:self.progressView];

    self.focusHighlightView = [[UIView alloc] initWithFrame:CGRectZero];
    self.focusHighlightView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    BrowserShapeApply(self.focusHighlightView.layer, 22.0);
    self.focusHighlightView.alpha = 0.0;
    self.focusHighlightView.hidden = YES;
    [self.chromeEffectView.contentView addSubview:self.focusHighlightView];

    _backImageView = [self newIconViewWithSymbol:@"chevron.backward" fallbackImageNamed:@"go-back-left-arrow"];
    _refreshImageView = [self newIconViewWithSymbol:@"arrow.clockwise" fallbackImageNamed:@"refresh-button"];
    _forwardImageView = [self newIconViewWithSymbol:@"chevron.forward" fallbackImageNamed:@"right-arrow-forward"];
    // Statt „Startseite“ (bleibt in der Seitenleiste) sitzt hier der Favoriten-Stern.
    _homeImageView = [self newIconViewWithSymbol:@"star" fallbackImageNamed:@"house-outline"];
    _tabsImageView = [self newIconViewWithSymbol:@"square.on.square" fallbackImageNamed:@"multi-tab"];
    _fullscreenImageView = [self newIconViewWithSymbol:@"arrow.up.left.and.arrow.down.right" fallbackImageNamed:@"resize-arrows"];
    _menuImageView = [self newIconViewWithSymbol:@"ellipsis.circle" fallbackImageNamed:@"menu-2"];
    _readerImageView = [self newIconViewWithSymbol:@"doc.plaintext" fallbackImageNamed:@"menu-2"];
    if ([UIImage systemImageNamed:@"doc.plaintext"] == nil) {
        _readerImageView.image = [[UIImage systemImageNamed:@"text.page"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] ?: _readerImageView.image;
    }
    _readerImageView.alpha = 0.0;
    // Hervorhebung hinter dem Symbol, solange der Reader läuft.
    _readerHighlightView = [[UIView alloc] initWithFrame:CGRectZero];
    _readerHighlightView.userInteractionEnabled = NO;
    _readerHighlightView.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.9];
    _readerHighlightView.layer.cornerCurve = kCACornerCurveContinuous;
    _readerHighlightView.alpha = 0.0;
    [self.chromeEffectView.contentView addSubview:_readerHighlightView];

    _URLLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _URLLabel.text = @"tvOS Browser";
    _URLLabel.textAlignment = NSTextAlignmentCenter;
    _URLLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    _URLLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _URLLabel.adjustsFontSizeToFitWidth = NO;
    _URLLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    // Beim Umschalten kompakt ↔ voll ändert sich die Breite: Inhalt mittig stehen lassen statt strecken/abschneiden.
    _URLLabel.contentMode = UIViewContentModeCenter;
    [self.chromeEffectView.contentView addSubview:_URLLabel];

    _loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingSpinner.color = [UIColor colorWithWhite:1.0 alpha:0.92];
    _loadingSpinner.tintColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _loadingSpinner.hidesWhenStopped = YES;
    [self.chromeEffectView.contentView addSubview:_loadingSpinner];

    NSArray<UIImageView *> *iconViews = @[
        _backImageView,
        _refreshImageView,
        _forwardImageView,
        _homeImageView,
        _tabsImageView,
        _fullscreenImageView,
        _menuImageView,
        _readerImageView
    ];
    for (UIImageView *imageView in iconViews) {
        [self.chromeEffectView.contentView addSubview:imageView];
    }

    _backFocusButton = [self newFocusButtonForAction:BrowserTopBarActionBack accessibilityLabel:BLS(@"Back")];
    _refreshFocusButton = [self newFocusButtonForAction:BrowserTopBarActionRefresh accessibilityLabel:BLS(@"Reload")];
    _forwardFocusButton = [self newFocusButtonForAction:BrowserTopBarActionForward accessibilityLabel:BLS(@"Forward")];
    _homeFocusButton = [self newFocusButtonForAction:BrowserTopBarActionFavorite accessibilityLabel:BLS(@"Favorit")];
    _tabsFocusButton = [self newFocusButtonForAction:BrowserTopBarActionTabs accessibilityLabel:BLS(@"Tabs")];
    _URLFocusButton = [self newFocusButtonForAction:BrowserTopBarActionURL accessibilityLabel:BLS(@"Adresse oder Suche")];
    _fullscreenFocusButton = [self newFocusButtonForAction:BrowserTopBarActionFullscreen accessibilityLabel:BLS(@"Obere Leiste ein- oder ausblenden")];
    _menuFocusButton = [self newFocusButtonForAction:BrowserTopBarActionMenu accessibilityLabel:BLS(@"Menu")];
    _readerFocusButton = [self newFocusButtonForAction:BrowserTopBarActionReader accessibilityLabel:BLS(@"Reader")];
    _focusButtons = @[
        _backFocusButton,
        _refreshFocusButton,
        _forwardFocusButton,
        _homeFocusButton,
        _tabsFocusButton,
        _URLFocusButton,
        _fullscreenFocusButton,
        _menuFocusButton,
        _readerFocusButton
    ];
    for (BrowserTopBarFocusButton *button in _focusButtons) {
        [self.chromeEffectView.contentView addSubview:button];
    }

    [self setUpAddressEditingViews];
    _classicDesign = BrowserMotion.classicDesignEnabled;
    [self applyIconImages];
    [self applyClassicFocusActions];
    [self applyVisualStyle];
    [self setFocusModeActive:NO];
    // Umschalten in der Seitenleiste, in der Ersteinrichtung oder per Selbsttest (pref:ClassicDesign=…) wirkt sofort.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(userDefaultsDidChange:)
                                               name:NSUserDefaultsDidChangeNotification
                                             object:nil];
    // Änderungen aus einem anderen Prozess melden die Standardwerte nicht; beim Aktivieren deshalb erneut vergleichen.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(userDefaultsDidChange:)
                                               name:UISceneDidActivateNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// SF Symbols wie in Safari, die alten Bilder nur als Rückfall.
- (UIImageView *)newIconViewWithSymbol:(NSString *)symbolName fallbackImageNamed:(NSString *)imageName {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:symbolName withConfiguration:configuration];
    if (image == nil) {
        image = [UIImage imageNamed:imageName];
    }
    UIImageView *imageView = [[UIImageView alloc] initWithImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    imageView.userInteractionEnabled = NO;
    imageView.contentMode = UIViewContentModeCenter;
    imageView.tintColor = UIColor.whiteColor;
    imageView.alpha = 0.95;
    return imageView;
}

- (void)setPageBackgroundColor:(UIColor *)color {
    self.pageColor = color;
    CGFloat red = 0, green = 0, blue = 0, alpha = 0;
    if (color == nil || ![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        red = green = blue = 0;
    }
    // Relative Helligkeit: helle Seite -> dunkle Symbole und Schrift, dunkle Seite -> helle.
    CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    // Altes Design: graue Kapsel mit weißen Symbolen auf jeder Seite, wie im Original.
    BOOL light = !self.classicDesign && luminance > 0.6;
    CGFloat hue = 0, saturation = 0, brightness = 0, hueAlpha = 0;
    // Kräftig gefärbte Seiten (z. B. rote Leiste): Grün wäre dort schlecht lesbar.
    self.colorfulPage = !self.classicDesign && color != nil &&
        [color getHue:&hue saturation:&saturation brightness:&brightness alpha:&hueAlpha] &&
        saturation > 0.4 && brightness > 0.25;
#if DEBUG
    NSLog(@"[TopBar] Seitenfarbe %@ s=%.2f b=%.2f bunt=%d", color, saturation, brightness, self.colorfulPage);
#endif
    UIColor *foreground = light ? [UIColor colorWithWhite:0.08 alpha:1.0] : UIColor.whiteColor;
    for (UIImageView *imageView in @[self.backImageView, self.refreshImageView, self.forwardImageView, self.homeImageView,
                                     self.tabsImageView, self.fullscreenImageView, self.menuImageView, self.readerImageView]) {
        imageView.tintColor = foreground;
    }
    self.pageForegroundColor = foreground;
    [self applyReaderStyle];
    [self applyFavoriteStyle];
    self.loadingSpinner.color = foreground;
    self.chromeEffectView.overrideUserInterfaceStyle = light ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
    self.lightPage = light;
    [self applyContrastStyle];
    [self renderTitle];
    [self applyAddressEditingStyle];
}

/// Reader-Knopf: nur sichtbar, wenn die Seite lesbar ist; im Reader weiß auf blauer Hervorhebung.
- (void)setReaderAvailable:(BOOL)available active:(BOOL)active {
    available = available || active;
    if (self.readerAvailable == available && self.readerActive == active) {
        return;
    }
    BOOL becomesActive = active && !self.readerActive;
    self.readerAvailable = available;
    self.readerActive = active;
    // Knopf und blaue Hervorhebung blenden über BrowserMotion; Liquid Glass: Hervorhebung federt beim Einschalten auf.
    if (becomesActive && BrowserMotion.liquidGlassEnabled) {
        self.readerHighlightView.transform = CGAffineTransformMakeScale(0.82, 0.82);
    }
    [BrowserMotion animateKind:BrowserMotionKindSnap delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        [self applyReaderStyle];
        self.readerHighlightView.transform = CGAffineTransformIdentity;
    } completion:nil];
    [self setNeedsLayout];
}

- (void)applyReaderStyle {
    self.readerImageView.tintColor = self.readerActive ? UIColor.whiteColor : (self.pageForegroundColor ?: UIColor.whiteColor);
    BOOL visible = self.readerAvailable && !self.compact && !self.addressEditing;
    self.readerImageView.alpha = visible ? 0.95 : 0.0;
    self.readerHighlightView.alpha = (visible && self.readerActive) ? 1.0 : 0.0;
}

- (BrowserTopBarFocusButton *)newFocusButtonForAction:(BrowserTopBarAction)action
                                   accessibilityLabel:(NSString *)accessibilityLabel {
    BrowserTopBarFocusButton *button = [BrowserTopBarFocusButton buttonWithType:UIButtonTypeCustom];
    button.topBarAction = action;
    button.backgroundColor = UIColor.clearColor;
    button.hidden = YES;
    button.enabled = NO;
    button.accessibilityLabel = accessibilityLabel;
    button.accessibilityTraits = UIAccessibilityTraitButton;
    [button addTarget:self action:@selector(handleFocusButtonPrimaryAction:) forControlEvents:UIControlEventPrimaryActionTriggered];
    return button;
}

- (void)applyVisualStyle {
    // Abheben vom Inhalt auch auf einfarbigen Seiten: weicher Schatten und feine Kante (HIG: Glas schwebt über dem Inhalt).
    self.chromeContainerView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.chromeContainerView.layer.shadowOffset = CGSizeMake(0.0, 8.0);
    self.chromeContainerView.layer.shadowRadius = 24.0;
    self.chromeEffectView.layer.cornerCurve = kCACornerCurveContinuous;
    self.chromeEffectView.layer.borderWidth = 1.0;
    if (self.classicDesign) {
        // Altes Design: kein Glas. Dunkler Blur (der vorhandene Rückfall) mit grauer Tönung ergibt die halbtransparente
        // graue Kapsel des Originals; ohne Kante und Schatten.
        self.effect = nil;
        self.chromeEffectView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        self.chromeEffectView.alpha = 1.0;
        self.chromeEffectView.layer.borderWidth = 0.0;
        [self applyContrastStyle];
        return;
    }
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        self.effect = nil;
        UIGlassEffect *glassEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleClear];
        glassEffect.interactive = YES;
        self.chromeEffectView.effect = glassEffect;
        self.chromeEffectView.alpha = 1.0;
        [self applyContrastStyle];
        return;
    }
#endif
    self.effect = nil;
    self.chromeEffectView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.chromeEffectView.alpha = 0.98;
    [self applyContrastStyle];
}

- (void)applyContrastStyle {
    if (self.classicDesign) {
        self.chromeContainerView.layer.shadowOpacity = 0.0;
        self.glassDimmingView.backgroundColor = [UIColor colorWithWhite:0.54 alpha:0.62]; // auf weißer Seite Grau 155 wie docs/original-screens/screen01.png
        return;
    }
    BOOL light = self.lightPage;
    self.chromeContainerView.layer.shadowOpacity = light ? 0.24 : 0.35;
    self.chromeEffectView.layer.borderColor = (light ? [UIColor colorWithWhite:0.0 alpha:0.14]
                                                     : [UIColor colorWithWhite:1.0 alpha:0.16]).CGColor;
    self.glassDimmingView.backgroundColor = light ? [UIColor colorWithWhite:1.0 alpha:0.42] : [UIColor colorWithWhite:0.0 alpha:0.35];
}

- (void)setFavorite:(BOOL)favorite {
    if (_favorite == favorite) {
        return;
    }
    _favorite = favorite;
    [self applyFavoriteStyle];
}

- (void)applyFavoriteStyle {
    if (self.classicDesign) {
        // Altes Design: an dieser Stelle sitzt wieder „Startseite“ (Haus), Favoriten über die Seitenleiste.
        self.homeImageView.tintColor = UIColor.whiteColor;
        return;
    }
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
    UIImage *star = [UIImage systemImageNamed:self.favorite ? @"star.fill" : @"star" withConfiguration:configuration];
    if (star != nil) {
        self.homeImageView.image = [star imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    self.homeImageView.tintColor = self.favorite ? UIColor.systemYellowColor : (self.pageForegroundColor ?: UIColor.whiteColor);
}

- (CGRect)progressFrameForValue:(double)value {
    CGRect bounds = self.chromeEffectView.bounds;
    CGFloat inset = CGRectGetHeight(bounds) / 2.0;
    CGFloat available = MAX(0.0, CGRectGetWidth(bounds) - 2.0 * inset);
    return CGRectMake(inset, CGRectGetHeight(bounds) - 6.0, available * MAX(0.0, MIN(1.0, value)), 3.0);
}

- (void)setLoadingProgress:(double)progress loading:(BOOL)loading {
    if (self.classicDesign) {
        // Altes Design: nur der Ladekreisel wie im Original, keine Fortschrittslinie.
        self.progressVisible = NO;
        self.loadingProgress = 0.0;
        self.progressView.alpha = 0.0;
        return;
    }
    if (loading) {
        // Kleiner Startwert, damit sofort sichtbar ist, dass etwas passiert.
        double value = MAX(progress, 0.08);
        BOOL wasVisible = self.progressVisible;
        self.progressVisible = YES;
        if (!wasVisible) {
            [self.progressView.layer removeAllAnimations];
            self.loadingProgress = 0.0;
            self.progressView.frame = [self progressFrameForValue:0.0];
        }
        if (value < self.loadingProgress) {
            return;
        }
        self.loadingProgress = value;
        [BrowserMotion animateKind:BrowserMotionKindFade delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self.progressView.alpha = 1.0;
            self.progressView.frame = [self progressFrameForValue:value];
        } completion:nil];
        return;
    }
    if (!self.progressVisible) {
        return;
    }
    self.progressVisible = NO;
    self.loadingProgress = 1.0;
    [BrowserMotion animateKind:BrowserMotionKindFade delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.progressView.frame = [self progressFrameForValue:1.0];
    } completion:^(__unused BOOL finished) {
        [BrowserMotion animateKind:BrowserMotionKindFade delay:0.0 options:0 animations:^{
            self.progressView.alpha = 0.0;
        } completion:^(__unused BOOL done) {
            if (!self.progressVisible) {
                self.loadingProgress = 0.0;
            }
        }];
    }];
}

- (void)setDisplayTitle:(NSString *)title domain:(NSString *)domain secure:(BOOL)secure {
    self.displayTitle = title;
    self.displayDomain = domain;
    self.displaySecure = secure;
    [self renderTitle];
}

- (void)setDisplayURLString:(NSString *)URLString {
    if ((self.displayURLString == nil && URLString == nil) || [self.displayURLString isEqualToString:URLString]) {
        return;
    }
    _displayURLString = [URLString copy];
    if (self.classicDesign) {
        [self renderTitle];
    }
}

- (void)renderTitle {
    if (self.classicDesign) {
        // Altes Design: die volle Adresse, schlicht in gedämpftem Weiß (wie das Original), sonst der Titel („Neuer Tab“).
        NSString *text = self.displayURLString.length > 0 ? self.displayURLString : (self.displayTitle ?: @"");
        self.URLLabel.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.72],
            NSFontAttributeName: self.URLLabel.font,
        }];
        [self setNeedsLayout];
        return;
    }
    UIColor *foreground = self.lightPage ? [UIColor colorWithWhite:0.08 alpha:1.0] : UIColor.whiteColor;
    UIColor *green = self.lightPage ? [UIColor colorWithRed:0.05 green:0.52 blue:0.20 alpha:1.0]
                                    : [UIColor colorWithRed:0.36 green:0.82 blue:0.48 alpha:1.0];
    NSString *title = self.displayTitle ?: @"";
    if (self.colorfulPage) {
        // Farbige Leiste: kräftigeres Grün, damit der Name lesbar bleibt.
        green = self.lightPage ? [UIColor colorWithRed:0.0 green:0.42 blue:0.14 alpha:1.0]
                               : [UIColor colorWithRed:0.55 green:1.0 blue:0.62 alpha:1.0];
    }
    BOOL greenTitle = self.displaySecure;
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    if (self.displaySecure && self.colorfulPage) {
        // Verschlüsselt auf farbiger Seite: zusätzlich das Schloss, der Name bleibt grün.
        UIImageSymbolConfiguration *lockConfiguration = [UIImageSymbolConfiguration configurationWithFont:self.URLLabel.font scale:UIImageSymbolScaleSmall];
        UIImage *lock = [[UIImage systemImageNamed:@"lock.fill" withConfiguration:lockConfiguration]
                         imageWithTintColor:[foreground colorWithAlphaComponent:0.8] renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (lock != nil) {
            [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:[NSTextAttachment textAttachmentWithImage:lock]]];
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{NSFontAttributeName: self.URLLabel.font}]];
        }
    }
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:title attributes:@{
        NSForegroundColorAttributeName: greenTitle ? green : [foreground colorWithAlphaComponent:0.9],
        NSFontAttributeName: self.URLLabel.font,
    }]];
    if (self.displayDomain.length > 0) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  ·  " stringByAppendingString:self.displayDomain] attributes:@{
            NSForegroundColorAttributeName: [foreground colorWithAlphaComponent:0.5],
            NSFontAttributeName: self.URLLabel.font,
        }]];
    }
    self.URLLabel.attributedText = text;
    [self setNeedsLayout];
}

- (void)attachToScrollView:(UIScrollView *)scrollView {
    if (@available(tvOS 26.0, *)) {
        UIScrollEdgeElementContainerInteraction *interaction = self.scrollEdgeInteraction;
        if (interaction == nil) {
            interaction = [[UIScrollEdgeElementContainerInteraction alloc] init];
            interaction.edge = UIRectEdgeTop;
            [self.chromeContainerView addInteraction:interaction];
            self.scrollEdgeInteraction = interaction;
        }
        if (interaction.scrollView != scrollView) {
            interaction.scrollView = scrollView;
            scrollView.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
        }
        // Altes Design: kein weicher Kanteneffekt unter der Leiste (gab es im Original nicht).
        scrollView.topEdgeEffect.hidden = self.classicDesign;
    }
}

- (CGRect)chromeFrame {
    return self.chromeContainerView.frame;
}

- (void)setCompact:(BOOL)compact animated:(BOOL)animated {
    if (_compact == compact) {
        return;
    }
    if (compact && self.focusModeActive) {
        return;
    }
    if (compact && self.addressEditing) {
        return;
    }
    if (compact && self.classicDesign) {
        return; // Altes Design: Die Leiste bleibt wie im Original immer voll.
    }
    _compact = compact;
    if (!animated) {
        [self setNeedsLayout];
        [self layoutIfNeeded];
        return;
    }
    [self animateChromeLayoutAlongside:nil];
}

/// Layoutwechsel der Leiste (kompakt ↔ voll, Bearbeiten) über BrowserMotion. Der Schattenumriss wird von
/// UIView-Animationen nicht mitgenommen und sprang sonst sofort auf die Endform (sichtbares Aufblinken); er läuft
/// deshalb als eigene Animation mit derselben Feder bzw. Kurve mit.
- (void)animateChromeLayoutAlongside:(void (^)(void))extra {
    CALayer *layer = self.chromeContainerView.layer;
    CGPathRef fromPath = CGPathRetain(layer.shadowPath);
    [BrowserMotion animateKind:BrowserMotionKindStandard delay:0.0
                       options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                    animations:^{
        if (extra != nil) {
            extra();
        }
        [self setNeedsLayout];
        [self layoutIfNeeded];
    } completion:nil];
    [BrowserMotion animateShadowPathOfLayer:layer fromPath:fromPath kind:BrowserMotionKindStandard];
    CGPathRelease(fromPath);
}

- (void)layoutSubviews {
    [super layoutSubviews];

    self.contentView.frame = self.bounds;

    CGFloat width = MIN(CGRectGetWidth(self.bounds) - (kTopBarHorizontalInset * 2.0), kTopBarMaxWidth);
    width = MAX(width, 860.0);
    CGFloat height = kTopBarHeight;
    if (self.compact) {
        width = kTopBarCompactWidth;
        height = kTopBarCompactHeight;
    }
    CGFloat originX = floor((CGRectGetWidth(self.bounds) - width) / 2.0);
    CGFloat originY = self.classicDesign ? kTopBarClassicVerticalInset : (self.compact ? kTopBarCompactVerticalInset : kTopBarVerticalInset);
    CGRect chromeFrame = CGRectMake(originX, originY, width, height);

    self.chromeContainerView.frame = chromeFrame;
    self.chromeContainerView.layer.cornerRadius = chromeFrame.size.height / 2.0;
    self.chromeContainerView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.chromeContainerView.bounds
                                                                           cornerRadius:self.chromeContainerView.layer.cornerRadius].CGPath;

    self.chromeEffectView.frame = self.chromeContainerView.bounds;
    self.chromeEffectView.layer.cornerRadius = self.chromeContainerView.layer.cornerRadius;
    self.glassDimmingView.frame = self.chromeEffectView.bounds;
    self.progressView.frame = [self progressFrameForValue:self.loadingProgress];

    CGFloat iconY = floor((CGRectGetHeight(chromeFrame) - kTopBarIconSize) / 2.0);
    CGFloat leftX = kTopBarLeadingPadding;
    // Altes Design: Zurück, Neu laden, Vor, Startseite, Tabs wie im Original; sonst sitzt der Stern beim Seitennamen.
    NSArray<UIImageView *> *leftIcons = self.classicDesign
        ? @[self.backImageView, self.refreshImageView, self.forwardImageView, self.homeImageView, self.tabsImageView]
        : @[self.backImageView, self.refreshImageView, self.forwardImageView, self.tabsImageView];
    for (UIImageView *imageView in leftIcons) {
        imageView.frame = CGRectMake(leftX, iconY, kTopBarIconSize, kTopBarIconSize);
        leftX += kTopBarIconSize + kTopBarIconSpacing;
    }

    CGFloat rightX = CGRectGetWidth(chromeFrame) - kTopBarTrailingPadding - kTopBarIconSize;
    self.menuImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    rightX = CGRectGetMinX(self.menuImageView.frame) - kTopBarIconSpacing - kTopBarIconSize;
    self.fullscreenImageView.frame = CGRectMake(rightX, iconY, kTopBarIconSize, kTopBarIconSize);

    // Der Knopf zum Ausblenden der Leiste entfällt: Beim Scrollen wird sie ohnehin zur Kapsel.
    // Im alten Design ist er wie im Original da (die Leiste wird dort nie zur Kapsel).
    self.fullscreenImageView.hidden = !self.classicDesign;
    // Reader-Knopf direkt links neben dem Menü; sein Platz bleibt immer reserviert, damit Ladekreisel und
    // Seitenname nicht springen, wenn die Lesbarkeit erst nach dem Laden feststeht.
    // Altes Design: links neben dem Vollbild-Knopf und nur, wenn die Seite lesbar ist (sonst sieht die Leiste aus
    // wie im Original).
    self.readerImageView.frame = self.classicDesign
        ? CGRectOffset(self.fullscreenImageView.frame, -(kTopBarIconSize + kTopBarIconSpacing), 0.0)
        : self.fullscreenImageView.frame;
    self.readerHighlightView.frame = CGRectInset(self.readerImageView.frame, -6.0, -2.0);
    // Kapsel wie die Leiste, in der der Knopf liegt.
    self.readerHighlightView.layer.cornerRadius = BrowserShapeCapsuleRadius(CGRectGetHeight(self.readerHighlightView.frame));
    CGFloat spinnerSide = 34.0;
    UIView *spinnerNeighbor = (self.classicDesign && !self.readerAvailable) ? self.fullscreenImageView : self.readerImageView;
    rightX = CGRectGetMinX(spinnerNeighbor.frame) - kTopBarSpinnerSpacing - spinnerSide;
    self.loadingSpinner.frame = CGRectMake(rightX,
                                           floor((CGRectGetHeight(chromeFrame) - spinnerSide) / 2.0),
                                           spinnerSide,
                                           spinnerSide);

    CGFloat labelOriginX = CGRectGetMaxX(self.tabsImageView.frame) + kTopBarLabelSpacing;
    CGFloat labelTrailingX = CGRectGetMinX(self.loadingSpinner.frame) - kTopBarLabelSpacing;
    CGFloat labelWidth = MAX(200.0, labelTrailingX - labelOriginX);
    CGRect labelFrame = CGRectMake(labelOriginX, 0.0, labelWidth, CGRectGetHeight(chromeFrame));
    CGFloat iconAlpha = self.compact ? 0.0 : 0.95;
    for (UIImageView *imageView in @[self.backImageView, self.refreshImageView, self.forwardImageView, self.homeImageView,
                                     self.tabsImageView, self.fullscreenImageView, self.menuImageView]) {
        imageView.alpha = iconAlpha;
    }
    [self applyReaderStyle];
    if (self.compact) {
        // Nur der Seitenname, verkleinert und mittig; der Ladekreisel rechts in der Kapsel.
        CGFloat compactSpinner = 28.0;
        self.loadingSpinner.frame = CGRectMake(CGRectGetWidth(chromeFrame) - 22.0 - compactSpinner,
                                               floor((CGRectGetHeight(chromeFrame) - compactSpinner) / 2.0),
                                               compactSpinner, compactSpinner);
        CGFloat inner = CGRectGetWidth(chromeFrame) - 2.0 * (22.0 + compactSpinner + 8.0);
        labelFrame = CGRectMake(0.0, 0.0, inner / kTopBarCompactLabelScale, CGRectGetHeight(chromeFrame));
    }
    CGPoint labelCenter = CGPointMake(CGRectGetWidth(chromeFrame) / 2.0, CGRectGetHeight(chromeFrame) / 2.0);
    self.URLTargetFrame = labelFrame;
    if (self.classicDesign) {
        // Altes Design: die Adresse mittig im ganzen Bereich zwischen Tabs-Knopf und Ladekreisel.
        labelCenter = CGPointMake(CGRectGetMidX(labelFrame), CGRectGetMidY(labelFrame));
    } else if (!self.compact) {
        // Stern direkt links neben dem Seitennamen, beide zusammen mittig im Adressbereich.
        CGFloat starGap = 14.0;
        CGFloat maxText = MAX(80.0, CGRectGetWidth(labelFrame) - kTopBarIconSize - starGap);
        CGFloat textWidth = MIN(ceil([self.URLLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGRectGetHeight(labelFrame))].width), maxText);
        CGFloat groupWidth = kTopBarIconSize + starGap + textWidth;
        CGFloat groupX = floor(CGRectGetMidX(labelFrame) - groupWidth / 2.0);
        self.homeImageView.frame = CGRectMake(groupX, iconY, kTopBarIconSize, kTopBarIconSize);
        CGFloat textX = groupX + kTopBarIconSize + starGap;
        labelFrame = CGRectMake(textX, 0.0, textWidth, CGRectGetHeight(chromeFrame));
        labelCenter = CGPointMake(CGRectGetMidX(labelFrame), CGRectGetMidY(labelFrame));
        // Ganzer Adressbereich zwischen Tab-Knopf und Kreisel ist wählbar (wie Safaris Adressfeld), nicht nur
        // rechts vom Stern. Der Stern bleibt trotzdem treffbar: Beim Einrasten gewinnt das kleinste Ziel.
        self.URLTargetFrame = CGRectMake(labelOriginX, 0.0, MAX(120.0, labelTrailingX - labelOriginX), CGRectGetHeight(chromeFrame));
    } else {
        self.homeImageView.center = labelCenter;
    }
    self.URLLabel.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(labelFrame), CGRectGetHeight(labelFrame));
    self.URLLabel.center = labelCenter;
    self.URLLabel.transform = self.compact ? CGAffineTransformMakeScale(kTopBarCompactLabelScale, kTopBarCompactLabelScale)
                                           : CGAffineTransformIdentity;

    [self layoutAddressEditingViewsInChromeFrame:chromeFrame];

    self.backFocusButton.frame = [self focusFrameForIconView:self.backImageView];
    self.refreshFocusButton.frame = [self focusFrameForIconView:self.refreshImageView];
    self.forwardFocusButton.frame = [self focusFrameForIconView:self.forwardImageView];
    self.homeFocusButton.frame = [self focusFrameForIconView:self.homeImageView];
    self.tabsFocusButton.frame = [self focusFrameForIconView:self.tabsImageView];
    self.URLFocusButton.frame = [self uniformFocusFrameForRect:self.URLTargetFrame horizontalInset:0.0];
    self.fullscreenFocusButton.frame = [self focusFrameForIconView:self.fullscreenImageView];
    self.menuFocusButton.frame = [self focusFrameForMenuIconView:self.menuImageView];
    self.readerFocusButton.frame = [self focusFrameForIconView:self.readerImageView];
    [self updateReaderFocusButtonAvailability];

    if (!self.focusModeActive) {
        [self resetFocusVisualState];
        return;
    }

    [self updateHighlightFrameForCurrentFocus];
}

- (CGRect)interactiveFrameForView:(UIView *)view {
    return [self convertRect:view.bounds fromView:view];
}

- (void)enumeratePointerTargetsUsingBlock:(void (^)(CGRect frame, BrowserTopBarAction action))block {
    if (block == nil || self.hidden) {
        return;
    }
    if (self.addressEditing) {
        // Bearbeiten-Zustand: nur das Diktierfeld.
        block(self.addressFieldFrame, BrowserTopBarActionURL);
        return;
    }
    if (self.compact) {
        // Die ganze Kapsel ist ein Ziel; ein Klick klappt die Leiste wieder auf.
        block(self.chromeContainerView.frame, BrowserTopBarActionURL);
        return;
    }
    NSArray *items = @[
        @[self.backImageView, @(BrowserTopBarActionBack)],
        @[self.refreshImageView, @(BrowserTopBarActionRefresh)],
        @[self.forwardImageView, @(BrowserTopBarActionForward)],
        @[self.homeImageView, @(self.classicDesign ? BrowserTopBarActionHome : BrowserTopBarActionFavorite)],
        @[self.tabsImageView, @(BrowserTopBarActionTabs)],
        @[self.URLLabel, @(BrowserTopBarActionURL)],
        @[self.fullscreenImageView, @(BrowserTopBarActionFullscreen)],
        @[self.menuImageView, @(BrowserTopBarActionMenu)],
        @[self.readerImageView, @(BrowserTopBarActionReader)],
    ];
    for (NSArray *item in items) {
        UIView *view = item[0];
        if (view.hidden || view.alpha < 0.05 || view.window == nil) {
            continue;
        }
        CGRect frame = view == self.URLLabel ? [self convertRect:self.URLTargetFrame fromView:self.chromeEffectView.contentView]
                                             : [self interactiveFrameForView:view];
        // Kleine Symbole auf eine gut treffbare Mindestgröße bringen.
        CGFloat growX = MAX(0.0, (64.0 - CGRectGetWidth(frame)) / 2.0);
        CGFloat growY = MAX(0.0, (64.0 - CGRectGetHeight(frame)) / 2.0);
        block(CGRectInset(frame, -growX, -growY), (BrowserTopBarAction)[item[1] integerValue]);
    }
}

- (CGRect)uniformFocusFrameForRect:(CGRect)frame horizontalInset:(CGFloat)horizontalInset {
    CGFloat normalizedHeight = MIN(kTopBarUniformFocusHeight, CGRectGetHeight(self.chromeEffectView.bounds));
    CGFloat originY = floor((CGRectGetHeight(self.chromeEffectView.bounds) - normalizedHeight) / 2.0);
    frame.origin.x -= horizontalInset;
    frame.size.width += horizontalInset * 2.0;
    frame.origin.y = originY;
    frame.size.height = normalizedHeight;
    return CGRectIntegral(frame);
}

- (CGRect)focusFrameForIconView:(UIView *)view {
    CGRect frame = view.frame;
    return [self uniformFocusFrameForRect:frame horizontalInset:12.0];
}

- (CGRect)focusFrameForMenuIconView:(UIView *)view {
    return [self focusFrameForIconView:view];
}

- (CGRect)focusFrameForLabel:(UIView *)view {
    CGRect frame = view.frame;
    return [self uniformFocusFrameForRect:frame horizontalInset:16.0];
}

- (CGRect)highlightFrameForButton:(BrowserTopBarFocusButton *)button {
    CGRect frame = button.frame;
    frame = CGRectInset(frame, kTopBarFocusHighlightInset, 0.0);
    return CGRectIntegral(frame);
}

- (CGRect)glowFrameForButton:(BrowserTopBarFocusButton *)button {
    CGRect frame = [self highlightFrameForButton:button];
    return CGRectInset(frame, -4.0, -4.0);
}

- (void)ensureFocusGlowViewAttached {
    if (self.focusGlowView.superview == self.chromeContainerView) {
        return;
    }
    [self.focusGlowView removeFromSuperview];
    [self.chromeContainerView insertSubview:self.focusGlowView belowSubview:self.chromeEffectView];
}

- (void)resetFocusVisualState {
    [self.focusGlowView.layer removeAllAnimations];
    [self.focusHighlightView.layer removeAllAnimations];
    self.focusGlowView.hidden = YES;
    self.focusGlowView.alpha = 0.0;
    self.focusGlowView.frame = CGRectZero;
    self.focusGlowView.layer.shadowOpacity = 0.0;
    self.focusGlowView.layer.shadowPath = nil;

    self.focusHighlightView.hidden = YES;
    self.focusHighlightView.alpha = 0.0;
    self.focusHighlightView.frame = CGRectZero;

    [self.focusGlowView removeFromSuperview];
    [self.layer setNeedsDisplay];
}

- (void)updateHighlightFrameForCurrentFocus {
    if (!self.focusModeActive || self.lastFocusedButton == nil || !self.lastFocusedButton.focused) {
        return;
    }
    [self ensureFocusGlowViewAttached];
    CGRect glowFrame = [self glowFrameForButton:self.lastFocusedButton];
    self.focusGlowView.hidden = NO;
    self.focusGlowView.alpha = 1.0;
    self.focusGlowView.frame = glowFrame;
    self.focusGlowView.layer.cornerRadius = MIN(CGRectGetHeight(glowFrame) / 2.0, 24.0);
    self.focusGlowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.focusGlowView.bounds
                                                                     cornerRadius:self.focusGlowView.layer.cornerRadius].CGPath;
    self.focusGlowView.layer.shadowOpacity = 0.78;
    self.focusHighlightView.hidden = YES;
    self.focusHighlightView.alpha = 0.0;
    self.focusHighlightView.frame = CGRectZero;
}

- (void)setFocusModeActive:(BOOL)focusModeActive {
    if (_focusModeActive == focusModeActive) {
        return;
    }

    _focusModeActive = focusModeActive;
    if (focusModeActive) {
        [self setCompact:NO animated:YES];
    }
    [self updateFocusButtonAvailability];

    if (!focusModeActive) {
        self.lastFocusedButton = nil;
        [self resetFocusVisualState];
    } else {
        [self setNeedsLayout];
    }
}

/// Welche Knöpfe im Fokusmodus wählbar sind: der Vollbild-Knopf nur im alten Design, Reader nur, wenn lesbar.
- (void)updateFocusButtonAvailability {
    for (BrowserTopBarFocusButton *button in self.focusButtons) {
        BOOL available = self.focusModeActive && (button != self.fullscreenFocusButton || self.classicDesign) &&
            (button != self.readerFocusButton || self.readerAvailable);
        button.hidden = !available;
        button.enabled = available;
    }
}

/// Der Reader-Knopf nimmt am Fokus nur teil, wenn er sichtbar ist.
- (void)updateReaderFocusButtonAvailability {
    BOOL available = self.focusModeActive && self.readerAvailable && !self.compact;
    self.readerFocusButton.hidden = !available;
    self.readerFocusButton.enabled = available;
}

- (UIView *)preferredFocusItem {
    if (!self.focusModeActive) {
        return nil;
    }
    return self.lastFocusedButton ?: self.URLFocusButton;
}

- (void)handleFocusButtonPrimaryAction:(BrowserTopBarFocusButton *)button {
    id<BrowserTopBarViewDelegate> delegate = self.delegate;
    if (delegate == nil) {
        return;
    }
    [delegate browserTopBarView:self didTriggerAction:button.topBarAction];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];

    BrowserTopBarFocusButton *nextFocusedButton = [context.nextFocusedView isKindOfClass:[BrowserTopBarFocusButton class]] ? (BrowserTopBarFocusButton *)context.nextFocusedView : nil;
    BrowserTopBarFocusButton *previousFocusedButton = [context.previouslyFocusedView isKindOfClass:[BrowserTopBarFocusButton class]] ? (BrowserTopBarFocusButton *)context.previouslyFocusedView : nil;

    if (nextFocusedButton != nil) {
        self.lastFocusedButton = nextFocusedButton;
    }

    [coordinator addCoordinatedAnimations:^{
        if (!self.focusModeActive || nextFocusedButton == nil) {
            self.focusGlowView.alpha = 0.0;
            self.focusGlowView.layer.shadowOpacity = 0.0;
            self.focusHighlightView.alpha = 0.0;
            return;
        }

        [self ensureFocusGlowViewAttached];
        CGRect glowFrame = [self glowFrameForButton:nextFocusedButton];
        self.focusGlowView.hidden = NO;
        self.focusGlowView.alpha = 1.0;
        self.focusGlowView.frame = glowFrame;
        self.focusGlowView.layer.cornerRadius = MIN(CGRectGetHeight(glowFrame) / 2.0, 24.0);
        self.focusGlowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.focusGlowView.bounds
                                                                         cornerRadius:self.focusGlowView.layer.cornerRadius].CGPath;
        self.focusGlowView.layer.shadowRadius = 18.0;
        self.focusGlowView.layer.shadowOpacity = 0.78;
        self.focusHighlightView.hidden = YES;
        self.focusHighlightView.alpha = 0.0;
        self.focusHighlightView.frame = CGRectZero;
        previousFocusedButton.alpha = 1.0;
        nextFocusedButton.alpha = 1.0;
    } completion:^{
        if (!self.focusModeActive || nextFocusedButton == nil) {
            [self resetFocusVisualState];
        }
    }];
}

#pragma mark - Adresse bearbeiten (Diktierfeld)

- (void)setUpAddressEditingViews {
    self.dictationFieldView = [[UIView alloc] initWithFrame:CGRectZero];
    self.dictationFieldView.userInteractionEnabled = NO;
    self.dictationFieldView.layer.cornerCurve = kCACornerCurveContinuous;
    self.dictationFieldView.alpha = 0.0;
    [self.chromeEffectView.contentView addSubview:self.dictationFieldView];

    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
    UIImage *mic = [[UIImage systemImageNamed:@"mic.fill" withConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.dictationIconView = [[UIImageView alloc] initWithImage:mic];
    self.dictationIconView.contentMode = UIViewContentModeCenter;
    [self.dictationFieldView addSubview:self.dictationIconView];

    self.dictationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.dictationLabel.text = BLS(@"Sprechen, um zu diktieren");
    self.dictationLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.dictationFieldView addSubview:self.dictationLabel];
    [self applyAddressEditingStyle];
}

- (void)applyAddressEditingStyle {
    UIColor *foreground = self.lightPage ? [UIColor colorWithWhite:0.08 alpha:1.0] : UIColor.whiteColor;
    // Dezent: Platzhalter und Mikrofon halb transparent, das Feld selbst nur leicht abgesetzt.
    self.dictationIconView.tintColor = [foreground colorWithAlphaComponent:0.7];
    self.dictationLabel.textColor = [foreground colorWithAlphaComponent:0.55];
    self.dictationFieldView.backgroundColor = self.lightPage ? [UIColor colorWithWhite:0.0 alpha:0.06] : [UIColor colorWithWhite:1.0 alpha:0.09];
}

- (CGRect)addressFieldFrame {
    if (!self.addressEditing) {
        return CGRectNull;
    }
    return [self convertRect:self.dictationFieldView.frame fromView:self.chromeEffectView.contentView];
}

- (void)layoutAddressEditingViewsInChromeFrame:(CGRect)chromeFrame {
    CGFloat inset = 10.0;
    CGRect field = CGRectInset(CGRectMake(0.0, 0.0, CGRectGetWidth(chromeFrame), CGRectGetHeight(chromeFrame)), inset, inset);
    self.dictationFieldView.frame = field;
    self.dictationFieldView.layer.cornerRadius = CGRectGetHeight(field) / 2.0;
    CGSize iconSize = CGSizeMake(44.0, CGRectGetHeight(field));
    CGFloat gap = 14.0;
    CGFloat textWidth = ceil([self.dictationLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGRectGetHeight(field))].width);
    textWidth = MIN(textWidth, CGRectGetWidth(field) - iconSize.width - gap - 40.0);
    CGFloat groupX = floor((CGRectGetWidth(field) - iconSize.width - gap - textWidth) / 2.0);
    self.dictationIconView.frame = CGRectMake(groupX, 0.0, iconSize.width, iconSize.height);
    self.dictationLabel.frame = CGRectMake(groupX + iconSize.width + gap, 0.0, textWidth, CGRectGetHeight(field));

    if (!self.addressEditing) {
        self.dictationFieldView.alpha = 0.0;
        return;
    }
    // Bearbeiten: alles andere aus, nur das Diktierfeld bleibt.
    self.dictationFieldView.alpha = 1.0;
    for (UIView *view in @[self.backImageView, self.refreshImageView, self.forwardImageView, self.homeImageView,
                           self.tabsImageView, self.fullscreenImageView, self.menuImageView, self.URLLabel, self.loadingSpinner,
                           self.readerImageView, self.readerHighlightView]) {
        view.alpha = 0.0;
    }
}

- (void)setAddressEditing:(BOOL)addressEditing animated:(BOOL)animated {
    if (_addressEditing == addressEditing) {
        return;
    }
    if (addressEditing && self.compact) {
        _compact = NO;
    }
    _addressEditing = addressEditing;
    if (!addressEditing) {
        // Seitenname und Knöpfe zurück (layoutSubviews setzt die Symbole, Name und Kreisel brauchen es hier).
        self.URLLabel.alpha = 1.0;
        self.loadingSpinner.alpha = 1.0;
    }
    if (!animated) {
        [self setNeedsLayout];
        [self layoutIfNeeded];
        return;
    }
    // Gleiche Bewegung wie kompakt ↔ voll, inklusive Schattenumriss (beim Bearbeiten klappt die Kapsel auf).
    [self animateChromeLayoutAlongside:^{
        if (!addressEditing) {
            self.URLLabel.alpha = 1.0;
            self.loadingSpinner.alpha = 1.0;
        }
    }];
}

#pragma mark - Altes Design

- (void)userDefaultsDidChange:(__unused NSNotification *)notification {
    // Die Meldung kann von einem anderen Thread kommen; nur bei echtem Wechsel neu aufbauen.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (BrowserMotion.classicDesignEnabled != self.classicDesign) {
            [self applyDesign];
        }
    });
}

- (void)applyDesign {
    self.classicDesign = BrowserMotion.classicDesignEnabled;
#if DEBUG
    NSLog(@"[TopBar] Design %@", self.classicDesign ? @"alt" : @"Liquid Glass");
#endif
    if (self.classicDesign) {
        _compact = NO;
        [self.progressView.layer removeAllAnimations];
        self.progressVisible = NO;
        self.loadingProgress = 0.0;
        self.progressView.alpha = 0.0;
    }
    [self applyIconImages];
    [self applyClassicFocusActions];
    [self applyVisualStyle];
    // Vordergrund, Titel und Stern hängen am Design und an der Seitenfarbe: mit der gemerkten Farbe neu berechnen.
    [self setPageBackgroundColor:self.pageColor];
    if (@available(tvOS 26.0, *)) {
        UIScrollEdgeElementContainerInteraction *interaction = self.scrollEdgeInteraction;
        interaction.scrollView.topEdgeEffect.hidden = self.classicDesign;
    }
    [self updateFocusButtonAvailability];
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

/// Symbole je Design: alt = die weißen Bilder des Originals (Icons/MenuIcons), sonst SF Symbols wie in Safari.
- (void)applyIconImages {
    BOOL classic = self.classicDesign;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
    void (^apply)(UIImageView *, NSString *, NSString *) = ^(UIImageView *imageView, NSString *symbolName, NSString *imageName) {
        UIImage *image = classic ? [UIImage imageNamed:imageName] : [UIImage systemImageNamed:symbolName withConfiguration:configuration];
        if (image == nil) {
            image = classic ? [UIImage systemImageNamed:symbolName withConfiguration:configuration] : [UIImage imageNamed:imageName];
        }
        imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        // Die Originalbilder sind 240 px groß und werden in die 52-pt-Fläche eingepasst.
        imageView.contentMode = classic ? UIViewContentModeScaleAspectFit : UIViewContentModeCenter;
    };
    apply(self.backImageView, @"chevron.backward", @"go-back-left-arrow");
    apply(self.refreshImageView, @"arrow.clockwise", @"refresh-button");
    apply(self.forwardImageView, @"chevron.forward", @"right-arrow-forward");
    apply(self.tabsImageView, @"square.on.square", @"multi-tab");
    apply(self.fullscreenImageView, @"arrow.up.left.and.arrow.down.right", @"resize-arrows");
    apply(self.menuImageView, @"ellipsis.circle", @"menu-2");
    if (classic) {
        apply(self.homeImageView, @"house", @"house-outline");
    } else {
        self.homeImageView.contentMode = UIViewContentModeCenter;
    }
    // Reader gab es im Original nicht: im alten Design ein kräftigeres Symbol, passend zu den dicken Originalbildern.
    UIImageSymbolConfiguration *readerConfiguration = classic
        ? [UIImageSymbolConfiguration configurationWithPointSize:36.0 weight:UIImageSymbolWeightBold]
        : configuration;
    UIImage *reader = [UIImage systemImageNamed:@"doc.plaintext" withConfiguration:readerConfiguration]
        ?: [UIImage systemImageNamed:@"text.page" withConfiguration:readerConfiguration];
    if (reader != nil) {
        self.readerImageView.image = [reader imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    [self applyFavoriteStyle];
}

/// Der Knopf neben „Vor“ ist im alten Design „Startseite“, sonst der Favoriten-Stern.
- (void)applyClassicFocusActions {
    self.homeFocusButton.topBarAction = self.classicDesign ? BrowserTopBarActionHome : BrowserTopBarActionFavorite;
    self.homeFocusButton.accessibilityLabel = self.classicDesign ? BLS(@"Startseite") : BLS(@"Favorit");
}

@end
