//
//  BrowserAppleTranslator.m
//  Browser
//

#import "BrowserAppleTranslator.h"
#import "BrowserWebView.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <sys/stat.h>

static NSString * const kTranslationFrameworkPath = @"/System/Library/Frameworks/Translation.framework/Translation";

/// Lädt Translation.framework (falls noch nicht geladen). YES, wenn die zentralen Klassen da sind.
static BOOL BrowserLTLoadFramework(void) {
    static BOOL loaded = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSClassFromString(@"_LTTranslator") == Nil) {
            dlopen(kTranslationFrameworkPath.fileSystemRepresentation, RTLD_NOW);
        }
        loaded = NSClassFromString(@"_LTTranslator") != Nil;
    });
    return loaded;
}

NSString * const BrowserAppleTranslatorErrorDomain = @"BrowserAppleTranslatorErrorDomain";

static NSError *BrowserLTError(BrowserAppleTranslatorError code, NSString *description) {
    return [NSError errorWithDomain:BrowserAppleTranslatorErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL BrowserLTHasLetter(NSString *text) {
    return [text rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound;
}

/// Sprachcode wie "en", "pt-BR", "zh-Hant" in Sprache und Region zerlegen (zh-Hans → CN, zh-Hant → TW).
static void BrowserLTSplitLanguage(NSString *code, NSString **language, NSString **region) {
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:code];
    NSString *lang = locale.languageCode.lowercaseString ?: code.lowercaseString;
    NSString *country = locale.countryCode;
    if ([lang isEqualToString:@"zh"] && country == nil) {
        country = [locale.scriptCode isEqualToString:@"Hant"] || [code.lowercaseString containsString:@"hant"] ? @"TW" : @"CN";
    }
    *language = lang;
    *region = country;
}

/// Apple hängt Teile ohne Buchstaben, die unverändert bleiben (Fußnote „[37]“ aus „[“, „37“, „]“), teils zusätzlich
/// an den Nachbarbereich an („37] Ihre Höhlen“). Solche Wiederholungen am Anfang bzw. Ende entfernen.
static void BrowserLTStripEchoedNeighbours(NSArray<NSString *> *parts, NSMutableArray<NSString *> *translated) {
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger i = 0; i < parts.count; i++) {
        if (!BrowserLTHasLetter(parts[i])) {
            continue;
        }
        NSMutableString *before = [NSMutableString string];
        for (NSInteger j = (NSInteger)i - 1; j >= 0 && !BrowserLTHasLetter(parts[j]); j--) {
            [before insertString:parts[j] atIndex:0];
        }
        NSMutableString *after = [NSMutableString string];
        for (NSUInteger j = i + 1; j < parts.count && !BrowserLTHasLetter(parts[j]); j++) {
            [after appendString:parts[j]];
        }
        NSString *echoBefore = [before stringByTrimmingCharactersInSet:space];
        NSString *echoAfter = [after stringByTrimmingCharactersInSet:space];
        NSString *text = translated[i];
        NSString *trimmed = [text stringByTrimmingCharactersInSet:space];
        // Längstes Ende von „vorher“ (ab 2 Zeichen, einzelne Satzzeichen bleiben), mit dem die Übersetzung beginnt.
        for (NSUInteger length = echoBefore.length; length >= 2; length--) {
            NSString *suffix = [echoBefore substringFromIndex:echoBefore.length - length];
            if ([trimmed hasPrefix:suffix]) {
                NSRange range = [text rangeOfString:suffix];
                text = [text stringByReplacingCharactersInRange:range withString:@""];
                break;
            }
        }
        trimmed = [text stringByTrimmingCharactersInSet:space];
        for (NSUInteger length = echoAfter.length; length >= 2; length--) {
            NSString *prefix = [echoAfter substringToIndex:length];
            if ([trimmed hasSuffix:prefix]) {
                NSRange range = [text rangeOfString:prefix options:NSBackwardsSearch];
                text = [text stringByReplacingCharactersInRange:range withString:@""];
                break;
            }
        }
        translated[i] = text;
    }
}

@interface BrowserAppleTranslator ()
@property (nonatomic, readwrite) BOOL available;
@property (nonatomic, strong, nullable) NSArray *localePairs; // _LTLocalePair
@property (nonatomic) BOOL preparing;
@property (nonatomic, strong) NSMutableArray<void (^)(BOOL)> *prepareWaiters;
@property (nonatomic, strong, nullable) id translator; // _LTTranslator
@end

@implementation BrowserAppleTranslator

+ (BrowserAppleTranslator *)sharedTranslator {
    static BrowserAppleTranslator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[BrowserAppleTranslator alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _prepareWaiters = [NSMutableArray array];
    }
    return self;
}

- (void)prepareWithCompletion:(void (^)(BOOL))completion {
    if (self.localePairs != nil) {
        if (completion != nil) {
            completion(self.available);
        }
        return;
    }
    if (completion != nil) {
        [self.prepareWaiters addObject:[completion copy]];
    }
    if (self.preparing) {
        return;
    }
    Class translatorClass = BrowserLTLoadFramework() ? NSClassFromString(@"_LTTranslator") : Nil;
    SEL pairs = NSSelectorFromString(@"availableLocalePairsForTask:useDedicatedMachPort:completion:");
    if (translatorClass == Nil || ![translatorClass respondsToSelector:pairs] ||
        NSClassFromString(@"_LTParagraphTranslationRequest") == Nil || NSClassFromString(@"_LTTranslationRange") == Nil) {
        NSLog(@"[AppleTranslate] Translation.framework oder Klassen fehlen");
        [self finishPrepareWithPairs:@[]];
        return;
    }
    self.preparing = YES;
    self.translator = [[translatorClass alloc] init];
    __block BOOL answered = NO;
    // Aufgabe 0 = Text. Über den eigenen Mach-Port des Textdienstes (der Hauptdienst ist aus der Sandbox gesperrt).
    ((void (*)(id, SEL, long, BOOL, id))objc_msgSend)(translatorClass, pairs, 0, YES, ^(id list) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (answered) {
                return;
            }
            answered = YES;
            [self finishPrepareWithPairs:[list isKindOfClass:NSArray.class] ? list : @[]];
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!answered) {
            answered = YES;
            NSLog(@"[AppleTranslate] Sprachpaare: keine Antwort in 5 s");
            [self finishPrepareWithPairs:nil];
        }
    });
}

/// pairs nil: beim nächsten Mal erneut versuchen (Zeitüberschreitung), sonst merken.
- (void)finishPrepareWithPairs:(nullable NSArray *)pairs {
    self.preparing = NO;
    self.localePairs = pairs;
    self.available = pairs.count > 0;
    NSLog(@"[AppleTranslate] Textdienst %@, %lu Sprachpaare", self.available ? @"bereit" : @"nicht verfügbar", (unsigned long)pairs.count);
    NSArray *waiters = [self.prepareWaiters copy];
    [self.prepareWaiters removeAllObjects];
    for (void (^waiter)(BOOL) in waiters) {
        waiter(self.available);
    }
}

/// Bestes Locale einer Sprache aus den angebotenen (gewünschte Region, sonst Standardregion, sonst irgendeins).
static NSLocale *BrowserLTBestLocale(NSArray<NSLocale *> *locales, NSString *code) {
    NSString *language = nil, *region = nil;
    BrowserLTSplitLanguage(code, &language, &region);
    NSDictionary *defaults = @{@"en": @"US", @"pt": @"BR", @"zh": @"CN", @"es": @"ES", @"fr": @"FR", @"de": @"DE"};
    NSString *preferred = region ?: defaults[language];
    NSLocale *fallback = nil;
    for (NSLocale *locale in locales) {
        if (![locale.languageCode.lowercaseString isEqualToString:language]) {
            continue;
        }
        if (preferred != nil && [locale.countryCode isEqualToString:preferred]) {
            return locale;
        }
        if (fallback == nil) {
            fallback = locale;
        }
    }
    // zh-Hant ohne TW-Angebot nicht auf vereinfachtes Chinesisch ausweichen (und umgekehrt).
    if ([language isEqualToString:@"zh"]) {
        return nil;
    }
    return fallback;
}

- (NSArray<NSLocale *> *)localesForSourceLanguage:(NSString *)source targetLanguage:(NSString *)target {
    if (!self.available || source.length == 0 || target.length == 0) {
        return nil;
    }
    NSString *sourceLanguage = nil, *targetLanguage = nil, *unused = nil;
    BrowserLTSplitLanguage(source, &sourceLanguage, &unused);
    BrowserLTSplitLanguage(target, &targetLanguage, &unused);
    if ([sourceLanguage isEqualToString:targetLanguage] && ![sourceLanguage isEqualToString:@"zh"]) {
        return nil;
    }
    NSMutableArray<NSLocale *> *targets = [NSMutableArray array];
    for (id pair in self.localePairs) {
        NSLocale *pairTarget = [pair valueForKey:@"targetLocale"];
        if ([pairTarget isKindOfClass:NSLocale.class]) {
            [targets addObject:pairTarget];
        }
    }
    NSLocale *targetLocale = BrowserLTBestLocale(targets, target);
    if (targetLocale == nil) {
        return nil;
    }
    NSMutableArray<NSLocale *> *sources = [NSMutableArray array];
    for (id pair in self.localePairs) {
        NSLocale *pairSource = [pair valueForKey:@"sourceLocale"];
        NSLocale *pairTarget = [pair valueForKey:@"targetLocale"];
        if ([pairTarget.localeIdentifier isEqualToString:targetLocale.localeIdentifier] && [pairSource isKindOfClass:NSLocale.class]) {
            [sources addObject:pairSource];
        }
    }
    NSLocale *sourceLocale = BrowserLTBestLocale(sources, source);
    return sourceLocale != nil ? @[sourceLocale, targetLocale] : nil;
}

- (void)detectLanguageOfTexts:(NSArray<NSString *> *)texts completion:(void (^)(NSString *))completion {
    Class translatorClass = NSClassFromString(@"_LTTranslator");
    SEL selector = NSSelectorFromString(@"languagesForText:usingModel:useDedicatedTextMachPort:completion:");
    if (!self.available || texts.count == 0 || ![translatorClass respondsToSelector:selector]) {
        completion(nil);
        return;
    }
    // Erwartet ein Array von Texten (eine einzelne Zeichenkette bringt translationd zum Absturz).
    ((void (*)(id, SEL, id, unsigned long, BOOL, id))objc_msgSend)(translatorClass, selector, texts, 0, YES, ^(id result, __unused id error) {
        NSLocale *dominant = [result respondsToSelector:NSSelectorFromString(@"dominantLocale")] ? [result valueForKey:@"dominantLocale"] : nil;
        NSString *language = nil;
        if ([dominant isKindOfClass:NSLocale.class]) {
            language = dominant.languageCode;
            if ([language isEqualToString:@"zh"]) {
                language = [dominant.countryCode isEqualToString:@"TW"] || [dominant.scriptCode isEqualToString:@"Hant"] ? @"zh-Hant" : @"zh-Hans";
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(language);
        });
    });
}

- (void)translateParts:(NSArray<NSString *> *)parts source:(NSLocale *)source target:(NSLocale *)target
            completion:(void (^)(NSArray<NSString *> *, BOOL, NSError *))completion {
    Class requestClass = NSClassFromString(@"_LTParagraphTranslationRequest");
    Class rangeClass = NSClassFromString(@"_LTTranslationRange");
    SEL translate = NSSelectorFromString(@"translate:useDedicatedTextMachPort:");
    id translator = self.translator;
    if (requestClass == Nil || rangeClass == Nil || translator == nil || ![translator respondsToSelector:translate] || parts.count == 0) {
        completion(nil, NO, BrowserLTError(BrowserAppleTranslatorErrorUnavailable, @"Apples Übersetzung nicht verfügbar"));
        return;
    }
    SEL rangeInit = NSSelectorFromString(@"initWithIdentifier:text:shouldTranslate:");
    NSMutableArray *ranges = [NSMutableArray arrayWithCapacity:parts.count];
    [parts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger index, __unused BOOL *stop) {
        // Teile ohne Buchstaben (Fußnoten [37], Zahlen, Satzzeichen) bleiben, wie sie sind.
        id range = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)([rangeClass alloc], rangeInit, @(index).stringValue, part,
                                                                 BrowserLTHasLetter(part));
        if (range != nil) {
            [ranges addObject:range];
        }
    }];
    id request = ((id (*)(id, SEL, id, id))objc_msgSend)([requestClass alloc], NSSelectorFromString(@"initWithSourceLocale:targetLocale:"), source, target);
    @try {
        [request setValue:[parts componentsJoinedByString:@""] forKey:@"text"];
        [request setValue:ranges forKey:@"ranges"];
        [request setValue:^(id result, NSError *error) {
            NSArray *candidates = [result respondsToSelector:NSSelectorFromString(@"translations")] ? [result valueForKey:@"translations"] : nil;
            NSString *full = [candidates.firstObject valueForKey:@"formattedString"];
            if (![full isKindOfClass:NSString.class]) {
                completion(nil, NO, [error isKindOfClass:NSError.class] ? error
                           : BrowserLTError(BrowserAppleTranslatorErrorUnavailable, @"Keine Übersetzung erhalten"));
                return;
            }
            NSMutableDictionary<NSString *, NSString *> *aligned = [NSMutableDictionary dictionary];
            for (id alignment in [result valueForKey:@"alignments"]) {
                NSString *identifier = [alignment valueForKey:@"identifier"];
                NSString *text = [alignment valueForKey:@"text"];
                if ([identifier isKindOfClass:NSString.class] && [text isKindOfClass:NSString.class]) {
                    aligned[identifier] = text;
                }
            }
            NSMutableArray<NSString *> *translated = [parts mutableCopy];
            BOOL complete = YES;
            NSUInteger longest = NSNotFound;
            for (NSUInteger i = 0; i < parts.count; i++) {
                NSString *text = aligned[@(i).stringValue];
                if (!BrowserLTHasLetter(parts[i])) {
                    continue; // unverändert lassen
                }
                if (text != nil) {
                    translated[i] = text;
                } else {
                    complete = NO;
                }
                if (BrowserLTHasLetter(parts[i]) && (longest == NSNotFound || parts[i].length > parts[longest].length)) {
                    longest = i;
                }
            }
            if (complete && parts.count > 1) {
                BrowserLTStripEchoedNeighbours(parts, translated);
            }
            if (parts.count == 1) {
                translated[0] = full;
                complete = YES;
            } else if (!complete && longest != NSNotFound) {
                // Bereiche unvollständig (oft nebeneinanderliegende Beschriftungen, die nur scheinbar ein Absatz sind):
                // jeden Wortteil einzeln übersetzen, statt alles in einen Knoten zu schreiben.
                [self translatePartsSeparately:parts translated:translated source:source target:target fallback:full
                                       longest:longest completion:completion];
                return;
            }
            completion(translated, complete, nil);
        } forKey:@"completionHandler"];
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(translator, translate, request, YES);
    } @catch (NSException *exception) {
        completion(nil, NO, BrowserLTError(BrowserAppleTranslatorErrorUnavailable, exception.reason ?: @"Ausnahme"));
    }
}

/// Rückfall bei unvollständigen Bereichen: Wortteile einzeln übersetzen. Scheitert das, steht der ganze Absatz im
/// längsten Teil und die übrigen Wortteile werden geleert.
- (void)translatePartsSeparately:(NSArray<NSString *> *)parts translated:(NSMutableArray<NSString *> *)translated
                          source:(NSLocale *)source target:(NSLocale *)target fallback:(NSString *)full longest:(NSUInteger)longest
                      completion:(void (^)(NSArray<NSString *> *, BOOL, NSError *))completion {
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
    for (NSUInteger i = 0; i < parts.count; i++) {
        if (BrowserLTHasLetter(parts[i])) {
            [indexes addObject:@(i)];
        }
    }
    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [NSObject new];
    __block BOOL failed = NO;
    for (NSNumber *number in indexes) {
        NSUInteger index = number.unsignedIntegerValue;
        dispatch_group_enter(group);
        [self translateParts:@[parts[index]] source:source target:target completion:^(NSArray<NSString *> *single, __unused BOOL used, __unused NSError *error) {
            @synchronized (lock) {
                if (single.count == 1) {
                    translated[index] = single[0];
                } else {
                    failed = YES;
                }
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (failed) {
            for (NSNumber *number in indexes) {
                NSUInteger index = number.unsignedIntegerValue;
                translated[index] = index == longest ? full : @"";
            }
        }
        completion(translated, NO, nil);
    });
}

#if DEBUG

extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

/// Beschreibt einen Blockparameter, dessen Typ unbekannt ist: nil, Objekt (Heap oder Tagged Pointer) oder Zahl.
static NSString *LTDescribe(uintptr_t value) {
    if (value == 0) {
        return @"0/nil";
    }
    if ((intptr_t)value < 0) { // Tagged Pointer (NSNumber, kurze NSString)
        id object = (__bridge id)(void *)value;
        return [NSString stringWithFormat:@"<%@> %@", NSStringFromClass(object_getClass(object)), object];
    }
    if (value < 0x100000000ULL) {
        return [NSString stringWithFormat:@"int %lu", (unsigned long)value];
    }
    if (malloc_size((const void *)value) > 0) {
        id object = (__bridge id)(void *)value;
        Class cls = object_getClass(object);
        if (cls != Nil) {
            NSString *description = [object description];
            if ([object isKindOfClass:NSError.class]) {
                NSError *error = object;
                description = [NSString stringWithFormat:@"%@ code=%ld userInfo=%@", error.domain, (long)error.code, error.userInfo];
            }
            return [NSString stringWithFormat:@"<%@> %@", NSStringFromClass(cls), description];
        }
    }
    return [NSString stringWithFormat:@"ptr 0x%lx", (unsigned long)value];
}

static void LTLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LTLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    // NSLog kürzt lange Zeilen; in Stücken ausgeben.
    NSUInteger chunk = 900;
    for (NSUInteger i = 0; i < line.length; i += chunk) {
        NSString *part = [line substringWithRange:NSMakeRange(i, MIN(chunk, line.length - i))];
        NSLog(@"[LTProbe]%@ %@", i == 0 ? @"" : @"+", part);
    }
}

static void LTDumpClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (cls == Nil) {
        LTLog(@"Klasse %@: FEHLT", name);
        return;
    }
    NSMutableArray *parts = [NSMutableArray array];
    unsigned count = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &count);
    for (unsigned i = 0; i < count; i++) {
        [parts addObject:[NSString stringWithFormat:@"@%s", property_getName(properties[i])]];
    }
    free(properties);
    for (int meta = 1; meta >= 0; meta--) {
        Class target = meta ? object_getClass(cls) : cls;
        Method *methods = class_copyMethodList(target, &count);
        for (unsigned i = 0; i < count; i++) {
            NSString *selector = NSStringFromSelector(method_getName(methods[i]));
            if ([selector hasPrefix:@"."] || [selector containsString:@"Coder"] || [selector isEqualToString:@"hash"] ||
                [selector hasPrefix:@"isEqual"] || [selector hasPrefix:@"copyWithZone"] || [selector hasPrefix:@"set"]) {
                continue;
            }
            [parts addObject:[NSString stringWithFormat:@"%c%@ %s", meta ? '+' : '-', selector, method_getTypeEncoding(methods[i])]];
        }
        free(methods);
    }
    LTLog(@"Klasse %@ : %s | %@", name, class_getName(class_getSuperclass(cls)), [parts componentsJoinedByString:@" | "]);
}

typedef void (^LTAnyBlock)(uintptr_t a, uintptr_t b, uintptr_t c);

static LTAnyBlock LTLoggingBlock(NSString *label) {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    return ^(uintptr_t a, uintptr_t b, uintptr_t c) {
        LTLog(@"%@ nach %.2f s: a=%@ | b=%@ | c=%@", label, CFAbsoluteTimeGetCurrent() - start, LTDescribe(a), LTDescribe(b), LTDescribe(c));
    };
}

/// Ruft eine Methode mit einem Block als letztem Parameter auf, falls die Klasse sie kennt.
static void LTCall(id target, NSString *selectorName, NSArray *objectArgs, NSString *label) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        LTLog(@"%@: %@ fehlt", label, selectorName);
        return;
    }
    LTAnyBlock block = LTLoggingBlock(label);
    LTLog(@"%@: rufe %@", label, selectorName);
    @try {
        switch (objectArgs.count) {
            case 0:
                ((void (*)(id, SEL, id))objc_msgSend)(target, selector, block);
                break;
            case 1:
                ((void (*)(id, SEL, id, id))objc_msgSend)(target, selector, objectArgs[0], block);
                break;
            case 2:
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(target, selector, objectArgs[0], objectArgs[1], block);
                break;
            default:
                break;
        }
    } @catch (NSException *exception) {
        LTLog(@"%@: Ausnahme %@", label, exception);
    }
}

- (void)runProbeDumpingClasses:(BOOL)dumpClasses {
    LTLog(@"Start, System %@", NSProcessInfo.processInfo.operatingSystemVersionString);
    BOOL before = NSClassFromString(@"_LTTranslator") != Nil;
    BOOL loaded = BrowserLTLoadFramework();
    LTLog(@"Translation.framework vorher geladen=%d, nachher Klassen da=%d, dlerror=%s", before, loaded, dlerror() ?: "-");
    struct stat info;
    for (NSString *path in @[kTranslationFrameworkPath,
                             @"/System/Library/Frameworks/Translation.framework/translationd",
                             @"/System/Library/PrivateFrameworks/TranslationDaemon.framework",
                             @"/System/Library/LaunchDaemons/com.apple.translationd.plist",
                             @"/System/Library/LaunchAgents/com.apple.translationd.plist"]) {
        LTLog(@"Pfad %@: %@", path, stat(path.fileSystemRepresentation, &info) == 0 ? @"vorhanden" : [NSString stringWithFormat:@"fehlt (errno %d)", errno]);
    }
    for (NSString *service in @[@"com.apple.translationd", @"com.apple.translation.text", @"com.apple.siri.translation"]) {
        mach_port_t port = MACH_PORT_NULL;
        kern_return_t result = bootstrap_look_up(bootstrap_port, service.UTF8String, &port);
        LTLog(@"Mach-Dienst %@: kr=%d (%s)%@", service, result, mach_error_string(result),
              result == KERN_SUCCESS ? @" -> erreichbar" : (result == 1100 ? @" -> Sandbox verweigert" : (result == 1102 ? @" -> unbekannt" : @"")));
        if (port != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), port);
        }
    }
    if (!loaded) {
        LTLog(@"Ende: Framework nicht ladbar");
        return;
    }
    for (NSString *name in @[@"_LTTranslator", @"_LTTextSession", @"_LTTextSessionConfiguration", @"_LTTranslationSession",
                             @"_LTTranslationRequest", @"_LTTextTranslationRequest", @"_LTBatchTextTranslationRequest",
                             @"_LTTranslationParagraph", @"_LTTranslationResult", @"_LTTextResult", @"_LTLanguageAvailability",
                             @"_LTLocalePair", @"_LTTextLanguageDetectionResult", @"_LTTaskContext", @"_LTPreflightChecker"]) {
        if (dumpClasses) {
            LTDumpClass(name);
        }
    }

    Class translator = NSClassFromString(@"_LTTranslator");
    NSLocale *en = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    NSLocale *de = [NSLocale localeWithLocaleIdentifier:@"de_DE"];
    NSString *text = @"The quick brown fox jumps over the lazy dog.";

    // Verfügbarkeit über den Textdienst (com.apple.translation.text ist aus der Sandbox erreichbar,
    // com.apple.translationd nicht: Klassenmethoden ohne "DedicatedMachPort" scheitern mit NSXPC 4099).
    LTCall(translator, @"onDeviceModeSupported:", @[], @"onDeviceModeSupported(translationd)");
    SEL pairs = NSSelectorFromString(@"availableLocalePairsForTask:useDedicatedMachPort:completion:");
    ((void (*)(id, SEL, long, BOOL, id))objc_msgSend)(translator, pairs, 0, YES, ^(NSArray *list) {
        NSArray *german = [list filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"targetLocale.localeIdentifier BEGINSWITH 'de'"]];
        LTLog(@"availableLocalePairs(text): %lu Paare, davon nach Deutsch %lu: %@", (unsigned long)list.count, (unsigned long)german.count,
              [[german valueForKeyPath:@"sourceLocale.localeIdentifier"] componentsJoinedByString:@","]);
    });
    SEL languages = NSSelectorFromString(@"languagesForText:usingModel:useDedicatedTextMachPort:completion:");
    ((void (*)(id, SEL, id, unsigned long, BOOL, id))objc_msgSend)(translator, languages, @[text, @"Der schnelle braune Fuchs."], 0, YES,
                                                                    LTLoggingBlock(@"languagesForText(text)"));

    // A: _LTTextSession (Unterbau der öffentlichen TranslationSession): Code 20, auch mit allowOnlineTranslation.
    id session = ((id (*)(id, SEL, id, id, long))objc_msgSend)([NSClassFromString(@"_LTTextSession") alloc],
                                                                NSSelectorFromString(@"initWithSourceLocale:targetLocale:preferredStrategy:"), en, de, 0);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(session, NSSelectorFromString(@"setAllowOnlineTranslation:"), YES);
    objc_setAssociatedObject(self, (__bridge const void *)session, session, OBJC_ASSOCIATION_RETAIN);
    LTCall(session, @"translateString:completionHandler:", @[text], @"A TextSession");

    // B: _LTTextTranslationRequest/_LTBatchTextTranslationRequest: Code 17 (CLIENT_REQUIRES_TEXT_SERVICE), sie können
    // den Textdienst nicht nutzen. D: _LTParagraphTranslationRequest kann es (_canUseTextService).
    id instance = [[translator alloc] init];
    objc_setAssociatedObject(self, @selector(runProbeDumpingClasses:), instance, OBJC_ASSOCIATION_RETAIN);
    SEL dedicated = NSSelectorFromString(@"translate:useDedicatedTextMachPort:");
    void (^describeResult)(NSString *, id, NSError *) = ^(NSString *label, id result, NSError *error) {
        if (result == nil) {
            LTLog(@"%@: Fehler %@ %ld %@", label, error.domain, (long)error.code, error.userInfo);
            return;
        }
        NSMutableArray *candidates = [NSMutableArray array];
        for (id candidate in [result valueForKey:@"translations"]) {
            [candidates addObject:[NSString stringWithFormat:@"\"%@\" (conf %.2f, tokens %lu)", [candidate valueForKey:@"formattedString"],
                                   [[candidate valueForKey:@"confidence"] doubleValue], (unsigned long)[[candidate valueForKey:@"tokens"] count]]];
        }
        LTLog(@"%@: route=%@ engine=%@ locale=%@ quelle=\"%@\" -> %@ | alignments=%@", label, [result valueForKey:@"route"],
              [result valueForKey:@"engineInfo"], [result valueForKey:@"locale"], [result valueForKey:@"sourceString"],
              [candidates componentsJoinedByString:@" / "], [result valueForKey:@"alignments"]);
    };
    id (^paragraph)(NSString *) = ^id(NSString *source) {
        return ((id (*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"_LTParagraphTranslationRequest") alloc],
                                                       NSSelectorFromString(@"initWithSourceLocale:targetLocale:"), en, de);
    };
    for (int offline = 0; offline <= 1; offline++) {
        id request = paragraph(text);
        NSString *label = [NSString stringWithFormat:@"D Paragraph offline=%d", offline];
        [request setValue:text forKey:@"text"];
        [request setValue:@(offline) forKey:@"forcedOfflineTranslation"];
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        [request setValue:^(id result, NSError *error) {
            describeResult([NSString stringWithFormat:@"%@ nach %.2f s", label, CFAbsoluteTimeGetCurrent() - start], result, error);
        } forKey:@"completionHandler"];
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(instance, dedicated, request, YES);
    }

    // F: Absatz mit Bereichen (Textknoten, z. B. Link in der Mitte) – bleiben die Grenzen erhalten?
    {
        Class rangeClass = NSClassFromString(@"_LTTranslationRange");
        SEL rangeInit = NSSelectorFromString(@"initWithIdentifier:text:shouldTranslate:");
        NSArray *parts = @[@"The quick ", @"brown fox", @" jumps over the ", @"lazy dog", @"."];
        NSMutableArray *ranges = [NSMutableArray array];
        [parts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger index, __unused BOOL *stop) {
            [ranges addObject:((id (*)(id, SEL, id, id, BOOL))objc_msgSend)([rangeClass alloc], rangeInit,
                                                                           [NSString stringWithFormat:@"r%lu", (unsigned long)index], part, YES)];
        }];
        id request = paragraph(text);
        [request setValue:[parts componentsJoinedByString:@""] forKey:@"text"];
        [request setValue:ranges forKey:@"ranges"];
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        [request setValue:^(id result, NSError *error) {
            describeResult([NSString stringWithFormat:@"F Bereiche nach %.2f s", CFAbsoluteTimeGetCurrent() - start], result, error);
            for (id alignment in [result valueForKey:@"alignments"]) {
                LTLog(@"F alignment %@", [alignment valueForKey:@"jsonRepresentation"]);
            }
        } forKey:@"completionHandler"];
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(instance, dedicated, request, YES);

        // F2: attributierter Text mit eigenem Attribut je Bereich
        NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] init];
        [parts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger index, __unused BOOL *stop) {
            [attributed appendAttributedString:[[NSAttributedString alloc] initWithString:part attributes:@{@"BrowserNode": @(index)}]];
        }];
        id request2 = paragraph(text);
        [request2 setValue:attributed forKey:@"attributedText"];
        [request2 setValue:^(id result, NSError *error) {
            describeResult(@"F2 attributiert", result, error);
        } forKey:@"completionHandler"];
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(instance, dedicated, request2, YES);
    }

    // F3: Umstellung im Deutschen, Bereich ohne Übersetzung (Code), Quellsprache ohne Region (fr)
    {
        Class rangeClass = NSClassFromString(@"_LTTranslationRange");
        SEL rangeInit = NSSelectorFromString(@"initWithIdentifier:text:shouldTranslate:");
        NSArray *parts = @[@"Yesterday I ", @"bought", @" a new car and typed ", @"rm -rf /tmp", @" in the terminal."];
        NSMutableArray *ranges = [NSMutableArray array];
        [parts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger index, __unused BOOL *stop) {
            [ranges addObject:((id (*)(id, SEL, id, id, BOOL))objc_msgSend)([rangeClass alloc], rangeInit,
                                                                           [NSString stringWithFormat:@"n%lu", (unsigned long)index], part, index != 3)];
        }];
        NSArray *pairsToTry = @[@[@"en", @"de"], @[@"fr", @"de"]];
        for (NSArray *pair in pairsToTry) {
            id request = ((id (*)(id, SEL, id, id))objc_msgSend)([NSClassFromString(@"_LTParagraphTranslationRequest") alloc],
                NSSelectorFromString(@"initWithSourceLocale:targetLocale:"), [NSLocale localeWithLocaleIdentifier:pair[0]], [NSLocale localeWithLocaleIdentifier:pair[1]]);
            BOOL french = [pair[0] isEqualToString:@"fr"];
            NSArray *useParts = french ? @[@"Hier j'ai ", @"acheté", @" une nouvelle voiture et tapé ", @"rm -rf /tmp", @" dans le terminal."] : parts;
            NSMutableArray *useRanges = [NSMutableArray array];
            [useParts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger index, __unused BOOL *stop) {
                [useRanges addObject:((id (*)(id, SEL, id, id, BOOL))objc_msgSend)([rangeClass alloc], rangeInit,
                                                                                  [NSString stringWithFormat:@"n%lu", (unsigned long)index], part, index != 3)];
            }];
            [request setValue:[useParts componentsJoinedByString:@""] forKey:@"text"];
            [request setValue:useRanges forKey:@"ranges"];
            NSString *label = [NSString stringWithFormat:@"F3 %@->%@", pair[0], pair[1]];
            [request setValue:^(id result, NSError *error) {
                describeResult(label, result, error);
                for (id alignment in [result valueForKey:@"alignments"]) {
                    LTLog(@"%@ alignment %@", label, [alignment valueForKey:@"jsonRepresentation"]);
                }
            } forKey:@"completionHandler"];
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(instance, dedicated, request, YES);
        }
        (void)ranges;
    }

    // G: 20 Absätze gleichzeitig (Seitenübersetzung)
    {
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        __block NSUInteger done = 0, failed = 0;
        for (NSUInteger i = 0; i < 20; i++) {
            id request = paragraph(text);
            [request setValue:[NSString stringWithFormat:@"Paragraph number %lu: the weather is nice today and we are going for a walk in the park.", (unsigned long)i + 1] forKey:@"text"];
            [request setValue:^(id result, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    done++;
                    failed += result == nil ? 1 : 0;
                    if (done == 20) {
                        LTLog(@"G 20 Absätze: fertig nach %.2f s, Fehler %lu, letzter: %@", CFAbsoluteTimeGetCurrent() - start, (unsigned long)failed,
                              [[[result valueForKey:@"translations"] firstObject] valueForKey:@"formattedString"] ?: error);
                    }
                });
            } forKey:@"completionHandler"];
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(instance, dedicated, request, YES);
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LTLog(@"20 s vorbei (fehlende Rückmeldungen = hängt)");
    });
}

#endif

@end

#pragma mark - Seite übersetzen (DOM)

static NSString * const kPageTranslationWorld = @"BrowserTranslation";
static const NSUInteger kBatchParagraphs = 30;
static const NSUInteger kBatchCharacters = 15000;
static const NSTimeInterval kBatchTimeout = 20.0;

static NSString *BrowserPageTranslationScript(void) {
    static NSString *script;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"page-translation" ofType:@"js" inDirectory:@"PageTranslation"];
        script = path != nil ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
        if (script.length == 0) {
            NSLog(@"[AppleTranslate] PageTranslation/page-translation.js fehlt");
        }
    });
    return script;
}

@interface BrowserPageTranslation ()
@property (nonatomic, weak, readwrite) BrowserWebView *webView;
@property (nonatomic, readwrite) BOOL active;
@property (nonatomic, copy, readwrite, nullable) NSString *sourceLanguage;
@property (nonatomic, copy, readwrite) NSString *targetLanguage;
@property (nonatomic, readwrite) NSUInteger translatedParagraphs;
@property (nonatomic, readwrite) NSUInteger failedParagraphs;
@property (nonatomic, strong, nullable) NSLocale *sourceLocale;
@property (nonatomic, strong, nullable) NSLocale *targetLocale;
@property (nonatomic, copy, nullable) void (^firstBatchHandler)(BOOL, NSError *);
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger fallbackParagraphs;
@property (nonatomic) CFAbsoluteTime startTime;
@end

@implementation BrowserPageTranslation

- (instancetype)initWithWebView:(BrowserWebView *)webView sourceLanguage:(NSString *)sourceLanguage targetLanguage:(NSString *)targetLanguage {
    self = [super init];
    if (self) {
        _webView = webView;
        _sourceLanguage = [sourceLanguage copy];
        _targetLanguage = [targetLanguage copy];
    }
    return self;
}

- (void)evaluate:(NSString *)script completion:(void (^)(id result, NSError *error))completion {
    BrowserWebView *webView = self.webView;
    if (webView == nil) {
        completion(nil, BrowserLTError(BrowserAppleTranslatorErrorPageGone, @"Seite geschlossen"));
        return;
    }
    [webView evaluateJavaScript:script inContentWorldNamed:kPageTranslationWorld resultHandler:completion];
}

- (void)finishFirstBatch:(BOOL)ok error:(NSError *)error {
    void (^handler)(BOOL, NSError *) = self.firstBatchHandler;
    self.firstBatchHandler = nil;
    if (handler != nil) {
        handler(ok, error);
    }
}

/// Abbruch vor dem ersten Erfolg: alles zurücksetzen und den Aufrufer informieren (Rückfall Google).
- (void)failWithError:(NSError *)error {
    NSLog(@"[AppleTranslate] abgebrochen: %@", error.localizedDescription);
    [self stopRestoringOriginal:YES completion:nil];
    [self finishFirstBatch:NO error:error];
}

- (void)startWithFirstBatchHandler:(void (^)(BOOL, NSError *))firstBatch {
    self.firstBatchHandler = firstBatch;
    self.startTime = CFAbsoluteTimeGetCurrent();
    NSUInteger generation = ++self.generation;
    [BrowserAppleTranslator.sharedTranslator prepareWithCompletion:^(BOOL available) {
        if (self.generation != generation) {
            return;
        }
        NSString *script = BrowserPageTranslationScript();
        if (!available || script.length == 0) {
            [self finishFirstBatch:NO error:BrowserLTError(BrowserAppleTranslatorErrorUnavailable, @"Apples Übersetzung nicht verfügbar")];
            return;
        }
        if (self.sourceLanguage != nil && ![self resolveLocales]) {
            [self finishFirstBatch:NO error:BrowserLTError(BrowserAppleTranslatorErrorUnsupportedPair, @"Sprachpaar wird von Apple nicht angeboten")];
            return;
        }
        NSString *language = [NSLocale localeWithLocaleIdentifier:self.targetLanguage].languageCode ?: self.targetLanguage;
        BOOL spaces = ![@[@"zh", @"ja", @"th", @"lo", @"km", @"my"] containsObject:language];
        NSString *start = [NSString stringWithFormat:@"\n;window.__btr.start({spaces: %@});", spaces ? @"true" : @"false"];
        [self evaluate:[script stringByAppendingString:start] completion:^(id result, NSError *error) {
            if (self.generation != generation) {
                return;
            }
            if (![result isKindOfClass:NSDictionary.class]) {
                NSLog(@"[AppleTranslate] Start fehlgeschlagen: %@", error.userInfo[@"WKJavaScriptExceptionMessage"] ?: error);
                [self finishFirstBatch:NO error:BrowserLTError(BrowserAppleTranslatorErrorPageGone, @"Skript ließ sich nicht starten")];
                return;
            }
            NSLog(@"[AppleTranslate] gestartet %@ -> %@, %@ Absätze gefunden", self.sourceLanguage ?: @"(erkennen)", self.targetLanguage, result[@"n"]);
            self.active = YES;
            [self pump];
        }];
    }];
}

- (BOOL)resolveLocales {
    NSArray<NSLocale *> *locales = [BrowserAppleTranslator.sharedTranslator localesForSourceLanguage:self.sourceLanguage targetLanguage:self.targetLanguage];
    if (locales.count != 2) {
        NSLog(@"[AppleTranslate] kein Sprachpaar %@ -> %@", self.sourceLanguage, self.targetLanguage);
        return NO;
    }
    self.sourceLocale = locales[0];
    self.targetLocale = locales[1];
    return YES;
}

/// Nächsten Stapel aus der Seite holen. Leer: später erneut (sichtbarer Bereich, nachgeladene Inhalte).
- (void)pump {
    if (!self.active) {
        return;
    }
    NSUInteger generation = self.generation;
    NSString *take = [NSString stringWithFormat:@"window.__btr ? window.__btr.take(%lu, %lu) : null",
                      (unsigned long)kBatchParagraphs, (unsigned long)kBatchCharacters];
    [self evaluate:take completion:^(id result, NSError *error) {
        if (self.generation != generation || !self.active) {
            return;
        }
        if (![result isKindOfClass:NSArray.class]) {
            // Neues Dokument (Skript weg) oder Fehler: Übersetzung ist vorbei.
            NSLog(@"[AppleTranslate] Seite ohne Übersetzungsskript (%@), beendet", error.localizedDescription ?: @"neues Dokument");
            self.active = NO;
            [self finishFirstBatch:NO error:BrowserLTError(BrowserAppleTranslatorErrorPageGone, @"Seite gewechselt")];
            return;
        }
        NSArray *paragraphs = result;
        if (paragraphs.count == 0) {
            if (self.firstBatchHandler != nil && CFAbsoluteTimeGetCurrent() - self.startTime > 8.0) {
                [self failWithError:BrowserLTError(BrowserAppleTranslatorErrorNoText, @"Kein übersetzbarer Text gefunden")];
                return;
            }
            BrowserWebView *webView = self.webView;
            NSTimeInterval delay = self.firstBatchHandler != nil ? 0.25 : (webView.window != nil ? 0.7 : 3.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.generation == generation) {
                    [self pump];
                }
            });
            return;
        }
        if (self.sourceLocale == nil) {
            [self detectLanguageForParagraphs:paragraphs generation:generation];
            return;
        }
        [self translateParagraphs:paragraphs generation:generation];
    }];
}

- (void)detectLanguageForParagraphs:(NSArray *)paragraphs generation:(NSUInteger)generation {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSUInteger length = 0;
    for (NSDictionary *paragraph in paragraphs) {
        NSMutableString *text = [NSMutableString string];
        for (NSArray *part in paragraph[@"p"]) {
            if ([part isKindOfClass:NSArray.class] && part.count == 2 && [part[1] isKindOfClass:NSString.class]) {
                [text appendString:part[1]];
            }
        }
        if (text.length > 20) {
            [texts addObject:text];
            length += text.length;
        }
        if (length > 3000) {
            break;
        }
    }
    [BrowserAppleTranslator.sharedTranslator detectLanguageOfTexts:texts.count > 0 ? texts : @[@""] completion:^(NSString *language) {
        if (self.generation != generation) {
            return;
        }
        NSLog(@"[AppleTranslate] Sprache erkannt: %@", language ?: @"?");
        self.sourceLanguage = language;
        if (language == nil || ![self resolveLocales]) {
            NSError *error = language == nil ? BrowserLTError(BrowserAppleTranslatorErrorUnknownLanguage, @"Sprache nicht erkannt")
                                             : BrowserLTError(BrowserAppleTranslatorErrorUnsupportedPair, @"Sprachpaar wird von Apple nicht angeboten");
            [self failWithError:error];
            return;
        }
        [self translateParagraphs:paragraphs generation:generation];
    }];
}

- (void)translateParagraphs:(NSArray *)paragraphs generation:(NSUInteger)generation {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSUInteger count = paragraphs.count;
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *paragraph = paragraphs[i];
        NSString *identifier = [paragraph isKindOfClass:NSDictionary.class] && [paragraph[@"i"] isKindOfClass:NSString.class] ? paragraph[@"i"] : @"";
        [results addObject:@{@"i": identifier, @"f": @1}]; // bis zur Antwort: fehlgeschlagen
    }
    __block NSUInteger pending = count;
    __block BOOL finished = NO;
    __block NSError *lastError = nil;
    __block NSUInteger fallbacks = 0;
    void (^finish)(void) = ^{
        if (finished) {
            return;
        }
        finished = YES;
        [self applyResults:results count:count error:lastError fallbacks:fallbacks elapsed:CFAbsoluteTimeGetCurrent() - start generation:generation];
    };
    BrowserAppleTranslator *translator = BrowserAppleTranslator.sharedTranslator;
    [paragraphs enumerateObjectsUsingBlock:^(NSDictionary *paragraph, NSUInteger index, __unused BOOL *stop) {
        NSString *identifier = results[index][@"i"];
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        NSArray *parts = [paragraph isKindOfClass:NSDictionary.class] && [paragraph[@"p"] isKindOfClass:NSArray.class] ? paragraph[@"p"] : @[];
        for (NSArray *part in parts) {
            if ([part isKindOfClass:NSArray.class] && part.count == 2 && [part[0] isKindOfClass:NSString.class] && [part[1] isKindOfClass:NSString.class]) {
                [ids addObject:part[0]];
                [texts addObject:part[1]];
            }
        }
        if (identifier.length == 0 || texts.count == 0) {
            if (--pending == 0) {
                finish();
            }
            return;
        }
        [translator translateParts:texts source:self.sourceLocale target:self.targetLocale
                        completion:^(NSArray<NSString *> *translated, BOOL usedAlignment, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (finished) {
                    return;
                }
                if (translated.count == ids.count) {
                    NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:ids.count]; // Reihenfolge wie in der Seite
                    [ids enumerateObjectsUsingBlock:^(NSString *nodeId, NSUInteger i, __unused BOOL *stop) {
                        [pairs addObject:@[nodeId, translated[i]]];
                    }];
                    results[index] = @{@"i": identifier, @"t": pairs};
                    fallbacks += usedAlignment ? 0 : 1;
                } else {
                    lastError = error;
                }
                if (--pending == 0) {
                    finish();
                }
            });
        }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBatchTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (finished) {
            return;
        }
        NSLog(@"[AppleTranslate] Stapel: %lu von %lu ohne Antwort nach %.0f s", (unsigned long)pending, (unsigned long)count, kBatchTimeout);
        lastError = lastError ?: BrowserLTError(BrowserAppleTranslatorErrorTimeout, @"Zeitüberschreitung");
        finish();
    });
}

- (void)applyResults:(NSArray *)results count:(NSUInteger)count error:(NSError *)error fallbacks:(NSUInteger)fallbacks
             elapsed:(NSTimeInterval)elapsed generation:(NSUInteger)generation {
    if (self.generation != generation || !self.active) {
        return;
    }
    NSUInteger ok = 0;
    for (NSDictionary *result in results) {
        ok += result[@"t"] != nil ? 1 : 0;
    }
    NSUInteger failed = count - ok;
    self.fallbackParagraphs += fallbacks;
    NSLog(@"[AppleTranslate] Stapel %lu Absätze in %.2f s: ok %lu, Fehler %lu, ohne Bereiche %lu%@", (unsigned long)count, elapsed,
          (unsigned long)ok, (unsigned long)failed, (unsigned long)fallbacks,
          error != nil ? [NSString stringWithFormat:@" (%@ %ld: %@)", error.domain, (long)error.code, error.localizedDescription] : @"");
    if (ok == 0 && self.firstBatchHandler != nil) {
        [self failWithError:error ?: BrowserLTError(BrowserAppleTranslatorErrorUnavailable, @"Übersetzung fehlgeschlagen")];
        return;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
    NSString *payload = json != nil ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"[]";
    [self evaluate:[NSString stringWithFormat:@"window.__btr ? window.__btr.apply(%@) : -1", payload] completion:^(__unused id applied, NSError *applyError) {
        if (self.generation != generation) {
            return;
        }
        if (applyError != nil) {
            NSLog(@"[AppleTranslate] Einsetzen fehlgeschlagen: %@", applyError.userInfo[@"WKJavaScriptExceptionMessage"] ?: applyError);
        }
        self.translatedParagraphs += ok;
        self.failedParagraphs += failed;
        if (ok > 0) {
            [self finishFirstBatch:YES error:nil];
        }
        [self pump];
    }];
}

- (void)stopRestoringOriginal:(BOOL)restore completion:(void (^)(NSUInteger))completion {
    self.generation++;
    self.active = NO;
    NSLog(@"[AppleTranslate] beendet (%lu Absätze übersetzt, %lu Fehler, %lu ohne Bereiche)%@", (unsigned long)self.translatedParagraphs,
          (unsigned long)self.failedParagraphs, (unsigned long)self.fallbackParagraphs, restore ? @", Original wird hergestellt" : @"");
    if (!restore || self.webView == nil) {
        if (completion != nil) {
            completion(0);
        }
        return;
    }
    [self evaluate:@"window.__btr ? window.__btr.restore() : 0" completion:^(id result, __unused NSError *error) {
        if (completion != nil) {
            completion([result respondsToSelector:@selector(unsignedIntegerValue)] ? [result unsignedIntegerValue] : 0);
        }
    }];
}

#if DEBUG
- (void)debugStateWithCompletion:(void (^)(NSString *))completion {
    [self evaluate:@"JSON.stringify(window.__btr ? window.__btr.state() : null)" completion:^(id result, __unused NSError *error) {
        completion([NSString stringWithFormat:@"aktiv=%d quelle=%@ übersetzt=%lu fehler=%lu ohneBereiche=%lu seite=%@", self.active,
                    self.sourceLanguage ?: @"?", (unsigned long)self.translatedParagraphs, (unsigned long)self.failedParagraphs,
                    (unsigned long)self.fallbackParagraphs, result ?: @"-"]);
    }];
}
#endif

@end
