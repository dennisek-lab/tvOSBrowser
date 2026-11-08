#import "BrowserSubtitleController.h"

#import "BrowserPreferencesStore.h"
#import "BrowserSubtitleAudioTapSource.h"
#import "BrowserSubtitleEngine.h"
#import "BrowserSubtitleHLSAudioSource.h"
#import "BrowserSubtitleOverlayView.h"

static NSString * const kSubtitleControllerLogPrefix = @"[Subtitles]";
static NSString * const kSubtitleMenuIdentifier = @"io.github.tvosbrowser.app.autoSubtitles";
static const double kSampleRate = 16000.0;
static const NSTimeInterval kCoverageUnit = 0.1;   // Raster der Abdeckung (s)

/// Ein Auswertungsabschnitt.
@interface BrowserSubtitleWindow : NSObject
@property (nonatomic, strong) NSData *samples;
@property (nonatomic) NSTimeInterval start;
@property (nonatomic) NSTimeInterval end;
@property (nonatomic) NSTimeInterval acceptFrom;
@property (nonatomic) NSTimeInterval acceptUntil;
@end

@implementation BrowserSubtitleWindow
@end

@interface BrowserSubtitleController () <BrowserSubtitleAudioSourceDelegate>
@property (nonatomic, weak) AVPlayerViewController *playerViewController;
@property (nonatomic, strong) NSURL *playbackURL;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *cookies;
@property (nonatomic, strong) BrowserPreferencesStore *preferences;
@property (nonatomic, strong) BrowserSubtitleOverlayView *overlay;
@property (nonatomic, strong, nullable) id timeObserver;
@property (nonatomic, weak) AVPlayer *observedPlayer;
@property (nonatomic, strong) NSMutableArray<BrowserSubtitleCue *> *cues;  // Hauptthread, nach Start sortiert
@property (nonatomic, strong, nullable) id<BrowserSubtitleAudioSource> source;
@property (nonatomic, strong, nullable) BrowserSubtitleEngine *engine;
@property (nonatomic) BOOL triedHLSFallback;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic) BOOL detached;
@property (nonatomic) NSTimeInterval lastSourceUpdate;
@property (nonatomic) NSTimeInterval lastSummary;
@property (nonatomic) NSTimeInterval lastMenuCheck;
@property (nonatomic) float lastRate;
// Verarbeitung (nur auf processingQueue)
@property (nonatomic, strong) dispatch_queue_t processingQueue;
@property (nonatomic, strong) dispatch_queue_t engineQueue;
@property (nonatomic, weak, nullable) id<BrowserSubtitleAudioSource> processingSource;
@property (nonatomic, strong, nullable) BrowserSubtitleEngine *processingEngine;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic) NSTimeInterval bufferStart;
@property (nonatomic) BOOL hasBuffer;
@property (nonatomic) NSTimeInterval windowSeconds;
@property (nonatomic) NSTimeInterval overlapSeconds;
@property (nonatomic) BOOL dropStaleWindows;
@property (nonatomic, strong) NSMutableArray<BrowserSubtitleWindow *> *pendingWindows;
@property (nonatomic) BOOL engineBusy;
@property (nonatomic, strong) NSMutableIndexSet *covered;
@property (nonatomic) NSUInteger droppedWindows;
@property (nonatomic) NSUInteger processedWindows;
@end

@implementation BrowserSubtitleController

+ (NSString *)menuTitle {
    return @"Automatische Untertitel";
}

+ (NSString *)menuDetailForPreferences:(BrowserPreferencesStore *)preferences {
    return preferences.autoSubtitlesEnabled ? @"An" : @"Aus";
}

+ (instancetype)attachToPlayerViewController:(AVPlayerViewController *)playerViewController
                                 playbackURL:(NSURL *)playbackURL
                              requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                                     cookies:(NSArray<NSHTTPCookie *> *)cookies {
    BrowserSubtitleController *controller = [[self alloc] init];
    controller.playerViewController = playerViewController;
    controller.playbackURL = playbackURL;
    controller.requestHeaders = requestHeaders ?: @{};
    controller.cookies = cookies ?: @[];
    [controller attach];
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _preferences = [BrowserPreferencesStore new];
        _cues = [NSMutableArray array];
        _processingQueue = dispatch_queue_create("io.github.tvosbrowser.app.subtitles.processing", DISPATCH_QUEUE_SERIAL);
        _engineQueue = dispatch_queue_create("io.github.tvosbrowser.app.subtitles.whisper",
                                             dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        _buffer = [NSMutableData data];
        _pendingWindows = [NSMutableArray array];
        _covered = [NSMutableIndexSet indexSet];
    }
    return self;
}

- (void)dealloc {
    [self detach];
}

#pragma mark Einhängen

- (void)attach {
    AVPlayerViewController *playerViewController = self.playerViewController;
    UIView *container = playerViewController.contentOverlayView;
    self.overlay = [[BrowserSubtitleOverlayView alloc] initWithFrame:container.bounds];
    [container addSubview:self.overlay];
    [self installMenu];
    [self observePlayer:playerViewController.player];
    NSLog(@"%@ eingehängt, an=%d, Sprache %@, whisper=%d, Modell %@", kSubtitleControllerLogPrefix,
          self.preferences.autoSubtitlesEnabled, self.preferences.autoSubtitlesLanguage,
          [BrowserSubtitleEngine isCompiledWithWhisper],
          [BrowserSubtitleEngine modelPathForLanguage:self.preferences.autoSubtitlesLanguage].lastPathComponent ?: @"–");
    if (self.preferences.autoSubtitlesEnabled) {
        [self startRecognition];
    }
}

- (void)detach {
    if (self.detached) {
        return;
    }
    self.detached = YES;
    [self stopRecognitionClearing:NO];
    if (self.timeObserver != nil) {
        [self.observedPlayer removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }
    [self.overlay removeFromSuperview];
    AVPlayerViewController *playerViewController = self.playerViewController;
    if (playerViewController != nil) {
        playerViewController.transportBarCustomMenuItems = [self menuItemsWithoutOwn:playerViewController.transportBarCustomMenuItems];
    }
    NSLog(@"%@ ausgehängt, %lu Untertitel, Speicher %.0f MB", kSubtitleControllerLogPrefix,
          (unsigned long)self.cues.count, [BrowserSubtitleEngine currentMemoryFootprintMB]);
}

- (void)observePlayer:(AVPlayer *)player {
    if (player == nil || self.timeObserver != nil) {
        return;
    }
    self.observedPlayer = player;
    __weak typeof(self) weakSelf = self;
    self.timeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC)
                                                             queue:dispatch_get_main_queue()
                                                        usingBlock:^(CMTime time) {
        [weakSelf playerTimeDidChange:time];
    }];
}

#pragma mark Menü im Player

- (NSArray<UIMenuElement *> *)menuItemsWithoutOwn:(NSArray<UIMenuElement *> *)items {
    NSMutableArray<UIMenuElement *> *result = [NSMutableArray array];
    for (UIMenuElement *element in items ?: @[]) {
        if ([element isKindOfClass:UIMenu.class] && [((UIMenu *)element).identifier isEqualToString:kSubtitleMenuIdentifier]) {
            continue;
        }
        [result addObject:element];
    }
    return result;
}

- (BOOL)menuInstalled {
    for (UIMenuElement *element in self.playerViewController.transportBarCustomMenuItems ?: @[]) {
        if ([element isKindOfClass:UIMenu.class] && [((UIMenu *)element).identifier isEqualToString:kSubtitleMenuIdentifier]) {
            return YES;
        }
    }
    return NO;
}

- (UIMenu *)buildMenu {
    __weak typeof(self) weakSelf = self;
    BOOL enabled = self.preferences.autoSubtitlesEnabled;
    UIAction *on = [UIAction actionWithTitle:@"An" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf setEnabledFromMenu:YES];
    }];
    on.state = enabled ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *off = [UIAction actionWithTitle:@"Aus" image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf setEnabledFromMenu:NO];
    }];
    off.state = enabled ? UIMenuElementStateOff : UIMenuElementStateOn;
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObjects:on, off, nil];

    if ([BrowserSubtitleEngine hasMultilingualModel]) {
        NSString *language = self.preferences.autoSubtitlesLanguage;
        UIAction *english = [UIAction actionWithTitle:@"Englisch" image:nil identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf setLanguageFromMenu:@"en"];
        }];
        english.state = [language isEqualToString:@"en"] ? UIMenuElementStateOn : UIMenuElementStateOff;
        UIAction *automatic = [UIAction actionWithTitle:@"Sprache automatisch" image:nil identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf setLanguageFromMenu:@"auto"];
        }];
        automatic.state = [language isEqualToString:@"auto"] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [children addObject:[UIMenu menuWithTitle:@"Sprache" image:nil identifier:nil
                                          options:UIMenuOptionsDisplayInline children:@[english, automatic]]];
    }
    UIImage *image = [UIImage systemImageNamed:enabled ? @"captions.bubble.fill" : @"captions.bubble"];
    return [UIMenu menuWithTitle:[BrowserSubtitleController menuTitle] image:image identifier:kSubtitleMenuIdentifier
                         options:0 children:children];
}

- (void)installMenu {
    AVPlayerViewController *playerViewController = self.playerViewController;
    if (playerViewController == nil || self.detached) {
        return;
    }
    NSMutableArray<UIMenuElement *> *items = [[self menuItemsWithoutOwn:playerViewController.transportBarCustomMenuItems] mutableCopy];
    [items addObject:[self buildMenu]];
    playerViewController.transportBarCustomMenuItems = items;
}

- (void)setEnabledFromMenu:(BOOL)enabled {
    NSLog(@"%@ Menü: %@", kSubtitleControllerLogPrefix, enabled ? @"an" : @"aus");
    self.preferences.autoSubtitlesEnabled = enabled;
    if (enabled) {
        [self startRecognition];
    } else {
        [self stopRecognitionClearing:NO];
        [self.overlay showStatus:@"Automatische Untertitel aus" duration:2.5];
    }
    [self installMenu];
}

- (void)setLanguageFromMenu:(NSString *)language {
    if ([language isEqualToString:self.preferences.autoSubtitlesLanguage]) {
        return;
    }
    NSLog(@"%@ Menü: Sprache %@", kSubtitleControllerLogPrefix, language);
    self.preferences.autoSubtitlesLanguage = language;
    if (self.running) {
        [self stopRecognitionClearing:YES];
        [self startRecognition];
    }
    [self installMenu];
}

#pragma mark Start/Stopp

- (void)startRecognition {
    if (self.running || self.detached) {
        return;
    }
    if (![BrowserSubtitleEngine isCompiledWithWhisper]) {
        [self.overlay showStatus:@"Automatische Untertitel nicht verfügbar (whisper fehlt im Build)" duration:5.0];
        NSLog(@"%@ whisper.xcframework fehlt (tools/build_whisper.sh)", kSubtitleControllerLogPrefix);
        return;
    }
    NSString *language = self.preferences.autoSubtitlesLanguage;
    NSString *modelPath = [BrowserSubtitleEngine modelPathForLanguage:language];
    if (modelPath == nil) {
        [self.overlay showStatus:@"Automatische Untertitel: kein Modell in der App" duration:5.0];
        NSLog(@"%@ kein Modell im Paket (tools/fetch_whisper_model.sh)", kSubtitleControllerLogPrefix);
        return;
    }
    self.running = YES;
    self.triedHLSFallback = NO;
    BrowserSubtitleEngine *engine = [[BrowserSubtitleEngine alloc] initWithModelPath:modelPath language:language];
    self.engine = engine;
    [self.overlay showStatus:@"Automatische Untertitel: Modell wird geladen …" duration:10.0];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.engineQueue, ^{
        NSError *error = nil;
        BOOL loaded = [engine loadModel:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.engine != engine) {
                return;
            }
            if (!loaded) {
                [strongSelf.overlay showStatus:[NSString stringWithFormat:@"Automatische Untertitel: %@", error.localizedDescription ?: @"Fehler"] duration:5.0];
                [strongSelf stopRecognitionClearing:NO];
                return;
            }
            [strongSelf.overlay showStatus:[NSString stringWithFormat:@"Automatische Untertitel an (%@)", engine.modelName] duration:3.0];
            [strongSelf startSourcePreferringHLS:[strongSelf playbackURLLooksLikeHLS]];
        });
    });
}

- (BOOL)playbackURLLooksLikeHLS {
    NSString *string = self.playbackURL.absoluteString.lowercaseString;
    return [string containsString:@".m3u8"] || [string containsString:@"format=m3u8"] || [string containsString:@"/hls/"];
}

- (void)startSourcePreferringHLS:(BOOL)hls {
    AVPlayerItem *item = self.playerViewController.player.currentItem;
    id<BrowserSubtitleAudioSource> source = nil;
    if (hls) {
        BrowserSubtitleHLSAudioSource *hlsSource = [[BrowserSubtitleHLSAudioSource alloc] initWithPlaylistURL:self.playbackURL
                                                                                                requestHeaders:self.requestHeaders
                                                                                                       cookies:self.cookies];
        NSString *language = self.preferences.autoSubtitlesLanguage;
        hlsSource.preferredLanguage = [language isEqualToString:@"auto"] ? nil : language;
        source = hlsSource;
    } else if (item != nil) {
        source = [[BrowserSubtitleAudioTapSource alloc] initWithPlayerItem:item];
    }
    if (source == nil) {
        [self stopRecognitionClearing:NO];
        return;
    }
    if (hls) {
        self.triedHLSFallback = YES;
    }
    BOOL ahead = source.deliversAhead;
    BrowserSubtitleEngine *engine = self.engine;
    dispatch_sync(self.processingQueue, ^{
        self.processingSource = source;
        self.processingEngine = engine;
        // Vorauslesende Quellen: längere Abschnitte (genauer, weniger Aufrufe). Echtzeit: kurz für wenig Verzug.
        self.windowSeconds = ahead ? 12.0 : 5.0;
        self.overlapSeconds = ahead ? 1.5 : 1.0;
        self.dropStaleWindows = !ahead;
        [self resetBufferLocked];
        [self.pendingWindows removeAllObjects];
    });
    self.source = source;
    source.delegate = self;
    NSLog(@"%@ Tonquelle %@ für %@", kSubtitleControllerLogPrefix, source.kindName, self.playbackURL.absoluteString);
    [source start];
    CMTime now = self.playerViewController.player.currentTime;
    [source updatePlaybackTime:CMTIME_IS_NUMERIC(now) ? CMTimeGetSeconds(now) : 0.0 rate:self.playerViewController.player.rate];
}

- (void)stopRecognitionClearing:(BOOL)clearCues {
    if (!self.running && self.source == nil && self.engine == nil) {
        if (clearCues) {
            [self.cues removeAllObjects];
        }
        return;
    }
    self.running = NO;
    id<BrowserSubtitleAudioSource> source = self.source;
    self.source = nil;
    source.delegate = nil;
    [source stop];
    BrowserSubtitleEngine *engine = self.engine;
    self.engine = nil;
    [engine cancel];
    dispatch_sync(self.processingQueue, ^{
        self.processingSource = nil;
        self.processingEngine = nil;
        [self.pendingWindows removeAllObjects];
        [self resetBufferLocked];
        if (clearCues) {
            [self.covered removeAllIndexes];
        }
    });
    // Modell auf der whisper-Queue freigeben, nachdem eine laufende Auswertung abgebrochen ist.
    dispatch_async(self.engineQueue, ^{
        (void)engine;
    });
    if (clearCues) {
        [self.cues removeAllObjects];
    }
    [self.overlay setSubtitleText:nil];
    NSLog(@"%@ Erkennung gestoppt (RTF Schnitt %.2f)", kSubtitleControllerLogPrefix, engine.averageRealTimeFactor);
}

#pragma mark Tonquelle (Hintergrund)

- (void)resetBufferLocked {
    self.buffer = [NSMutableData data];
    self.hasBuffer = NO;
    self.bufferStart = 0.0;
}

- (NSTimeInterval)bufferedSecondsLocked {
    return (double)(self.buffer.length / sizeof(float)) / kSampleRate;
}

- (void)audioSource:(id<BrowserSubtitleAudioSource>)source didProduceSamples:(NSData *)samples atTime:(NSTimeInterval)mediaTime discontinuity:(BOOL)discontinuity {
    dispatch_async(self.processingQueue, ^{
        if (source != self.processingSource || samples.length == 0) {
            return;
        }
        NSTimeInterval expectedEnd = self.bufferStart + [self bufferedSecondsLocked];
        if (discontinuity || !self.hasBuffer || fabs(mediaTime - expectedEnd) > 0.3) {
            if (self.hasBuffer && [self bufferedSecondsLocked] >= 1.5) {
                [self submitWindowFromBufferLength:self.buffer.length final:YES];
            }
            [self resetBufferLocked];
            self.bufferStart = mediaTime;
            self.hasBuffer = YES;
        } else {
            // An die Zeit der Quelle anlehnen, damit sich Rundungen nicht aufsummieren.
            self.bufferStart += mediaTime - expectedEnd;
        }
        [self.buffer appendData:samples];
        NSUInteger windowBytes = (NSUInteger)(self.windowSeconds * kSampleRate) * sizeof(float);
        NSUInteger stepBytes = (NSUInteger)((self.windowSeconds - self.overlapSeconds) * kSampleRate) * sizeof(float);
        while (self.buffer.length >= windowBytes) {
            [self submitWindowFromBufferLength:windowBytes final:NO];
            [self.buffer replaceBytesInRange:NSMakeRange(0, stepBytes) withBytes:NULL length:0];
            self.bufferStart += (double)(stepBytes / sizeof(float)) / kSampleRate;
        }
    });
}

- (void)flushPartialWindow {
    dispatch_async(self.processingQueue, ^{
        if (self.processingSource == nil || !self.hasBuffer || [self bufferedSecondsLocked] < 1.5) {
            return;
        }
        [self submitWindowFromBufferLength:self.buffer.length final:YES];
        NSTimeInterval end = self.bufferStart + [self bufferedSecondsLocked];
        [self resetBufferLocked];
        self.bufferStart = end;
    });
}

- (void)audioSource:(id<BrowserSubtitleAudioSource>)source didFailWithReason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (source != self.source) {
            return;
        }
        NSLog(@"%@ Tonquelle %@ fehlgeschlagen: %@", kSubtitleControllerLogPrefix, source.kindName, reason);
        if (!self.triedHLSFallback && [source isKindOfClass:BrowserSubtitleAudioTapSource.class]) {
            // Kein Tap möglich (z. B. HLS ohne .m3u8 in der Adresse): Segmentweg versuchen.
            self.source = nil;
            source.delegate = nil;
            [source stop];
            [self startSourcePreferringHLS:YES];
            return;
        }
        [self.overlay showStatus:[NSString stringWithFormat:@"Automatische Untertitel: %@", reason] duration:6.0];
        [self stopRecognitionClearing:NO];
    });
}

- (NSTimeInterval)audioSourcePendingSeconds:(id<BrowserSubtitleAudioSource>)source {
    __block NSTimeInterval pending = 0.0;
    dispatch_sync(self.processingQueue, ^{
        pending = [self bufferedSecondsLocked] + self.pendingWindows.count * (self.windowSeconds - self.overlapSeconds) +
                  (self.engineBusy ? self.windowSeconds : 0.0);
    });
    return pending;
}

- (BOOL)audioSource:(id<BrowserSubtitleAudioSource>)source isRangeCoveredFrom:(NSTimeInterval)start to:(NSTimeInterval)end {
    __block BOOL covered = NO;
    dispatch_sync(self.processingQueue, ^{
        NSUInteger first = (NSUInteger)ceil(MAX(0.0, start) / kCoverageUnit);
        NSUInteger last = (NSUInteger)floor(MAX(0.0, end) / kCoverageUnit);
        covered = last > first && [self.covered containsIndexesInRange:NSMakeRange(first, last - first)];
    });
    return covered;
}

#pragma mark Abschnitte (processingQueue)

- (void)submitWindowFromBufferLength:(NSUInteger)length final:(BOOL)final {
    BrowserSubtitleWindow *window = [BrowserSubtitleWindow new];
    window.samples = [self.buffer subdataWithRange:NSMakeRange(0, length)];
    window.start = self.bufferStart;
    window.end = self.bufferStart + (double)(length / sizeof(float)) / kSampleRate;
    window.acceptFrom = window.start;
    window.acceptUntil = final ? window.end : window.end - self.overlapSeconds / 2.0;

    NSUInteger first = (NSUInteger)ceil(MAX(0.0, window.acceptFrom) / kCoverageUnit);
    NSUInteger last = (NSUInteger)floor(MAX(0.0, window.acceptUntil) / kCoverageUnit);
    if (last > first && [self.covered containsIndexesInRange:NSMakeRange(first, last - first)]) {
        return;  // schon ausgewertet (z. B. nach Zurückspulen)
    }
    if (self.dropStaleWindows && self.pendingWindows.count > 0) {
        // Echtzeitquelle und whisper kommt nicht nach: alte Abschnitte verwerfen, sonst wächst der Verzug.
        self.droppedWindows += self.pendingWindows.count;
        NSLog(@"%@ %lu Abschnitt(e) verworfen (Erkennung zu langsam)", kSubtitleControllerLogPrefix, (unsigned long)self.pendingWindows.count);
        [self.pendingWindows removeAllObjects];
    }
    [self.pendingWindows addObject:window];
    [self pumpLocked];
}

- (void)pumpLocked {
    if (self.engineBusy || self.pendingWindows.count == 0 || self.processingEngine == nil) {
        return;
    }
    BrowserSubtitleWindow *window = self.pendingWindows.firstObject;
    [self.pendingWindows removeObjectAtIndex:0];
    self.engineBusy = YES;
    BrowserSubtitleEngine *engine = self.processingEngine;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.engineQueue, ^{
        NSArray<BrowserSubtitleCue *> *cues = [engine transcribeSamples:window.samples.bytes
                                                                  count:window.samples.length / sizeof(float)
                                                              startTime:window.start];
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        dispatch_async(strongSelf.processingQueue, ^{
            strongSelf.engineBusy = NO;
            if (engine == strongSelf.processingEngine && cues != nil) {
                strongSelf.processedWindows++;
                [strongSelf acceptCues:cues fromWindow:window];
            }
            [strongSelf pumpLocked];
        });
    });
}

- (void)acceptCues:(NSArray<BrowserSubtitleCue *> *)cues fromWindow:(BrowserSubtitleWindow *)window {
    NSMutableArray<BrowserSubtitleCue *> *accepted = [NSMutableArray array];
    for (BrowserSubtitleCue *cue in cues) {
        NSTimeInterval middle = (cue.start + cue.end) / 2.0;
        if (middle < window.acceptFrom || middle >= window.acceptUntil) {
            continue;  // gehört zum Nachbarabschnitt (Überlappung)
        }
        if ([self.covered containsIndex:(NSUInteger)floor(MAX(0.0, middle) / kCoverageUnit)]) {
            continue;  // schon von einem früheren Abschnitt
        }
        [accepted addObject:cue];
    }
    NSUInteger first = (NSUInteger)ceil(MAX(0.0, window.acceptFrom) / kCoverageUnit);
    NSUInteger last = (NSUInteger)floor(MAX(0.0, window.acceptUntil) / kCoverageUnit);
    if (last > first) {
        [self.covered addIndexesInRange:NSMakeRange(first, last - first)];
    }
    if (accepted.count == 0) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self addCues:accepted];
    });
}

#pragma mark Anzeige (Hauptthread)

- (void)addCues:(NSArray<BrowserSubtitleCue *> *)cues {
    if (self.detached) {
        return;
    }
    CMTime currentTime = self.observedPlayer.currentTime;
    NSTimeInterval now = CMTIME_IS_NUMERIC(currentTime) ? CMTimeGetSeconds(currentTime) : 0.0;
    for (BrowserSubtitleCue *cue in cues) {
        if ([self isRepeatedCue:cue]) {
            continue;  // whisper wiederholt sich gern (gleicher Satz doppelt, „directional“ in Musik)
        }
        NSTimeInterval duration = cue.end - cue.start;
        cue.visibleUntil = cue.end + 0.6;
        if (now > cue.end - 0.3 && now - cue.end < 8.0) {
            // Kam zu spät (Echtzeit-Tap): ab jetzt noch eine Lesezeit lang zeigen.
            cue.visibleUntil = MAX(cue.visibleUntil, now + MIN(4.0, MAX(1.5, duration)));
        }
        NSUInteger index = [self.cues indexOfObject:cue inSortedRange:NSMakeRange(0, self.cues.count)
                                            options:NSBinarySearchingInsertionIndex
                                    usingComparator:^NSComparisonResult(BrowserSubtitleCue *a, BrowserSubtitleCue *b) {
            return [@(a.start) compare:@(b.start)];
        }];
        [self.cues insertObject:cue atIndex:index];
    }
    [self updateOverlayAtTime:now];
}

static NSString *BrowserSubtitleNormalizedText(NSString *text) {
    NSCharacterSet *drop = NSCharacterSet.alphanumericCharacterSet.invertedSet;
    return [[[text lowercaseString] componentsSeparatedByCharactersInSet:drop] componentsJoinedByString:@""];
}

- (BOOL)isRepeatedCue:(BrowserSubtitleCue *)cue {
    NSString *normalized = BrowserSubtitleNormalizedText(cue.text);
    if (normalized.length == 0) {
        return YES;
    }
    for (BrowserSubtitleCue *other in self.cues) {
        if (fabs(other.start - cue.start) < 15.0 && [BrowserSubtitleNormalizedText(other.text) isEqualToString:normalized]) {
            return YES;
        }
    }
    return NO;
}

- (void)updateOverlayAtTime:(NSTimeInterval)time {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSInteger i = (NSInteger)self.cues.count - 1; i >= 0 && lines.count < 2; i--) {
        BrowserSubtitleCue *cue = self.cues[(NSUInteger)i];
        if (cue.start > time + 0.1) {
            continue;
        }
        if (cue.start < time - 30.0) {
            break;
        }
        if (cue.visibleUntil > time) {
            [lines insertObject:cue.text atIndex:0];
        }
    }
    [self.overlay setSubtitleText:lines.count > 0 ? [lines componentsJoinedByString:@"\n"] : nil];
}

- (void)playerTimeDidChange:(CMTime)time {
    if (self.detached || !CMTIME_IS_NUMERIC(time)) {
        return;
    }
    NSTimeInterval seconds = CMTimeGetSeconds(time);
    [self updateOverlayAtTime:seconds];

    NSTimeInterval wall = CACurrentMediaTime();
    float rate = self.observedPlayer.rate;
    if (self.source != nil && (wall - self.lastSourceUpdate > 0.5 || rate != self.lastRate)) {
        self.lastSourceUpdate = wall;
        [self.source updatePlaybackTime:seconds rate:rate];
    }
    if (self.source != nil && !self.source.deliversAhead && self.lastRate > 0.0f && rate == 0.0f) {
        [self flushPartialWindow];  // Pause: angefangenen Satz trotzdem auswerten
    }
    self.lastRate = rate;
    if (wall - self.lastMenuCheck > 2.0) {
        self.lastMenuCheck = wall;
        if (!self.menuInstalled) {
            [self installMenu];  // falls der Player seine Einträge neu gesetzt hat
        }
    }
    if (self.running && wall - self.lastSummary > 30.0) {
        self.lastSummary = wall;
        __block NSUInteger processed = 0, dropped = 0, pending = 0;
        dispatch_sync(self.processingQueue, ^{
            processed = self.processedWindows;
            dropped = self.droppedWindows;
            pending = self.pendingWindows.count;
        });
        NSLog(@"%@ Stand t=%.1f s: %lu Untertitel, %lu Abschnitte, %lu verworfen, %lu wartend, RTF Schnitt %.2f, Speicher %.0f MB",
              kSubtitleControllerLogPrefix, seconds, (unsigned long)self.cues.count, (unsigned long)processed,
              (unsigned long)dropped, (unsigned long)pending, self.engine.averageRealTimeFactor,
              [BrowserSubtitleEngine currentMemoryFootprintMB]);
    }
}

@end
