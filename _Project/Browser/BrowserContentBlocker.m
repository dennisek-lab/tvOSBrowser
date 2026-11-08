#import "BrowserContentBlocker.h"
#import "BrowserPreferencesStore.h"

#import <objc/message.h>

static NSString * const kBlockerResourceDirectory = @"ContentBlocker";
static NSString * const kBlockerIdentifierPrefix = @"adblock-";
static NSString * const kStateExceptionKey = @"exception";
static NSString * const kStateSignatureKey = @"signature";

@interface BrowserContentBlocker ()

@property (nonatomic) BOOL started;
@property (nonatomic, strong, nullable) id store;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingEntries;
@property (nonatomic, strong) NSMutableArray *readyLists;
@property (nonatomic, copy) NSArray<NSString *> *wantedIdentifiers;
@property (nonatomic) NSUInteger totalListCount;
/// Controller (schwach) -> @{exception, signature} des zuletzt angewendeten Zustands
@property (nonatomic, strong) NSMapTable<id, NSDictionary *> *controllerStates;
@property (nonatomic, strong) dispatch_queue_t workQueue;

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
        _workQueue = dispatch_queue_create("browser.contentblocker.compile", DISPATCH_QUEUE_SERIAL);
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
}

#pragma mark Kompilieren

- (void)prepare {
    if (self.started) {
        return;
    }
    self.started = YES;
    Class storeClass = NSClassFromString(@"WKContentRuleListStore");
    NSURL *manifestURL = [NSBundle.mainBundle URLForResource:@"manifest" withExtension:@"json" subdirectory:kBlockerResourceDirectory];
    NSData *manifestData = manifestURL != nil ? [NSData dataWithContentsOfURL:manifestURL] : nil;
    NSDictionary *manifest = manifestData != nil ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
    NSArray *lists = [manifest[@"lists"] isKindOfClass:NSArray.class] ? manifest[@"lists"] : nil;
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
    NSMutableArray<NSString *> *wanted = [NSMutableArray array];
    for (NSDictionary *entry in lists) {
        [wanted addObject:[self identifierForEntry:entry]];
    }
    self.wantedIdentifiers = wanted;
    self.totalListCount = lists.count;
    [self.pendingEntries addObjectsFromArray:lists];
    [self processNextEntry];
}

- (NSString *)identifierForEntry:(NSDictionary *)entry {
    return [NSString stringWithFormat:@"%@%@-%@", kBlockerIdentifierPrefix, entry[@"name"], entry[@"hash"]];
}

/// Arbeitet die Regelsätze nacheinander ab (Speicherbedarf beim Kompilieren), zuerst Nachschlagen im Store.
- (void)processNextEntry {
    if (self.pendingEntries.count == 0) {
        [self removeStaleLists];
        return;
    }
    NSDictionary *entry = self.pendingEntries.firstObject;
    [self.pendingEntries removeObjectAtIndex:0];
    NSString *identifier = [self identifierForEntry:entry];
    NSDate *start = [NSDate date];
    void (^completion)(id, NSError *) = ^(id list, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (list != nil) {
                NSLog(@"[AdBlock] %@ aus Store (%.0f ms)", entry[@"name"], -[start timeIntervalSinceNow] * 1000.0);
                [self listBecameReady:list];
                [self processNextEntry];
            } else {
                [self compileEntry:entry identifier:identifier];
            }
        });
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.store, NSSelectorFromString(@"lookUpContentRuleListForIdentifier:completionHandler:"),
                                              identifier, completion);
}

/// Lädt und entpackt die Datei abseits des Hauptthreads und lässt WebKit kompilieren.
- (void)compileEntry:(NSDictionary *)entry identifier:(NSString *)identifier {
    NSURL *fileURL = [NSBundle.mainBundle URLForResource:entry[@"file"] withExtension:nil subdirectory:kBlockerResourceDirectory];
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
                [self processNextEntry];
                return;
            }
            NSDate *start = [NSDate date];
            void (^completion)(id, NSError *) = ^(id list, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (list != nil) {
                        NSLog(@"[AdBlock] %@ kompiliert (%.1f s, %@ Regeln)", entry[@"name"], -[start timeIntervalSinceNow], entry[@"rules"]);
                        [self listBecameReady:list];
                    } else {
                        NSLog(@"[AdBlock] %@ Fehler %ld: %@", entry[@"name"], (long)error.code, error.userInfo);
                    }
                    [self processNextEntry];
                });
            };
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(self.store,
                NSSelectorFromString(@"compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:"),
                identifier, json, completion);
        });
    });
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
    return active ? [NSString stringWithFormat:@"on:%lu", (unsigned long)self.readyLists.count] : @"off";
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
}

- (void)updateUserContentController:(id)userContentController forNavigationToURL:(NSURL *)url {
    if (userContentController == nil) {
        return;
    }
    [self refreshController:userContentController exception:[self isExceptionForURL:url] force:NO];
}

- (void)preferencesDidChange {
    [self refreshAllControllersForce:YES];
}

@end
