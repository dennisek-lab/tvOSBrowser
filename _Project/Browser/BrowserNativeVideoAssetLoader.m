#import "BrowserNativeVideoAssetLoader.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static NSString * const kBrowserNativeVideoAssetLoaderLogPrefix = @"[NativeVideoAssetLoader]";
static NSString * const kBrowserNativeVideoHTTPProxyScheme = @"browserhttp";
static NSString * const kBrowserNativeVideoHTTPSProxyScheme = @"browserhttps";

@interface BrowserNativeVideoAssetLoader () <AVAssetResourceLoaderDelegate>

@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *cookies;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t resourceLoaderQueue;
@property (nonatomic, strong) NSMapTable<AVAssetResourceLoadingRequest *, NSURLSessionDataTask *> *taskByLoadingRequest;

@end

@implementation BrowserNativeVideoAssetLoader

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"%@ %@", kBrowserNativeVideoAssetLoaderLogPrefix, message);
}

- (instancetype)initWithRequestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                               cookies:(NSArray<NSHTTPCookie *> *)cookies {
    self = [super init];
    if (self) {
        _requestHeaders = [requestHeaders copy] ?: @{};
        _cookies = [cookies copy] ?: @[];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:configuration];
        _resourceLoaderQueue = dispatch_queue_create("com.browser.nativevideo.assetloader", DISPATCH_QUEUE_SERIAL);
        _taskByLoadingRequest = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

- (NSURL *)assetURLForPlaybackURL:(NSURL *)playbackURL {
    NSURLComponents *components = [NSURLComponents componentsWithURL:playbackURL resolvingAgainstBaseURL:NO];
    NSString *scheme = components.scheme.lowercaseString;
    if ([scheme isEqualToString:@"https"]) {
        components.scheme = kBrowserNativeVideoHTTPSProxyScheme;
    } else if ([scheme isEqualToString:@"http"]) {
        components.scheme = kBrowserNativeVideoHTTPProxyScheme;
    }
    return components.URL ?: playbackURL;
}

- (BOOL)attachToAsset:(id)asset {
    if (asset == nil) {
        return NO;
    }

    SEL resourceLoaderSelector = NSSelectorFromString(@"resourceLoader");
    if (![asset respondsToSelector:resourceLoaderSelector]) {
        return NO;
    }

    AVAssetResourceLoader *resourceLoader = ((id (*)(id, SEL))objc_msgSend)(asset, resourceLoaderSelector);
    [resourceLoader setDelegate:self queue:self.resourceLoaderQueue];
    return YES;
}

- (NSURL *)playbackURLFromAssetURL:(NSURL *)assetURL {
    if (assetURL == nil) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:assetURL resolvingAgainstBaseURL:NO];
    NSString *scheme = components.scheme.lowercaseString;
    if ([scheme isEqualToString:kBrowserNativeVideoHTTPSProxyScheme]) {
        components.scheme = @"https";
    } else if ([scheme isEqualToString:kBrowserNativeVideoHTTPProxyScheme]) {
        components.scheme = @"http";
    }
    return components.URL;
}

- (NSString *)cookieHeaderValue {
    return [self cookieHeaderValueForURL:nil];
}

- (BOOL)cookie:(NSHTTPCookie *)cookie matchesURL:(NSURL *)URL {
    if (cookie == nil || URL == nil) {
        return NO;
    }

    NSString *host = URL.host.lowercaseString ?: @"";
    NSString *cookieDomain = cookie.domain.lowercaseString ?: @"";
    if (host.length == 0 || cookieDomain.length == 0) {
        return NO;
    }

    if ([cookieDomain hasPrefix:@"."]) {
        cookieDomain = [cookieDomain substringFromIndex:1];
    }

    BOOL domainMatches = [host isEqualToString:cookieDomain] || [host hasSuffix:[@"." stringByAppendingString:cookieDomain]];
    if (!domainMatches) {
        return NO;
    }

    if (cookie.isSecure && ![URL.scheme.lowercaseString isEqualToString:@"https"]) {
        return NO;
    }

    NSString *cookiePath = cookie.path.length > 0 ? cookie.path : @"/";
    NSString *requestPath = URL.path.length > 0 ? URL.path : @"/";
    return [requestPath hasPrefix:cookiePath];
}

- (NSArray<NSHTTPCookie *> *)cookiesForURL:(NSURL *)URL {
    if (self.cookies.count == 0 || URL == nil) {
        return @[];
    }

    NSMutableArray<NSHTTPCookie *> *matchingCookies = [NSMutableArray array];
    for (NSHTTPCookie *cookie in self.cookies) {
        if ([self cookie:cookie matchesURL:URL]) {
            [matchingCookies addObject:cookie];
        }
    }
    return matchingCookies;
}

- (NSString *)cookieHeaderValueForURL:(NSURL *)URL {
    NSArray<NSHTTPCookie *> *cookies = URL != nil ? [self cookiesForURL:URL] : self.cookies;
    if (cookies.count == 0) {
        return nil;
    }
    NSDictionary<NSString *, NSString *> *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
    return cookieHeaders[@"Cookie"];
}

- (NSMutableURLRequest *)requestForPlaybackURL:(NSURL *)playbackURL loadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:playbackURL];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 30.0;

    NSString *host = playbackURL.host.lowercaseString ?: @"";
    BOOL isGoogleVideoHost = [host containsString:@"googlevideo.com"];
    [self.requestHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        if (value.length > 0) {
            if (isGoogleVideoHost && [key caseInsensitiveCompare:@"Origin"] == NSOrderedSame) {
                return;
            }
            [request setValue:value forHTTPHeaderField:key];
        }
    }];

    NSString *cookieHeader = [self cookieHeaderValueForURL:playbackURL];
    if (cookieHeader.length > 0) {
        [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
    }

    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    if (dataRequest != nil) {
        long long startOffset = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset;
        if (startOffset < 0) {
            startOffset = 0;
        }

        NSString *rangeHeader = nil;
        if (dataRequest.requestsAllDataToEndOfResource) {
            rangeHeader = [NSString stringWithFormat:@"bytes=%lld-", startOffset];
        } else if (dataRequest.requestedLength > 0) {
            long long endOffset = startOffset + dataRequest.requestedLength - 1;
            rangeHeader = [NSString stringWithFormat:@"bytes=%lld-%lld", startOffset, endOffset];
        }

        if (rangeHeader.length > 0) {
            [request setValue:rangeHeader forHTTPHeaderField:@"Range"];
        }
    }

    return request;
}

- (BOOL)isPlaylistResponse:(NSHTTPURLResponse *)response data:(NSData *)data requestURL:(NSURL *)requestURL {
    NSString *contentType = [response valueForHTTPHeaderField:@"Content-Type"].lowercaseString ?: @"";
    NSString *pathExtension = requestURL.pathExtension.lowercaseString ?: @"";
    if ([contentType containsString:@"mpegurl"] || [contentType containsString:@"m3u"] || [pathExtension isEqualToString:@"m3u8"]) {
        return YES;
    }

    if (data.length >= 7) {
        NSData *prefixData = [data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)128, data.length))];
        NSString *prefixString = [[NSString alloc] initWithData:prefixData encoding:NSUTF8StringEncoding];
        if ([prefixString containsString:@"#EXTM3U"]) {
            return YES;
        }
    }
    return NO;
}

/// Absolute Adresse eines Playlist-Eintrags. Über den Loader (eigenes Schema) laufen nur Playlists und
/// Schlüssel; Mediensegmente (auch `#EXT-X-MAP`, WebVTT-Segmente) bleiben `https`, weil AVFoundation
/// Segmentdaten aus einem Resource-Loader bei HLS ablehnt (CoreMediaErrorDomain -12881). Die Segmente lädt
/// AVFoundation selbst mit den Asset-Optionen (Header, Cookies).
- (NSString *)URLStringForPlaylistEntry:(NSString *)entry baseURL:(NSURL *)baseURL viaLoader:(BOOL)viaLoader {
    if (entry.length == 0) {
        return entry;
    }

    NSURL *resolvedURL = [NSURL URLWithString:entry relativeToURL:baseURL].absoluteURL;
    if (resolvedURL == nil) {
        return entry;
    }

    NSString *scheme = resolvedURL.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return entry;
    }

    if (!viaLoader) {
        return resolvedURL.absoluteString ?: entry;
    }
    return [[self assetURLForPlaybackURL:resolvedURL] absoluteString] ?: entry;
}

- (NSString *)rewrittenPlaylistLine:(NSString *)line
                            baseURL:(NSURL *)baseURL
                     masterPlaylist:(BOOL)masterPlaylist {
    NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmedLine.length == 0) {
        return line;
    }

    if (![trimmedLine hasPrefix:@"#"]) {
        // In der Hauptplaylist sind die Einträge Teil-Playlists, sonst Segmente.
        return [self URLStringForPlaylistEntry:trimmedLine baseURL:baseURL viaLoader:masterPlaylist];
    }

    static NSRegularExpression *URIExpression = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        URIExpression = [NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]+)\"" options:0 error:NULL];
    });
    if (URIExpression == nil) {
        return line;
    }

    // Playlists (#EXT-X-MEDIA, #EXT-X-I-FRAME-STREAM-INF) und Schlüssel (#EXT-X-KEY, #EXT-X-SESSION-KEY)
    // über den Loader, Init-Segmente (#EXT-X-MAP) und alles andere direkt.
    BOOL viaLoader = [trimmedLine hasPrefix:@"#EXT-X-MEDIA:"] ||
        [trimmedLine hasPrefix:@"#EXT-X-I-FRAME-STREAM-INF:"] ||
        [trimmedLine hasPrefix:@"#EXT-X-KEY:"] ||
        [trimmedLine hasPrefix:@"#EXT-X-SESSION-KEY:"];

    NSMutableString *rewrittenLine = [line mutableCopy];
    NSArray<NSTextCheckingResult *> *matches = [URIExpression matchesInString:line options:0 range:NSMakeRange(0, line.length)];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        if (match.numberOfRanges < 2) {
            continue;
        }
        NSRange valueRange = [match rangeAtIndex:1];
        NSString *originalValue = [line substringWithRange:valueRange];
        NSString *replacementValue = [self URLStringForPlaylistEntry:originalValue baseURL:baseURL viaLoader:viaLoader];
        [rewrittenLine replaceCharactersInRange:valueRange withString:replacementValue];
    }
    return rewrittenLine;
}

- (NSData *)rewrittenPlaylistDataFromData:(NSData *)data responseURL:(NSURL *)responseURL {
    NSString *playlistString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (playlistString.length == 0) {
        return data;
    }

    BOOL masterPlaylist = [playlistString containsString:@"#EXT-X-STREAM-INF"] || [playlistString containsString:@"#EXT-X-MEDIA:"];
    NSMutableArray<NSString *> *rewrittenLines = [NSMutableArray array];
    [playlistString enumerateLinesUsingBlock:^(NSString *line, __unused BOOL *stop) {
        [rewrittenLines addObject:[self rewrittenPlaylistLine:line baseURL:responseURL masterPlaylist:masterPlaylist]];
    }];

    NSString *rewrittenString = [rewrittenLines componentsJoinedByString:@"\n"];
    if ([playlistString hasSuffix:@"\n"]) {
        rewrittenString = [rewrittenString stringByAppendingString:@"\n"];
    }
    return [rewrittenString dataUsingEncoding:NSUTF8StringEncoding] ?: data;
}

- (void)fillContentInfoForLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
                                response:(NSHTTPURLResponse *)response
                                    data:(NSData *)data
                              requestURL:(NSURL *)requestURL {
    AVAssetResourceLoadingContentInformationRequest *contentInformationRequest = loadingRequest.contentInformationRequest;
    if (contentInformationRequest == nil) {
        return;
    }

    NSString *contentType = [response valueForHTTPHeaderField:@"Content-Type"] ?: response.MIMEType;
    if ([self isPlaylistResponse:response data:data requestURL:requestURL]) {
        contentType = @"application/vnd.apple.mpegurl";
    }

    // AVFoundation erwartet hier einen UTI (public.mpeg-4), keinen MIME-Typ (video/mp4).
    contentType = [[contentType componentsSeparatedByString:@";"].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (contentType.length > 0) {
        UTType *type = [UTType typeWithMIMEType:contentType];
        if (type == nil && requestURL.pathExtension.length > 0) {
            type = [UTType typeWithFilenameExtension:requestURL.pathExtension];
        }
        contentInformationRequest.contentType = type.identifier ?: contentType;
    }

    // Bei Teilantworten (206) steht die Gesamtlänge in Content-Range ("bytes 0-1/788493").
    NSString *contentRange = [response valueForHTTPHeaderField:@"Content-Range"];
    NSRange slash = [contentRange rangeOfString:@"/" options:NSBackwardsSearch];
    long long totalLength = slash.location != NSNotFound ? [contentRange substringFromIndex:slash.location + 1].longLongValue : 0;
    long long expectedLength = response.expectedContentLength;
    if (totalLength > 0) {
        contentInformationRequest.contentLength = totalLength;
    } else if (expectedLength > 0) {
        contentInformationRequest.contentLength = expectedLength;
    } else if (data.length > 0) {
        contentInformationRequest.contentLength = (long long)data.length;
    }

    NSString *acceptRanges = [response valueForHTTPHeaderField:@"Accept-Ranges"] ?: @"";
    contentInformationRequest.byteRangeAccessSupported = [acceptRanges.lowercaseString containsString:@"bytes"] || response.statusCode == 206;
}

- (NSData *)responseDataForLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest data:(NSData *)data {
    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    if (dataRequest == nil || data.length == 0) {
        return data ?: [NSData data];
    }

    if (dataRequest.requestedOffset <= 0 && dataRequest.currentOffset <= 0) {
        return data;
    }

    long long startOffset = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset;
    if (startOffset < 0 || startOffset >= (long long)data.length) {
        return [NSData data];
    }

    NSUInteger length = data.length - (NSUInteger)startOffset;
    if (!dataRequest.requestsAllDataToEndOfResource && dataRequest.requestedLength > 0) {
        length = MIN(length, (NSUInteger)dataRequest.requestedLength);
    }
    return [data subdataWithRange:NSMakeRange((NSUInteger)startOffset, length)];
}

/// Erzeugte Playlist ausliefern (kein Netz). Läuft auf der Loader-Queue.
- (void)respondWithGeneratedData:(NSData *)data playbackURL:(NSURL *)playbackURL loadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSData *playlist = [self rewrittenPlaylistDataFromData:data responseURL:playbackURL];
    AVAssetResourceLoadingContentInformationRequest *contentInformationRequest = loadingRequest.contentInformationRequest;
    if (contentInformationRequest != nil) {
        contentInformationRequest.contentType = [UTType typeWithMIMEType:@"application/vnd.apple.mpegurl"].identifier ?: @"public.m3u-playlist";
        contentInformationRequest.contentLength = (long long)playlist.length;
        contentInformationRequest.byteRangeAccessSupported = NO;
    }
    NSData *dataForRequest = [self responseDataForLoadingRequest:loadingRequest data:playlist];
    if (dataForRequest.length > 0) {
        [loadingRequest.dataRequest respondWithData:dataForRequest];
    }
    [loadingRequest finishLoading];
    [self log:@"erzeugte Playlist %@ (%lu Bytes)", playbackURL.lastPathComponent ?: @"", (unsigned long)playlist.length];
}

- (void)dealloc {
    // Ohne Invalidieren bleibt die Session (samt Verbindungen) nach jedem Player im Speicher.
    [_session invalidateAndCancel];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    __unused AVAssetResourceLoader *unusedResourceLoader = resourceLoader;
    NSURL *requestURL = loadingRequest.request.URL;
    NSURL *playbackURL = [self playbackURLFromAssetURL:requestURL];
    if (playbackURL == nil) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
        [loadingRequest finishLoadingWithError:error];
        return NO;
    }

    NSData *generated = self.generatedResources[playbackURL.absoluteString];
    if (generated != nil) {
        [self respondWithGeneratedData:generated playbackURL:playbackURL loadingRequest:loadingRequest];
        return YES;
    }

    NSMutableURLRequest *request = [self requestForPlaybackURL:playbackURL loadingRequest:loadingRequest];
    [self log:@"requesting resource url=%@ range=%@", playbackURL.absoluteString ?: @"", [request valueForHTTPHeaderField:@"Range"] ?: @""];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        dispatch_async(strongSelf.resourceLoaderQueue, ^{
            [strongSelf.taskByLoadingRequest removeObjectForKey:loadingRequest];

            if (error != nil) {
                [strongSelf log:@"resource failed url=%@ error=%@", playbackURL.absoluteString ?: @"", error];
                [loadingRequest finishLoadingWithError:error];
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (![httpResponse isKindOfClass:[NSHTTPURLResponse class]]) {
                NSError *invalidResponseError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil];
                [loadingRequest finishLoadingWithError:invalidResponseError];
                return;
            }

            if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
                NSString *bodyPreview = data.length > 0 ? [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)160, data.length))] encoding:NSUTF8StringEncoding] : @"";
                [strongSelf log:@"resource HTTP status=%ld url=%@ preview=%@",
                 (long)httpResponse.statusCode,
                 playbackURL.absoluteString ?: @"",
                 bodyPreview ?: @""];
                NSError *statusError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]
                }];
                [loadingRequest finishLoadingWithError:statusError];
                return;
            }

            NSData *responseData = data ?: [NSData data];
            if ([strongSelf isPlaylistResponse:httpResponse data:responseData requestURL:playbackURL]) {
                // Nach Weiterleitungen relativ zur tatsächlichen Adresse auflösen.
                responseData = [strongSelf rewrittenPlaylistDataFromData:responseData responseURL:httpResponse.URL ?: playbackURL];
            }

            [strongSelf fillContentInfoForLoadingRequest:loadingRequest response:httpResponse data:responseData requestURL:playbackURL];
            // 206: der Server hat den angefragten Bereich geliefert, die Daten beginnen schon beim Offset.
            NSData *dataForRequest = httpResponse.statusCode == 206 ? responseData
                                                                     : [strongSelf responseDataForLoadingRequest:loadingRequest data:responseData];
            if (dataForRequest.length > 0) {
                [loadingRequest.dataRequest respondWithData:dataForRequest];
            }
            [loadingRequest finishLoading];
        });
    }];

    [self.taskByLoadingRequest setObject:task forKey:loadingRequest];
    [task resume];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    __unused AVAssetResourceLoader *unusedResourceLoader = resourceLoader;
    NSURLSessionDataTask *task = [self.taskByLoadingRequest objectForKey:loadingRequest];
    [task cancel];
    [self.taskByLoadingRequest removeObjectForKey:loadingRequest];
}

@end
