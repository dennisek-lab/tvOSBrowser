#import "BrowserWebAudioCapture.h"

#import "BrowserWebView.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <math.h>

static NSString * const kBrowserWebAudioMessageName = @"browserWebAudio";
static double const kBrowserWebAudioSampleRate = 16000.0;
static NSUInteger const kBrowserWebAudioRingCapacity = 16000 * 30;
/// Abweichung der gemeldeten Blockzeit von der erwarteten, ab der ein neuer Abschnitt beginnt (Spulen, Pause).
static NSTimeInterval const kBrowserWebAudioContinuityTolerance = 0.3;

static void *BrowserWebAudioProxyKey = &BrowserWebAudioProxyKey;
static void *BrowserWebAudioScriptKey = &BrowserWebAudioScriptKey;
static void *BrowserWebAudioScrollContext = &BrowserWebAudioScrollContext;

static NSString *BrowserWebAudioScriptSource(void) {
    static NSString *source;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"web_audio_tap" ofType:@"js" inDirectory:@"WebSubtitles"];
        source = path != nil ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
        if (source.length == 0) {
            NSLog(@"[WebAudio] Skript WebSubtitles/web_audio_tap.js fehlt im App-Paket");
            source = @"";
        }
    });
    return source;
}

#pragma mark - Rückkanal

/// Schwacher Vermittler, weil WKUserContentController seinen Handler festhält. Einer je Controller (Tab).
@interface BrowserWebAudioMessageProxy : NSObject
@property (nonatomic, weak) BrowserWebAudioCapture *capture;
@end

@interface BrowserWebAudioCapture ()
@property (nonatomic, readwrite, weak, nullable) BrowserWebView *webView;
@property (nonatomic, readwrite) BrowserWebAudioCaptureStatus status;
@property (nonatomic, readwrite, copy) NSString *statusDetail;
@property (nonatomic, readwrite) BrowserWebAudioPlaybackState playbackState;
@property (nonatomic, readwrite, getter=isActive) BOOL active;
@property (nonatomic, readwrite, copy, nullable) NSString *mediaSourceURL;
@property (nonatomic, readwrite, copy, nullable) NSString *mediaPageURL;
@property (nonatomic, readwrite, copy, nullable) NSString *mediaUserAgent;
@property (nonatomic, weak, nullable) UIScrollView *observedScrollView;
@property (nonatomic) CGPoint contentOffsetAtReport;
@property (nonatomic) CGRect cssRectAtReport;
@property (nonatomic) CGFloat cssViewportWidth;
@property (nonatomic) BOOL videoFixed;
- (void)handleMessageBody:(id)body;
@end

@implementation BrowserWebAudioMessageProxy
- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    (void)controller;
    id body = [message respondsToSelector:@selector(body)] ? ((id (*)(id, SEL))objc_msgSend)(message, @selector(body)) : nil;
    [self.capture handleMessageBody:body];
}
@end

@implementation BrowserWebAudioCapture {
    dispatch_queue_t _sampleQueue;
    os_unfair_lock _ringLock;
    float *_ring;
    uint64_t _totalWritten;      // geschriebene Werte insgesamt
    uint64_t _segmentStart;      // Index des ersten Werts im aktuellen zusammenhängenden Abschnitt
    NSTimeInterval _segmentStartTime;
    double _segmentRate;
    NSTimeInterval _expectedNextTime;
    NSUInteger _segmentGeneration;
    // Kennzahlen (unter _ringLock)
    NSUInteger _receivedBlocks;
    NSUInteger _silentBlocks;
    float _lastRMS;
    float _lastPeak;
    double _transportSum;
    double _decodeSum;
}

+ (NSString *)messageHandlerName {
    return kBrowserWebAudioMessageName;
}

+ (double)sampleRate {
    return kBrowserWebAudioSampleRate;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sampleQueue = dispatch_queue_create("io.github.tvosbrowser.app.webaudio", DISPATCH_QUEUE_SERIAL);
        _ringLock = OS_UNFAIR_LOCK_INIT;
        _ring = calloc(kBrowserWebAudioRingCapacity, sizeof(float));
        _statusDetail = @"";
        _blockDuration = 0.5;
        _silenceThreshold = 4.0;
        _playbackState.videoRect = CGRectNull;
        _playbackState.rate = 1.0;
        _playbackState.paused = YES;
#if DEBUG
        _logsBlocks = YES;
#endif
    }
    return self;
}

- (void)dealloc {
    [self stopObservingScroll];
    free(_ring);
}

#pragma mark - Installation

+ (BrowserWebAudioMessageProxy *)proxyForController:(id)controller {
    if (controller == nil) {
        return nil;
    }
    BrowserWebAudioMessageProxy *proxy = objc_getAssociatedObject(controller, BrowserWebAudioProxyKey);
    if (proxy != nil) {
        return proxy;
    }
    SEL addHandler = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if (![controller respondsToSelector:addHandler]) {
        return nil;
    }
    Protocol *protocol = objc_getProtocol("WKScriptMessageHandler");
    if (protocol != NULL && !class_conformsToProtocol(BrowserWebAudioMessageProxy.class, protocol)) {
        class_addProtocol(BrowserWebAudioMessageProxy.class, protocol);
    }
    proxy = [BrowserWebAudioMessageProxy new];
    ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addHandler, proxy, kBrowserWebAudioMessageName);
    objc_setAssociatedObject(controller, BrowserWebAudioProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return proxy;
}

+ (void)installIntoUserContentController:(id)controller {
    if (controller == nil) {
        return;
    }
    [self proxyForController:controller];
    if (objc_getAssociatedObject(controller, BrowserWebAudioScriptKey) != nil) {
        return;
    }
    Class scriptClass = NSClassFromString(@"WKUserScript");
    SEL addScript = NSSelectorFromString(@"addUserScript:");
    SEL scriptInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    NSString *source = BrowserWebAudioScriptSource();
    if (scriptClass == Nil || source.length == 0 || ![controller respondsToSelector:addScript] ||
        ![scriptClass instancesRespondToSelector:scriptInit]) {
        return;
    }
    id script = [scriptClass alloc];
    // injectionTime 0 = document-start, alle Frames (Videos in iframes, etwa eingebettete Player).
    script = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(script, scriptInit, source, 0, NO);
    if (script != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, script);
        objc_setAssociatedObject(controller, BrowserWebAudioScriptKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - Start und Stopp

- (NSString *)startCommand {
    NSTimeInterval block = MIN(1.0, MAX(0.1, self.blockDuration));
    return [NSString stringWithFormat:@"window.__browserWebAudio ? window.__browserWebAudio.start({block:%.3f,silence:%.2f,mode:'%@',force:%@}) : 'missing'",
            block, MAX(1.0, self.silenceThreshold), self.forceScriptProcessor ? @"sp" : @"auto", self.ignoreCrossOriginCheck ? @"true" : @"false"];
}

- (void)startForWebView:(BrowserWebView *)webView {
    if (webView == nil) {
        return;
    }
    if (self.active && self.webView != webView) {
        [self stop];
    }
    id controller = webView.userContentController;
    BrowserWebAudioMessageProxy *proxy = [BrowserWebAudioCapture proxyForController:controller];
    if (proxy == nil) {
        [self updateStatus:BrowserWebAudioCaptureStatusUnsupported detail:@"no-message-handler"];
        return;
    }
    // Nutzerskript für künftige Seiten; die aktuelle Seite bekommt das Skript direkt.
    [BrowserWebAudioCapture installIntoUserContentController:controller];
    proxy.capture = self;
    self.webView = webView;
    self.active = YES;
    self.mediaSourceURL = nil;
    [self resetSegment];
    [self observeScrollOfWebView:webView];
    [self updateStatus:BrowserWebAudioCaptureStatusStarting detail:@""];
    [self sendStartCommandIncludingScript:YES];
}

- (void)sendStartCommandIncludingScript:(BOOL)includeScript {
    BrowserWebView *webView = self.webView;
    if (webView == nil || !self.active) {
        return;
    }
    NSString *command = self.startCommand;
    if (includeScript) {
        command = [NSString stringWithFormat:@"%@\n;%@", BrowserWebAudioScriptSource(), command];
    }
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScriptAsync:command completion:^(id result) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.active) {
            return;
        }
        if (![result isKindOfClass:NSString.class] || ![result isEqualToString:@"ok"]) {
            NSLog(@"[WebAudio] Startbefehl ohne Erfolg: %@", result);
            [strongSelf updateStatus:BrowserWebAudioCaptureStatusError detail:@"script"];
        }
    }];
}

- (void)stop {
    if (!self.active) {
        return;
    }
    BrowserWebView *webView = self.webView;
    self.active = NO;
    BrowserWebAudioMessageProxy *proxy = objc_getAssociatedObject(webView.userContentController, BrowserWebAudioProxyKey);
    if (proxy.capture == self) {
        proxy.capture = nil;
    }
    [webView evaluateJavaScriptAsync:@"window.__browserWebAudio && window.__browserWebAudio.stop()"];
    [self stopObservingScroll];
    [self resetSegment];
    self.mediaSourceURL = nil;
    BrowserWebAudioPlaybackState state = self.playbackState;
    state.videoRect = CGRectNull;
    state.paused = YES;
    state.startDate = 0.0;
    self.playbackState = state;
    [self updateStatus:BrowserWebAudioCaptureStatusStopped detail:@""];
}

- (void)fetchScriptStatus:(void (^)(NSString *))completion {
    BrowserWebView *webView = self.webView;
    if (webView == nil) {
        completion(nil);
        return;
    }
    [webView evaluateJavaScriptAsync:@"window.__browserWebAudio ? window.__browserWebAudio.status() : null" completion:^(id result) {
        completion([result isKindOfClass:NSString.class] ? result : nil);
    }];
}

#pragma mark - Nachrichten

- (void)handleMessageBody:(id)body {
    if (!self.active || ![body isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSDictionary *message = body;
    NSString *type = [message[@"type"] isKindOfClass:NSString.class] ? message[@"type"] : @"";
    if ([type isEqualToString:@"block"]) {
        double arrivalMilliseconds = NSDate.date.timeIntervalSince1970 * 1000.0;
        dispatch_async(_sampleQueue, ^{
            [self handleBlock:message arrivalMilliseconds:arrivalMilliseconds];
        });
        return;
    }
    if ([type isEqualToString:@"time"]) {
        [self handleTime:message];
        [self noteMediaInfo:message];
        return;
    }
    if ([type isEqualToString:@"state"]) {
        [self noteMediaInfo:message];   // zuerst: der Controller entscheidet am Zustand, ob er den Ton selbst lädt
        [self handleState:message];
        return;
    }
    if ([type isEqualToString:@"ready"]) {
        // Neue Seite im Hauptframe: Abgriff dort erneut starten.
        [self resetSegment];
        self.mediaSourceURL = nil;
        [self updateStatus:BrowserWebAudioCaptureStatusStarting detail:@"navigation"];
        [self sendStartCommandIncludingScript:NO];
    }
}

- (void)handleState:(NSDictionary *)message {
    NSString *state = [message[@"state"] isKindOfClass:NSString.class] ? message[@"state"] : @"";
    NSString *reason = [message[@"reason"] isKindOfClass:NSString.class] ? message[@"reason"] : @"";
    BrowserWebAudioCaptureStatus status = self.status;
    if ([state isEqualToString:@"started"]) {
        status = BrowserWebAudioCaptureStatusStarting;
    } else if ([state isEqualToString:@"running"]) {
        status = BrowserWebAudioCaptureStatusRunning;
    } else if ([state isEqualToString:@"suspended"]) {
        status = BrowserWebAudioCaptureStatusWaitingForInteraction;
    } else if ([state isEqualToString:@"silent"]) {
        status = BrowserWebAudioCaptureStatusSilent;
    } else if ([state isEqualToString:@"novideo"]) {
        status = BrowserWebAudioCaptureStatusNoVideo;
    } else if ([state isEqualToString:@"blocked"] || [state isEqualToString:@"drm"]) {
        status = BrowserWebAudioCaptureStatusBlocked;
        if ([state isEqualToString:@"drm"]) {
            reason = @"drm";
        }
    } else if ([state isEqualToString:@"unsupported"]) {
        status = BrowserWebAudioCaptureStatusUnsupported;
    } else if ([state isEqualToString:@"error"]) {
        status = BrowserWebAudioCaptureStatusError;
    } else if ([state isEqualToString:@"stopped"]) {
        // Das Skript bestätigt nur; der App-Zustand steht schon (oder es war ein iframe).
        return;
    }
    NSLog(@"[WebAudio] Zustand %@%@ (Skript: %@%@, %@ Hz, ctx=%@%@%@)", state, reason.length ? [@" " stringByAppendingString:reason] : @"",
          message[@"mode"] ?: @"", [message[@"fallback"] length] ? [NSString stringWithFormat:@", Fallback %@", message[@"fallback"]] : @"",
          message[@"inRate"] ?: @0, message[@"ctx"] ?: @"", [message[@"frame"] integerValue] ? @", iframe" : @"",
          [message[@"src"] isKindOfClass:NSString.class] ? [NSString stringWithFormat:@", src=%@", [message[@"src"] substringToIndex:MIN((NSUInteger)120, [message[@"src"] length])]] : @"");
    [self updateStatus:status detail:reason];
}

/// Medienadresse aus 'state'/'time' übernehmen; bei Änderung `mediaSourceHandler`.
- (void)noteMediaInfo:(NSDictionary *)message {
    NSString *source = [message[@"src"] isKindOfClass:NSString.class] ? message[@"src"] : nil;
    if (source.length == 0 || [source isEqualToString:self.mediaSourceURL]) {
        return;
    }
    self.mediaSourceURL = source;
    self.mediaPageURL = [message[@"page"] isKindOfClass:NSString.class] ? message[@"page"] : self.webView.committedURL.absoluteString;
    self.mediaUserAgent = [message[@"ua"] isKindOfClass:NSString.class] ? message[@"ua"] : nil;
    NSLog(@"[WebAudio] Medienadresse %@ (Frame %@)", source.length > 160 ? [[source substringToIndex:160] stringByAppendingString:@"…"] : source,
          self.mediaPageURL ?: @"?");
    if (self.mediaSourceHandler != nil) {
        self.mediaSourceHandler(source, self.mediaPageURL ?: @"", self.mediaUserAgent ?: @"");
    }
}

- (void)updateStatus:(BrowserWebAudioCaptureStatus)status detail:(NSString *)detail {
    detail = detail ?: @"";
    if (status == self.status && [detail isEqualToString:self.statusDetail]) {
        return;
    }
    self.status = status;
    self.statusDetail = detail;
    if (self.statusHandler != nil) {
        self.statusHandler(status, detail);
    }
}

- (void)handleTime:(NSDictionary *)message {
    BrowserWebAudioPlaybackState state = self.playbackState;
    state.mediaTime = [message[@"t"] doubleValue];
    state.hostTime = CACurrentMediaTime();
    state.rate = [message[@"rate"] doubleValue];
    state.paused = [message[@"paused"] boolValue];
    state.seeking = [message[@"seeking"] boolValue];
    state.fullscreen = [message[@"fs"] boolValue];
    state.startDate = [message[@"sd"] doubleValue] > 0.0 ? [message[@"sd"] doubleValue] / 1000.0 : 0.0;
    NSArray *rect = [message[@"rect"] isKindOfClass:NSArray.class] ? message[@"rect"] : nil;
    self.cssViewportWidth = [message[@"w"] doubleValue];
    self.videoFixed = [message[@"fx"] boolValue];
    self.contentOffsetAtReport = self.observedScrollView != nil ? self.observedScrollView.contentOffset : CGPointZero;
    self.cssRectAtReport = rect.count >= 4 ? CGRectMake([rect[0] doubleValue], [rect[1] doubleValue], [rect[2] doubleValue], [rect[3] doubleValue]) : CGRectNull;
    state.videoRect = [self currentVideoRect];
    self.playbackState = state;
    if (self.playbackHandler != nil) {
        self.playbackHandler(state);
    }
}

/// CSS-Rechteck → Koordinaten der BrowserWebView: Faktor Punkte je CSS-Pixel, Leisteneinschub oben, seit der
/// Meldung gescrollte Strecke (nicht bei fixierten Videos). Wie BrowserClickTargetTracker/rectsShiftedByTopInset:.
- (CGRect)currentVideoRect {
    BrowserWebView *webView = self.webView;
    CGRect css = self.cssRectAtReport;
    CGFloat viewWidth = CGRectGetWidth(webView.bounds);
    if (webView == nil || CGRectIsNull(css) || self.cssViewportWidth <= 0.0 || viewWidth <= 0.0) {
        return CGRectNull;
    }
    CGFloat scale = viewWidth / self.cssViewportWidth;
    CGPoint offsetNow = self.observedScrollView != nil ? self.observedScrollView.contentOffset : self.contentOffsetAtReport;
    CGFloat shiftX = self.videoFixed ? 0.0 : self.contentOffsetAtReport.x - offsetNow.x;
    CGFloat shiftY = self.videoFixed ? 0.0 : self.contentOffsetAtReport.y - offsetNow.y;
    return CGRectMake(CGRectGetMinX(css) * scale + shiftX,
                      CGRectGetMinY(css) * scale + shiftY + webView.topObscuredInset,
                      CGRectGetWidth(css) * scale,
                      CGRectGetHeight(css) * scale);
}

- (void)observeScrollOfWebView:(BrowserWebView *)webView {
    UIScrollView *scrollView = webView.scrollView;
    if (scrollView == self.observedScrollView) {
        return;
    }
    [self stopObservingScroll];
    if (scrollView != nil) {
        [scrollView addObserver:self forKeyPath:@"contentOffset" options:NSKeyValueObservingOptionNew context:BrowserWebAudioScrollContext];
        self.observedScrollView = scrollView;
        self.contentOffsetAtReport = scrollView.contentOffset;
    }
}

- (void)stopObservingScroll {
    [_observedScrollView removeObserver:self forKeyPath:@"contentOffset" context:BrowserWebAudioScrollContext];
    _observedScrollView = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != BrowserWebAudioScrollContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (!self.active || CGRectIsNull(self.cssRectAtReport)) {
        return;
    }
    BrowserWebAudioPlaybackState state = self.playbackState;
    state.videoRect = [self currentVideoRect];
    self.playbackState = state;
    if (self.playbackHandler != nil) {
        self.playbackHandler(state);
    }
}

#pragma mark - Blöcke und Ringpuffer

- (void)handleBlock:(NSDictionary *)message arrivalMilliseconds:(double)arrivalMilliseconds {
    NSUInteger count = [message[@"n"] unsignedIntegerValue];
    if (count == 0 || count > kBrowserWebAudioRingCapacity) {
        return;
    }
    CFTimeInterval decodeStart = CACurrentMediaTime();
    NSMutableData *samplesData = nil;
    BOOL zero = [message[@"zero"] boolValue];
    if (zero) {
        samplesData = [NSMutableData dataWithLength:count * sizeof(float)];
    } else {
        NSString *base64 = [message[@"data"] isKindOfClass:NSString.class] ? message[@"data"] : nil;
        NSData *decoded = base64 != nil ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil;
        if (decoded.length != count * sizeof(float)) {
            NSLog(@"[WebAudio] Block verworfen: %lu Bytes statt %lu", (unsigned long)decoded.length, (unsigned long)(count * sizeof(float)));
            return;
        }
        samplesData = [decoded mutableCopy];
    }
    const float *samples = samplesData.bytes;
    double sum = 0.0;
    float peak = 0.0f;
    for (NSUInteger i = 0; i < count; i++) {
        sum += (double)samples[i] * samples[i];
        peak = MAX(peak, fabsf(samples[i]));
    }
    float rms = (float)sqrt(sum / count);
    double decodeMilliseconds = (CACurrentMediaTime() - decodeStart) * 1000.0;

    NSTimeInterval mediaTime = [message[@"t"] doubleValue];
    double rate = [message[@"rate"] doubleValue];
    if (rate <= 0.0) {
        rate = 1.0;
    }
    [self appendSamples:samples count:count mediaTime:mediaTime rate:rate];

    double transport = MAX(0.0, arrivalMilliseconds - [message[@"ts"] doubleValue]);
    os_unfair_lock_lock(&_ringLock);
    _receivedBlocks++;
    if (peak == 0.0f) {
        _silentBlocks++;
    }
    _lastRMS = rms;
    _lastPeak = peak;
    _transportSum += transport;
    _decodeSum += decodeMilliseconds;
    os_unfair_lock_unlock(&_ringLock);
    if (self.logsBlocks) {
        NSLog(@"[WebAudio] Block #%@ %.2f s t=%.2f rms=%.4f (%.1f dB) peak=%.3f Weg=%.0f ms Dekodieren=%.2f ms Verzug=%.0f ms%@",
              message[@"seq"], count / kBrowserWebAudioSampleRate, mediaTime, rms, 20.0 * log10(MAX(rms, 1e-9f)), peak,
              transport, decodeMilliseconds, [message[@"lag"] doubleValue] * 1000.0, zero ? @" (Nullen)" : @"");
    }
    if (self.sampleHandler != nil) {
        self.sampleHandler(samples, count, mediaTime);
    }
}

- (void)resetSegment {
    os_unfair_lock_lock(&_ringLock);
    _segmentStart = _totalWritten;
    _segmentStartTime = 0.0;
    _segmentRate = 1.0;
    _expectedNextTime = -1.0;
    os_unfair_lock_unlock(&_ringLock);
}

- (void)appendSamples:(const float *)samples count:(NSUInteger)count mediaTime:(NSTimeInterval)mediaTime rate:(double)rate {
    os_unfair_lock_lock(&_ringLock);
    BOOL continuous = _expectedNextTime >= 0.0 && fabs(mediaTime - _expectedNextTime) < kBrowserWebAudioContinuityTolerance && fabs(rate - _segmentRate) < 0.01;
    if (!continuous) {
        _segmentStart = _totalWritten;
        _segmentStartTime = mediaTime;
        _segmentRate = rate;
        _segmentGeneration++;
    }
    NSUInteger position = (NSUInteger)(_totalWritten % kBrowserWebAudioRingCapacity);
    NSUInteger first = MIN(count, kBrowserWebAudioRingCapacity - position);
    memcpy(_ring + position, samples, first * sizeof(float));
    if (first < count) {
        memcpy(_ring, samples + first, (count - first) * sizeof(float));
    }
    _totalWritten += count;
    // Erwartung aus dem Abschnittsanker statt aus der Blockzeit, damit sich Schwankungen nicht aufsummieren.
    _expectedNextTime = _segmentStartTime + (_totalWritten - _segmentStart) * _segmentRate / kBrowserWebAudioSampleRate;
    os_unfair_lock_unlock(&_ringLock);
}

- (NSUInteger)copyLatestSamples:(float *)buffer maxCount:(NSUInteger)maxCount startTime:(NSTimeInterval *)startTime {
    os_unfair_lock_lock(&_ringLock);
    uint64_t available = MIN(_totalWritten - _segmentStart, (uint64_t)kBrowserWebAudioRingCapacity);
    NSUInteger count = (NSUInteger)MIN((uint64_t)maxCount, available);
    uint64_t firstIndex = _totalWritten - count;
    if (startTime != NULL) {
        *startTime = _segmentStartTime + (firstIndex - _segmentStart) * _segmentRate / kBrowserWebAudioSampleRate;
    }
    NSUInteger position = (NSUInteger)(firstIndex % kBrowserWebAudioRingCapacity);
    NSUInteger first = MIN(count, kBrowserWebAudioRingCapacity - position);
    if (buffer != NULL && count > 0) {
        memcpy(buffer, _ring + position, first * sizeof(float));
        if (first < count) {
            memcpy(buffer + first, _ring, (count - first) * sizeof(float));
        }
    }
    os_unfair_lock_unlock(&_ringLock);
    return count;
}

- (NSUInteger)segmentGeneration {
    os_unfair_lock_lock(&_ringLock);
    NSUInteger value = _segmentGeneration;
    os_unfair_lock_unlock(&_ringLock);
    return value;
}

- (NSTimeInterval)bufferedDuration {
    os_unfair_lock_lock(&_ringLock);
    uint64_t available = MIN(_totalWritten - _segmentStart, (uint64_t)kBrowserWebAudioRingCapacity);
    os_unfair_lock_unlock(&_ringLock);
    return available / kBrowserWebAudioSampleRate;
}

#pragma mark - Kennzahlen

// Kennzahlen unter derselben Sperre wie der Ringpuffer: auch aus sampleHandler heraus abrufbar.
- (NSUInteger)receivedBlocks {
    os_unfair_lock_lock(&_ringLock);
    NSUInteger value = _receivedBlocks;
    os_unfair_lock_unlock(&_ringLock);
    return value;
}

- (NSUInteger)silentBlocks {
    os_unfair_lock_lock(&_ringLock);
    NSUInteger value = _silentBlocks;
    os_unfair_lock_unlock(&_ringLock);
    return value;
}

- (float)lastRMS {
    os_unfair_lock_lock(&_ringLock);
    float value = _lastRMS;
    os_unfair_lock_unlock(&_ringLock);
    return value;
}

- (float)lastPeak {
    os_unfair_lock_lock(&_ringLock);
    float value = _lastPeak;
    os_unfair_lock_unlock(&_ringLock);
    return value;
}

- (double)averageTransportMilliseconds {
    os_unfair_lock_lock(&_ringLock);
    double value = _receivedBlocks ? _transportSum / _receivedBlocks : 0.0;
    os_unfair_lock_unlock(&_ringLock);
    return value;
}

- (double)averageDecodeMilliseconds {
    os_unfair_lock_lock(&_ringLock);
    double value = _receivedBlocks ? _decodeSum / _receivedBlocks : 0.0;
    os_unfair_lock_unlock(&_ringLock);
    return value;
}

+ (NSString *)nameForStatus:(BrowserWebAudioCaptureStatus)status {
    switch (status) {
        case BrowserWebAudioCaptureStatusIdle: return @"idle";
        case BrowserWebAudioCaptureStatusStarting: return @"starting";
        case BrowserWebAudioCaptureStatusWaitingForInteraction: return @"waiting-for-interaction";
        case BrowserWebAudioCaptureStatusRunning: return @"running";
        case BrowserWebAudioCaptureStatusSilent: return @"silent";
        case BrowserWebAudioCaptureStatusNoVideo: return @"no-video";
        case BrowserWebAudioCaptureStatusBlocked: return @"blocked";
        case BrowserWebAudioCaptureStatusUnsupported: return @"unsupported";
        case BrowserWebAudioCaptureStatusError: return @"error";
        case BrowserWebAudioCaptureStatusStopped: return @"stopped";
    }
    return @"?";
}

@end
