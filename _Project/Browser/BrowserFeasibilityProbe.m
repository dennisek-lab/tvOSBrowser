#import "BrowserFeasibilityProbe.h"
#import <UIKit/UIKit.h>
#import <Network/Network.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - Script-Message-Handler

@interface BrowserProbeMessageHandler : NSObject
@property (nonatomic, copy) void (^onMessage)(id body);
@end

@implementation BrowserProbeMessageHandler
- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    id body = nil;
    if ([message respondsToSelector:@selector(body)]) {
        body = ((id (*)(id, SEL))objc_msgSend)(message, @selector(body));
    }
    if (self.onMessage) {
        self.onMessage(body);
    }
}
@end

#pragma mark - Navigation-Delegate

@interface BrowserProbeNavigationDelegate : NSObject
@property (nonatomic, copy) void (^onEvent)(NSString *event);
@end

@implementation BrowserProbeNavigationDelegate
- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    if (self.onEvent) self.onEvent(@"finished");
}
- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    if (self.onEvent) self.onEvent([NSString stringWithFormat:@"failedProvisional: %@", error.localizedDescription]);
}
- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    if (self.onEvent) self.onEvent([NSString stringWithFormat:@"failed: %@", error.localizedDescription]);
}
@end

#pragma mark - Probe

@interface BrowserFeasibilityProbe ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *results;
@property (nonatomic, strong) NSMutableArray *retained;
@property (nonatomic, strong) nw_listener_t listener;
@property (nonatomic, strong) nw_connection_t dohConnection;
@end

@implementation BrowserFeasibilityProbe

+ (instancetype)shared {
    static BrowserFeasibilityProbe *probe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ probe = [BrowserFeasibilityProbe new]; });
    return probe;
}

+ (void)runIfRequested {
    fprintf(stderr, "[Probe] runIfRequested env=%s\n", NSProcessInfo.processInfo.environment[@"RUN_FEASIBILITY_PROBE"].UTF8String ?: "nil");
    BOOL requested = [[NSUserDefaults standardUserDefaults] boolForKey:@"RunFeasibilityProbe"] ||
                     NSProcessInfo.processInfo.environment[@"RUN_FEASIBILITY_PROBE"] != nil;
    if (!requested) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[self shared] run];
    });
}

- (void)record:(NSString *)key value:(id)value {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.results[key] = value ?: [NSNull null];
        NSLog(@"[Probe] %@ = %@", key, value);
        fprintf(stderr, "[Probe] %s = %s\n", key.UTF8String, [value description].UTF8String);
        [self write];
    });
}

- (void)write {
    NSURL *caches = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *file = [caches URLByAppendingPathComponent:@"feasibility.json"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.results options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToURL:file atomically:YES];
}

- (void)run {
    self.results = [NSMutableDictionary dictionary];
    self.retained = [NSMutableArray array];
    self.results[@"tvOS"] = [UIDevice currentDevice].systemVersion;

    NSArray *classes = @[@"WKWebView", @"WKWebViewConfiguration", @"WKUserContentController", @"WKUserScript",
                         @"WKContentRuleListStore", @"WKContentRuleList", @"WKWebsiteDataStore", @"WKContentWorld"];
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    for (NSString *name in classes) {
        found[name] = @(NSClassFromString(name) != Nil);
    }
    [self record:@"classes" value:found];
    Class webViewClass = NSClassFromString(@"WKWebView");
    [self record:@"pageZoomSelector" value:@([webViewClass instancesRespondToSelector:NSSelectorFromString(@"setPageZoom:")])];

    [self probeContentRuleList];
    [self probeScriptMessageHandler];
    [self probeProxyConfiguration];
    [self probeEncryptedDNS];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self record:@"done" value:@YES];
    });
}

#pragma mark Werbeblocker-Regeln

- (void)probeContentRuleList {
    Class storeClass = NSClassFromString(@"WKContentRuleListStore");
    if (storeClass == Nil) {
        [self record:@"contentRuleList" value:@"class missing"];
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *caches = [[fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"ContentRuleLists" isDirectory:YES];
    NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ContentRuleLists"] isDirectory:YES];
    [fm createDirectoryAtURL:caches withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:tmp withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary *stores = @{
        @"default": ((id (*)(id, SEL))objc_msgSend)(storeClass, NSSelectorFromString(@"defaultStore")) ?: [NSNull null],
        @"caches": ((id (*)(id, SEL, id))objc_msgSend)(storeClass, NSSelectorFromString(@"storeWithURL:"), caches) ?: [NSNull null],
        @"tmp": ((id (*)(id, SEL, id))objc_msgSend)(storeClass, NSSelectorFromString(@"storeWithURL:"), tmp) ?: [NSNull null],
    };
    NSString *rules = @"[{\"trigger\":{\"url-filter\":\"doubleclick\\\\.net\"},\"action\":{\"type\":\"block\"}},"
                      @"{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"css-display-none\",\"selector\":\".ad-banner\"}}]";
    SEL compile = NSSelectorFromString(@"compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:");
    [stores enumerateKeysAndObjectsUsingBlock:^(NSString *name, id store, BOOL *stop) {
        NSString *key = [@"contentRuleList." stringByAppendingString:name];
        if (store == [NSNull null] || ![store respondsToSelector:compile]) {
            [self record:key value:@"store unavailable"];
            return;
        }
        NSDate *start = [NSDate date];
        void (^completion)(id, NSError *) = ^(id list, NSError *error) {
            NSTimeInterval ms = -[start timeIntervalSinceNow] * 1000.0;
            if (list != nil) {
                [self record:key value:[NSString stringWithFormat:@"compiled in %.0f ms", ms]];
                if ([name isEqualToString:@"caches"]) {
                    [self probeRuleListApplied:list];
                }
            } else {
                [self record:key value:[NSString stringWithFormat:@"error %ld: %@", (long)error.code, error.userInfo]];
            }
        };
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, compile, @"probe", rules, completion);
    }];
}

/// Prüft, ob eine kompilierte Regelliste in einer WebView greift: die CSS-Regel muss .ad-banner ausblenden.
- (void)probeRuleListApplied:(id)list {
    id configuration = [self makeConfigurationWithDataStore:nil];
    id controller = ((id (*)(id, SEL))objc_msgSend)(configuration, NSSelectorFromString(@"userContentController"));
    ((void (*)(id, SEL, id))objc_msgSend)(controller, NSSelectorFromString(@"addContentRuleList:"), list);
    Protocol *protocol = objc_getProtocol("WKScriptMessageHandler");
    if (protocol != NULL) {
        class_addProtocol(BrowserProbeMessageHandler.class, protocol);
    }
    BrowserProbeMessageHandler *handler = [BrowserProbeMessageHandler new];
    handler.onMessage = ^(id body) {
        [self record:@"contentRuleList.applied" value:body];
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(controller, NSSelectorFromString(@"addScriptMessageHandler:name:"), handler, @"rules");
    id webView = [self makeHiddenWebViewWithConfiguration:configuration];
    NSString *html = @"<html><body><div class='ad-banner'>AD</div><script>"
                     @"setTimeout(function(){var d=getComputedStyle(document.querySelector('.ad-banner')).display;"
                     @"window.webkit.messageHandlers.rules.postMessage('ad-banner display='+d);},300);</script></body></html>";
    ((void (*)(id, SEL, id, id))objc_msgSend)(webView, NSSelectorFromString(@"loadHTMLString:baseURL:"), html, [NSURL URLWithString:@"https://probe.local/"]);
}

#pragma mark Hilfen

- (id)makeConfigurationWithDataStore:(id)dataStore {
    id configuration = [NSClassFromString(@"WKWebViewConfiguration") new];
    if (dataStore != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(configuration, NSSelectorFromString(@"setWebsiteDataStore:"), dataStore);
    }
    return configuration;
}

- (id)makeHiddenWebViewWithConfiguration:(id)configuration {
    id webView = [NSClassFromString(@"WKWebView") alloc];
    webView = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webView, NSSelectorFromString(@"initWithFrame:configuration:"),
                                                          CGRectMake(0, 0, 320, 240), configuration);
    UIView *view = (UIView *)webView;
    view.alpha = 0.01;
    view.userInteractionEnabled = NO;
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            window = ((UIWindowScene *)scene).windows.firstObject;
        }
    }
    if (window == nil) {
        window = UIApplication.sharedApplication.windows.firstObject;
    }
    [window addSubview:view];
    [self.retained addObject:webView];
    return webView;
}

#pragma mark JS-Rückkanal

- (void)probeScriptMessageHandler {
    id configuration = [self makeConfigurationWithDataStore:nil];
    id controller = ((id (*)(id, SEL))objc_msgSend)(configuration, NSSelectorFromString(@"userContentController"));
    SEL add = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if (controller == nil || ![controller respondsToSelector:add]) {
        [self record:@"scriptMessageHandler" value:@"addScriptMessageHandler missing"];
        return;
    }
    Protocol *protocol = objc_getProtocol("WKScriptMessageHandler");
    if (protocol != NULL) {
        class_addProtocol(BrowserProbeMessageHandler.class, protocol);
    }
    BrowserProbeMessageHandler *handler = [BrowserProbeMessageHandler new];
    handler.onMessage = ^(id body) {
        [self record:@"scriptMessageHandler" value:[NSString stringWithFormat:@"received: %@", body]];
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(controller, add, handler, @"probe");
    id webView = [self makeHiddenWebViewWithConfiguration:configuration];
    NSString *html = @"<html><body><script>window.webkit.messageHandlers.probe.postMessage('hello from JS');</script></body></html>";
    ((void (*)(id, SEL, id, id))objc_msgSend)(webView, NSSelectorFromString(@"loadHTMLString:baseURL:"), html, [NSURL URLWithString:@"https://probe.local/"]);
    [self record:@"scriptMessageHandler" value:@"waiting"];
}

#pragma mark Proxy (Grundlage für Cloudflare-DNS)

- (void)probeProxyConfiguration {
    Class storeClass = NSClassFromString(@"WKWebsiteDataStore");
    id dataStore = ((id (*)(id, SEL))objc_msgSend)(storeClass, NSSelectorFromString(@"nonPersistentDataStore"));
    SEL setProxies = NSSelectorFromString(@"setProxyConfigurations:");
    if (dataStore == nil || ![dataStore respondsToSelector:setProxies]) {
        [self record:@"proxyConfigurations" value:@"setProxyConfigurations: missing"];
        return;
    }
    [self record:@"proxyConfigurations" value:@"selector present"];

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_local_endpoint(parameters, nw_endpoint_create_host("127.0.0.1", "0"));
    nw_listener_t listener = nw_listener_create(parameters);
    self.listener = listener;
    nw_listener_set_queue(listener, dispatch_get_main_queue());
    __block BOOL gotConnection = NO;
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        nw_connection_set_queue(connection, dispatch_get_main_queue());
        nw_connection_start(connection);
        nw_connection_receive(connection, 1, 64, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
            if (gotConnection) return;
            gotConnection = YES;
            NSMutableString *hex = [NSMutableString string];
            if (content != nil) {
                dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                    const uint8_t *bytes = buffer;
                    for (size_t i = 0; i < size; i++) [hex appendFormat:@"%02x", bytes[i]];
                    return true;
                });
            }
            [self record:@"proxyConnection" value:[NSString stringWithFormat:@"WebKit connected to local SOCKS listener, first bytes %@", hex]];
            nw_connection_cancel(connection);
        });
    });
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        if (state == nw_listener_state_ready) {
            uint16_t port = nw_listener_get_port(listener);
            [self record:@"proxyListener" value:[NSString stringWithFormat:@"ready on 127.0.0.1:%u", port]];
            nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", [NSString stringWithFormat:@"%u", port].UTF8String);
            nw_proxy_config_t proxy = nw_proxy_config_create_socksv5(endpoint);
            ((void (*)(id, SEL, id))objc_msgSend)(dataStore, setProxies, @[proxy]);
            id configuration = [self makeConfigurationWithDataStore:dataStore];
            BrowserProbeNavigationDelegate *delegate = [BrowserProbeNavigationDelegate new];
            delegate.onEvent = ^(NSString *event) {
                [self record:@"proxyNavigation" value:event];
            };
            [self.retained addObject:delegate];
            id webView = [self makeHiddenWebViewWithConfiguration:configuration];
            ((void (*)(id, SEL, id))objc_msgSend)(webView, NSSelectorFromString(@"setNavigationDelegate:"), delegate);
            NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.com/"]];
            ((void (*)(id, SEL, id))objc_msgSend)(webView, NSSelectorFromString(@"loadRequest:"), request);
        } else if (state == nw_listener_state_failed) {
            [self record:@"proxyListener" value:[NSString stringWithFormat:@"failed %d", error ? nw_error_get_error_code(error) : 0]];
        }
    });
    nw_listener_start(listener);
}

#pragma mark Verschlüsseltes DNS über Cloudflare

- (void)probeEncryptedDNS {
    nw_endpoint_t dohURL = nw_endpoint_create_url("https://cloudflare-dns.com/dns-query");
    nw_resolver_config_t resolver = nw_resolver_config_create_https(dohURL);
    nw_resolver_config_add_server_address(resolver, nw_endpoint_create_host("1.1.1.1", "443"));
    nw_resolver_config_add_server_address(resolver, nw_endpoint_create_host("1.0.0.1", "443"));
    nw_privacy_context_t context = nw_privacy_context_create("cloudflare-doh-probe");
    nw_privacy_context_require_encrypted_name_resolution(context, true, resolver);

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DEFAULT_CONFIGURATION, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_privacy_context(parameters, context);
    nw_connection_t connection = nw_connection_create(nw_endpoint_create_host("example.com", "443"), parameters);
    self.dohConnection = connection;
    nw_connection_set_queue(connection, dispatch_get_main_queue());
    NSDate *start = [NSDate date];
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        if (state == nw_connection_state_ready) {
            NSString *remote = @"?";
            nw_path_t path = nw_connection_copy_current_path(connection);
            nw_endpoint_t endpoint = path ? nw_path_copy_effective_remote_endpoint(path) : nil;
            if (endpoint != nil) {
                char *description = nw_endpoint_copy_address_string(endpoint);
                if (description) { remote = @(description); free(description); }
            }
            [self record:@"encryptedDNS" value:[NSString stringWithFormat:@"ready via Cloudflare DoH in %.0f ms, remote %@",
                                                -[start timeIntervalSinceNow] * 1000.0, remote]];
            nw_connection_cancel(connection);
        } else if (state == nw_connection_state_failed || state == nw_connection_state_waiting) {
            [self record:@"encryptedDNS" value:[NSString stringWithFormat:@"state %d error %d", state, error ? nw_error_get_error_code(error) : 0]];
        }
    });
    nw_connection_start(connection);
}

@end
