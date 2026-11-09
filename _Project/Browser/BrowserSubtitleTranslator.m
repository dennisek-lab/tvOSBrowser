#import "BrowserSubtitleTranslator.h"

#import "BrowserAppleTranslator.h"
#import "BrowserSubtitleEngine.h"

#import <os/lock.h>
#import <stdatomic.h>

static NSString * const kSubtitleTranslatorLogPrefix = @"[Subtitles]";
/// So lange übersetzt whisper nach einem Fehler (offline, Code 16, Absturz von translationd 4097/4099) selbst.
static const NSTimeInterval kSubtitleTranslatorErrorPause = 60.0;
/// … und nach zwei zu späten Antworten in Folge (Netz langsam). Danach versucht es die Engine wieder mit Apple.
/// Eine einzelne verpasste Frist (live 0,5 s; im Simulator gelegentlich 0,55–0,6 s) setzt Apple nicht aus: Der Abschnitt
/// kommt dann im Original, der nächste wieder übersetzt (vorher übersetzte whisper danach 20 s lang schlecht selbst).
static const NSTimeInterval kSubtitleTranslatorTimeoutPause = 20.0;
static const NSUInteger kSubtitleTranslatorTimeoutsBeforePause = 2;

static NSString *BrowserSubtitleTranslatorShort(NSString *text) {
    return text.length > 70 ? [[text substringToIndex:70] stringByAppendingString:@"…"] : text;
}

static BOOL BrowserSubtitleTranslatorHasLetter(NSString *text) {
    return [text rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound;
}

static NSString *BrowserSubtitleTranslatorErrorText(NSError *error) {
    if (error == nil) {
        return @"keine Übersetzung";
    }
    NSString *domain = [error.domain isEqualToString:NSCocoaErrorDomain] ? @"NSXPC/Cocoa" : error.domain;
    return [NSString stringWithFormat:@"%@ %ld: %@", domain, (long)error.code, error.localizedDescription ?: @""];
}

@interface BrowserSubtitleTranslator () {
    os_unfair_lock _lock;
    // Unter _lock:
    NSMutableDictionary<NSString *, NSArray<NSLocale *> *> *_localeCache;   // „en>de“ → [Quelle, Ziel], NSNull = nein
    CFAbsoluteTime _suspendedUntil;
    NSUInteger _requests;
    NSUInteger _failures;
    NSUInteger _consecutiveTimeouts;
    double _totalSeconds;
    double _maxSeconds;
    _Atomic(bool) _prepared;
}
@property (nonatomic, strong) NSCache<NSString *, NSString *> *cache;
@end

@implementation BrowserSubtitleTranslator

+ (BrowserSubtitleTranslator *)sharedTranslator {
    static BrowserSubtitleTranslator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[BrowserSubtitleTranslator alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _localeCache = [NSMutableDictionary dictionary];
        _cache = [NSCache new];
        _cache.countLimit = 400;
        atomic_store(&_prepared, false);
    }
    return self;
}

- (void)prepare {
    if (atomic_load(&_prepared)) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [BrowserAppleTranslator.sharedTranslator prepareWithCompletion:^(BOOL available) {
            atomic_store(&self->_prepared, available);
            NSLog(@"%@ Apple-Übersetzung %@", kSubtitleTranslatorLogPrefix,
                  available ? @"bereit (Textdienst antwortet)" : @"nicht verfügbar: whisper übersetzt selbst (Rückfall whisper)");
        }];
    });
}

- (BOOL)isSuspended {
    os_unfair_lock_lock(&_lock);
    BOOL suspended = CFAbsoluteTimeGetCurrent() < _suspendedUntil;
    os_unfair_lock_unlock(&_lock);
    return suspended;
}

- (void)suspendFor:(NSTimeInterval)seconds reason:(NSString *)reason {
    os_unfair_lock_lock(&_lock);
    _suspendedUntil = MAX(_suspendedUntil, CFAbsoluteTimeGetCurrent() + seconds);
    _failures++;
    os_unfair_lock_unlock(&_lock);
    NSLog(@"%@ Rückfall whisper: %@ – whisper übersetzt die nächsten %.0f s selbst", kSubtitleTranslatorLogPrefix, reason, seconds);
}

/// Verpasste Frist zählen; erst ab der zweiten in Folge aussetzen. YES = ausgesetzt.
- (BOOL)noteTimeoutWithReason:(NSString *)reason {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = ++_consecutiveTimeouts;
    if (count < kSubtitleTranslatorTimeoutsBeforePause) {
        _failures++;
    }
    os_unfair_lock_unlock(&_lock);
    if (count >= kSubtitleTranslatorTimeoutsBeforePause) {
        [self suspendFor:kSubtitleTranslatorTimeoutPause reason:[reason stringByAppendingFormat:@", %lu× in Folge", (unsigned long)count]];
        return YES;
    }
    NSLog(@"%@ Rückfall Original: %@ – dieser Abschnitt im Original, Apple bleibt an", kSubtitleTranslatorLogPrefix, reason);
    return NO;
}

- (void)noteOnTime {
    os_unfair_lock_lock(&_lock);
    _consecutiveTimeouts = 0;
    os_unfair_lock_unlock(&_lock);
}

- (NSArray<NSLocale *> *)localesFrom:(NSString *)source to:(NSString *)target {
    NSString *key = [NSString stringWithFormat:@"%@>%@", source, target];
    os_unfair_lock_lock(&_lock);
    id cached = _localeCache[key];
    os_unfair_lock_unlock(&_lock);
    if (cached != nil) {
        return [cached isKindOfClass:NSArray.class] ? cached : nil;
    }
    // Die Sprachpaare stehen nach prepare fest (einmal gesetzt, danach nur gelesen).
    NSArray<NSLocale *> *locales = [BrowserAppleTranslator.sharedTranslator localesForSourceLanguage:source targetLanguage:target];
    os_unfair_lock_lock(&_lock);
    _localeCache[key] = locales ?: (id)NSNull.null;
    os_unfair_lock_unlock(&_lock);
    NSLog(@"%@ Apple-Übersetzung %@ → %@: %@", kSubtitleTranslatorLogPrefix, source, target,
          locales != nil ? [NSString stringWithFormat:@"%@ → %@", locales[0].localeIdentifier, locales[1].localeIdentifier]
                         : @"Sprachpaar nicht angeboten (Rückfall whisper)");
    return locales;
}

- (BOOL)canTranslateFrom:(NSString *)source to:(NSString *)target {
    if (source.length == 0 || target.length == 0 || [source isEqualToString:target] ||
        [NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesNoAppleTranslation"]) {
        return NO;
    }
    if (!atomic_load(&_prepared)) {
        [self prepare];
        return NO;
    }
    if (self.suspended) {
        return NO;
    }
    return [self localesFrom:source to:target] != nil;
}

- (void)recordSeconds:(double)seconds {
    os_unfair_lock_lock(&_lock);
    _requests++;
    _totalSeconds += seconds;
    _maxSeconds = MAX(_maxSeconds, seconds);
    os_unfair_lock_unlock(&_lock);
}

- (NSString *)summary {
    os_unfair_lock_lock(&_lock);
    NSString *text = [NSString stringWithFormat:@"Apple-Übersetzung: %lu Anfragen, Ø %.2f s, max %.2f s, %lu Fehler/zu spät%@",
                      (unsigned long)_requests, _requests > 0 ? _totalSeconds / _requests : 0.0, _maxSeconds,
                      (unsigned long)_failures, CFAbsoluteTimeGetCurrent() < _suspendedUntil ? @" (Rückfall whisper aktiv)" : @""];
    os_unfair_lock_unlock(&_lock);
    return text;
}

- (NSString *)cacheKeyForText:(NSString *)text source:(NSString *)source target:(NSString *)target {
    return [NSString stringWithFormat:@"%@>%@|%@", source, target, text];
}

- (void)translateTexts:(NSArray<NSString *> *)texts from:(NSString *)source to:(NSString *)target context:(NSString *)context
               timeout:(NSTimeInterval)timeout completion:(void (^)(NSArray<NSString *> *, NSString *))completion {
    if (texts.count == 0) {
        completion(@[], nil);
        return;
    }
    // Schon übersetzt (Mithören fragt denselben Satz oft mehrmals an, erst vorläufig, dann fertig)?
    NSMutableArray<NSString *> *cached = [NSMutableArray arrayWithCapacity:texts.count];
    for (NSString *text in texts) {
        NSString *hit = [self.cache objectForKey:[self cacheKeyForText:text source:source target:target]];
        if (hit == nil) {
            cached = nil;
            break;
        }
        [cached addObject:hit];
    }
    if (cached != nil) {
        completion(cached, nil);
        return;
    }
    NSArray<NSLocale *> *locales = [self localesFrom:source to:target];
    if (locales == nil) {
        completion(nil, @"Sprachpaar nicht angeboten");
        return;
    }
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesAppleTranslationFail"]) {
        // Test des Rückfalls (Selbsttest pref:SubtitlesAppleTranslationFail=YES), wirkt wie ein Fehler von translationd.
        [self suspendFor:kSubtitleTranslatorErrorPause reason:@"Fehler erzwungen (SubtitlesAppleTranslationFail)"];
        completion(nil, @"Fehler erzwungen");
        return;
    }
    BOOL useContext = context.length > 0 && ![NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesTranslateNoContext"];
    // Ein Absatz: [Kontext, " ", Text 1, " ", Text 2, …]. Teile ohne Buchstaben (die Leerzeichen) bleiben, wie sie sind;
    // Apple übersetzt den ganzen Absatz am Stück und ordnet jedem Bereich seinen Teil zu (_LTAlignment).
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
    if (useContext) {
        [parts addObject:context];
    }
    for (NSString *text in texts) {
        if (parts.count > 0) {
            [parts addObject:@" "];
        }
        [indexes addObject:@(parts.count)];
        [parts addObject:text];
    }
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    __block _Atomic(bool) done = false;
    void (^finish)(NSArray<NSString *> *, NSString *) = ^(NSArray<NSString *> *translated, NSString *failure) {
        bool expected = false;
        if (!atomic_compare_exchange_strong(&done, &expected, true)) {
            return;
        }
        completion(translated, failure);
    };
    // Stand nach der Hauptanfrage, solange einzelne Sätze nachgefragt werden: Läuft dann die Frist ab, kommt dieser Stand
    // (fehlende Sätze im Original), und Apple wird nicht ausgesetzt – die Hauptanfrage war ja pünktlich.
    NSObject *partialLock = [NSObject new];
    __block NSArray<NSString *> *partial = nil;
    __block NSUInteger partialMissing = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (atomic_load(&done)) {
            return;
        }
        NSArray<NSString *> *pending = nil;
        NSUInteger pendingMissing = 0;
        @synchronized (partialLock) {
            pending = partial;
            pendingMissing = partialMissing;
        }
        if (pending != nil) {
            NSLog(@"%@ Apple-Übersetzung: Einzelnachfrage nach %.1f s nicht fertig, %lu von %lu Sätzen im Original", kSubtitleTranslatorLogPrefix,
                  timeout, (unsigned long)pendingMissing, (unsigned long)texts.count);
            finish(pending, nil);
            return;
        }
        [self noteTimeoutWithReason:[NSString stringWithFormat:@"Apple-Übersetzung zu spät (> %.1f s, %lu Sätze)", timeout, (unsigned long)texts.count]];
        finish(nil, [NSString stringWithFormat:@"zu spät (> %.1f s)", timeout]);
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [BrowserAppleTranslator.sharedTranslator translateParts:parts source:locales[0] target:locales[1]
                                                     completion:^(NSArray<NSString *> *translated, BOOL usedAlignment, NSError *error) {
            double seconds = CFAbsoluteTimeGetCurrent() - begin;
            [self recordSeconds:seconds];
            if (translated.count != parts.count) {
                if (!atomic_load(&done)) {
                    [self suspendFor:kSubtitleTranslatorErrorPause reason:BrowserSubtitleTranslatorErrorText(error)];
                }
                finish(nil, BrowserSubtitleTranslatorErrorText(error));
                return;
            }
            NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:texts.count];
            NSMutableIndexSet *missing = [NSMutableIndexSet indexSet];
            [indexes enumerateObjectsUsingBlock:^(NSNumber *index, NSUInteger i, __unused BOOL *stop) {
                NSString *text = [self cleanedTranslation:translated[index.unsignedIntegerValue] original:texts[i]];
                if (text.length == 0) {
                    [missing addIndex:i];
                    text = texts[i];
                }
                [result addObject:text];
            }];
            BOOL late = atomic_load(&done);
            if (!late) {
                [self noteOnTime];
            }
            NSLog(@"%@ Apple-Übersetzung %@→%@: %lu Sätze in %.2f s, Speicher %.0f MB%@%@%@%@ – „%@“ → „%@“", kSubtitleTranslatorLogPrefix, source, target,
                  (unsigned long)texts.count, seconds, [BrowserSubtitleEngine currentMemoryFootprintMB], useContext ? [NSString stringWithFormat:@", Kontext %lu Z.", (unsigned long)context.length] : @"",
                  usedAlignment ? @"" : @", Bereiche unvollständig", missing.count > 0 ? [NSString stringWithFormat:@", %lu einzeln nachgefragt", (unsigned long)missing.count] : @"",
                  late ? @", kam zu spät (nur gemerkt)" : @"",
                  BrowserSubtitleTranslatorShort([texts componentsJoinedByString:@" | "]),
                  BrowserSubtitleTranslatorShort([result componentsJoinedByString:@" | "]));
            void (^deliver)(void) = ^{
                [result enumerateObjectsUsingBlock:^(NSString *text, NSUInteger i, __unused BOOL *stop) {
                    if (![missing containsIndex:i]) {
                        [self.cache setObject:text forKey:[self cacheKeyForText:texts[i] source:source target:target]];
                    }
                }];
                if (missing.count == texts.count) {
                    if (!atomic_load(&done)) {
                        [self suspendFor:kSubtitleTranslatorErrorPause reason:@"Apple lieferte keinen der Sätze"];
                    }
                    finish(nil, @"keine Bereiche übersetzt");
                    return;
                }
                finish(result, nil);
            };
            if (missing.count == 0 || late) {
                deliver();
                return;
            }
            // Bereiche fehlen oder sind verdächtig kurz (Apple schiebt beim Umstellen Text in den Kontext oder den
            // Nachbarbereich, z. B. „… means bringing the most“ → „bringen“): diese Sätze einzeln ohne Bereiche
            // nachfragen. Was in der Frist nicht kommt, bleibt im Original.
            dispatch_group_t group = dispatch_group_create();
            NSObject *lock = [NSObject new];
            NSIndexSet *retry = [missing copy];
            if (retry.count < texts.count) {
                @synchronized (partialLock) {
                    partial = [result copy];
                    partialMissing = retry.count;
                }
            }
            [retry enumerateIndexesUsingBlock:^(NSUInteger i, __unused BOOL *stop) {
                dispatch_group_enter(group);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [BrowserAppleTranslator.sharedTranslator translateParts:@[texts[i]] source:locales[0] target:locales[1]
                                                                 completion:^(NSArray<NSString *> *single, __unused BOOL used, __unused NSError *singleError) {
                        NSString *text = single.count == 1 ? [self cleanedTranslation:single[0] original:texts[i]] : @"";
                        @synchronized (lock) {
                            if (text.length > 0) {
                                result[i] = text;
                                [missing removeIndex:i];
                            }
                        }
                        dispatch_group_leave(group);
                    }];
                });
            }];
            dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSLog(@"%@ Apple-Übersetzung einzeln: %lu von %lu nachgeholt in %.2f s – „%@“", kSubtitleTranslatorLogPrefix,
                      (unsigned long)(retry.count - missing.count), (unsigned long)retry.count, CFAbsoluteTimeGetCurrent() - begin,
                      BrowserSubtitleTranslatorShort([[result objectsAtIndexes:retry] componentsJoinedByString:@" | "]));
                deliver();
            });
        }];
    });
}

/// Übersetzten Bereich säubern: Leerraum, nach vorn geschobene Satzzeichen („, ich werde …“, „. Ich werde …“).
/// Leer zurück, wenn der Bereich unbrauchbar ist: nur Satzzeichen, obwohl das Original Wörter hat, oder verdächtig kurz
/// (unter 40 % der Originallänge bei mindestens 16 Zeichen; Deutsch ist meist länger als Englisch).
- (NSString *)cleanedTranslation:(NSString *)translation original:(NSString *)original {
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSCharacterSet *leading = [NSCharacterSet characterSetWithCharactersInString:@",;:."];
    NSString *text = [translation stringByTrimmingCharactersInSet:space] ?: @"";
    while (text.length > 0 && [leading characterIsMember:[text characterAtIndex:0]] && ![original hasPrefix:[text substringToIndex:1]]) {
        text = [[text substringFromIndex:1] stringByTrimmingCharactersInSet:space];
    }
    if (!BrowserSubtitleTranslatorHasLetter(text) && BrowserSubtitleTranslatorHasLetter(original)) {
        return @"";
    }
    if (original.length >= 16 && text.length < original.length * 0.4) {
        return @"";
    }
    return text;
}

@end
