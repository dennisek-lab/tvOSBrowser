#import "BrowserYouTubeHDBridge.h"
#import "BrowserWebView.h"

#import <QuartzCore/QuartzCore.h>

NSErrorDomain const BrowserYouTubeHDErrorDomain = @"BrowserYouTubeHD";

static NSString * const kBrowserYouTubeHDDefaultsKey = @"YouTubeHDBridge";
static NSString * const kBrowserYouTubeHDMaxHeightKey = @"YouTubeHDMaxHeight";
static NSString * const kBrowserYouTubeHDPlaylistHost = @"youtube-hd.invalid";
static NSInteger const kBrowserYouTubeHDMaxVariants = 3;
static NSInteger const kBrowserYouTubeHDMaxAudioTracks = 4;
/// Kürzer ist ein Vorab-pot (Apple TV: 16 Zeichen), das echte hat über 100.
static NSUInteger const kBrowserYouTubeHDMinimumPotLength = 40;

@implementation BrowserYouTubeHDPresentation
@end

/// Ein Format des Player-Response mit fertiger Adresse und gelesenem Segmentindex.
@interface BrowserYouTubeHDTrack : NSObject
@property (nonatomic, copy) NSDictionary *format;
@property (nonatomic, copy) NSString *URLString;
@property (nonatomic, copy) NSString *codecs;
@property (nonatomic) long long initEnd;
@property (nonatomic) long long indexStart;
@property (nonatomic) long long indexEnd;
/// Segmente aus dem sidx: Offset, Länge, Dauer (Sekunden).
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *segments;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, copy) NSString *playlistName;
@property (nonatomic) double indexMilliseconds;
@property (nonatomic) NSInteger indexStatus;
@end

@implementation BrowserYouTubeHDTrack
@end

@interface BrowserYouTubeHDBridge ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation BrowserYouTubeHDBridge

+ (BOOL)isEnabled {
    NSNumber *value = [NSUserDefaults.standardUserDefaults objectForKey:kBrowserYouTubeHDDefaultsKey];
    // Vorgabe an. Bei Problemen fällt die Brücke je Video auf 360p zurück (YouTubeHDBridge=NO schaltet sie ganz ab).
    return value != nil ? value.boolValue : YES;
}

+ (NSString *)userScriptSource {
#if DEBUG
    // Schnelles Ausprobieren im Simulator ohne Neubau: Skript direkt vom Mac lesen.
    NSString *overridePath = NSProcessInfo.processInfo.environment[@"YTHD_SCRIPT_PATH"];
    if (overridePath.length > 0) {
        NSString *source = [NSString stringWithContentsOfFile:overridePath encoding:NSUTF8StringEncoding error:NULL];
        if (source.length > 0) {
            NSLog(@"[YouTubeHD] Skript aus %@ (%lu Zeichen)", overridePath, (unsigned long)source.length);
            return source;
        }
    }
#endif
    static NSString *source;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"youtube_hd_bridge" ofType:@"js" inDirectory:@"YouTubeHD"];
        source = path != nil ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
        if (source.length == 0) {
            NSLog(@"[YouTubeHD] Skript YouTubeHD/youtube_hd_bridge.js fehlt im App-Paket");
            source = @"";
        }
    });
    return source;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest = 10.0;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)dealloc {
    [_session invalidateAndCancel];
}

static NSError *BrowserYouTubeHDMakeError(BrowserYouTubeHDError code, NSString *message) {
    return [NSError errorWithDomain:BrowserYouTubeHDErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

#pragma mark - Adressen

/// Parameter einer Adresse (prozentkodiert, wie sie in der Adresse stehen).
static NSDictionary<NSString *, NSString *> *BrowserYouTubeHDQuery(NSString *URLString) {
    NSURLComponents *components = [NSURLComponents componentsWithString:URLString ?: @""];
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.percentEncodedQueryItems ?: @[]) {
        if (item.value != nil && query[item.name] == nil) {
            query[item.name] = item.value;
        }
    }
    return query;
}

/// Formatadresse mit dem entschlüsselten n und dem PO-Token der beobachteten Anfrage.
static NSString *BrowserYouTubeHDPlaybackURL(NSString *formatURL, NSDictionary<NSString *, NSString *> *captured) {
    NSURLComponents *components = [NSURLComponents componentsWithString:formatURL];
    if (components == nil) {
        return nil;
    }
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    BOOL hasPot = NO;
    for (NSURLQueryItem *item in components.percentEncodedQueryItems ?: @[]) {
        if ([item.name isEqualToString:@"n"] && captured[@"n"].length > 0) {
            [items addObject:[NSURLQueryItem queryItemWithName:@"n" value:captured[@"n"]]];
        } else {
            [items addObject:item];
        }
        hasPot = hasPot || [item.name isEqualToString:@"pot"];
    }
    if (!hasPot && captured[@"pot"].length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"pot" value:captured[@"pot"]]];
    }
    components.percentEncodedQueryItems = items;
    return components.URL.absoluteString;
}

static NSString *BrowserYouTubeHDCodecs(NSString *mime) {
    NSRange start = [mime rangeOfString:@"codecs=\""];
    if (start.location == NSNotFound) {
        return @"";
    }
    NSString *rest = [mime substringFromIndex:NSMaxRange(start)];
    NSRange end = [rest rangeOfString:@"\""];
    return end.location != NSNotFound ? [rest substringToIndex:end.location] : rest;
}

static long long BrowserYouTubeHDLong(id value) {
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
}

#pragma mark - Ablauf

- (void)preparePresentationForWebView:(BrowserWebView *)webView
                          waitSeconds:(NSTimeInterval)waitSeconds
                           completion:(void (^)(BrowserYouTubeHDPresentation *, NSError *))completion {
    CFTimeInterval start = CACurrentMediaTime();
    [self pollInfoOfWebView:webView start:start deadline:start + MAX(0.0, waitSeconds) capturedAt:0.0 completion:completion];
}

- (void)pollInfoOfWebView:(BrowserWebView *)webView
                    start:(CFTimeInterval)start
                 deadline:(CFTimeInterval)deadline
               capturedAt:(CFTimeInterval)capturedAt
               completion:(void (^)(BrowserYouTubeHDPresentation *, NSError *))completion {
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    [webView evaluateJavaScriptAsync:@"window.__browserYouTubeHD && window.__browserYouTubeHD.info ? window.__browserYouTubeHD.info() : ''"
                          completion:^(id result) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSDictionary *info = nil;
        if ([result isKindOfClass:NSString.class] && [result length] > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            info = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        }
        NSError *error = nil;
        NSDictionary *captured = [strongSelf captureMatchingInfo:info error:&error];
        if (captured == nil) {
            BrowserWebView *strongWebView = weakWebView;
            if (strongWebView != nil && CACurrentMediaTime() < deadline) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf pollInfoOfWebView:strongWebView start:start deadline:deadline capturedAt:0.0 completion:completion];
                });
                return;
            }
            NSLog(@"[YouTubeHD] keine passende Medienanfrage nach %.1f s: %@", CACurrentMediaTime() - start, error.localizedDescription);
            completion(nil, error);
            return;
        }
        // signatureCipher: Nur die Formate, die der Seitenplayer abgerufen hat, haben eine Adresse. Die Brücke bittet
        // ihn um HD; bis zu 8 s auf das gewünschte Format warten, sonst mit dem nehmen, was da ist.
        CFTimeInterval now = CACurrentMediaTime();
        CFTimeInterval firstSeen = capturedAt > 0.0 ? capturedAt : now;
        if ([info[@"cipher"] boolValue] && info[@"wantItag"] != nil && ![strongSelf info:info hasFormatWithItag:info[@"wantItag"]]) {
            BrowserWebView *strongWebView = weakWebView;
            if (strongWebView != nil && now - firstSeen < 8.0) {
                if (capturedAt <= 0.0) {
                    NSLog(@"[YouTubeHD] Signatur nur für abgerufene Formate, warte auf itag %@ (%@p)", info[@"wantItag"], info[@"wantHeight"]);
                    [strongWebView evaluateJavaScriptAsync:@"window.__browserYouTubeHD && window.__browserYouTubeHD.askForHD('Übergabe')"];
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf pollInfoOfWebView:strongWebView start:start deadline:deadline capturedAt:firstSeen completion:completion];
                });
                return;
            }
            NSLog(@"[YouTubeHD] itag %@ nach %.1f s nicht abgerufen, nehme die vorhandenen Formate", info[@"wantItag"], now - firstSeen);
        }
        // Kurzes Vorab-pot (Apple TV: 16 Zeichen, das echte hat über 100): bis 4 s auf das echte warten, sonst bricht
        // googlevideo nach etwa 45 s mit 403 ab. Kommt keins, mit dem kurzen starten (Rückfall bei Abbruch).
        if ([captured[@"pot"] length] > 0 && [captured[@"pot"] length] < kBrowserYouTubeHDMinimumPotLength) {
            BrowserWebView *strongWebView = weakWebView;
            if (strongWebView != nil && now - firstSeen < 4.0) {
                if (capturedAt <= 0.0) {
                    NSLog(@"[YouTubeHD] pot erst %lu Zeichen (Vorab-Token), warte auf das echte", (unsigned long)[captured[@"pot"] length]);
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf pollInfoOfWebView:strongWebView start:start deadline:deadline capturedAt:firstSeen completion:completion];
                });
                return;
            }
            NSLog(@"[YouTubeHD] nach %.1f s nur kurzes pot (%lu Zeichen), starte trotzdem", now - firstSeen, (unsigned long)[captured[@"pot"] length]);
        }
        NSLog(@"[YouTubeHD] Medienanfrage itag=%@ nach %.1f s, n=%@ pot=%lu Zeichen", captured[@"itag"],
              CACurrentMediaTime() - start, captured[@"n"], (unsigned long)[captured[@"pot"] length]);
        [strongSelf buildPresentationFromInfo:info captured:captured start:start completion:completion];
    }];
}

- (BOOL)info:(NSDictionary *)info hasFormatWithItag:(id)itag {
    NSArray *formats = [info[@"formats"] isKindOfClass:NSArray.class] ? info[@"formats"] : @[];
    for (NSDictionary *format in formats) {
        if ([format isKindOfClass:NSDictionary.class] && [[format[@"itag"] description] isEqualToString:[itag description]]) {
            return YES;
        }
    }
    return NO;
}

/// Beobachtete Anfrage zum Player-Response der Seite (gleicher googlevideo-Parameter `id`), mit n und pot.
- (NSDictionary *)captureMatchingInfo:(NSDictionary *)info error:(NSError **)error {
    NSArray *formats = [info[@"formats"] isKindOfClass:NSArray.class] ? info[@"formats"] : @[];
    if (info == nil || formats.count == 0) {
        if (error != NULL) {
            *error = BrowserYouTubeHDMakeError(BrowserYouTubeHDErrorNoInfo, info == nil ? @"Brücke nicht aktiv" : @"keine Formate mit Adresse");
        }
        return nil;
    }
    NSDictionary *first = [formats.firstObject isKindOfClass:NSDictionary.class] ? formats.firstObject : @{};
    NSString *formatID = BrowserYouTubeHDQuery(first[@"url"])[@"id"] ?: @"";
    NSDictionary *captures = [info[@"captures"] isKindOfClass:NSDictionary.class] ? info[@"captures"] : @{};
    NSDictionary *capture = [captures[formatID] isKindOfClass:NSDictionary.class] ? captures[formatID] : nil;
    if (capture == nil || ![capture[@"url"] isKindOfClass:NSString.class]) {
        if (error != NULL) {
            *error = BrowserYouTubeHDMakeError(BrowserYouTubeHDErrorNoCapture,
                [NSString stringWithFormat:@"keine Anfrage zu id %@ (%lu andere)", formatID, (unsigned long)captures.count]);
        }
        return nil;
    }
    NSDictionary<NSString *, NSString *> *query = BrowserYouTubeHDQuery(capture[@"url"]);
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"url"] = capture[@"url"];
    result[@"itag"] = capture[@"itag"] ?: @"";
    result[@"n"] = query[@"n"] ?: @"";
    result[@"pot"] = query[@"pot"] ?: @"";
    return result;
}

- (NSArray<NSDictionary *> *)videoFormatsFromInfo:(NSDictionary *)info {
    NSInteger maxHeight = [NSUserDefaults.standardUserDefaults integerForKey:kBrowserYouTubeHDMaxHeightKey];
    if (maxHeight <= 0) {
        maxHeight = 1080;
    }
    NSMutableDictionary<NSNumber *, NSDictionary *> *bestByHeight = [NSMutableDictionary dictionary];
    for (NSDictionary *format in info[@"formats"]) {
        if (![format isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *mime = format[@"mime"] ?: @"";
        NSString *codecs = BrowserYouTubeHDCodecs(mime);
        NSInteger height = [format[@"h"] integerValue];
        if (![mime hasPrefix:@"video/mp4"] || !([codecs hasPrefix:@"avc1."] || [codecs hasPrefix:@"avc3."]) ||
            height <= 0 || height > maxHeight || format[@"init"] == nil || format[@"index"] == nil) {
            continue;
        }
        NSDictionary *current = bestByHeight[@(height)];
        BOOL better = current == nil || [format[@"fps"] integerValue] > [current[@"fps"] integerValue] ||
            ([format[@"fps"] integerValue] == [current[@"fps"] integerValue] && [format[@"bitrate"] longLongValue] > [current[@"bitrate"] longLongValue]);
        if (better) {
            bestByHeight[@(height)] = format;
        }
    }
    NSArray<NSNumber *> *heights = [bestByHeight.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSNumber *height in heights) {
        if (result.count >= kBrowserYouTubeHDMaxVariants) {
            break;
        }
        [result addObject:bestByHeight[height]];
    }
    return result;
}

/// AAC-Tonspuren, je Sprache eine (ohne DRC-Fassung, Stereo bevorzugt). Die Standardspur zuerst.
- (NSArray<NSDictionary *> *)audioFormatsFromInfo:(NSDictionary *)info {
    NSMutableDictionary<NSString *, NSDictionary *> *bestByLanguage = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *format in info[@"formats"]) {
        if (![format isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *mime = format[@"mime"] ?: @"";
        NSString *codecs = BrowserYouTubeHDCodecs(mime);
        if (![mime hasPrefix:@"audio/mp4"] || ![codecs hasPrefix:@"mp4a.40."] || [format[@"drc"] boolValue] ||
            [format[@"channels"] integerValue] > 2 || format[@"init"] == nil || format[@"index"] == nil) {
            continue;
        }
        NSString *language = [format[@"lang"] isKindOfClass:NSString.class] ? format[@"lang"] : @"";
        NSDictionary *current = bestByLanguage[language];
        if (current == nil) {
            [order addObject:language];
        }
        if (current == nil || [format[@"bitrate"] longLongValue] > [current[@"bitrate"] longLongValue]) {
            bestByLanguage[language] = format;
        }
    }
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSString *language in order) {
        NSDictionary *format = bestByLanguage[language];
        if ([format[@"audioDefault"] boolValue]) {
            [result insertObject:format atIndex:0];
        } else {
            [result addObject:format];
        }
    }
    if (result.count > kBrowserYouTubeHDMaxAudioTracks) {
        [result removeObjectsInRange:NSMakeRange(kBrowserYouTubeHDMaxAudioTracks, result.count - kBrowserYouTubeHDMaxAudioTracks)];
    }
    return result;
}

- (NSDictionary<NSString *, NSString *> *)headersForInfo:(NSDictionary *)info {
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    NSString *userAgent = [info[@"ua"] isKindOfClass:NSString.class] ? info[@"ua"] : @"";
    if (userAgent.length > 0) {
        headers[@"User-Agent"] = userAgent;
    }
    NSURL *page = [NSURL URLWithString:[info[@"page"] isKindOfClass:NSString.class] ? info[@"page"] : @""];
    if (page.host.length > 0) {
        headers[@"Referer"] = [NSString stringWithFormat:@"https://%@/", page.host];
    }
    return headers;
}

- (void)buildPresentationFromInfo:(NSDictionary *)info
                         captured:(NSDictionary *)captured
                            start:(CFTimeInterval)start
                       completion:(void (^)(BrowserYouTubeHDPresentation *, NSError *))completion {
    NSArray<NSDictionary *> *videoFormats = [self videoFormatsFromInfo:info];
    NSArray<NSDictionary *> *audioFormats = [self audioFormatsFromInfo:info];
    if (videoFormats.count == 0 || audioFormats.count == 0) {
        completion(nil, BrowserYouTubeHDMakeError(BrowserYouTubeHDErrorNoFormat,
            [NSString stringWithFormat:@"Formate: Video %lu, Ton %lu", (unsigned long)videoFormats.count, (unsigned long)audioFormats.count]));
        return;
    }
    NSDictionary<NSString *, NSString *> *headers = [self headersForInfo:info];
    NSMutableArray<BrowserYouTubeHDTrack *> *videoTracks = [NSMutableArray array];
    NSMutableArray<BrowserYouTubeHDTrack *> *audioTracks = [NSMutableArray array];
    NSMutableArray<BrowserYouTubeHDTrack *> *allTracks = [NSMutableArray array];
    for (NSArray *pair in @[@[videoFormats, videoTracks], @[audioFormats, audioTracks]]) {
        for (NSDictionary *format in pair[0]) {
            BrowserYouTubeHDTrack *track = [BrowserYouTubeHDTrack new];
            track.format = format;
            track.URLString = BrowserYouTubeHDPlaybackURL(format[@"url"], captured);
            track.codecs = BrowserYouTubeHDCodecs(format[@"mime"] ?: @"");
            track.initEnd = BrowserYouTubeHDLong(format[@"init"][@"end"]);
            track.indexStart = BrowserYouTubeHDLong(format[@"index"][@"start"]);
            track.indexEnd = BrowserYouTubeHDLong(format[@"index"][@"end"]);
            track.playlistName = [NSString stringWithFormat:@"%@_%@.m3u8", pair[1] == videoTracks ? @"video" : @"audio", format[@"itag"]];
            if (track.URLString.length == 0 || track.indexEnd <= track.indexStart) {
                continue;
            }
            [pair[1] addObject:track];
            [allTracks addObject:track];
        }
    }

    dispatch_group_t group = dispatch_group_create();
    for (BrowserYouTubeHDTrack *track in allTracks) {
        dispatch_group_enter(group);
        [self loadIndexOfTrack:track headers:headers completion:^{
            dispatch_group_leave(group);
        }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSPredicate *loaded = [NSPredicate predicateWithBlock:^BOOL(BrowserYouTubeHDTrack *track, __unused NSDictionary *bindings) {
            return track.segments.count > 0;
        }];
        NSArray<BrowserYouTubeHDTrack *> *videos = [videoTracks filteredArrayUsingPredicate:loaded];
        NSArray<BrowserYouTubeHDTrack *> *audios = [audioTracks filteredArrayUsingPredicate:loaded];
        NSMutableArray<NSString *> *indexLog = [NSMutableArray array];
        for (BrowserYouTubeHDTrack *track in allTracks) {
            [indexLog addObject:[NSString stringWithFormat:@"%@:%ld/%lu Seg/%.0f ms", track.format[@"itag"], (long)track.indexStatus,
                                 (unsigned long)track.segments.count, track.indexMilliseconds]];
        }
        if (videos.count == 0 || audios.count == 0) {
            NSLog(@"[YouTubeHD] Segmentindex fehlt: %@", [indexLog componentsJoinedByString:@", "]);
            completion(nil, BrowserYouTubeHDMakeError(BrowserYouTubeHDErrorIndex,
                [NSString stringWithFormat:@"Segmentindex nicht ladbar (%@)", [indexLog componentsJoinedByString:@", "]]));
            return;
        }
        BrowserYouTubeHDPresentation *presentation = [strongSelf presentationWithInfo:info videos:videos audios:audios headers:headers];
        presentation.summary = [NSString stringWithFormat:@"%@ | Index %@ | %.2f s", presentation.summary,
                                [indexLog componentsJoinedByString:@", "], CACurrentMediaTime() - start];
        NSLog(@"[YouTubeHD] HLS bereit: %@", presentation.summary);
        completion(presentation, nil);
    });
}

#pragma mark - Segmentindex (sidx)

- (void)loadIndexOfTrack:(BrowserYouTubeHDTrack *)track headers:(NSDictionary<NSString *, NSString *> *)headers completion:(dispatch_block_t)completion {
    NSString *indexURL = [BrowserYouTubeHDTestFailure() isEqualToString:@"index"] ? BrowserYouTubeHDExpiredURL(track.URLString) : track.URLString;
    NSURL *URL = [NSURL URLWithString:indexURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", track.indexStart, track.indexEnd] forHTTPHeaderField:@"Range"];
    CFTimeInterval started = CACurrentMediaTime();
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            track.indexMilliseconds = (CACurrentMediaTime() - started) * 1000.0;
            track.indexStatus = status;
            if (error != nil || status < 200 || status >= 300) {
                NSLog(@"[YouTubeHD] sidx itag=%@ HTTP %ld %@", track.format[@"itag"], (long)status, error.localizedDescription ?: @"");
                completion();
                return;
            }
            NSData *indexData = data;
            long long expected = track.indexEnd - track.indexStart + 1;
            if (status == 200 && (long long)data.length > expected && (long long)data.length > track.indexEnd) {
                // Server ignoriert Range: Index aus der ganzen Antwort schneiden.
                indexData = [data subdataWithRange:NSMakeRange((NSUInteger)track.indexStart, (NSUInteger)expected)];
            }
            [self parseIndexData:indexData ofTrack:track];
            completion();
        });
    }];
    [task resume];
}

static uint32_t BrowserYouTubeHDRead32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static uint64_t BrowserYouTubeHDRead64(const uint8_t *bytes) {
    return ((uint64_t)BrowserYouTubeHDRead32(bytes) << 32) | BrowserYouTubeHDRead32(bytes + 4);
}

/// ISO/IEC 14496-12 `sidx`: Bezugspunkt ist das erste Byte nach der Box, dazu `first_offset`.
- (void)parseIndexData:(NSData *)data ofTrack:(BrowserYouTubeHDTrack *)track {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (length < 32 || memcmp(bytes + 4, "sidx", 4) != 0) {
        NSLog(@"[YouTubeHD] sidx itag=%@ unlesbar (%lu Bytes)", track.format[@"itag"], (unsigned long)length);
        return;
    }
    uint32_t boxSize = BrowserYouTubeHDRead32(bytes);
    uint8_t version = bytes[8];
    uint32_t timescale = BrowserYouTubeHDRead32(bytes + 16);
    NSUInteger offset = 20;
    uint64_t firstOffset = 0;
    if (version == 0) {
        firstOffset = BrowserYouTubeHDRead32(bytes + offset + 4);
        offset += 8;
    } else {
        firstOffset = BrowserYouTubeHDRead64(bytes + offset + 8);
        offset += 16;
    }
    if (offset + 4 > length || timescale == 0) {
        return;
    }
    uint16_t count = (uint16_t)((bytes[offset + 2] << 8) | bytes[offset + 3]);
    offset += 4;
    long long position = track.indexStart + (long long)boxSize + (long long)firstOffset;
    NSMutableArray<NSArray<NSNumber *> *> *segments = [NSMutableArray arrayWithCapacity:count];
    NSTimeInterval total = 0.0;
    for (uint16_t i = 0; i < count && offset + 12 <= length; i++, offset += 12) {
        uint32_t reference = BrowserYouTubeHDRead32(bytes + offset);
        uint32_t size = reference & 0x7fffffff;
        NSTimeInterval duration = (NSTimeInterval)BrowserYouTubeHDRead32(bytes + offset + 4) / timescale;
        if (reference & 0x80000000) {
            // Verweis auf einen weiteren sidx (kommt bei YouTube nicht vor): abbrechen statt falsch abspielen.
            NSLog(@"[YouTubeHD] sidx itag=%@ verschachtelt, nicht unterstützt", track.format[@"itag"]);
            return;
        }
        [segments addObject:@[@(position), @(size), @(duration)]];
        position += size;
        total += duration;
    }
    track.segments = segments;
    track.duration = total;
}

#pragma mark - Playlists

/// DEBUG: `YouTubeHDTestFehler` = `index` (Segmentindex mit abgelaufener Adresse → 403, Rückfall) oder `segmente`
/// (Playlists mit abgelaufener Adresse → AVPlayer scheitert, Rückfall). Nur zum Prüfen der Rückfallwege.
/// Ohne PO-Token liefert googlevideo den Anfang der Datei (Index, erste Segmente) übrigens noch aus.
static NSString *BrowserYouTubeHDTestFailure(void) {
#if DEBUG
    return [NSUserDefaults.standardUserDefaults stringForKey:@"YouTubeHDTestFehler"] ?: @"";
#else
    return @"";
#endif
}

static NSString *BrowserYouTubeHDExpiredURL(NSString *URLString) {
    NSURLComponents *components = [NSURLComponents componentsWithString:URLString];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.percentEncodedQueryItems ?: @[]) {
        // Abgelaufene Adresse: googlevideo antwortet mit 403 wie nach Ablauf (expire, etwa 6 h).
        [items addObject:[item.name isEqualToString:@"expire"] ? [NSURLQueryItem queryItemWithName:@"expire" value:@"1600000000"] : item];
    }
    components.percentEncodedQueryItems = items;
    return components.URL.absoluteString ?: URLString;
}

static NSString *BrowserYouTubeHDMediaPlaylist(BrowserYouTubeHDTrack *track) {
    NSString *segmentURL = [BrowserYouTubeHDTestFailure() isEqualToString:@"segmente"] ? BrowserYouTubeHDExpiredURL(track.URLString) : track.URLString;
    NSTimeInterval maxDuration = 1.0;
    for (NSArray<NSNumber *> *segment in track.segments) {
        maxDuration = MAX(maxDuration, segment[2].doubleValue);
    }
    NSMutableString *playlist = [NSMutableString string];
    [playlist appendString:@"#EXTM3U\n#EXT-X-VERSION:7\n"];
    [playlist appendFormat:@"#EXT-X-TARGETDURATION:%ld\n", (long)ceil(maxDuration)];
    [playlist appendString:@"#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MEDIA-SEQUENCE:0\n"];
    [playlist appendFormat:@"#EXT-X-MAP:URI=\"%@\",BYTERANGE=\"%lld@0\"\n", segmentURL, track.initEnd + 1];
    for (NSArray<NSNumber *> *segment in track.segments) {
        [playlist appendFormat:@"#EXTINF:%.6f,\n#EXT-X-BYTERANGE:%lld@%lld\n%@\n",
         segment[2].doubleValue, segment[1].longLongValue, segment[0].longLongValue, segmentURL];
    }
    [playlist appendString:@"#EXT-X-ENDLIST\n"];
    return playlist;
}

static NSString *BrowserYouTubeHDLanguage(NSString *trackID) {
    // YouTube: "de.4", "en-US.3" → "de", "en-US".
    NSString *language = [trackID componentsSeparatedByString:@"."].firstObject ?: @"";
    return language;
}

- (BrowserYouTubeHDPresentation *)presentationWithInfo:(NSDictionary *)info
                                                videos:(NSArray<BrowserYouTubeHDTrack *> *)videos
                                                audios:(NSArray<BrowserYouTubeHDTrack *> *)audios
                                               headers:(NSDictionary<NSString *, NSString *> *)headers {
    NSString *videoID = [info[@"videoId"] isKindOfClass:NSString.class] && [info[@"videoId"] length] > 0 ? info[@"videoId"] : @"video";
    NSString *base = [NSString stringWithFormat:@"https://%@/%@/", kBrowserYouTubeHDPlaylistHost, videoID];
    NSMutableDictionary<NSString *, NSData *> *playlists = [NSMutableDictionary dictionary];
    for (BrowserYouTubeHDTrack *track in [videos arrayByAddingObjectsFromArray:audios]) {
        playlists[[base stringByAppendingString:track.playlistName]] = [BrowserYouTubeHDMediaPlaylist(track) dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSMutableString *master = [NSMutableString stringWithString:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"];
    long long audioBitrate = 0;
    NSString *audioCodecs = audios.firstObject.codecs;
    for (NSUInteger i = 0; i < audios.count; i++) {
        BrowserYouTubeHDTrack *track = audios[i];
        audioBitrate = MAX(audioBitrate, [track.format[@"bitrate"] longLongValue]);
        NSString *language = BrowserYouTubeHDLanguage(track.format[@"lang"] ?: @"");
        NSString *name = [track.format[@"audioName"] isKindOfClass:NSString.class] && [track.format[@"audioName"] length] > 0 ?
            track.format[@"audioName"] : (language.length > 0 ? language : @"Ton");
        name = [name stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
        NSString *languageAttribute = language.length > 0 ? [NSString stringWithFormat:@",LANGUAGE=\"%@\"", language] : @"";
        NSInteger channels = MAX(1, [track.format[@"channels"] integerValue]);
        [master appendFormat:@"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\",NAME=\"%@\"%@,DEFAULT=%@,AUTOSELECT=YES,CHANNELS=\"%ld\",URI=\"%@\"\n",
         name, languageAttribute, i == 0 ? @"YES" : @"NO", (long)channels, track.playlistName];
    }
    for (BrowserYouTubeHDTrack *track in videos) {
        long long bandwidth = [track.format[@"bitrate"] longLongValue] + audioBitrate;
        long long average = [track.format[@"avg"] longLongValue] > 0 ? [track.format[@"avg"] longLongValue] + audioBitrate : bandwidth;
        double fps = MAX(1.0, [track.format[@"fps"] doubleValue]);
        [master appendFormat:@"#EXT-X-STREAM-INF:BANDWIDTH=%lld,AVERAGE-BANDWIDTH=%lld,CODECS=\"%@,%@\",RESOLUTION=%ldx%ld,FRAME-RATE=%.3f,AUDIO=\"aac\"\n%@\n",
         bandwidth, average, track.codecs, audioCodecs, (long)[track.format[@"w"] integerValue], (long)[track.format[@"h"] integerValue],
         fps, track.playlistName];
    }
    NSString *masterURLString = [base stringByAppendingString:@"master.m3u8"];
    playlists[masterURLString] = [master dataUsingEncoding:NSUTF8StringEncoding];

    BrowserYouTubeHDPresentation *presentation = [BrowserYouTubeHDPresentation new];
    presentation.masterURL = [NSURL URLWithString:masterURLString];
    presentation.playlists = playlists;
    presentation.requestHeaders = headers;
    presentation.videoID = videoID;
    presentation.title = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : @"";
    presentation.author = [info[@"author"] isKindOfClass:NSString.class] ? info[@"author"] : @"";
    NSString *thumb = [info[@"thumb"] isKindOfClass:NSString.class] ? info[@"thumb"] : @"";
    presentation.artworkURL = thumb.length > 0 ? [NSURL URLWithString:thumb] : nil;
    presentation.pageTime = [info[@"t"] doubleValue];
    presentation.duration = videos.firstObject.duration;
    presentation.width = [videos.firstObject.format[@"w"] integerValue];
    presentation.height = [videos.firstObject.format[@"h"] integerValue];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (BrowserYouTubeHDTrack *track in videos) {
        [parts addObject:[NSString stringWithFormat:@"%@ %@x%@ %@ %@fps %lu Seg", track.format[@"itag"], track.format[@"w"], track.format[@"h"],
                          track.codecs, track.format[@"fps"], (unsigned long)track.segments.count]];
    }
    for (BrowserYouTubeHDTrack *track in audios) {
        [parts addObject:[NSString stringWithFormat:@"Ton %@ %@ %@ %lu Seg", track.format[@"itag"], track.codecs,
                          track.format[@"lang"] ?: @"", (unsigned long)track.segments.count]];
    }
    presentation.summary = [NSString stringWithFormat:@"%@ „%@“ %.0f s: %@", videoID, presentation.title, presentation.duration,
                            [parts componentsJoinedByString:@"; "]];
    return presentation;
}

@end
