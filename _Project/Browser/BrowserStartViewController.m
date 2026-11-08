//
//  BrowserStartViewController.m
//

#import "BrowserStartViewController.h"
#import "BrowserHistoryStore.h"

// Aufbau der Kachelabschnitte, hier leicht änderbar.
static NSUInteger const kStartTileRows = 2;
static NSUInteger const kStartTileColumns = 3;
static NSUInteger const kStartMaxTilesPerSection = kStartTileRows * kStartTileColumns;
static NSUInteger const kStartRecentCount = 3;
static NSUInteger const kStartTopCount = 5;
static CGFloat const kStartSideMargin = 90.0;
static CGFloat const kStartTileSpacing = 36.0;
static CGFloat const kStartTileHeight = 132.0;
static CGFloat const kStartIconSize = 88.0;

#pragma mark - Symbolbilder

/// Lädt apple-touch-icon.png, ersatzweise favicon.ico, und merkt sich Treffer im Speicher.
@interface BrowserSiteIconLoader : NSObject
+ (void)loadIconForHost:(NSString *)host completion:(void (^)(UIImage *_Nullable image))completion;
@end

@implementation BrowserSiteIconLoader

+ (NSCache<NSString *, UIImage *> *)cache {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
    });
    return cache;
}

+ (void)fetchPaths:(NSArray<NSString *> *)paths host:(NSString *)host completion:(void (^)(UIImage *))completion {
    if (paths.count == 0) {
        completion(nil);
        return;
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", host, paths.firstObject]];
    NSArray<NSString *> *rest = [paths subarrayWithRange:NSMakeRange(1, paths.count - 1)];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:8];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error == nil && status == 200 && data.length > 0) {
            image = [UIImage imageWithData:data];
            // Winzige Bilder (16-px-Favicons) wirken unscharf, trotzdem besser als nichts. Leere ablehnen.
            if (image != nil && (image.size.width < 8 || image.size.height < 8)) {
                image = nil;
            }
        }
        if (image != nil) {
            completion(image);
        } else {
            [self fetchPaths:rest host:host completion:completion];
        }
    }] resume];
}

+ (void)loadIconForHost:(NSString *)host completion:(void (^)(UIImage *))completion {
    UIImage *cached = [self.cache objectForKey:host];
    if (cached != nil) {
        completion(cached);
        return;
    }
    [self fetchPaths:@[@"/apple-touch-icon.png", @"/favicon.ico"] host:host completion:^(UIImage *image) {
        if (image != nil) {
            [self.cache setObject:image forKey:host];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(image);
        });
    }];
}

@end

#pragma mark - Kachel

@interface BrowserStartTileView : UIControl
@property (nonatomic, strong) BrowserSiteEntry *entry;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *letterLabel;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *domainLabel;
- (instancetype)initWithEntry:(BrowserSiteEntry *)entry;
@end

static NSString *BrowserStartDisplayName(BrowserSiteEntry *entry) {
    NSString *name = entry.name;
    if (name.length == 0 || name.length > 28) {
        // Langer Seitentitel: lieber der Hauptteil des Hostnamens.
        NSArray<NSString *> *parts = [entry.host componentsSeparatedByString:@"."];
        NSString *base = parts.count >= 2 ? parts[parts.count - 2] : entry.host;
        return base.length > 0 ? [base.capitalizedString copy] : entry.host;
    }
    return name;
}

static UIColor *BrowserStartColorForHost(NSString *host) {
    NSUInteger hash = 5381;
    for (NSUInteger i = 0; i < host.length; i++) {
        hash = hash * 33 + [host characterAtIndex:i];
    }
    return [UIColor colorWithHue:(hash % 360) / 360.0 saturation:0.55 brightness:0.65 alpha:1.0];
}

@implementation BrowserStartTileView

- (instancetype)initWithEntry:(BrowserSiteEntry *)entry {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _entry = entry;
        _displayName = BrowserStartDisplayName(entry);
        self.layer.cornerRadius = 28;
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0;
        self.layer.shadowRadius = 24;
        self.layer.shadowOffset = CGSizeMake(0, 14);

        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFill;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerRadius = 20;
        _iconView.backgroundColor = BrowserStartColorForHost(entry.host);
        [self addSubview:_iconView];

        _letterLabel = [UILabel new];
        _letterLabel.textAlignment = NSTextAlignmentCenter;
        _letterLabel.font = [UIFont systemFontOfSize:48 weight:UIFontWeightBold];
        _letterLabel.textColor = UIColor.whiteColor;
        _letterLabel.text = [[_displayName substringToIndex:MIN((NSUInteger)1, _displayName.length)] uppercaseString];
        [_iconView addSubview:_letterLabel];

        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightSemibold];
        _nameLabel.textColor = UIColor.whiteColor;
        _nameLabel.text = _displayName;
        [self addSubview:_nameLabel];

        _domainLabel = [UILabel new];
        _domainLabel.font = [UIFont systemFontOfSize:24];
        _domainLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
        _domainLabel.text = entry.host;
        [self addSubview:_domainLabel];

        self.isAccessibilityElement = YES;
        self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", _displayName, entry.host];

        __weak typeof(self) weakSelf = self;
        [BrowserSiteIconLoader loadIconForHost:entry.host completion:^(UIImage *image) {
            if (image != nil) {
                weakSelf.iconView.image = image;
                weakSelf.iconView.backgroundColor = UIColor.whiteColor;
                weakSelf.letterLabel.hidden = YES;
            }
        }];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat pad = (self.bounds.size.height - kStartIconSize) / 2.0;
    self.iconView.frame = CGRectMake(pad, pad, kStartIconSize, kStartIconSize);
    self.letterLabel.frame = self.iconView.bounds;
    CGFloat textX = pad + kStartIconSize + 24;
    CGFloat textW = MAX(0, self.bounds.size.width - textX - pad);
    self.nameLabel.frame = CGRectMake(textX, pad + 2, textW, 40);
    self.domainLabel.frame = CGRectMake(textX, pad + 46, textW, 32);
}

- (BOOL)canBecomeFocused {
    return YES;
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    BOOL focused = context.nextFocusedView == self;
    [coordinator addCoordinatedAnimations:^{
        self.transform = focused ? CGAffineTransformMakeScale(1.08, 1.08) : CGAffineTransformIdentity;
        self.backgroundColor = focused ? [UIColor colorWithWhite:1.0 alpha:0.95] : [UIColor colorWithWhite:1.0 alpha:0.12];
        self.nameLabel.textColor = focused ? UIColor.blackColor : UIColor.whiteColor;
        self.domainLabel.textColor = focused ? [UIColor colorWithWhite:0.0 alpha:0.6] : [UIColor colorWithWhite:1.0 alpha:0.6];
        self.layer.shadowOpacity = focused ? 0.5 : 0;
    } completion:nil];
}

@end

#pragma mark - Startansicht

@interface BrowserStartViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) NSMutableArray<UIView *> *sectionViews;
@property (nonatomic, strong) NSMutableArray<BrowserStartTileView *> *tiles;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *sectionLayout;
@property (nonatomic) NSUInteger lastTextLength;
@property (nonatomic) BOOL didSubmit;
@end

@implementation BrowserStartViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    self.sectionViews = [NSMutableArray array];
    self.tiles = [NSMutableArray array];
    self.sectionLayout = [NSMutableArray array];

    self.scrollView = [UIScrollView new];
    self.scrollView.clipsToBounds = NO;
    [self.view addSubview:self.scrollView];

    self.searchField = [UITextField new];
    self.searchField.delegate = self;
    self.searchField.font = [UIFont systemFontOfSize:40];
    self.searchField.placeholder = @"Suchen oder Adresse eingeben";
    self.searchField.keyboardType = UIKeyboardTypeWebSearch;
    self.searchField.returnKeyType = UIReturnKeySearch;
    self.searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [self.scrollView addSubview:self.searchField];

    self.hintLabel = [UILabel new];
    self.hintLabel.font = [UIFont systemFontOfSize:28];
    self.hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.text = @"Siri-Taste gedrückt halten und sprechen";
    [self.scrollView addSubview:self.hintLabel];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(searchFieldDidChange:) name:UITextFieldTextDidChangeNotification object:self.searchField];
    [self reloadSections];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Favoriten können sich seit dem letzten Öffnen geändert haben.
    [self reloadSections];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.searchField];
}

#pragma mark Aufbau

- (UILabel *)sectionTitleLabel:(NSString *)title {
    UILabel *label = [UILabel new];
    label.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    label.textColor = UIColor.whiteColor;
    label.text = title;
    return label;
}

- (NSArray<NSDictionary *> *)sectionDefinitions {
    BrowserHistoryStore *store = BrowserHistoryStore.sharedStore;
    NSArray *favorites = store.favorites;
    if (favorites.count > kStartMaxTilesPerSection) {
        favorites = [favorites subarrayWithRange:NSMakeRange(0, kStartMaxTilesPerSection)];
    }
    return @[
        @{@"title": @"Zuletzt besucht", @"entries": [store recentEntries:MIN(kStartRecentCount, kStartMaxTilesPerSection)]},
        @{@"title": @"Meistbesucht", @"entries": [store topEntries:MIN(kStartTopCount, kStartMaxTilesPerSection)]},
        @{@"title": @"Favoriten", @"entries": favorites, @"hint": @"Favoriten im Schnellmenü hinzufügen"},
    ];
}

- (void)reloadSections {
    for (UIView *view in self.sectionViews) {
        [view removeFromSuperview];
    }
    [self.sectionViews removeAllObjects];
    [self.tiles removeAllObjects];
    [self.sectionLayout removeAllObjects];

    for (NSDictionary *section in [self sectionDefinitions]) {
        NSArray<BrowserSiteEntry *> *entries = section[@"entries"];
        NSString *hint = section[@"hint"];
        if (entries.count == 0 && hint == nil) {
            continue;
        }
        UILabel *title = [self sectionTitleLabel:section[@"title"]];
        [self.scrollView addSubview:title];
        [self.sectionViews addObject:title];
        NSMutableArray<BrowserStartTileView *> *sectionTiles = [NSMutableArray array];
        UILabel *hintLabel = nil;
        if (entries.count == 0) {
            hintLabel = [UILabel new];
            hintLabel.font = [UIFont systemFontOfSize:30];
            hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
            hintLabel.text = hint;
            [self.scrollView addSubview:hintLabel];
            [self.sectionViews addObject:hintLabel];
        }
        for (BrowserSiteEntry *entry in entries) {
            BrowserStartTileView *tile = [[BrowserStartTileView alloc] initWithEntry:entry];
            [tile addTarget:self action:@selector(tileSelected:) forControlEvents:UIControlEventPrimaryActionTriggered];
            if ([section[@"title"] isEqualToString:@"Favoriten"]) {
                UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(favoriteTileLongPressed:)];
                longPress.allowedPressTypes = @[@(UIPressTypeSelect)];
                longPress.minimumPressDuration = 0.6;
                [tile addGestureRecognizer:longPress];
            }
            [self.scrollView addSubview:tile];
            [self.sectionViews addObject:tile];
            [self.tiles addObject:tile];
            [sectionTiles addObject:tile];
        }
        NSMutableDictionary *layout = [@{@"title": title, @"tiles": sectionTiles} mutableCopy];
        if (hintLabel != nil) {
            layout[@"hint"] = hintLabel;
        }
        [self.sectionLayout addObject:layout];
    }
    [self.view setNeedsLayout];
    [self setNeedsFocusUpdate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    self.scrollView.frame = bounds;
    CGFloat width = bounds.size.width - 2 * kStartSideMargin;
    CGFloat y = 70;
    self.searchField.frame = CGRectMake(kStartSideMargin, y, width, 80);
    y += 80;
    self.hintLabel.frame = CGRectMake(kStartSideMargin, y + 12, width, 36);
    y += 36 + 12 + 60;

    CGFloat tileWidth = (width - (kStartTileColumns - 1) * kStartTileSpacing) / kStartTileColumns;
    for (NSDictionary *section in self.sectionLayout) {
        UILabel *title = section[@"title"];
        title.frame = CGRectMake(kStartSideMargin, y, width, 46);
        y += 46 + 24;
        UILabel *hint = section[@"hint"];
        if (hint != nil) {
            hint.frame = CGRectMake(kStartSideMargin, y, width, 40);
            y += 40 + 50;
            continue;
        }
        NSArray<BrowserStartTileView *> *tiles = section[@"tiles"];
        [tiles enumerateObjectsUsingBlock:^(BrowserStartTileView *tile, NSUInteger index, __unused BOOL *stop) {
            NSUInteger row = index / kStartTileColumns;
            NSUInteger column = index % kStartTileColumns;
            tile.frame = CGRectMake(kStartSideMargin + column * (tileWidth + kStartTileSpacing),
                                    y + row * (kStartTileHeight + kStartTileSpacing), tileWidth, kStartTileHeight);
        }];
        NSUInteger rows = (tiles.count + kStartTileColumns - 1) / kStartTileColumns;
        y += rows * kStartTileHeight + (rows > 0 ? (rows - 1) * kStartTileSpacing : 0) + 50;
    }
    self.scrollView.contentSize = CGSizeMake(bounds.size.width, y + 40);
}

#pragma mark Aktionen

- (void)openURL:(NSURL *)url {
    if (url == nil || self.didSubmit) {
        return;
    }
    self.didSubmit = YES;
    void (^handler)(NSURL *) = self.openURLHandler;
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler != nil) {
            handler(url);
        }
    }];
}

- (void)tileSelected:(BrowserStartTileView *)tile {
    NSURL *url = [NSURL URLWithString:tile.entry.urlString];
    [self openURL:url];
}

- (void)favoriteTileLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    BrowserStartTileView *tile = (BrowserStartTileView *)recognizer.view;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:tile.displayName
                                                                   message:tile.entry.host
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Aus Favoriten entfernen"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:tile.entry.urlString];
        if (url != nil) {
            [BrowserHistoryStore.sharedStore removeFavoriteWithURL:url];
        }
        [weakSelf reloadSections];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Eingabe

/// Sieht die Eingabe wie eine Adresse aus (kein Leerzeichen, mit Punkt oder Schema)? Gleiche Regel wie im ViewController.
- (BOOL)enteredTextLooksLikeAddress:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) {
        return NO;
    }
    return [trimmed containsString:@"://"] || [trimmed hasPrefix:@"localhost"] ||
        ([trimmed containsString:@"."] && ![trimmed hasSuffix:@"."]);
}

- (NSURL *)URLForEnteredText:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return nil;
    }
    if ([self enteredTextLooksLikeAddress:trimmed]) {
        NSString *address = [trimmed containsString:@"://"] ? trimmed : [@"https://" stringByAppendingString:trimmed];
        NSURL *url = [NSURL URLWithString:address];
        if (url.host.length > 0) {
            return url;
        }
    }
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&+=#?"];
    NSString *query = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return [NSURL URLWithString:[@"https://www.google.com/search?q=" stringByAppendingString:query ?: @""]];
}

- (void)submitSearchField {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(submitSearchField) object:nil];
    NSURL *url = [self URLForEnteredText:self.searchField.text ?: @""];
    if (url == nil) {
        return;
    }
    [self.searchField resignFirstResponder];
    [self openURL:url];
}

- (void)searchFieldDidChange:(NSNotification *)notification {
    UITextField *textField = notification.object;
    NSUInteger previousLength = self.lastTextLength;
    self.lastTextLength = textField.text.length;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(submitSearchField) object:nil];
    // Diktat (Siri-Taste halten) fügt den ganzen Satz auf einmal ein. Dann ohne weiteren Druck öffnen.
    if (previousLength == 0 && textField.text.length >= 3) {
        [self performSelector:@selector(submitSearchField) withObject:nil afterDelay:1.5];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self submitSearchField];
    return YES;
}

@end
