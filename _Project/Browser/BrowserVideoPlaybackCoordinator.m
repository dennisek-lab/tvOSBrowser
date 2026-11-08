#import "BrowserVideoPlaybackCoordinator.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"
#import "BrowserYouTubeExtractor.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static BOOL const kBrowserYouTubeNativeExtractionEnabled = NO;

@interface BrowserVideoPlaybackCoordinator ()

@property (nonatomic, weak) id<BrowserVideoPlaybackCoordinatorHost> host;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserYouTubeExtractor *youTubeExtractor;
/// Läuft gerade eine Übergabe an den nativen Player (Skriptabfrage oder Player offen)?
@property (nonatomic) BOOL handoverInProgress;
@property (nonatomic, weak) BrowserNativeVideoPlayerViewController *activePlayer;

@end

/// Auslöser einer Übergabe an den nativen Player.
typedef NS_ENUM(NSInteger, BrowserPageVideoTrigger) {
    BrowserPageVideoTriggerMenu,        ///< Schnellmenü „Im Player öffnen“
    BrowserPageVideoTriggerFullscreen,  ///< Seite wollte das Video im Vollbild zeigen
    BrowserPageVideoTriggerAutomatic,   ///< Video hat zu spielen begonnen (Einstellung „automatisch öffnen“)
};

@implementation BrowserVideoPlaybackCoordinator

- (BOOL)isFullscreenVideoPlaybackEnabled {
    return self.host.browserFullscreenVideoPlaybackEnabled;
}

- (instancetype)initWithHost:(id<BrowserVideoPlaybackCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService {
    self = [super init];
    if (self) {
        _host = host;
        _domInteractionService = domInteractionService;
    }
    return self;
}

- (BrowserYouTubeExtractor *)youTubeExtractor {
    if (_youTubeExtractor == nil) {
        _youTubeExtractor = [BrowserYouTubeExtractor new];
    }
    return _youTubeExtractor;
}

- (void)playVideoUnderCursorIfAvailable {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        return;
    }

    UIViewController *presentedViewController = self.host.browserPresentedViewController;
    if (!self.host.browserIsCursorModeEnabled ||
        (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]])) {
        return;
    }

    NSURL *pageURL = self.host.browserWebView.request.URL;
    CGPoint point = self.host.browserDOMCursorPoint;
    NSDictionary *videoInfo = [self.domInteractionService videoInfoAtDOMPoint:point
                                                                       webView:self.host.browserWebView];
    if (kBrowserYouTubeNativeExtractionEnabled && [[self youTubeExtractor] canExtractFromPageURL:pageURL]) {
        [self playYouTubeVideoAtPageURL:pageURL fallbackVideoInfo:videoInfo];
        return;
    }

    NSString *videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
    if (![self isNativePlayableVideoURLString:videoURLString] &&
        [self.domInteractionService isVideoActivationTargetAtDOMPoint:point webView:self.host.browserWebView]) {
        NSDictionary *activatedVideoInfo = [self.domInteractionService activateVideoTargetAtDOMPoint:point
                                                                                              webView:self.host.browserWebView
                                                                                              timeout:1.5];
        if (activatedVideoInfo.count > 0) {
            videoInfo = activatedVideoInfo;
            videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
        }
    }

    if (![self isNativePlayableVideoURLString:videoURLString]) {
        [self presentUnsupportedNativeVideoAlertForVideoInfo:videoInfo ?: @{}];
        return;
    }

    NSURL *videoURL = [NSURL URLWithString:videoURLString];
    NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : self.host.browserCurrentPageTitle;
    [self presentNativeVideoPlayerForURL:videoURL title:title];
}

- (BOOL)handleSelectPressForVideoAtCursor {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        return NO;
    }

    CGPoint point = self.host.browserDOMCursorPoint;
    if ([self.domInteractionService isVideoDismissTargetAtDOMPoint:point webView:self.host.browserWebView]) {
        return NO;
    }

    NSDictionary *directVideoInfo = [self.domInteractionService directVideoInfoAtDOMPoint:point
                                                                                   webView:self.host.browserWebView];
    NSString *directVideoURLString = [self nativePlayableURLStringFromVideoInfo:directVideoInfo];
    if ([self isNativePlayableVideoURLString:directVideoURLString]) {
        NSURL *videoURL = [NSURL URLWithString:directVideoURLString];
        NSString *title = [directVideoInfo[@"title"] isKindOfClass:[NSString class]] ? directVideoInfo[@"title"] : self.host.browserCurrentPageTitle;
        [self presentNativeVideoPlayerForURL:videoURL title:title];
        return YES;
    }

    if (![self.domInteractionService isVideoActivationTargetAtDOMPoint:point webView:self.host.browserWebView]) {
        return NO;
    }

    NSDictionary *videoInfo = [self.domInteractionService primedVideoInfoAtDOMPoint:point webView:self.host.browserWebView];
    if (videoInfo.count == 0) {
        videoInfo = [self.domInteractionService videoInfoAtDOMPoint:point webView:self.host.browserWebView];
    }

    NSString *videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
    if (![self isNativePlayableVideoURLString:videoURLString]) {
        NSDictionary *activatedVideoInfo = [self.domInteractionService activateVideoTargetAtDOMPoint:point
                                                                                              webView:self.host.browserWebView
                                                                                              timeout:1.5];
        if (activatedVideoInfo.count > 0) {
            videoInfo = activatedVideoInfo;
            videoURLString = [self nativePlayableURLStringFromVideoInfo:videoInfo];
        }
    }

    if ([self isNativePlayableVideoURLString:videoURLString]) {
        NSURL *videoURL = [NSURL URLWithString:videoURLString];
        NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : self.host.browserCurrentPageTitle;
        [self presentNativeVideoPlayerForURL:videoURL title:title];
    } else {
        [self presentUnsupportedNativeVideoAlertForVideoInfo:videoInfo ?: @{}];
    }
    return YES;
}

- (NSString *)nativePlayableURLStringFromVideoInfo:(NSDictionary *)videoInfo {
    NSString *primarySource = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
    if ([self isNativePlayableVideoURLString:primarySource]) {
        return primarySource;
    }

    NSArray *sources = [videoInfo[@"sources"] isKindOfClass:[NSArray class]] ? videoInfo[@"sources"] : @[];
    for (id sourceValue in sources) {
        if (![sourceValue isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *source = (NSString *)sourceValue;
        if ([self isNativePlayableVideoURLString:source]) {
            return source;
        }
    }

    return primarySource;
}

- (BOOL)isNativePlayableVideoURLString:(NSString *)URLString {
    if (URLString.length == 0) {
        return NO;
    }

    NSString *lowercaseURLString = URLString.lowercaseString;
    if ([lowercaseURLString hasPrefix:@"blob:"] ||
        [lowercaseURLString hasPrefix:@"data:"] ||
        [lowercaseURLString hasPrefix:@"mediastream:"]) {
        return NO;
    }

    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return NO;
    }

    NSString *scheme = URL.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

- (void)presentNativeVideoPlayerForURL:(NSURL *)URL title:(NSString *)title {
    [self presentNativeVideoPlayerForURL:URL title:title requestHeaders:nil cookies:nil];
}

- (void)presentNativeVideoPlayerForURL:(NSURL *)URL
                                 title:(NSString *)title
                        requestHeaders:(NSDictionary<NSString *, NSString *> *)requestHeaders
                               cookies:(NSArray<NSHTTPCookie *> *)cookies {
    if (![self isFullscreenVideoPlaybackEnabled]) {
        return;
    }

    if (URL == nil) {
        return;
    }

    [self.host.browserWebView pauseAllMediaPlayback];

    BrowserNativeVideoPlayerViewController *playerViewController = [[BrowserNativeVideoPlayerViewController alloc] initWithURL:URL
                                                                                                                          title:title
                                                                                                                  requestHeaders:requestHeaders
                                                                                                                         cookies:cookies];
    [self.host browserPresentViewController:playerViewController];
}

#pragma mark - Übergabe von Seitenvideos an den nativen Player

/// Wählt das Video (Kennung, Zeigerposition, sonst laufendes, aktives, größtes), merkt es sich als
/// `window.__browserHandoverVideo` und liefert JSON mit Adressen, Position und Seitenangaben. Pausiert nicht.
static NSString *BrowserPageVideoProbeScript(NSInteger bid, CGPoint point) {
    return [NSString stringWithFormat:@"(function(bid,x,y){"
        "var vs=[].slice.call(document.querySelectorAll('video')), v=null, i;"
        "if (bid>0 && window.__browserVideoById) { v=window.__browserVideoById(bid); }"
        "if (!v && x>=0) { for (i=0;i<vs.length;i++){ var r=vs[i].getBoundingClientRect(); if (x>=r.left&&x<=r.right&&y>=r.top&&y<=r.bottom) { v=vs[i]; } } }"
        "if (!v) { for (i=0;i<vs.length;i++){ if (!vs[i].paused && !vs[i].ended) { v=vs[i]; break; } } }"
        "if (!v && window.__browserActiveVideo && window.__browserActiveVideo.isConnected) { v=window.__browserActiveVideo; }"
        "if (!v) { var best=0; for (i=0;i<vs.length;i++){ var q=vs[i].getBoundingClientRect(); var a=q.width*q.height; if (a>best) { best=a; v=vs[i]; } } }"
        "if (!v) { return ''; }"
        "window.__browserHandoverVideo=v; v.__bnoauto=true;"
        "var srcs=[], ss=v.querySelectorAll('source'); for (i=0;i<ss.length;i++){ if (ss[i].src) { srcs.push(ss[i].src); } }"
        "var m=window.__browserManifests||{};"
        "return JSON.stringify({cs:v.currentSrc||'',src:v.src||'',sources:srcs,hls:m.hls||'',hlsAll:m.all||[],dash:m.dash||'',"
            "t:v.currentTime||0,ua:navigator.userAgent||'',page:location.href,title:document.title||'',paused:v.paused});"
        "})(%ld,%f,%f);", (long)bid, point.x, point.y];
}

static NSString * const kBrowserHandoverPauseScript = @"(function(){ var v=window.__browserHandoverVideo; if (!v) { return -1; } try { v.pause(); } catch(e) {} return v.currentTime||0; })();";
static NSString * const kBrowserHandoverResumeScript = @"(function(){ var v=window.__browserHandoverVideo; if (v) { var p=v.play(); if (p && p.catch) { p.catch(function(){}); } } })();";

- (BOOL)pageHasVideo {
    BrowserWebView *webView = self.host.browserWebView;
    return webView != nil && (webView.videoRects.count > 0 || webView.mediaInfo != nil);
}

- (void)openPageVideoInNativePlayer {
    [self openPageVideoWithID:0 trigger:BrowserPageVideoTriggerMenu];
}

- (void)handlePageVideoEvent:(NSDictionary *)event {
    NSString *type = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"";
    NSInteger bid = [event[@"bid"] respondsToSelector:@selector(integerValue)] ? [event[@"bid"] integerValue] : 0;
    if ([type isEqualToString:@"fullscreen"]) {
        [self openPageVideoWithID:bid trigger:BrowserPageVideoTriggerFullscreen];
    } else if ([type isEqualToString:@"playing"]) {
        if (![[BrowserPreferencesStore new] autoOpenVideosInNativePlayer]) {
            return;
        }
        [self openPageVideoWithID:bid trigger:BrowserPageVideoTriggerAutomatic];
    }
}

- (BOOL)isExtensionUnsupportedByAVPlayerForURL:(NSURL *)URL {
    NSString *extension = URL.path.pathExtension.lowercaseString;
    NSSet<NSString *> *unsupported = [NSSet setWithObjects:@"mpd", @"webm", @"ogv", @"ogg", @"flv", @"mkv", @"avi", @"f4v", nil];
    return [unsupported containsObject:extension];
}

- (BOOL)isNativeCandidateURLString:(NSString *)URLString {
    if (![self isNativePlayableVideoURLString:URLString]) {
        return NO;
    }
    NSURL *URL = [NSURL URLWithString:URLString];
    return URL != nil && ![self isExtensionUnsupportedByAVPlayerForURL:URL];
}

/// Direkte Adresse des Videos, sonst das zuletzt beobachtete HLS-Manifest (MSE/blob:). DASH und WebM gehen nicht.
- (NSURL *)nativeURLFromProbe:(NSDictionary *)probe unsupportedReason:(NSString **)reason {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *key in @[@"cs", @"src"]) {
        if ([probe[key] isKindOfClass:[NSString class]]) {
            [candidates addObject:probe[key]];
        }
    }
    if ([probe[@"sources"] isKindOfClass:[NSArray class]]) {
        for (id source in probe[@"sources"]) {
            if ([source isKindOfClass:[NSString class]]) {
                [candidates addObject:source];
            }
        }
    }
    if ([probe[@"hls"] isKindOfClass:[NSString class]]) {
        [candidates addObject:probe[@"hls"]];
    }
    for (NSString *candidate in candidates) {
        if ([self isNativeCandidateURLString:candidate]) {
            return [NSURL URLWithString:candidate];
        }
    }
    NSString *dash = [probe[@"dash"] isKindOfClass:[NSString class]] ? probe[@"dash"] : @"";
    BOOL hasUnsupportedFile = dash.length > 0;
    for (NSString *candidate in candidates) {
        NSURL *URL = [NSURL URLWithString:candidate];
        if (URL != nil && [self isNativePlayableVideoURLString:candidate] && [self isExtensionUnsupportedByAVPlayerForURL:URL]) {
            hasUnsupportedFile = YES;
        }
    }
    if (reason != NULL) {
        *reason = hasUnsupportedFile
            ? @"Dieses Video nutzt ein Format (DASH oder WebM), das der native Player nicht abspielen kann. Es bleibt in der Webseite."
            : @"Für dieses Video wurde keine Adresse gefunden, die der native Player öffnen kann. Es bleibt in der Webseite.";
    }
    return nil;
}

/// Cookies aus dem Datenspeicher der WebView (nicht aus NSHTTPCookieStorage), passend zu Adresse, Pfad und Ablauf.
- (NSArray<NSHTTPCookie *> *)webViewCookiesForURL:(NSURL *)URL {
    NSString *host = URL.host.lowercaseString;
    if (host.length == 0) {
        return @[];
    }
    BOOL secureScheme = [URL.scheme.lowercaseString isEqualToString:@"https"];
    NSString *requestPath = URL.path.length > 0 ? URL.path : @"/";
    NSDate *now = [NSDate date];
    NSMutableArray<NSHTTPCookie *> *matching = [NSMutableArray array];
    for (NSHTTPCookie *cookie in [BrowserWebView allCookies]) {
        if (![self cookie:cookie matchesHost:host]) {
            continue;
        }
        if (cookie.isSecure && !secureScheme) {
            continue;
        }
        if (cookie.expiresDate != nil && [cookie.expiresDate compare:now] == NSOrderedAscending) {
            continue;
        }
        NSString *cookiePath = cookie.path.length > 0 ? cookie.path : @"/";
        if (![requestPath hasPrefix:cookiePath]) {
            continue;
        }
        [matching addObject:cookie];
    }
    return matching;
}

- (void)openPageVideoWithID:(NSInteger)bid trigger:(BrowserPageVideoTrigger)trigger {
    BrowserWebView *webView = self.host.browserWebView;
    BOOL automatic = trigger == BrowserPageVideoTriggerAutomatic;
    if (webView == nil || self.handoverInProgress || self.activePlayer != nil) {
        return;
    }
    UIViewController *presented = self.host.browserPresentedViewController;
    if (presented != nil && (automatic || [presented isKindOfClass:[BrowserNativeVideoPlayerViewController class]])) {
        return;
    }

    CGPoint point = trigger == BrowserPageVideoTriggerMenu ? self.host.browserDOMCursorPoint : CGPointMake(-1.0, -1.0);
    self.handoverInProgress = YES;
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    [webView evaluateJavaScriptAsync:BrowserPageVideoProbeScript(bid, point) completion:^(id result) {
        typeof(self) strongSelf = weakSelf;
        BrowserWebView *strongWebView = weakWebView;
        if (strongSelf == nil || strongWebView == nil) {
            return;
        }
        NSDictionary *probe = nil;
        if ([result isKindOfClass:[NSString class]] && [result length] > 0) {
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            probe = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
        }
        if (probe == nil) {
            strongSelf.handoverInProgress = NO;
            if (!automatic) {
                [strongSelf presentNativePlayerNoticeWithMessage:@"Auf dieser Seite wurde kein Video gefunden."];
            }
            return;
        }
        NSString *reason = nil;
        NSURL *videoURL = [strongSelf nativeURLFromProbe:probe unsupportedReason:&reason];
        if (videoURL == nil) {
            strongSelf.handoverInProgress = NO;
            if (!automatic) {
                [strongSelf presentNativePlayerNoticeWithMessage:reason];
            }
            return;
        }
        [strongSelf pauseAndPresentPlayerForURL:videoURL probe:probe webView:strongWebView];
    }];
}

- (void)pauseAndPresentPlayerForURL:(NSURL *)videoURL probe:(NSDictionary *)probe webView:(BrowserWebView *)webView {
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    [webView evaluateJavaScriptAsync:kBrowserHandoverPauseScript completion:^(id result) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        double time = [result respondsToSelector:@selector(doubleValue)] ? [result doubleValue] : [probe[@"t"] doubleValue];
        if (time < 0.0 || !isfinite(time)) {
            time = [probe[@"t"] doubleValue];
        }

        NSURL *pageURL = [NSURL URLWithString:[probe[@"page"] isKindOfClass:[NSString class]] ? probe[@"page"] : @""];
        NSString *userAgent = [probe[@"ua"] isKindOfClass:[NSString class]] ? probe[@"ua"] : @"";
        if (userAgent.length == 0) {
            userAgent = [[BrowserPreferencesStore new] userAgent];
        }
        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
        if (userAgent.length > 0) {
            headers[@"User-Agent"] = userAgent;
        }
        if (pageURL.absoluteString.length > 0) {
            headers[@"Referer"] = pageURL.absoluteString;
            if (pageURL.scheme.length > 0 && pageURL.host.length > 0) {
                NSString *port = pageURL.port != nil ? [NSString stringWithFormat:@":%@", pageURL.port] : @"";
                headers[@"Origin"] = [NSString stringWithFormat:@"%@://%@%@", pageURL.scheme, pageURL.host, port];
            }
        }
        NSArray<NSHTTPCookie *> *cookies = [strongSelf webViewCookiesForURL:videoURL];

        NSString *title = weakWebView.reportedPageTitle;
        if (title.length == 0) {
            title = weakWebView.reportedSiteName;
        }
        if (title.length == 0) {
            title = [probe[@"title"] isKindOfClass:[NSString class]] ? probe[@"title"] : nil;
        }
        if (title.length == 0) {
            title = pageURL.host;
        }

        BrowserNativeVideoPlayerViewController *player = [[BrowserNativeVideoPlayerViewController alloc] initWithURL:videoURL
                                                                                                              title:title
                                                                                                     requestHeaders:headers
                                                                                                            cookies:cookies];
        player.initialPlaybackTime = time;
        __block BOOL failed = NO;
        player.dismissHandler = ^(NSTimeInterval playbackTime) {
            typeof(self) innerSelf = weakSelf;
            innerSelf.activePlayer = nil;
            innerSelf.handoverInProgress = NO;
            BrowserWebView *innerWebView = weakWebView;
            if (failed || innerWebView == nil) {
                return;
            }
            // Neue Position zurück in die Seite, das Video bleibt pausiert.
            NSString *script = [NSString stringWithFormat:@"(function(){ var v=window.__browserHandoverVideo; if (v) { try { v.currentTime=%f; v.pause(); } catch(e) {} } })();", playbackTime];
            [innerWebView evaluateJavaScriptAsync:script];
            [innerWebView refreshClickTargets];
        };
        player.failureHandler = ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) innerSelf = weakSelf;
                BrowserWebView *innerWebView = weakWebView;
                failed = YES;
                NSLog(@"[NativeVideoPlayer] Wiedergabe fehlgeschlagen, zurück zur Seite: %@", error);
                [innerWebView evaluateJavaScriptAsync:kBrowserHandoverResumeScript];
                BrowserNativeVideoPlayerViewController *failedPlayer = innerSelf.activePlayer;
                innerSelf.activePlayer = nil;
                innerSelf.handoverInProgress = NO;
                [failedPlayer dismissViewControllerAnimated:YES completion:^{
                    [innerSelf presentNativePlayerNoticeWithMessage:@"Der native Player kann dieses Video nicht abspielen. Es läuft weiter in der Webseite."];
                }];
            });
        };
        strongSelf.activePlayer = player;
        [strongSelf.host browserPresentViewController:player];
    }];
}

- (void)presentNativePlayerNoticeWithMessage:(NSString *)message {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Im Player öffnen"
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (NSDictionary<NSString *, NSString *> *)browserHeadersForYouTubePlaybackURL:(NSURL *)playbackURL
                                                                       pageURL:(NSURL *)pageURL {
    if (playbackURL == nil || pageURL == nil) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    NSString *userAgent = [[NSUserDefaults standardUserDefaults] stringForKey:kUserAgentDefaultsKey];
    if (userAgent.length > 0) {
        headers[@"User-Agent"] = userAgent;
    }

    headers[@"Referer"] = pageURL.absoluteString ?: @"https://www.youtube.com/";
    NSString *origin = [NSString stringWithFormat:@"%@://%@", pageURL.scheme ?: @"https", pageURL.host ?: @"www.youtube.com"];
    headers[@"Origin"] = origin;

    NSArray<NSHTTPCookie *> *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:pageURL];
    if (cookies.count > 0) {
        NSDictionary<NSString *, NSString *> *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
        NSString *cookieHeader = cookieHeaders[@"Cookie"];
        if (cookieHeader.length > 0) {
            headers[@"Cookie"] = cookieHeader;
        }
    }

    return headers.count > 0 ? headers : nil;
}

- (BOOL)cookie:(NSHTTPCookie *)cookie matchesHost:(NSString *)host {
    if (cookie == nil || host.length == 0) {
        return NO;
    }

    NSString *cookieDomain = cookie.domain.lowercaseString ?: @"";
    NSString *lowercaseHost = host.lowercaseString;
    if (cookieDomain.length == 0) {
        return NO;
    }

    if ([cookieDomain hasPrefix:@"."]) {
        cookieDomain = [cookieDomain substringFromIndex:1];
    }

    return [lowercaseHost isEqualToString:cookieDomain] || [lowercaseHost hasSuffix:[@"." stringByAppendingString:cookieDomain]];
}

- (NSArray<NSHTTPCookie *> *)browserCookiesForYouTubePlaybackURL:(NSURL *)playbackURL
                                                          pageURL:(NSURL *)pageURL {
    NSMutableArray<NSHTTPCookie *> *matchingCookies = [NSMutableArray array];
    NSMutableSet<NSString *> *seenCookieKeys = [NSMutableSet set];
    NSArray<NSHTTPCookie *> *allCookies = [BrowserWebView allCookies];
    NSString *pageHost = pageURL.host.lowercaseString ?: @"";
    NSString *playbackHost = playbackURL.host.lowercaseString ?: @"";

    for (NSHTTPCookie *cookie in allCookies) {
        BOOL matches = [self cookie:cookie matchesHost:pageHost] ||
            [self cookie:cookie matchesHost:playbackHost] ||
            [self cookie:cookie matchesHost:@"youtube.com"] ||
            [self cookie:cookie matchesHost:@"googlevideo.com"];
        if (!matches) {
            continue;
        }

        NSString *cookieKey = [NSString stringWithFormat:@"%@|%@|%@", cookie.domain ?: @"", cookie.path ?: @"", cookie.name ?: @""];
        if ([seenCookieKeys containsObject:cookieKey]) {
            continue;
        }
        [seenCookieKeys addObject:cookieKey];
        [matchingCookies addObject:cookie];
    }

    return matchingCookies;
}

- (void)presentUnsupportedNativeVideoAlertForVideoInfo:(NSDictionary *)videoInfo {
    NSArray *sources = [videoInfo[@"sources"] isKindOfClass:[NSArray class]] ? videoInfo[@"sources"] : @[];
    NSString *sourceSummary = nil;
    if (sources.count > 0) {
        sourceSummary = [sources componentsJoinedByString:@"\n"];
    } else if (videoInfo.count > 0) {
        sourceSummary = @"No direct media URL was exposed by the page.";
    } else {
        sourceSummary = @"No video element was detected under the cursor.";
    }
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Native Video Unavailable"
                                                                             message:[NSString stringWithFormat:@"This page is not exposing a direct video URL that AVPlayer can open.\n\nDetected sources:\n%@", sourceSummary]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentYouTubeExtractionError:(NSError *)error fallbackVideoInfo:(NSDictionary *)videoInfo {
    NSString *message = error.localizedDescription ?: @"Could not extract a better YouTube playback URL.";
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"YouTube Extraction Failed"
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    NSString *fallbackURLString = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
    if ([self isNativePlayableVideoURLString:fallbackURLString]) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Play Current URL"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURL *fallbackURL = [NSURL URLWithString:fallbackURLString];
            NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : weakSelf.host.browserCurrentPageTitle;
            [weakSelf presentNativeVideoPlayerForURL:fallbackURL title:title];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (void)playYouTubeVideoAtPageURL:(NSURL *)pageURL fallbackVideoInfo:(NSDictionary *)videoInfo {
    __weak typeof(self) weakSelf = self;
    [[self youTubeExtractor] extractPlaybackInfoFromPageURL:pageURL webView:self.host.browserWebView completion:^(BrowserYouTubeExtractionResult *result, NSError *error) {
        if (result.playbackURL != nil) {
            NSString *title = result.title.length > 0 ? result.title : weakSelf.host.browserCurrentPageTitle;
            NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionaryWithDictionary:result.requestHeaders ?: @{}];
            NSDictionary<NSString *, NSString *> *fallbackHeaders = [weakSelf browserHeadersForYouTubePlaybackURL:result.playbackURL pageURL:pageURL];
            [fallbackHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
                if (headers[key].length == 0 && value.length > 0) {
                    headers[key] = value;
                }
            }];

            NSArray<NSHTTPCookie *> *cookies = [weakSelf browserCookiesForYouTubePlaybackURL:result.playbackURL pageURL:pageURL];
            if (cookies.count > 0) {
                NSDictionary<NSString *, NSString *> *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
                NSString *cookieHeader = cookieHeaders[@"Cookie"];
                if (cookieHeader.length > 0) {
                    headers[@"Cookie"] = cookieHeader;
                }
            }

            [weakSelf presentNativeVideoPlayerForURL:result.playbackURL
                                               title:title
                                      requestHeaders:headers.count > 0 ? headers : nil
                                             cookies:cookies];
            return;
        }

        [weakSelf presentYouTubeExtractionError:error fallbackVideoInfo:videoInfo ?: @{}];
    }];
}

@end
