//
//  BrowserFaviconCache.m
//

#import "BrowserFaviconCache.h"

/// Nach einem Fehlschlag erst nach dieser Zeit erneut im Netz suchen.
static NSTimeInterval const kFaviconMissRetryInterval = 24 * 60 * 60;
/// Kleinere Favicons (16/32 px) wirken auf dem Fernseher unscharf: dann zusätzlich Google-s2 (128 px) versuchen.
static CGFloat const kFaviconSmallPixelSize = 48.0;

@interface BrowserFaviconCache ()
@property (nonatomic) NSCache<NSString *, UIImage *> *memoryCache;
@property (nonatomic) NSMutableDictionary<NSString *, NSMutableArray *> *pending;
@property (nonatomic) NSURL *directoryURL;
@property (nonatomic) NSURLSession *session;
@end

@implementation BrowserFaviconCache

+ (instancetype)sharedCache {
    static BrowserFaviconCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [BrowserFaviconCache new];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _memoryCache = [NSCache new];
        _memoryCache.countLimit = 120;
        _pending = [NSMutableDictionary dictionary];
        NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        _directoryURL = [caches URLByAppendingPathComponent:@"Favicons" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:_directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 8.0;
        configuration.HTTPMaximumConnectionsPerHost = 2;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

#pragma mark - Platte

- (NSString *)fileKeyForHost:(NSString *)host {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789.-"];
    NSMutableString *key = [NSMutableString string];
    for (NSUInteger i = 0; i < host.length; i++) {
        unichar c = [host.lowercaseString characterAtIndex:i];
        [key appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    return key;
}

- (NSURL *)imageFileURLForHost:(NSString *)host {
    return [self.directoryURL URLByAppendingPathComponent:[[self fileKeyForHost:host] stringByAppendingPathExtension:@"img"]];
}

- (NSURL *)missFileURLForHost:(NSString *)host {
    return [self.directoryURL URLByAppendingPathComponent:[[self fileKeyForHost:host] stringByAppendingPathExtension:@"none"]];
}

- (BOOL)recentlyMissedHost:(NSString *)host {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:[self missFileURLForHost:host].path error:nil];
    NSDate *date = attributes.fileModificationDate;
    return date != nil && -date.timeIntervalSinceNow < kFaviconMissRetryInterval;
}

- (UIImage *)cachedIconForHost:(NSString *)host {
    if (host.length == 0) {
        return nil;
    }
    UIImage *image = [self.memoryCache objectForKey:host];
    if (image != nil) {
        return image;
    }
    NSData *data = [NSData dataWithContentsOfURL:[self imageFileURLForHost:host]];
    image = data.length > 0 ? [UIImage imageWithData:data] : nil;
    if (image != nil) {
        [self.memoryCache setObject:image forKey:host];
    }
    return image;
}

#pragma mark - Netz

/// Größe in Pixeln (längere Seite).
static CGFloat BrowserFaviconPixelSize(UIImage *image) {
    return MAX(image.size.width, image.size.height) * image.scale;
}

- (void)fetchURLs:(NSArray<NSURL *> *)urls best:(nullable NSData *)bestData completion:(void (^)(NSData *_Nullable data))completion {
    if (urls.count == 0) {
        completion(bestData);
        return;
    }
    NSURL *url = urls.firstObject;
    NSArray<NSURL *> *rest = [urls subarrayWithRange:NSMakeRange(1, urls.count - 1)];
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:8.0];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        UIImage *image = (error == nil && status == 200 && data.length > 0) ? [UIImage imageWithData:data] : nil;
        CGFloat size = image != nil ? BrowserFaviconPixelSize(image) : 0.0;
        // Leere oder winzige Bilder (Zählpixel) zählen nicht.
        if (size < 8.0) {
            image = nil;
        }
        NSData *best = bestData;
        CGFloat bestSize = best != nil ? BrowserFaviconPixelSize([UIImage imageWithData:best]) : 0.0;
        if (image != nil && size > bestSize) {
            best = data;
            bestSize = size;
        }
        // Gutes Icon gefunden: fertig. Kleines Favicon: noch den Rückfall mit höherer Auflösung probieren.
        if (best != nil && bestSize >= kFaviconSmallPixelSize) {
            completion(best);
            return;
        }
        [self fetchURLs:rest best:best completion:completion];
    }] resume];
}

- (NSArray<NSURL *> *)candidateURLsForHost:(NSString *)host {
    NSString *encodedHost = [host stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLHostAllowedCharacterSet] ?: host;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *path in @[@"/apple-touch-icon.png", @"/apple-touch-icon-precomposed.png", @"/favicon.ico"]) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", encodedHost, path]];
        if (url != nil) {
            [urls addObject:url];
        }
    }
    NSURL *google = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.google.com/s2/favicons?domain=%@&sz=128", encodedHost]];
    if (google != nil) {
        [urls addObject:google];
    }
    return urls;
}

- (void)loadIconForHost:(NSString *)host completion:(void (^)(UIImage *))completion {
    if (host.length == 0) {
        completion(nil);
        return;
    }
    UIImage *cached = [self cachedIconForHost:host];
    if (cached != nil) {
        completion(cached);
        return;
    }
    if ([self recentlyMissedHost:host]) {
        completion(nil);
        return;
    }
    NSMutableArray *waiting = self.pending[host];
    if (waiting != nil) {
        [waiting addObject:[completion copy]];
        return;
    }
    self.pending[host] = [NSMutableArray arrayWithObject:[completion copy]];
    [self fetchURLs:[self candidateURLsForHost:host] best:nil completion:^(NSData *data) {
        UIImage *image = data != nil ? [UIImage imageWithData:data] : nil;
        if (image != nil) {
            [data writeToURL:[self imageFileURLForHost:host] atomically:YES];
            [NSFileManager.defaultManager removeItemAtURL:[self missFileURLForHost:host] error:nil];
        } else {
            [[NSData data] writeToURL:[self missFileURLForHost:host] atomically:YES];
        }
#if DEBUG
        NSLog(@"[Favicon] %@: %@", host, image != nil ? NSStringFromCGSize(image.size) : @"keins");
#endif
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image != nil) {
                [self.memoryCache setObject:image forKey:host];
            }
            NSArray *callbacks = self.pending[host];
            [self.pending removeObjectForKey:host];
            for (void (^callback)(UIImage *) in callbacks) {
                callback(image);
            }
        });
    }];
}

@end
