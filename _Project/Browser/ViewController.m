//
//  ViewController.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "BrowserMenuCoordinator.h"
#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserNowPlayingController.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserRemoteInputController.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserNowPlayingController *nowPlayingController;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;

@end

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.definesPresentationContext = YES;
    self.scrollViewAllowBounces = YES;

    self.preferencesStore = [BrowserPreferencesStore new];
    [self.preferencesStore ensureUserAgentConsistency];

    self.viewModel = [BrowserViewModel new];
    self.viewModel.topNavigationBarVisible = self.preferencesStore.topNavigationBarVisible;
    self.viewModel.textFontSize = self.preferencesStore.textFontSize;
    self.viewModel.fullscreenVideoPlaybackEnabled = self.preferencesStore.fullscreenVideoPlaybackEnabled;

    self.domInteractionService = [BrowserDOMInteractionService new];
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.nowPlayingController = [BrowserNowPlayingController new];
    __weak typeof(self) weakNowPlayingSelf = self;
    self.nowPlayingController.commandHandler = ^(NSString *command) {
        [weakNowPlayingSelf.webview sendVideoCommand:command];
    };
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
    [self.view addSubview:self.remoteInputController.cursorView];
    self.videoPlaybackCoordinator = [[BrowserVideoPlaybackCoordinator alloc] initWithHost:self
                                                                      domInteractionService:self.domInteractionService];
    self.tabCoordinator = [[BrowserTabCoordinator alloc] initWithHost:self
                                                             viewModel:self.viewModel
                                                      preferencesStore:self.preferencesStore
                                                     navigationService:self.navigationService
                                                          sessionStore:self.sessionStore
                                                    browserContainerView:self.browserContainerView
                                                              rootView:self.view
                                                            topMenuView:self.topMenuView
                                                            cursorView:self.remoteInputController.cursorView
                                               manualScrollPanRecognizer:self.remoteInputController.manualScrollPanRecognizer
                                                           webViewDelegate:self
                                                       scrollViewAllowBounces:self.scrollViewAllowBounces];
    self.tabOverviewController = [[BrowserTabOverviewController alloc] initWithHost:self
                                                                            viewModel:self.viewModel
                                                                             rootView:self.view
                                                                           topMenuView:self.topMenuView
                                                                           cursorView:self.remoteInputController.cursorView];
    self.pageActionCoordinator = [[BrowserPageActionCoordinator alloc] initWithHost:self
                                                               domInteractionService:self.domInteractionService
                                                                   navigationService:self.navigationService
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator];

    self.topMenuView.delegate = self;
    self.topMenuView.loadingSpinner.hidesWhenStopped = YES;
    self.remoteInputController.cursorView.hidden = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalSelectPressEndedNotification:)
                                                 name:kBrowserGlobalSelectPressEndedNotification
                                               object:nil];

    [self.tabCoordinator restoreInitialStateOrCreateFirstTab];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tabCoordinator webViewDidAppear];
    if (!self.preferencesStore.dontShowHintsOnLaunch && !self.displayedHintsOnLaunch) {
        [self showHintsAlert];
    }
    self.displayedHintsOnLaunch = YES;
#if DEBUG
    [self runPointerSelfTestIfRequested];
#endif
}

#if DEBUG
/// Selbsttest ohne Fernbedienung: POINTER_SELFTEST="x,y;x,y;…" fährt die Punkte im Abstand von 3 s ab.
/// Ein Punkt "click" löst einen Klick aus. Vorher werden offene Hinweise geschlossen.
- (void)runPointerSelfTestIfRequested {
    NSString *spec = NSProcessInfo.processInfo.environment[@"POINTER_SELFTEST"];
    if (spec.length == 0) {
        return;
    }
    NSArray<NSString *> *steps = [spec componentsSeparatedByString:@";"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dismissViewControllerAnimated:NO completion:nil];
        [steps enumerateObjectsUsingBlock:^(NSString *step, NSUInteger index, __unused BOOL *stop) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((index * 3 + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if ([step isEqualToString:@"click"]) {
                    NSLog(@"[SelfTest] click");
                    [self browserHandlePrimaryAction];
                    return;
                }
                if ([step hasPrefix:@"url:"]) {
                    NSURL *url = [NSURL URLWithString:[step substringFromIndex:4]];
                    NSLog(@"[SelfTest] load %@", url);
                    if (url != nil) {
                        [self.webview loadRequest:[NSURLRequest requestWithURL:url]];
                    }
                    return;
                }
                if ([step isEqualToString:@"playpause"]) {
                    NSLog(@"[SelfTest] playpause overVideo=%d playing=%d", [self pointerIsOverVideo], self.webview.videoPlaying);
                    [self browserRemoteInputControllerHandlePlayPausePress];
                    return;
                }
                if ([step isEqualToString:@"left"] || [step isEqualToString:@"right"]) {
                    NSLog(@"[SelfTest] %@ overVideo=%d", step, [self pointerIsOverVideo]);
                    if ([step isEqualToString:@"left"]) {
                        [self browserRemoteInputControllerNavigateBack];
                    } else {
                        [self browserRemoteInputControllerNavigateForward];
                    }
                    return;
                }
                if ([step hasPrefix:@"fill:"]) {
                    UIAlertController *alert = [self.presentedViewController isKindOfClass:UIAlertController.class] ? (UIAlertController *)self.presentedViewController : nil;
                    NSArray<NSString *> *values = [[step substringFromIndex:5] componentsSeparatedByString:@"|"];
                    NSLog(@"[SelfTest] fill alert=%@ fields=%lu types=%@", alert.title, (unsigned long)alert.textFields.count, [alert.textFields valueForKey:@"textContentType"]);
                    for (NSUInteger i = 0; i + 1 < values.count && i < alert.textFields.count; i++) {
                        alert.textFields[i].text = values[i];
                    }
                    NSInteger actionIndex = values.lastObject.integerValue;
                    if (alert != nil && actionIndex >= 0 && actionIndex < (NSInteger)alert.actions.count) {
                        UIAlertAction *action = alert.actions[actionIndex];
                        void (^handler)(UIAlertAction *) = [action valueForKey:@"handler"];
                        NSLog(@"[SelfTest] tap %@", action.title);
                        [alert dismissViewControllerAnimated:NO completion:^{
                            if (handler != nil) {
                                handler(action);
                            }
                        }];
                    }
                    return;
                }
                if ([step hasPrefix:@"js:"]) {
                    [self.webview evaluateJavaScriptAsync:[step substringFromIndex:3] completion:^(id result) {
                        NSLog(@"[SelfTest] js %@", result);
                    }];
                    return;
                }
                if ([step isEqualToString:@"video"]) {
                    [self.webview evaluateJavaScriptAsync:@"(function(){var v=document.querySelector('video');return v?('t='+v.currentTime.toFixed(1)+' paused='+v.paused+' ready='+v.readyState+' net='+v.networkState+' err='+(v.error?v.error.code:0)+' playErr='+(window.__browserLastPlayError||'')):'none';})()"
                                               completion:^(id result) {
                        NSLog(@"[SelfTest] video %@ rects=%lu playing=%d idle=%d", result, (unsigned long)[self.webview videoRects].count, self.webview.videoPlaying, UIApplication.sharedApplication.idleTimerDisabled);
                    }];
                    return;
                }
                NSArray<NSString *> *parts = [step componentsSeparatedByString:@","];
                if (parts.count != 2) {
                    return;
                }
                CGPoint point = CGPointMake(parts[0].doubleValue, parts[1].doubleValue);
                NSLog(@"[SelfTest] move %@ targets=%lu", NSStringFromCGPoint(point), (unsigned long)[self browserRemoteInputControllerPointerTargets].count);
                [self.remoteInputController movePointerToPoint:point];
            });
        }];
    });
}
#endif

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleGlobalSelectPressEndedNotification:(NSNotification *)notification {
    (void)notification;
    [self.remoteInputController handleGlobalSelectPressEndedNotification];
}

#pragma mark - Helpers

- (BrowserWebView *)webview {
    return self.tabCoordinator.activeWebView;
}

- (CGPoint)browserDOMPointForCursor {
    return [self.domInteractionService DOMPointForCursorOrigin:self.remoteInputController.cursorView.frame.origin
                                                        inView:self.view
                                                       webView:self.webview];
}

- (void)loadHomePage {
    [self.tabCoordinator loadHomePage];
}

- (void)showAdvancedMenu {
    [self deactivateTopBarFocusMode];
    [self.menuCoordinator showAdvancedMenu];
}

- (BOOL)canActivateTopBarFocusMode {
    return self.presentedViewController == nil &&
        !self.tabOverviewController.visible &&
        self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden;
}

- (void)activateTopBarFocusMode {
    if (![self canActivateTopBarFocusMode]) {
        return;
    }
    if (self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = YES;
    [self.topMenuView setFocusModeActive:YES];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)deactivateTopBarFocusMode {
    if (!self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = NO;
    [self.topMenuView setFocusModeActive:NO];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)performTopBarAction:(BrowserTopBarAction)action {
    [self deactivateTopBarFocusMode];

    switch (action) {
        case BrowserTopBarActionBack:
            if (self.webview.canGoBack) {
                [self.webview goBack];
            }
            break;
        case BrowserTopBarActionRefresh:
            [self.webview reload];
            break;
        case BrowserTopBarActionForward:
            if (self.webview.canGoForward) {
                [self.webview goForward];
            }
            break;
        case BrowserTopBarActionHome:
            [self loadHomePage];
            break;
        case BrowserTopBarActionTabs:
            [self browserShowTabOverview];
            break;
        case BrowserTopBarActionURL:
            [self showInputURLorSearchGoogle];
            break;
        case BrowserTopBarActionFullscreen:
            if (self.viewModel.topNavigationBarVisible) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Hide Top Navigation bar?"
                                                                                         message:@"You can still open the side menu by double-tapping the Play/Pause button."
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Hide Bar"
                                                                    style:UIAlertActionStyleDestructive
                                                                  handler:^(__unused UIAlertAction *action) {
                    [self browserHideTopNav];
                }]];
                [self browserPresentViewController:alertController];
            } else {
                [self browserShowTopNav];
            }
            break;
        case BrowserTopBarActionMenu:
            [self showAdvancedMenu];
            break;
    }
}

- (void)updateTextFontSize {
    if (self.webview == nil) {
        return;
    }

    NSString *jsString = [[NSString alloc] initWithFormat:
                          @"(function(){"
                           "var value='%lu%%';"
                           "var multiplier=%lu/100;"
                           "if (document.documentElement && document.documentElement.style) {"
                               "document.documentElement.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.documentElement.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (document.body && document.body.style) {"
                               "document.body.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.body.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (!document.body || !window.getComputedStyle) { return value; }"
                           "var elements = document.querySelectorAll('body, body *');"
                           "for (var i = 0; i < elements.length; i++) {"
                               "var element = elements[i];"
                               "if (!element || !element.tagName) { continue; }"
                               "var tagName = element.tagName.toLowerCase();"
                               "if (tagName === 'script' || tagName === 'style' || tagName === 'noscript') { continue; }"
                               "var originalSize = element.getAttribute('data-browser-original-font-size');"
                               "if (!originalSize) {"
                                   "var computedSize = window.getComputedStyle(element).fontSize || '';"
                                   "if (computedSize.indexOf('px') == -1) { continue; }"
                                   "var parsedSize = parseFloat(computedSize);"
                                   "if (!isFinite(parsedSize) || parsedSize <= 0) { continue; }"
                                   "originalSize = String(parsedSize);"
                                   "element.setAttribute('data-browser-original-font-size', originalSize);"
                               "}"
                               "var baseSize = parseFloat(originalSize);"
                               "if (!isFinite(baseSize) || baseSize <= 0) { continue; }"
                               "element.style.setProperty('font-size', (baseSize * multiplier) + 'px', 'important');"
                           "}"
                           "return value;"
                          "})()",
                          (unsigned long)self.viewModel.textFontSize,
                          (unsigned long)self.viewModel.textFontSize];
    [self.webview stringByEvaluatingJavaScriptFromString:jsString];
}

- (void)showInputURLorSearchGoogle {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Adresse oder Suchbegriff"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeURL;
        textField.placeholder = @"z. B. computerbase.de oder Suchbegriff";
        [textField setReturnKeyType:UIReturnKeyDone];
    }];

    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Mit Google suchen"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForQuery:textField.text];
        if (searchRequest != nil) {
            [weakSelf.webview loadRequest:searchRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Website öffnen"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        if (textField.text.length == 0) {
            [weakSelf requestURLorSearchInput];
            return;
        }
        NSURLRequest *navigationRequest = [weakSelf.navigationService requestForEnteredAddressString:textField.text];
        if (navigationRequest != nil) {
            [weakSelf.webview loadRequest:navigationRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];

    UITextField *textField = alertController.textFields.firstObject;
    if (self.webview.request == nil || self.webview.request.URL.absoluteString.length > 0) {
        [textField becomeFirstResponder];
    }
}

- (void)requestURLorSearchInput {
    NSString *host = self.webview.request.URL.host;
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Schnellmenü"
                                                                             message:host.length > 0 ? host : @""
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;

    [alertController addAction:[UIAlertAction actionWithTitle:@"Adresse oder Suche"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf showInputURLorSearchGoogle];
    }]];

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Neu laden"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    }

    if (self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Vor"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf.webview goForward];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"Neuer Tab"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf browserCreateNewTabLoadingHomePage:YES];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Tabs anzeigen"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf browserShowTabOverview];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Startseite"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf loadHomePage];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Weitere Einstellungen …"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf showAdvancedMenu];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)showHintsAlert {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Bedienung"
                                                                             message:@"Wischen bewegt den Zeiger. In der Nähe von Links und Knöpfen rastet er ein.\nClickpad drücken: klicken.\nClickpad oben/unten drücken: eine Seite scrollen. Zeiger an den Rand schieben scrollt ebenfalls.\nClickpad links/rechts drücken: zurück/vor, über einem Video 10 s spulen.\nZurück-Taste: Seite zurück, auf der ersten Seite zum Home-Bildschirm.\nPlay/Pause: Video starten/anhalten, sonst Schnellmenü. Halten: Schnellmenü. Zweimal: erweitertes Menü.\nDie Knöpfe der oberen Leiste lassen sich direkt anklicken."
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    if (self.preferencesStore.dontShowHintsOnLaunch) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Always Show On Launch"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = NO;
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Don't Show This Again"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = YES;
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"Dismiss"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (BOOL)topBarAcceptsPointer {
    return self.viewModel.topNavigationBarVisible && !self.topMenuView.hidden && self.topMenuView.alpha > 0.05;
}

/// Klick auf einen Knopf der oberen Leiste direkt auslösen, ohne den Umweg über den Fokusmodus.
- (BOOL)performTopBarActionAtPoint:(CGPoint)point {
    if (![self topBarAcceptsPointer]) {
        return NO;
    }
    __block BOOL found = NO;
    __block BrowserTopBarAction foundAction = BrowserTopBarActionURL;
    [self.topMenuView enumeratePointerTargetsUsingBlock:^(CGRect frame, BrowserTopBarAction action) {
        if (!found && CGRectContainsPoint([self.topMenuView convertRect:frame toView:self.view], point)) {
            found = YES;
            foundAction = action;
        }
    }];
    if (found) {
        [self performTopBarAction:foundAction];
    }
    return found;
}

- (void)observeClickTargetsOfWebView:(BrowserWebView *)webView {
    if (webView == nil || webView.clickTargetsDidChange != nil) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    webView.clickTargetsDidChange = ^{
        if (weakSelf.webview == weakWebView) {
            [weakSelf.remoteInputController pointerTargetsDidChange];
            // Kein Bildschirmschoner, solange auf der Seite ein Video läuft.
            UIApplication.sharedApplication.idleTimerDisabled = weakWebView.videoPlaying;
            [weakSelf.nowPlayingController updateWithMediaInfo:weakWebView.mediaInfo];
        }
    };
}

- (void)browserHandlePrimaryAction {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        return;
    }

    if ([self performTopBarActionAtPoint:self.remoteInputController.cursorView.frame.origin]) {
        return;
    }

    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    if (point.y < 0) {
        [self activateTopBarFocusMode];
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.topBarFocusActive) {
        UIView *preferredFocusItem = [self.topMenuView preferredFocusItem];
        if (preferredFocusItem != nil) {
            return @[preferredFocusItem];
        }
    }
    return [super preferredFocusEnvironments];
}

#pragma mark - BrowserTopBarViewDelegate

- (void)browserTopBarView:(__unused BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action {
    [self performTopBarAction:action];
}

#pragma mark - BrowserMenuCoordinatorHost

- (BrowserWebView *)browserWebView {
    return self.webview;
}

- (NSString *)browserPreviousURL {
    return self.tabCoordinator.previousURL;
}

- (void)setBrowserPreviousURL:(NSString *)browserPreviousURL {
    self.tabCoordinator.previousURL = browserPreviousURL ?: @"";
}

- (NSUInteger)browserTextFontSize {
    return self.viewModel.textFontSize;
}

- (void)setBrowserTextFontSize:(NSUInteger)browserTextFontSize {
    self.viewModel.textFontSize = browserTextFontSize;
    self.preferencesStore.textFontSize = self.viewModel.textFontSize;
}

- (BOOL)browserTopMenuShowing {
    return self.viewModel.topNavigationBarVisible;
}

- (BOOL)browserFullscreenVideoPlaybackEnabled {
    return self.viewModel.fullscreenVideoPlaybackEnabled;
}

- (void)setBrowserFullscreenVideoPlaybackEnabled:(BOOL)browserFullscreenVideoPlaybackEnabled {
    self.viewModel.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
    self.preferencesStore.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
}

- (void)browserPresentViewController:(UIViewController *)viewController {
    [self deactivateTopBarFocusMode];
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserLoadHomePage {
    [self loadHomePage];
}

- (void)browserShowHints {
    [self showHintsAlert];
}

- (void)browserShowTabOverview {
    [self deactivateTopBarFocusMode];
    [self.tabCoordinator prepareTabOverviewThumbnails];
    [self.tabOverviewController show];
}

- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserHideTopNav {
    [self deactivateTopBarFocusMode];
    self.viewModel.topNavigationBarVisible = NO;
    self.preferencesStore.topNavigationBarVisible = NO;
    [self.tabCoordinator setTopNavigationVisible:NO];
}

- (void)browserShowTopNav {
    self.viewModel.topNavigationBarVisible = YES;
    self.preferencesStore.topNavigationBarVisible = YES;
    [self.tabCoordinator setTopNavigationVisible:YES];
}

- (void)browserUpdateTextFontSize {
    [self updateTextFontSize];
}

- (void)browserCaptureSnapshotForCurrentTab {
    [self.tabCoordinator captureSnapshotForCurrentTab];
}

- (void)browserRecreateActiveWebViewPreservingCurrentURL {
    [self.tabCoordinator recreateActiveWebViewPreservingCurrentURL];
}

- (void)browserBringCursorToFront {
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];
}

- (void)browserPlayVideoUnderCursorIfAvailable {
    [self.videoPlaybackCoordinator playVideoUnderCursorIfAvailable];
}

#pragma mark - BrowserVideoPlaybackCoordinatorHost

- (BOOL)browserIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (CGPoint)browserDOMCursorPoint {
    return [self browserDOMPointForCursor];
}

- (UIViewController *)browserPresentedViewController {
    return self.presentedViewController;
}

- (NSString *)browserCurrentPageTitle {
    return self.webview.title;
}

#pragma mark - BrowserTabCoordinatorHost

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (void)browserTabCoordinatorUpdateTextFontSize {
    [self updateTextFontSize];
}

- (BOOL)browserTabCoordinatorIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (BOOL)browserTabCoordinatorIsTabOverviewVisible {
    return self.tabOverviewController.visible;
}

#pragma mark - BrowserTabOverviewControllerHost

- (BOOL)browserTabOverviewControllerCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (void)browserTabOverviewControllerSetCursorModeEnabled:(BOOL)enabled {
    [self.remoteInputController setCursorModeEnabled:enabled];
}

- (void)browserTabOverviewControllerPresentViewController:(UIViewController *)viewController {
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserTabOverviewControllerCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserTabOverviewControllerSwitchToTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator switchToTabAtIndex:tabIndex];
}

- (void)browserTabOverviewControllerCloseTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator closeTabAtIndex:tabIndex];
}

#pragma mark - BrowserPageActionCoordinatorHost

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request {
    return [self.tabCoordinator createNewTabWithRequest:request];
}

#pragma mark - BrowserRemoteInputControllerHost

- (UIScrollView *)browserRemoteInputControllerActiveScrollView {
    return self.webview.scrollView;
}

- (UIViewController *)browserRemoteInputControllerPresentedViewController {
    return self.presentedViewController;
}

- (BOOL)browserRemoteInputControllerTopBarFocusActive {
    return self.topBarFocusActive;
}

- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus {
    return [self canActivateTopBarFocusMode];
}

- (void)browserRemoteInputControllerActivateTopBarFocus {
    [self activateTopBarFocusMode];
}

- (void)browserRemoteInputControllerDeactivateTopBarFocus {
    [self deactivateTopBarFocusMode];
}

- (BOOL)browserRemoteInputControllerTabOverviewVisible {
    return self.tabOverviewController.visible;
}

- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point {
    return [self.tabOverviewController containsPoint:point];
}

- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point {
    return [self.tabOverviewController handleSelectionAtPoint:point];
}

- (void)browserRemoteInputControllerDismissTabOverview {
    [self.tabOverviewController dismiss];
}

- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction {
    [self.tabOverviewController handleAlternateAction];
}

- (void)browserRemoteInputControllerHandlePrimaryAction {
    [self browserHandlePrimaryAction];
}

- (BOOL)browserRemoteInputControllerHandleMenuPress {
    if (self.presentedViewController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }
    if (self.webview.canGoBack) {
        [self.webview goBack];
        return YES;
    }
    // Erste Seite: wie jede tvOS-App zurück zum Home-Bildschirm.
    [self.tabCoordinator persistSession];
    return NO;
}

/// Steht der Zeiger auf einem Video? Gilt auch, wenn er gerade ausgeblendet ist (Video läuft, Zeiger ruht).
- (BOOL)pointerIsOverVideo {
    BrowserWebView *webView = self.webview;
    if (webView == nil || !self.remoteInputController.cursorModeEnabled) {
        return NO;
    }
    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:webView];
    for (NSValue *value in [webView videoRects]) {
        if (CGRectContainsPoint(value.CGRectValue, point)) {
            return YES;
        }
    }
    return NO;
}

- (CGPoint)pointerPointInWebView {
    return [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
}

- (void)browserRemoteInputControllerHandlePlayPausePress {
    if (self.presentedViewController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    // Läuft ein Video oder steht der Zeiger auf einem, steuert Play/Pause das Video.
    if (self.webview != nil && (self.webview.videoPlaying || [self pointerIsOverVideo])) {
        [self.webview sendVideoCommand:@"toggle" atPoint:[self pointerPointInWebView]];
        return;
    }
    [self requestURLorSearchInput];
}

- (void)browserRemoteInputControllerHandlePlayPauseLongPress {
    if (self.presentedViewController != nil) {
        return;
    }
    [self requestURLorSearchInput];
}

- (void)browserRemoteInputControllerHandleAdvancedMenuPress {
    [self showAdvancedMenu];
}

- (NSArray<NSValue *> *)browserRemoteInputControllerPointerTargets {
    NSMutableArray<NSValue *> *targets = [NSMutableArray array];
    BrowserWebView *webView = self.webview;
    BOOL topBarVisible = [self topBarAcceptsPointer];
    CGRect topBarFrame = topBarVisible ? [self.topMenuView.superview convertRect:self.topMenuView.frame toView:self.view] : CGRectNull;

    if (webView != nil && webView.window != nil) {
        [self observeClickTargetsOfWebView:webView];
        CGRect visible = [webView convertRect:webView.bounds toView:self.view];
        for (NSValue *value in [webView clickTargetRects]) {
            CGRect rect = CGRectIntersection([webView convertRect:value.CGRectValue toView:self.view], visible);
            if (CGRectIsEmpty(rect)) {
                continue;
            }
            // Was unter der oberen Leiste liegt, ist nicht erreichbar.
            if (topBarVisible && CGRectContainsPoint(topBarFrame, CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)))) {
                continue;
            }
            [targets addObject:[NSValue valueWithCGRect:rect]];
        }
    }

    if (topBarVisible) {
        [self.topMenuView enumeratePointerTargetsUsingBlock:^(CGRect frame, __unused BrowserTopBarAction action) {
            [targets addObject:[NSValue valueWithCGRect:[self.topMenuView convertRect:frame toView:self.view]]];
        }];
    }
    return targets;
}

- (void)browserRemoteInputControllerNavigateBack {
    if ([self pointerIsOverVideo]) {
        [self.webview sendVideoCommand:@"seek:-10" atPoint:[self pointerPointInWebView]];
        return;
    }
    if (self.webview.canGoBack) {
        [self.webview goBack];
    }
}

- (void)browserRemoteInputControllerNavigateForward {
    if ([self pointerIsOverVideo]) {
        [self.webview sendVideoCommand:@"seek:10" atPoint:[self pointerPointInWebView]];
        return;
    }
    if (self.webview.canGoForward) {
        [self.webview goForward];
    }
}

- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled {
    self.webview.userInteractionEnabled = enabled;
}

- (void)browserRemoteInputControllerPersistSession {
    [self.tabCoordinator persistSession];
}

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    return [self.tabCoordinator createNewTabWithRequest:request];
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)navigationType;
    [self.tabCoordinator prepareTabForRequest:request webView:webView];
    return YES;
}

- (void)webViewDidStartLoad:(id)webView {
    if ([webView isKindOfClass:BrowserWebView.class]) {
        [self observeClickTargetsOfWebView:webView];
    }
    [self.tabCoordinator webViewDidStartLoad:webView];
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    if (self.tabOverviewController.visible) {
        BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
        NSInteger tabIndex = tab != nil ? [self.viewModel.tabs indexOfObject:tab] : NSNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.tabOverviewController.visible) {
                return;
            }
            if (tabIndex != NSNotFound) {
                [self.tabOverviewController updateCardAtIndex:tabIndex];
            } else {
                [self.tabOverviewController reload];
            }
        });
    }
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
    BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSURL *failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    NSURLRequest *currentRequest = [webView request];
    NSString *currentRequestURLString = currentRequest.URL.absoluteString ?: @"";
    if (failingURL != nil &&
        currentRequestURLString.length > 0 &&
        ![failingURL.absoluteString isEqualToString:currentRequestURLString]) {
        return;
    }

    if (tab == self.tabCoordinator.activeTab) {
        [self.topMenuView.loadingSpinner stopAnimating];
    }
    if (tab != self.tabCoordinator.activeTab) {
        return;
    }
    if ([self.navigationService shouldIgnoreLoadError:error]) {
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Could Not Load Webpage"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Google This Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            if (searchRequest != nil) {
                [weakSelf.webview loadRequest:searchRequest];
            }
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Enter a URL or Search"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf requestURLorSearchInput];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Presses / Touches

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesBegan:presses withEvent:event];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesCancelled:presses withEvent:event];
    [super pressesCancelled:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if ([self.remoteInputController handlePressesEnded:presses withEvent:event]) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesBegan:touches withEvent:event]) {
        return;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesMoved:touches withEvent:event]) {
        return;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesCancelled:touches withEvent:event];
}

@end
