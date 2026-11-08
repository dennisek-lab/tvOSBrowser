#import "BrowserScriptletInjector.h"
#import "BrowserContentBlocker.h"

#import <objc/message.h>

static NSString * const kScriptletResourceDirectory = @"Scriptlets";
static NSString * const kScriptletDataPlaceholder = @"/*BROWSER_SCRIPTLET_DATA*/";
static NSString * const kStateScriptKey = @"script";
static NSString * const kStateSignatureKey = @"signature";
static NSString * const kStateHostsKey = @"hosts";
static NSString * const kStateActiveKey = @"active";
static NSString * const kStateSeenKey = @"seen";

@interface BrowserScriptletInjector ()

@property (nonatomic, strong) dispatch_queue_t loadQueue;
@property (nonatomic) BOOL loaded;
@property (nonatomic, copy, nullable) NSArray<NSString *> *functionNames;
@property (nonatomic, copy, nullable) NSArray<NSString *> *functionCode;
@property (nonatomic, copy, nullable) NSArray *rules;
@property (nonatomic, copy, nullable) NSArray *cssRules;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSDictionary *> *hosts;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSDictionary *> *exceptions;
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *genericRules;
@property (nonatomic, copy, nullable) NSString *libraryVersion;
@property (nonatomic, copy, nullable) NSString *runtimeTemplate;
@property (nonatomic, copy, nullable) NSString *extendedCssSource;
/// Controller (schwach) -> Zustand (Skript, Signatur, Hosts der Seite, aktiv)
@property (nonatomic, strong) NSMapTable<id, NSMutableDictionary *> *controllerStates;

@end

@implementation BrowserScriptletInjector

+ (instancetype)sharedInjector {
    static BrowserScriptletInjector *injector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        injector = [BrowserScriptletInjector new];
    });
    return injector;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _loadQueue = dispatch_queue_create("browser.scriptlets.load", DISPATCH_QUEUE_SERIAL);
        _controllerStates = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

#pragma mark Laden

- (void)prepare {
    dispatch_async(self.loadQueue, ^{
        [self loadIfNeeded];
    });
}

/// Auf loadQueue: entpackt scriptlets.json.z und liest Laufzeit-Vorlage und ExtendedCss.
- (void)loadIfNeeded {
    if (self.loaded) {
        return;
    }
    self.loaded = YES;
    NSDate *start = [NSDate date];
    NSBundle *bundle = NSBundle.mainBundle;
    NSURL *dataURL = [bundle URLForResource:@"scriptlets.json" withExtension:@"z" subdirectory:kScriptletResourceDirectory];
    NSURL *runtimeURL = [bundle URLForResource:@"runtime" withExtension:@"js" subdirectory:kScriptletResourceDirectory];
    NSURL *extendedCssURL = [bundle URLForResource:@"extended-css.min" withExtension:@"js" subdirectory:kScriptletResourceDirectory];
    NSData *packed = dataURL != nil ? [NSData dataWithContentsOfURL:dataURL] : nil;
    NSData *data = packed != nil ? [packed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil] : nil;
    NSDictionary *json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *runtime = runtimeURL != nil ? [NSString stringWithContentsOfURL:runtimeURL encoding:NSUTF8StringEncoding error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class] || runtime.length == 0 || ![runtime containsString:kScriptletDataPlaceholder]) {
        NSLog(@"[Scriptlets] nicht verfügbar (Daten %@, Laufzeit %@)", json != nil ? @"ok" : @"fehlt", runtime.length > 0 ? @"ok" : @"fehlt");
        return;
    }
    self.functionNames = json[@"names"];
    self.functionCode = json[@"fn"];
    self.rules = json[@"rules"];
    self.cssRules = json[@"css"];
    self.hosts = json[@"hosts"];
    self.exceptions = json[@"except"];
    self.genericRules = json[@"generic"][@"s"];
    self.libraryVersion = [json[@"library"][@"scriptlets"] description] ?: @"";
    self.runtimeTemplate = runtime;
    self.extendedCssSource = extendedCssURL != nil ? [NSString stringWithContentsOfURL:extendedCssURL encoding:NSUTF8StringEncoding error:nil] : nil;
    NSLog(@"[Scriptlets] geladen: %lu Scriptlets, %lu CSS-Regeln, %lu Hosts, Stand %@ (%.0f ms)",
          (unsigned long)self.rules.count, (unsigned long)self.cssRules.count, (unsigned long)self.hosts.count,
          json[@"version"], -[start timeIntervalSinceNow] * 1000.0);
}

- (BOOL)ensureLoaded {
    // Immer über loadQueue: prepare lädt dort im Hintergrund, ein ungeschützter Blick auf runtimeTemplate
    // sähe es womöglich schon gesetzt, extendedCssSource und die Regeln aber noch nicht.
    __block BOOL loaded = NO;
    dispatch_sync(self.loadQueue, ^{
        [self loadIfNeeded];
        loaded = self.runtimeTemplate != nil;
    });
    return loaded;
}

#pragma mark Zuordnung Host -> Regeln

/// Schlüssel, unter denen Regeln für einen Host stehen können: alle Oberdomains und Platzhalter-TLDs (google.*).
static NSArray<NSString *> *BrowserScriptletCandidateKeys(NSString *host) {
    NSArray<NSString *> *labels = [host componentsSeparatedByString:@"."];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSArray<NSString *> *tail = [labels subarrayWithRange:NSMakeRange(i, labels.count - i)];
        [keys addObject:[tail componentsJoinedByString:@"."]];
        for (NSUInteger tld = 1; tld <= 2 && tld < tail.count; tld++) {
            NSArray<NSString *> *core = [tail subarrayWithRange:NSMakeRange(0, tail.count - tld)];
            [keys addObject:[[core componentsJoinedByString:@"."] stringByAppendingString:@".*"]];
        }
    }
    return keys;
}

static void BrowserScriptletAddIndexes(NSMutableIndexSet *set, id list) {
    if (![list isKindOfClass:NSArray.class]) {
        return;
    }
    for (NSNumber *n in list) {
        if (n.integerValue >= 0) {
            [set addIndex:n.unsignedIntegerValue];
        }
    }
}

/// Liefert @[Scriptlet-Indizes, CSS-Indizes] für einen Host (Ausnahmen abgezogen).
- (NSArray<NSIndexSet *> *)matchesForHost:(NSString *)host {
    NSMutableIndexSet *scriptlets = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *css = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *exceptScriptlets = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *exceptCss = [NSMutableIndexSet indexSet];
    BOOL allScriptletsOff = NO;
    if (host.length > 0) {
        BrowserScriptletAddIndexes(scriptlets, self.genericRules);
        for (NSString *key in BrowserScriptletCandidateKeys(host)) {
            NSDictionary *entry = self.hosts[key];
            BrowserScriptletAddIndexes(scriptlets, entry[@"s"]);
            BrowserScriptletAddIndexes(css, entry[@"c"]);
            NSDictionary *exception = self.exceptions[key];
            if (exception != nil) {
                if ([exception[@"s"] containsObject:@(-1)]) {
                    allScriptletsOff = YES;
                }
                BrowserScriptletAddIndexes(exceptScriptlets, exception[@"s"]);
                BrowserScriptletAddIndexes(exceptCss, exception[@"c"]);
            }
        }
    }
    if (allScriptletsOff) {
        [scriptlets removeAllIndexes];
    }
    [scriptlets removeIndexes:exceptScriptlets];
    [css removeIndexes:exceptCss];
    return @[scriptlets, css];
}

- (NSUInteger)ruleCountForHost:(NSString *)host {
    if (host.length == 0 || ![self ensureLoaded]) {
        return 0;
    }
    NSArray<NSIndexSet *> *matches = [self matchesForHost:host.lowercaseString];
    return matches[0].count + matches[1].count;
}

#pragma mark Skript bauen

static NSString *BrowserScriptletJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingWithoutEscapingSlashes | NSJSONWritingFragmentsAllowed error:nil];
    return data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}

/// Baut den Quelltext für die Hosts der Seite: nur die benutzten Funktionen und Regeln, lokal neu nummeriert.
- (NSString *)sourceForHostMatches:(NSDictionary<NSString *, NSArray<NSIndexSet *> *> *)hostMatches
                      ruleCount:(NSUInteger *)ruleCountOut {
    NSMutableDictionary<NSNumber *, NSNumber *> *localRule = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *localCss = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *localFunction = [NSMutableDictionary dictionary];
    NSMutableArray *rules = [NSMutableArray array];
    NSMutableArray *css = [NSMutableArray array];
    NSMutableArray<NSString *> *functions = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableDictionary *table = [NSMutableDictionary dictionary];
    BOOL needsExtendedCss = NO;
    for (NSString *host in hostMatches) {
        NSArray<NSIndexSet *> *matches = hostMatches[host];
        NSMutableArray<NSNumber *> *s = [NSMutableArray array];
        NSMutableArray<NSNumber *> *c = [NSMutableArray array];
        [matches[0] enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            NSNumber *local = localRule[@(idx)];
            if (local == nil) {
                NSArray *rule = self.rules[idx];
                NSNumber *fn = rule[0];
                NSNumber *localFn = localFunction[fn];
                if (localFn == nil) {
                    localFn = @(functions.count);
                    localFunction[fn] = localFn;
                    [functions addObject:self.functionCode[fn.unsignedIntegerValue]];
                    [names addObject:self.functionNames[fn.unsignedIntegerValue]];
                }
                local = @(rules.count);
                localRule[@(idx)] = local;
                [rules addObject:@[localFn, rule[1]]];
            }
            [s addObject:local];
        }];
        [matches[1] enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            NSNumber *local = localCss[@(idx)];
            if (local == nil) {
                local = @(css.count);
                localCss[@(idx)] = local;
                [css addObject:self.cssRules[idx]];
            }
            [c addObject:local];
        }];
        for (NSArray *entry in css) {
            if (entry.count > 1 && [entry[1] integerValue] != 0) {
                needsExtendedCss = YES;
                break;
            }
        }
        table[host] = @{@"s": s, @"c": c};
    }
    if (ruleCountOut != NULL) {
        *ruleCountOut = rules.count + css.count;
    }
    NSString *extendedCss = @"null";
    if (needsExtendedCss && self.extendedCssSource.length > 0) {
        // extended-css.min.js definiert `var ExtendedCss`; in einer Funktion bleibt das lokal (kein globaler Name).
        extendedCss = [NSString stringWithFormat:@"function(){\n%@\n;return ExtendedCss;}", self.extendedCssSource];
    }
#if DEBUG
    NSString *debug = @"true";
#else
    NSString *debug = @"false";
#endif
    NSString *data = [NSString stringWithFormat:@"var T=%@;\nvar N=%@;\nvar R=%@;\nvar C=%@;\nvar V=%@;\nvar D=%@;\nvar EC=%@;\nvar F=[\n%@\n];",
                      BrowserScriptletJSON(table), BrowserScriptletJSON(names), BrowserScriptletJSON(rules),
                      BrowserScriptletJSON(css), BrowserScriptletJSON(self.libraryVersion ?: @""), debug, extendedCss,
                      [functions componentsJoinedByString:@",\n"]];
    return [self.runtimeTemplate stringByReplacingOccurrencesOfString:kScriptletDataPlaceholder withString:data];
}

/// Signatur des Zustands, damit bei gleichen Regeln (z. B. Navigation innerhalb von YouTube) nichts getauscht wird.
static NSString *BrowserScriptletSignature(NSDictionary<NSString *, NSArray<NSIndexSet *> *> *hostMatches) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *host in [hostMatches.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray<NSIndexSet *> *m = hostMatches[host];
        [parts addObject:[NSString stringWithFormat:@"%@:%@|%@", host, m[0], m[1]]];
    }
    return [parts componentsJoinedByString:@";"];
}

#pragma mark Einspielen

- (id)makeUserScriptWithSource:(NSString *)source {
    Class scriptClass = NSClassFromString(@"WKUserScript");
    SEL scriptInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (scriptClass == Nil || ![scriptClass instancesRespondToSelector:scriptInit]) {
        return nil;
    }
    id script = [scriptClass alloc];
    // 0 = document-start, NO = alle Frames; Seitenwelt (Scriptlets müssen Seitenobjekte wie fetch/JSON.parse umbiegen).
    return ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(script, scriptInit, source, 0, NO);
}

/// Tauscht das eigene Skript aus. Bevorzugt das private `_removeUserScript:`; sonst wie beim Cookie-Ablehner alle
/// Skripte als echte Kopie merken (userScripts ist eine Live-Ansicht, siehe docs/ERWEITERUNGEN.md) und neu anhängen.
- (void)controller:(id)controller replaceScript:(nullable id)oldScript withScript:(nullable id)newScript {
    SEL addScript = NSSelectorFromString(@"addUserScript:");
    if (![controller respondsToSelector:addScript]) {
        return;
    }
    if (oldScript != nil) {
        SEL removeOne = NSSelectorFromString(@"_removeUserScript:");
        SEL removeAll = NSSelectorFromString(@"removeAllUserScripts");
        SEL scriptsGetter = NSSelectorFromString(@"userScripts");
        if ([controller respondsToSelector:removeOne]) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, removeOne, oldScript);
        } else if ([controller respondsToSelector:removeAll] && [controller respondsToSelector:scriptsGetter]) {
            NSArray *scripts = [NSArray arrayWithArray:((NSArray *(*)(id, SEL))objc_msgSend)(controller, scriptsGetter)];
            ((void (*)(id, SEL))objc_msgSend)(controller, removeAll);
            for (id script in scripts) {
                if (script != oldScript) {
                    ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, script);
                }
            }
        }
    }
    if (newScript != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, newScript);
    }
}

- (void)applyState:(NSMutableDictionary *)state toController:(id)controller {
    NSMutableDictionary<NSString *, NSArray<NSIndexSet *> *> *hostMatches = state[kStateHostsKey];
    BOOL active = [state[kStateActiveKey] boolValue] && hostMatches.count > 0;
    NSString *signature = active ? BrowserScriptletSignature(hostMatches) : @"off";
    if ([state[kStateSignatureKey] isEqualToString:signature]) {
        return;
    }
    id oldScript = state[kStateScriptKey];
    id newScript = nil;
    NSUInteger count = 0;
    NSUInteger bytes = 0;
    if (active) {
        NSString *source = [self sourceForHostMatches:hostMatches ruleCount:&count];
        bytes = source.length;
        newScript = [self makeUserScriptWithSource:source];
    }
    [self controller:controller replaceScript:oldScript withScript:newScript];
    state[kStateScriptKey] = newScript;
    state[kStateSignatureKey] = signature;
#if DEBUG
    if (active) {
        NSLog(@"[Scriptlets] %@ %lu Regeln (%.1f KB)", [hostMatches.allKeys componentsJoinedByString:@","], (unsigned long)count, bytes / 1024.0);
    } else {
        NSLog(@"[Scriptlets] %@", [state[kStateActiveKey] boolValue] ? @"keine Regeln für diese Seite" : @"aus (Schalter oder Ausnahme)");
    }
#endif
}

- (void)updateUserContentController:(id)userContentController forNavigationToURL:(NSURL *)url mainFrame:(BOOL)mainFrame {
    if (userContentController == nil) {
        return;
    }
    NSString *scheme = url.scheme.lowercaseString;
    BOOL web = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    NSString *host = web ? url.host.lowercaseString : nil;
    NSMutableDictionary *state = [self.controllerStates objectForKey:userContentController];
    if (state == nil) {
        if (!mainFrame) {
            return;
        }
        state = [NSMutableDictionary dictionary];
        [self.controllerStates setObject:state forKey:userContentController];
    }
    if (mainFrame) {
        BrowserContentBlocker *blocker = [BrowserContentBlocker sharedBlocker];
        BOOL active = host.length > 0 && blocker.isEnabled && ![blocker isExceptionForURL:url] && [self ensureLoaded];
        state[kStateActiveKey] = @(active);
        state[kStateSeenKey] = [NSMutableSet set];
        NSMutableDictionary *hostMatches = [NSMutableDictionary dictionary];
        if (active) {
            NSArray<NSIndexSet *> *matches = [self matchesForHost:host];
            if (matches[0].count + matches[1].count > 0) {
                hostMatches[host] = matches;
            }
            [state[kStateSeenKey] addObject:host];
        }
        state[kStateHostsKey] = hostMatches;
        [self applyState:state toController:userContentController];
        return;
    }
    // Unterframe: nur ergänzen, wenn für seinen Host Regeln existieren (z. B. eingebettetes YouTube).
    if (![state[kStateActiveKey] boolValue] || host.length == 0 || [state[kStateSeenKey] containsObject:host]) {
        return;
    }
    [state[kStateSeenKey] addObject:host];
    NSArray<NSIndexSet *> *matches = [self matchesForHost:host];
    if (matches[0].count + matches[1].count == 0) {
        return;
    }
    ((NSMutableDictionary *)state[kStateHostsKey])[host] = matches;
    [self applyState:state toController:userContentController];
}

@end
