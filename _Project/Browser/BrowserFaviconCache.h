//
//  BrowserFaviconCache.h
//  Seiten-Icons (apple-touch-icon, favicon.ico, Google-s2 als Rückfall), im Speicher und in Library/Caches/Favicons.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserFaviconCache : NSObject

+ (instancetype)sharedCache;

/// Sofort verfügbares Icon (Speicher oder Platte), sonst nil.
- (nullable UIImage *)cachedIconForHost:(NSString *)host;

/// Lädt das Icon asynchron; completion läuft auf dem Hauptthread (nil = keins gefunden).
/// Mehrere gleichzeitige Anfragen für denselben Host werden zusammengefasst; Fehlschläge werden einen Tag lang gemerkt.
- (void)loadIconForHost:(NSString *)host completion:(void (^)(UIImage *_Nullable image))completion;

@end

NS_ASSUME_NONNULL_END
