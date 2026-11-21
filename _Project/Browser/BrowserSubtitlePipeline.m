#import "BrowserSubtitlePipeline.h"

#import "BrowserSubtitleTranslator.h"

static NSString * const kPipelineLogPrefix = @"[Subtitles]";
static const double kPipelineSampleRate = 16000.0;
static const NSTimeInterval kPipelineCoverageUnit = 0.1;   // Raster der Abdeckung (s)

/// Ein Auswertungsabschnitt.
@interface BrowserSubtitleWindow : NSObject
@property (nonatomic, strong) NSData *samples;
@property (nonatomic) NSTimeInterval start;
@property (nonatomic) NSTimeInterval end;
@property (nonatomic) NSTimeInterval acceptFrom;
@property (nonatomic) NSTimeInterval acceptUntil;
@property (nonatomic) BOOL final;
@property (nonatomic) BOOL firstOfRun;
@property (nonatomic) NSUInteger generation;
/// An der Live-Kante abgeschnitten (Live-HLS): Übersetzung mit kurzer Frist wie beim Mithören.
@property (nonatomic) BOOL atLiveEdge;
/// Vorauslesend: Ergebnis liegt vor (erkannt und ggf. übersetzt), `cues` nil = nichts zu übernehmen.
@property (nonatomic) BOOL ready;
@property (nonatomic, strong, nullable) NSArray<BrowserSubtitleCue *> *cues;
@end

@implementation BrowserSubtitleWindow
@end

NSString *BrowserSubtitleOffsetSummary(NSArray<NSNumber *> *offsets) {
    if (offsets.count == 0) {
        return @"Versatz: keine Messung";
    }
    NSArray<NSNumber *> *sorted = [offsets sortedArrayUsingSelector:@selector(compare:)];
    double median = sorted[sorted.count / 2].doubleValue;
    if (sorted.count % 2 == 0) {
        median = (median + sorted[sorted.count / 2 - 1].doubleValue) / 2.0;
    }
    double maxAbs = 0.0;
    NSUInteger within = 0;
    for (NSNumber *value in sorted) {
        maxAbs = MAX(maxAbs, fabs(value.doubleValue));
        within += fabs(value.doubleValue) <= 1.0 ? 1 : 0;
    }
    return [NSString stringWithFormat:@"Versatz: n=%lu, Median %+.2f s, min %+.2f, max %+.2f, max |Δ| %.2f s, ≤ 1 s: %lu (%.0f %%)",
            (unsigned long)sorted.count, median, sorted.firstObject.doubleValue, sorted.lastObject.doubleValue, maxAbs,
            (unsigned long)within, 100.0 * within / sorted.count];
}

@interface BrowserSubtitlePipeline ()
@property (nonatomic, copy) BrowserSubtitleTranscriber transcriber;
@property (nonatomic, strong) dispatch_queue_t queue;
// Nur auf queue:
@property (nonatomic, weak, nullable) id<BrowserSubtitleAudioSource> source;
@property (nonatomic, readwrite) BOOL live;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic) NSTimeInterval bufferStart;
@property (nonatomic) BOOL hasBuffer;
@property (nonatomic, strong) NSMutableArray<BrowserSubtitleWindow *> *pendingWindows;
@property (nonatomic) BOOL engineBusy;
@property (nonatomic, strong) NSMutableIndexSet *covered;
@property (nonatomic) BOOL firstWindowOfRun;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSTimeInterval lastSubmitEnd;
@property (nonatomic) BOOL liveFlushRequested;
@property (nonatomic, readwrite) NSUInteger processedWindows;
@property (nonatomic, readwrite) NSUInteger droppedWindows;
/// Vorauslesend: erkannte Abschnitte in Reihenfolge, bis ihre Übersetzung da ist (whisper rechnet derweil weiter).
@property (nonatomic, strong) NSMutableArray<BrowserSubtitleWindow *> *finishingWindows;
/// Mithören: Übersetzung des letzten Durchlaufs läuft (kein neuer Durchlauf auf demselben Ton).
@property (nonatomic) BOOL liveTranslating;
/// Zuletzt erkannte Originalsätze (Kontext „vorheriger Satz“ für Apples Übersetzung).
@property (nonatomic, strong) NSMutableArray<BrowserSubtitleCue *> *recentSourceCues;
/// Vorauslesend zuletzt übernommene Untertitel (Doppelte an Abschnittsgrenzen erkennen, seit DTW-Zeiten).
@property (nonatomic, strong) NSMutableArray<BrowserSubtitleCue *> *acceptedAheadCues;
@end

@implementation BrowserSubtitlePipeline

- (instancetype)initWithTranscriber:(BrowserSubtitleTranscriber)transcriber {
    self = [super init];
    if (self) {
        _transcriber = [transcriber copy];
        _queue = dispatch_queue_create("tvbrowser.subtitles.processing", DISPATCH_QUEUE_SERIAL);
        _buffer = [NSMutableData data];
        _pendingWindows = [NSMutableArray array];
        _covered = [NSMutableIndexSet indexSet];
        _windowSeconds = 12.0;
        _overlapSeconds = 1.5;
        _firstWindowSeconds = 4.0;
        _liveStepSeconds = 1.0;
        _liveMaxWindowSeconds = 8.0;
        _liveHoldbackSeconds = 1.0;
        _translationTimeout = 4.0;
        _liveTranslationTimeout = 0.5;
        _finishingWindows = [NSMutableArray array];
        _recentSourceCues = [NSMutableArray array];
        _acceptedAheadCues = [NSMutableArray array];
    }
    return self;
}

- (void)attachSource:(id<BrowserSubtitleAudioSource>)source {
    BOOL live = !source.deliversAhead;
    dispatch_sync(self.queue, ^{
        self.source = source;
        self.live = live;
        self.generation++;
        self.firstWindowOfRun = YES;
        self.lastSubmitEnd = -INFINITY;
        self.liveFlushRequested = NO;
        self.liveTranslating = NO;
        [self resetBuffer];
        [self.pendingWindows removeAllObjects];
        [self.finishingWindows removeAllObjects];
        [self.recentSourceCues removeAllObjects];
        [self.acceptedAheadCues removeAllObjects];
    });
    source.delegate = self;
}

- (void)detachSource {
    dispatch_sync(self.queue, ^{
        self.source = nil;
        self.generation++;
        self.liveTranslating = NO;
        [self.pendingWindows removeAllObjects];
        [self.finishingWindows removeAllObjects];
        [self resetBuffer];
    });
}

- (void)clearCoverage {
    dispatch_sync(self.queue, ^{
        [self.covered removeAllIndexes];
        [self.acceptedAheadCues removeAllObjects];   // neu erkannte Stelle ist kein Doppel
    });
}

- (NSUInteger)pendingWindowCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.queue, ^{
        count = self.pendingWindows.count;
    });
    return count;
}

#pragma mark Puffer (queue)

- (void)resetBuffer {
    self.buffer = [NSMutableData data];
    self.hasBuffer = NO;
    self.bufferStart = 0.0;
}

- (NSTimeInterval)bufferedSeconds {
    return (double)(self.buffer.length / sizeof(float)) / kPipelineSampleRate;
}

- (void)dropBufferedSeconds:(NSTimeInterval)seconds {
    NSUInteger samples = MIN(self.buffer.length / sizeof(float), (NSUInteger)llround(MAX(0.0, seconds) * kPipelineSampleRate));
    [self.buffer replaceBytesInRange:NSMakeRange(0, samples * sizeof(float)) withBytes:NULL length:0];
    self.bufferStart += (double)samples / kPipelineSampleRate;
}

#pragma mark BrowserSubtitleAudioSourceDelegate

- (void)audioSource:(id<BrowserSubtitleAudioSource>)source didProduceSamples:(NSData *)samples atTime:(NSTimeInterval)mediaTime discontinuity:(BOOL)discontinuity {
    dispatch_async(self.queue, ^{
        if (source != self.source || samples.length == 0) {
            return;
        }
        NSTimeInterval expectedEnd = self.bufferStart + [self bufferedSeconds];
        if (discontinuity || !self.hasBuffer || fabs(mediaTime - expectedEnd) > 0.3) {
            if (!self.live && self.hasBuffer && [self bufferedSeconds] >= 1.5) {
                [self submitAheadWindowOfLength:self.buffer.length final:YES];
            }
            if (self.live) {
                self.generation++;  // laufender Durchlauf gehört zur alten Stelle
                self.lastSubmitEnd = -INFINITY;
            }
            [self resetBuffer];
            self.bufferStart = mediaTime;
            self.hasBuffer = YES;
            self.firstWindowOfRun = YES;
        } else {
            // An die Zeit der Quelle anlehnen, damit sich Rundungen nicht aufsummieren.
            self.bufferStart += mediaTime - expectedEnd;
        }
        [self.buffer appendData:samples];
        if (self.live) {
            [self pumpLive];
        } else {
            [self cutAheadWindows];
        }
    });
}

- (void)audioSource:(id<BrowserSubtitleAudioSource>)source didFailWithReason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.failureHandler != nil) {
            self.failureHandler(source, reason);
        }
    });
}

- (NSTimeInterval)audioSourcePendingSeconds:(id<BrowserSubtitleAudioSource>)source {
    __block NSTimeInterval pending = 0.0;
    dispatch_sync(self.queue, ^{
        pending = [self bufferedSeconds] + (self.pendingWindows.count + self.finishingWindows.count) * (self.windowSeconds - self.overlapSeconds) +
                  (self.engineBusy ? self.windowSeconds : 0.0);
    });
    return pending;
}

- (BOOL)audioSource:(id<BrowserSubtitleAudioSource>)source isRangeCoveredFrom:(NSTimeInterval)start to:(NSTimeInterval)end {
    __block BOOL covered = NO;
    dispatch_sync(self.queue, ^{
        NSUInteger first = (NSUInteger)ceil(MAX(0.0, start) / kPipelineCoverageUnit);
        NSUInteger last = (NSUInteger)floor(MAX(0.0, end) / kPipelineCoverageUnit);
        covered = last > first && [self.covered containsIndexesInRange:NSMakeRange(first, last - first)];
    });
    return covered;
}

- (void)audioSourceDidReachLiveEdge:(id<BrowserSubtitleAudioSource>)source {
    dispatch_async(self.queue, ^{
        // Ab 3 s Angefangenes auswerten (Satzpause in der letzten Sekunde suchen), das Ende überlappt wie sonst. Live
        // liegt die Kante nur ~3 Zielzeiten vor der Wiedergabe; mit 4 s kamen Abschnitte im Simulator ~1 s zu spät.
        if (source != self.source || self.live || !self.hasBuffer || [self bufferedSeconds] < 3.0) {
            return;
        }
        NSUInteger length = self.buffer.length / sizeof(float);
        NSUInteger cut = [self quietCutBefore:length search:1.0];
        [self submitAheadWindowOfLength:cut * sizeof(float) final:NO atLiveEdge:YES];
        [self dropBufferedSeconds:MAX(0.5, (double)cut / kPipelineSampleRate - self.overlapSeconds)];
        self.firstWindowOfRun = NO;
    });
}

- (void)flushPartial {
    dispatch_async(self.queue, ^{
        if (self.source == nil || !self.hasBuffer) {
            return;
        }
        if (self.live) {
            self.liveFlushRequested = YES;
            [self pumpLive];
            return;
        }
        if ([self bufferedSeconds] < 1.5) {
            return;
        }
        [self submitAheadWindowOfLength:self.buffer.length final:YES];
        NSTimeInterval end = self.bufferStart + [self bufferedSeconds];
        [self resetBuffer];
        self.bufferStart = end;
    });
}

#pragma mark Vorauslesen (queue)

/// Leiseste 50-ms-Stelle in den letzten `search` Sekunden vor `length` Samples (Satzpause), als Sampleanzahl.
- (NSUInteger)quietCutBefore:(NSUInteger)length search:(NSTimeInterval)search {
    const float *samples = self.buffer.bytes;
    const NSUInteger frame = 800;
    NSUInteger searchSamples = (NSUInteger)(search * kPipelineSampleRate);
    if (length < searchSamples + frame) {
        return length;
    }
    NSUInteger bestEnd = length;
    double bestEnergy = INFINITY;
    for (NSUInteger end = length; end >= length - searchSamples + frame; end -= frame / 2) {
        double energy = 0.0;
        for (NSUInteger k = end - frame; k < end; k++) {
            energy += (double)samples[k] * (double)samples[k];
        }
        // Leicht späte Stellen bevorzugen (längerer Abschnitt), sonst gewinnt bei gleicher Stille die früheste.
        energy *= 1.0 + 0.1 * (double)(length - end) / (double)searchSamples;
        if (energy < bestEnergy) {
            bestEnergy = energy;
            bestEnd = end - frame / 2;
        }
    }
    return bestEnd;
}

- (void)cutAheadWindows {
    while (YES) {
        NSTimeInterval seconds = self.firstWindowOfRun ? self.firstWindowSeconds : self.windowSeconds;
        NSUInteger windowSamples = (NSUInteger)(seconds * kPipelineSampleRate);
        if (self.buffer.length < windowSamples * sizeof(float)) {
            return;
        }
        NSUInteger cut = [self quietCutBefore:windowSamples search:MIN(1.5, seconds * 0.25)];
        [self submitAheadWindowOfLength:cut * sizeof(float) final:NO];
        NSTimeInterval step = (double)cut / kPipelineSampleRate - self.overlapSeconds;
        [self dropBufferedSeconds:MAX(0.5, step)];
        self.firstWindowOfRun = NO;
    }
}

- (void)submitAheadWindowOfLength:(NSUInteger)length final:(BOOL)final {
    [self submitAheadWindowOfLength:length final:final atLiveEdge:NO];
}

- (void)submitAheadWindowOfLength:(NSUInteger)length final:(BOOL)final atLiveEdge:(BOOL)atLiveEdge {
    BrowserSubtitleWindow *window = [BrowserSubtitleWindow new];
    window.atLiveEdge = atLiveEdge;
    window.samples = [self.buffer subdataWithRange:NSMakeRange(0, length)];
    window.start = self.bufferStart;
    window.end = self.bufferStart + (double)(length / sizeof(float)) / kPipelineSampleRate;
    window.acceptFrom = window.start;
    window.acceptUntil = final ? window.end : window.end - self.overlapSeconds / 2.0;
    window.final = final;
    window.firstOfRun = self.firstWindowOfRun;
    window.generation = self.generation;

    NSUInteger first = (NSUInteger)ceil(MAX(0.0, window.acceptFrom) / kPipelineCoverageUnit);
    NSUInteger last = (NSUInteger)floor(MAX(0.0, window.acceptUntil) / kPipelineCoverageUnit);
    if (last > first && [self.covered containsIndexesInRange:NSMakeRange(first, last - first)]) {
        if (window.firstOfRun) {
            [self reportFirstWindow:window];  // Stelle schon erkannt (z. B. Zurückspulen): Start nicht aufhalten
        }
        return;
    }
    [self.pendingWindows addObject:window];
    [self pumpAhead];
}

- (void)reportFirstWindow:(BrowserSubtitleWindow *)window {
    NSTimeInterval start = window.start, end = window.end;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.firstWindowHandler != nil) {
            self.firstWindowHandler(start, end);
        }
    });
}

- (void)pumpAhead {
    if (self.engineBusy || self.pendingWindows.count == 0) {
        return;
    }
    BrowserSubtitleWindow *window = self.pendingWindows.firstObject;
    [self.pendingWindows removeObjectAtIndex:0];
    [self runWindow:window completion:^(NSArray<BrowserSubtitleCue *> *cues) {
        [self finishAheadWindow:window cues:cues];
        [self pumpAhead];   // whisper rechnet den nächsten Abschnitt, während Apple diesen übersetzt
    }];
}

/// Vorauslesend: übersetzen (falls nötig), Ergebnisse in Abschnittsreihenfolge übernehmen.
- (void)finishAheadWindow:(BrowserSubtitleWindow *)window cues:(nullable NSArray<BrowserSubtitleCue *> *)cues {
    [self.finishingWindows addObject:window];
    if (cues == nil || ![self cuesNeedTranslation:cues]) {
        [self rememberSourceCues:cues windowStart:window.start];
        [self markWindow:window ready:cues];
        return;
    }
    [self translateAheadWindow:window cues:cues attempt:1];
}

- (void)translateAheadWindow:(BrowserSubtitleWindow *)window cues:(NSArray<BrowserSubtitleCue *> *)cues attempt:(NSUInteger)attempt {
    NSUInteger generation = self.generation;
    NSTimeInterval timeout = window.atLiveEdge ? self.liveTranslationTimeout : self.translationTimeout;
    [self translateCues:cues timeout:timeout completion:^(NSArray<BrowserSubtitleCue *> *translated, NSString *failure) {
        if (generation != self.generation || self.source == nil) {
            return;
        }
        if (translated != nil) {
            [self markWindow:window ready:translated];
            return;
        }
        if (window.atLiveEdge) {
            // Live-Kante: für einen zweiten whisper-Lauf ist keine Zeit, der Satz kommt im Original.
            NSLog(@"%@ Rückfall whisper: Abschnitt %.1f–%.1f s im Originaltext (%@)", kPipelineLogPrefix, window.start, window.end, failure);
            [self markWindow:window ready:[self untranslatedCues:cues]];
            return;
        }
        if (attempt == 1 && !BrowserSubtitleTranslator.sharedTranslator.suspended) {
            // Einzelne verpasste Frist (Apple nicht ausgesetzt): vorauslesend ist Zeit für einen zweiten Versuch.
            NSLog(@"%@ Apple-Übersetzung: Abschnitt %.1f–%.1f s noch einmal (%@)", kPipelineLogPrefix, window.start, window.end, failure);
            [self translateAheadWindow:window cues:cues attempt:2];
            return;
        }
        // Vorauslesend ist Zeit: denselben Abschnitt noch einmal erkennen, Apple ist jetzt ausgesetzt, whisper
        // übersetzt also selbst (bisheriger Weg). Kommt auch da nichts, bleibt der Originaltext.
        NSLog(@"%@ Rückfall whisper: Abschnitt %.1f–%.1f s wird von whisper übersetzt (%@)", kPipelineLogPrefix, window.start, window.end, failure);
        self.transcriber(window.samples, window.start, ^(NSArray<BrowserSubtitleCue *> *again) {
            dispatch_async(self.queue, ^{
                if (generation != self.generation || self.source == nil) {
                    return;
                }
                BOOL usable = again != nil && ![self cuesNeedTranslation:again];
                [self markWindow:window ready:usable ? again : [self untranslatedCues:cues]];
            });
        });
    }];
}

- (void)markWindow:(BrowserSubtitleWindow *)window ready:(nullable NSArray<BrowserSubtitleCue *> *)cues {
    window.cues = cues;
    window.ready = YES;
    while (self.finishingWindows.count > 0 && self.finishingWindows.firstObject.ready) {
        BrowserSubtitleWindow *next = self.finishingWindows.firstObject;
        [self.finishingWindows removeObjectAtIndex:0];
        if (next.cues != nil) {
            [self acceptAheadCues:next.cues fromWindow:next];
        }
        if (next.firstOfRun) {
            [self reportFirstWindow:next];
        }
    }
}

#pragma mark Übersetzung (queue)

- (BOOL)cuesNeedTranslation:(NSArray<BrowserSubtitleCue *> *)cues {
    for (BrowserSubtitleCue *cue in cues) {
        if (cue.translationTarget != nil) {
            return YES;
        }
    }
    return NO;
}

/// Originaltext anzeigen (Übersetzung gescheitert): Markierung entfernen, Text bleibt.
- (NSArray<BrowserSubtitleCue *> *)untranslatedCues:(NSArray<BrowserSubtitleCue *> *)cues {
    for (BrowserSubtitleCue *cue in cues) {
        cue.translationTarget = nil;
    }
    return cues;
}

/// Originalsätze merken (für den Kontext des nächsten Stapels). Ältere Fassung desselben Bereichs ersetzen.
- (void)rememberSourceCues:(nullable NSArray<BrowserSubtitleCue *> *)cues windowStart:(NSTimeInterval)windowStart {
    if (cues.count == 0) {
        return;
    }
    NSIndexSet *stale = [self.recentSourceCues indexesOfObjectsPassingTest:^BOOL(BrowserSubtitleCue *cue, NSUInteger index, BOOL *stop) {
        return cue.start >= windowStart - 0.05;
    }];
    [self.recentSourceCues removeObjectsAtIndexes:stale];
    for (BrowserSubtitleCue *cue in cues) {
        BrowserSubtitleCue *original = [[BrowserSubtitleCue alloc] initWithStart:cue.start end:cue.end text:cue.originalText ?: cue.text];
        original.language = cue.originalText != nil ? nil : cue.language;
        [self.recentSourceCues addObject:original];
    }
    if (self.recentSourceCues.count > 12) {
        [self.recentSourceCues removeObjectsInRange:NSMakeRange(0, self.recentSourceCues.count - 12)];
    }
}

/// Vorheriger Satz vor `time` in `language` (höchstens 12 s alt, ≤ 200 Zeichen), sonst nil.
- (nullable NSString *)sourceContextBeforeTime:(NSTimeInterval)time language:(NSString *)language {
    for (BrowserSubtitleCue *cue in self.recentSourceCues.reverseObjectEnumerator) {
        if (cue.end > time + 0.1) {
            continue;
        }
        if (cue.end < time - 12.0 || ![cue.language isEqualToString:language] || cue.text.length > 200) {
            return nil;
        }
        return cue.text;
    }
    return nil;
}

/// Übersetzt alle markierten Untertitel eines Abschnitts in einer Anfrage, mit dem vorherigen Satz als Kontext.
/// `completion` auf queue: übersetzte Untertitel (gleiche Reihenfolge) oder nil mit Grund.
- (void)translateCues:(NSArray<BrowserSubtitleCue *> *)cues timeout:(NSTimeInterval)timeout
           completion:(void (^)(NSArray<BrowserSubtitleCue *> * _Nullable translated, NSString * _Nullable failure))completion {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    NSString *language = nil, *target = nil;
    NSTimeInterval firstStart = INFINITY;
    for (NSUInteger i = 0; i < cues.count; i++) {
        BrowserSubtitleCue *cue = cues[i];
        if (cue.translationTarget == nil || cue.language == nil) {
            continue;
        }
        if (language == nil) {
            language = cue.language;
            target = cue.translationTarget;
        }
        [texts addObject:cue.text];
        [indexes addIndex:i];
        firstStart = MIN(firstStart, cue.start);
    }
    if (language == nil) {
        completion([self untranslatedCues:cues], nil);
        return;
    }
    NSString *context = [self sourceContextBeforeTime:firstStart language:language];
    [self rememberSourceCues:cues windowStart:cues.firstObject.start];
    dispatch_queue_t queue = self.queue;
    [BrowserSubtitleTranslator.sharedTranslator translateTexts:texts from:language to:target context:context timeout:timeout
                                                    completion:^(NSArray<NSString *> *translated, NSString *failure) {
        dispatch_async(queue, ^{
            if (translated.count != texts.count) {
                completion(nil, failure ?: @"keine Übersetzung");
                return;
            }
            NSMutableArray<BrowserSubtitleCue *> *result = [cues mutableCopy];
            __block NSUInteger k = 0;
            [indexes enumerateIndexesUsingBlock:^(NSUInteger index, __unused BOOL *stop) {
                result[index] = [cues[index] cueWithTranslatedText:translated[k++]];
            }];
            completion(result, nil);
        });
    }];
}

/// Läuft die Erkennung für `window`; `completion` auf queue (cues nil bei Abbruch oder veraltet).
- (void)runWindow:(BrowserSubtitleWindow *)window completion:(void (^)(NSArray<BrowserSubtitleCue *> * _Nullable cues))completion {
    self.engineBusy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_queue_t queue = self.queue;
    self.transcriber(window.samples, window.start, ^(NSArray<BrowserSubtitleCue *> *cues) {
        dispatch_async(queue, ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.engineBusy = NO;
            if (cues != nil && strongSelf.source != nil) {
                strongSelf.processedWindows++;
            }
            completion(strongSelf.source != nil ? cues : nil);
        });
    });
}

/// Derselbe Satz aus zwei überlappenden Abschnitten: Mit DTW-Wortzeiten liegt seine Mitte mal knapp vor, mal knapp
/// hinter der Abschnittsgrenze, die Abdeckung nach Mitte fängt das nicht (am Apple TV kam „Ich habe euch gestern Abend
/// reden hören.“ zweimal). Zeitlich zu mehr als der Hälfte des kürzeren in einem übernommenen: doppelt.
- (BOOL)overlapsAcceptedAheadCue:(BrowserSubtitleCue *)cue {
    for (BrowserSubtitleCue *other in self.acceptedAheadCues.reverseObjectEnumerator) {
        if (other.end < cue.start - 30.0) {
            break;
        }
        double overlap = MIN(cue.end, other.end) - MAX(cue.start, other.start);
        double shorter = MIN(cue.end - cue.start, other.end - other.start);
        if (shorter > 0.0 && overlap > 0.5 * shorter) {
            return YES;
        }
    }
    return NO;
}

- (void)acceptAheadCues:(NSArray<BrowserSubtitleCue *> *)cues fromWindow:(BrowserSubtitleWindow *)window {
    NSMutableArray<BrowserSubtitleCue *> *accepted = [NSMutableArray array];
    for (BrowserSubtitleCue *cue in cues) {
        NSTimeInterval middle = (cue.start + cue.end) / 2.0;
        if (middle < window.acceptFrom || middle >= window.acceptUntil) {
#if DEBUG
            NSLog(@"%@ Untertitel %.2f–%.2f s außerhalb %.2f–%.2f s, verworfen: %@", kPipelineLogPrefix, cue.start, cue.end,
                  window.acceptFrom, window.acceptUntil, cue.text);
#endif
            continue;  // gehört zum Nachbarabschnitt (Überlappung)
        }
        if ([self.covered containsIndex:(NSUInteger)floor(MAX(0.0, middle) / kPipelineCoverageUnit)]) {
#if DEBUG
            NSLog(@"%@ Untertitel %.2f–%.2f s schon abgedeckt, verworfen: %@", kPipelineLogPrefix, cue.start, cue.end, cue.text);
#endif
            continue;  // schon von einem früheren Abschnitt
        }
        if ([self overlapsAcceptedAheadCue:cue]) {
#if DEBUG
            NSLog(@"%@ Untertitel %.2f–%.2f s doppelt (Abschnittsgrenze), verworfen: %@", kPipelineLogPrefix, cue.start, cue.end, cue.text);
#endif
            continue;
        }
#if DEBUG
        NSLog(@"%@ Untertitel %.2f–%.2f s: %@", kPipelineLogPrefix, cue.start, cue.end, cue.text);
#endif
        [self.acceptedAheadCues addObject:cue];
        [accepted addObject:cue];
    }
    if (self.acceptedAheadCues.count > 40) {
        [self.acceptedAheadCues removeObjectsInRange:NSMakeRange(0, self.acceptedAheadCues.count - 40)];
    }
    NSUInteger first = (NSUInteger)ceil(MAX(0.0, window.acceptFrom) / kPipelineCoverageUnit);
    NSUInteger last = (NSUInteger)floor(MAX(0.0, window.acceptUntil) / kPipelineCoverageUnit);
    if (last > first) {
        [self.covered addIndexesInRange:NSMakeRange(first, last - first)];
    }
    [self emitCues:accepted replaceFrom:NAN window:window];
}

- (void)emitCues:(NSArray<BrowserSubtitleCue *> *)cues replaceFrom:(NSTimeInterval)replaceFrom window:(BrowserSubtitleWindow *)window {
    if (cues.count == 0 && isnan(replaceFrom)) {
        return;
    }
    NSTimeInterval start = window.start, end = window.end;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.cueHandler != nil) {
            self.cueHandler(cues, replaceFrom, start, end);
        }
    });
}

#pragma mark Mithören (queue)

- (void)pumpLive {
    if (self.engineBusy || self.liveTranslating || !self.hasBuffer) {
        return;
    }
    NSTimeInterval buffered = [self bufferedSeconds];
    NSTimeInterval end = self.bufferStart + buffered;
    BOOL flush = self.liveFlushRequested;
    if (!flush && (buffered < 1.0 || end - self.lastSubmitEnd < self.liveStepSeconds)) {
        return;
    }
    if (flush && buffered < 0.5) {
        self.liveFlushRequested = NO;
        return;
    }
    if (buffered > self.liveMaxWindowSeconds) {
        // Kein Satzende gefunden (Dauerrede, Musik): Ältestes verwerfen, was schon gezeigt wurde, bleibt stehen.
        [self dropBufferedSeconds:buffered - self.liveMaxWindowSeconds];
        self.droppedWindows++;
    }
    self.liveFlushRequested = NO;
    BrowserSubtitleWindow *window = [BrowserSubtitleWindow new];
    window.samples = [self.buffer copy];
    window.start = self.bufferStart;
    window.end = self.bufferStart + [self bufferedSeconds];
    window.final = flush;
    window.firstOfRun = self.firstWindowOfRun;
    window.generation = self.generation;
    self.lastSubmitEnd = window.end;
    self.firstWindowOfRun = NO;
    [self runWindow:window completion:^(NSArray<BrowserSubtitleCue *> *cues) {
        if (cues == nil || window.generation != self.generation) {
            [self pumpLive];
            return;
        }
        if (![self cuesNeedTranslation:cues]) {
            [self rememberSourceCues:cues windowStart:window.start];
            [self acceptLiveCues:cues fromWindow:window];
            [self pumpLive];
            return;
        }
        // Mithören: Apple bekommt höchstens liveTranslationTimeout (0,5 s), sonst Originaltext; der nächste
        // Durchlauf wartet so lange (er würde denselben offenen Satz noch einmal rechnen).
        self.liveTranslating = YES;
        [self translateCues:cues timeout:self.liveTranslationTimeout completion:^(NSArray<BrowserSubtitleCue *> *translated, NSString *failure) {
            self.liveTranslating = NO;
            if (window.generation == self.generation && self.source != nil) {
                if (translated == nil) {
                    NSLog(@"%@ Rückfall whisper: Mithören %.1f–%.1f s im Originaltext (%@)", kPipelineLogPrefix, window.start, window.end, failure);
                }
                [self acceptLiveCues:translated ?: [self untranslatedCues:cues] fromWindow:window];
            }
            [self pumpLive];
        }];
    }];
}

- (void)acceptLiveCues:(NSArray<BrowserSubtitleCue *> *)cues fromWindow:(BrowserSubtitleWindow *)window {
    NSArray<BrowserSubtitleCue *> *sorted = [cues sortedArrayUsingComparator:^NSComparisonResult(BrowserSubtitleCue *a, BrowserSubtitleCue *b) {
        return [@(a.start) compare:@(b.start)];
    }];
    NSUInteger finalCount = 0;
    if (window.final) {
        finalCount = sorted.count;
    } else {
        NSTimeInterval holdback = window.end - self.liveHoldbackSeconds;
        while (finalCount + 1 < sorted.count && sorted[finalCount].end <= holdback) {
            finalCount++;
        }
    }
    NSTimeInterval commit = -INFINITY;
    if (finalCount > 0) {
        commit = sorted[finalCount - 1].end;
    } else if (sorted.count == 0 && window.end - window.start >= 3.0) {
        commit = window.end - 1.0;   // nichts erkannt (Stille, Musik): bis kurz vor Schluss nicht noch einmal rechnen
    }
    if (window.final) {
        commit = window.end;
    }
    for (NSUInteger i = 0; i < sorted.count; i++) {
        sorted[i].tentative = i >= finalCount;
    }
    if (commit > self.bufferStart) {
        [self dropBufferedSeconds:commit - self.bufferStart];
    }
    [self emitCues:sorted replaceFrom:window.start - 0.05 window:window];
}

@end
