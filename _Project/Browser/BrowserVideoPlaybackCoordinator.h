#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class BrowserDOMInteractionService;
@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserVideoPlaybackCoordinatorHost <NSObject>

@property (nonatomic, readonly) BrowserWebView *browserWebView;
@property (nonatomic, readonly) BOOL browserIsCursorModeEnabled;
@property (nonatomic, readonly) CGPoint browserDOMCursorPoint;
@property (nonatomic, readonly, nullable) UIViewController *browserPresentedViewController;
@property (nonatomic, readonly, nullable) NSString *browserCurrentPageTitle;
@property (nonatomic, readonly) BOOL browserFullscreenVideoPlaybackEnabled;

- (void)browserPresentViewController:(UIViewController *)viewController;

@end

@interface BrowserVideoPlaybackCoordinator : NSObject

- (instancetype)initWithHost:(id<BrowserVideoPlaybackCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService;
- (void)playVideoUnderCursorIfAvailable;
- (BOOL)handleSelectPressForVideoAtCursor;

/// Hat die aktuelle Seite ein Video (sichtbares Video oder aktives Medium)?
- (BOOL)pageHasVideo;
/// Übergibt das Video der Seite (unter dem Zeiger, sonst das laufende oder größte) an den nativen Player.
- (void)openPageVideoInNativePlayer;
/// Verarbeitet Meldungen des Seiten-Skripts (`BrowserWebView.videoEventHandler`): Vollbildwunsch, Videostart.
- (void)handlePageVideoEvent:(NSDictionary *)event;

@end

NS_ASSUME_NONNULL_END
