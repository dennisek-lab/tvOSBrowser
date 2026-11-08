#import "BrowserDNSProxy.h"
#import <Network/Network.h>
#import <objc/message.h>

static NSString * const kDNSOverCloudflareDefaultsKey = @"DNSOverCloudflare";
static const size_t kRelayChunkSize = 64 * 1024;

#pragma mark - Einzelne SOCKS-Sitzung

@class BrowserSOCKSSession;

@interface BrowserDNSProxy ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong, nullable) nw_listener_t listener;
@property (nonatomic, strong) nw_privacy_context_t privacyContext;
@property (nonatomic, strong) NSMutableSet<BrowserSOCKSSession *> *sessions;
@property (nonatomic, readwrite) uint16_t port;
@property (nonatomic, readwrite) NSUInteger connectionCount;
@property (nonatomic, readwrite) NSUInteger failureCount;
- (void)sessionDidFinish:(BrowserSOCKSSession *)session;
- (void)sessionDidConnect:(BOOL)success;
@end

typedef NS_ENUM(NSInteger, BrowserSOCKSState) {
    BrowserSOCKSStateGreeting,
    BrowserSOCKSStateRequest,
    BrowserSOCKSStateConnecting,
    BrowserSOCKSStateRelaying,
    BrowserSOCKSStateClosed,
};

@interface BrowserSOCKSSession : NSObject
@property (nonatomic, weak) BrowserDNSProxy *proxy;
@property (nonatomic, strong) nw_connection_t client;
@property (nonatomic, strong, nullable) nw_connection_t upstream;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic) BrowserSOCKSState state;
@property (nonatomic) BOOL clientFinished;
@property (nonatomic) BOOL upstreamFinished;
@end

@implementation BrowserSOCKSSession

- (instancetype)initWithClient:(nw_connection_t)client proxy:(BrowserDNSProxy *)proxy {
    self = [super init];
    if (self) {
        _client = client;
        _proxy = proxy;
        _buffer = [NSMutableData data];
        _state = BrowserSOCKSStateGreeting;
    }
    return self;
}

- (void)start {
    __weak typeof(self) weakSelf = self;
    nw_connection_set_queue(self.client, self.proxy.queue);
    nw_connection_set_state_changed_handler(self.client, ^(nw_connection_state_t state, nw_error_t error) {
        if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            [weakSelf close];
        }
    });
    nw_connection_start(self.client);
    [self readHandshake];
}

#pragma mark Handshake

- (void)readHandshake {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(self.client, 1, 4096, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        typeof(self) self = weakSelf;
        if (self == nil || self.state == BrowserSOCKSStateClosed) {
            return;
        }
        if (content != nil) {
            [self.buffer appendData:(NSData *)content];
        }
        if (error != nil || (complete && content == nil)) {
            [self close];
            return;
        }
        [self processHandshake];
    });
}

- (void)processHandshake {
    const uint8_t *bytes = self.buffer.bytes;
    NSUInteger length = self.buffer.length;

    if (self.state == BrowserSOCKSStateGreeting) {
        if (length < 2) { [self readHandshake]; return; }
        if (bytes[0] != 0x05) { [self close]; return; }
        NSUInteger needed = 2 + bytes[1];
        if (length < needed) { [self readHandshake]; return; }
        [self.buffer replaceBytesInRange:NSMakeRange(0, needed) withBytes:NULL length:0];
        self.state = BrowserSOCKSStateRequest;
        static const uint8_t noAuth[] = {0x05, 0x00};
        [self sendToClient:[NSData dataWithBytes:noAuth length:sizeof(noAuth)] completion:nil];
        if (self.buffer.length > 0) {
            [self processHandshake];
        } else {
            [self readHandshake];
        }
        return;
    }

    if (self.state != BrowserSOCKSStateRequest) {
        return;
    }
    if (length < 5) { [self readHandshake]; return; }
    if (bytes[0] != 0x05) { [self close]; return; }
    if (bytes[1] != 0x01) {           // nur CONNECT
        [self replyAndClose:0x07];
        return;
    }
    uint8_t addressType = bytes[3];
    NSString *host = nil;
    NSUInteger addressEnd = 0;
    if (addressType == 0x01) {        // IPv4
        addressEnd = 4 + 4;
        if (length < addressEnd + 2) { [self readHandshake]; return; }
        host = [NSString stringWithFormat:@"%u.%u.%u.%u", bytes[4], bytes[5], bytes[6], bytes[7]];
    } else if (addressType == 0x03) { // Domainname
        NSUInteger nameLength = bytes[4];
        addressEnd = 5 + nameLength;
        if (length < addressEnd + 2) { [self readHandshake]; return; }
        host = [[NSString alloc] initWithBytes:bytes + 5 length:nameLength encoding:NSUTF8StringEncoding];
    } else if (addressType == 0x04) { // IPv6
        addressEnd = 4 + 16;
        if (length < addressEnd + 2) { [self readHandshake]; return; }
        NSMutableString *v6 = [NSMutableString string];
        for (int i = 0; i < 16; i += 2) {
            [v6 appendFormat:@"%s%x", i == 0 ? "" : ":", (bytes[4 + i] << 8) | bytes[5 + i]];
        }
        host = v6;
    } else {
        [self replyAndClose:0x08];
        return;
    }
    uint16_t port = (uint16_t)((bytes[addressEnd] << 8) | bytes[addressEnd + 1]);
    [self.buffer replaceBytesInRange:NSMakeRange(0, addressEnd + 2) withBytes:NULL length:0];
    if (host.length == 0 || port == 0) {
        [self replyAndClose:0x01];
        return;
    }
    self.state = BrowserSOCKSStateConnecting;
    [self connectToHost:host port:port];
}

#pragma mark Ausgehende Verbindung

- (void)connectToHost:(NSString *)host port:(uint16_t)port {
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_privacy_context(parameters, self.proxy.privacyContext);
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, [NSString stringWithFormat:@"%u", port].UTF8String);
    nw_connection_t upstream = nw_connection_create(endpoint, parameters);
#if DEBUG
    NSLog(@"[DNSProxy] CONNECT %@:%u", host, port);
#endif
    self.upstream = upstream;
    nw_connection_set_queue(upstream, self.proxy.queue);

    __weak typeof(self) weakSelf = self;
    nw_connection_set_state_changed_handler(upstream, ^(nw_connection_state_t state, nw_error_t error) {
        typeof(self) self = weakSelf;
        if (self == nil) {
            return;
        }
        switch (state) {
            case nw_connection_state_ready:
                if (self.state == BrowserSOCKSStateConnecting) {
                    [self.proxy sessionDidConnect:YES];
                    [self didConnect];
                }
                break;
            case nw_connection_state_waiting:
                // Ohne Netz oder ohne erreichbaren DoH-Server: nicht ewig warten, WebKit soll einen Fehler sehen.
                if (self.state == BrowserSOCKSStateConnecting) {
                    [self.proxy sessionDidConnect:NO];
                    [self replyAndClose:0x04];
                }
                break;
            case nw_connection_state_failed:
                if (self.state == BrowserSOCKSStateConnecting) {
                    [self.proxy sessionDidConnect:NO];
                    [self replyAndClose:0x05];
                } else {
                    [self close];
                }
                break;
            case nw_connection_state_cancelled:
                [self close];
                break;
            default:
                break;
        }
    });
    nw_connection_start(upstream);
}

- (void)didConnect {
    self.state = BrowserSOCKSStateRelaying;
    // Erfolg, gebundene Adresse 0.0.0.0:0
    static const uint8_t success[] = {0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
    [self sendToClient:[NSData dataWithBytes:success length:sizeof(success)] completion:nil];
    if (self.buffer.length > 0) {
        NSData *pending = [self.buffer copy];
        [self.buffer setLength:0];
        nw_connection_send(self.upstream, [self dispatchDataFromData:pending], NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {});
    }
    [self relayFrom:self.client to:self.upstream fromClient:YES];
    [self relayFrom:self.upstream to:self.client fromClient:NO];
}

#pragma mark Weiterreichen

- (void)relayFrom:(nw_connection_t)source to:(nw_connection_t)destination fromClient:(BOOL)fromClient {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(source, 1, kRelayChunkSize, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        typeof(self) self = weakSelf;
        if (self == nil || self.state != BrowserSOCKSStateRelaying) {
            return;
        }
        BOOL endOfStream = complete || error != nil;
        if (content != nil) {
            nw_connection_send(destination, content, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t sendError) {
                typeof(self) self = weakSelf;
                if (self == nil) {
                    return;
                }
                if (sendError != nil) {
                    [self close];
                    return;
                }
                if (endOfStream) {
                    [self finishDirectionTo:destination fromClient:fromClient];
                } else {
                    [self relayFrom:source to:destination fromClient:fromClient];
                }
            });
        } else if (endOfStream) {
            [self finishDirectionTo:destination fromClient:fromClient];
        } else {
            [self relayFrom:source to:destination fromClient:fromClient];
        }
    });
}

/// Eine Richtung ist zu Ende: Schreibseite des Ziels schließen. Sind beide Richtungen fertig, Sitzung beenden.
- (void)finishDirectionTo:(nw_connection_t)destination fromClient:(BOOL)fromClient {
    nw_connection_send(destination, NULL, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t error) {});
    if (fromClient) {
        self.clientFinished = YES;
    } else {
        self.upstreamFinished = YES;
    }
    if (self.clientFinished && self.upstreamFinished) {
        [self close];
    }
}

#pragma mark Hilfen

- (dispatch_data_t)dispatchDataFromData:(NSData *)data {
    NSData *copy = [data copy];
    return dispatch_data_create(copy.bytes, copy.length, self.proxy.queue, ^{ (void)copy; });
}

- (void)sendToClient:(NSData *)data completion:(void (^_Nullable)(void))completion {
    nw_connection_send(self.client, [self dispatchDataFromData:data], NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        if (completion != nil) {
            completion();
        }
    });
}

- (void)replyAndClose:(uint8_t)code {
    uint8_t reply[] = {0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
    __weak typeof(self) weakSelf = self;
    [self sendToClient:[NSData dataWithBytes:reply length:sizeof(reply)] completion:^{
        [weakSelf close];
    }];
}

- (void)close {
    if (self.state == BrowserSOCKSStateClosed) {
        return;
    }
    self.state = BrowserSOCKSStateClosed;
    if (self.upstream != nil) {
        nw_connection_cancel(self.upstream);
    }
    nw_connection_cancel(self.client);
    [self.proxy sessionDidFinish:self];
}

@end

#pragma mark - Proxy

@implementation BrowserDNSProxy

+ (instancetype)sharedProxy {
    static BrowserDNSProxy *proxy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ proxy = [BrowserDNSProxy new]; });
    return proxy;
}

+ (BOOL)isEnabled {
#if DEBUG
    if ([NSProcessInfo.processInfo.environment[@"DNS_PROXY"] isEqualToString:@"off"]) {
        return NO;
    }
#endif
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kDNSOverCloudflareDefaultsKey];
    return value == nil ? YES : [value boolValue];
}

+ (void)setEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kDNSOverCloudflareDefaultsKey];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("io.github.tvosbrowser.app.dnsproxy", DISPATCH_QUEUE_SERIAL);
        _sessions = [NSMutableSet set];
        _privacyContext = nw_privacy_context_create("cloudflare-doh");
        nw_privacy_context_require_encrypted_name_resolution(_privacyContext, true, [BrowserDNSProxy cloudflareResolver]);
    }
    return self;
}

+ (nw_resolver_config_t)cloudflareResolver {
    nw_resolver_config_t resolver = nw_resolver_config_create_https(nw_endpoint_create_url("https://cloudflare-dns.com/dns-query"));
    // Feste Adressen, damit nicht einmal der Name des DoH-Servers beim Provider-DNS landet.
    for (NSString *address in @[@"1.1.1.1", @"1.0.0.1", @"2606:4700:4700::1111", @"2606:4700:4700::1001"]) {
        nw_resolver_config_add_server_address(resolver, nw_endpoint_create_host(address.UTF8String, "443"));
    }
    return resolver;
}

- (BOOL)startAndWaitWithTimeout:(NSTimeInterval)timeout {
    if (!BrowserDNSProxy.isEnabled) {
        return NO;
    }
    // App-eigene Verbindungen (URLSession, Network) ebenfalls über Cloudflare auflösen.
    static dispatch_once_t defaultContextOnce;
    dispatch_once(&defaultContextOnce, ^{
        nw_privacy_context_require_encrypted_name_resolution(NW_DEFAULT_PRIVACY_CONTEXT, true, [BrowserDNSProxy cloudflareResolver]);
    });

    __block BOOL alreadyRunning = NO;
    dispatch_sync(self.queue, ^{ alreadyRunning = self.listener != nil && self.port != 0; });
    if (alreadyRunning) {
        return YES;
    }

    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_async(self.queue, ^{
        nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        nw_parameters_set_local_endpoint(parameters, nw_endpoint_create_host("127.0.0.1", "0"));
        nw_listener_t listener = nw_listener_create(parameters);
        if (listener == nil) {
            dispatch_semaphore_signal(ready);
            return;
        }
        self.listener = listener;
        nw_listener_set_queue(listener, self.queue);
        __weak typeof(self) weakSelf = self;
        nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
            typeof(self) self = weakSelf;
            if (self == nil) {
                nw_connection_cancel(connection);
                return;
            }
            BrowserSOCKSSession *session = [[BrowserSOCKSSession alloc] initWithClient:connection proxy:self];
            [self.sessions addObject:session];
            [session start];
        });
        __block BOOL signalled = NO;
        nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
            typeof(self) self = weakSelf;
            if (state == nw_listener_state_ready) {
                self.port = nw_listener_get_port(listener);
                NSLog(@"[DNSProxy] SOCKS5 auf 127.0.0.1:%u, DNS über Cloudflare", self.port);
            } else if (state == nw_listener_state_failed || state == nw_listener_state_cancelled) {
                NSLog(@"[DNSProxy] Listener beendet (%d)", state);
                self.port = 0;
                self.listener = nil;
            }
            if (!signalled && state != nw_listener_state_invalid && state != nw_listener_state_waiting) {
                signalled = YES;
                dispatch_semaphore_signal(ready);
            }
        });
        nw_listener_start(listener);
    });
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));

    __block uint16_t port = 0;
    dispatch_sync(self.queue, ^{ port = self.port; });
    return port != 0;
}

- (void)applyToWebsiteDataStore:(id)dataStore {
    SEL setter = NSSelectorFromString(@"setProxyConfigurations:");
    if (dataStore == nil || ![dataStore respondsToSelector:setter]) {
        return;
    }
    __block uint16_t port = 0;
    dispatch_sync(self.queue, ^{ port = self.port; });
    NSArray *configurations = nil;
    if (BrowserDNSProxy.isEnabled && port != 0) {
        nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", [NSString stringWithFormat:@"%u", port].UTF8String);
        configurations = @[nw_proxy_config_create_socksv5(endpoint)];
    }
    ((void (*)(id, SEL, id))objc_msgSend)(dataStore, setter, configurations);
}

- (void)sessionDidConnect:(BOOL)success {
    if (success) {
        self.connectionCount += 1;
    } else {
        self.failureCount += 1;
    }
#if DEBUG
    if ((self.connectionCount + self.failureCount) % 10 == 1 || !success) {
        NSLog(@"[DNSProxy] Verbindungen ok=%lu fehlgeschlagen=%lu", (unsigned long)self.connectionCount, (unsigned long)self.failureCount);
    }
#endif
}

- (void)sessionDidFinish:(BrowserSOCKSSession *)session {
    [self.sessions removeObject:session];
}

@end
