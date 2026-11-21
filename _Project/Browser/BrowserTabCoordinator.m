#import "BrowserTabCoordinator.h"

#import "BrowserNavigationService.h"
#import "BrowserPreferencesStore.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTopBarView.h"
#import "BrowserViewModel.h"
#import "BrowserWebView.h"
#import "BrowserLocalization.h"

static CGFloat const kThumbnailStagingOffset = 4096.0;
/// Breite der Vorschau in der Tab-Übersicht (kTabCardWidth in BrowserTabOverviewController.m) in Punkten.
static CGFloat const kThumbnailMaximumWidth = 600.0;
/// Höchstens so viele Tabs behalten ihre WebView (je ein eigener Seitenprozess, am Apple TV 130–590 MB). Ältere Tabs
/// werden entladen: Adresse, Titel, Scrollposition und Vorschaubild bleiben, der Verlauf (Zurück/Vor) geht verloren.
static NSUInteger const kMaximumLoadedTabCount = 5;

@interface BrowserTabCoordinator ()

@property (nonatomic, weak) id<BrowserTabCoordinatorHost> host;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic, weak) UIView *browserContainerView;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, weak) BrowserTopBarView *topMenuView;
@property (nonatomic, weak) UIImageView *cursorView;
@property (nonatomic, weak) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, weak) id webViewDelegate;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic) NSMutableDictionary<NSString *, BrowserWebView *> *webViewsByTabIdentifier;
@property (nonatomic) UIView *thumbnailStagingView;
@property (nonatomic, readwrite, nullable) BrowserWebView *activeWebView;
/// Beim Start wurde eine Sitzung wiederhergestellt: Beim ersten Erscheinen die Startseite zeigen (Einstellung
/// „Startseite festlegen“), die übrigen Tabs bleiben im Hintergrund.
@property (nonatomic) BOOL launchHomePagePending;

@end

@implementation BrowserTabCoordinator

- (instancetype)initWithHost:(id<BrowserTabCoordinatorHost>)host
                   viewModel:(BrowserViewModel *)viewModel
            preferencesStore:(BrowserPreferencesStore *)preferencesStore
           navigationService:(BrowserNavigationService *)navigationService
                sessionStore:(BrowserSessionStore *)sessionStore
          browserContainerView:(UIView *)browserContainerView
                    rootView:(UIView *)rootView
                  topMenuView:(BrowserTopBarView *)topMenuView
                  cursorView:(UIImageView *)cursorView
     manualScrollPanRecognizer:(UIPanGestureRecognizer *)manualScrollPanRecognizer
             webViewDelegate:(id)webViewDelegate
         scrollViewAllowBounces:(BOOL)scrollViewAllowBounces {
    self = [super init];
    if (self) {
        _host = host;
        _viewModel = viewModel;
        _preferencesStore = preferencesStore;
        _navigationService = navigationService;
        _sessionStore = sessionStore;
        _browserContainerView = browserContainerView;
        _rootView = rootView;
        _topMenuView = topMenuView;
        _cursorView = cursorView;
        _manualScrollPanRecognizer = manualScrollPanRecognizer;
        _webViewDelegate = webViewDelegate;
        _scrollViewAllowBounces = scrollViewAllowBounces;
        _webViewsByTabIdentifier = [NSMutableDictionary dictionary];
        [_preferencesStore ensureUserAgentConsistency];
        [self ensureThumbnailStagingView];
    }
    return self;
}

- (BrowserTabViewModel *)activeTab {
    return [self.viewModel activeTab];
}

- (NSString *)requestURL {
    return self.activeTab.requestURL;
}

- (void)setRequestURL:(NSString *)requestURL {
    self.activeTab.requestURL = requestURL ?: @"";
}

- (NSString *)previousURL {
    return self.activeTab.previousURL;
}

- (void)setPreviousURL:(NSString *)previousURL {
    self.activeTab.previousURL = previousURL ?: @"";
}

- (BOOL)topNavigationVisible {
    return self.viewModel.topNavigationBarVisible;
}

- (CGFloat)topMenuBrowserOffset {
    return self.topNavigationVisible ? self.topMenuView.frame.size.height : 0.0;
}

- (void)setTopNavigationVisible:(BOOL)visible {
    self.viewModel.topNavigationBarVisible = visible;
    self.topMenuView.hidden = !visible;
    [self updateTopNavAndWebView];
}

- (void)updateTopNavAndWebView {
    if (self.activeWebView == nil) {
        return;
    }
    // Die WebView reicht bis unter die schwebende Leiste, der Inhalt beginnt per Inset darunter.
    self.activeWebView.frame = self.rootView.bounds;
    self.activeWebView.topObscuredInset = self.topNavigationVisible ? self.topMenuBrowserOffset : 0.0;
}

- (CGSize)thumbnailViewportSize {
    CGFloat width = CGRectGetWidth(self.rootView.bounds);
    CGFloat height = CGRectGetHeight(self.rootView.bounds) - self.topMenuBrowserOffset;
    return CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
}

- (void)ensureThumbnailStagingView {
    if (self.thumbnailStagingView != nil || self.rootView == nil) {
        return;
    }

    CGSize viewportSize = [self thumbnailViewportSize];
    UIView *stagingView = [[UIView alloc] initWithFrame:CGRectMake(kThumbnailStagingOffset,
                                                                   0.0,
                                                                   viewportSize.width,
                                                                   viewportSize.height)];
    stagingView.backgroundColor = UIColor.clearColor;
    stagingView.userInteractionEnabled = NO;
    stagingView.clipsToBounds = YES;
    [self.rootView addSubview:stagingView];
    self.thumbnailStagingView = stagingView;
}

- (void)updateThumbnailStagingViewFrame {
    [self ensureThumbnailStagingView];
    if (self.thumbnailStagingView == nil) {
        return;
    }

    CGSize viewportSize = [self thumbnailViewportSize];
    self.thumbnailStagingView.frame = CGRectMake(kThumbnailStagingOffset,
                                                 0.0,
                                                 viewportSize.width,
                                                 viewportSize.height);
}

- (void)prepareWebViewLayoutForSnapshot:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }

    if (webView.superview == self.thumbnailStagingView) {
        webView.frame = self.thumbnailStagingView.bounds;
    }
    [webView setNeedsLayout];
    [webView layoutIfNeeded];

    UIScrollView *scrollView = webView.scrollView;
    [scrollView setNeedsLayout];
    [scrollView layoutIfNeeded];
    [self.rootView setNeedsLayout];
    [self.rootView layoutIfNeeded];
}

- (void)parkWebViewForThumbnailing:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }

    [self updateThumbnailStagingViewFrame];
    webView.userInteractionEnabled = NO;
    UIScrollView *scrollView = webView.scrollView;
    scrollView.scrollEnabled = NO;
    scrollView.bounces = self.scrollViewAllowBounces;
    if (webView.superview != self.thumbnailStagingView) {
        [webView removeFromSuperview];
        [self.thumbnailStagingView addSubview:webView];
    }
    webView.frame = self.thumbnailStagingView.bounds;
}

- (BOOL)isWebViewStaged:(BrowserWebView *)webView {
    return webView != nil && webView.superview == self.thumbnailStagingView;
}

- (BrowserWebView *)createConfiguredWebView {
    BrowserWebView *webView = [[BrowserWebView alloc] initWithUserAgent:self.preferencesStore.userAgent
                                            allowsInlineMediaPlayback:YES];
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    webView.clipsToBounds = NO;
    webView.delegate = self.webViewDelegate;
    webView.layoutMargins = UIEdgeInsetsZero;
    webView.opaque = NO;
    webView.backgroundColor = UIColor.blackColor;

    UIScrollView *scrollView = webView.scrollView;
    scrollView.layoutMargins = UIEdgeInsetsZero;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scrollView.contentOffset = CGPointZero;
    scrollView.contentInset = UIEdgeInsetsZero;
    scrollView.clipsToBounds = NO;
    scrollView.backgroundColor = UIColor.blackColor;
    scrollView.bounces = self.scrollViewAllowBounces;
    [scrollView.panGestureRecognizer addTarget:self action:@selector(handleWebViewPanGesture:)];
    scrollView.scrollEnabled = NO;

    BOOL shouldScalePagesToFit = self.preferencesStore.scalePagesToFit;
    webView.scalesPageToFit = shouldScalePagesToFit;
    webView.pageZoom = self.preferencesStore.pageZoom;
    webView.contentMode = shouldScalePagesToFit ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleToFill;
    webView.userInteractionEnabled = NO;
    return webView;
}

static NSString *BrowserLetters(NSString *string) {
    NSMutableString *result = [NSMutableString string];
    NSString *folded = [string.lowercaseString stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    [folded enumerateSubstringsInRange:NSMakeRange(0, folded.length) options:NSStringEnumerationByComposedCharacterSequences
                            usingBlock:^(NSString *character, __unused NSRange range, __unused NSRange enclosing, __unused BOOL *stop) {
        if ([character rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet].location != NSNotFound) {
            [result appendString:character];
        }
    }];
    return result;
}

/// Hauptteil der Domain ohne Endung, z. B. "github" aus "github.com" oder "computerbase" aus "www.computerbase.de".
static NSString *BrowserHostLabel(NSString *host) {
    NSArray<NSString *> *parts = [host componentsSeparatedByString:@"."];
    if (parts.count >= 2) {
        NSString *label = parts[parts.count - 2];
        // co.uk, com.au usw.
        if (label.length <= 3 && parts.count >= 3) {
            label = parts[parts.count - 3];
        }
        return label;
    }
    return host;
}

static BOOL BrowserNameMatchesHost(NSString *name, NSString *host) {
    NSString *letters = BrowserLetters(name);
    NSString *label = BrowserLetters(BrowserHostLabel(host));
    return letters.length > 0 && label.length > 0 && ([letters containsString:label] || [label containsString:letters]);
}

/// Wortfolge im Titel, deren Buchstaben genau dem Domainnamen entsprechen (ohne Groß/Klein und Satzzeichen).
static NSString *BrowserPhraseMatchingHost(NSString *title, NSString *host) {
    NSString *label = BrowserLetters(BrowserHostLabel(host));
    if (label.length < 3) {
        return nil;
    }
    NSArray<NSString *> *words = [title componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSUInteger start = 0; start < words.count; start++) {
        NSMutableString *letters = [NSMutableString string];
        for (NSUInteger end = start; end < words.count && end < start + 4; end++) {
            [letters appendString:BrowserLetters(words[end])];
            if ([letters isEqualToString:label] || ([letters hasPrefix:label] && letters.length <= label.length + 1)) {
                NSString *phrase = [[words subarrayWithRange:NSMakeRange(start, end - start + 1)] componentsJoinedByString:@" "];
                phrase = [phrase stringByTrimmingCharactersInSet:NSCharacterSet.punctuationCharacterSet];
                if ([phrase hasSuffix:@"'s"] || [phrase hasSuffix:@"’s"]) {
                    phrase = [phrase substringToIndex:phrase.length - 2];
                }
                if (phrase.length == 0) {
                    return nil;
                }
                return [[[phrase substringToIndex:1] uppercaseString] stringByAppendingString:[phrase substringFromIndex:1]];
            }
            if (letters.length > label.length) {
                break;
            }
        }
    }
    return nil;
}

/// Kurzer Name der Website wie in Safari: Metadaten, sonst der zur Domain passende Teil des Titels.
NSString *BrowserShortSiteName(NSString *siteName, NSString *title, NSString *host) {
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    siteName = [siteName stringByTrimmingCharactersInSet:whitespace];
    if (siteName.length > 0) {
        return siteName;
    }
    title = [title stringByTrimmingCharactersInSet:whitespace];
    if (title.length == 0) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:title];
    for (NSString *separator in @[@" – ", @" — ", @" - ", @" | ", @" · ", @" • ", @": ", @" :: "]) {
        NSMutableArray<NSString *> *next = [NSMutableArray array];
        for (NSString *part in parts) {
            [next addObjectsFromArray:[part componentsSeparatedByString:separator]];
        }
        parts = next;
    }
    NSString *best = nil;
    for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:whitespace];
        if (trimmed.length > 0 && BrowserNameMatchesHost(trimmed, host) && (best == nil || trimmed.length < best.length)) {
            best = trimmed;
        }
    }
    if (best == nil || best.length > 24) {
        // Kein kurzer Teil passt (z. B. „Latest news … from the Guardian“): die Wörter des Titels nehmen,
        // die zusammen den Domainnamen ergeben („the Guardian“ → „The Guardian“).
        NSString *phrase = BrowserPhraseMatchingHost(title, host);
        if (phrase.length > 0) {
            best = phrase;
        }
    }
    if (best == nil) {
        best = [parts.firstObject stringByTrimmingCharactersInSet:whitespace];
    }
    if (best.length > 40) {
        best = [[best substringToIndex:38] stringByAppendingString:@"…"];
    }
    return best;
}

- (void)refreshActiveTabUI {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        [self.topMenuView setDisplayURLString:nil];
        [self.topMenuView setDisplayTitle:@"" domain:nil secure:NO];
        return;
    }

    NSURLRequest *request = self.activeWebView.request;
    // Adresse der angezeigten Seite (passt zum Titel); die Tab-Adresse hinkt beim Laden hinterher.
    NSString *committedURL = self.activeWebView.committedURL.absoluteString;
    NSString *currentURL = committedURL.length > 0 && ![committedURL isEqualToString:@"about:blank"] ? committedURL
        : (tab.URLString.length > 0 ? tab.URLString : request.URL.absoluteString);
    // Das alte Design zeigt wie das Original die volle Adresse.
    [self.topMenuView setDisplayURLString:currentURL];
    // Wie Safari kurz statt der ganzen Adresse: Seitentitel und dahinter dezent die Domain.
    NSString *host = [NSURL URLWithString:currentURL].host ?: @"";
    if ([host hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    NSString *fullTitle = self.activeWebView.reportedPageTitle.length > 0 ? self.activeWebView.reportedPageTitle : self.activeWebView.title;
    NSString *title = BrowserShortSiteName(self.activeWebView.reportedSiteName, fullTitle, host);
    BOOL secure = [[NSURL URLWithString:currentURL].scheme.lowercaseString isEqualToString:@"https"];
    // Immer „Titel · Domain“ (wie Safari), außer der Titel ist schon die Domain selbst.
    if (title.length > 0 && host.length > 0 && [title.lowercaseString isEqualToString:host.lowercaseString]) {
        [self.topMenuView setDisplayTitle:title domain:nil secure:secure];
    } else if (title.length > 0 && host.length > 0) {
        [self.topMenuView setDisplayTitle:title domain:host secure:secure];
    } else if (host.length > 0) {
        [self.topMenuView setDisplayTitle:host domain:nil secure:secure];
    } else {
        [self.topMenuView setDisplayTitle:(currentURL.length > 0 ? currentURL : BLS(@"Neuer Tab")) domain:nil secure:NO];
    }

    if (request != nil) {
        [self.host browserTabCoordinatorUpdateTextFontSize];
    }
}

- (BOOL)restoreBrowserSession {
    return [self.sessionStore restoreSessionIntoViewModel:self.viewModel];
}

- (void)restoreInitialStateOrCreateFirstTab {
    self.topMenuView.hidden = !self.viewModel.topNavigationBarVisible;
    if (![self restoreBrowserSession]) {
        [self createNewTabLoadingHomePage:NO];
        return;
    }
    self.launchHomePagePending = YES;
    [self initWebView];
    [self refreshActiveTabUI];
}

- (void)webViewDidAppear {
    NSURLRequest *savedReopenRequest = [self.sessionStore consumeSavedURLToReopenRequestWithNavigationService:self.navigationService];
    BOOL showHome = self.launchHomePagePending;
    self.launchHomePagePending = NO;
    if (savedReopenRequest != nil) {
        [self.activeWebView loadRequest:savedReopenRequest];
    } else if (showHome && [self showHomePageAfterLaunch]) {
        return;
    } else if (self.activeWebView.request == nil) {
        [self loadStoredContentForTab:self.activeTab webView:self.activeWebView fallbackToHomePage:YES];
    }
}

static BOOL BrowserTabShowsHomePage(NSString *urlString, NSURL *home) {
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (url.host.length == 0 || home.host.length == 0) {
        return NO;
    }
    NSString *(^host)(NSURL *) = ^NSString *(NSURL *u) {
        NSString *h = u.host.lowercaseString;
        return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
    };
    NSString *(^path)(NSURL *) = ^NSString *(NSURL *u) {
        NSString *p = u.path.length > 0 ? u.path : @"/";
        return [p hasSuffix:@"/"] && p.length > 1 ? [p substringToIndex:p.length - 1] : p;
    };
    return [host(url) isEqualToString:host(home)] && [path(url) isEqualToString:path(home)];
}

/// Start nach wiederhergestellter Sitzung: Tab mit der Startseite nach vorn holen, sonst die Startseite in einem neuen
/// Tab öffnen (leerer aktiver Tab: dort). Sind alle Tabs belegt, lädt der aktive Tab die Startseite (Zurück führt zur
/// vorigen Seite). NO: keine Startseite eingestellt, dann wie bisher den letzten Tab laden.
- (BOOL)showHomePageAfterLaunch {
    NSURLRequest *home = [self.navigationService homePageRequest];
    if (home.URL == nil) {
        return NO;
    }
    NSArray<BrowserTabViewModel *> *tabs = [self.viewModel.tabs copy];
    for (NSUInteger index = 0; index < tabs.count; index++) {
        BrowserTabViewModel *tab = tabs[index];
        if (BrowserTabShowsHomePage(tab.URLString, home.URL) || BrowserTabShowsHomePage(tab.requestURL, home.URL)) {
            NSLog(@"[Tabs] Start: Startseite steht schon in Tab %lu", (unsigned long)index);
            if ((NSInteger)index != self.viewModel.activeTabIndex) {
                [self switchToTabAtIndex:(NSInteger)index];
                [self refreshActiveTabUI];
            } else if (self.activeWebView.request == nil) {
                [self loadStoredContentForTab:self.activeTab webView:self.activeWebView fallbackToHomePage:YES];
            }
            return YES;
        }
    }
    BrowserTabViewModel *active = self.activeTab;
    if (active.URLString.length == 0 && active.requestURL.length == 0) {
        NSLog(@"[Tabs] Start: Startseite im leeren aktiven Tab");
        [self.activeWebView loadRequest:home];
        return YES;
    }
    if (tabs.count >= BrowserViewModel.maximumTabCount || ![self createNewTabWithRequest:home]) {
        NSLog(@"[Tabs] Start: alle Tabs belegt, Startseite im aktiven Tab");
        [self.activeWebView loadRequest:home];
        return YES;
    }
    NSLog(@"[Tabs] Start: Startseite in neuem Tab %ld, %lu Tabs im Hintergrund", (long)self.viewModel.activeTabIndex, (unsigned long)tabs.count);
    return YES;
}

- (void)loadHomePage {
    NSURLRequest *homePageRequest = [self.navigationService homePageRequest];
    if (homePageRequest != nil) {
        [self.activeWebView loadRequest:homePageRequest];
    }
}

- (void)initWebView {
    self.topMenuView.hidden = !self.viewModel.topNavigationBarVisible;

    BrowserTabViewModel *tab = [self.viewModel ensureActiveTab];
    if (tab == nil) {
        return;
    }

    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    if (webView == nil) {
        webView = [self createConfiguredWebView];
        self.webViewsByTabIdentifier[tab.identifier] = webView;
    }
    self.activeWebView = webView;
    [self attachActiveWebView];
}

- (void)attachActiveWebView {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        return;
    }

    BrowserWebView *activeWebView = self.webViewsByTabIdentifier[tab.identifier];
    if (activeWebView == nil) {
        return;
    }

    // Angezeigt = benutzt: Ein Tab, zu dem der Nutzer wechselt, schließt sich nie mehr von selbst.
    [self markTabUsed:tab];
    tab.lastActivatedAt = NSDate.date.timeIntervalSince1970;
    [self updateThumbnailStagingViewFrame];
    for (BrowserTabViewModel *candidate in self.viewModel.tabs) {
        BrowserWebView *candidateWebView = self.webViewsByTabIdentifier[candidate.identifier];
        if (candidateWebView == nil || candidateWebView == activeWebView) {
            continue;
        }
        [self parkWebViewForThumbnailing:candidateWebView];
    }

    self.activeWebView = activeWebView;
    [self.topMenuView.loadingSpinner stopAnimating];
    [self.activeWebView removeFromSuperview];
    [self.browserContainerView addSubview:self.activeWebView];
    [self updateTopNavAndWebView];

    UIScrollView *scrollView = self.activeWebView.scrollView;
    [scrollView setNeedsLayout];
    [scrollView layoutIfNeeded];
    [self.rootView setNeedsLayout];
    [self.rootView layoutIfNeeded];
    scrollView.bounces = self.scrollViewAllowBounces;

    BOOL shouldAllowWebInteraction = ![self.host browserTabCoordinatorIsCursorModeEnabled] &&
        ![self.host browserTabCoordinatorIsTabOverviewVisible];
    scrollView.scrollEnabled = shouldAllowWebInteraction;
    self.activeWebView.userInteractionEnabled = shouldAllowWebInteraction;
    self.manualScrollPanRecognizer.enabled = shouldAllowWebInteraction;

    [self refreshActiveTabUI];
    [self unloadTabsBeyondLoadedBudget];
}

- (NSUInteger)loadedTabCount {
    NSUInteger count = 0;
    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        if (self.webViewsByTabIdentifier[tab.identifier] != nil) {
            count++;
        }
    }
    return count;
}

/// Mehr als kMaximumLoadedTabCount Tabs mit WebView: die am längsten nicht angezeigten entladen, nie den aktiven.
- (void)unloadTabsBeyondLoadedBudget {
    NSUInteger loaded = [self loadedTabCount];
    if (loaded <= kMaximumLoadedTabCount) {
        return;
    }
    BrowserTabViewModel *activeTab = self.activeTab;
    NSMutableArray<BrowserTabViewModel *> *candidates = [NSMutableArray array];
    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        if (tab != activeTab && self.webViewsByTabIdentifier[tab.identifier] != nil) {
            [candidates addObject:tab];
        }
    }
    // Stabil sortiert: bei gleichem Zeitpunkt (z. B. nie angezeigt) zuerst die weiter vorn stehenden Tabs.
    [candidates sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(BrowserTabViewModel *a, BrowserTabViewModel *b) {
        if (a.lastActivatedAt < b.lastActivatedAt) {
            return NSOrderedAscending;
        }
        return a.lastActivatedAt > b.lastActivatedAt ? NSOrderedDescending : NSOrderedSame;
    }];
    for (BrowserTabViewModel *tab in candidates) {
        if (loaded <= kMaximumLoadedTabCount) {
            break;
        }
        [self unloadWebViewForTab:tab];
        loaded--;
        NSLog(@"[Tabs] Hintergrund-Tab entladen: %@ (geladen %lu/%lu)", tab.URLString.length > 0 ? tab.URLString : tab.requestURL,
              (unsigned long)loaded, (unsigned long)kMaximumLoadedTabCount);
    }
}

/// WebView eines Hintergrund-Tabs freigeben (wie beim Schließen). Scrollposition und Vorschaubild bleiben; beim nächsten
/// Anzeigen lädt der Tab seine Adresse neu und springt an die alte Stelle. Der Verlauf (Zurück/Vor) geht verloren.
- (void)unloadWebViewForTab:(BrowserTabViewModel *)tab {
    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    if (webView == nil || tab == self.activeTab) {
        return;
    }
    if (tab.snapshotImage == nil) {
        [self captureSnapshotForTab:tab];
    } else {
        [self updateStoredScrollOffsetForTab:tab];
    }
    if (tab.hasSavedScrollOffset) {
        tab.needsScrollRestore = YES;
    }
    [webView closePage];
    [webView removeFromSuperview];
    [self.webViewsByTabIdentifier removeObjectForKey:tab.identifier];
}

- (BOOL)isTabLoaded:(BrowserTabViewModel *)tab {
    return tab != nil && self.webViewsByTabIdentifier[tab.identifier] != nil;
}

- (void)updateStoredScrollOffsetForTab:(BrowserTabViewModel *)tab {
    if (tab == nil) {
        return;
    }

    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    // Solange die Seite nach dem Neuladen noch nicht an die alte Stelle gesprungen ist, gilt die gespeicherte Position
    // (die neue WebView steht noch oben).
    if (webView == nil || tab.needsScrollRestore) {
        return;
    }

    UIScrollView *scrollView = webView.scrollView;
    tab.savedScrollOffset = scrollView.contentOffset;
    tab.hasSavedScrollOffset = YES;
}

- (void)persistSession {
    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        [self updateStoredScrollOffsetForTab:tab];
    }
    [self.sessionStore saveSessionForViewModel:self.viewModel];
}

- (void)loadStoredContentForTab:(BrowserTabViewModel *)tab
                        webView:(BrowserWebView *)webView
             fallbackToHomePage:(BOOL)fallbackToHomePage {
    if (webView == nil) {
        return;
    }

    NSString *URLString = tab.URLString.length > 0 ? tab.URLString : tab.requestURL;
    if (URLString.length == 0) {
        if (fallbackToHomePage) {
            NSURLRequest *homePageRequest = [self.navigationService homePageRequest];
            if (homePageRequest != nil) {
                [webView loadRequest:homePageRequest];
            }
        }
        return;
    }

    NSURLRequest *request = [self.navigationService requestForURLString:URLString];
    if (request != nil) {
        [webView loadRequest:request];
    } else if (fallbackToHomePage) {
        NSURLRequest *homePageRequest = [self.navigationService homePageRequest];
        if (homePageRequest != nil) {
            [webView loadRequest:homePageRequest];
        }
    }
}

- (void)restoreSavedScrollOffsetForTab:(BrowserTabViewModel *)tab webView:(BrowserWebView *)webView {
    if (tab == nil || !tab.needsScrollRestore || !tab.hasSavedScrollOffset) {
        return;
    }

    UIScrollView *scrollView = webView.scrollView;
    CGPoint savedScrollOffset = tab.savedScrollOffset;
    dispatch_async(dispatch_get_main_queue(), ^{
        [scrollView layoutIfNeeded];
        CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
        CGFloat minOffsetY = -scrollView.contentInset.top;
        CGFloat maxOffsetY = MAX(minOffsetY, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds));
        CGPoint clampedScrollOffset = CGPointMake(MIN(MAX(savedScrollOffset.x, 0.0), maxOffsetX),
                                                  MIN(MAX(savedScrollOffset.y, minOffsetY), maxOffsetY));
        [scrollView setContentOffset:clampedScrollOffset animated:NO];
        tab.savedScrollOffset = clampedScrollOffset;
        tab.hasSavedScrollOffset = YES;
        [self captureSnapshotForTab:tab];
        [self persistSession];
    });
    tab.needsScrollRestore = NO;
}

- (void)captureSnapshotForTab:(BrowserTabViewModel *)tab {
    if (tab == nil) {
        return;
    }

    if (!tab.needsScrollRestore) {
        [self updateStoredScrollOffsetForTab:tab];
    }

    BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
    if (webView == nil || CGRectIsEmpty(webView.bounds)) {
        return;
    }
    // Entladener Tab lädt gerade neu: das Bild von vorher ist besser als eine halb geladene Seite.
    if (tab.needsScrollRestore && tab.snapshotImage != nil) {
        return;
    }

    [self prepareWebViewLayoutForSnapshot:webView];
    // Nur so fein wie die Karte der Tab-Übersicht (584 pt breit), nicht in voller Bildschirmauflösung: ein Bild in
    // Bildschirmgröße kostet am Apple TV 4K rund 33 MB je Tab und blieb bis zum Schließen des Tabs im Speicher.
    CGFloat screenScale = webView.window.screen.scale ?: UIScreen.mainScreen.scale;
    CGFloat scale = MIN(screenScale, kThumbnailMaximumWidth * screenScale / CGRectGetWidth(webView.bounds));
    UIGraphicsBeginImageContextWithOptions(webView.bounds.size, YES, scale);
    [webView drawViewHierarchyInRect:webView.bounds afterScreenUpdates:NO];
    UIImage *snapshotImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (snapshotImage != nil) {
        tab.snapshotImage = snapshotImage;
    }
}

- (void)captureSnapshotForCurrentTab {
    [self captureSnapshotForTab:self.activeTab];
}

- (void)prepareTabOverviewThumbnails {
    [self updateThumbnailStagingViewFrame];

    // Geladene Tabs: Vorschau neu aufnehmen. Entladene Tabs behalten ihr Vorschaubild.
    NSMutableArray<BrowserTabViewModel *> *missing = [NSMutableArray array];
    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        BrowserWebView *webView = self.webViewsByTabIdentifier[tab.identifier];
        if (tab == self.activeTab) {
            [self captureSnapshotForTab:tab];
            continue;
        }
        if (webView != nil) {
            [self parkWebViewForThumbnailing:webView];
            if (webView.request == nil) {
                [self loadStoredContentForTab:tab webView:webView fallbackToHomePage:NO];
            } else {
                [self captureSnapshotForTab:tab];
            }
            continue;
        }
        // Ohne Bild (z. B. nach einem Neustart) nur im Rahmen des Ladebudgets für die Vorschau laden. Nie unbenutzte
        // Hintergrund-Tabs (Pop-ups): Die laden erst, wenn der Nutzer sie öffnet; die Karte zeigt Titel und Adresse.
        if (tab.snapshotImage == nil && tab.userInteracted) {
            [missing addObject:tab];
        }
    }

    // Zuletzt benutzte zuerst.
    [missing sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(BrowserTabViewModel *a, BrowserTabViewModel *b) {
        if (a.lastActivatedAt > b.lastActivatedAt) {
            return NSOrderedAscending;
        }
        return a.lastActivatedAt < b.lastActivatedAt ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger loaded = [self loadedTabCount];
    for (NSUInteger index = 0; index < missing.count; index++) {
        BrowserTabViewModel *tab = missing[index];
        if (loaded >= kMaximumLoadedTabCount) {
            NSLog(@"[Tabs] Übersicht: %lu Tabs ohne Vorschau, Ladebudget %lu erreicht", (unsigned long)(missing.count - index),
                  (unsigned long)kMaximumLoadedTabCount);
            break;
        }
        BrowserWebView *webView = [self createConfiguredWebView];
        self.webViewsByTabIdentifier[tab.identifier] = webView;
        [self parkWebViewForThumbnailing:webView];
        [self loadStoredContentForTab:tab webView:webView fallbackToHomePage:NO];
        loaded++;
        NSLog(@"[Tabs] Übersicht: lade Tab für Vorschau: %@ (geladen %lu/%lu)", tab.URLString.length > 0 ? tab.URLString : tab.requestURL,
              (unsigned long)loaded, (unsigned long)kMaximumLoadedTabCount);
    }
}

- (void)showMaxTabsAlert {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BLS(@"Zu viele Tabs")
                                                                             message:BLS(@"Es können höchstens zehn Tabs gleichzeitig offen sein.")
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"Schließen")
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self.host browserTabCoordinatorPresentViewController:alertController];
}

- (void)createNewTabLoadingHomePage:(BOOL)loadHomePage {
    BrowserTabViewModel *tab = [self.viewModel addTab];
    if (tab == nil) {
        [self showMaxTabsAlert];
        return;
    }

    (void)tab;
    [self initWebView];
    [self refreshActiveTabUI];
    [self.rootView bringSubviewToFront:self.cursorView];

    if (loadHomePage) {
        [self loadHomePage];
    }
    [self persistSession];
}

- (BOOL)createNewTabWithRequest:(NSURLRequest *)request {
    if (request == nil || request.URL == nil) {
        return NO;
    }

    [self captureSnapshotForTab:self.activeTab];
    if ([self.viewModel addTab] == nil) {
        [self showMaxTabsAlert];
        return NO;
    }

    [self initWebView];
    [self refreshActiveTabUI];
    [self.rootView bringSubviewToFront:self.cursorView];
    [self.activeWebView loadRequest:request];
    [self persistSession];
    return YES;
}

- (void)markTabUsed:(BrowserTabViewModel *)tab {
    if (tab == nil || tab.userInteracted) {
        return;
    }
    tab.userInteracted = YES;
    NSLog(@"[Tabs] Tab benutzt: %@", tab.URLString.length > 0 ? tab.URLString : tab.requestURL);
}

- (BrowserTabViewModel *)createBackgroundTabWithRequest:(NSURLRequest *)request {
    if (request == nil || request.URL == nil) {
        return nil;
    }
    BrowserTabViewModel *tab = [self.viewModel addBackgroundTab];
    if (tab == nil) {
        return nil;
    }
    tab.userInteracted = NO;
    tab.openedAt = NSDate.date.timeIntervalSince1970;
    NSString *URLString = request.URL.absoluteString ?: @"";
    tab.requestURL = URLString;
    tab.URLString = URLString;
    tab.title = request.URL.host.length > 0 ? request.URL.host : BLS(@"Neuer Tab");
    // Noch nicht laden: keine WebView, kein Seitenprozess. Erst beim Öffnen (Einblendung oder Tab-Übersicht) lädt
    // switchToTabAtIndex: die Anfrage. So verdrängt ein Pop-up keinen anderen Tab aus dem Speicher.
    tab.pendingRequest = request;
    NSLog(@"[Tabs] Hintergrund-Tab angelegt, lädt erst beim Öffnen: %@ (geladen %lu/%lu)", URLString,
          (unsigned long)[self loadedTabCount], (unsigned long)kMaximumLoadedTabCount);
    [self persistSession];
    return tab;
}

/// Aktiver Tab hat eine frische WebView ohne Seite: zurückgestellte Pop-up-Anfrage oder gespeicherte Adresse laden.
- (void)loadContentIntoEmptyActiveWebView {
    if (self.activeWebView == nil || self.activeWebView.request != nil) {
        return;
    }
    BrowserTabViewModel *tab = self.activeTab;
    NSURLRequest *pendingRequest = tab.pendingRequest;
    tab.pendingRequest = nil;
    if (pendingRequest != nil) {
        [self.activeWebView loadRequest:pendingRequest];
        return;
    }
    [self loadStoredContentForTab:tab webView:self.activeWebView fallbackToHomePage:YES];
}

- (NSUInteger)closeUnusedTabsOlderThan:(NSTimeInterval)expiry {
    if (expiry <= 0.0) {
        return 0;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSUInteger closed = 0;
    for (NSInteger index = (NSInteger)self.viewModel.tabs.count - 1; index >= 0; index--) {
        if (self.viewModel.tabs.count <= 1) {
            break; // Der letzte Tab bleibt immer.
        }
        if (index >= (NSInteger)self.viewModel.tabs.count || index == self.viewModel.activeTabIndex) {
            continue; // Der sichtbare Tab schließt sich nie von selbst.
        }
        BrowserTabViewModel *tab = self.viewModel.tabs[index];
        NSTimeInterval age = now - tab.openedAt;
        if (tab.userInteracted || age < expiry) {
            continue;
        }
        NSLog(@"[Tabs] unbenutzten Tab automatisch geschlossen nach %.0f s: %@", age,
              tab.URLString.length > 0 ? tab.URLString : tab.requestURL);
        [self closeTabAtIndex:index];
        closed++;
    }
    return closed;
}

- (void)switchToTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.viewModel.tabs.count) {
        return;
    }

    BrowserTabViewModel *currentTab = self.activeTab;
    [self captureSnapshotForTab:currentTab];

    [self.viewModel switchToTabAtIndex:tabIndex];
    [self initWebView];
    [self.rootView bringSubviewToFront:self.cursorView];
    // Entladener Tab oder noch nicht geladenes Pop-up: jetzt laden (Scrollposition folgt in webViewDidFinishLoad:).
    [self loadContentIntoEmptyActiveWebView];
    [self persistSession];
}

- (void)closeTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= self.viewModel.tabs.count) {
        return;
    }

    BOOL closingActiveTab = tabIndex == self.viewModel.activeTabIndex;
    BrowserTabViewModel *tab = self.viewModel.tabs[tabIndex];
    [self.webViewsByTabIdentifier[tab.identifier] closePage];
    [self.webViewsByTabIdentifier[tab.identifier] removeFromSuperview];
    [self.webViewsByTabIdentifier removeObjectForKey:tab.identifier];
    [self.viewModel removeTabAtIndex:tabIndex];

    if (self.viewModel.tabs.count == 0) {
        [self createNewTabLoadingHomePage:YES];
        return;
    }

    if (closingActiveTab) {
        [self initWebView];
        [self loadContentIntoEmptyActiveWebView];
    }

    [self refreshActiveTabUI];
    [self persistSession];
}

- (void)recreateActiveWebViewPreservingCurrentURL {
    BrowserTabViewModel *tab = self.activeTab;
    if (tab == nil) {
        return;
    }

    NSString *currentURL = self.activeWebView.request.URL.absoluteString;
    [self.webViewsByTabIdentifier[tab.identifier] closePage];
    [self.webViewsByTabIdentifier[tab.identifier] removeFromSuperview];
    [self.webViewsByTabIdentifier removeObjectForKey:tab.identifier];
    tab.requestURL = currentURL ?: @"";
    tab.previousURL = @"";
    tab.URLString = currentURL ?: @"";
    [self initWebView];

    if (currentURL.length > 0) {
        NSURLRequest *request = [self.navigationService requestForURLString:currentURL];
        if (request != nil) {
            [self.activeWebView loadRequest:request];
        }
    } else {
        [self loadHomePage];
    }
    [self persistSession];
}

- (void)handleWebViewPanGesture:(UIPanGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state != UIGestureRecognizerStateEnded &&
        gestureRecognizer.state != UIGestureRecognizerStateCancelled &&
        gestureRecognizer.state != UIGestureRecognizerStateFailed) {
        return;
    }

    UIView *gestureView = gestureRecognizer.view;
    if (![gestureView isKindOfClass:[UIScrollView class]]) {
        return;
    }

    UIScrollView *scrollView = (UIScrollView *)gestureView;
    if (scrollView != self.activeWebView.scrollView) {
        return;
    }

    [self persistSession];
}

- (BOOL)isPrimaryDocumentRequest:(NSURLRequest *)request {
    NSURL *requestURL = request.URL;
    NSURL *mainDocumentURL = request.mainDocumentURL;
    if (requestURL == nil) {
        return NO;
    }
    if (mainDocumentURL == nil) {
        return YES;
    }
    return [requestURL isEqual:mainDocumentURL];
}

- (BrowserTabViewModel *)tabForWebView:(id)webView {
    for (BrowserTabViewModel *tab in self.viewModel.tabs) {
        if (self.webViewsByTabIdentifier[tab.identifier] == webView) {
            return tab;
        }
    }
    return nil;
}

- (void)prepareTabForRequest:(NSURLRequest *)request webView:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil || ![self isPrimaryDocumentRequest:request]) {
        return;
    }
    NSString *requestURL = request.URL.absoluteString ?: @"";
    if (tab.URLString.length > 0 && ![tab.URLString isEqualToString:requestURL]) {
        tab.savedScrollOffset = CGPointZero;
        tab.hasSavedScrollOffset = NO;
        tab.needsScrollRestore = NO;
    }
    tab.requestURL = requestURL;
}

- (void)webViewDidStartLoad:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    if (tab == self.activeTab && ![tab.previousURL isEqualToString:tab.requestURL]) {
        [self.topMenuView.loadingSpinner startAnimating];
    }
    tab.previousURL = tab.requestURL;
}

- (void)webViewDidFinishLoad:(id)webView {
    BrowserTabViewModel *tab = [self tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    if (tab == self.activeTab) {
        [self.topMenuView.loadingSpinner stopAnimating];
    }

    NSString *theTitle = [webView stringByEvaluatingJavaScriptFromString:@"document.title"];
    NSURLRequest *request = [webView request];
    NSString *currentURL = request.URL.absoluteString ?: @"";
    [self.navigationService updateTab:tab withPageTitle:theTitle currentURLString:currentURL];

    if (tab == self.activeTab) {
        [self refreshActiveTabUI];
    } else if ([self isWebViewStaged:webView]) {
        [webView pauseAllMediaPlayback];
    }
    [self restoreSavedScrollOffsetForTab:tab webView:webView];
    if (!tab.needsScrollRestore) {
        [self captureSnapshotForTab:tab];
        [self persistSession];
    }
}

@end
