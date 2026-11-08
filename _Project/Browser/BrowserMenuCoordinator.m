#import "BrowserMenuCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserDNSProxy.h"
#import "BrowserContentBlocker.h"
#import "BrowserCookieConsentBlocker.h"
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

@interface BrowserAdvancedMenuViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

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
@property (nonatomic) UITableView *tableView;
@property (nonatomic) NSLayoutConstraint *panelTrailingConstraint;
@property (nonatomic) CGFloat panelWidth;
@property (nonatomic) BOOL didAnimateIn;
@property (nonatomic) BOOL dismissalInProgress;
@property (nonatomic) BOOL usingNativeGlassEffect;

@end

@implementation BrowserAdvancedMenuViewController

- (UIVisualEffect *)panelEffect {
    Class glassEffectClass = NSClassFromString(@"UIGlassEffect");
    if (glassEffectClass != Nil) {
        id effect = [[glassEffectClass alloc] init];
        if ([effect isKindOfClass:[UIVisualEffect class]]) {
            return (UIVisualEffect *)effect;
        }
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
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
    self.usingNativeGlassEffect = (NSClassFromString(@"UIGlassEffect") != Nil);

    UIView *dimView = [UIView new];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    dimView.backgroundColor = self.usingNativeGlassEffect ? UIColor.clearColor : [UIColor colorWithWhite:0.0 alpha:0.45];
    dimView.alpha = 0.0;
    [self.view addSubview:dimView];
    self.dimView = dimView;

    UIVisualEffectView *panelView = [[UIVisualEffectView alloc] initWithEffect:[self panelEffect]];
    panelView.translatesAutoresizingMaskIntoConstraints = NO;
    panelView.backgroundColor = UIColor.clearColor;
    panelView.layer.cornerRadius = 28.0;
    panelView.layer.masksToBounds = YES;
    panelView.layer.borderWidth = self.usingNativeGlassEffect ? 0.0 : 1.0;
    panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    [self.view addSubview:panelView];
    self.panelView = panelView;

    UIView *panelTint = nil;
    if (!self.usingNativeGlassEffect) {
        panelTint = [UIView new];
        panelTint.translatesAutoresizingMaskIntoConstraints = NO;
        panelTint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        [panelView.contentView addSubview:panelTint];
    }

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = self.menuTitle;
    titleLabel.font = [UIFont boldSystemFontOfSize:34.0];
    titleLabel.textAlignment = NSTextAlignmentLeft;
    if (@available(tvOS 13.0, *)) {
        titleLabel.textColor = UIColor.labelColor;
    } else {
        titleLabel.textColor = UIColor.whiteColor;
    }
    [panelView.contentView addSubview:titleLabel];

    UIView *separator = [UIView new];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(tvOS 13.0, *)) {
        separator.backgroundColor = UIColor.separatorColor;
    } else {
        separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    }
    [panelView.contentView addSubview:separator];

    UILabel *footerLabel = [UILabel new];
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    footerLabel.text = self.footerText;
    footerLabel.textAlignment = NSTextAlignmentCenter;
    footerLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightRegular];
    if (@available(tvOS 13.0, *)) {
        footerLabel.textColor = UIColor.secondaryLabelColor;
    } else {
        footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    }
    [panelView.contentView addSubview:footerLabel];

    UITableView *tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.rowHeight = 68.0;
    tableView.backgroundColor = UIColor.clearColor;
    tableView.preservesSuperviewLayoutMargins = NO;
    tableView.layoutMargins = UIEdgeInsetsZero;
    if (@available(tvOS 11.0, *)) {
        tableView.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
        tableView.insetsLayoutMarginsFromSafeArea = NO;
    }
    tableView.cellLayoutMarginsFollowReadableWidth = NO;
    tableView.clipsToBounds = NO;
    tableView.layer.cornerRadius = 0.0;
    tableView.remembersLastFocusedIndexPath = YES;
    tableView.contentInset = UIEdgeInsetsZero;
    tableView.showsVerticalScrollIndicator = NO;
    if (@available(tvOS 11.0, *)) {
        tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        tableView.insetsContentViewsToSafeArea = NO;
    }
    [panelView.contentView addSubview:tableView];
    self.tableView = tableView;

    self.panelTrailingConstraint = [panelView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                                                             constant:self.panelWidth + 32.0];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panelView.widthAnchor constraintEqualToConstant:self.panelWidth],
        [panelView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16.0],
        [panelView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16.0],
        self.panelTrailingConstraint,

        [titleLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:32.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-32.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panelView.topAnchor constant:26.0],

        [separator.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:20.0],
        [separator.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-20.0],
        [separator.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:20.0],
        [separator.heightAnchor constraintEqualToConstant:1.0],

        [tableView.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:12.0],
        [tableView.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:16.0],
        [tableView.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-16.0],
        [tableView.bottomAnchor constraintEqualToAnchor:footerLabel.topAnchor constant:-8.0],

        [footerLabel.leadingAnchor constraintEqualToAnchor:panelView.leadingAnchor constant:24.0],
        [footerLabel.trailingAnchor constraintEqualToAnchor:panelView.trailingAnchor constant:-24.0],
        [footerLabel.bottomAnchor constraintEqualToAnchor:panelView.bottomAnchor constant:-12.0],
    ]];
    if (panelTint != nil) {
        [constraints addObject:[panelTint.leadingAnchor constraintEqualToAnchor:panelView.contentView.leadingAnchor]];
        [constraints addObject:[panelTint.trailingAnchor constraintEqualToAnchor:panelView.contentView.trailingAnchor]];
        [constraints addObject:[panelTint.topAnchor constraintEqualToAnchor:panelView.contentView.topAnchor]];
        [constraints addObject:[panelTint.bottomAnchor constraintEqualToAnchor:panelView.contentView.bottomAnchor]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didAnimateIn) {
        return;
    }
    self.didAnimateIn = YES;
    self.panelTrailingConstraint.constant = -16.0;
    [UIView animateWithDuration:0.28
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
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

    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
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
    [UIView animateWithDuration:0.22
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.dimView.alpha = 0.0;
        [self.view layoutIfNeeded];
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:completion];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) {
        return 0;
    }
    return (NSInteger)self.sections[(NSUInteger)section].items.count;
}

- (UIView *)tableView:(__unused UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *header = [UIView new];
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = [self.sections[(NSUInteger)section].title uppercaseString];
    label.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.secondaryLabelColor;
    [header addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24.0],
        [label.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-24.0],
        [label.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-6.0],
    ]];
    return header;
}

- (CGFloat)tableView:(__unused UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? 52.0 : 76.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const kCellIdentifier = @"BrowserAdvancedMenuCell";
    static NSInteger const kMenuTitleLabelTag = 9191;
    static NSInteger const kMenuFocusBackgroundTag = 9292;
    static NSInteger const kMenuDetailLabelTag = 9393;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kCellIdentifier];
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.clipsToBounds = NO;
        cell.contentView.clipsToBounds = NO;
        cell.preservesSuperviewLayoutMargins = NO;
        cell.layoutMargins = UIEdgeInsetsZero;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([cell respondsToSelector:@selector(setFocusStyle:)]) {
            [cell setValue:@(1) forKey:@"focusStyle"]; // UITableViewCellFocusStyleCustom
        }

        UIView *focusBackgroundView = [UIView new];
        focusBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
        focusBackgroundView.tag = kMenuFocusBackgroundTag;
        focusBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        focusBackgroundView.layer.cornerRadius = 12.0;
        focusBackgroundView.alpha = 0.0;
        [cell.contentView addSubview:focusBackgroundView];

        UILabel *titleLabel = [UILabel new];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.tag = kMenuTitleLabelTag;
        titleLabel.font = [UIFont systemFontOfSize:31.0 weight:UIFontWeightRegular];
        titleLabel.textAlignment = NSTextAlignmentLeft;
        titleLabel.numberOfLines = 1;
        [cell.contentView addSubview:titleLabel];

        UILabel *detailLabel = [UILabel new];
        detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        detailLabel.tag = kMenuDetailLabelTag;
        detailLabel.font = [UIFont systemFontOfSize:27.0 weight:UIFontWeightMedium];
        detailLabel.textAlignment = NSTextAlignmentRight;
        detailLabel.textColor = UIColor.secondaryLabelColor;
        detailLabel.numberOfLines = 1;
        detailLabel.adjustsFontSizeToFitWidth = YES;
        detailLabel.minimumScaleFactor = 0.7;
        [detailLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
        [detailLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [cell.contentView addSubview:detailLabel];
        [titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        [NSLayoutConstraint activateConstraints:@[
            [focusBackgroundView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:0.0],
            [focusBackgroundView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:0.0],
            [focusBackgroundView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:2.0],
            [focusBackgroundView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-2.0],

            [titleLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:24.0],
            [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:detailLabel.leadingAnchor constant:-12.0],
            [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [detailLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-24.0],
            [detailLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [detailLabel.widthAnchor constraintLessThanOrEqualToAnchor:cell.contentView.widthAnchor multiplier:0.5],
        ]];
    }

    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    UILabel *titleLabel = (UILabel *)[cell.contentView viewWithTag:kMenuTitleLabelTag];
    UIView *focusBackgroundView = [cell.contentView viewWithTag:kMenuFocusBackgroundTag];
    titleLabel.text = item.title;
    UILabel *detailLabel = (UILabel *)[cell.contentView viewWithTag:kMenuDetailLabelTag];
    detailLabel.text = item.detail;
    BOOL isOn = [item.detail isEqualToString:@"An"];
    detailLabel.textColor = isOn ? [UIColor colorWithRed:0.35 green:0.85 blue:0.5 alpha:1.0] : UIColor.secondaryLabelColor;
    UIColor *titleColor = nil;
    if (item.style == UIAlertActionStyleDestructive) {
        titleColor = UIColor.redColor;
    } else if (@available(tvOS 13.0, *)) {
        titleColor = UIColor.labelColor;
    } else {
        titleColor = UIColor.whiteColor;
    }
    titleLabel.textColor = titleColor;
    focusBackgroundView.alpha = cell.isFocused ? 1.0 : 0.0;
    return cell;
}

- (void)tableView:(UITableView *)tableView
didUpdateFocusInContext:(UITableViewFocusUpdateContext *)context
withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    NSIndexPath *previousIndexPath = context.previouslyFocusedIndexPath;
    NSIndexPath *nextIndexPath = context.nextFocusedIndexPath;

    UITableViewCell *previousCell = previousIndexPath ? [tableView cellForRowAtIndexPath:previousIndexPath] : nil;
    UITableViewCell *nextCell = nextIndexPath ? [tableView cellForRowAtIndexPath:nextIndexPath] : nil;

    [coordinator addCoordinatedAnimations:^{
        UIView *previousFocusBackground = [previousCell.contentView viewWithTag:9292];
        previousFocusBackground.alpha = 0.0;

        UIView *nextFocusBackground = [nextCell.contentView viewWithTag:9292];
        nextFocusBackground.alpha = 1.0;
    } completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BrowserAdvancedMenuSection *section = self.sections[(NSUInteger)indexPath.section];
    BrowserAdvancedMenuItem *item = section.items[(NSUInteger)indexPath.row];
    BrowserAdvancedMenuItemHandler handler = item.handler;
    [self dismissMenuWithCompletion:^{
        if (handler != nil) {
            handler();
        }
    }];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[self.tableView];
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
    return [self browserActionWithTitle:nil style:UIAlertActionStyleCancel handler:nil];
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
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Delete a Favorite"
                                                                       message:@"Select a Favorite to Delete"];
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
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Name New Favorite"
                                                                       message:currentURL];
    __weak typeof(self) weakSelf = self;
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeDefault;
        textField.placeholder = @"Name New Favorite";
        textField.text = pageTitle;
        textField.textColor = MenuTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];
    
    [alertController addAction:[self browserActionWithTitle:@"Save"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(__unused UIAlertAction *action) {
        UITextField *titleTextField = alertController.textFields.firstObject;
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
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Favorites" message:@""];
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
        [alertController addAction:[self browserActionWithTitle:@"Delete a Favorite"
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(__unused UIAlertAction *action) {
            [weakSelf presentDeleteFavoriteMenu];
        }]];
    }
    
    [alertController addAction:[self browserActionWithTitle:@"Add Current Page to Favorites"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
        [weakSelf presentAddFavoritePrompt];
    }]];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentHistoryMenu {
    NSArray *historyEntries = [[NSUserDefaults standardUserDefaults] arrayForKey:@"HISTORY"];
    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"History" message:@""];
    __weak typeof(self) weakSelf = self;
    
    if (historyEntries.count > 0) {
        [alertController addAction:[self browserActionWithTitle:@"Clear History"
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
                                                                           message:@"The page did not return diagnostics data."];
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

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"Media Diagnostics"
                                                                       message:message];
    [alertController addAction:[self browserCancelAction]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentWebKitRuntimeMediaPreferences {
    NSString *report = [[self.host browserWebView] runtimeMediaPreferenceReport];
    if (![self stringHasVisibleContent:report]) {
        report = @"No runtime WebKit media preference information was returned.";
    }

    NSLog(@"%@ %@", kBrowserWebKitMediaPrefsLogPrefix, report);

    NSString *message = report;
    if (message.length > 1800) {
        message = [[message substringToIndex:1800] stringByAppendingString:@"\n\nFull report logged to console."];
    }

    UIAlertController *alertController = [self browserAlertControllerWithTitle:@"WebKit Media Prefs"
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
            [alertController addAction:[self browserActionWithTitle:@"Cancel"
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

- (BrowserAdvancedMenuItem *)setCurrentPageAsHomePageMenuItem {
    return [self advancedMenuItemWithTitle:@"Diese Seite als Startseite"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        NSURLRequest *request = [[self.host browserWebView] request];
        if (request != nil && [self stringHasVisibleContent:request.URL.absoluteString]) {
            self.preferencesStore.homePageURLString = request.URL.absoluteString;
        }
    }];
}

- (BrowserAdvancedMenuItem *)usageGuideMenuItem {
    return [self advancedMenuItemWithTitle:@"Bedienung"
                                     style:UIAlertActionStyleDefault
                                   handler:^{
        [self.host browserShowHints];
    }];
}

- (UIAlertAction *)wkWebViewProofOfConceptAction {
    return [self browserActionWithTitle:@"Open WKWebView PoC"
                                  style:UIAlertActionStyleDefault
                                handler:^(__unused UIAlertAction *action) {
        Class proofOfConceptControllerClass = NSClassFromString(@"BrowserWKWebViewProofOfConceptViewController");
        UIViewController *viewController = nil;
        if (proofOfConceptControllerClass != Nil) {
            viewController = [proofOfConceptControllerClass new];
            viewController.modalPresentationStyle = UIModalPresentationFullScreen;
        } else {
            viewController = [UIAlertController alertControllerWithTitle:@"WKWebView PoC Missing"
                                                                 message:@"The proof-of-concept controller was not compiled into this build."
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
    return [self browserActionWithTitle:@"Play Active Video"
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
        [self cookieBannerMenuItem],
        [self cookiePayWallMenuItem],
        [self autoOpenNativePlayerMenuItem],
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
    BrowserAdvancedMenuItem *mediaDiagnosticsItem = [self advancedMenuItemWithTitle:@"Media Diagnostics"
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
                                               items:@[
            reloadItem,
            [self pageZoomMenuItem],
            [self adBlockSiteMenuItem],
            [self cookieBannerSiteMenuItem],
            [self setCurrentPageAsHomePageMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Navigation"
                                               items:@[
            [self homePageMenuItem],
            [self favoritesMenuItem],
            [self historyMenuItem],
            [self showTabsMenuItem],
            [self newTabMenuItem],
        ]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Erweiterungen"
                                               items:[self extensionMenuItems]],
        [BrowserAdvancedMenuSection sectionWithTitle:@"Ansicht & Wiedergabe"
                                               items:@[
            [self topNavigationVisibilityMenuItem],
            [self rainbowGlowMenuItem],
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
