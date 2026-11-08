#import "BrowserWebSubtitleController.h"

#import "BrowserSpeechRecognizerStub.h"
#import "BrowserWebView.h"

#import <QuartzCore/QuartzCore.h>

@interface BrowserWebSubtitleController ()
@property (nonatomic, readwrite) BrowserWebAudioCapture *capture;
@property (nonatomic, readwrite) BrowserWebSubtitleOverlay *overlay;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, readwrite, weak, nullable) BrowserWebView *webView;
@end

@implementation BrowserWebSubtitleController {
    dispatch_queue_t _recognitionQueue;
    // Nur auf capture.sampleQueue:
    NSUInteger _newSamples;
    NSUInteger _segment;
    NSUInteger _generation;
    BOOL _inFlight;
    NSUInteger _windows;
    NSUInteger _skipped;
    double _recognitionSum;
    double _recognitionMax;
    // Nur auf dem Hauptthread:
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
        _recognitionQueue = dispatch_queue_create("io.github.tvosbrowser.app.websubtitles.recognition", DISPATCH_QUEUE_SERIAL);
        _capture = [BrowserWebAudioCapture new];
        _overlay = [[BrowserWebSubtitleOverlay alloc] initWithFrame:CGRectZero];
        _showsStatusHints = YES;
        _lastDisplayedStart = -1.0;
        self.recognizer = recognizer ?: [BrowserSpeechRecognizerStub new];
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

- (void)setWindowDuration:(NSTimeInterval)windowDuration {
    _windowDuration = windowDuration;
    self.overlay.holdDuration = MAX(2.0, windowDuration + 1.5);
}

- (void)wireCapture {
    __weak typeof(self) weakSelf = self;
    self.capture.sampleHandler = ^(const float *samples, NSUInteger count, NSTimeInterval mediaTime) {
        (void)samples;
        (void)mediaTime;
        [weakSelf handleNewSamples:count];
    };
    self.capture.playbackHandler = ^(BrowserWebAudioPlaybackState state) {
        typeof(self) strongSelf = weakSelf;
        BOOL wasPaused = strongSelf.overlay.currentPlaybackPaused;
        [strongSelf.overlay updatePlaybackState:state];
        if (state.paused && !wasPaused) {
            // Pause: den angefangenen Abschnitt sofort auswerten, sonst fehlt der Text bis zur Pausenstelle.
            dispatch_async(strongSelf.capture.sampleQueue, ^{
                [strongSelf processWindowForcing:YES];
            });
        }
    };
    self.capture.statusHandler = ^(BrowserWebAudioCaptureStatus status, NSString *detail) {
        [weakSelf handleStatus:status detail:detail];
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
    [self resetRecognition];
    NSLog(@"[WebSubs] Start: Erkennung %@, Abschnitt %.1f s, Überlappung %.1f s",
          [self.recognizer respondsToSelector:@selector(recognizerName)] ? self.recognizer.recognizerName : NSStringFromClass([(NSObject *)self.recognizer class]),
          self.windowDuration, self.overlapDuration);
    [self.capture startForWebView:webView];
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    [self.capture stop];
    [self resetRecognition];
    [self.overlay removeAllCues];
    [self.overlay attachToWebView:nil];
    NSLog(@"[WebSubs] Stopp: %@", self.statisticsSummary);
}

- (void)resetRecognition {
    dispatch_async(self.capture.sampleQueue, ^{
        self->_generation++;
        self->_newSamples = 0;
        self->_inFlight = NO;
    });
    id<BrowserSpeechRecognizing> recognizer = self.recognizer;
    if ([recognizer respondsToSelector:@selector(reset)]) {
        dispatch_async(_recognitionQueue, ^{
            [recognizer reset];
        });
    }
}

#pragma mark - Abschnitte

/// Läuft auf capture.sampleQueue.
- (void)handleNewSamples:(NSUInteger)count {
    BrowserWebAudioCapture *capture = self.capture;
    NSUInteger segment = capture.segmentGeneration;
    if (segment != _segment) {
        // Spulen, Pause oder neue Seite: Zusammenhang verwerfen, laufende Ergebnisse verfallen.
        _segment = segment;
        _generation++;
        _newSamples = 0;
        _inFlight = NO;
        id<BrowserSpeechRecognizing> recognizer = self.recognizer;
        if ([recognizer respondsToSelector:@selector(reset)]) {
            dispatch_async(_recognitionQueue, ^{
                [recognizer reset];
            });
        }
    }
    _newSamples += count;
    [self processWindowForcing:NO];
}

/// Läuft auf capture.sampleQueue. `force`: auch einen angefangenen Abschnitt auswerten (bei Pause).
- (void)processWindowForcing:(BOOL)force {
    BrowserWebAudioCapture *capture = self.capture;
    double rate = BrowserWebAudioCapture.sampleRate;
    NSUInteger hop = (NSUInteger)llround(MAX(0.25, self.windowDuration - self.overlapDuration) * rate);
    if (_newSamples < (force ? (NSUInteger)(0.25 * rate) : hop)) {
        return;
    }
    if (_inFlight) {
        // Erkennung noch beschäftigt: nicht stauen. Der nächste Block nimmt dann den neuesten Abschnitt.
        _skipped++;
        return;
    }
    NSUInteger windowCount = (NSUInteger)llround(self.windowDuration * rate);
    if (force) {
        // Nur das Neue plus Überlappung, damit der Abschnitt beim Pausenpunkt endet und nichts doppelt kommt.
        windowCount = MIN(windowCount, _newSamples + (NSUInteger)llround(self.overlapDuration * rate));
    }
    NSMutableData *window = [NSMutableData dataWithLength:windowCount * sizeof(float)];
    NSTimeInterval startTime = 0.0;
    NSUInteger copied = [capture copyLatestSamples:window.mutableBytes maxCount:windowCount startTime:&startTime];
    if (copied < (NSUInteger)(0.25 * rate)) {
        return;
    }
    window.length = copied * sizeof(float);
    _newSamples = 0;
    _inFlight = YES;
    _windows++;
    NSUInteger generation = _generation;
    id<BrowserSpeechRecognizing> recognizer = self.recognizer;
    dispatch_queue_t sampleQueue = capture.sampleQueue;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_recognitionQueue, ^{
        CFTimeInterval begin = CACurrentMediaTime();
        __block BOOL finished = NO;
        [recognizer transcribeSamples:window.bytes count:copied startTime:startTime completion:^(NSArray<BrowserWebSubtitleCue *> *cues) {
            if (finished) {
                return;
            }
            finished = YES;
            double milliseconds = (CACurrentMediaTime() - begin) * 1000.0;
            dispatch_async(sampleQueue, ^{
                [weakSelf recognitionFinishedWithCues:cues ?: @[] startTime:startTime duration:copied / rate
                                         milliseconds:milliseconds generation:generation];
            });
        }];
    });
}

/// Läuft auf capture.sampleQueue.
- (void)recognitionFinishedWithCues:(NSArray<BrowserWebSubtitleCue *> *)cues startTime:(NSTimeInterval)startTime
                           duration:(NSTimeInterval)duration milliseconds:(double)milliseconds generation:(NSUInteger)generation {
    if (generation != _generation) {
        return;
    }
    _inFlight = NO;
    _recognitionSum += milliseconds;
    _recognitionMax = MAX(_recognitionMax, milliseconds);
#if DEBUG
    NSLog(@"[WebSubs] Abschnitt %.2f–%.2f s erkannt in %.0f ms: %@", startTime, startTime + duration, milliseconds,
          [[cues valueForKey:@"text"] componentsJoinedByString:@" / "]);
#else
    (void)duration;
#endif
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.running) {
            return;
        }
        [self.overlay addCues:cues replacingFrom:startTime];
    });
}

- (void)cueDidAppear:(BrowserWebSubtitleCue *)cue atMediaTime:(NSTimeInterval)mediaTime {
    if (cue.start <= _lastDisplayedStart) {
        return;
    }
    _lastDisplayedStart = cue.start;
    double lag = mediaTime - cue.start;
    if (lag >= 0.0 && lag < 30.0) {
        _displayLagSum += lag;
        _displayed++;
    }
#if DEBUG
    NSLog(@"[WebSubs] Anzeige „%@“ bei t=%.2f, Verzug %.2f s nach Abschnittsbeginn", cue.text, mediaTime, lag);
#endif
}

#pragma mark - Zustand

- (void)handleStatus:(BrowserWebAudioCaptureStatus)status detail:(NSString *)detail {
    NSString *message = [BrowserWebSubtitleController messageForStatus:status detail:detail];
    if (status == BrowserWebAudioCaptureStatusRunning || status == BrowserWebAudioCaptureStatusStarting) {
        _lastDisplayedStart = -1.0;
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
    __block NSUInteger windows = 0, skipped = 0;
    __block double recognitionAverage = 0.0, recognitionMax = 0.0;
    dispatch_sync(capture.sampleQueue, ^{
        windows = self->_windows;
        skipped = self->_skipped;
        recognitionAverage = self->_windows ? self->_recognitionSum / self->_windows : 0.0;
        recognitionMax = self->_recognitionMax;
    });
    return [NSString stringWithFormat:@"Zustand=%@%@ Blöcke=%lu (Nullen %lu) rms=%.4f peak=%.3f Weg=%.1f ms Dekodieren=%.2f ms Puffer=%.1f s Abschnitte=%lu übersprungen=%lu Erkennung Ø%.0f/max %.0f ms Anzeige-Verzug Ø%.2f s (%lu) Cues=%lu t=%.2f Video=%@%@ Overlay: %@",
            [BrowserWebAudioCapture nameForStatus:capture.status], capture.statusDetail.length ? [@"/" stringByAppendingString:capture.statusDetail] : @"",
            (unsigned long)capture.receivedBlocks, (unsigned long)capture.silentBlocks, capture.lastRMS, capture.lastPeak,
            capture.averageTransportMilliseconds, capture.averageDecodeMilliseconds, capture.bufferedDuration,
            (unsigned long)windows, (unsigned long)skipped, recognitionAverage, recognitionMax,
            _displayed ? _displayLagSum / _displayed : 0.0, (unsigned long)_displayed, (unsigned long)self.overlay.cueCount,
            self.overlay.currentMediaTime, NSStringFromCGRect(capture.playbackState.videoRect),
            capture.playbackState.fullscreen ? @" Vollbild" : @"", self.overlay.layoutSummary];
}

@end
