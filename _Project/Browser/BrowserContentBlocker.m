#import "BrowserContentBlocker.h"
#import "BrowserFilterListUpdater.h"
#import "BrowserLocalization.h"
#import "BrowserPreferencesStore.h"
#import "BrowserPerf.h"

#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kBlockerResourceDirectory = @"ContentBlocker";
static NSString * const kBlockerIdentifierPrefix = @"adblock-";
static NSString * const kStateExceptionKey = @"exception";
static NSString * const kStateSignatureKey = @"signature";
static NSString * const kWallMessageName = @"browserAdblockWall";

@class BrowserContentBlocker;

/// Empfängt {host, text, top} der Sperren-Erkennung (adblock-wall.js).
@interface BrowserAdblockWallMessageProxy : NSObject
@property (nonatomic, weak) BrowserContentBlocker *blocker;
@end

@interface BrowserContentBlocker ()

@property (nonatomic) BOOL started;
@property (nonatomic, strong, nullable) id store;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingEntries;
@property (nonatomic, strong) NSMutableArray *readyLists;
@property (nonatomic, copy) NSArray<NSString *> *wantedIdentifiers;
@property (nonatomic) NSUInteger totalListCount;
/// Ordner der .json.z des aktuellen Stands (App-Paket oder Library/Caches/FilterLists/…) und dessen Manifest.
@property (nonatomic, strong, nullable) NSURL *sourceDirectory;
@property (nonatomic, copy, nullable) NSDictionary *sourceManifest;
@property (nonatomic) BOOL sourceDownloaded;
/// Wird bei jedem Wechsel des Listenstands erhöht; Rückmeldungen eines älteren Durchgangs werden verworfen.
@property (nonatomic) NSUInteger generation;
/// Läuft gerade ein Durchgang (Nachschlagen/Kompilieren) oder eine Aktualisierung?
@property (nonatomic) BOOL busy;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *idleBlocks;
/// Controller (schwach) -> @{exception, signature} des zuletzt angewendeten Zustands
@property (nonatomic, strong) NSMapTable<id, NSDictionary *> *controllerStates;
/// Controller (schwach) -> @{active, script} der Sperren-Erkennung
@property (nonatomic, strong) NSMapTable<id, NSDictionary *> *wallStates;
/// Hosts, für die in diesem App-Lauf schon eine automatische Ausnahme samt Neuladen ausgelöst wurde (Schleifenschutz).
@property (nonatomic, strong) NSMutableSet<NSString *> *wallHandledHosts;
- (void)handleWallMessage:(id)message;
@property (nonatomic, strong) dispatch_queue_t workQueue;

@end

@implementation BrowserAdblockWallMessageProxy
- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    (void)controller;
    [self.blocker handleWallMessage:message];
}
@end

@implementation BrowserContentBlocker

+ (instancetype)sharedBlocker {
    static BrowserContentBlocker *blocker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocker = [BrowserContentBlocker new];
    });
    return blocker;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingEntries = [NSMutableArray array];
        _readyLists = [NSMutableArray array];
        _wantedIdentifiers = @[];
        _controllerStates = [NSMapTable weakToStrongObjectsMapTable];
        _wallStates = [NSMapTable weakToStrongObjectsMapTable];
        _wallHandledHosts = [NSMutableSet set];
        _workQueue = dispatch_queue_create("browser.contentblocker.compile", DISPATCH_QUEUE_SERIAL);
        _idleBlocks = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isEnabled {
    return [BrowserPreferencesStore new].adBlockEnabled;
}

- (NSUInteger)readyListCount {
    return self.readyLists.count;
}

#pragma mark Ausnahmen pro Seite

+ (NSString *)exceptionKeyForURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if ([host hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    return host.length > 0 ? host : nil;
}

static BOOL BrowserHostMatchesException(NSString *host, NSString *entry) {
    return [host isEqualToString:entry] || [host hasSuffix:[@"." stringByAppendingString:entry]];
}

- (BOOL)isExceptionForURL:(NSURL *)url {
    NSString *key = [BrowserContentBlocker exceptionKeyForURL:url];
    if (key == nil) {
        return NO;
    }
    for (NSString *entry in [BrowserPreferencesStore new].adBlockExceptionHosts) {
        if (BrowserHostMatchesException(key, entry)) {
            return YES;
        }
    }
    return NO;
}

- (void)setException:(BOOL)exception forURL:(NSURL *)url {
    NSString *key = [BrowserContentBlocker exceptionKeyForURL:url];
    if (key == nil) {
        return;
    }
    BrowserPreferencesStore *store = [BrowserPreferencesStore new];
    NSMutableArray<NSString *> *hosts = [store.adBlockExceptionHosts mutableCopy];
    if (exception) {
        if (![hosts containsObject:key]) {
            [hosts addObject:key];
        }
    } else {
        // auch Oberdomain-Einträge entfernen, die diese Seite abdecken
        for (NSString *entry in [hosts copy]) {
            if (BrowserHostMatchesException(key, entry)) {
                [hosts removeObject:entry];
            }
        }
    }
    store.adBlockExceptionHosts = hosts;
    // Eine Entscheidung des Nutzers (Menü) ersetzt die automatische Ausnahme.
    [self removeAutoExceptionForKey:key];
}

- (void)removeAutoExceptionForKey:(NSString *)key {
    BrowserPreferencesStore *store = [BrowserPreferencesStore new];
    NSMutableArray<NSString *> *autoHosts = [store.adBlockAutoExceptionHosts mutableCopy];
    for (NSString *entry in [autoHosts copy]) {
        if (BrowserHostMatchesException(key, entry)) {
            [autoHosts removeObject:entry];
        }
    }
    store.adBlockAutoExceptionHosts = autoHosts;
}

- (BOOL)isAutoExceptionForURL:(NSURL *)url {
    NSString *key = [BrowserContentBlocker exceptionKeyForURL:url];
    if (key == nil) {
        return NO;
    }
    for (NSString *entry in [BrowserPreferencesStore new].adBlockAutoExceptionHosts) {
        if (BrowserHostMatchesException(key, entry)) {
            return YES;
        }
    }
    return NO;
}

#pragma mark Adblock-Sperre erkennen

/// Skript aus dem Paket (ContentBlocker/adblock-wall.js), einmal gelesen.
static NSString *BrowserAdblockWallSource(void) {
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"adblock-wall" ofType:@"js" inDirectory:kBlockerResourceDirectory];
        source = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : @"";
#if DEBUG
        if (source.length == 0) {
            NSLog(@"[AdBlockWall] Ressource adblock-wall.js fehlt im App-Paket");
        }
#endif
    });
    return source;
}

- (id)makeWallUserScript {
    Class scriptClass = NSClassFromString(@"WKUserScript");
    SEL scriptInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    NSString *source = BrowserAdblockWallSource();
    if (scriptClass == Nil || ![scriptClass instancesRespondToSelector:scriptInit] || source.length == 0) {
        return nil;
    }
    id script = [scriptClass alloc];
    // document-end (1), alle Frames: Sperren liegen auch in CMP-iframes
    return ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(script, scriptInit, source, 1, NO);
}

/// Das Skript steckt nur im Controller, wenn Werbeblocker und Automatik an sind und die Seite noch keine Ausnahme hat.
/// Ein-/Ausbau wie beim Cookie-Ablehner: userScripts ist eine Live-Ansicht, daher echte Kopie vor removeAllUserScripts.
- (void)refreshWallController:(id)controller exception:(BOOL)exception force:(BOOL)force {
    SEL addScript = NSSelectorFromString(@"addUserScript:");
    SEL removeAll = NSSelectorFromString(@"removeAllUserScripts");
    SEL scriptsGetter = NSSelectorFromString(@"userScripts");
    if (![controller respondsToSelector:addScript] || ![controller respondsToSelector:removeAll] ||
        ![controller respondsToSelector:scriptsGetter]) {
        return;
    }
    BrowserPreferencesStore *store = [BrowserPreferencesStore new];
    BOOL active = store.adBlockEnabled && store.adBlockAutoPauseOnWall && !exception;
    NSDictionary *current = [self.wallStates objectForKey:controller];
    if (!force && current != nil && [current[@"active"] boolValue] == active) {
        return;
    }
    id oldScript = current[@"script"];
    if (oldScript == NSNull.null) {
        oldScript = nil;
    }
    id newScript = active ? [self makeWallUserScript] : nil;
    if (oldScript != nil || newScript != nil) {
        NSArray *scripts = [NSArray arrayWithArray:((NSArray *(*)(id, SEL))objc_msgSend)(controller, scriptsGetter)];
        ((void (*)(id, SEL))objc_msgSend)(controller, removeAll);
        for (id script in scripts) {
            if (script != oldScript) {
                ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, script);
            }
        }
        if (newScript != nil) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, newScript);
        }
    }
    [self.wallStates setObject:@{@"active": @(active), @"script": newScript ?: NSNull.null} forKey:controller];
}

- (void)installWallHandlerOnController:(id)controller {
    SEL addHandler = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if ([self.wallStates objectForKey:controller] != nil || ![controller respondsToSelector:addHandler]) {
        return;
    }
    Protocol *protocol = objc_getProtocol("WKScriptMessageHandler");
    if (protocol != NULL && !class_conformsToProtocol(BrowserAdblockWallMessageProxy.class, protocol)) {
        class_addProtocol(BrowserAdblockWallMessageProxy.class, protocol);
    }
    BrowserAdblockWallMessageProxy *proxy = [BrowserAdblockWallMessageProxy new];
    proxy.blocker = self;
    ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addHandler, proxy, kWallMessageName);
}

/// Treffer der Erkennung: für den Host der Hauptseite eine automatische Ausnahme setzen und einmal neu laden.
- (void)handleWallMessage:(id)message {
    SEL bodySel = NSSelectorFromString(@"body");
    SEL webViewSel = NSSelectorFromString(@"webView");
    id body = [message respondsToSelector:bodySel] ? ((id (*)(id, SEL))objc_msgSend)(message, bodySel) : nil;
    if (![body isKindOfClass:NSDictionary.class]) {
        return;
    }
    id webView = [message respondsToSelector:webViewSel] ? ((id (*)(id, SEL))objc_msgSend)(message, webViewSel) : nil;
    // Hauptseite: bevorzugt die echte URL der WebView (auch bei Meldungen aus iframes), sonst der gemeldete Host
    SEL urlSel = NSSelectorFromString(@"URL");
    NSURL *pageURL = [webView respondsToSelector:urlSel] ? ((NSURL *(*)(id, SEL))objc_msgSend)(webView, urlSel) : nil;
    NSString *key = [BrowserContentBlocker exceptionKeyForURL:pageURL];
    if (key == nil && [body[@"host"] isKindOfClass:NSString.class]) {
        key = [BrowserContentBlocker exceptionKeyForURL:[NSURL URLWithString:[@"https://" stringByAppendingString:body[@"host"]]]];
        pageURL = key ? [NSURL URLWithString:[@"https://" stringByAppendingString:key]] : nil;
    }
    BrowserPreferencesStore *store = [BrowserPreferencesStore new];
    if (key == nil || !store.adBlockEnabled || !store.adBlockAutoPauseOnWall || [self isExceptionForURL:pageURL]) {
        return;
    }
    if ([self.wallHandledHosts containsObject:key]) {
        return; // Schleifenschutz: pro Host einmal je App-Lauf
    }
    [self.wallHandledHosts addObject:key];
#if DEBUG
    NSLog(@"[AdBlockWall] host %@ erkannt → Ausnahme, neu laden (%@) Text: %@", key, [body[@"top"] boolValue] ? @"Hauptframe" : @"iframe", body[@"text"]);
#endif
    [self setException:YES forURL:pageURL];
    NSMutableArray<NSString *> *autoHosts = [store.adBlockAutoExceptionHosts mutableCopy];
    if (![autoHosts containsObject:key]) {
        [autoHosts addObject:key];
        store.adBlockAutoExceptionHosts = autoHosts;
    }
    SEL reload = NSSelectorFromString(@"reload");
    if ([webView respondsToSelector:reload]) {
        ((id (*)(id, SEL))objc_msgSend)(webView, reload);
    }
}

#pragma mark Kompilieren

- (void)prepare {
    if (self.started) {
        return;
    }
    self.started = YES;
    Class storeClass = NSClassFromString(@"WKContentRuleListStore");
    // Mitgelieferte oder (wenn neuer und vollständig) heruntergeladene Listen, siehe BrowserFilterListUpdater
    NSDictionary *set = [[BrowserFilterListUpdater sharedUpdater] preferredContentBlockerSet];
    NSArray *lists = [set[@"manifest"][@"lists"] isKindOfClass:NSArray.class] ? set[@"manifest"][@"lists"] : nil;
    if (storeClass == Nil || lists.count == 0) {
        NSLog(@"[AdBlock] nicht verfügbar (Klasse %@, Regelsätze %lu)", storeClass, (unsigned long)lists.count);
        return;
    }
    NSURL *caches = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
                     URLByAppendingPathComponent:@"ContentRuleLists" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:caches withIntermediateDirectories:YES attributes:nil error:nil];
    // defaultStore scheitert unter tvOS (Library/WebKit nicht beschreibbar), daher ein eigener Ordner in Caches.
    self.store = ((id (*)(id, SEL, id))objc_msgSend)((id)storeClass, NSSelectorFromString(@"storeWithURL:"), caches);
    if (self.store == nil) {
        NSLog(@"[AdBlock] Store nicht erstellbar");
        return;
    }
    [self startWithSet:set];
}

/// Beginnt einen Durchgang mit einem Listenstand: nacheinander nachschlagen bzw. kompilieren, fertige Listen sofort
/// anwenden (beim Start soll der Schutz so früh wie möglich greifen).
- (void)startWithSet:(NSDictionary *)set {
    NSDictionary *manifest = set[@"manifest"];
    NSArray *lists = manifest[@"lists"];
    self.generation += 1;
    self.sourceDirectory = set[@"directory"];
    self.sourceManifest = manifest;
    self.sourceDownloaded = [set[@"downloaded"] boolValue];
    NSLog(@"[AdBlock] Listenstand %@ vom %@ (%@)", manifest[@"version"],
          [BrowserFilterListUpdater displayStringForDate:[self activeListsDate]],
          self.sourceDownloaded ? @"heruntergeladen" : @"mitgeliefert");
    NSMutableArray<NSString *> *wanted = [NSMutableArray array];
    for (NSDictionary *entry in lists) {
        [wanted addObject:[self identifierForEntry:entry]];
    }
    self.wantedIdentifiers = wanted;
    self.totalListCount = lists.count;
    [self.readyLists removeAllObjects];
    [self.pendingEntries removeAllObjects];
    [self.pendingEntries addObjectsFromArray:lists];
    self.busy = YES;
    [self processNextEntry];
}

/// Heruntergeladene Listen sind beim Start unbrauchbar: verwerfen und mit den mitgelieferten neu beginnen.
- (void)fallBackToBundledListsAfterProblem:(NSString *)problem {
    NSLog(@"[AdBlock] heruntergeladene Listen unbrauchbar (%@), nehme mitgelieferte", problem);
    BrowserFilterListUpdater *updater = [BrowserFilterListUpdater sharedUpdater];
    [updater discardDownloadedContentBlocker];
    NSDictionary *set = [updater bundledContentBlockerSet];
    if (set == nil) {
        [self becomeIdle];
        return;
    }
    [self startWithSet:set];
    [self refreshAllControllersForce:YES];
}

- (NSTimeInterval)activeGeneratedAt {
    id value = self.sourceManifest[@"generatedAt"];
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
}

- (NSDate *)activeListsDate {
    NSTimeInterval generatedAt = self.activeGeneratedAt;
    return generatedAt > 0 ? [NSDate dateWithTimeIntervalSince1970:generatedAt] : nil;
}

- (NSString *)activeVersion {
    return [self.sourceManifest[@"version"] description];
}

- (BOOL)activeListsDownloaded {
    return self.sourceDownloaded;
}

- (NSString *)identifierForEntry:(NSDictionary *)entry {
    return [NSString stringWithFormat:@"%@%@-%@", kBlockerIdentifierPrefix, entry[@"name"], entry[@"hash"]];
}

- (void)becomeIdle {
    self.busy = NO;
    NSArray<dispatch_block_t> *blocks = [self.idleBlocks copy];
    [self.idleBlocks removeAllObjects];
    for (dispatch_block_t block in blocks) {
        block();
    }
}

/// Arbeitet die Regelsätze nacheinander ab (Speicherbedarf beim Kompilieren), zuerst Nachschlagen im Store.
- (void)processNextEntry {
    if (self.pendingEntries.count == 0) {
        BrowserPerfLog(@"Werbeblocker: %lu von %lu Listen bereit", (unsigned long)self.readyLists.count, (unsigned long)self.totalListCount);
        [self removeStaleLists];
        [self becomeIdle];
        return;
    }
    NSDictionary *entry = self.pendingEntries.firstObject;
    [self.pendingEntries removeObjectAtIndex:0];
    NSUInteger generation = self.generation;
    [self lookUpOrCompileEntry:entry directory:self.sourceDirectory completion:^(id list, NSString *problem) {
        if (generation != self.generation) {
            return; // Stand wurde inzwischen gewechselt
        }
        if (list != nil) {
            [self listBecameReady:list];
        } else if (self.sourceDownloaded) {
            [self fallBackToBundledListsAfterProblem:[NSString stringWithFormat:@"%@: %@", entry[@"name"], problem]];
            return;
        }
        [self processNextEntry];
    }];
}

/// Schlägt einen Regelsatz im Store nach (Kennung mit Inhalts-Hash) oder kompiliert ihn aus `directory`.
/// Completion auf dem Hauptthread: Liste oder Fehlertext.
- (void)lookUpOrCompileEntry:(NSDictionary *)entry directory:(NSURL *)directory completion:(void (^)(id list, NSString *problem))completion {
    NSString *identifier = [self identifierForEntry:entry];
    NSDate *start = [NSDate date];
    void (^lookup)(id, NSError *) = ^(id list, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (list != nil) {
                NSLog(@"[AdBlock] %@ aus Store (%.0f ms)", entry[@"name"], -[start timeIntervalSinceNow] * 1000.0);
                completion(list, nil);
            } else {
                [self compileEntry:entry identifier:identifier directory:directory completion:completion];
            }
        });
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.store, NSSelectorFromString(@"lookUpContentRuleListForIdentifier:completionHandler:"),
                                              identifier, lookup);
}

/// Lädt und entpackt die Datei abseits des Hauptthreads und lässt WebKit kompilieren.
- (void)compileEntry:(NSDictionary *)entry identifier:(NSString *)identifier directory:(NSURL *)directory
          completion:(void (^)(id list, NSString *problem))completion {
    NSURL *fileURL = directory != nil ? [directory URLByAppendingPathComponent:entry[@"file"]] : nil;
    dispatch_async(self.workQueue, ^{
        NSString *json = nil;
        NSData *packed = fileURL != nil ? [NSData dataWithContentsOfURL:fileURL] : nil;
        if (packed != nil) {
            NSData *data = [packed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
            json = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (json == nil) {
                NSLog(@"[AdBlock] %@ nicht lesbar", entry[@"name"]);
                completion(nil, BLS(@"nicht lesbar"));
                return;
            }
            NSDate *start = [NSDate date];
            void (^compiled)(id, NSError *) = ^(id list, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (list != nil) {
                        NSLog(@"[AdBlock] %@ kompiliert (%.1f s, %@ Regeln)", entry[@"name"], -[start timeIntervalSinceNow], entry[@"rules"]);
                        completion(list, nil);
                    } else {
                        NSLog(@"[AdBlock] %@ Fehler %ld: %@", entry[@"name"], (long)error.code, error.userInfo);
                        completion(nil, [NSString stringWithFormat:BLS(@"WebKit-Fehler %ld"), (long)error.code]);
                    }
                });
            };
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(self.store,
                NSSelectorFromString(@"compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:"),
                identifier, json, compiled);
        });
    });
}

#pragma mark Neuer Listenstand (Aktualisierung ohne App-Update)

- (void)installListSetAtDirectory:(NSURL *)directory manifest:(NSDictionary *)manifest
                       completion:(void (^)(BOOL ok, NSString *error))completion {
    [self prepare];
    if (self.store == nil) {
        completion(NO, BLS(@"Werbeblocker nicht verfügbar"));
        return;
    }
    if (self.busy) {
        // erst den laufenden Durchgang abwarten (zwei Kompilierungen gleichzeitig kosten zu viel Speicher)
        __weak typeof(self) weakSelf = self;
        [self.idleBlocks addObject:^{
            [weakSelf installListSetAtDirectory:directory manifest:manifest completion:completion];
        }];
        return;
    }
    self.busy = YES;
    NSArray<NSDictionary *> *lists = manifest[@"lists"];
    NSMutableArray *compiled = [NSMutableArray array];
    [self compileLists:lists index:0 directory:directory into:compiled completion:^(NSString *problem) {
        if (problem != nil) {
            NSLog(@"[AdBlock] neuer Listenstand %@ verworfen: %@", manifest[@"version"], problem);
            [self removeStaleLists]; // schon kompilierte Teile des verworfenen Stands wieder entfernen
            [self becomeIdle];
            completion(NO, problem);
            return;
        }
        // Alles kompiliert: jetzt in einem Schritt umschalten.
        self.generation += 1;
        self.sourceDirectory = directory;
        self.sourceManifest = manifest;
        self.sourceDownloaded = YES;
        NSMutableArray<NSString *> *wanted = [NSMutableArray array];
        for (NSDictionary *entry in lists) {
            [wanted addObject:[self identifierForEntry:entry]];
        }
        self.wantedIdentifiers = wanted;
        self.totalListCount = lists.count;
        [self.pendingEntries removeAllObjects];
        [self.readyLists setArray:compiled];
        [self refreshAllControllersForce:YES];
        [self removeStaleLists];
        NSLog(@"[AdBlock] umgeschaltet auf Listenstand %@ (%lu Regelsätze)", manifest[@"version"], (unsigned long)compiled.count);
        [self becomeIdle];
        completion(YES, nil);
    }];
}

- (void)compileLists:(NSArray<NSDictionary *> *)lists index:(NSUInteger)index directory:(NSURL *)directory
                into:(NSMutableArray *)compiled completion:(void (^)(NSString *problem))completion {
    if (index == lists.count) {
        completion(nil);
        return;
    }
    NSDictionary *entry = lists[index];
    [self lookUpOrCompileEntry:entry directory:directory completion:^(id list, NSString *problem) {
        if (list == nil) {
            completion([NSString stringWithFormat:@"%@: %@", entry[@"name"], problem ?: BLS(@"Fehler")]);
            return;
        }
        [compiled addObject:list];
        [self compileLists:lists index:index + 1 directory:directory into:compiled completion:completion];
    }];
}

/// Entfernt Regelsätze früherer Listenstände aus dem Store.
- (void)removeStaleLists {
    NSSet<NSString *> *wanted = [NSSet setWithArray:self.wantedIdentifiers];
    id store = self.store;
    void (^completion)(NSArray<NSString *> *) = ^(NSArray<NSString *> *identifiers) {
        for (NSString *identifier in identifiers) {
            if ([identifier hasPrefix:kBlockerIdentifierPrefix] && ![wanted containsObject:identifier]) {
                void (^done)(NSError *) = ^(NSError *error) {};
                ((void (*)(id, SEL, id, id))objc_msgSend)(store, NSSelectorFromString(@"removeContentRuleListForIdentifier:completionHandler:"),
                                                          identifier, done);
            }
        }
    };
    ((void (*)(id, SEL, id))objc_msgSend)(store, NSSelectorFromString(@"getAvailableContentRuleListIdentifiers:"), completion);
}

- (void)listBecameReady:(id)list {
    [self.readyLists addObject:list];
    [self refreshAllControllersForce:NO];
}

#pragma mark Anwenden

- (NSString *)signatureForException:(BOOL)exception {
    BOOL active = self.isEnabled && !exception && self.readyLists.count > 0;
    // Der Stand (generation) gehört dazu: nach einem Listenwechsel mit gleicher Anzahl muss trotzdem neu bestückt werden.
    return active ? [NSString stringWithFormat:@"on:%lu:%lu", (unsigned long)self.generation, (unsigned long)self.readyLists.count] : @"off";
}

- (void)refreshController:(id)controller exception:(BOOL)exception force:(BOOL)force {
    NSString *signature = [self signatureForException:exception];
    NSDictionary *current = [self.controllerStates objectForKey:controller];
    if (!force && [current[kStateSignatureKey] isEqualToString:signature]) {
        return;
    }
    [self.controllerStates setObject:@{kStateExceptionKey: @(exception), kStateSignatureKey: signature} forKey:controller];
    SEL removeAll = NSSelectorFromString(@"removeAllContentRuleLists");
    SEL add = NSSelectorFromString(@"addContentRuleList:");
    if (![controller respondsToSelector:removeAll] || ![controller respondsToSelector:add]) {
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(controller, removeAll);
    if ([signature hasPrefix:@"on:"]) {
        for (id list in self.readyLists) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, add, list);
        }
    }
}

/// Alle bekannten Controller neu bestücken; der Ausnahmezustand der aktuellen Seite bleibt erhalten.
- (void)refreshAllControllersForce:(BOOL)force {
    for (id controller in self.controllerStates.keyEnumerator.allObjects) {
        BOOL exception = [[self.controllerStates objectForKey:controller][kStateExceptionKey] boolValue];
        [self refreshController:controller exception:exception force:force];
    }
}

- (void)applyToUserContentController:(id)userContentController {
    if (userContentController == nil) {
        return;
    }
    [self prepare];
    // Neue Tabs starten ohne Zielseite; eine Ausnahme greift mit der ersten Navigation.
    [self refreshController:userContentController exception:NO force:YES];
    [self installWallHandlerOnController:userContentController];
    [self refreshWallController:userContentController exception:NO force:YES];
}

- (void)updateUserContentController:(id)userContentController forNavigationToURL:(NSURL *)url {
    if (userContentController == nil) {
        return;
    }
    BOOL exception = [self isExceptionForURL:url];
    [self refreshController:userContentController exception:exception force:NO];
    [self refreshWallController:userContentController exception:exception force:NO];
}

- (void)preferencesDidChange {
    [self refreshAllControllersForce:YES];
    for (id controller in self.wallStates.keyEnumerator.allObjects) {
        // Ausnahmezustand der Seite bleibt erhalten
        BOOL exception = [[self.controllerStates objectForKey:controller][kStateExceptionKey] boolValue];
        [self refreshWallController:controller exception:exception force:YES];
    }
}

@end
