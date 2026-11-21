//
//  BrowserAddressInputController.m
//

#import "BrowserAddressInputController.h"
#import "BrowserLocalization.h"

/// Unsichtbares, fokussierbares Feld unter der Tastatur: Bekommt es den Fokus (Wischen nach unten aus der
/// Tastatur), geht es zu den Kacheln der Aufklapp-Karte.
@interface BrowserAddressInputFocusCatcher : UIView
@end

@implementation BrowserAddressInputFocusCatcher
- (BOOL)canBecomeFocused {
    return YES;
}
@end

/// Ergebnisbereich der Suche: durchsichtig (darunter liegt die Karte der App), oben der Knopf „Los“ bei Text.
@interface BrowserAddressInputResultsController : UIViewController
@property (nonatomic) UIButton *submitButton;
@property (nonatomic) BrowserAddressInputFocusCatcher *catcher;
@property (nonatomic, copy) void (^submitHandler)(void);
@property (nonatomic, copy) void (^catcherFocusedHandler)(void);
/// Nach jedem Layout (Knopf erscheint/verschwindet): Tastaturkarte anpassen.
@property (nonatomic, copy) void (^layoutHandler)(void);
/// Selbsttest: bevorzugter Fokus ist das Feld unter der Tastatur.
@property (nonatomic) BOOL debugPreferCatcher;
@end

@implementation BrowserAddressInputResultsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.catcher = [[BrowserAddressInputFocusCatcher alloc] initWithFrame:CGRectZero];
    self.catcher.backgroundColor = UIColor.clearColor;
    [self.view addSubview:self.catcher];

    self.submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.submitButton.hidden = YES;
    [self.submitButton addTarget:self action:@selector(submitTapped) forControlEvents:UIControlEventPrimaryActionTriggered];
    [self.view addSubview:self.submitButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    [self.submitButton sizeToFit];
    CGSize size = self.submitButton.bounds.size;
    CGFloat width = MIN(MAX(size.width + 40.0, 360.0), CGRectGetWidth(bounds) - 200.0);
    self.submitButton.frame = CGRectMake(floor((CGRectGetWidth(bounds) - width) / 2.0), 10.0, width, MAX(size.height, 66.0));
    CGFloat catcherTop = self.submitButton.hidden ? 0.0 : CGRectGetMaxY(self.submitButton.frame) + 20.0;
    self.catcher.frame = CGRectMake(0.0, catcherTop, CGRectGetWidth(bounds), MAX(1.0, CGRectGetHeight(bounds) - catcherTop));
    if (self.layoutHandler != nil) {
        self.layoutHandler();
    }
}

/// Unterkante des Knopfs „Los“ in Fensterkoordinaten (0 ohne Knopf).
- (CGFloat)submitButtonBottomInWindow {
    if (self.submitButton.hidden || self.view.window == nil) {
        return 0.0;
    }
    return CGRectGetMaxY([self.view convertRect:self.submitButton.frame toView:nil]);
}

- (void)setSubmitTitle:(nullable NSString *)title {
    [self.submitButton setTitle:title forState:UIControlStateNormal];
    self.submitButton.hidden = title.length == 0;
    [self.view setNeedsLayout];
}

- (void)submitTapped {
    if (self.submitHandler != nil) {
        self.submitHandler();
    }
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return self.debugPreferCatcher ? @[self.catcher] : [super preferredFocusEnvironments];
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    if (context.nextFocusedView == self.catcher && self.catcherFocusedHandler != nil) {
        self.catcherFocusedHandler();
    }
}

@end

@interface BrowserAddressInputController () <UISearchControllerDelegate, UISearchResultsUpdating, UISearchBarDelegate>
@property (nonatomic) UISearchController *searchController;
@property (nonatomic) UISearchContainerViewController *containerController;
@property (nonatomic) BrowserAddressInputResultsController *resultsController;
@property (nonatomic, copy) NSString *lastText;
@property (nonatomic) BOOL finished;
@property (nonatomic) UIVisualEffectView *cardView;
@property (nonatomic) CGFloat cardHeight;
@property (nonatomic) BOOL debugPreferResults;
@end

@implementation BrowserAddressInputController

/// Abstand Leiste → Tastaturkarte → Aufklapp-Karte (wie kPanelGapBelowBar).
static CGFloat const kInputGap = 14.0;
/// Höhe der Tastaturkarte: Suchzeile (70 pt) und einzeilige Tastatur (66 pt) mit Rand; am Simulator tvOS 27 gemessen
/// (UIKeyboard 104 pt unter der Oberkante der Suchansicht).
static CGFloat const kInputCardHeight = 190.0;
static CGFloat const kInputContentInset = 6.0;

+ (CGFloat)keyboardAreaHeight {
    return kInputCardHeight + kInputGap;
}

#if DEBUG
- (nullable UIView *)debugFindViewOfClassNamed:(NSString *)name inView:(UIView *)view {
    if ([NSStringFromClass(view.class) isEqualToString:name]) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *found = [self debugFindViewOfClassNamed:name inView:sub];
        if (found != nil) {
            return found;
        }
    }
    return nil;
}
#endif

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        _barFrame = CGRectMake(80.0, 14.0, 1760.0, 86.0);
        _cardHeight = kInputCardHeight;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    // Dunkle Darstellung: helle Tasten auf der Glaskarte, unabhängig von der Seite darunter.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    // Glaskarte hinter Suchzeile und Tastatur, wie die Aufklapp-Karte darunter (Leiste → Tastatur → Kacheln).
    UIVisualEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    }
#endif
    self.cardView = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.cardView.clipsToBounds = YES;
    self.cardView.layer.cornerRadius = 40.0;
    self.cardView.layer.cornerCurve = kCACornerCurveContinuous;
    self.cardView.layer.borderWidth = 1.0;
    self.cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    UIView *tint = [[UIView alloc] initWithFrame:self.cardView.contentView.bounds];
    tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tint.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
    [self.cardView.contentView addSubview:tint];
    [self.view addSubview:self.cardView];

    BrowserAddressInputResultsController *results = [BrowserAddressInputResultsController new];
    __weak typeof(self) weakSelf = self;
    results.submitHandler = ^{
        [weakSelf submitCurrentText];
    };
    results.catcherFocusedHandler = ^{
        [weakSelf finishWithEnd:BrowserAddressInputEndToTiles text:nil];
    };
    results.layoutHandler = ^{
        [weakSelf updateCardHeight];
    };
    self.resultsController = results;

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:results];
    search.searchResultsUpdater = self;
    search.delegate = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.delegate = self;
    search.searchBar.placeholder = BLS(@"Suchbegriff oder Adresse");
    self.searchController = search;

    UISearchContainerViewController *container = [[UISearchContainerViewController alloc] initWithSearchController:search];
    container.view.backgroundColor = UIColor.clearColor;
    [self addChildViewController:container];
    [self.view addSubview:container.view];
    [container didMoveToParentViewController:self];
    self.containerController = container;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGRect bar = [self.view convertRect:self.barFrame fromView:nil];
    CGFloat top = CGRectGetMaxY(bar) + kInputGap;
    self.cardView.frame = CGRectMake(CGRectGetMinX(bar), top, CGRectGetWidth(bar), self.cardHeight);
    // Suchansicht so breit wie die Karte: Suchzeile und Diktat-Hinweis bleiben innerhalb der Glaskarte.
    self.containerController.view.frame = CGRectMake(CGRectGetMinX(bar), top + kInputContentInset, CGRectGetWidth(bar),
                                                     CGRectGetHeight(bounds) - top - kInputContentInset);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self hideSearchSeparator];
#if DEBUG
    // Kurz danach: Lage der Tastatur und fokussiertes Element (muss in der Tastatur liegen, sonst kein Diktat).
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self_ = weakSelf;
        if (self_ == nil || self_.view.window == nil) {
            return;
        }
        [self_ hideSearchSeparator];
        UIView *keyboard = [self_ debugFindViewOfClassNamed:@"UIKeyboard" inView:self_.view.window];
        id focused = [UIFocusSystem focusSystemForEnvironment:self_].focusedItem;
        NSLog(@"[Address] Tastatur offen, Leiste=%@ Tastatur=%@ Fokus=%@", NSStringFromCGRect(self_.barFrame),
              keyboard != nil ? NSStringFromCGRect([keyboard convertRect:keyboard.bounds toView:nil]) : @"-",
              focused != nil ? NSStringFromClass([focused class]) : @"-");
    });
#endif
}

/// Haarlinie der Suchansicht unter der Tastatur (schlichte UIView, 1 pt hoch, direkt in der Suchansicht) ausblenden:
/// Sie läge sonst quer über der Aufklapp-Karte. Findet sie sich nicht (andere tvOS-Version), bleibt sie eben sichtbar.
- (void)hideSearchSeparator {
    if (!self.searchController.isViewLoaded) {
        return;
    }
    for (UIView *view in self.searchController.view.subviews) {
        if (view.class == UIView.class && CGRectGetHeight(view.bounds) <= 1.5 && CGRectGetWidth(view.bounds) > 200.0 && view.subviews.count == 0) {
            view.hidden = YES;
        }
    }
}

/// Mit Text wächst die Tastaturkarte nach unten um den Knopf „Los“ (er liegt im Ergebnisbereich der Suche);
/// die Aufklapp-Karte rückt mit (keyboardAreaHeightHandler).
- (void)updateCardHeight {
    [self hideSearchSeparator];
    CGFloat buttonBottom = [self.resultsController submitButtonBottomInWindow];
    CGRect bar = [self.view convertRect:self.barFrame fromView:nil];
    CGFloat top = CGRectGetMaxY(bar) + kInputGap;
    CGFloat height = buttonBottom > 0.0 ? MAX(kInputCardHeight, buttonBottom + 18.0 - top) : kInputCardHeight;
    if (fabs(height - self.cardHeight) < 0.5) {
        return;
    }
    self.cardHeight = height;
    [UIView animateWithDuration:0.25 delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.cardView.frame = CGRectMake(CGRectGetMinX(bar), top, CGRectGetWidth(bar), height);
    } completion:nil];
    if (self.keyboardAreaHeightHandler != nil) {
        self.keyboardAreaHeightHandler(height + kInputGap);
    }
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.debugPreferResults) {
        return @[self.resultsController];
    }
    return self.containerController != nil ? @[self.containerController] : [super preferredFocusEnvironments];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Von außen geschlossen (Menü, Befehl, anderer Dialog): wie Abbrechen.
    if (!self.finished && (self.isBeingDismissed || self.presentingViewController == nil)) {
        [self finishWithEnd:BrowserAddressInputEndCancelled text:nil];
    }
}

#pragma mark Text

- (NSString *)text {
    return self.searchController.searchBar.text ?: @"";
}

- (void)insertDictatedText:(NSString *)text {
    self.searchController.searchBar.text = text;
    [self updateSearchResultsForSearchController:self.searchController];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = searchController.searchBar.text ?: @"";
    // UIKit meldet sich auch ohne Änderung (Aktivieren, Fokuswechsel); das darf die geplante Bestätigung nicht abbrechen.
    if ([text isEqualToString:self.lastText ?: @""]) {
        return;
    }
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self.resultsController setSubmitTitle:trimmed.length > 0 ? [NSString stringWithFormat:BLS(@"Los: „%@“"), trimmed] : nil];

    NSUInteger previousLength = self.lastText.length;
    self.lastText = text;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(submitCurrentText) object:nil];
    // Diktat (Siri-Taste halten) fügt den ganzen Satz auf einmal ein. Dann ohne weiteren Druck ausführen.
    if (previousLength == 0 && text.length >= 3) {
#if DEBUG
        NSLog(@"[Address] Diktat erkannt: \"%@\", bestätige in 1,5 s", text);
#endif
        [self performSelector:@selector(submitCurrentText) withObject:nil afterDelay:1.5];
    }
}

/// Beendet das System die Suche selbst (z. B. Menü über einen eigenen Gestenerkenner der Suchansicht), darf die
/// durchsichtige Hülle mit Glaskarte nicht ohne Tastatur stehen bleiben: wie Abbrechen.
- (void)didDismissSearchController:(UISearchController *)searchController {
    if (!self.finished && self.view.window != nil) {
#if DEBUG
        NSLog(@"[Address] Suche vom System beendet");
#endif
        [self finishWithEnd:BrowserAddressInputEndCancelled text:nil];
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self submitCurrentText];
}

- (void)submitCurrentText {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(submitCurrentText) object:nil];
    NSString *text = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) {
        return;
    }
    [self finishWithEnd:BrowserAddressInputEndSubmitted text:text];
}

#pragma mark Schließen

- (void)finishWithEnd:(BrowserAddressInputEnd)end text:(nullable NSString *)text {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(submitCurrentText) object:nil];
#if DEBUG
    NSLog(@"[Address] Tastatur zu: %@%@", end == BrowserAddressInputEndSubmitted ? @"bestätigt" : end == BrowserAddressInputEndToTiles ? @"zu den Kacheln" : @"abgebrochen",
          text != nil ? [NSString stringWithFormat:@" \"%@\"", text] : @"");
#endif
    void (^handler)(BrowserAddressInputEnd, NSString *) = self.endHandler;
    self.endHandler = nil;
    // Rückruf erst nach dem Schließen: Dann ist presentedViewController wieder nil (Zeiger, Klicks, Seite laden).
    if (self.presentingViewController != nil && !self.isBeingDismissed) {
        [self.presentingViewController dismissViewControllerAnimated:YES completion:^{
            if (handler != nil) {
                handler(end, text);
            }
        }];
        return;
    }
    if (handler != nil) {
        handler(end, text);
    }
}

#if DEBUG
- (void)debugMoveFocusBelowKeyboard {
    self.resultsController.debugPreferCatcher = YES;
    self.debugPreferResults = YES;
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}
#endif

- (void)closeSilentlyAnimated:(BOOL)animated {
    self.finished = YES;
    self.endHandler = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(submitCurrentText) object:nil];
    if (self.presentingViewController != nil && !self.isBeingDismissed) {
        [self.presentingViewController dismissViewControllerAnimated:animated completion:nil];
    }
}

@end
