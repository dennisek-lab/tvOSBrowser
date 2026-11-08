#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserNativeVideoPlayerViewController : AVPlayerViewController

- (instancetype)initWithURL:(NSURL *)URL title:(nullable NSString *)title;
- (instancetype)initWithURL:(NSURL *)URL
                      title:(nullable NSString *)title
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                    cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;

/// Startposition in Sekunden (wird gesetzt, sobald das Video bereit ist).
@property (nonatomic) NSTimeInterval initialPlaybackTime;
/// Wird beim Schließen des Players mit der letzten Position (Sekunden) aufgerufen.
@property (nonatomic, copy, nullable) void (^dismissHandler)(NSTimeInterval playbackTime);
/// Wird aufgerufen, wenn AVPlayer das Video nicht abspielen kann (Status „failed“). Einmalig.
@property (nonatomic, copy, nullable) void (^failureHandler)(NSError * _Nullable error);

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
