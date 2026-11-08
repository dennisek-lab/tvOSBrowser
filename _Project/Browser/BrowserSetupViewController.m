#import "BrowserSetupViewController.h"
#import <objc/runtime.h>
#import "BrowserDNSProxy.h"
#import "BrowserHistoryStore.h"
#import "BrowserMotion.h"
#import "BrowserPreferencesStore.h"
#import "BrowserShape.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

typedef NS_ENUM(NSInteger, BrowserSetupPage) {
    BrowserSetupPageWelcome = 0,
    BrowserSetupPageFavorites,
    BrowserSetupPageHome,
    BrowserSetupPageProtection,
    BrowserSetupPageVideo,
    BrowserSetupPageDesign,
    BrowserSetupPageCount,
};

static NSString * const kSetupGoogleURL = @"https://www.google.com";
static const NSUInteger kSetupMaxCustomFavorites = 7;
static const NSUInteger kSetupGridColumns = 4;

@interface BrowserSetupViewController ()
@property (nonatomic, strong) UIVisualEffectView *cardView;
@property (nonatomic, strong) UILabel *stepLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIView *bodyContainer;
@property (nonatomic, strong) UIStackView *buttonRow;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, weak) UIView *preferredFocusView;
/// Auswählbare Elemente des aktuellen Schritts in Bildschirmreihenfolge (für den Selbsttest).
@property (nonatomic, strong) NSMutableArray<UIButton *> *optionButtons;

@property (nonatomic) BrowserSetupPage page;
/// Gewählte Favoriten als @[URL, Name], in Auswahlreihenfolge.
@property (nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *favorites;
/// Eigene Adressen (nicht aus den Vorschlägen), als @[URL, Name].
@property (nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *customFavorites;
/// Startseite; leer = Google.
@property (nonatomic, copy) NSString *homePageURLString;
@property (nonatomic, copy) NSString *initialHomePageURLString;
@property (nonatomic) BOOL adBlock;
@property (nonatomic) BOOL cloudflareDNS;
@property (nonatomic) BOOL cookieBanner;
@property (nonatomic) BOOL autoSubtitles;
@property (nonatomic) BOOL webSubtitles;
@property (nonatomic) BOOL nativePlayer;
@property (nonatomic) BOOL classicDesign;
@end

@implementation BrowserSetupViewController

/// Vorschläge für Favoriten (@[URL, Name]). Nichts ist vorausgewählt.
+ (NSArray<NSArray<NSString *> *> *)suggestions {
    return @[
        @[@"https://www.youtube.com", @"YouTube"],
        @[@"https://de.wikipedia.org", @"Wikipedia"],
        @[@"https://www.tagesschau.de", @"tagesschau"],
        @[@"https://www.ardmediathek.de", @"ARD Mediathek"],
        @[@"https://www.zdf.de", @"ZDF"],
        @[@"https://www.arte.tv/de/", @"ARTE"],
        @[@"https://www.spiegel.de", @"SPIEGEL"],
        @[@"https://www.heise.de", @"heise online"],
        @[@"https://www.computerbase.de", @"ComputerBase"],
        @[@"https://www.twitch.tv", @"Twitch"],
        @[@"https://www.reddit.com", @"Reddit"],
        @[@"https://www.wetter.com", @"wetter.com"],
    ];
}

+ (nullable NSString *)hostKeyForURLString:(NSString *)URLString {
    NSURL *url = [NSURL URLWithString:URLString];
    return url != nil ? [BrowserHistoryStore hostKeyForURL:url] : nil;
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self loadCurrentSettings];
    }
    return self;
}

/// Vorbelegung: aktuelle Werte. Bei einer frischen Installation sind alle Schalter an (Vorgaben),
/// Favoriten leer und die Startseite Google. Wer die App schon nutzt, sieht seine bisherige Wahl.
- (void)loadCurrentSettings {
    BrowserPreferencesStore *store = [BrowserPreferencesStore new];
    BOOL freshInstall = [NSUserDefaults.standardUserDefaults objectForKey:@"WhatsNewSeenVersion"] == nil;
    self.favorites = [NSMutableArray array];
    self.customFavorites = [NSMutableArray array];
    NSMutableSet<NSString *> *suggestionHosts = [NSMutableSet set];
    for (NSArray<NSString *> *suggestion in [BrowserSetupViewController suggestions]) {
        NSString *host = [BrowserSetupViewController hostKeyForURLString:suggestion[0]];
        if (host != nil) {
            [suggestionHosts addObject:host];
        }
    }
    for (BrowserSiteEntry *entry in [BrowserHistoryStore sharedStore].favorites) {
        if (entry.urlString.length == 0) {
            continue;
        }
        NSArray<NSString *> *item = @[entry.urlString, entry.name.length > 0 ? entry.name : entry.host];
        [self.favorites addObject:item];
        if (![suggestionHosts containsObject:entry.host] && self.customFavorites.count < kSetupMaxCustomFavorites) {
            [self.customFavorites addObject:item];
        }
    }
    self.homePageURLString = store.homePageURLString ?: @"";
    self.initialHomePageURLString = self.homePageURLString;
    self.adBlock = store.adBlockEnabled;
    self.cloudflareDNS = BrowserDNSProxy.isEnabled;
    self.cookieBanner = store.cookieBannerBlockEnabled;
    // Neu installiert: alles an (Wunsch: alle Optionen standardmäßig aktiviert).
    self.autoSubtitles = freshInstall ? YES : store.autoSubtitlesEnabled;
    self.webSubtitles = freshInstall ? YES : store.webSubtitlesEnabled;
    self.nativePlayer = store.autoOpenVideosInNativePlayer;
    self.classicDesign = store.classicDesignEnabled;
}

#pragma mark - Aufbau

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.alpha = 0.95;
    [self.view addSubview:backdrop];

    UIVisualEffect *cardEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        cardEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    }
#endif
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:cardEffect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.clipsToBounds = YES;
    BrowserShapeApply(card.layer, BrowserShapeCardRadius);
    [self.view addSubview:card];
    self.cardView = card;

    self.stepLabel = [self labelWithSize:24.0 weight:UIFontWeightSemibold alpha:0.55];
    self.titleLabel = [self labelWithSize:52.0 weight:UIFontWeightBold alpha:1.0];
    self.subtitleLabel = [self labelWithSize:30.0 weight:UIFontWeightRegular alpha:0.75];
    self.subtitleLabel.numberOfLines = 0;

    self.bodyContainer = [[UIView alloc] init];
    self.bodyContainer.translatesAutoresizingMaskIntoConstraints = NO;

    self.buttonRow = [[UIStackView alloc] init];
    self.buttonRow.axis = UILayoutConstraintAxisHorizontal;
    self.buttonRow.spacing = 32.0;
    self.buttonRow.distribution = UIStackViewDistributionFillEqually;
    self.buttonRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[self.stepLabel, self.titleLabel, self.subtitleLabel, self.bodyContainer, self.buttonRow]];
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 14.0;
    [content setCustomSpacing:40.0 afterView:self.subtitleLabel];
    [content setCustomSpacing:44.0 afterView:self.bodyContainer];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:content];

    CGFloat inset = BrowserShapeCardInset;
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:1500.0],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor constant:-60.0],
        [content.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:inset + 6.0],
        [content.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-inset],
        [content.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:inset],
        [content.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-inset],
        [self.subtitleLabel.widthAnchor constraintLessThanOrEqualToAnchor:content.widthAnchor constant:-120.0],
        [self.bodyContainer.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-60.0],
        [self.buttonRow.widthAnchor constraintEqualToConstant:820.0],
    ]];

    [self showPage:BrowserSetupPageWelcome animated:NO];
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight alpha:(CGFloat)alpha {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:alpha];
    label.textAlignment = NSTextAlignmentCenter;
    return label;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (animated) {
        [BrowserMotion presentCard:self.cardView glassEffect:self.cardView.effect];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (animated) {
        [BrowserMotion dismissCard:self.cardView];
    }
}

#pragma mark - Schritte

- (void)showPage:(BrowserSetupPage)page animated:(BOOL)animated {
    self.page = page;
    self.optionButtons = [NSMutableArray array];
    self.preferredFocusView = nil;

    void (^rebuild)(void) = ^{
        for (UIView *subview in self.bodyContainer.subviews) {
            [subview removeFromSuperview];
        }
        for (UIView *subview in self.buttonRow.arrangedSubviews) {
            [self.buttonRow removeArrangedSubview:subview];
            [subview removeFromSuperview];
        }
        self.stepLabel.text = page == BrowserSetupPageWelcome ? @"Einrichtung" : [NSString stringWithFormat:@"Schritt %ld von %ld", (long)page, (long)(BrowserSetupPageCount - 1)];
        UIView *body = [self buildBodyForPage:page];
        body.translatesAutoresizingMaskIntoConstraints = NO;
        [self.bodyContainer addSubview:body];
        [NSLayoutConstraint activateConstraints:@[
            [body.topAnchor constraintEqualToAnchor:self.bodyContainer.topAnchor],
            [body.bottomAnchor constraintEqualToAnchor:self.bodyContainer.bottomAnchor],
            [body.leadingAnchor constraintEqualToAnchor:self.bodyContainer.leadingAnchor],
            [body.trailingAnchor constraintEqualToAnchor:self.bodyContainer.trailingAnchor],
        ]];
        [self buildButtonsForPage:page];
        [self.view layoutIfNeeded];
    };

    if (animated) {
        [UIView transitionWithView:self.cardView.contentView
                          duration:0.25
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                        animations:rebuild
                        completion:nil];
    } else {
        rebuild();
    }
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
    NSLog(@"[Setup] Schritt %ld", (long)page);
}

- (UIView *)buildBodyForPage:(BrowserSetupPage)page {
    switch (page) {
        case BrowserSetupPageWelcome: return [self welcomeBody];
        case BrowserSetupPageFavorites: return [self favoritesBody];
        case BrowserSetupPageHome: return [self homeBody];
        case BrowserSetupPageProtection: return [self protectionBody];
        case BrowserSetupPageVideo: return [self videoBody];
        case BrowserSetupPageDesign: return [self designBody];
        default: return [UIView new];
    }
}

- (void)buildButtonsForPage:(BrowserSetupPage)page {
    __weak typeof(self) weakSelf = self;
    UIButton *back;
    if (page == BrowserSetupPageWelcome) {
        back = [self buttonWithTitle:@"Überspringen" handler:^{ [weakSelf finish]; }];
    } else {
        back = [self buttonWithTitle:@"Zurück" handler:^{ [weakSelf goBack]; }];
    }
    NSString *nextTitle = page == BrowserSetupPageWelcome ? @"Einrichten" : (page == BrowserSetupPageDesign ? @"Fertig" : @"Weiter");
    self.nextButton = [self buttonWithTitle:nextTitle handler:^{ [weakSelf goForward]; }];
    [self.buttonRow addArrangedSubview:back];
    [self.buttonRow addArrangedSubview:self.nextButton];
    if (self.preferredFocusView == nil) {
        self.preferredFocusView = self.nextButton;
    }
}

- (void)goForward {
    if (self.page >= BrowserSetupPageDesign) {
        [self finish];
        return;
    }
    [self showPage:self.page + 1 animated:YES];
}

- (void)goBack {
    if (self.page > BrowserSetupPageWelcome) {
        [self showPage:self.page - 1 animated:YES];
    }
}

#pragma mark - Inhalte

- (UIView *)welcomeBody {
    self.titleLabel.text = @"Willkommen";
    self.subtitleLabel.text = @"In ein paar Schritten richtest du den Browser ein.\nAlles lässt sich später in der Seitenleiste ändern.";
    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 18.0;
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"star", @"Favoriten", @"Seiten, die du oft besuchst"],
        @[@"house", @"Startseite", @"Was beim Öffnen der App erscheint"],
        @[@"checkmark.shield", @"Schutz", @"Werbeblocker, Cloudflare-DNS, Cookie-Banner"],
        @[@"captions.bubble", @"Videos", @"Automatische Untertitel und Apple-Player"],
        @[@"paintbrush", @"Design", @"Liquid Glass oder das alte Design"],
    ];
    for (NSArray<NSString *> *item in items) {
        [rows addArrangedSubview:[self infoRowWithSymbol:item[0] title:item[1] text:item[2]]];
    }
    UIView *wrapper = [UIView new];
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
        [rows.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
        [rows.centerXAnchor constraintEqualToAnchor:wrapper.centerXAnchor],
        [rows.widthAnchor constraintEqualToConstant:820.0],
    ]];
    return wrapper;
}

- (UIView *)favoritesBody {
    self.titleLabel.text = @"Favoriten";
    self.subtitleLabel.text = @"Welche Seiten willst du über diesen Browser öfter besuchen?";
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIButton *> *cells = [NSMutableArray array];
    NSMutableArray<NSArray<NSString *> *> *items = [[BrowserSetupViewController suggestions] mutableCopy];
    [items addObjectsFromArray:self.customFavorites];
    for (NSArray<NSString *> *item in items) {
        UIButton *button = [self optionButtonWithTitle:item[1] subtitle:nil symbolOn:@"checkmark.circle.fill" symbolOff:@"circle" selected:[self isFavorite:item[0]] handler:nil];
        __weak UIButton *weakButton = button;
        [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            BOOL nowSelected = [weakSelf toggleFavorite:item];
            [weakSelf setOptionButton:weakButton selected:nowSelected];
        }] forControlEvents:UIControlEventPrimaryActionTriggered];
        [cells addObject:button];
    }
    if (self.customFavorites.count < kSetupMaxCustomFavorites) {
        UIButton *add = [self optionButtonWithTitle:@"Eigene Seite" subtitle:nil symbolOn:@"plus.circle" symbolOff:@"plus.circle" selected:NO handler:^{
            [weakSelf promptForAddressWithTitle:@"Favorit hinzufügen" completion:^(NSString *URLString) {
                [weakSelf addCustomFavoriteWithURLString:URLString];
            }];
        }];
        [cells addObject:add];
    }
    self.preferredFocusView = cells.firstObject;
    return [self gridWithButtons:cells];
}

- (UIView *)homeBody {
    self.titleLabel.text = @"Startseite";
    self.subtitleLabel.text = @"Welche Seite soll beim Starten der App als Erstes geöffnet werden?";
    __weak typeof(self) weakSelf = self;
    NSMutableArray<NSArray<NSString *> *> *items = [NSMutableArray arrayWithObject:@[kSetupGoogleURL, @"Google"]];
    NSMutableSet<NSString *> *hosts = [NSMutableSet setWithObject:@"google.com"];
    for (NSArray<NSString *> *favorite in self.favorites) {
        NSString *host = [BrowserSetupViewController hostKeyForURLString:favorite[0]];
        if (host != nil && ![hosts containsObject:host]) {
            [hosts addObject:host];
            [items addObject:favorite];
        }
    }
    // Eigene Startseite, die weder Google noch ein Favorit ist.
    NSString *currentHost = [BrowserSetupViewController hostKeyForURLString:self.homePageURLString];
    if (self.homePageURLString.length > 0 && currentHost != nil && ![hosts containsObject:currentHost]) {
        [items addObject:@[self.homePageURLString, currentHost]];
    }
    NSMutableArray<UIButton *> *cells = [NSMutableArray array];
    for (NSArray<NSString *> *item in items) {
        BOOL selected = [self homePageMatches:item[0]];
        UIButton *button = [self optionButtonWithTitle:item[1] subtitle:nil symbolOn:@"largecircle.fill.circle" symbolOff:@"circle" selected:selected handler:^{
            weakSelf.homePageURLString = [item[0] isEqualToString:kSetupGoogleURL] ? @"" : item[0];
            [weakSelf refreshSelectionOnHomePage];
        }];
        button.accessibilityIdentifier = item[0];
        [cells addObject:button];
        if (selected) {
            self.preferredFocusView = button;
        }
    }
    UIButton *other = [self optionButtonWithTitle:@"Andere Seite" subtitle:nil symbolOn:@"keyboard" symbolOff:@"keyboard" selected:NO handler:^{
        [weakSelf promptForAddressWithTitle:@"Startseite" completion:^(NSString *URLString) {
            weakSelf.homePageURLString = URLString;
            [weakSelf showPage:BrowserSetupPageHome animated:NO];
        }];
    }];
    [cells addObject:other];
    if (self.preferredFocusView == nil) {
        self.preferredFocusView = cells.firstObject;
    }
    return [self gridWithButtons:cells];
}

- (void)refreshSelectionOnHomePage {
    for (UIButton *button in self.optionButtons) {
        if (button.accessibilityIdentifier.length > 0) {
            [self setOptionButton:button selected:[self homePageMatches:button.accessibilityIdentifier]];
        }
    }
}

- (BOOL)homePageMatches:(NSString *)URLString {
    if ([URLString isEqualToString:kSetupGoogleURL]) {
        NSString *host = [BrowserSetupViewController hostKeyForURLString:self.homePageURLString];
        return self.homePageURLString.length == 0 || [host isEqualToString:@"google.com"];
    }
    return [self.homePageURLString isEqualToString:URLString];
}

- (UIView *)protectionBody {
    self.titleLabel.text = @"Schutz";
    self.subtitleLabel.text = @"Was soll der Browser für dich abwehren?";
    __weak typeof(self) weakSelf = self;
    return [self toggleListWithItems:@[
        @[@"Werbeblocker", @"Blendet Werbung und Tracker aus (Filterlisten von uBlock Origin Lite).", ^BOOL{ return weakSelf.adBlock; }, ^{ weakSelf.adBlock = !weakSelf.adBlock; }],
        @[@"Cloudflare-DNS", @"Für freies Internet: verschlüsselte Namensauflösung über Cloudflare statt über den Anbieter, DNS-Sperren greifen nicht.", ^BOOL{ return weakSelf.cloudflareDNS; }, ^{ weakSelf.cloudflareDNS = !weakSelf.cloudflareDNS; }],
        @[@"Cookie-Banner ablehnen", @"Lehnt Cookie-Banner automatisch ab, soweit es die Seite zulässt.", ^BOOL{ return weakSelf.cookieBanner; }, ^{ weakSelf.cookieBanner = !weakSelf.cookieBanner; }],
    ]];
}

- (UIView *)videoBody {
    self.titleLabel.text = @"Videos";
    self.subtitleLabel.text = @"Wie sollen Videos abgespielt werden?";
    __weak typeof(self) weakSelf = self;
    return [self toggleListWithItems:@[
        @[@"Videos im Apple-Player", @"Videos öffnen sich im Player von tvOS, mit Bild-in-Bild und Steuerung über das iPhone.", ^BOOL{ return weakSelf.nativePlayer; }, ^{ weakSelf.nativePlayer = !weakSelf.nativePlayer; }],
        @[@"Automatische Untertitel", @"Erzeugt im Apple-Player Untertitel auf dem Gerät, wenn ein Video keine hat.", ^BOOL{ return weakSelf.autoSubtitles; }, ^{ weakSelf.autoSubtitles = !weakSelf.autoSubtitles; }],
        @[@"Untertitel in der Webseite", @"Auch für Videos, die in der Seite laufen. Braucht etwas mehr Leistung.", ^BOOL{ return weakSelf.webSubtitles; }, ^{ weakSelf.webSubtitles = !weakSelf.webSubtitles; }],
    ]];
}

- (UIView *)designBody {
    self.titleLabel.text = @"Design";
    self.subtitleLabel.text = @"Wie soll der Browser aussehen?";
    __weak typeof(self) weakSelf = self;
    UIButton *glass = [self designButtonWithSymbol:@"drop" title:@"Liquid Glass" text:@"Neues Design: Glas, federnde Animationen, leuchtende Hervorhebung." selected:!self.classicDesign handler:^{
        weakSelf.classicDesign = NO;
        [weakSelf refreshDesignSelection];
    }];
    UIButton *classic = [self designButtonWithSymbol:@"rectangle.topthird.inset.filled" title:@"Altes Design" text:@"Wie in der ursprünglichen Fassung des Browsers." selected:self.classicDesign handler:^{
        weakSelf.classicDesign = YES;
        [weakSelf refreshDesignSelection];
    }];
    glass.tag = 0;
    classic.tag = 1;
    self.preferredFocusView = self.classicDesign ? classic : glass;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[glass, classic]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 40.0;
    row.distribution = UIStackViewDistributionFillEqually;
    UIView *wrapper = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
        [row.centerXAnchor constraintEqualToAnchor:wrapper.centerXAnchor],
        [row.widthAnchor constraintEqualToConstant:1120.0],
    ]];
    return wrapper;
}

- (void)refreshDesignSelection {
    for (UIButton *button in self.optionButtons) {
        [self setOptionButton:button selected:(button.tag == 1) == self.classicDesign];
    }
}

#pragma mark - Favoriten

- (BOOL)isFavorite:(NSString *)URLString {
    NSString *host = [BrowserSetupViewController hostKeyForURLString:URLString];
    for (NSArray<NSString *> *favorite in self.favorites) {
        if ([favorite[0] isEqualToString:URLString] || (host != nil && [[BrowserSetupViewController hostKeyForURLString:favorite[0]] isEqualToString:host])) {
            return YES;
        }
    }
    return NO;
}

/// Schaltet den Favoriten um und liefert den neuen Zustand.
- (BOOL)toggleFavorite:(NSArray<NSString *> *)item {
    NSString *host = [BrowserSetupViewController hostKeyForURLString:item[0]];
    NSIndexSet *matches = [self.favorites indexesOfObjectsPassingTest:^BOOL(NSArray<NSString *> *favorite, __unused NSUInteger idx, __unused BOOL *stop) {
        return [favorite[0] isEqualToString:item[0]] || (host != nil && [[BrowserSetupViewController hostKeyForURLString:favorite[0]] isEqualToString:host]);
    }];
    if (matches.count > 0) {
        [self.favorites removeObjectsAtIndexes:matches];
        // Abgewählte Startseite fällt auf Google zurück.
        if ([self homePageMatches:item[0]] && ![item[0] isEqualToString:kSetupGoogleURL]) {
            self.homePageURLString = @"";
        }
        return NO;
    }
    [self.favorites addObject:item];
    return YES;
}

- (void)addCustomFavoriteWithURLString:(NSString *)URLString {
    NSString *host = [BrowserSetupViewController hostKeyForURLString:URLString];
    if (host == nil) {
        return;
    }
    NSArray<NSString *> *item = @[URLString, host];
    BOOL known = NO;
    for (NSArray<NSString *> *suggestion in [[BrowserSetupViewController suggestions] arrayByAddingObjectsFromArray:self.customFavorites]) {
        if ([[BrowserSetupViewController hostKeyForURLString:suggestion[0]] isEqualToString:host]) {
            item = suggestion;
            known = YES;
            break;
        }
    }
    if (!known) {
        [self.customFavorites addObject:item];
    }
    if (![self isFavorite:item[0]]) {
        [self.favorites addObject:item];
    }
    [self showPage:BrowserSetupPageFavorites animated:NO];
}

- (void)promptForAddressWithTitle:(NSString *)title completion:(void (^)(NSString *URLString))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:@"Adresse der Seite, z. B. tagesschau.de" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.placeholder = @"z. B. tagesschau.de";
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Sichern" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *text = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length == 0) {
            return;
        }
        if ([text rangeOfString:@"://"].location == NSNotFound) {
            text = [@"https://" stringByAppendingString:text];
        }
        NSURL *url = [NSURL URLWithString:text];
        if (url.host.length == 0 || [url.host rangeOfString:@"."].location == NSNotFound) {
            return;
        }
        completion(url.absoluteString);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Bausteine

- (UIButtonConfiguration *)baseConfiguration {
    UIButtonConfiguration *config = nil;
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        config = [UIButtonConfiguration glassButtonConfiguration];
    }
#endif
    if (config == nil) {
        config = [UIButtonConfiguration grayButtonConfiguration];
    }
    return config;
}

- (UIButton *)buttonWithTitle:(NSString *)title handler:(void (^)(void))handler {
    UIButtonConfiguration *config = [self baseConfiguration];
    config.title = title;
    config.contentInsets = NSDirectionalEdgeInsetsMake(20.0, 36.0, 20.0, 36.0);
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(__unused UIAction *action) { handler(); }]];
    [button.heightAnchor constraintEqualToConstant:2.0 * (BrowserShapeCardRadius - BrowserShapeCardInset)].active = YES;
    return button;
}

/// Auswahlknopf mit Kreis/Haken vorn. `handler` optional (sonst fügt der Aufrufer eine Aktion an).
- (UIButton *)optionButtonWithTitle:(NSString *)title subtitle:(nullable NSString *)subtitle symbolOn:(NSString *)symbolOn symbolOff:(NSString *)symbolOff selected:(BOOL)selected handler:(nullable void (^)(void))handler {
    UIButtonConfiguration *config = [self baseConfiguration];
    config.title = title;
    config.subtitle = subtitle;
    config.titleLineBreakMode = NSLineBreakByTruncatingTail;
    config.imagePadding = 16.0;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
    config.contentInsets = NSDirectionalEdgeInsetsMake(18.0, 28.0, 18.0, 28.0);
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    objc_setAssociatedObject(button, @selector(symbolOn), symbolOn, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(button, @selector(symbolOff), symbolOff, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self setOptionButton:button selected:selected];
    if (handler != nil) {
        [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { handler(); }] forControlEvents:UIControlEventPrimaryActionTriggered];
    }
    [self.optionButtons addObject:button];
    return button;
}

- (SEL)symbolOn { return _cmd; }
- (SEL)symbolOff { return _cmd; }

- (void)setOptionButton:(UIButton *)button selected:(BOOL)selected {
    if (button == nil) {
        return;
    }
    NSString *symbol = objc_getAssociatedObject(button, selected ? @selector(symbolOn) : @selector(symbolOff));
    UIButtonConfiguration *config = button.configuration;
    config.image = symbol.length > 0 ? [UIImage systemImageNamed:symbol] : nil;
    // Gewählt: Symbol grün, damit die Auswahl auch ohne Fokus deutlich ist.
    config.imageColorTransformer = selected ? ^UIColor *(UIColor *color) {
        return [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
    } : nil;
    button.configuration = config;
    button.selected = NO; // eigenes Erscheinungsbild; der Systemzustand „selected“ würde die Glasfläche umfärben
    button.accessibilityValue = selected ? @"ausgewählt" : @"nicht ausgewählt";
}

- (UIView *)gridWithButtons:(NSArray<UIButton *> *)buttons {
    UIStackView *grid = [[UIStackView alloc] init];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 20.0;
    for (NSUInteger start = 0; start < buttons.count; start += kSetupGridColumns) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 24.0;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSUInteger i = start; i < start + kSetupGridColumns; i++) {
            if (i < buttons.count) {
                [buttons[i].heightAnchor constraintEqualToConstant:84.0].active = YES;
                [row addArrangedSubview:buttons[i]];
            } else {
                [row addArrangedSubview:[UIView new]]; // Platzhalter, damit die letzte Reihe dieselbe Spaltenbreite hat
            }
        }
        [grid addArrangedSubview:row];
    }
    return grid;
}

/// Liste von Schaltern: Einträge @[Titel, Text, BOOL-Block (Zustand), Block (umschalten)].
- (UIView *)toggleListWithItems:(NSArray<NSArray *> *)items {
    UIStackView *list = [[UIStackView alloc] init];
    list.axis = UILayoutConstraintAxisVertical;
    list.spacing = 22.0;
    for (NSArray *item in items) {
        BOOL (^state)(void) = item[2];
        void (^toggle)(void) = item[3];
        UIButton *button = [self optionButtonWithTitle:item[0] subtitle:item[1] symbolOn:@"checkmark.circle.fill" symbolOff:@"circle" selected:state() handler:nil];
        UIButtonConfiguration *config = button.configuration;
        config.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
            NSMutableDictionary *result = [attributes mutableCopy];
            result[NSFontAttributeName] = [UIFont systemFontOfSize:34.0 weight:UIFontWeightBold];
            return result;
        };
        config.subtitleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
            NSMutableDictionary *result = [attributes mutableCopy];
            result[NSFontAttributeName] = [UIFont systemFontOfSize:25.0 weight:UIFontWeightRegular];
            return result;
        };
        config.titlePadding = 6.0;
        config.imagePadding = 24.0;
        config.contentInsets = NSDirectionalEdgeInsetsMake(22.0, 40.0, 22.0, 40.0);
        config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
        button.configuration = config;
        __weak typeof(self) weakSelf = self;
        __weak UIButton *weakButton = button;
        [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            toggle();
            [weakSelf setOptionButton:weakButton selected:state()];
        }] forControlEvents:UIControlEventPrimaryActionTriggered];
        [list addArrangedSubview:button];
    }
    self.preferredFocusView = self.optionButtons.firstObject;
    UIView *wrapper = [UIView new];
    list.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:list];
    [NSLayoutConstraint activateConstraints:@[
        [list.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
        [list.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
        [list.centerXAnchor constraintEqualToAnchor:wrapper.centerXAnchor],
        [list.widthAnchor constraintEqualToConstant:1120.0],
    ]];
    return wrapper;
}

- (UIButton *)designButtonWithSymbol:(NSString *)symbol title:(NSString *)title text:(NSString *)text selected:(BOOL)selected handler:(void (^)(void))handler {
    UIButton *button = [self optionButtonWithTitle:title subtitle:text symbolOn:@"largecircle.fill.circle" symbolOff:@"circle" selected:selected handler:handler];
    UIButtonConfiguration *config = button.configuration;
    config.imagePlacement = NSDirectionalRectEdgeTop;
    config.imagePadding = 22.0;
    config.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
    config.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
        NSMutableDictionary *result = [attributes mutableCopy];
        result[NSFontAttributeName] = [UIFont systemFontOfSize:38.0 weight:UIFontWeightBold];
        return result;
    };
    config.contentInsets = NSDirectionalEdgeInsetsMake(36.0, 40.0, 36.0, 40.0);
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:44.0 weight:UIImageSymbolWeightSemibold];
    button.configuration = config;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    [button.heightAnchor constraintEqualToConstant:300.0].active = YES;
    (void)symbol;
    return button;
}

- (UIView *)infoRowWithSymbol:(NSString *)symbol title:(NSString *)title text:(NSString *)text {
    UIView *circle = [[UIView alloc] init];
    circle.translatesAutoresizingMaskIntoConstraints = NO;
    circle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    circle.layer.cornerRadius = 32.0;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold]]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = UIColor.whiteColor;
    [circle addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [circle.widthAnchor constraintEqualToConstant:64.0],
        [circle.heightAnchor constraintEqualToConstant:64.0],
        [icon.centerXAnchor constraintEqualToAnchor:circle.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:circle.centerYAnchor],
    ]];
    UILabel *titleLabel = [self labelWithSize:32.0 weight:UIFontWeightBold alpha:1.0];
    titleLabel.text = title;
    titleLabel.textAlignment = NSTextAlignmentNatural;
    UILabel *textLabel = [self labelWithSize:26.0 weight:UIFontWeightRegular alpha:0.7];
    textLabel.text = text;
    textLabel.textAlignment = NSTextAlignmentNatural;
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, textLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2.0;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[circle, texts]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 26.0;
    return row;
}

#pragma mark - Abschluss

- (void)finish {
    BrowserPreferencesStore *store = [BrowserPreferencesStore new];
    BrowserHistoryStore *history = [BrowserHistoryStore sharedStore];
    // Favoriten: abgewählte entfernen, neue hinzufügen.
    for (BrowserSiteEntry *entry in [history.favorites copy]) {
        NSURL *url = [NSURL URLWithString:entry.urlString];
        if (url != nil && ![self isFavorite:entry.urlString]) {
            [history removeFavoriteWithURL:url];
        }
    }
    for (NSArray<NSString *> *favorite in self.favorites) {
        NSURL *url = [NSURL URLWithString:favorite[0]];
        if (url != nil && ![history isFavoriteURL:url]) {
            [history addFavoriteWithURL:url title:favorite[1]];
        }
    }
    store.homePageURLString = self.homePageURLString;
    store.adBlockEnabled = self.adBlock;
    store.cookieBannerBlockEnabled = self.cookieBanner;
    BrowserDNSProxy.enabled = self.cloudflareDNS;
    store.autoOpenVideosInNativePlayer = self.nativePlayer;
    store.autoSubtitlesEnabled = self.autoSubtitles;
    store.webSubtitlesEnabled = self.webSubtitles;
    store.classicDesignEnabled = self.classicDesign;
    store.setupCompleted = YES;
    NSLog(@"[Setup] fertig: %lu Favoriten, Startseite %@, Werbeblocker %d, DNS %d, Cookie %d, Player %d, Untertitel %d/%d, alt %d",
          (unsigned long)self.favorites.count, self.homePageURLString.length > 0 ? self.homePageURLString : @"Google",
          self.adBlock, self.cloudflareDNS, self.cookieBanner, self.nativePlayer, self.autoSubtitles, self.webSubtitles, self.classicDesign);

    BOOL homeChanged = ![self.homePageURLString isEqualToString:self.initialHomePageURLString ?: @""];
    void (^handler)(BOOL) = self.completionHandler;
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler != nil) {
            handler(homeChanged);
        }
    }];
}

#pragma mark - Fokus und Tasten

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    UIView *view = self.preferredFocusView ?: self.nextButton;
    return view != nil ? @[view] : @[];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeMenu) {
            // Menü: einen Schritt zurück. Im ersten Schritt bleibt die Einrichtung offen (Überspringen ist ein Knopf).
            [self goBack];
            return;
        }
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeMenu) {
            return;
        }
    }
    [super pressesEnded:presses withEvent:event];
}

#if DEBUG
- (void)debugShowPage:(NSInteger)page {
    [self showPage:(BrowserSetupPage)MAX(0, MIN(page, BrowserSetupPageCount - 1)) animated:NO];
}

- (void)debugActivateOption:(NSInteger)index {
    if (index >= 0 && index < (NSInteger)self.optionButtons.count) {
        [self.optionButtons[index] sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    }
}

- (void)debugNext {
    [self goForward];
}
#endif

@end
