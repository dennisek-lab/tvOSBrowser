#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserNavigationService;
@class BrowserPreferencesStore;
@class BrowserSessionStore;
@class BrowserTabViewModel;
@class BrowserTopBarView;
@class BrowserViewModel;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserTabCoordinatorHost <NSObject>

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController;
- (void)browserTabCoordinatorUpdateTextFontSize;
- (BOOL)browserTabCoordinatorIsCursorModeEnabled;
- (BOOL)browserTabCoordinatorIsTabOverviewVisible;

@end

@interface BrowserTabCoordinator : NSObject

@property (nonatomic, readonly, nullable) BrowserWebView *activeWebView;
@property (nonatomic, readonly, nullable) BrowserTabViewModel *activeTab;
@property (nonatomic, copy) NSString *requestURL;
@property (nonatomic, copy) NSString *previousURL;

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
         scrollViewAllowBounces:(BOOL)scrollViewAllowBounces NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)restoreInitialStateOrCreateFirstTab;
- (void)webViewDidAppear;
- (void)loadHomePage;
- (void)createNewTabLoadingHomePage:(BOOL)loadHomePage;
- (BOOL)createNewTabWithRequest:(NSURLRequest *)request;
/// Pop-up bzw. Link mit target=_blank: neuer Tab am Ende, der aktive Tab bleibt vorn. Lädt noch nicht (keine WebView,
/// zählt nicht zu den fünf geladenen Tabs); erst beim Öffnen. Der neue Tab gilt als unbenutzt (`userInteracted = NO`).
/// nil, wenn schon zehn Tabs offen sind (nie wird dafür ein anderer Tab geschlossen) oder die Adresse fehlt.
- (nullable BrowserTabViewModel *)createBackgroundTabWithRequest:(NSURLRequest *)request;
/// Schließt unbenutzte Tabs, die länger als `expiry` Sekunden offen sind. Nie den aktiven und nie den letzten Tab.
/// Rückgabe: Zahl der geschlossenen Tabs.
- (NSUInteger)closeUnusedTabsOlderThan:(NSTimeInterval)expiry;
- (void)switchToTabAtIndex:(NSInteger)tabIndex;
/// Zahl der Tabs mit WebView (höchstens fünf); die übrigen sind entladen oder noch nicht geladene Pop-ups.
- (NSUInteger)loadedTabCount;
- (BOOL)isTabLoaded:(nullable BrowserTabViewModel *)tab;
/// Adresszeile (Titel und Domain) neu setzen.
- (void)refreshActiveTabUI;
- (void)closeTabAtIndex:(NSInteger)tabIndex;
- (void)recreateActiveWebViewPreservingCurrentURL;
- (void)captureSnapshotForCurrentTab;
- (void)prepareTabOverviewThumbnails;
- (void)persistSession;
- (void)handleWebViewPanGesture:(UIPanGestureRecognizer *)gestureRecognizer;
- (void)webViewDidStartLoad:(id)webView;
- (void)webViewDidFinishLoad:(id)webView;
- (void)prepareTabForRequest:(NSURLRequest *)request webView:(id)webView;
- (void)setTopNavigationVisible:(BOOL)visible;
- (BrowserTabViewModel *)tabForWebView:(id)webView;
- (BOOL)isPrimaryDocumentRequest:(NSURLRequest *)request;

@end

NS_ASSUME_NONNULL_END

/// Kurzer Name der Website wie in Safari (Metadaten, sonst der zum Host passende Teil des Titels).
FOUNDATION_EXPORT NSString * _Nonnull BrowserShortSiteName(NSString * _Nullable siteName, NSString * _Nullable title, NSString * _Nonnull host);
