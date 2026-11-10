#import "BrowserAppleSpeechTranscriber.h"

#import "BrowserSubtitleEngine.h"
#import "BrowserSubtitleTranslator.h"

#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

static NSString * const kAppleSpeechLogPrefix = @"[AppleSpeech]";
static NSString * const kAppleSpeechRecognizerDefaultsKey = @"SubtitlesRecognizer";
/// Zwei Zeilen wie bei whisper (kBrowserSubtitleMaxCueCharacters in der Engine).
static const NSInteger kAppleSpeechMaxCueCharacters = 84;

typedef NS_ENUM(NSInteger, BrowserAppleSpeechLocaleState) {
    BrowserAppleSpeechLocaleStatePreparing = 1,
    BrowserAppleSpeechLocaleStateReady,
    BrowserAppleSpeechLocaleStateFailed,
};

static Class<BrowserAppleSpeechRecognizerClass> BrowserAppleSpeechRecognizerClassOrNil(void) {
    Class cls = NSClassFromString(@"BrowserAppleSpeechRecognizer");
    if (cls == Nil || ![cls respondsToSelector:@selector(transcribeSamples:startTime:locale:maxCharacters:wholeSentences:completion:)]) {
        return Nil;
    }
    return (Class<BrowserAppleSpeechRecognizerClass>)cls;
}

/// Zustand der Sprachpakete, für alle Instanzen gemeinsam (die Pakete gelten systemweit).
static os_unfair_lock gLocaleLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSNumber *> *gLocaleStates;     // Sprache → BrowserAppleSpeechLocaleState
static NSMutableDictionary<NSString *, NSString *> *gLocaleIdentifiers; // Sprache → „en_US“
static NSMutableDictionary<NSString *, NSString *> *gLocaleFailures;    // Sprache → Grund

@interface BrowserAppleSpeechTranscriber ()
@property (nonatomic, copy, readwrite) NSString *subtitleLanguage;
@end

@implementation BrowserAppleSpeechTranscriber {
    os_unfair_lock _statsLock;
    NSUInteger _windows;
    NSUInteger _fallbacks;
    double _computeSum;
    double _computeMax;
    double _audioSum;
    NSString *_lastFallbackReason;
    NSString *_lastTranslationNote;
}

+ (BOOL)isRequested {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:kAppleSpeechRecognizerDefaultsKey];
    return [value.lowercaseString isEqualToString:@"apple"];
}

+ (BOOL)isUsable {
    if (![self isRequested]) {
        return NO;
    }
    Class<BrowserAppleSpeechRecognizerClass> cls = BrowserAppleSpeechRecognizerClassOrNil();
    BOOL available = cls != Nil && [cls isFrameworkAvailable];
#if DEBUG
    // Test im Simulator (dort fehlt SpeechTranscriber): Weg über Apple trotzdem nehmen. whisper läuft dann auf „auto“,
    // das Vorbereiten der Sprache scheitert, jeder Abschnitt geht an whisper (Rückfall), Übersetzung über
    // translationTarget wie mit Apple. Prüft Haken, Sprachbestimmung und Rückfall ohne Gerät.
    if (!available && cls != Nil && [NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesAppleSpeechForce"]) {
        static dispatch_once_t forceOnce;
        dispatch_once(&forceOnce, ^{
            NSLog(@"%@ SubtitlesAppleSpeechForce: Apple-Weg erzwungen, obwohl SpeechTranscriber fehlt (nur DEBUG, Test des Rückfalls)",
                  kAppleSpeechLogPrefix);
        });
        return YES;
    }
#endif
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"%@ Einstellung SubtitlesRecognizer=apple: %@", kAppleSpeechLogPrefix,
              available ? @"SpeechTranscriber verfügbar"
                        : (cls == Nil ? @"Swift-Klasse fehlt – Rückfall whisper"
                                      : @"SpeechTranscriber.isAvailable = false (Simulator/zu altes tvOS) – Rückfall whisper"));
    });
    return available;
}

+ (NSString *)whisperLanguageForSubtitleLanguage:(NSString *)language {
    return [self isUsable] ? @"auto" : language;
}

+ (instancetype)transcriberForSubtitleLanguage:(NSString *)language {
    if (![self isUsable]) {
        return nil;
    }
    return [[self alloc] initWithSubtitleLanguage:language];
}

- (instancetype)initWithSubtitleLanguage:(NSString *)language {
    self = [super init];
    if (self) {
        _subtitleLanguage = language.length > 0 ? [language copy] : @"auto";
        _statsLock = OS_UNFAIR_LOCK_INIT;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            gLocaleStates = [NSMutableDictionary dictionary];
            gLocaleIdentifiers = [NSMutableDictionary dictionary];
            gLocaleFailures = [NSMutableDictionary dictionary];
        });
        // Paket erst für die gesprochene Sprache vorbereiten, nicht für die Untertitelsprache: spricht das Video eine
        // andere, würde sonst ein unnötiges Paket geladen (und bei maximumReservedLocales = 1 gleich wieder verdrängt).
        NSLog(@"%@ Erkennung Apple (SpeechTranscriber), Untertitelsprache %@, whisper bestimmt die gesprochene Sprache und ist Rückfall",
              kAppleSpeechLogPrefix, _subtitleLanguage);
    }
    return self;
}

#pragma mark Sprachpakete

/// Locale-Kennung, wenn das Paket bereit ist; sonst nil (Vorbereitung wird beim ersten Mal angestoßen).
/// `reason` bekommt den Grund, warum (noch) nicht.
- (nullable NSString *)localeForLanguage:(NSString *)language reason:(NSString * _Nullable * _Nullable)reason {
    os_unfair_lock_lock(&gLocaleLock);
    NSInteger state = gLocaleStates[language].integerValue;
    NSString *identifier = gLocaleIdentifiers[language];
    NSString *failure = gLocaleFailures[language];
    BOOL start = state == 0;
    if (start) {
        gLocaleStates[language] = @(BrowserAppleSpeechLocaleStatePreparing);
    }
    os_unfair_lock_unlock(&gLocaleLock);
    if (start) {
        Class<BrowserAppleSpeechRecognizerClass> cls = BrowserAppleSpeechRecognizerClassOrNil();
        CFTimeInterval begin = CACurrentMediaTime();
        NSLog(@"%@ Sprache %@ vorbereiten (supportedLocales, AssetInventory)", kAppleSpeechLogPrefix, language);
        [cls prepareLanguage:language progress:^(NSString *message) {
            NSLog(@"%@ %@", kAppleSpeechLogPrefix, message);
        } completion:^(NSString *locale, NSString *message) {
            os_unfair_lock_lock(&gLocaleLock);
            if (locale.length > 0) {
                gLocaleStates[language] = @(BrowserAppleSpeechLocaleStateReady);
                gLocaleIdentifiers[language] = locale;
            } else {
                gLocaleStates[language] = @(BrowserAppleSpeechLocaleStateFailed);
                gLocaleFailures[language] = message;
            }
            os_unfair_lock_unlock(&gLocaleLock);
            NSLog(@"%@ Sprache %@: %@ (%.2f s)%@", kAppleSpeechLogPrefix, language, message, CACurrentMediaTime() - begin,
                  locale.length > 0 ? @"" : @" – Rückfall whisper für diese Sprache");
        }];
    }
    if (state == BrowserAppleSpeechLocaleStateReady) {
        return identifier;
    }
    if (reason != NULL) {
        *reason = state == BrowserAppleSpeechLocaleStateFailed ? (failure ?: @"nicht verfügbar") : @"Sprachpaket wird vorbereitet";
    }
    return nil;
}

#pragma mark Erkennen

/// Übersetzung nach der Untertitelsprache, wenn sie fest ist, eine andere als die gesprochene und Apple sie anbietet.
- (nullable NSString *)translationTargetForSpoken:(nullable NSString *)spoken {
    NSString *target = self.subtitleLanguage;
    if (spoken.length == 0 || [target isEqualToString:@"auto"] || [target isEqualToString:spoken]) {
        return nil;
    }
    BOOL possible = [BrowserSubtitleTranslator.sharedTranslator canTranslateFrom:spoken to:target];
    NSString *note = possible ? [NSString stringWithFormat:@"Apple übersetzt %@ → %@", spoken, target]
                              : [NSString stringWithFormat:@"Übersetzung %@ → %@ nicht möglich (abgeschaltet, ausgesetzt oder nicht angeboten): Originaltext", spoken, target];
    os_unfair_lock_lock(&_statsLock);
    BOOL changed = ![note isEqualToString:_lastTranslationNote ?: @""];
    _lastTranslationNote = note;
    os_unfair_lock_unlock(&_statsLock);
    if (changed) {
        NSLog(@"%@ %@", kAppleSpeechLogPrefix, note);
    }
    return possible ? target : nil;
}

- (NSArray<BrowserSubtitleCue *> *)markCues:(NSArray<BrowserSubtitleCue *> *)cues spoken:(nullable NSString *)spoken {
    NSString *target = [self translationTargetForSpoken:spoken];
    for (BrowserSubtitleCue *cue in cues) {
        if (spoken.length > 0) {
            cue.language = spoken;
        }
        cue.translationTarget = target;
    }
    return cues;
}

- (void)noteFallback:(NSString *)reason startTime:(NSTimeInterval)startTime {
    os_unfair_lock_lock(&_statsLock);
    _fallbacks += 1;
    BOOL changed = ![reason isEqualToString:_lastFallbackReason ?: @""];
    _lastFallbackReason = reason;
    NSUInteger count = _fallbacks;
    os_unfair_lock_unlock(&_statsLock);
    if (changed) {
        NSLog(@"%@ Abschnitt @ %.1f s: %@ – Rückfall whisper (%lu.)", kAppleSpeechLogPrefix, startTime, reason, (unsigned long)count);
    }
#if DEBUG
    else {
        NSLog(@"%@ Abschnitt @ %.1f s: Rückfall whisper (%@)", kAppleSpeechLogPrefix, startTime, reason);
    }
#endif
}

- (void)transcribeSamples:(NSData *)samples
                startTime:(NSTimeInterval)startTime
                  whisper:(BrowserSubtitleTranscriber)whisper
               completion:(void (^)(NSArray<BrowserSubtitleCue *> *))completion {
    NSString * _Nullable (^provider)(void) = self.spokenLanguageProvider;
    NSString *spoken = provider != nil ? provider() : nil;
    if (spoken.length > 0) {
        [self recognizeSamples:samples startTime:startTime spoken:spoken whisperCues:nil whisper:whisper completion:completion];
        return;
    }
    // Sprache noch offen: whisper rechnet den Abschnitt (zählt als Stimme für das Festlegen) und liefert seine Sprache.
    // Hat whisper hier nichts (Stille, Musik, Abbruch), bleibt es dabei.
    whisper(samples, startTime, ^(NSArray<BrowserSubtitleCue *> *cues) {
        if (cues == nil) {
            completion(nil);
            return;
        }
        NSString *windowLanguage = cues.firstObject.language;
        if (cues.count == 0 || windowLanguage.length == 0 || [windowLanguage isEqualToString:@"auto"]) {
            completion([self markCues:cues spoken:windowLanguage]);
            return;
        }
        [self recognizeSamples:samples startTime:startTime spoken:windowLanguage whisperCues:cues whisper:whisper completion:completion];
    });
}

- (void)recognizeSamples:(NSData *)samples
               startTime:(NSTimeInterval)startTime
                  spoken:(NSString *)spoken
             whisperCues:(nullable NSArray<BrowserSubtitleCue *> *)whisperCues
                 whisper:(BrowserSubtitleTranscriber)whisper
              completion:(void (^)(NSArray<BrowserSubtitleCue *> *))completion {
    void (^fallback)(NSString *) = ^(NSString *reason) {
        [self noteFallback:reason startTime:startTime];
        if (whisperCues != nil) {
            completion([self markCues:whisperCues spoken:spoken]);
            return;
        }
        whisper(samples, startTime, ^(NSArray<BrowserSubtitleCue *> *cues) {
            completion(cues != nil ? [self markCues:cues spoken:cues.firstObject.language ?: spoken] : nil);
        });
    };
    NSString *reason = nil;
    NSString *locale = [self localeForLanguage:spoken reason:&reason];
    Class<BrowserAppleSpeechRecognizerClass> cls = BrowserAppleSpeechRecognizerClassOrNil();
    if (locale == nil || cls == Nil) {
        fallback([NSString stringWithFormat:@"Sprache %@: %@", spoken, reason ?: @"Swift-Klasse fehlt"]);
        return;
    }
    NSString *target = [self translationTargetForSpoken:spoken];
    double seconds = (double)samples.length / sizeof(float) / 16000.0;
    CFTimeInterval begin = CACurrentMediaTime();
    [cls transcribeSamples:samples startTime:startTime locale:locale maxCharacters:kAppleSpeechMaxCueCharacters
            wholeSentences:target != nil completion:^(NSArray<NSDictionary<NSString *, id> *> *pieces, NSString *failure) {
        double compute = CACurrentMediaTime() - begin;
        if (pieces == nil) {
            fallback([NSString stringWithFormat:@"Fehler beim Erkennen: %@", failure ?: @"unbekannt"]);
            return;
        }
        NSMutableArray<BrowserSubtitleCue *> *cues = [NSMutableArray arrayWithCapacity:pieces.count];
        for (NSDictionary<NSString *, id> *piece in pieces) {
            NSString *text = piece[@"text"];
            if (text.length == 0) {
                continue;
            }
            BrowserSubtitleCue *cue = [[BrowserSubtitleCue alloc] initWithStart:[piece[@"start"] doubleValue]
                                                                            end:[piece[@"end"] doubleValue] text:text];
            cue.language = spoken;
            cue.translationTarget = target;
            [cues addObject:cue];
        }
        os_unfair_lock_lock(&self->_statsLock);
        self->_windows += 1;
        self->_computeSum += compute;
        self->_computeMax = MAX(self->_computeMax, compute);
        self->_audioSum += seconds;
        double rtf = self->_audioSum > 0.0 ? self->_computeSum / self->_audioSum : 0.0;
        os_unfair_lock_unlock(&self->_statsLock);
        NSLog(@"%@ Abschnitt %.1f s @ %.1f s (%@%@): %lu Untertitel in %.2f s (RTF %.2f, Schnitt %.2f), Speicher %.0f MB%@%@",
              kAppleSpeechLogPrefix, seconds, startTime, locale, target != nil ? [NSString stringWithFormat:@" → %@", target] : @"",
              (unsigned long)cues.count, compute, seconds > 0.0 ? compute / seconds : 0.0, rtf,
              [BrowserSubtitleEngine currentMemoryFootprintMB],
              cues.count > 0 ? @" – " : @"", cues.count > 0 ? [[cues valueForKey:@"text"] componentsJoinedByString:@" | "] : @"");
        completion(cues);
    }];
}

- (NSString *)summary {
    os_unfair_lock_lock(&_statsLock);
    NSString *line = [NSString stringWithFormat:@"Apple-Spracherkennung: %lu Abschnitte, Ø %.2f s, max %.2f s, RTF %.2f, %lu Rückfälle whisper",
                      (unsigned long)_windows, _windows > 0 ? _computeSum / _windows : 0.0, _computeMax,
                      _audioSum > 0.0 ? _computeSum / _audioSum : 0.0, (unsigned long)_fallbacks];
    os_unfair_lock_unlock(&_statsLock);
    return line;
}

#pragma mark Selbsttest

+ (void)runProbeWithCompletion:(void (^)(void))completion {
    Class<BrowserAppleSpeechRecognizerClass> cls = BrowserAppleSpeechRecognizerClassOrNil();
    if (cls == Nil) {
        NSLog(@"%@ speechprobe: Swift-Klasse BrowserAppleSpeechRecognizer fehlt", kAppleSpeechLogPrefix);
        if (completion != nil) {
            completion();
        }
        return;
    }
    NSLog(@"%@ speechprobe: Einstellung SubtitlesRecognizer=%@", kAppleSpeechLogPrefix,
          [NSUserDefaults.standardUserDefaults stringForKey:kAppleSpeechRecognizerDefaultsKey] ?: @"(whisper, Standard)");
    [cls runProbeWithLog:^(NSString *line) {
        NSLog(@"%@ speechprobe %@", kAppleSpeechLogPrefix, line);
    } completion:^{
        NSLog(@"%@ speechprobe fertig, Speicher %.0f MB", kAppleSpeechLogPrefix, [BrowserSubtitleEngine currentMemoryFootprintMB]);
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    }];
}

@end
