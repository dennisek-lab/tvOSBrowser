#import "BrowserWhisperSpeechRecognizer.h"

#import "BrowserSubtitleEngine.h"

#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <stdatomic.h>

static NSString * const kWhisperWebLogPrefix = @"[WebSubs][whisper]";

/// Wörter für den Vergleich an der Überlappung: klein, ohne Satzzeichen.
static NSArray<NSString *> *BrowserWhisperWords(NSString *text) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *token in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (token.length > 0) {
            [words addObject:token];
        }
    }
    return words;
}

static NSString *BrowserWhisperNormalizedWord(NSString *word) {
    NSString *trimmed = [word stringByTrimmingCharactersInSet:NSCharacterSet.punctuationCharacterSet];
    return trimmed.lowercaseString;
}

/// Wiederholungsschleifen von whisper zusammenfalten („I'm gonna be I'm gonna be I'm gonna be …“ → einmal):
/// je Periode (1–8 Wörter) wird eine mindestens dreifache Wiederholung am Stück auf ein Vorkommen gekürzt.
static NSArray<NSString *> *BrowserWhisperCollapseRepeats(NSArray<NSString *> *words) {
    NSMutableArray<NSString *> *result = [words mutableCopy];
    for (NSUInteger period = 1; period <= 8; period++) {
        NSUInteger i = 0;
        while (i + period * 3 <= result.count) {
            NSUInteger repeats = 1;
            while (i + period * (repeats + 1) <= result.count) {
                BOOL same = YES;
                for (NSUInteger j = 0; j < period && same; j++) {
                    same = [BrowserWhisperNormalizedWord(result[i + j])
                            isEqualToString:BrowserWhisperNormalizedWord(result[i + period * repeats + j])];
                }
                if (!same) {
                    break;
                }
                repeats++;
            }
            if (repeats >= 3) {
                [result removeObjectsInRange:NSMakeRange(i + period, period * (repeats - 1))];
            }
            i++;
        }
    }
    return result;
}

@interface BrowserWhisperSpeechRecognizer ()
@property (nonatomic, copy, readwrite) NSString *language;
@property (nonatomic, copy, readwrite) NSString *modelName;
@property (nonatomic, copy) NSString *modelPath;
@end

@implementation BrowserWhisperSpeechRecognizer {
    dispatch_queue_t _engineQueue;
    _Atomic(NSUInteger) _generation;
    // Nur auf _engineQueue:
    BrowserSubtitleEngine *_engine;
    BOOL _reportedLoad;
    NSUInteger _useToken;
    NSArray<NSString *> *_previousWords;
    NSTimeInterval _previousEnd;
    NSMutableArray<NSArray *> *_recentCues;  // [normalisierter Text, Start]
    // Unter _statsLock (der Zeiger auf _engine wird nur auf _engineQueue geändert, gelesen auch von reset):
    os_unfair_lock _statsLock;
    double _totalCompute;
    double _totalAudio;
}

+ (BOOL)isAvailableForLanguage:(NSString *)language {
    return [self unavailableReasonForLanguage:language] == nil;
}

+ (NSString *)unavailableReasonForLanguage:(NSString *)language {
    if (![BrowserSubtitleEngine isCompiledWithWhisper]) {
        return @"whisper fehlt im Build";
    }
    if ([BrowserSubtitleEngine modelPathForLanguage:language.length > 0 ? language : @"en"] == nil) {
        return @"kein Sprachmodell in der App";
    }
    return nil;
}

- (instancetype)initWithLanguage:(NSString *)language {
    NSString *effective = language.length > 0 ? [language copy] : @"en";
    NSString *modelPath = [BrowserSubtitleEngine isCompiledWithWhisper] ? [BrowserSubtitleEngine modelPathForLanguage:effective] : nil;
    if (modelPath == nil) {
        return nil;
    }
    self = [super init];
    if (self) {
        _language = effective;
        _modelPath = [modelPath copy];
        _modelName = [[modelPath.lastPathComponent stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"ggml-" withString:@""];
        _preferredWindowDuration = 3.0;
        _preferredOverlapDuration = 0.5;
        _idleUnloadDelay = 90.0;
        _statsLock = OS_UNFAIR_LOCK_INIT;
        _previousEnd = -1.0;
        _recentCues = [NSMutableArray array];
        atomic_store(&_generation, 0);
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _engineQueue = dispatch_queue_create("io.github.tvosbrowser.app.websubtitles.whisper", attributes);
        // Gleich im Hintergrund laden, damit der erste Abschnitt nicht auf das Modell wartet.
        dispatch_async(_engineQueue, ^{
            [self ensureEngineLoaded];
        });
    }
    return self;
}

- (NSString *)recognizerName {
    return [NSString stringWithFormat:@"whisper %@ (%@)", self.modelName, self.language];
}

- (NSString *)lockedLanguage {
    return [self lockedEngine].lockedLanguage;
}

- (double)averageRealTimeFactor {
    os_unfair_lock_lock(&_statsLock);
    double factor = _totalAudio > 0.0 ? _totalCompute / _totalAudio : 0.0;
    os_unfair_lock_unlock(&_statsLock);
    return factor;
}

#pragma mark - Modell (nur _engineQueue)

- (void)setEngine:(BrowserSubtitleEngine *)engine {
    BrowserSubtitleEngine *old = nil;
    os_unfair_lock_lock(&_statsLock);
    old = _engine;
    _engine = engine;
    os_unfair_lock_unlock(&_statsLock);
    old = nil;  // außerhalb der Sperre freigeben (whisper_free dauert)
}

- (BrowserSubtitleEngine *)lockedEngine {
    os_unfair_lock_lock(&_statsLock);
    BrowserSubtitleEngine *engine = _engine;
    os_unfair_lock_unlock(&_statsLock);
    return engine;
}

- (BOOL)ensureEngineLoaded {
    if (_engine != nil && _engine.loaded) {
        return YES;
    }
    if (_engine == nil) {
        [self setEngine:[[BrowserSubtitleEngine alloc] initWithModelPath:self.modelPath language:self.language]];
    }
    CFTimeInterval begin = CACurrentMediaTime();
    NSError *error = nil;
    BOOL loaded = [_engine loadModel:&error];
    NSLog(@"%@ Modell %@ %@ in %.2f s, Speicher %.0f MB", kWhisperWebLogPrefix, self.modelName,
          loaded ? @"bereit" : @"FEHLER", CACurrentMediaTime() - begin, [BrowserSubtitleEngine currentMemoryFootprintMB]);
    if (!loaded) {
        [self setEngine:nil];
    }
    if (!_reportedLoad || !loaded) {
        _reportedLoad = loaded;
        void (^handler)(BOOL, NSString *) = self.loadHandler;
        if (handler != nil) {
            NSString *message = loaded
                ? [NSString stringWithFormat:@"Untertitel: Spracherkennung bereit (%@)", self.modelName]
                : [NSString stringWithFormat:@"Untertitel: %@", error.localizedDescription ?: @"Modell konnte nicht geladen werden"];
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(loaded, message);
            });
        }
    }
    return loaded;
}

- (void)scheduleIdleUnload {
    NSTimeInterval delay = self.idleUnloadDelay;
    if (delay <= 0.0) {
        return;
    }
    NSUInteger token = ++_useToken;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _engineQueue, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_useToken != token || strongSelf->_engine == nil) {
            return;
        }
        NSLog(@"%@ %.0f s ohne Abschnitt, Modell wird freigegeben", kWhisperWebLogPrefix, delay);
        [strongSelf setEngine:nil];  // dealloc gibt den whisper-Kontext frei (Log „Modell freigegeben“)
    });
}

#pragma mark - BrowserSpeechRecognizing

- (void)transcribeSamples:(const float *)samples
                    count:(NSUInteger)count
                startTime:(NSTimeInterval)startTime
               completion:(void (^)(NSArray<BrowserWebSubtitleCue *> *))completion {
    // `samples` gilt nur während des Aufrufs: kopieren, dann auf der eigenen Queue rechnen.
    NSData *copy = samples != NULL && count > 0 ? [NSData dataWithBytes:samples length:count * sizeof(float)] : nil;
    NSUInteger generation = atomic_load(&_generation);
    CFTimeInterval submitted = CACurrentMediaTime();
    dispatch_async(_engineQueue, ^{
        NSArray<BrowserWebSubtitleCue *> *result = @[];
        BOOL ready = [self ensureEngineLoaded];
        // Hat der Abschnitt auf das Laden gewartet (Metal-Übersetzung beim ersten Start), ist er veraltet: verwerfen,
        // der Controller schickt gleich den nächsten (sonst stünde der Text erst viele Sekunden zu spät da).
        double waited = CACurrentMediaTime() - submitted;
        if (ready && waited > MAX(1.0, self.preferredWindowDuration)) {
            NSLog(@"%@ Abschnitt @ %.1f s verworfen, %.1f s auf das Modell gewartet", kWhisperWebLogPrefix, startTime, waited);
            ready = NO;
        }
        if (copy != nil && generation == atomic_load(&self->_generation) && ready) {
            CFTimeInterval begin = CACurrentMediaTime();
            NSArray<BrowserSubtitleCue *> *engineCues = [self->_engine transcribeSamples:copy.bytes count:count startTime:startTime];
            double compute = CACurrentMediaTime() - begin;
            os_unfair_lock_lock(&self->_statsLock);
            self->_totalCompute += compute;
            self->_totalAudio += count / 16000.0;
            os_unfair_lock_unlock(&self->_statsLock);
            if (generation == atomic_load(&self->_generation)) {
                result = [self webCuesFromEngineCues:engineCues ?: @[]];
            }
        }
        completion(result);
        [self scheduleIdleUnload];
    });
}

- (void)transcribeEngineSamples:(NSData *)samples startTime:(NSTimeInterval)startTime
                     completion:(void (^)(NSArray<BrowserSubtitleCue *> *))completion {
    NSUInteger generation = atomic_load(&_generation);
    dispatch_async(_engineQueue, ^{
        NSArray<BrowserSubtitleCue *> *result = nil;
        if (generation == atomic_load(&self->_generation) && [self ensureEngineLoaded]) {
            NSUInteger count = samples.length / sizeof(float);
            CFTimeInterval begin = CACurrentMediaTime();
            result = [self->_engine transcribeSamples:samples.bytes count:count startTime:startTime];
            double compute = CACurrentMediaTime() - begin;
            os_unfair_lock_lock(&self->_statsLock);
            self->_totalCompute += compute;
            self->_totalAudio += count / 16000.0;
            os_unfair_lock_unlock(&self->_statsLock);
            if (generation != atomic_load(&self->_generation)) {
                result = nil;
            }
        }
        completion(result);
        [self scheduleIdleUnload];
    });
}

- (void)reset {
    atomic_fetch_add(&_generation, 1);
    // Laufende Auswertung abbrechen; ihr Ergebnis verwirft der Controller ohnehin (generation).
    [[self lockedEngine] cancel];
    dispatch_async(_engineQueue, ^{
        self->_previousWords = nil;
        self->_previousEnd = -1.0;
        [self->_recentCues removeAllObjects];
    });
}

/// Läuft auf _engineQueue. Wandelt die Engine-Cues um und entfernt Wörter, die wegen der Überlappung schon im
/// letzten Abschnitt standen (der Controller ersetzt nur Cues ab Abschnittsbeginn, der Rest bliebe doppelt).
- (NSArray<BrowserWebSubtitleCue *> *)webCuesFromEngineCues:(NSArray<BrowserSubtitleCue *> *)engineCues {
    NSMutableArray<BrowserWebSubtitleCue *> *cues = [NSMutableArray arrayWithCapacity:engineCues.count];
    // Schleifen über Segmente: gleicher Text mehrfach hintereinander (bei kurzen Abschnitten teils 20× und mehr).
    NSMutableArray<BrowserSubtitleCue *> *unique = [NSMutableArray arrayWithCapacity:engineCues.count];
    NSString *lastNormalized = nil;
    for (BrowserSubtitleCue *engineCue in engineCues) {
        NSString *normalized = [[BrowserWhisperWords(engineCue.text) valueForKey:@"lowercaseString"] componentsJoinedByString:@" "];
        if (lastNormalized != nil && [normalized isEqualToString:lastNormalized]) {
            continue;
        }
        lastNormalized = normalized;
        [unique addObject:engineCue];
    }
    if (unique.count < engineCues.count) {
        NSLog(@"%@ Wiederholungsschleife: %lu von %lu Segmenten verworfen", kWhisperWebLogPrefix,
              (unsigned long)(engineCues.count - unique.count), (unsigned long)engineCues.count);
    }
    BOOL first = YES;
    for (BrowserSubtitleCue *engineCue in unique) {
        NSTimeInterval start = engineCue.start;
        NSTimeInterval end = engineCue.end;
        NSArray<NSString *> *words = BrowserWhisperCollapseRepeats(BrowserWhisperWords(engineCue.text));
        if (first && _previousWords.count > 0 && start < _previousEnd + 0.25) {
            NSUInteger maxOverlap = MIN((NSUInteger)8, MIN(_previousWords.count, words.count));
            NSUInteger overlap = 0;
            for (NSUInteger k = maxOverlap; k >= 1; k--) {
                BOOL equal = YES;
                for (NSUInteger i = 0; i < k && equal; i++) {
                    NSString *previous = BrowserWhisperNormalizedWord(_previousWords[_previousWords.count - k + i]);
                    NSString *current = BrowserWhisperNormalizedWord(words[i]);
                    equal = previous.length > 0 && [previous isEqualToString:current];
                }
                if (equal) {
                    overlap = k;
                    break;
                }
            }
            if (overlap == 1 && BrowserWhisperNormalizedWord(words[0]).length < 3) {
                overlap = 0;  // „I“, „a“, „so“ … wiederholen sich oft wirklich
            }
            if (overlap > 0) {
                NSTimeInterval shift = (end - start) * overlap / MAX((NSUInteger)1, words.count);
                words = [words subarrayWithRange:NSMakeRange(overlap, words.count - overlap)];
                start += shift;
#if DEBUG
                NSLog(@"%@ Überlappung: %lu Wort/Wörter entfernt („%@“)", kWhisperWebLogPrefix, (unsigned long)overlap, engineCue.text);
#endif
            }
        }
        first = NO;
        if (words.count == 0) {
            continue;
        }
        // Gleicher Text innerhalb von 15 s (wie Weg A): meist ein Satz, der in zwei Abschnitten steckt, oder ein
        // erfundenes Wort bei Musik („directional“), das in jedem Abschnitt wiederkommt.
        NSMutableArray<NSString *> *normalizedWords = [NSMutableArray arrayWithCapacity:words.count];
        for (NSString *word in words) {
            [normalizedWords addObject:BrowserWhisperNormalizedWord(word)];
        }
        NSString *normalized = [normalizedWords componentsJoinedByString:@" "];
        NSIndexSet *old = [_recentCues indexesOfObjectsPassingTest:^BOOL(NSArray *entry, NSUInteger index, BOOL *stop) {
            return fabs([entry[1] doubleValue] - start) > 30.0;
        }];
        [_recentCues removeObjectsAtIndexes:old];
        BOOL repeated = NO;
        for (NSArray *entry in _recentCues) {
            if ([entry[0] isEqualToString:normalized] && fabs([entry[1] doubleValue] - start) < 15.0) {
                repeated = YES;
                break;
            }
        }
        if (repeated) {
#if DEBUG
            NSLog(@"%@ Wiederholung innerhalb 15 s verworfen: „%@“", kWhisperWebLogPrefix, engineCue.text);
#endif
            continue;
        }
        [_recentCues addObject:@[normalized, @(start)]];
        [cues addObject:[BrowserWebSubtitleCue cueWithStart:start end:end text:[words componentsJoinedByString:@" "]]];
    }
    if (unique.count > 0) {
        BrowserSubtitleCue *last = unique.lastObject;
        _previousWords = BrowserWhisperCollapseRepeats(BrowserWhisperWords(last.text));
        _previousEnd = last.end;
    }
    return cues;
}

@end
