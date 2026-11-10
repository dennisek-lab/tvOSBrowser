#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserNativeVideoAssetLoader : NSObject

- (instancetype)initWithRequestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                               cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Fertige Antworten ohne Netz (absolute https-Adresse → Playlist), z. B. die erzeugten YouTube-HD-Playlists (10.5).
/// Werden wie geladene Playlists umgeschrieben (Teil-Playlists über den Loader, Segmente direkt).
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSData *> *generatedResources;

- (NSURL *)assetURLForPlaybackURL:(NSURL *)playbackURL;
- (BOOL)attachToAsset:(id)asset;

@end

NS_ASSUME_NONNULL_END
