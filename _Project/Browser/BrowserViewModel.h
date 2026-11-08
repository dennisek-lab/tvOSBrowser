#import <Foundation/Foundation.h>

@class BrowserTabViewModel;

@interface BrowserViewModel : NSObject

@property (nonatomic, strong, readonly) NSMutableArray *tabs;
@property (nonatomic) NSInteger activeTabIndex;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) BOOL tabOverviewVisible;
@property (nonatomic) NSUInteger textFontSize;
@property (nonatomic) BOOL fullscreenVideoPlaybackEnabled;

- (BrowserTabViewModel *)activeTab;
- (BrowserTabViewModel *)addTab;
/// Neuer Tab am Ende, der aktive Tab bleibt aktiv (Pop-ups, Links mit target=_blank). nil bei Höchstzahl.
- (BrowserTabViewModel *)addBackgroundTab;
- (BrowserTabViewModel *)ensureActiveTab;
- (BrowserTabViewModel *)removeTabAtIndex:(NSInteger)tabIndex;
- (void)restoreTabs:(NSArray<BrowserTabViewModel *> *)tabs activeTabIndex:(NSInteger)activeTabIndex;
- (void)switchToTabAtIndex:(NSInteger)tabIndex;

@end
