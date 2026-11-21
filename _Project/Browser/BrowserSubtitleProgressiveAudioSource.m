#import "BrowserSubtitleProgressiveAudioSource.h"
#import "BrowserLocalization.h"

#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>

static NSString * const kMP4LogPrefix = @"[Subtitles][MP4]";
static const NSUInteger kMP4InitialFetch = 256 * 1024;       // Kopf der Datei (ftyp, meist schon moov)
static const uint64_t kMP4MaxMoovSize = 16ull * 1024 * 1024;  // größere moov-Atome: Tap nehmen
static const uint64_t kMP4MergeGap = 2 * 1024;                // kleinere Lücken immer mitladen
static const NSTimeInterval kMP4FirstBatchSeconds = 4.0;      // nach Start/Sprung: schnell den Anfang
static const NSTimeInterval kMP4BatchSeconds = 10.0;
static const OSStatus kMP4NeedMoreData = 'more';

static inline uint16_t BrowserMP4U16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static inline uint32_t BrowserMP4U32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static inline uint64_t BrowserMP4U64(const uint8_t *p) { return ((uint64_t)BrowserMP4U32(p) << 32) | BrowserMP4U32(p + 4); }
#define BrowserMP4Type(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))

static NSString *BrowserMP4TypeName(uint32_t type) {
    char name[5] = {(char)(type >> 24), (char)(type >> 16), (char)(type >> 8), (char)type, 0};
    for (int i = 0; i < 4; i++) {
        if (name[i] < 32 || name[i] > 126) { name[i] = '?'; }
    }
    return [NSString stringWithUTF8String:name];
}

typedef struct {
    uint32_t type;
    size_t start;     // Anfang der Box (Kopf)
    size_t payload;   // Anfang der Nutzdaten
    size_t end;       // Ende der Box
} BrowserMP4Box;

/// Nächste Box in [*cursor, limit). NO am Ende oder bei kaputter Größe.
static BOOL BrowserMP4NextBox(const uint8_t *bytes, size_t limit, size_t *cursor, BrowserMP4Box *box) {
    size_t offset = *cursor;
    if (offset + 8 > limit) {
        return NO;
    }
    uint64_t size = BrowserMP4U32(bytes + offset);
    size_t header = 8;
    if (size == 1) {
        if (offset + 16 > limit) {
            return NO;
        }
        size = BrowserMP4U64(bytes + offset + 8);
        header = 16;
    } else if (size == 0) {
        size = limit - offset;
    }
    if (size < header || size > limit - offset) {
        return NO;
    }
    box->type = BrowserMP4U32(bytes + offset + 4);
    box->start = offset;
    box->payload = offset + header;
    box->end = offset + (size_t)size;
    *cursor = box->end;
    return YES;
}

static BOOL BrowserMP4FindChild(const uint8_t *bytes, size_t start, size_t end, uint32_t type, BrowserMP4Box *found) {
    size_t cursor = start;
    BrowserMP4Box box;
    while (BrowserMP4NextBox(bytes, end, &cursor, &box)) {
        if (box.type == type) {
            *found = box;
            return YES;
        }
    }
    return NO;
}

/// Länge eines MPEG-4-Deskriptors (bis 4 Bytes mit Fortsetzungsbit).
static BOOL BrowserMP4DescriptorLength(const uint8_t *bytes, size_t end, size_t *cursor, size_t *length) {
    size_t value = 0;
    for (int i = 0; i < 4; i++) {
        if (*cursor >= end) {
            return NO;
        }
        uint8_t b = bytes[(*cursor)++];
        value = (value << 7) | (b & 0x7F);
        if (!(b & 0x80)) {
            *length = value;
            return YES;
        }
    }
    *length = value;
    return YES;
}

/// ES_Descriptor (Inhalt von esds ohne Version/Flags): objectTypeIndication und AudioSpecificConfig.
static BOOL BrowserMP4ParseESDescriptor(NSData *descriptor, uint8_t *objectType, NSData **specificConfig) {
    const uint8_t *p = descriptor.bytes;
    size_t end = descriptor.length;
    size_t cursor = 0;
    size_t length = 0;
    if (end < 2 || p[cursor++] != 0x03 || !BrowserMP4DescriptorLength(p, end, &cursor, &length)) {
        return NO;
    }
    if (cursor + 3 > end) {
        return NO;
    }
    cursor += 2;  // ES_ID
    uint8_t flags = p[cursor++];
    if (flags & 0x80) { cursor += 2; }
    if (flags & 0x40) {
        if (cursor >= end) { return NO; }
        cursor += 1 + p[cursor];
    }
    if (flags & 0x20) { cursor += 2; }
    if (cursor + 2 > end || p[cursor++] != 0x04 || !BrowserMP4DescriptorLength(p, end, &cursor, &length) || cursor + 13 > end) {
        return NO;
    }
    *objectType = p[cursor];
    size_t decoderEnd = MIN(end, cursor + length);
    cursor += 13;
    if (cursor + 2 <= decoderEnd && p[cursor] == 0x05) {
        cursor++;
        if (BrowserMP4DescriptorLength(p, decoderEnd, &cursor, &length) && cursor + length <= decoderEnd) {
            *specificConfig = [NSData dataWithBytes:p + cursor length:length];
        }
    }
    return YES;
}

static OSStatus BrowserMP4InputProc(AudioConverterRef converter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData,
                                    AudioStreamPacketDescription **outDescriptions, void *userData);

typedef struct {
    const uint8_t *data;
    const uint32_t *sizes;
    const size_t *offsets;      // in `data`
    UInt32 count;
    UInt32 next;
    BOOL endOfStream;
    AudioStreamPacketDescription description;
} BrowserMP4DecodeInput;

static OSStatus BrowserMP4InputProc(AudioConverterRef converter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData,
                                    AudioStreamPacketDescription **outDescriptions, void *userData) {
    (void)converter;
    BrowserMP4DecodeInput *input = (BrowserMP4DecodeInput *)userData;
    if (input->next >= input->count) {
        *ioNumberDataPackets = 0;
        ioData->mBuffers[0].mData = NULL;
        ioData->mBuffers[0].mDataByteSize = 0;
        return input->endOfStream ? noErr : kMP4NeedMoreData;
    }
    // Ein Paket je Aufruf: die Pakete liegen im Puffer hintereinander, aber jede Beschreibung braucht Versatz 0.
    UInt32 index = input->next++;
    ioData->mBuffers[0].mData = (void *)(input->data + input->offsets[index]);
    ioData->mBuffers[0].mDataByteSize = input->sizes[index];
    *ioNumberDataPackets = 1;
    if (outDescriptions != NULL) {
        input->description.mStartOffset = 0;
        input->description.mVariableFramesInPacket = 0;
        input->description.mDataByteSize = input->sizes[index];
        *outDescriptions = &input->description;
    }
    return noErr;
}

#pragma mark - Netz (Delegate-Vermittler, damit die Session die Quelle nicht festhält)

@class BrowserSubtitleProgressiveAudioSource;

@interface BrowserMP4Fetch : NSObject
@property (nonatomic) NSRange range;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic) uint64_t totalLength;
@property (nonatomic, copy, nullable) NSString *error;
@property (nonatomic, copy) void (^completion)(NSData * _Nullable data, uint64_t totalLength, NSString * _Nullable error);
@end

@implementation BrowserMP4Fetch
@end

@interface BrowserMP4SessionDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, BrowserMP4Fetch *> *fetches;  // nur auf der Queue der Quelle
@end

@implementation BrowserMP4SessionDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _fetches = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    BrowserMP4Fetch *fetch = self.fetches[@(dataTask.taskIdentifier)];
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    NSInteger status = http != nil ? http.statusCode : 200;
    if (status >= 400) {
        fetch.error = [NSString stringWithFormat:@"HTTP %ld", (long)status];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (status == 206) {
        NSString *contentRange = [http valueForHTTPHeaderField:@"Content-Range"];  // bytes a-b/total
        NSRange slash = [contentRange rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            fetch.totalLength = (uint64_t)[[contentRange substringFromIndex:slash.location + 1] longLongValue];
        }
    } else {
        // Server ignoriert Range: nur kleine Dateien ganz nehmen, sonst würde das ganze Video geladen.
        long long expected = response.expectedContentLength;
        fetch.totalLength = expected > 0 ? (uint64_t)expected : 0;
        if (fetch.range.length > 0 && (expected < 0 || expected > 4 * 1024 * 1024)) {
            fetch.error = BLS(@"Server unterstützt keine Range-Anfragen");
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.fetches[@(dataTask.taskIdentifier)].data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    BrowserMP4Fetch *fetch = self.fetches[@(task.taskIdentifier)];
    [self.fetches removeObjectForKey:@(task.taskIdentifier)];
    if (fetch == nil) {
        return;
    }
    NSString *problem = fetch.error ?: (error != nil ? error.localizedDescription : nil);
    NSData *data = problem == nil ? fetch.data : nil;
    NSHTTPURLResponse *http = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
    if (data != nil && fetch.range.length > 0 && http.statusCode == 200) {
        // Ganze (kleine) Datei bekommen: gewünschten Ausschnitt nehmen.
        NSUInteger start = MIN(fetch.range.location, data.length);
        data = [data subdataWithRange:NSMakeRange(start, MIN(fetch.range.length, data.length - start))];
    }
    fetch.completion(data, fetch.totalLength, problem);
}

@end

#pragma mark - Quelle

@interface BrowserSubtitleProgressiveAudioSource ()
@property (nonatomic, strong) NSURL *URL;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *cookies;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) BrowserMP4SessionDelegate *sessionDelegate;
@property (nonatomic) BOOL running;
@property (nonatomic) BOOL ready;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL failed;
@property (nonatomic) uint64_t fileLength;
@property (nonatomic, copy) NSString *codecName;
// Spur
@property (nonatomic) uint32_t timescale;
@property (nonatomic) int64_t mediaTimeOffset;     // elst media_time (Spurzeitskala)
@property (nonatomic) double presentationShift;     // leere Edits am Anfang (s)
@property (nonatomic) AudioStreamBasicDescription inputFormat;
@property (nonatomic, strong, nullable) NSData *magicCookie;
// Planung
@property (nonatomic) NSUInteger nextPacket;
@property (nonatomic) double runStartTime;
@property (nonatomic) uint64_t runSamples;
@property (nonatomic) BOOL pendingDiscontinuity;
@property (nonatomic) BOOL firstBatchOfRun;
// Statistik
@property (nonatomic) uint64_t fetchedBytes;
@property (nonatomic) NSUInteger requests;
@property (nonatomic) NSUInteger batches;
@property (nonatomic) double decodeSeconds;
@property (nonatomic) NSUInteger retries;
@end

@implementation BrowserSubtitleProgressiveAudioSource {
    _Atomic(double) _playbackTime;
    uint64_t *_packetOffsets;
    uint32_t *_packetSizes;
    int64_t *_packetTimes;    // DTS in Spurzeitskala
    NSUInteger _packetCount;
    AudioConverterRef _converter;
    UInt32 _channels;
}

@synthesize delegate = _delegate;

+ (BOOL)canHandleURL:(NSURL *)URL {
    NSString *scheme = URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return NO;
    }
    NSString *string = URL.absoluteString.lowercaseString;
    return ![string containsString:@".m3u8"] && ![string containsString:@".mpd"] && ![string containsString:@"format=m3u8"];
}

- (instancetype)initWithURL:(NSURL *)URL requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders cookies:(NSArray<NSHTTPCookie *> *)cookies {
    self = [super init];
    if (self) {
        _URL = URL;
        _requestHeaders = [requestHeaders copy] ?: @{};
        _cookies = [cookies copy] ?: @[];
        _lookahead = 60.0;
        _maxPending = 25.0;
        _queue = dispatch_queue_create("tvbrowser.subtitles.mp4", DISPATCH_QUEUE_SERIAL);
        _sessionDelegate = [BrowserMP4SessionDelegate new];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPShouldSetCookies = NO;
        configuration.timeoutIntervalForRequest = 20.0;
        configuration.HTTPMaximumConnectionsPerHost = 4;
        NSOperationQueue *delegateQueue = [NSOperationQueue new];
        delegateQueue.underlyingQueue = _queue;
        delegateQueue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:_sessionDelegate delegateQueue:delegateQueue];
        _nextPacket = NSNotFound;
        atomic_store(&_playbackTime, 0.0);
    }
    return self;
}

- (void)dealloc {
    [_session invalidateAndCancel];
    if (_converter != NULL) {
        AudioConverterDispose(_converter);
    }
    free(_packetOffsets);
    free(_packetSizes);
    free(_packetTimes);
}

- (BOOL)deliversAhead {
    return YES;
}

- (NSString *)kindName {
    return @"mp4";
}

- (void)start {
    dispatch_async(self.queue, ^{
        if (self.running) {
            return;
        }
        self.running = YES;
        [self loadHeader];
    });
}

- (void)stop {
    dispatch_async(self.queue, ^{
        if (!self.running) {
            return;
        }
        self.running = NO;
        [self.session invalidateAndCancel];
        NSLog(@"%@ gestoppt: %lu Läufe, %lu Anfragen, %.1f MB geladen (Datei %.1f MB), Dekodieren %.2f s", kMP4LogPrefix,
              (unsigned long)self.batches, (unsigned long)self.requests, self.fetchedBytes / 1048576.0,
              self.fileLength / 1048576.0, self.decodeSeconds);
    });
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
    NSLog(@"%@ %@", kMP4LogPrefix, reason);
    [self.delegate audioSource:self didFailWithReason:reason];
}

#pragma mark Netz (auf self.queue)

- (NSMutableURLRequest *)requestForRange:(NSRange)range {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.URL];
    [self.requestHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        if ([key caseInsensitiveCompare:@"Range"] != NSOrderedSame) {
            [request setValue:value forHTTPHeaderField:key];
        }
    }];
    NSString *host = self.URL.host.lowercaseString ?: @"";
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
    [request setValue:[NSString stringWithFormat:@"bytes=%lu-%lu", (unsigned long)range.location, (unsigned long)(NSMaxRange(range) - 1)]
   forHTTPHeaderField:@"Range"];
    // Kein gzip: sonst passen Byte-Bereiche nicht.
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    return request;
}

- (void)fetchRange:(NSRange)range completion:(void (^)(NSData * _Nullable data, uint64_t totalLength, NSString * _Nullable error))completion {
    if (!self.running) {
        completion(nil, 0, @"gestoppt");  // Session ist dann invalidiert
        return;
    }
    BrowserMP4Fetch *fetch = [BrowserMP4Fetch new];
    fetch.range = range;
    fetch.data = [NSMutableData dataWithCapacity:MIN(range.length, (NSUInteger)4 * 1024 * 1024)];
    __weak typeof(self) weakSelf = self;
    fetch.completion = ^(NSData *data, uint64_t totalLength, NSString *error) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf != nil) {
            strongSelf.requests++;
            strongSelf.fetchedBytes += data.length;
        }
        completion(data, totalLength, error);
    };
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:[self requestForRange:range]];
    self.sessionDelegate.fetches[@(task.taskIdentifier)] = fetch;
    [task resume];
}

#pragma mark Kopf und moov

- (void)loadHeader {
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    [self fetchRange:NSMakeRange(0, kMP4InitialFetch) completion:^(NSData *data, uint64_t totalLength, NSString *error) {
        if (!self.running) {
            return;
        }
        if (data == nil) {
            [self failWithReason:[NSString stringWithFormat:BLS(@"Kopf nicht ladbar (%@)"), error ?: @"?"]];
            return;
        }
        self.fileLength = totalLength > 0 ? totalLength : data.length;
        [self findMoovInData:data atOffset:0 attempt:0 begin:begin];
    }];
}

/// Sucht das moov-Atom in den Top-Level-Boxen. `data` beginnt bei `offset` in der Datei, ist dort Boxanfang.
- (void)findMoovInData:(NSData *)data atOffset:(uint64_t)offset attempt:(NSUInteger)attempt begin:(CFAbsoluteTime)begin {
    const uint8_t *bytes = data.bytes;
    size_t cursor = 0;
    while (cursor + 8 <= data.length) {
        uint64_t size = BrowserMP4U32(bytes + cursor);
        uint32_t type = BrowserMP4U32(bytes + cursor + 4);
        size_t header = 8;
        if (size == 1) {
            if (cursor + 16 > data.length) {
                break;
            }
            size = BrowserMP4U64(bytes + cursor + 8);
            header = 16;
        } else if (size == 0) {
            size = self.fileLength - (offset + cursor);
        }
        if (size < header) {
            [self failWithReason:[NSString stringWithFormat:BLS(@"Kein MP4 (Box %@ mit Größe %llu)"), BrowserMP4TypeName(type), size]];
            return;
        }
        uint64_t boxOffset = offset + cursor;
        if (type == BrowserMP4Type('m', 'o', 'o', 'f')) {
            [self failWithReason:BLS(@"fragmentierte MP4 (moof) wird nicht unterstützt")];
            return;
        }
        if (type == BrowserMP4Type('m', 'o', 'o', 'v')) {
            if (size > kMP4MaxMoovSize) {
                [self failWithReason:[NSString stringWithFormat:BLS(@"moov zu groß (%.1f MB)"), size / 1048576.0]];
                return;
            }
            if (cursor + size <= data.length) {
                [self parseMoov:[data subdataWithRange:NSMakeRange(cursor, (NSUInteger)size)] offset:boxOffset begin:begin];
                return;
            }
            [self fetchRange:NSMakeRange((NSUInteger)boxOffset, (NSUInteger)size) completion:^(NSData *moov, uint64_t total, NSString *error) {
                if (!self.running) {
                    return;
                }
                if (moov.length != size) {
                    [self failWithReason:[NSString stringWithFormat:BLS(@"moov nicht ladbar (%@)"), error ?: BLS(@"zu kurz")]];
                    return;
                }
                [self parseMoov:moov offset:boxOffset begin:begin];
            }];
            return;
        }
        if (attempt == 0 && cursor == 0 && type != BrowserMP4Type('f', 't', 'y', 'p') && type != BrowserMP4Type('w', 'i', 'd', 'e') &&
            type != BrowserMP4Type('f', 'r', 'e', 'e') && type != BrowserMP4Type('m', 'd', 'a', 't') &&
            type != BrowserMP4Type('s', 'k', 'i', 'p') && type != BrowserMP4Type('p', 'n', 'o', 't')) {
            [self failWithReason:[NSString stringWithFormat:BLS(@"Kein MP4/MOV (erste Box %@)"), BrowserMP4TypeName(type)]];
            return;
        }
        if (cursor + size > data.length) {
            // Box reicht über das Geladene hinaus (meist mdat): Kopf der nächsten Box nachladen.
            uint64_t next = boxOffset + size;
            if (next + 8 > self.fileLength || attempt >= 8) {
                [self failWithReason:BLS(@"kein moov gefunden")];
                return;
            }
            NSUInteger length = (NSUInteger)MIN((uint64_t)64 * 1024, self.fileLength - next);
            [self fetchRange:NSMakeRange((NSUInteger)next, length) completion:^(NSData *more, uint64_t total, NSString *error) {
                if (!self.running) {
                    return;
                }
                if (more.length < 8) {
                    [self failWithReason:[NSString stringWithFormat:BLS(@"Box bei %llu nicht ladbar (%@)"), next, error ?: BLS(@"zu kurz")]];
                    return;
                }
                [self findMoovInData:more atOffset:next attempt:attempt + 1 begin:begin];
            }];
            return;
        }
        cursor += (size_t)size;
    }
    [self failWithReason:BLS(@"kein moov gefunden")];
}

- (void)parseMoov:(NSData *)moov offset:(uint64_t)moovOffset begin:(CFAbsoluteTime)begin {
    const uint8_t *bytes = moov.bytes;
    size_t end = moov.length;
    BrowserMP4Box root;
    size_t cursor = 0;
    if (!BrowserMP4NextBox(bytes, end, &cursor, &root)) {
        [self failWithReason:BLS(@"moov kaputt")];
        return;
    }
    uint32_t movieTimescale = 1000;
    BrowserMP4Box mvhd;
    if (BrowserMP4FindChild(bytes, root.payload, root.end, BrowserMP4Type('m', 'v', 'h', 'd'), &mvhd) && mvhd.payload + 24 <= mvhd.end) {
        movieTimescale = bytes[mvhd.payload] == 1 ? BrowserMP4U32(bytes + mvhd.payload + 20) : BrowserMP4U32(bytes + mvhd.payload + 12);
    }
    size_t trakCursor = root.payload;
    BrowserMP4Box trak;
    NSUInteger audioTracks = 0;
    NSString *problem = BLS(@"keine Audiospur");
    while (BrowserMP4NextBox(bytes, root.end, &trakCursor, &trak)) {
        if (trak.type != BrowserMP4Type('t', 'r', 'a', 'k')) {
            continue;
        }
        BrowserMP4Box mdia, hdlr, mdhd, minf, stbl;
        if (!BrowserMP4FindChild(bytes, trak.payload, trak.end, BrowserMP4Type('m', 'd', 'i', 'a'), &mdia) ||
            !BrowserMP4FindChild(bytes, mdia.payload, mdia.end, BrowserMP4Type('h', 'd', 'l', 'r'), &hdlr) ||
            hdlr.payload + 12 > hdlr.end || BrowserMP4U32(bytes + hdlr.payload + 8) != BrowserMP4Type('s', 'o', 'u', 'n')) {
            continue;
        }
        audioTracks++;
        if (audioTracks > 1) {
            continue;  // nur die erste Audiospur (wie AVPlayer ohne Auswahl)
        }
        if (!BrowserMP4FindChild(bytes, mdia.payload, mdia.end, BrowserMP4Type('m', 'd', 'h', 'd'), &mdhd) ||
            !BrowserMP4FindChild(bytes, mdia.payload, mdia.end, BrowserMP4Type('m', 'i', 'n', 'f'), &minf) ||
            !BrowserMP4FindChild(bytes, minf.payload, minf.end, BrowserMP4Type('s', 't', 'b', 'l'), &stbl)) {
            problem = BLS(@"Audiospur ohne Tabellen");
            continue;
        }
        self.timescale = bytes[mdhd.payload] == 1 ? BrowserMP4U32(bytes + mdhd.payload + 20) : BrowserMP4U32(bytes + mdhd.payload + 12);
        if (self.timescale == 0) {
            problem = BLS(@"Zeitskala 0");
            continue;
        }
        [self parseEditListInTrak:trak bytes:bytes movieTimescale:movieTimescale];
        NSString *tableProblem = [self parseSampleTable:stbl bytes:bytes];
        if (tableProblem != nil) {
            problem = tableProblem;
            continue;
        }
        problem = nil;
    }
    if (problem != nil) {
        [self failWithReason:problem];
        return;
    }
    NSString *converterProblem = [self createConverter];
    if (converterProblem != nil) {
        [self failWithReason:converterProblem];
        return;
    }
    double duration = _packetCount > 0 ? [self presentationTimeOfPacket:_packetCount - 1] : 0.0;
    NSLog(@"%@ moov @ %llu (%.0f KB), Datei %.1f MB, Audiospur %@ %.0f Hz %u ch, %lu Pakete, %.1f s, elst %lld/%u (+%.3f s leer), %lu Audiospuren, bereit in %.2f s",
          kMP4LogPrefix, moovOffset, moov.length / 1024.0, self.fileLength / 1048576.0, self.codecName,
          self.inputFormat.mSampleRate, (unsigned)self.inputFormat.mChannelsPerFrame, (unsigned long)_packetCount, duration,
          self.mediaTimeOffset, self.timescale, self.presentationShift, (unsigned long)audioTracks, CFAbsoluteTimeGetCurrent() - begin);
    self.ready = YES;
    [self tick];
}

- (void)parseEditListInTrak:(BrowserMP4Box)trak bytes:(const uint8_t *)bytes movieTimescale:(uint32_t)movieTimescale {
    self.mediaTimeOffset = 0;
    self.presentationShift = 0.0;
    BrowserMP4Box edts, elst;
    if (!BrowserMP4FindChild(bytes, trak.payload, trak.end, BrowserMP4Type('e', 'd', 't', 's'), &edts) ||
        !BrowserMP4FindChild(bytes, edts.payload, edts.end, BrowserMP4Type('e', 'l', 's', 't'), &elst) || elst.payload + 8 > elst.end) {
        return;
    }
    BOOL version1 = bytes[elst.payload] == 1;
    uint32_t count = BrowserMP4U32(bytes + elst.payload + 4);
    size_t entrySize = version1 ? 20 : 12;
    size_t p = elst.payload + 8;
    for (uint32_t i = 0; i < count && p + entrySize <= elst.end; i++, p += entrySize) {
        int64_t segmentDuration = version1 ? (int64_t)BrowserMP4U64(bytes + p) : (int64_t)BrowserMP4U32(bytes + p);
        int64_t mediaTime = version1 ? (int64_t)BrowserMP4U64(bytes + p + 8) : (int64_t)(int32_t)BrowserMP4U32(bytes + p + 4);
        if (mediaTime == -1) {
            // Leeres Edit: Spur beginnt später.
            self.presentationShift += movieTimescale > 0 ? (double)segmentDuration / movieTimescale : 0.0;
            continue;
        }
        self.mediaTimeOffset = mediaTime;
        break;  // weitere Edits (Schnitte) werden nicht unterstützt; sind bei Web-Videos unüblich
    }
}

- (NSString *)parseSampleTable:(BrowserMP4Box)stbl bytes:(const uint8_t *)bytes {
    BrowserMP4Box stsd, stts, stsc, stsz, stco;
    BOOL co64 = NO;
    if (!BrowserMP4FindChild(bytes, stbl.payload, stbl.end, BrowserMP4Type('s', 't', 's', 'd'), &stsd) ||
        !BrowserMP4FindChild(bytes, stbl.payload, stbl.end, BrowserMP4Type('s', 't', 't', 's'), &stts) ||
        !BrowserMP4FindChild(bytes, stbl.payload, stbl.end, BrowserMP4Type('s', 't', 's', 'c'), &stsc)) {
        return BLS(@"Audiospur ohne stsd/stts/stsc");
    }
    if (!BrowserMP4FindChild(bytes, stbl.payload, stbl.end, BrowserMP4Type('s', 't', 's', 'z'), &stsz)) {
        return BLS(@"Audiospur ohne stsz (stz2 nicht unterstützt)");
    }
    if (!BrowserMP4FindChild(bytes, stbl.payload, stbl.end, BrowserMP4Type('s', 't', 'c', 'o'), &stco)) {
        if (!BrowserMP4FindChild(bytes, stbl.payload, stbl.end, BrowserMP4Type('c', 'o', '6', '4'), &stco)) {
            return BLS(@"Audiospur ohne stco/co64");
        }
        co64 = YES;
    }
    NSString *formatProblem = [self parseSampleDescription:stsd bytes:bytes];
    if (formatProblem != nil) {
        return formatProblem;
    }
    if (stsz.payload + 12 > stsz.end || stts.payload + 8 > stts.end || stsc.payload + 8 > stsc.end || stco.payload + 8 > stco.end) {
        return BLS(@"Tabellen zu kurz");
    }
    uint32_t constantSize = BrowserMP4U32(bytes + stsz.payload + 4);
    uint32_t sampleCount = BrowserMP4U32(bytes + stsz.payload + 8);
    if (sampleCount == 0) {
        return BLS(@"Audiospur ohne Pakete (fragmentiert?)");
    }
    if (constantSize == 0 && stsz.payload + 12 + (size_t)sampleCount * 4 > stsz.end) {
        return @"stsz zu kurz";
    }
    uint32_t chunkCount = BrowserMP4U32(bytes + stco.payload + 4);
    if (stco.payload + 8 + (size_t)chunkCount * (co64 ? 8 : 4) > stco.end) {
        return @"stco zu kurz";
    }
    uint32_t stscCount = BrowserMP4U32(bytes + stsc.payload + 4);
    if (stsc.payload + 8 + (size_t)stscCount * 12 > stsc.end || stscCount == 0) {
        return @"stsc kaputt";
    }
    free(_packetOffsets);
    free(_packetSizes);
    free(_packetTimes);
    _packetOffsets = calloc(sampleCount, sizeof(uint64_t));
    _packetSizes = calloc(sampleCount, sizeof(uint32_t));
    _packetTimes = calloc(sampleCount, sizeof(int64_t));
    if (_packetOffsets == NULL || _packetSizes == NULL || _packetTimes == NULL) {
        return BLS(@"kein Speicher für die Pakettabelle");
    }
    // Größen
    for (uint32_t i = 0; i < sampleCount; i++) {
        _packetSizes[i] = constantSize != 0 ? constantSize : BrowserMP4U32(bytes + stsz.payload + 12 + (size_t)i * 4);
    }
    // Versätze über Chunks
    NSUInteger sample = 0;
    const uint8_t *stscEntries = bytes + stsc.payload + 8;
    for (uint32_t entry = 0; entry < stscCount && sample < sampleCount; entry++) {
        uint32_t firstChunk = BrowserMP4U32(stscEntries + entry * 12);
        uint32_t perChunk = BrowserMP4U32(stscEntries + entry * 12 + 4);
        uint32_t lastChunk = entry + 1 < stscCount ? BrowserMP4U32(stscEntries + (entry + 1) * 12) - 1 : chunkCount;
        for (uint32_t chunk = firstChunk; chunk <= lastChunk && chunk >= 1 && chunk <= chunkCount && sample < sampleCount; chunk++) {
            uint64_t offset = co64 ? BrowserMP4U64(bytes + stco.payload + 8 + (size_t)(chunk - 1) * 8)
                                   : BrowserMP4U32(bytes + stco.payload + 8 + (size_t)(chunk - 1) * 4);
            for (uint32_t k = 0; k < perChunk && sample < sampleCount; k++) {
                _packetOffsets[sample] = offset;
                offset += _packetSizes[sample];
                sample++;
            }
        }
    }
    if (sample < sampleCount) {
        NSLog(@"%@ stsc deckt nur %lu von %u Paketen ab", kMP4LogPrefix, (unsigned long)sample, sampleCount);
        sampleCount = (uint32_t)sample;
    }
    // Zeiten
    uint32_t sttsCount = BrowserMP4U32(bytes + stts.payload + 4);
    if (stts.payload + 8 + (size_t)sttsCount * 8 > stts.end) {
        return @"stts zu kurz";
    }
    int64_t time = 0;
    NSUInteger index = 0;
    for (uint32_t entry = 0; entry < sttsCount && index < sampleCount; entry++) {
        uint32_t count = BrowserMP4U32(bytes + stts.payload + 8 + entry * 8);
        uint32_t delta = BrowserMP4U32(bytes + stts.payload + 12 + entry * 8);
        for (uint32_t k = 0; k < count && index < sampleCount; k++) {
            _packetTimes[index++] = time;
            time += delta;
        }
    }
    while (index < sampleCount) {
        _packetTimes[index++] = time;  // stts kürzer als stsz: letzte Zeit fortschreiben
    }
    _packetCount = sampleCount;
    return nil;
}

- (NSString *)parseSampleDescription:(BrowserMP4Box)stsd bytes:(const uint8_t *)bytes {
    size_t cursor = stsd.payload + 8;
    BrowserMP4Box entry;
    if (!BrowserMP4NextBox(bytes, stsd.end, &cursor, &entry) || entry.payload + 28 > entry.end) {
        return @"stsd ohne Eintrag";
    }
    const uint8_t *p = bytes + entry.payload;
    uint16_t version = BrowserMP4U16(p + 8);
    uint16_t channels = BrowserMP4U16(p + 16);
    double sampleRate = BrowserMP4U32(p + 24) / 65536.0;
    size_t children = entry.payload + 28;
    if (version == 1) {
        children += 16;
    } else if (version == 2) {
        if (entry.payload + 28 + 36 <= entry.end) {
            uint64_t bits = BrowserMP4U64(p + 32);
            double rate = 0.0;
            memcpy(&rate, &bits, sizeof(rate));
            sampleRate = rate;
            channels = (uint16_t)BrowserMP4U32(p + 40);
        }
        children += 36;
    }
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = sampleRate > 0.0 ? sampleRate : 48000.0;
    format.mChannelsPerFrame = MAX(1u, (UInt32)channels);
    self.magicCookie = nil;
    switch (entry.type) {
        case BrowserMP4Type('m', 'p', '4', 'a'): {
            BrowserMP4Box esds, wave;
            BOOL found = BrowserMP4FindChild(bytes, children, entry.end, BrowserMP4Type('e', 's', 'd', 's'), &esds);
            if (!found && BrowserMP4FindChild(bytes, children, entry.end, BrowserMP4Type('w', 'a', 'v', 'e'), &wave)) {
                found = BrowserMP4FindChild(bytes, wave.payload, wave.end, BrowserMP4Type('e', 's', 'd', 's'), &esds);  // QuickTime .mov
            }
            if (!found || esds.payload + 4 >= esds.end) {
                return @"mp4a ohne esds";
            }
            NSData *descriptor = [NSData dataWithBytes:bytes + esds.payload + 4 length:esds.end - esds.payload - 4];
            uint8_t objectType = 0;
            NSData *config = nil;
            if (!BrowserMP4ParseESDescriptor(descriptor, &objectType, &config)) {
                return @"esds nicht lesbar";
            }
            if (objectType == 0x69 || objectType == 0x6B) {
                format.mFormatID = kAudioFormatMPEGLayer3;
                format.mFramesPerPacket = 1152;
                self.codecName = @"MP3";
                break;
            }
            if (objectType != 0x40 && objectType != 0x66 && objectType != 0x67 && objectType != 0x68) {
                return [NSString stringWithFormat:BLS(@"Audioformat 0x%02X nicht unterstützt"), objectType];
            }
            self.magicCookie = descriptor;
            format.mFormatID = kAudioFormatMPEG4AAC;
            format.mFramesPerPacket = 1024;
            if (![self fillAACFormat:&format cookie:descriptor config:config]) {
                return BLS(@"AAC-Konfiguration nicht lesbar");
            }
            break;
        }
        case BrowserMP4Type('a', 'c', '-', '3'):
            format.mFormatID = kAudioFormatAC3;
            format.mFramesPerPacket = 1536;
            self.codecName = @"AC-3";
            break;
        case BrowserMP4Type('e', 'c', '-', '3'):
            format.mFormatID = kAudioFormatEnhancedAC3;
            format.mFramesPerPacket = 1536;
            self.codecName = @"E-AC-3";
            break;
        case BrowserMP4Type('.', 'm', 'p', '3'):
            format.mFormatID = kAudioFormatMPEGLayer3;
            format.mFramesPerPacket = 1152;
            self.codecName = @"MP3";
            break;
        case BrowserMP4Type('e', 'n', 'c', 'a'):
            return BLS(@"Audiospur verschlüsselt");
        default:
            return [NSString stringWithFormat:BLS(@"Audioformat %@ nicht unterstützt"), BrowserMP4TypeName(entry.type)];
    }
    self.inputFormat = format;
    return nil;
}

/// AAC-Format aus dem Cookie (inkl. HE-AAC-Schichten), sonst aus der AudioSpecificConfig.
- (BOOL)fillAACFormat:(AudioStreamBasicDescription *)format cookie:(NSData *)cookie config:(NSData *)config {
    AudioFormatInfo info = {0};
    info.mASBD.mFormatID = kAudioFormatMPEG4AAC;
    info.mMagicCookie = cookie.bytes;
    info.mMagicCookieSize = (UInt32)cookie.length;
    UInt32 size = 0;
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, sizeof(info), &info, &size) == noErr && size >= sizeof(AudioFormatListItem)) {
        AudioFormatListItem *items = malloc(size);
        if (items != NULL && AudioFormatGetProperty(kAudioFormatProperty_FormatList, sizeof(info), &info, &size, items) == noErr) {
            *format = items[0].mASBD;  // höchste Schicht (HE-AAC v2 → HE-AAC → LC)
            free(items);
            self.codecName = format->mFormatID == kAudioFormatMPEG4AAC_HE ? @"HE-AAC"
                           : (format->mFormatID == kAudioFormatMPEG4AAC_HE_V2 ? @"HE-AACv2" : @"AAC");
            return format->mSampleRate > 0.0;
        }
        free(items);
    }
    AudioStreamBasicDescription fromCookie = {0};
    fromCookie.mFormatID = kAudioFormatMPEG4AAC;
    size = sizeof(fromCookie);
    if (AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, (UInt32)cookie.length, cookie.bytes, &size, &fromCookie) == noErr &&
        fromCookie.mSampleRate > 0.0) {
        *format = fromCookie;
        self.codecName = @"AAC";
        return YES;
    }
    if (config.length >= 2) {
        static const double rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};
        const uint8_t *c = config.bytes;
        uint8_t objectType = c[0] >> 3;
        uint8_t frequencyIndex = (uint8_t)(((c[0] & 0x07) << 1) | (c[1] >> 7));
        uint8_t channelConfig = (c[1] >> 3) & 0x0F;
        if (frequencyIndex < 13) {
            format->mSampleRate = rates[frequencyIndex];
        }
        format->mFormatFlags = objectType;
        if (channelConfig > 0 && channelConfig < 8) {
            format->mChannelsPerFrame = channelConfig == 7 ? 8 : channelConfig;
        }
        self.codecName = @"AAC";
        return YES;
    }
    return NO;
}

- (NSString *)createConverter {
    AudioStreamBasicDescription input = self.inputFormat;
    _channels = MAX(1u, input.mChannelsPerFrame);
    AudioStreamBasicDescription output = {0};
    output.mSampleRate = 16000.0;
    output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    output.mBitsPerChannel = 32;
    output.mChannelsPerFrame = _channels;
    output.mFramesPerPacket = 1;
    output.mBytesPerFrame = 4 * _channels;
    output.mBytesPerPacket = 4 * _channels;
    OSStatus status = AudioConverterNew(&input, &output, &_converter);
    if (status != noErr || _converter == NULL) {
        return [NSString stringWithFormat:BLS(@"Dekoder %@ nicht verfügbar (%d)"), self.codecName, (int)status];
    }
    if (self.magicCookie.length > 0) {
        status = AudioConverterSetProperty(_converter, kAudioConverterDecompressionMagicCookie,
                                           (UInt32)self.magicCookie.length, self.magicCookie.bytes);
        if (status != noErr) {
            NSLog(@"%@ Cookie nicht angenommen (%d), dekodiere ohne", kMP4LogPrefix, (int)status);
        }
    }
    return nil;
}

#pragma mark Planung (auf self.queue)

- (double)presentationTimeOfPacket:(NSUInteger)index {
    return (double)(_packetTimes[index] - self.mediaTimeOffset) / (double)self.timescale + self.presentationShift;
}

/// Erstes Paket, dessen Ende nach `time` liegt.
- (NSUInteger)packetIndexAtTime:(double)time {
    NSUInteger low = 0, high = _packetCount;
    while (low < high) {
        NSUInteger mid = (low + high) / 2;
        double end = mid + 1 < _packetCount ? [self presentationTimeOfPacket:mid + 1] : INFINITY;
        if (end <= time) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

- (void)restartRunAtTime:(double)time {
    NSUInteger index = [self packetIndexAtTime:MAX(0.0, time)];
    index = index >= 2 ? index - 2 : 0;  // zwei Pakete Vorlauf für den Dekoder (Überlappung der Frames)
    self.nextPacket = index;
    self.runStartTime = index < _packetCount ? [self presentationTimeOfPacket:index] : time;
    self.runSamples = 0;
    self.pendingDiscontinuity = YES;
    self.firstBatchOfRun = YES;
    if (_converter != NULL) {
        AudioConverterReset(_converter);
    }
}

- (void)tick {
    if (!self.running || !self.ready || self.busy || self.failed || _packetCount == 0) {
        return;
    }
    double time = atomic_load(&_playbackTime);
    double nextTime = self.nextPacket < _packetCount ? [self presentationTimeOfPacket:self.nextPacket] : INFINITY;
    if (self.nextPacket == NSNotFound || time < self.runStartTime - 0.5 || (self.nextPacket < _packetCount && time > nextTime + 3.0)) {
        if (self.nextPacket != NSNotFound) {
            NSLog(@"%@ Sprung auf %.1f s", kMP4LogPrefix, time);
        }
        [self restartRunAtTime:time];
    }
    id<BrowserSubtitleAudioSourceDelegate> delegate = self.delegate;
    // Schon ausgewertete Stellen (Zurückspulen) überspringen.
    if ([delegate respondsToSelector:@selector(audioSource:isRangeCoveredFrom:to:)]) {
        BOOL skipped = NO;
        while (self.nextPacket < _packetCount) {
            double start = [self presentationTimeOfPacket:self.nextPacket];
            NSUInteger end = [self packetIndexAtTime:start + 2.0];
            if (end <= self.nextPacket || ![delegate audioSource:self isRangeCoveredFrom:start to:start + 2.0]) {
                break;
            }
            self.nextPacket = end;
            skipped = YES;
        }
        if (skipped && self.nextPacket < _packetCount) {
            NSUInteger index = self.nextPacket >= 2 ? self.nextPacket - 2 : 0;
            self.nextPacket = index;
            self.runStartTime = [self presentationTimeOfPacket:index];
            self.runSamples = 0;
            self.pendingDiscontinuity = YES;
            if (_converter != NULL) {
                AudioConverterReset(_converter);
            }
        }
    }
    if (self.nextPacket >= _packetCount) {
        return;
    }
    double start = [self presentationTimeOfPacket:self.nextPacket];
    if (start > time + self.lookahead) {
        return;
    }
    if ([delegate respondsToSelector:@selector(audioSourcePendingSeconds:)] && [delegate audioSourcePendingSeconds:self] > self.maxPending) {
        return;
    }
    double batchSeconds = self.firstBatchOfRun ? kMP4FirstBatchSeconds : kMP4BatchSeconds;
    NSUInteger first = self.nextPacket;
    NSUInteger last = MIN(_packetCount, MAX(first + 1, [self packetIndexAtTime:start + batchSeconds]));
    [self loadAndDecodePacketsFrom:first to:last];
}

/// Byte-Bereiche für die Pakete [first, last). Audio liegt verschachtelt zwischen Videodaten: Jede Lücke ist entweder
/// eine eigene Anfrage oder wird mitgeladen. Höchstens ≈ 1,5 Anfragen je Sekunde Ton; getrennt wird an den größten
/// Lücken (bei Dateien mit 0,5–1-s-Verschachtelung also fast nur Ton, bei Verschachtelung je Videobild wie der
/// tagesschau lädt das den Großteil der Datei mit, ≈ Videobitrate).
- (NSArray<NSValue *> *)byteRunsForPacketsFrom:(NSUInteger)first to:(NSUInteger)last {
    NSMutableArray<NSValue *> *exact = [NSMutableArray array];
    NSMutableArray<NSNumber *> *gaps = [NSMutableArray array];      // Lücke vor exact[i + 1]; −1 = rückwärts (immer trennen)
    uint64_t runStart = _packetOffsets[first];
    uint64_t runEnd = runStart + _packetSizes[first];
    for (NSUInteger i = first + 1; i < last; i++) {
        uint64_t offset = _packetOffsets[i];
        if (offset == runEnd) {
            runEnd += _packetSizes[i];
            continue;
        }
        [exact addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)runStart, (NSUInteger)(runEnd - runStart))]];
        [gaps addObject:@(offset > runEnd ? (long long)(offset - runEnd) : -1LL)];
        runStart = offset;
        runEnd = offset + _packetSizes[i];
    }
    [exact addObject:[NSValue valueWithRange:NSMakeRange((NSUInteger)runStart, (NSUInteger)(runEnd - runStart))]];
    double seconds = [self presentationTimeOfPacket:last - 1] - [self presentationTimeOfPacket:first];
    NSUInteger budget = (NSUInteger)MAX(4.0, ceil(seconds * 1.5));
    NSMutableIndexSet *splits = [NSMutableIndexSet indexSet];
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    for (NSUInteger i = 0; i < gaps.count; i++) {
        long long gap = gaps[i].longLongValue;
        if (gap < 0) {
            [splits addIndex:i];
        } else if ((uint64_t)gap >= kMP4MergeGap) {
            [candidates addObject:@(i)];
        }
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [gaps[b.unsignedIntegerValue] compare:gaps[a.unsignedIntegerValue]];
    }];
    for (NSNumber *index in candidates) {
        if (splits.count + 1 >= budget) {
            break;
        }
        [splits addIndex:index.unsignedIntegerValue];
    }
    NSMutableArray<NSValue *> *runs = [NSMutableArray array];
    NSRange current = exact[0].rangeValue;
    for (NSUInteger i = 0; i < gaps.count; i++) {
        NSRange next = exact[i + 1].rangeValue;
        if ([splits containsIndex:i]) {
            [runs addObject:[NSValue valueWithRange:current]];
            current = next;
        } else {
            current.length = NSMaxRange(next) - current.location;
        }
    }
    [runs addObject:[NSValue valueWithRange:current]];
    // Spart das Aufteilen wenig (Ton je Videobild verschachtelt), lieber eine Anfrage: viele parallele Range-Anfragen
    // beantworten manche CDNs mit HTTP 429 (download.blender.org).
    uint64_t splitBytes = 0;
    for (NSValue *value in runs) {
        splitBytes += value.rangeValue.length;
    }
    BOOL backwards = NO;
    for (NSNumber *gap in gaps) {
        backwards = backwards || gap.longLongValue < 0;
    }
    if (backwards || runs.count < 2) {
        return runs;
    }
    NSRange span = NSMakeRange(exact.firstObject.rangeValue.location, NSMaxRange(exact.lastObject.rangeValue) - exact.firstObject.rangeValue.location);
    if (splitBytes * 2 > span.length) {
        return @[[NSValue valueWithRange:span]];
    }
    return runs;
}

- (void)loadAndDecodePacketsFrom:(NSUInteger)first to:(NSUInteger)last {
    self.busy = YES;
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    NSArray<NSValue *> *runs = [self byteRunsForPacketsFrom:first to:last];

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:runs.count];
    for (NSUInteger i = 0; i < runs.count; i++) {
        [results addObject:NSNull.null];
    }
    __block NSUInteger remaining = runs.count;
    __block NSString *firstError = nil;
    NSUInteger generation = self.batches;
    for (NSUInteger r = 0; r < runs.count; r++) {
        NSRange range = runs[r].rangeValue;
        [self fetchRange:range completion:^(NSData *data, uint64_t total, NSString *error) {
            if (data.length == range.length) {
                results[r] = data;
            } else if (firstError == nil) {
                firstError = error ?: BLS(@"zu kurz");
            }
            if (--remaining > 0) {
                return;
            }
            if (!self.running || self.batches != generation) {
                return;
            }
            self.batches++;
            if (firstError != nil) {
                if (self.retries < 3) {
                    // z. B. HTTP 429/503 oder Zeitüberschreitung: kurz warten, dann denselben Lauf noch einmal.
                    self.retries++;
                    NSLog(@"%@ Lauf bei Paket %lu fehlgeschlagen (%@), neuer Versuch %lu", kMP4LogPrefix, (unsigned long)first,
                          firstError, (unsigned long)self.retries);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * self.retries * NSEC_PER_SEC)), self.queue, ^{
                        self.busy = NO;
                        [self tick];
                    });
                    return;
                }
                self.busy = NO;
                [self failWithReason:[NSString stringWithFormat:BLS(@"Audiodaten nicht ladbar (%@)"), firstError]];
                return;
            }
            self.retries = 0;
            double loadSeconds = CFAbsoluteTimeGetCurrent() - begin;
            [self decodePacketsFrom:first to:last runs:runs data:results loadSeconds:loadSeconds];
            self.busy = NO;
            [self tick];
        }];
    }
}

- (void)decodePacketsFrom:(NSUInteger)first to:(NSUInteger)last runs:(NSArray<NSValue *> *)runs data:(NSArray<NSData *> *)data loadSeconds:(double)loadSeconds {
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    NSUInteger count = last - first;
    // Pakete in einen Puffer kopieren.
    uint64_t total = 0;
    for (NSUInteger i = first; i < last; i++) {
        total += _packetSizes[i];
    }
    NSMutableData *packets = [NSMutableData dataWithLength:(NSUInteger)total];
    size_t *offsets = calloc(count, sizeof(size_t));
    uint8_t *destination = packets.mutableBytes;
    size_t position = 0;
    NSUInteger run = 0;
    for (NSUInteger i = first; i < last; i++) {
        uint64_t offset = _packetOffsets[i];
        while (run < runs.count && offset >= NSMaxRange(runs[run].rangeValue)) {
            run++;
        }
        if (run >= runs.count) {
            break;
        }
        NSRange range = runs[run].rangeValue;
        memcpy(destination + position, (const uint8_t *)data[run].bytes + (offset - range.location), _packetSizes[i]);
        offsets[i - first] = position;
        position += _packetSizes[i];
    }
    BrowserMP4DecodeInput input = {0};
    input.data = packets.bytes;
    input.sizes = _packetSizes + first;
    input.offsets = offsets;
    input.count = (UInt32)count;
    input.endOfStream = last >= _packetCount;

    const UInt32 chunkFrames = 4096;
    float *buffer = malloc(chunkFrames * _channels * sizeof(float));
    NSMutableData *mono = [NSMutableData dataWithCapacity:(NSUInteger)((([self presentationTimeOfPacket:last - 1] - [self presentationTimeOfPacket:first]) + 1.0) * 16000.0 * sizeof(float))];
    OSStatus status = noErr;
    while (YES) {
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = _channels;
        list.mBuffers[0].mDataByteSize = chunkFrames * _channels * sizeof(float);
        list.mBuffers[0].mData = buffer;
        UInt32 frames = chunkFrames;
        status = AudioConverterFillComplexBuffer(_converter, BrowserMP4InputProc, &input, &frames, &list, NULL);
        if (frames > 0) {
            NSUInteger start = mono.length;
            mono.length += frames * sizeof(float);
            float *out = (float *)((uint8_t *)mono.mutableBytes + start);
            float scale = 1.0f / (float)_channels;
            for (UInt32 f = 0; f < frames; f++) {
                float sum = 0.0f;
                for (UInt32 c = 0; c < _channels; c++) {
                    sum += buffer[f * _channels + c];
                }
                out[f] = sum * scale;
            }
        }
        if (status != noErr || frames == 0) {
            break;
        }
    }
    free(buffer);
    free(offsets);
    double decodeSeconds = CFAbsoluteTimeGetCurrent() - begin;
    self.decodeSeconds += decodeSeconds;
    if (status != noErr && status != kMP4NeedMoreData) {
        NSLog(@"%@ Dekodieren Fehler %d bei Paket %lu", kMP4LogPrefix, (int)status, (unsigned long)first);
        AudioConverterReset(_converter);
        self.pendingDiscontinuity = YES;
    }
    double time = self.runStartTime + (double)self.runSamples / 16000.0;
    NSUInteger produced = mono.length / sizeof(float);
    if (self.batches <= 3 || self.batches % 10 == 0) {
        uint64_t loaded = 0;
        for (NSValue *value in runs) {
            loaded += value.rangeValue.length;
        }
        NSLog(@"%@ Lauf %lu @ %.2f s: %lu Pakete (%.0f KB), %lu Anfragen (%.0f KB) in %.2f s → %.2f s Ton (Dekodieren %.3f s)", kMP4LogPrefix,
              (unsigned long)self.batches, time, (unsigned long)count, total / 1024.0, (unsigned long)runs.count, loaded / 1024.0,
              loadSeconds, produced / 16000.0, decodeSeconds);
    }
    self.nextPacket = last;
    self.firstBatchOfRun = NO;
    if (produced == 0) {
        return;
    }
    self.runSamples += produced;
    BOOL discontinuity = self.pendingDiscontinuity;
    self.pendingDiscontinuity = NO;
    [self.delegate audioSource:self didProduceSamples:mono atTime:time discontinuity:discontinuity];
}

@end
