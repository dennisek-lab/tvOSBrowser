#import "BrowserSubtitleHLSAudioSource.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonCryptor.h>
#import <stdatomic.h>

static NSString * const kHLSLogPrefix = @"[Subtitles][HLS]";
static const NSTimeInterval kHLSLookahead = 60.0;      // so weit vor der Abspielposition laden
static const NSTimeInterval kHLSMaxPending = 25.0;     // höchstens so viel unausgewerteten Ton stauen

#pragma mark - Playlist-Modell

@interface BrowserHLSSegment : NSObject
@property (nonatomic, strong) NSURL *URL;
@property (nonatomic) NSTimeInterval start;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSRange byteRange;           // length 0 = ganze Datei
@property (nonatomic, strong, nullable) NSURL *mapURL;
@property (nonatomic) NSRange mapByteRange;
@property (nonatomic, strong, nullable) NSURL *keyURL;   // AES-128
@property (nonatomic, strong, nullable) NSData *keyIV;
@property (nonatomic) uint64_t sequence;
@property (nonatomic) BOOL hasDate;                // Start aus #EXT-X-PROGRAM-DATE-TIME (Sekunden seit 1970)
@end

@implementation BrowserHLSSegment
@end

static NSDictionary<NSString *, NSString *> *BrowserHLSAttributes(NSString *list) {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    NSScanner *scanner = [NSScanner scannerWithString:list];
    scanner.charactersToBeSkipped = nil;
    while (!scanner.isAtEnd) {
        NSString *key = nil;
        [scanner scanCharactersFromSet:NSCharacterSet.whitespaceCharacterSet intoString:NULL];
        // Attribut ohne „=“ am Ende: scanLocation += 1 läge hinter dem Text (NSRangeException).
        if (![scanner scanUpToString:@"=" intoString:&key] || ![scanner scanString:@"=" intoString:NULL]) {
            break;
        }
        NSString *value = @"";
        if ([scanner scanString:@"\"" intoString:NULL]) {
            [scanner scanUpToString:@"\"" intoString:&value];
            [scanner scanString:@"\"" intoString:NULL];
        } else {
            [scanner scanUpToString:@"," intoString:&value];
        }
        attributes[key.uppercaseString] = value ?: @"";
        [scanner scanString:@"," intoString:NULL];
    }
    return attributes;
}

static NSRange BrowserHLSByteRange(NSString *value, NSUInteger previousEnd) {
    // "<n>[@<o>]"
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"@"];
    NSUInteger length = (NSUInteger)parts.firstObject.longLongValue;
    NSUInteger offset = parts.count > 1 ? (NSUInteger)parts[1].longLongValue : previousEnd;
    return NSMakeRange(offset, length);
}

static NSData *BrowserHLSDataFromHex(NSString *hex) {
    if ([hex hasPrefix:@"0x"] || [hex hasPrefix:@"0X"]) {
        hex = [hex substringFromIndex:2];
    }
    NSMutableData *data = [NSMutableData dataWithLength:16];
    uint8_t *bytes = data.mutableBytes;
    NSUInteger digits = hex.length;
    for (NSUInteger i = 0; i < 16; i++) {
        NSInteger index = (NSInteger)digits - (NSInteger)(16 - i) * 2;
        if (index < 0) {
            continue;
        }
        unsigned value = 0;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange((NSUInteger)index, 2)]] scanHexInt:&value];
        bytes[i] = (uint8_t)value;
    }
    return data;
}

#pragma mark - Quelle

@interface BrowserSubtitleHLSAudioSource ()
@property (nonatomic, strong) NSURL *playlistURL;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *cookies;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSArray<BrowserHLSSegment *> *segments;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *dataCache; // Init-Segmente, Schlüssel
@property (nonatomic) NSUInteger nextIndex;
@property (nonatomic) NSTimeInterval runStart;
@property (nonatomic) BOOL pendingDiscontinuity;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL ready;
@property (nonatomic) BOOL running;
@property (nonatomic) BOOL failed;
@property (nonatomic) NSUInteger decodedSegments;
@property (nonatomic) double decodeSeconds;
// Live (ohne #EXT-X-ENDLIST): Playlist nachladen, neue Segmente anhängen.
@property (nonatomic) BOOL live;
@property (nonatomic, strong, nullable) NSURL *mediaPlaylistURL;
@property (nonatomic) NSTimeInterval targetDuration;
@property (nonatomic) NSUInteger reloads;
@property (nonatomic, readwrite) BOOL usesDateTimeline;
@end

@implementation BrowserSubtitleHLSAudioSource {
    _Atomic(double) _playbackTime;
    _Atomic(double) _playbackDate;
}

@synthesize delegate = _delegate;

- (instancetype)initWithPlaylistURL:(NSURL *)playlistURL requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders cookies:(NSArray<NSHTTPCookie *> *)cookies {
    self = [super init];
    if (self) {
        _playlistURL = playlistURL;
        _requestHeaders = [requestHeaders copy] ?: @{};
        _cookies = [cookies copy] ?: @[];
        _queue = dispatch_queue_create("io.github.tvosbrowser.app.subtitles.hls", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPShouldSetCookies = NO;
        configuration.timeoutIntervalForRequest = 20.0;
        NSOperationQueue *delegateQueue = [NSOperationQueue new];
        delegateQueue.underlyingQueue = _queue;
        delegateQueue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:delegateQueue];
        _dataCache = [NSMutableDictionary dictionary];
        _nextIndex = NSNotFound;
        atomic_store(&_playbackTime, 0.0);
        atomic_store(&_playbackDate, NAN);
        _targetDuration = 6.0;
    }
    return self;
}

- (void)dealloc {
    [_session invalidateAndCancel];
}

- (BOOL)deliversAhead {
    return YES;
}

- (NSString *)kindName {
    return @"hls";
}

- (void)start {
    dispatch_async(self.queue, ^{
        if (self.running) {
            return;
        }
        self.running = YES;
        [self loadPlaylist:self.playlistURL depth:0];
    });
}

- (void)stop {
    dispatch_async(self.queue, ^{
        if (!self.running) {
            return;
        }
        self.running = NO;
        [self.session invalidateAndCancel];
        NSLog(@"%@ gestoppt: %lu Segmente dekodiert, %.2f s Dekodierzeit", kHLSLogPrefix,
              (unsigned long)self.decodedSegments, self.decodeSeconds);
    });
}

- (void)updatePlaybackTime:(NSTimeInterval)time date:(NSTimeInterval)date rate:(float)rate {
    atomic_store(&_playbackDate, date);
    [self updatePlaybackTime:time rate:rate];
}

- (void)updatePlaybackTime:(NSTimeInterval)time rate:(float)rate {
    if (!isfinite(time)) {
        return;
    }
    atomic_store(&_playbackTime, time);
    dispatch_async(self.queue, ^{
        [self tick];
    });
}

- (void)failWithReason:(NSString *)reason {
    if (self.failed) {
        return;
    }
    self.failed = YES;
    NSLog(@"%@ %@", kHLSLogPrefix, reason);
    [self.delegate audioSource:self didFailWithReason:reason];
}

#pragma mark Netzwerk

- (NSMutableURLRequest *)requestForURL:(NSURL *)URL range:(NSRange)range {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [self.requestHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        if ([key caseInsensitiveCompare:@"Range"] != NSOrderedSame) {
            [request setValue:value forHTTPHeaderField:key];
        }
    }];
    NSString *host = URL.host.lowercaseString ?: @"";
    NSMutableArray<NSHTTPCookie *> *matching = [NSMutableArray array];
    for (NSHTTPCookie *cookie in self.cookies) {
        NSString *domain = cookie.domain.lowercaseString ?: @"";
        NSString *bare = [domain hasPrefix:@"."] ? [domain substringFromIndex:1] : domain;
        if ([host isEqualToString:bare] || [host hasSuffix:[@"." stringByAppendingString:bare]]) {
            [matching addObject:cookie];
        }
    }
    if (matching.count > 0) {
        [[NSHTTPCookie requestHeaderFieldsWithCookies:matching] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            [request setValue:value forHTTPHeaderField:key];
        }];
    }
    if (range.length > 0) {
        [request setValue:[NSString stringWithFormat:@"bytes=%lu-%lu", (unsigned long)range.location, (unsigned long)(NSMaxRange(range) - 1)]
       forHTTPHeaderField:@"Range"];
    }
    return request;
}

/// Lädt Daten; Abschluss auf self.queue.
- (void)fetchURL:(NSURL *)URL range:(NSRange)range completion:(void (^)(NSData * _Nullable data, NSString * _Nullable error))completion {
    if (!self.running) {
        // Nach stop ist die Session invalidiert; ein neuer Task darauf wirft NSGenericException.
        completion(nil, @"gestoppt");
        return;
    }
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:[self requestForURL:URL range:range]
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
        if (error != nil || data == nil || status >= 400) {
            completion(nil, error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status]);
            return;
        }
        if (range.length > 0 && status == 200 && data.length >= NSMaxRange(range)) {
            data = [data subdataWithRange:range];  // Server ignoriert Range
        }
        completion(data, nil);
    }];
    [task resume];
}

#pragma mark Playlists

- (void)loadPlaylist:(NSURL *)URL depth:(NSUInteger)depth {
    if (depth > 3) {
        [self failWithReason:@"HLS: zu viele verschachtelte Playlists"];
        return;
    }
    [self fetchURL:URL range:NSMakeRange(0, 0) completion:^(NSData *data, NSString *error) {
        if (!self.running) {
            return;
        }
        NSString *text = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (text == nil || ![text hasPrefix:@"#EXTM3U"]) {
            [self failWithReason:[NSString stringWithFormat:@"HLS: Playlist nicht lesbar (%@)", error ?: @"kein #EXTM3U"]];
            return;
        }
        if ([text containsString:@"#EXT-X-STREAM-INF"]) {
            NSURL *media = [self audioPlaylistURLFromMaster:text baseURL:URL];
            if (media == nil) {
                [self failWithReason:@"HLS: keine passende Audio-Playlist gefunden"];
                return;
            }
            [self loadPlaylist:media depth:depth + 1];
        } else {
            [self parseMediaPlaylist:text baseURL:URL];
        }
    }];
}

- (NSURL *)audioPlaylistURLFromMaster:(NSString *)text baseURL:(NSURL *)baseURL {
    NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *audio = [NSMutableArray array];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line hasPrefix:@"#EXT-X-MEDIA:"]) {
            NSDictionary *attributes = BrowserHLSAttributes([line substringFromIndex:13]);
            if ([attributes[@"TYPE"] isEqualToString:@"AUDIO"]) {
                [audio addObject:attributes];
            }
        } else if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            NSDictionary *attributes = BrowserHLSAttributes([line substringFromIndex:18]);
            for (NSUInteger j = i + 1; j < lines.count; j++) {
                NSString *uri = [lines[j] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (uri.length > 0 && ![uri hasPrefix:@"#"]) {
                    NSMutableDictionary *variant = [attributes mutableCopy];
                    variant[@"URI"] = uri;
                    [variants addObject:variant];
                    i = j;
                    break;
                }
            }
        }
    }
    if (variants.count == 0) {
        return nil;
    }
    // Varianten mit AAC bevorzugen (AC-3/E-AC-3 lässt sich nicht überall dekodieren), dann kleinste Bandbreite.
    NSArray *aacVariants = [variants filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *variant, NSDictionary *bindings) {
        NSString *codecs = variant[@"CODECS"];
        return codecs.length == 0 || [codecs containsString:@"mp4a"];
    }]];
    NSArray *candidates = aacVariants.count > 0 ? aacVariants : variants;
    candidates = [candidates sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@([a[@"BANDWIDTH"] longLongValue]) compare:@([b[@"BANDWIDTH"] longLongValue])];
    }];
    NSDictionary *variant = candidates.firstObject;
    NSString *group = variant[@"AUDIO"];
    if (group.length > 0) {
        NSArray *renditions = [audio filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *rendition, NSDictionary *bindings) {
            return [rendition[@"GROUP-ID"] isEqualToString:group] && [rendition[@"URI"] length] > 0;
        }]];
        NSDictionary *chosen = nil;
        NSString *language = self.preferredLanguage.lowercaseString;
        for (NSDictionary *rendition in renditions) {
            if (language.length > 0 && [[rendition[@"LANGUAGE"] lowercaseString] hasPrefix:language]) {
                chosen = rendition;
                break;
            }
        }
        for (NSDictionary *rendition in renditions) {
            if (chosen == nil && [rendition[@"DEFAULT"] isEqualToString:@"YES"]) {
                chosen = rendition;
            }
        }
        chosen = chosen ?: renditions.firstObject;
        if (chosen != nil) {
            NSLog(@"%@ Audio-Rendition „%@“ (%@, Gruppe %@)", kHLSLogPrefix, chosen[@"NAME"] ?: @"", chosen[@"LANGUAGE"] ?: @"-", group);
            return [NSURL URLWithString:chosen[@"URI"] relativeToURL:baseURL].absoluteURL;
        }
    }
    NSLog(@"%@ Ton gemuxt in Variante %@ bit/s (%@)", kHLSLogPrefix, variant[@"BANDWIDTH"] ?: @"?", variant[@"CODECS"] ?: @"");
    return [NSURL URLWithString:variant[@"URI"] relativeToURL:baseURL].absoluteURL;
}

static NSTimeInterval BrowserHLSParseDate(NSString *value) {
    static NSISO8601DateFormatter *fractional = nil;
    static NSISO8601DateFormatter *plain = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fractional = [NSISO8601DateFormatter new];
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
        plain.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSDate *date = [fractional dateFromString:trimmed] ?: [plain dateFromString:trimmed];
    if (date == nil && trimmed.length > 5 && ([trimmed hasSuffix:@"+0000"] || [trimmed hasSuffix:@"-0000"])) {
        trimmed = [[trimmed substringToIndex:trimmed.length - 5] stringByAppendingString:@"Z"];
        date = [fractional dateFromString:trimmed] ?: [plain dateFromString:trimmed];
    }
    return date != nil ? date.timeIntervalSince1970 : NAN;
}

- (void)parseMediaPlaylist:(NSString *)text baseURL:(NSURL *)baseURL {
    NSMutableArray<BrowserHLSSegment *> *segments = [NSMutableArray array];
    NSTimeInterval time = 0.0;
    NSTimeInterval pendingDuration = -1.0;
    NSTimeInterval pendingDate = NAN;
    NSTimeInterval runningDate = NAN;    // Datum des nächsten Segments (fortgeschrieben)
    NSRange pendingRange = NSMakeRange(0, 0);
    NSUInteger previousRangeEnd = 0;
    NSURL *mapURL = nil;
    NSRange mapRange = NSMakeRange(0, 0);
    NSURL *keyURL = nil;
    NSData *keyIV = nil;
    uint64_t sequence = 0;
    BOOL endList = NO;
    BOOL unsupportedKey = NO;
    NSTimeInterval targetDuration = 6.0;
    NSUInteger datedSegments = 0;
    NSUInteger discontinuities = 0;
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0) {
            continue;
        }
        if ([line hasPrefix:@"#EXTINF:"]) {
            pendingDuration = [[line substringFromIndex:8] doubleValue];
        } else if ([line hasPrefix:@"#EXT-X-TARGETDURATION:"]) {
            targetDuration = MAX(1.0, [[line substringFromIndex:22] doubleValue]);
        } else if ([line hasPrefix:@"#EXT-X-PROGRAM-DATE-TIME:"]) {
            pendingDate = BrowserHLSParseDate([line substringFromIndex:25]);
        } else if ([line hasPrefix:@"#EXT-X-DISCONTINUITY"] && ![line hasPrefix:@"#EXT-X-DISCONTINUITY-SEQUENCE"]) {
            discontinuities++;
        } else if ([line hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
            sequence = (uint64_t)[[line substringFromIndex:22] longLongValue];
        } else if ([line hasPrefix:@"#EXT-X-BYTERANGE:"]) {
            pendingRange = BrowserHLSByteRange([line substringFromIndex:17], previousRangeEnd);
        } else if ([line hasPrefix:@"#EXT-X-MAP:"]) {
            NSDictionary *attributes = BrowserHLSAttributes([line substringFromIndex:11]);
            mapURL = [NSURL URLWithString:attributes[@"URI"] relativeToURL:baseURL].absoluteURL;
            mapRange = attributes[@"BYTERANGE"] != nil ? BrowserHLSByteRange(attributes[@"BYTERANGE"], 0) : NSMakeRange(0, 0);
        } else if ([line hasPrefix:@"#EXT-X-KEY:"]) {
            NSDictionary *attributes = BrowserHLSAttributes([line substringFromIndex:11]);
            NSString *method = attributes[@"METHOD"] ?: @"NONE";
            if ([method isEqualToString:@"NONE"]) {
                keyURL = nil;
                keyIV = nil;
            } else if ([method isEqualToString:@"AES-128"]) {
                keyURL = [NSURL URLWithString:attributes[@"URI"] relativeToURL:baseURL].absoluteURL;
                keyIV = attributes[@"IV"] != nil ? BrowserHLSDataFromHex(attributes[@"IV"]) : nil;
            } else {
                unsupportedKey = YES;
            }
        } else if ([line hasPrefix:@"#EXT-X-ENDLIST"]) {
            endList = YES;
        } else if (![line hasPrefix:@"#"] && pendingDuration >= 0.0) {
            BrowserHLSSegment *segment = [BrowserHLSSegment new];
            segment.URL = [NSURL URLWithString:line relativeToURL:baseURL].absoluteURL;
            segment.start = time;
            segment.duration = pendingDuration;
            segment.byteRange = pendingRange;
            segment.mapURL = mapURL;
            segment.mapByteRange = mapRange;
            segment.keyURL = keyURL;
            segment.keyIV = keyIV;
            segment.sequence = sequence;
            if (isfinite(pendingDate)) {
                runningDate = pendingDate;
            }
            if (isfinite(runningDate)) {
                segment.hasDate = YES;
                segment.start = runningDate;   // vorläufig das Datum; unten je nach Zeitachse übernommen oder ersetzt
                datedSegments++;
                runningDate += pendingDuration;
            }
            if (segment.URL != nil) {
                [segments addObject:segment];
            }
            if (pendingRange.length > 0) {
                previousRangeEnd = NSMaxRange(pendingRange);
            }
            time += pendingDuration;
            sequence++;
            pendingDuration = -1.0;
            pendingDate = NAN;
            pendingRange = NSMakeRange(0, 0);
        }
    }
    if (unsupportedKey) {
        [self failWithReason:@"HLS: verschlüsselt (SAMPLE-AES/FairPlay), Ton nicht lesbar"];
        return;
    }
    BOOL firstLoad = !self.ready;
    if (segments.count == 0 && firstLoad) {
        [self failWithReason:@"HLS: Playlist ohne Segmente"];
        return;
    }
    self.targetDuration = targetDuration;
    if (firstLoad) {
        self.live = !endList;
        self.mediaPlaylistURL = baseURL;
        // VOD: Medienzeit = Summe der EXTINF ab Playlist-Anfang (so zählt AVPlayer.currentTime und video.currentTime).
        // Live: Datum aus PROGRAM-DATE-TIME (AVPlayerItem.currentDate bzw. video.getStartDate() + currentTime).
        // Live ohne Datum: Zeit ab dem ersten Segment der ersten Playlist (Player lädt sie fast gleichzeitig; geschätzt).
        self.usesDateTimeline = self.live && segments.count > 0 && datedSegments == segments.count;
    }
    NSUInteger added = 0;
    if (firstLoad) {
        double offset = 0.0;
        for (BrowserHLSSegment *segment in segments) {
            if (!self.usesDateTimeline) {
                segment.start = offset;
            }
            offset += segment.duration;
        }
        self.segments = segments;
        added = segments.count;
    } else if (self.live) {
        // Nachladen: nur Segmente mit neuer Sequenznummer anhängen; Zeit fortschreiben bzw. Datum übernehmen.
        NSMutableArray<BrowserHLSSegment *> *merged = [self.segments mutableCopy];
        BrowserHLSSegment *last = merged.lastObject;
        for (BrowserHLSSegment *segment in segments) {
            if (last != nil && segment.sequence <= last.sequence) {
                continue;
            }
            if (!self.usesDateTimeline || !segment.hasDate) {
                segment.start = last != nil ? last.start + last.duration : 0.0;
            }
            [merged addObject:segment];
            last = segment;
            added++;
        }
        // Live läuft beliebig lange: alte Segmente vergessen (Planung zählt in Indizes).
        if (merged.count > 400) {
            NSUInteger drop = merged.count - 400;
            [merged removeObjectsInRange:NSMakeRange(0, drop)];
            if (self.nextIndex != NSNotFound) {
                self.nextIndex = self.nextIndex > drop ? self.nextIndex - drop : 0;
            }
        }
        self.segments = merged;
        if (endList) {
            self.live = NO;  // Sendung beendet
        }
    }
    if (firstLoad) {
        self.ready = YES;
        NSString *timeline = !self.live ? @"VOD, Zeit = Summe EXTINF"
            : (self.usesDateTimeline ? @"Live, Zeitachse PROGRAM-DATE-TIME" : @"Live ohne PROGRAM-DATE-TIME, Zeitbezug geschätzt");
        NSLog(@"%@ Audio-Playlist %@: %lu Segmente, %.1f s, Ziel %.0f s, fMP4=%d, AES=%d, Brüche %lu, %@", kHLSLogPrefix,
              baseURL.lastPathComponent, (unsigned long)segments.count, time, targetDuration,
              segments.firstObject.mapURL != nil, segments.firstObject.keyURL != nil, (unsigned long)discontinuities, timeline);
    } else if (added > 0 && (self.reloads <= 3 || self.reloads % 20 == 0)) {
        BrowserHLSSegment *last = self.segments.lastObject;
        NSLog(@"%@ Live-Playlist #%lu: +%lu Segmente, Kante %.1f", kHLSLogPrefix, (unsigned long)self.reloads,
              (unsigned long)added, last.start + last.duration);
    }
    if (self.live) {
        // Wie ein Player: nach einer Zielzeit neu laden, ohne Neues nach der halben (RFC 8216, 6.3.4).
        [self scheduleReloadAfter:added > 0 ? targetDuration : targetDuration / 2.0];
    }
    [self tick];
}

- (void)scheduleReloadAfter:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(1.0, delay) * NSEC_PER_SEC)), self.queue, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.running || strongSelf.failed || strongSelf.mediaPlaylistURL == nil) {
            return;
        }
        strongSelf.reloads++;
        [strongSelf fetchURL:strongSelf.mediaPlaylistURL range:NSMakeRange(0, 0) completion:^(NSData *data, NSString *error) {
            if (!strongSelf.running) {
                return;
            }
            NSString *text = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            if (![text hasPrefix:@"#EXTM3U"]) {
                NSLog(@"%@ Live-Playlist nicht lesbar (%@), neuer Versuch", kHLSLogPrefix, error ?: @"kein #EXTM3U");
                [strongSelf scheduleReloadAfter:strongSelf.targetDuration];
                return;
            }
            [strongSelf parseMediaPlaylist:text baseURL:strongSelf.mediaPlaylistURL];
        }];
    });
}

#pragma mark Planung

- (NSUInteger)segmentIndexAtTime:(NSTimeInterval)time {
    NSArray<BrowserHLSSegment *> *segments = self.segments;
    for (NSUInteger i = 0; i < segments.count; i++) {
        if (time < segments[i].start + segments[i].duration) {
            return i;
        }
    }
    return segments.count;
}

- (void)tick {
    if (!self.running || !self.ready || self.busy || self.failed) {
        return;
    }
    NSArray<BrowserHLSSegment *> *segments = self.segments;
    NSTimeInterval time = self.usesDateTimeline ? atomic_load(&_playbackDate) : atomic_load(&_playbackTime);
    if (!isfinite(time)) {
        // Datum der Wiedergabe noch unbekannt: dort anfangen, wo AVPlayer/Safari live einsteigen (drei Zielzeiten vor der Kante).
        BrowserHLSSegment *last = segments.lastObject;
        time = last != nil ? last.start + last.duration - 3.0 * self.targetDuration : 0.0;
    }
    NSTimeInterval nextStart = self.nextIndex < segments.count ? segments[self.nextIndex].start : INFINITY;
    if (self.nextIndex == NSNotFound || time < self.runStart - 0.5 || (self.nextIndex < segments.count && time > nextStart + 3.0)) {
        NSUInteger index = [self segmentIndexAtTime:time];
        if (self.nextIndex != NSNotFound) {
            NSLog(@"%@ Sprung auf %.1f s → Segment %lu", kHLSLogPrefix, time, (unsigned long)index);
        }
        self.nextIndex = index;
        self.runStart = index < segments.count ? segments[index].start : time;
        self.pendingDiscontinuity = YES;
    }
    id<BrowserSubtitleAudioSourceDelegate> delegate = self.delegate;
    while (self.nextIndex < segments.count && [delegate respondsToSelector:@selector(audioSource:isRangeCoveredFrom:to:)]) {
        BrowserHLSSegment *segment = segments[self.nextIndex];
        if (![delegate audioSource:self isRangeCoveredFrom:segment.start to:segment.start + segment.duration]) {
            break;
        }
        self.nextIndex++;
        self.pendingDiscontinuity = YES;
    }
    if (self.nextIndex >= segments.count) {
        return;
    }
    BrowserHLSSegment *segment = segments[self.nextIndex];
    if (segment.start > time + kHLSLookahead) {
        return;
    }
    if ([delegate respondsToSelector:@selector(audioSourcePendingSeconds:)] && [delegate audioSourcePendingSeconds:self] > kHLSMaxPending) {
        return;
    }
    self.busy = YES;
    NSUInteger index = self.nextIndex;
    [self loadSegment:segment completion:^(NSData *samples, NSString *error) {
        self.busy = NO;
        if (!self.running) {
            return;
        }
        if (samples.length > 0) {
            BOOL discontinuity = self.pendingDiscontinuity;
            self.pendingDiscontinuity = NO;
            [self.delegate audioSource:self didProduceSamples:samples atTime:segment.start discontinuity:discontinuity];
        } else {
            NSLog(@"%@ Segment %lu (%.1f s) ohne Ton: %@", kHLSLogPrefix, (unsigned long)index, segment.start, error ?: @"leer");
            self.pendingDiscontinuity = YES;
        }
        if (self.nextIndex == index) {
            self.nextIndex = index + 1;
        }
        [self tick];
    }];
}

#pragma mark Laden und Dekodieren

- (void)cachedDataForURL:(NSURL *)URL range:(NSRange)range completion:(void (^)(NSData *data, NSString *error))completion {
    if (URL == nil) {
        completion([NSData data], nil);
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@#%lu-%lu", URL.absoluteString, (unsigned long)range.location, (unsigned long)range.length];
    NSData *cached = self.dataCache[key];
    if (cached != nil) {
        completion(cached, nil);
        return;
    }
    [self fetchURL:URL range:range completion:^(NSData *data, NSString *error) {
        if (data != nil) {
            self.dataCache[key] = data;
        }
        completion(data, error);
    }];
}

- (void)loadSegment:(BrowserHLSSegment *)segment completion:(void (^)(NSData * _Nullable samples, NSString * _Nullable error))completion {
    [self cachedDataForURL:segment.mapURL range:segment.mapByteRange completion:^(NSData *initData, NSString *initError) {
        if (initData == nil) {
            completion(nil, [@"Init-Segment: " stringByAppendingString:initError ?: @"?"]);
            return;
        }
        [self cachedDataForURL:segment.keyURL range:NSMakeRange(0, 0) completion:^(NSData *key, NSString *keyError) {
            if (key == nil) {
                completion(nil, [@"Schlüssel: " stringByAppendingString:keyError ?: @"?"]);
                return;
            }
            [self fetchURL:segment.URL range:segment.byteRange completion:^(NSData *data, NSString *error) {
                if (data == nil) {
                    completion(nil, error);
                    return;
                }
                if (segment.keyURL != nil) {
                    data = [self decryptAES128:data key:key segment:segment];
                    if (data == nil) {
                        completion(nil, @"Entschlüsselung fehlgeschlagen");
                        return;
                    }
                }
                CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
                NSString *decodeError = nil;
                NSData *samples = [self decodeSegmentData:data initData:initData error:&decodeError];
                double elapsed = CFAbsoluteTimeGetCurrent() - begin;
                self.decodedSegments++;
                self.decodeSeconds += elapsed;
                if (self.decodedSegments <= 3 || self.decodedSegments % 20 == 0) {
                    NSLog(@"%@ Segment @ %.1f s: %lu KB → %.2f s Ton in %.3f s", kHLSLogPrefix, segment.start,
                          (unsigned long)(data.length / 1024), samples.length / sizeof(float) / 16000.0, elapsed);
                }
                completion(samples, decodeError);
            }];
        }];
    }];
}

- (NSData *)decryptAES128:(NSData *)data key:(NSData *)key segment:(BrowserHLSSegment *)segment {
    if (key.length != kCCKeySizeAES128) {
        return nil;
    }
    NSData *iv = segment.keyIV;
    if (iv == nil) {
        NSMutableData *sequenceIV = [NSMutableData dataWithLength:16];
        uint64_t big = CFSwapInt64HostToBig(segment.sequence);
        memcpy((uint8_t *)sequenceIV.mutableBytes + 8, &big, 8);
        iv = sequenceIV;
    }
    NSMutableData *output = [NSMutableData dataWithLength:data.length + kCCBlockSizeAES128];
    size_t moved = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes, key.length, iv.bytes,
                                     data.bytes, data.length, output.mutableBytes, output.length, &moved);
    if (status != kCCSuccess) {
        return nil;
    }
    output.length = moved;
    return output;
}

- (NSData *)decodeSegmentData:(NSData *)data initData:(NSData *)initData error:(NSString **)error {
    const uint8_t *bytes = data.bytes;
    if (initData.length > 0 || (data.length > 8 && (memcmp(bytes + 4, "moof", 4) == 0 || memcmp(bytes + 4, "styp", 4) == 0 || memcmp(bytes + 4, "ftyp", 4) == 0))) {
        NSMutableData *file = [initData mutableCopy];
        [file appendData:data];
        return [self decodeWithAssetReader:file extension:@"mp4" error:error];
    }
    if (data.length >= 188 * 2 && bytes[0] == 0x47 && bytes[188] == 0x47) {
        NSString *extension = nil;
        NSData *elementary = [self demuxTransportStream:data extension:&extension error:error];
        if (elementary == nil) {
            return nil;
        }
        return [self decodeWithExtAudioFile:elementary extension:extension error:error];
    }
    // Gepacktes Audio (.aac/.mp3/.ac3), meist mit ID3-Kopf für den Zeitstempel.
    NSData *payload = [self dataByStrippingID3:data];
    const uint8_t *p = payload.bytes;
    NSString *extension = @"aac";
    if (payload.length > 2) {
        if (p[0] == 0x0B && p[1] == 0x77) {
            extension = @"ac3";
        } else if (p[0] == 0xFF && (p[1] & 0xF6) == 0xF0) {
            extension = @"aac";   // ADTS
        } else if (p[0] == 0xFF && (p[1] & 0xE0) == 0xE0) {
            extension = @"mp3";
        }
    }
    return [self decodeWithExtAudioFile:payload extension:extension error:error];
}

- (NSData *)dataByStrippingID3:(NSData *)data {
    NSUInteger offset = 0;
    const uint8_t *p = data.bytes;
    while (data.length >= offset + 10 && memcmp(p + offset, "ID3", 3) == 0) {
        NSUInteger size = ((NSUInteger)(p[offset + 6] & 0x7F) << 21) | ((NSUInteger)(p[offset + 7] & 0x7F) << 14) |
                          ((NSUInteger)(p[offset + 8] & 0x7F) << 7) | (NSUInteger)(p[offset + 9] & 0x7F);
        offset += 10 + size + ((p[offset + 5] & 0x10) ? 10 : 0);
    }
    return offset > 0 && offset < data.length ? [data subdataWithRange:NSMakeRange(offset, data.length - offset)] : data;
}

/// Holt den Audio-Elementarstrom (PES-Nutzdaten) aus MPEG-TS.
- (NSData *)demuxTransportStream:(NSData *)data extension:(NSString **)extension error:(NSString **)error {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length - (data.length % 188);
    int pmtPID = -1;
    int audioPID = -1;
    uint8_t audioType = 0;
    NSMutableData *elementary = [NSMutableData data];
    for (NSUInteger offset = 0; offset + 188 <= length; offset += 188) {
        const uint8_t *packet = bytes + offset;
        if (packet[0] != 0x47) {
            continue;
        }
        BOOL unitStart = (packet[1] & 0x40) != 0;
        int pid = ((packet[1] & 0x1F) << 8) | packet[2];
        int adaptation = (packet[3] >> 4) & 0x3;
        NSUInteger payload = 4;
        if (adaptation & 0x2) {
            payload += 1 + packet[4];
        }
        if (!(adaptation & 0x1) || payload >= 188) {
            continue;
        }
        const uint8_t *p = packet + payload;
        NSUInteger available = 188 - payload;
        if (pid == 0 && unitStart && pmtPID < 0) {
            NSUInteger pointer = p[0];
            if (1 + pointer + 12 > available) {
                continue;  // pointer_field zeigt hinter das Paket (sonst Unterlauf und Lesen außerhalb)
            }
            const uint8_t *section = p + 1 + pointer;
            NSUInteger sectionAvailable = available - 1 - pointer;
            if (sectionAvailable < 12 || section[0] != 0x00) {
                continue;
            }
            NSUInteger sectionLength = ((section[1] & 0x0F) << 8) | section[2];
            NSUInteger end = MIN(3 + sectionLength - 4, sectionAvailable);
            for (NSUInteger i = 8; i + 4 <= end; i += 4) {
                int program = (section[i] << 8) | section[i + 1];
                if (program != 0) {
                    pmtPID = ((section[i + 2] & 0x1F) << 8) | section[i + 3];
                    break;
                }
            }
        } else if (pid == pmtPID && unitStart && audioPID < 0) {
            NSUInteger pointer = p[0];
            if (1 + pointer + 12 > available) {
                continue;  // pointer_field zeigt hinter das Paket (sonst Unterlauf und Lesen außerhalb)
            }
            const uint8_t *section = p + 1 + pointer;
            NSUInteger sectionAvailable = available - 1 - pointer;
            if (sectionAvailable < 12 || section[0] != 0x02) {
                continue;
            }
            NSUInteger sectionLength = ((section[1] & 0x0F) << 8) | section[2];
            NSUInteger programInfo = ((section[10] & 0x0F) << 8) | section[11];
            NSUInteger end = MIN(3 + sectionLength - 4, sectionAvailable);
            for (NSUInteger i = 12 + programInfo; i + 5 <= end;) {
                uint8_t type = section[i];
                int esPID = ((section[i + 1] & 0x1F) << 8) | section[i + 2];
                NSUInteger infoLength = ((section[i + 3] & 0x0F) << 8) | section[i + 4];
                if (type == 0x0F || type == 0x03 || type == 0x04 || type == 0x81) {
                    audioPID = esPID;
                    audioType = type;
                    break;
                }
                i += 5 + infoLength;
            }
        } else if (pid == audioPID && audioPID >= 0) {
            if (unitStart) {
                if (available < 9 || p[0] != 0 || p[1] != 0 || p[2] != 1) {
                    continue;
                }
                NSUInteger headerLength = 9 + p[8];
                if (headerLength >= available) {
                    continue;
                }
                [elementary appendBytes:p + headerLength length:available - headerLength];
            } else {
                [elementary appendBytes:p length:available];
            }
        }
    }
    if (audioPID < 0) {
        if (error != NULL) {
            *error = pmtPID < 0 ? @"TS ohne PAT/PMT" : @"TS ohne unterstützte Audiospur (AAC/MP3/AC-3)";
        }
        return nil;
    }
    if (extension != NULL) {
        *extension = audioType == 0x0F ? @"aac" : (audioType == 0x81 ? @"ac3" : @"mp3");
    }
    return elementary;
}

- (NSURL *)temporaryFileWithData:(NSData *)data extension:(NSString *)extension {
    NSString *name = [NSString stringWithFormat:@"subtitle-%@.%@", NSUUID.UUID.UUIDString, extension];
    NSURL *URL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    return [data writeToURL:URL atomically:NO] ? URL : nil;
}

- (NSData *)decodeWithExtAudioFile:(NSData *)data extension:(NSString *)extension error:(NSString **)error {
    NSURL *URL = [self temporaryFileWithData:data extension:extension];
    if (URL == nil) {
        if (error != NULL) { *error = @"Temporärdatei"; }
        return nil;
    }
    ExtAudioFileRef file = NULL;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)URL, &file);
    NSMutableData *output = [NSMutableData data];
    if (status == noErr) {
        AudioStreamBasicDescription fileFormat = {0};
        UInt32 size = sizeof(fileFormat);
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat);
        UInt32 channels = MAX(1u, fileFormat.mChannelsPerFrame);
        AudioStreamBasicDescription client = {0};
        client.mSampleRate = 16000.0;
        client.mFormatID = kAudioFormatLinearPCM;
        client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        client.mBitsPerChannel = 32;
        client.mChannelsPerFrame = channels;
        client.mFramesPerPacket = 1;
        client.mBytesPerFrame = 4 * channels;
        client.mBytesPerPacket = 4 * channels;
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
        const UInt32 chunkFrames = 4096;
        float *buffer = (float *)malloc(chunkFrames * channels * sizeof(float));
        while (status == noErr) {
            AudioBufferList list;
            list.mNumberBuffers = 1;
            list.mBuffers[0].mNumberChannels = channels;
            list.mBuffers[0].mDataByteSize = chunkFrames * channels * sizeof(float);
            list.mBuffers[0].mData = buffer;
            UInt32 frames = chunkFrames;
            status = ExtAudioFileRead(file, &frames, &list);
            if (status != noErr || frames == 0) {
                break;
            }
            NSUInteger start = output.length;
            output.length += frames * sizeof(float);
            float *mono = (float *)((uint8_t *)output.mutableBytes + start);
            for (UInt32 f = 0; f < frames; f++) {
                float sum = 0.0f;
                for (UInt32 c = 0; c < channels; c++) {
                    sum += buffer[f * channels + c];
                }
                mono[f] = sum / (float)channels;
            }
        }
        free(buffer);
        ExtAudioFileDispose(file);
    }
    [NSFileManager.defaultManager removeItemAtURL:URL error:NULL];
    if (output.length == 0 && error != NULL) {
        *error = [NSString stringWithFormat:@"ExtAudioFile .%@ Fehler %d", extension, (int)status];
    }
    return output;
}

- (NSData *)decodeWithAssetReader:(NSData *)data extension:(NSString *)extension error:(NSString **)error {
    NSURL *URL = [self temporaryFileWithData:data extension:extension];
    if (URL == nil) {
        if (error != NULL) { *error = @"Temporärdatei"; }
        return nil;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:URL options:nil];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block AVAssetTrack *track = nil;
    [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *loadError) {
        track = tracks.firstObject;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    NSMutableData *output = [NSMutableData data];
    NSString *problem = nil;
    if (track == nil) {
        problem = @"fMP4 ohne Audiospur";
    } else {
        NSError *readerError = nil;
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
        NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM),
                                   AVSampleRateKey: @16000,
                                   AVNumberOfChannelsKey: @1,
                                   AVLinearPCMBitDepthKey: @32,
                                   AVLinearPCMIsFloatKey: @YES,
                                   AVLinearPCMIsNonInterleaved: @NO,
                                   AVLinearPCMIsBigEndianKey: @NO};
        AVAssetReaderTrackOutput *trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
        if (reader != nil && [reader canAddOutput:trackOutput]) {
            [reader addOutput:trackOutput];
            [reader startReading];
            CMSampleBufferRef sample = NULL;
            while ((sample = [trackOutput copyNextSampleBuffer]) != NULL) {
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
                size_t blockLength = block != NULL ? CMBlockBufferGetDataLength(block) : 0;
                if (blockLength > 0) {
                    NSUInteger start = output.length;
                    output.length += blockLength;
                    CMBlockBufferCopyDataBytes(block, 0, blockLength, (uint8_t *)output.mutableBytes + start);
                }
                CFRelease(sample);
            }
            if (reader.status == AVAssetReaderStatusFailed) {
                problem = reader.error.localizedDescription;
            }
        } else {
            problem = readerError.localizedDescription ?: @"AVAssetReader nicht möglich";
        }
    }
    [NSFileManager.defaultManager removeItemAtURL:URL error:NULL];
    if (output.length == 0 && error != NULL) {
        *error = problem ?: @"fMP4 ohne Samples";
    }
    return output;
}

@end
