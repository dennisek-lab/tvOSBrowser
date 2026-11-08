#import "BrowserCookieConsentBlocker.h"
#import "BrowserPreferencesStore.h"

#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kConsentMessageName = @"browserAutoconsent";
static NSString * const kStateActiveKey = @"active";
static NSString * const kStateExceptionKey = @"exception";
static NSString * const kStateScriptKey = @"script";

/// Empfängt die Meldungen {type, cmp, url, top, ...} der Brücke (bridge.js).
@interface BrowserCookieConsentMessageProxy : NSObject
@property (nonatomic, weak) BrowserCookieConsentBlocker *blocker;
@end

@interface BrowserCookieConsentBlocker ()
@property (nonatomic, readwrite) NSUInteger handledCount;
/// Controller (schwach) -> @{active, exception, script}
@property (nonatomic, strong) NSMapTable<id, NSDictionary *> *controllerStates;
@property (nonatomic, strong) NSMutableArray *proxies;
- (void)handleMessageBody:(id)body;
@end

@implementation BrowserCookieConsentMessageProxy
- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    (void)controller;
    id body = [message respondsToSelector:@selector(body)] ? ((id (*)(id, SEL))objc_msgSend)(message, @selector(body)) : nil;
    [self.blocker handleMessageBody:body];
}
@end

/// Bundle + Brücke aus dem Ordner Autoconsent (App-Paket), einmal gelesen. Reihenfolge: erst autoconsent.standalone.js
/// (unverändert, MPL-2.0), dann bridge.js.
static NSString *BrowserAutoconsentSource(void) {
    static NSString *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *bundlePath = [bundle pathForResource:@"autoconsent.standalone" ofType:@"js" inDirectory:@"Autoconsent"];
        NSString *bridgePath = [bundle pathForResource:@"bridge" ofType:@"js" inDirectory:@"Autoconsent"];
        NSString *bundleSource = bundlePath ? [NSString stringWithContentsOfFile:bundlePath encoding:NSUTF8StringEncoding error:NULL] : nil;
        NSString *bridgeSource = bridgePath ? [NSString stringWithContentsOfFile:bridgePath encoding:NSUTF8StringEncoding error:NULL] : nil;
        if (bundleSource.length > 0 && bridgeSource.length > 0) {
            source = [NSString stringWithFormat:@"%@\n%@\n", bundleSource, bridgeSource];
        } else {
            source = @"";
#if DEBUG
            NSLog(@"[CookieBlock] Ressource Autoconsent fehlt im App-Paket");
#endif
        }
    });
    return source;
}

@implementation BrowserCookieConsentBlocker

+ (instancetype)sharedBlocker {
    static BrowserCookieConsentBlocker *blocker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocker = [BrowserCookieConsentBlocker new];
    });
    return blocker;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _controllerStates = [NSMapTable weakToStrongObjectsMapTable];
        _proxies = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isEnabled {
    return [BrowserPreferencesStore new].cookieBannerBlockEnabled;
}

#pragma mark Ausnahmen pro Seite

+ (NSString *)exceptionKeyForURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if ([host hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    return host.length > 0 ? host : nil;
}

static BOOL BrowserConsentHostMatches(NSString *host, NSString *entry) {
    return [host isEqualToString:entry] || [host hasSuffix:[@"." stringByAppendingString:entry]];
}

- (BOOL)isExceptionForURL:(NSURL *)url {
    NSString *key = [BrowserCookieConsentBlocker exceptionKeyForURL:url];
    if (key == nil) {
        return NO;
    }
    for (NSString *entry in [BrowserPreferencesStore new].cookieBannerExceptionHosts) {
        if (BrowserConsentHostMatches(key, entry)) {
            return YES;
        }
    }
    return NO;
}

- (void)setException:(BOOL)exception forURL:(NSURL *)url {
    NSString *key = [BrowserCookieConsentBlocker exceptionKeyForURL:url];
    if (key == nil) {
        return;
    }
    BrowserPreferencesStore *store = [BrowserPreferencesStore new];
    NSMutableArray<NSString *> *hosts = [store.cookieBannerExceptionHosts mutableCopy];
    if (exception) {
        if (![hosts containsObject:key]) {
            [hosts addObject:key];
        }
    } else {
        for (NSString *entry in [hosts copy]) {
            if (BrowserConsentHostMatches(key, entry)) {
                [hosts removeObject:entry];
            }
        }
    }
    store.cookieBannerExceptionHosts = hosts;
}

#pragma mark Skript ein-/ausbauen

- (id)makeUserScript {
    Class scriptClass = NSClassFromString(@"WKUserScript");
    SEL scriptInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (scriptClass == Nil || ![scriptClass instancesRespondToSelector:scriptInit]) {
        return nil;
    }
    NSString *source = BrowserAutoconsentSource();
    if (source.length == 0) {
        return nil;
    }
    // Schalter für die Brücke: Bezahlschranken (kein Ablehnen möglich) annehmen.
    BOOL acceptPayWalls = [BrowserPreferencesStore new].cookieBannerAcceptPayWalls;
    source = [NSString stringWithFormat:@"window.__browserAcceptPayWalls=%@;\n%@", acceptPayWalls ? @"true" : @"false", source];
    id script = ((id (*)(id, SEL))objc_msgSend)((id)scriptClass, @selector(alloc));
    // injectionTime 0 = document-start (frühes Vorausblenden), forMainFrameOnly NO: CMPs laufen oft in fremden iframes.
    // Das Skript läuft in der Seitenwelt, damit eval-Regeln der Bibliothek direkt im Seitenkontext laufen.
    return ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(script, scriptInit, source, 0, NO);
}

/// Bringt den Controller in den gewünschten Zustand. removeAllUserScripts kennt kein Einzel-Entfernen, daher werden die
/// übrigen Skripte (Video-Hooks usw.) gemerkt und wieder angehängt.
- (void)refreshController:(id)controller exception:(BOOL)exception force:(BOOL)force {
    SEL addScript = NSSelectorFromString(@"addUserScript:");
    SEL removeAll = NSSelectorFromString(@"removeAllUserScripts");
    SEL scriptsGetter = NSSelectorFromString(@"userScripts");
    if (![controller respondsToSelector:addScript] || ![controller respondsToSelector:removeAll] ||
        ![controller respondsToSelector:scriptsGetter]) {
        return;
    }
    BOOL active = self.enabled && !exception;
    NSDictionary *current = [self.controllerStates objectForKey:controller];
    id oldScript = current[kStateScriptKey];
    if (oldScript == NSNull.null) {
        oldScript = nil;
    }
    if (!force && current != nil && [current[kStateActiveKey] boolValue] == active) {
        return;
    }
    id newScript = active ? [self makeUserScript] : nil;
    if (oldScript != nil || newScript != nil) {
        // Echte Kopie: userScripts ist eine Live-Ansicht, die nach removeAllUserScripts leer wäre (copy gibt sie selbst zurück).
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
    [self.controllerStates setObject:@{kStateActiveKey: @(active), kStateExceptionKey: @(exception),
                                       kStateScriptKey: newScript ?: NSNull.null} forKey:controller];
}

- (void)applyToUserContentController:(id)userContentController {
    if (userContentController == nil) {
        return;
    }
    SEL addHandler = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if ([self.controllerStates objectForKey:userContentController] == nil && [userContentController respondsToSelector:addHandler]) {
        Protocol *protocol = objc_getProtocol("WKScriptMessageHandler");
        if (protocol != NULL && !class_conformsToProtocol(BrowserCookieConsentMessageProxy.class, protocol)) {
            class_addProtocol(BrowserCookieConsentMessageProxy.class, protocol);
        }
        BrowserCookieConsentMessageProxy *proxy = [BrowserCookieConsentMessageProxy new];
        proxy.blocker = self;
        [self.proxies addObject:proxy];
        ((void (*)(id, SEL, id, id))objc_msgSend)(userContentController, addHandler, proxy, kConsentMessageName);
    }
    // Neue Tabs starten ohne Zielseite; eine Ausnahme greift mit der ersten Navigation.
    [self refreshController:userContentController exception:NO force:YES];
}

- (void)updateUserContentController:(id)userContentController forNavigationToURL:(NSURL *)url {
    if (userContentController == nil || [self.controllerStates objectForKey:userContentController] == nil) {
        return;
    }
    [self refreshController:userContentController exception:[self isExceptionForURL:url] force:NO];
}

- (void)preferencesDidChange {
    for (id controller in self.controllerStates.keyEnumerator.allObjects) {
        BOOL exception = [[self.controllerStates objectForKey:controller][kStateExceptionKey] boolValue];
        [self refreshController:controller exception:exception force:YES];
    }
}

#pragma mark Rückmeldung

- (void)handleMessageBody:(id)body {
    if (![body isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSString *type = [body[@"type"] isKindOfClass:NSString.class] ? body[@"type"] : @"";
    if ([type isEqualToString:@"autoconsentDone"] || [type isEqualToString:@"payWallAccepted"]) {
        self.handledCount += 1;
    }
#if DEBUG
    NSString *cmp = [body[@"cmp"] isKindOfClass:NSString.class] ? body[@"cmp"] : @"";
    NSString *url = [body[@"url"] isKindOfClass:NSString.class] ? body[@"url"] : @"";
    NSMutableString *extra = [NSMutableString string];
    if ([body[@"result"] isKindOfClass:NSNumber.class]) {
        [extra appendFormat:@" ergebnis=%@", [body[@"result"] boolValue] ? @"ja" : @"nein"];
    }
    if ([body[@"lifecycle"] isKindOfClass:NSString.class]) {
        [extra appendFormat:@" zustand=%@", body[@"lifecycle"]];
    }
    if ([body[@"details"] isKindOfClass:NSString.class]) {
        [extra appendFormat:@" %@", body[@"details"]];
    }
    NSLog(@"[CookieBlock] %@ %@ %@%@ (%@)", type, cmp, url, extra, [body[@"top"] boolValue] ? @"Hauptframe" : @"iframe");
#endif
}

@end
