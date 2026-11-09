#import "BrowserWebSubtitleController.h"

#import "BrowserPreferencesStore.h"
#import "BrowserSpeechRecognizerStub.h"
#import "BrowserSubtitleEngine.h"
#import "BrowserSubtitleHLSAudioSource.h"
#import "BrowserSubtitlePipeline.h"
#import "BrowserSubtitleTranslator.h"
#import "BrowserSubtitleProgressiveAudioSource.h"
#import "BrowserWebView.h"
#import "BrowserWhisperSpeechRecognizer.h"

#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>

typedef NS_ENUM(NSInteger, BrowserWebSubtitleMode) {
    BrowserWebSubtitleModeNone = 0,
    /// Mithören über Web Audio (Blöcke aus dem Seiten-Skript), Pipeline im Echtzeittakt.
    BrowserWebSubtitleModeTap,
    /// App lädt den Ton der Medienadresse selbst (MP4/HLS), vor der Abspielposition.
    BrowserWebSubtitleModeDirect,
};

#pragma mark - Web Audio als Pipeline-Quelle

/// Blöcke aus BrowserWebAudioCapture für BrowserSubtitlePipeline (Echtzeit, `deliversAhead` NO). Die Blöcke reicht
/// der Controller durch; Start/Stopp und Zeit steuert der Abgriff selbst.
@interface BrowserWebAudioPipelineSource : NSObject <BrowserSubtitleAudioSource>
@end

@implementation BrowserWebAudioPipelineSource
@synthesize delegate = _delegate;
- (BOOL)deliversAhead { return NO; }
- (NSString *)kindName { return @"webaudio"; }
- (void)start {}
- (void)stop {}
- (void)updatePlaybackTime:(NSTimeInterval)time rate:(float)rate { (void)time; (void)rate; }
@end

#pragma mark - Controller

@interface BrowserWebSubtitleController ()
@property (nonatomic, readwrite) BrowserWebAudioCapture *capture;
@property (nonatomic, readwrite) BrowserWebSubtitleOverlay *overlay;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, readwrite, weak, nullable) BrowserWebView *webView;
@property (nonatomic, strong) BrowserSubtitlePipeline *pipeline;
@property (nonatomic, strong) BrowserWebAudioPipelineSource *tapSource;
@property (nonatomic, strong, nullable) id<BrowserSubtitleAudioSource> directSource;
@property (nonatomic, copy, nullable) NSString *directURL;
@property (nonatomic, strong) NSMutableSet<NSString *> *failedDirectURLs;
@property (nonatomic, strong) NSMutableArray<NSString *> *directKinds;   // noch zu versuchende Arten („mp4“, „hls“)
// Adresse bekannt, Video spielt aber noch nicht (Vorschaubild, Autoplay gesperrt, Video im nativen Player):
// erst beim Abspielen laden, sonst lüde die App 60 s Ton für nichts.
@property (nonatomic, copy, nullable) NSString *pendingSource;
@property (nonatomic, copy, nullable) NSString *pendingPageURL;
@property (nonatomic, copy, nullable) NSString *pendingUserAgent;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *offsets;
@property (nonatomic) BOOL droppedDateCuesLogged;
@end

@implementation BrowserWebSubtitleController {
    _Atomic(NSInteger) _mode;
    // Nur auf capture.sampleQueue:
    NSUInteger _segment;
    // Nur auf dem Hauptthread:
    NSUInteger _windows;
    double _recognitionSum;
    double _recognitionMax;
    double _displayLagSum;
    NSUInteger _displayed;
    NSTimeInterval _lastDisplayedStart;
    CFTimeInterval _noVideoHintUntil;
}

- (instancetype)init {
    return [self initWithRecognizer:nil];
}

- (instancetype)initWithRecognizer:(id<BrowserSpeechRecognizing>)recognizer {
    self = [super init];
    if (self) {
        _capture = [BrowserWebAudioCapture new];
        _overlay = [[BrowserWebSubtitleOverlay alloc] initWithFrame:CGRectZero];
        _showsStatusHints = YES;
        _lastDisplayedStart = -INFINITY;
        _tapSource = [BrowserWebAudioPipelineSource new];
        _failedDirectURLs = [NSMutableSet set];
        _directKinds = [NSMutableArray array];
        _offsets = [NSMutableArray array];
        atomic_store(&_mode, BrowserWebSubtitleModeNone);
        self.recognizer = recognizer ?: [BrowserSpeechRecognizerStub new];
        [self makePipeline];
        [self wireCapture];
    }
    return self;
}

- (void)setRecognizer:(id<BrowserSpeechRecognizing>)recognizer {
    _recognizer = recognizer;
    NSTimeInterval window = [recognizer respondsToSelector:@selector(preferredWindowDuration)] ? recognizer.preferredWindowDuration : 3.0;
    NSTimeInterval overlap = [recognizer respondsToSelector:@selector(preferredOverlapDuration)] ? recognizer.preferredOverlapDuration : 0.5;
    self.windowDuration = window > 0.0 ? window : 3.0;
    self.overlapDuration = MIN(MAX(0.0, overlap), self.windowDuration * 0.5);
}

- (void)makePipeline {
    __weak typeof(self) weakSelf = self;
    self.pipeline = [[BrowserSubtitlePipeline alloc] initWithTranscriber:^(NSData *samples, NSTimeInterval startTime,
                                                                           void (^completion)(NSArray<BrowserSubtitleCue *> *)) {
        [weakSelf transcribeSamples:samples startTime:startTime completion:completion];
    }];
    self.pipeline.cueHandler = ^(NSArray<BrowserSubtitleCue *> *cues, NSTimeInterval replaceFrom, NSTimeInterval windowStart, NSTimeInterval windowEnd) {
        [weakSelf pipelineDeliveredCues:cues replaceFrom:replaceFrom windowStart:windowStart windowEnd:windowEnd];
    };
    self.pipeline.failureHandler = ^(id<BrowserSubtitleAudioSource> source, NSString *reason) {
        [weakSelf directSource:source didFailWithReason:reason];
    };
}

/// Läuft auf der Queue der Pipeline. whisper direkt (Satzstücke mit Zeitmarken), sonst über die schmale Schnittstelle.
- (void)transcribeSamples:(NSData *)samples startTime:(NSTimeInterval)startTime
               completion:(void (^)(NSArray<BrowserSubtitleCue *> *))completion {
    id<BrowserSpeechRecognizing> recognizer = self.recognizer;
    CFTimeInterval begin = CACurrentMediaTime();
    void (^finish)(NSArray<BrowserSubtitleCue *> *) = ^(NSArray<BrowserSubtitleCue *> *cues) {
        double milliseconds = (CACurrentMediaTime() - begin) * 1000.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_windows++;
            self->_recognitionSum += milliseconds;
            self->_recognitionMax = MAX(self->_recognitionMax, milliseconds);
        });
        completion(cues);
    };
    if ([recognizer isKindOfClass:BrowserWhisperSpeechRecognizer.class]) {
        [(BrowserWhisperSpeechRecognizer *)recognizer transcribeEngineSamples:samples startTime:startTime completion:finish];
        return;
    }
    [recognizer transcribeSamples:samples.bytes count:samples.length / sizeof(float) startTime:startTime
                       completion:^(NSArray<BrowserWebSubtitleCue *> *webCues) {
        NSMutableArray<BrowserSubtitleCue *> *cues = [NSMutableArray arrayWithCapacity:webCues.count];
        for (BrowserWebSubtitleCue *cue in webCues) {
            [cues addObject:[[BrowserSubtitleCue alloc] initWithStart:cue.start end:cue.end text:cue.text]];
        }
        finish(cues);
    }];
}

- (BrowserWebSubtitleMode)mode {
    return (BrowserWebSubtitleMode)atomic_load(&_mode);
}

- (void)setMode:(BrowserWebSubtitleMode)mode {
    atomic_store(&_mode, mode);
    // Vorauslesend gibt es keinen Verzug: kurzer Nachlauf. Mithören: Text kommt ≈ 1–1,5 s nach dem Sprechen.
    self.overlay.holdDuration = mode == BrowserWebSubtitleModeDirect ? 0.8 : 2.0;
}

- (void)wireCapture {
    __weak typeof(self) weakSelf = self;
    self.capture.sampleHandler = ^(const float *samples, NSUInteger count, NSTimeInterval mediaTime) {
        [weakSelf handleSamples:samples count:count mediaTime:mediaTime];
    };
    self.capture.playbackHandler = ^(BrowserWebAudioPlaybackState state) {
        [weakSelf handlePlaybackState:state];
    };
    self.capture.statusHandler = ^(BrowserWebAudioCaptureStatus status, NSString *detail) {
        [weakSelf handleStatus:status detail:detail];
    };
    self.capture.mediaSourceHandler = ^(NSString *source, NSString *pageURL, NSString *userAgent) {
        [weakSelf mediaSourceDidChange:source pageURL:pageURL userAgent:userAgent];
    };
    self.overlay.cueDidAppear = ^(BrowserWebSubtitleCue *cue, NSTimeInterval mediaTime) {
        [weakSelf cueDidAppear:cue atMediaTime:mediaTime];
    };
}

#pragma mark - Start und Stopp

- (void)startForWebView:(BrowserWebView *)webView {
    [self startForWebView:webView userInitiated:NO];
}

- (void)startForWebView:(BrowserWebView *)webView userInitiated:(BOOL)userInitiated {
    if (webView == nil) {
        return;
    }
    _noVideoHintUntil = userInitiated ? CACurrentMediaTime() + 4.0 : 0.0;
    if (self.running && self.webView != webView) {
        [self stop];
    }
    self.webView = webView;
    self.running = YES;
    [self.overlay removeAllCues];
    [self.overlay attachToWebView:webView];
    [self.failedDirectURLs removeAllObjects];
    [self resetRecognition];
    [self useTap];
    NSLog(@"[WebSubs] Start: Erkennung %@, Mithören Schritt %.1f s (bis %.0f s), Vorausquelle bei direkter Medienadresse",
          [self.recognizer respondsToSelector:@selector(recognizerName)] ? self.recognizer.recognizerName : NSStringFromClass([(NSObject *)self.recognizer class]),
          self.pipeline.liveStepSeconds, self.pipeline.liveMaxWindowSeconds);
    [self.capture startForWebView:webView];
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    self.pendingSource = nil;
    [self.capture stop];
    [self stopDirectSource];
    [self.pipeline detachSource];
    self.mode = BrowserWebSubtitleModeNone;
    [self resetRecognition];
    [self.overlay removeAllCues];
    [self.overlay attachToWebView:nil];
    NSLog(@"[WebSubs] Stopp: %@", self.statisticsSummary);
}

- (void)resetRecognition {
    id<BrowserSpeechRecognizing> recognizer = self.recognizer;
    if ([recognizer respondsToSelector:@selector(reset)]) {
        [recognizer reset];
    }
    [self.pipeline clearCoverage];
    [self.offsets removeAllObjects];
    _lastDisplayedStart = -INFINITY;
}

/// Mithören über Web Audio (Ausgangslage und Rückfall).
- (void)useTap {
    [self.pipeline attachSource:self.tapSource];
    self.mode = BrowserWebSubtitleModeTap;
}

#pragma mark - Direkte Quelle (App lädt den Ton selbst)

+ (BOOL)isHLSAddress:(NSURL *)URL {
    NSString *path = URL.path.lowercaseString ?: @"";
    NSString *query = URL.query.lowercaseString ?: @"";
    return [path hasSuffix:@".m3u8"] || [path hasSuffix:@".m3u"] || [query containsString:@"format=m3u8"] ||
           [query containsString:@"m3u8"];
}

+ (BOOL)isProgressiveAddress:(NSURL *)URL {
    NSString *extension = URL.pathExtension.lowercaseString ?: @"";
    return [@[@"mp4", @"m4v", @"mov", @"m4a", @"3gp"] containsObject:extension];
}

/// Medienadresse, die die App selbst laden kann (http/https, nicht blob:/data:/MSE).
+ (nullable NSURL *)loadableURLFromSource:(NSString *)source {
    NSURL *URL = source.length > 0 ? [NSURL URLWithString:source] : nil;
    NSString *scheme = URL.scheme.lowercaseString;
    if (URL == nil || URL.host.length == 0 || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        return nil;
    }
    return URL;
}

- (void)mediaSourceDidChange:(NSString *)source pageURL:(NSString *)pageURL userAgent:(NSString *)userAgent {
    if (!self.running) {
        return;
    }
    if ([source isEqualToString:self.directURL]) {
        return;
    }
    self.pendingSource = nil;
    NSURL *URL = [BrowserWebSubtitleController loadableURLFromSource:source];
    if (self.directSource != nil) {
        // anderes Video in der Seite: alte Quelle weg, Text gehört nicht mehr dazu
        [self stopDirectSource];
        [self.overlay removeAllCues];
        [self resetRecognition];
        [self useTap];
    }
    if (URL == nil) {
        NSLog(@"[WebSubs] Medienadresse nicht selbst ladbar (%@), Mithören über Web Audio", [source componentsSeparatedByString:@":"].firstObject);
        return;
    }
    if ([self.failedDirectURLs containsObject:source]) {
        return;
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesForceTap"]) {
        NSLog(@"[WebSubs] SubtitlesForceTap: nur Mithören über Web Audio");
        return;   // Test/Messung des Mithörens
    }
    if (self.capture.playbackState.paused) {
        self.pendingSource = source;
        self.pendingPageURL = pageURL;
        self.pendingUserAgent = userAgent;
        NSLog(@"[WebSubs] Medienadresse bekannt, Ton wird beim Abspielen geladen");
        return;
    }
    [self startDirectSourceForSource:source URL:URL pageURL:pageURL userAgent:userAgent];
}

- (void)startDirectSourceForSource:(NSString *)source URL:(NSURL *)URL pageURL:(NSString *)pageURL userAgent:(NSString *)userAgent {
    [self.directKinds removeAllObjects];
    if ([BrowserWebSubtitleController isHLSAddress:URL]) {
        [self.directKinds addObject:@"hls"];
    } else if ([BrowserWebSubtitleController isProgressiveAddress:URL]) {
        [self.directKinds addObject:@"mp4"];
    } else {
        // Ohne Endung (z. B. Zugriffs-Token im Pfad): zuerst als Datei, sonst als Playlist.
        [self.directKinds addObjectsFromArray:@[@"mp4", @"hls"]];
    }
    [self startNextDirectSourceForURL:URL source:source pageURL:pageURL userAgent:userAgent];
}

- (void)startNextDirectSourceForURL:(NSURL *)URL source:(NSString *)source pageURL:(NSString *)pageURL userAgent:(NSString *)userAgent {
    NSString *kind = self.directKinds.firstObject;
    if (kind == nil) {
        return;
    }
    [self.directKinds removeObjectAtIndex:0];
    NSURL *page = pageURL.length > 0 ? [NSURL URLWithString:pageURL] : self.webView.committedURL;
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    NSString *agent = userAgent.length > 0 ? userAgent : [[BrowserPreferencesStore new] userAgent];
    if (agent.length > 0) {
        headers[@"User-Agent"] = agent;
    }
    if ([page.scheme.lowercaseString hasPrefix:@"http"]) {
        headers[@"Referer"] = page.absoluteString;
        if (page.scheme.length > 0 && page.host.length > 0) {
            NSString *port = page.port != nil ? [NSString stringWithFormat:@":%@", page.port] : @"";
            headers[@"Origin"] = [NSString stringWithFormat:@"%@://%@%@", page.scheme, page.host, port];
        }
    }
    NSArray<NSHTTPCookie *> *cookies = [BrowserWebView allCookies];
    id<BrowserSubtitleAudioSource> audioSource = nil;
    if ([kind isEqualToString:@"hls"]) {
        audioSource = [[BrowserSubtitleHLSAudioSource alloc] initWithPlaylistURL:URL requestHeaders:headers cookies:cookies];
    } else {
        audioSource = [[BrowserSubtitleProgressiveAudioSource alloc] initWithURL:URL requestHeaders:headers cookies:cookies];
    }
    self.directSource = audioSource;
    self.directURL = source;
    [self.overlay removeAllCues];
    [self resetRecognition];
    [self.pipeline attachSource:audioSource];
    self.mode = BrowserWebSubtitleModeDirect;
    NSLog(@"[WebSubs] Tonquelle %@ (App lädt selbst, Referer %@, %lu Cookies) für %@", audioSource.kindName, page.host ?: @"-",
          (unsigned long)cookies.count, source.length > 160 ? [[source substringToIndex:160] stringByAppendingString:@"…"] : source);
    [audioSource start];
    [self pushPlaybackState:self.capture.playbackState];
}

- (void)stopDirectSource {
    id<BrowserSubtitleAudioSource> source = self.directSource;
    if (source == nil) {
        return;
    }
    self.directSource = nil;
    self.directURL = nil;
    [source stop];
    NSLog(@"[WebSubs] Tonquelle %@ getrennt, Versatz: %@, %@", source.kindName, BrowserSubtitleOffsetSummary(self.offsets),
          [BrowserSubtitleTranslator.sharedTranslator summary]);
}

- (void)directSource:(id<BrowserSubtitleAudioSource>)source didFailWithReason:(NSString *)reason {
    if (source != self.directSource || !self.running) {
        return;
    }
    NSString *failedURL = self.directURL;
    NSLog(@"[WebSubs] Tonquelle %@ geht nicht: %@", source.kindName, reason);
    self.directSource = nil;
    self.directURL = nil;
    [source stop];
    NSURL *URL = [BrowserWebSubtitleController loadableURLFromSource:failedURL];
    if (self.directKinds.count > 0 && URL != nil) {
        [self startNextDirectSourceForURL:URL source:failedURL pageURL:self.capture.mediaPageURL ?: @"" userAgent:self.capture.mediaUserAgent ?: @""];
        return;
    }
    if (failedURL != nil) {
        [self.failedDirectURLs addObject:failedURL];
    }
    [self useTap];
    BOOL protected = [reason containsString:@"FairPlay"] || [reason containsString:@"SAMPLE-AES"];
    BOOL tapWorks = self.capture.status == BrowserWebAudioCaptureStatusRunning;
    if (!tapWorks && self.showsStatusHints) {
        // Web Audio liefert hier nichts (sonst wäre die App gar nicht erst selbst losgezogen): echte Grenze.
        [self.overlay showHint:protected ? @"Untertitel: Video ist kopiergeschützt" : @"Untertitel für dieses Video nicht möglich" duration:6.0];
    }
}

#pragma mark - Ton und Zeit

/// Läuft auf capture.sampleQueue.
- (void)handleSamples:(const float *)samples count:(NSUInteger)count mediaTime:(NSTimeInterval)mediaTime {
    NSUInteger segment = self.capture.segmentGeneration;
    BOOL discontinuity = segment != _segment;
    _segment = segment;
    if (self.mode != BrowserWebSubtitleModeTap || count == 0) {
        return;
    }
    BrowserWebAudioPipelineSource *source = self.tapSource;
    [source.delegate audioSource:source didProduceSamples:[NSData dataWithBytes:samples length:count * sizeof(float)]
                          atTime:mediaTime discontinuity:discontinuity];
}

- (void)handlePlaybackState:(BrowserWebAudioPlaybackState)state {
    BOOL wasPaused = self.overlay.currentPlaybackPaused;
    [self.overlay updatePlaybackState:state];
    if (!state.paused && self.pendingSource != nil && self.directSource == nil) {
        NSString *source = self.pendingSource;
        self.pendingSource = nil;
        NSURL *URL = [BrowserWebSubtitleController loadableURLFromSource:source];
        if (URL != nil) {
            [self startDirectSourceForSource:source URL:URL pageURL:self.pendingPageURL ?: @"" userAgent:self.pendingUserAgent ?: @""];
        }
    }
    if (state.paused && !wasPaused) {
        // Pause: den angefangenen Satz sofort auswerten, sonst fehlt der Text bis zur Pausenstelle.
        [self.pipeline flushPartial];
    }
    [self pushPlaybackState:state];
}

- (void)pushPlaybackState:(BrowserWebAudioPlaybackState)state {
    id<BrowserSubtitleAudioSource> source = self.directSource;
    if (source == nil || state.hostTime <= 0.0) {
        return;
    }
    float rate = state.paused ? 0.0f : (float)(state.rate > 0.0 ? state.rate : 1.0);
    NSTimeInterval date = state.startDate > 0.0 ? state.startDate + state.mediaTime : NAN;
    if ([source respondsToSelector:@selector(updatePlaybackTime:date:rate:)]) {
        [source updatePlaybackTime:state.mediaTime date:date rate:rate];
    } else {
        [source updatePlaybackTime:state.mediaTime rate:rate];
    }
}

#pragma mark - Untertitel

/// Hauptthread. Zeiten der Pipeline → Medienzeit der Seite (bei Live-HLS mit Datum: minus getStartDate()).
- (void)pipelineDeliveredCues:(NSArray<BrowserSubtitleCue *> *)cues replaceFrom:(NSTimeInterval)replaceFrom
                  windowStart:(NSTimeInterval)windowStart windowEnd:(NSTimeInterval)windowEnd {
    if (!self.running) {
        return;
    }
    NSTimeInterval shift = 0.0;
    id<BrowserSubtitleAudioSource> source = self.directSource;
    if (self.mode == BrowserWebSubtitleModeDirect && [source respondsToSelector:@selector(usesDateTimeline)] && source.usesDateTimeline) {
        NSTimeInterval startDate = self.capture.playbackState.startDate;
        if (startDate <= 0.0) {
            if (!self.droppedDateCuesLogged) {
                self.droppedDateCuesLogged = YES;
                NSLog(@"[WebSubs] Live-HLS mit Datum, aber die Seite meldet kein getStartDate(): Untertitel nicht zuzuordnen");
            }
            return;
        }
        shift = startDate;
    }
    NSMutableArray<BrowserWebSubtitleCue *> *webCues = [NSMutableArray arrayWithCapacity:cues.count];
    for (BrowserSubtitleCue *cue in cues) {
        [webCues addObject:[BrowserWebSubtitleCue cueWithStart:cue.start - shift end:cue.end - shift text:cue.text]];
    }
#if DEBUG
    NSLog(@"[WebSubs] Abschnitt %.2f–%.2f s (%@, bei t=%.2f): %@", windowStart - shift, windowEnd - shift,
          self.mode == BrowserWebSubtitleModeDirect ? source.kindName : @"webaudio", self.overlay.currentMediaTime,
          [[cues valueForKey:@"text"] componentsJoinedByString:@" / "]);
#else
    (void)windowStart;
    (void)windowEnd;
#endif
    [self.overlay addCues:webCues replacingFrom:isnan(replaceFrom) ? INFINITY : replaceFrom - shift];
}

- (void)cueDidAppear:(BrowserWebSubtitleCue *)cue atMediaTime:(NSTimeInterval)mediaTime {
    if (cue.start <= _lastDisplayedStart + 0.01) {
        return;   // ersetzter vorläufiger Text mit gleichem Anfang: schon gemessen
    }
    _lastDisplayedStart = cue.start;
    double offset = mediaTime - cue.start;
    if (fabs(offset) < 30.0) {
        _displayLagSum += offset;
        _displayed++;
        [self.offsets addObject:@(offset)];
    }
    NSLog(@"[WebSubs] Anzeige Δ=%+.2f s (Sprechbeginn %.2f, eingeblendet %.2f, %@) „%@“", offset, cue.start, mediaTime,
          self.mode == BrowserWebSubtitleModeDirect ? self.directSource.kindName : @"webaudio", cue.text);
}

#pragma mark - Zustand

/// YES, wenn die App den Ton gerade selbst lädt oder es gleich tun kann: dann sind Hinweise zu Web Audio hinfällig.
- (BOOL)directSourceCoversTapProblems {
    if (self.directSource != nil || self.pendingSource != nil) {
        return YES;
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesForceTap"]) {
        return NO;
    }
    NSString *source = self.capture.mediaSourceURL;
    return [BrowserWebSubtitleController loadableURLFromSource:source] != nil && ![self.failedDirectURLs containsObject:source];
}

- (void)handleStatus:(BrowserWebAudioCaptureStatus)status detail:(NSString *)detail {
    NSString *message = [BrowserWebSubtitleController messageForStatus:status detail:detail];
    if (status == BrowserWebAudioCaptureStatusRunning || status == BrowserWebAudioCaptureStatusStarting) {
        _lastDisplayedStart = -INFINITY;
    }
    if ((status == BrowserWebAudioCaptureStatusStarting && [detail isEqualToString:@"navigation"]) ||
        status == BrowserWebAudioCaptureStatusNoVideo) {
        // neue Seite bzw. kein Video mehr: selbst geladenen Ton beenden
        self.pendingSource = nil;
        if (self.directSource != nil) {
            [self stopDirectSource];
            [self.overlay removeAllCues];
            [self resetRecognition];
            [self useTap];
        }
    }
    BOOL realLimit = status == BrowserWebAudioCaptureStatusBlocked && [detail isEqualToString:@"drm"];
    if (message != nil && !realLimit && status != BrowserWebAudioCaptureStatusNoVideo && [self directSourceCoversTapProblems]) {
        // Web Audio liefert nichts (natives HLS, fremde Herkunft, Seite nutzt Web Audio selbst …), die App lädt
        // den Ton aber selbst: kein Hinweis. Scheitert das, meldet directSource:didFailWithReason: die Grenze.
        NSLog(@"[WebSubs] Hinweis „%@“ entfällt, Ton kommt aus der Medienadresse", message);
        message = nil;
    }
    // „Kein Video“ nur direkt nach dem Einschalten zeigen, sonst stünde es auf jeder Seite ohne Video.
    BOOL quiet = status == BrowserWebAudioCaptureStatusNoVideo && CACurrentMediaTime() > _noVideoHintUntil;
    if (message != nil && self.showsStatusHints && self.running && !quiet) {
        [self.overlay showHint:message duration:6.0];
    }
    if (self.statusHandler != nil) {
        self.statusHandler(status, detail, message);
    }
}

+ (NSString *)messageForStatus:(BrowserWebAudioCaptureStatus)status detail:(NSString *)detail {
    switch (status) {
        case BrowserWebAudioCaptureStatusIdle:
        case BrowserWebAudioCaptureStatusStarting:
        case BrowserWebAudioCaptureStatusRunning:
        case BrowserWebAudioCaptureStatusStopped:
            return nil;
        case BrowserWebAudioCaptureStatusWaitingForInteraction:
            return @"Untertitel: Video einmal anklicken";
        case BrowserWebAudioCaptureStatusSilent:
            if ([detail isEqualToString:@"cors"]) {
                return @"Untertitel: Kein Ton. Seite neu laden";
            }
            if ([detail isEqualToString:@"muted"]) {
                return @"Untertitel: Video ist stumm";
            }
            if ([detail isEqualToString:@"hls"]) {
                return @"Untertitel für dieses Video nicht möglich";
            }
            return @"Untertitel: Kein Ton";
        case BrowserWebAudioCaptureStatusNoVideo:
            return @"Untertitel: Kein Video gefunden";
        case BrowserWebAudioCaptureStatusBlocked:
            if ([detail isEqualToString:@"drm"]) {
                return @"Untertitel: Video ist kopiergeschützt";
            }
            return @"Untertitel für dieses Video nicht möglich";
        case BrowserWebAudioCaptureStatusUnsupported:
            return @"Untertitel für dieses Video nicht möglich";
        case BrowserWebAudioCaptureStatusError:
            if ([detail hasPrefix:@"source"]) {
                return @"Untertitel für dieses Video nicht möglich";
            }
            return @"Untertitel ließen sich nicht starten";
    }
    return nil;
}

- (NSString *)statisticsSummary {
    BrowserWebAudioCapture *capture = self.capture;
    NSString *mode = self.mode == BrowserWebSubtitleModeDirect ? (self.directSource.kindName ?: @"direkt")
                   : (self.mode == BrowserWebSubtitleModeTap ? @"webaudio" : @"aus");
    return [NSString stringWithFormat:@"Zustand=%@%@ Quelle=%@ Blöcke=%lu (Nullen %lu) rms=%.4f peak=%.3f Weg=%.1f ms Dekodieren=%.2f ms Puffer=%.1f s Abschnitte=%lu (Pipeline %lu, verworfen %lu) Erkennung Ø%.0f/max %.0f ms Versatz %@ Cues=%lu t=%.2f Video=%@%@ Overlay: %@",
            [BrowserWebAudioCapture nameForStatus:capture.status], capture.statusDetail.length ? [@"/" stringByAppendingString:capture.statusDetail] : @"",
            mode, (unsigned long)capture.receivedBlocks, (unsigned long)capture.silentBlocks, capture.lastRMS, capture.lastPeak,
            capture.averageTransportMilliseconds, capture.averageDecodeMilliseconds, capture.bufferedDuration,
            (unsigned long)_windows, (unsigned long)self.pipeline.processedWindows, (unsigned long)self.pipeline.droppedWindows,
            _windows ? _recognitionSum / _windows : 0.0, _recognitionMax,
            [NSString stringWithFormat:@"%@, %@", BrowserSubtitleOffsetSummary(self.offsets), [BrowserSubtitleTranslator.sharedTranslator summary]],
            (unsigned long)self.overlay.cueCount,
            self.overlay.currentMediaTime, NSStringFromCGRect(capture.playbackState.videoRect),
            capture.playbackState.fullscreen ? @" Vollbild" : @"", self.overlay.layoutSummary];
}

@end
