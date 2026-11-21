#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserLocalization.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"
#import "BrowserYouTubeExtractor.h"
#import "BrowserYouTubeHDBridge.h"

#import <QuartzCore/QuartzCore.h>

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static BOOL const kBrowserYouTubeNativeExtractionEnabled = NO;

@interface BrowserVideoPlaybackCoordinator ()

@property (nonatomic, weak) id<BrowserVideoPlaybackCoordinatorHost> host;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserYouTubeExtractor *youTubeExtractor;
/// Läuft gerade eine Übergabe an den nativen Player (Skriptabfrage oder Player offen)?
@property (nonatomic) BOOL handoverInProgress;
/// Stark gehalten: im Bild-in-Bild hängt der Player nicht mehr in der Ansichtshierarchie.
@property (nonatomic, nullable) BrowserNativeVideoPlayerViewController *activePlayer;
/// Vom Seitenskript gemeldete Manifeste und Frame-Videos (Rückkanal `browserVideo`), gültig für `reportedPageURL`.
@property (nonatomic, copy, nullable) NSString *reportedPageURL;
@property (nonatomic, copy, nullable) NSString *reportedHLS;
@property (nonatomic, copy, nullable) NSString *reportedDASH;
@property (nonatomic, copy, nullable) NSDictionary *frameVideo;
@property (nonatomic, nullable) NSDate *frameVideoDate;
/// YouTube in HD (Abschnitt 10.5): baut HLS aus den getrennten Spuren, die der Seitenplayer über die MSE-Brücke abruft.
@property (nonatomic) BrowserYouTubeHDBridge *youTubeHDBridge;
/// Zeitpunkt, zu dem der native Player eines YouTube-HD-Videos zuletzt geschlossen wurde (kein sofortiges Wiederöffnen).
@property (nonatomic, nullable) NSDate *youTubeHDClosedDate;
/// Seite, für die die Brücke schon auf 360p zurückgefallen ist (nur einmal neu laden).
@property (nonatomic, copy, nullable) NSString *youTubeHDFallbackPage;
/// Zähler für den Wächter „Seitenplayer ruft nichts ab“ (gilt nur für das letzte attach).
@property (nonatomic) NSUInteger youTubeHDAttachGeneration;

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
        // Eigener Player der Seite (blob:/MSE, DRM …): Der Aktivierungsklick oben hat ihn schon gestartet. Kein
        // Hinweisdialog, sonst verdeckt er das Video, das gerade in der Seite anläuft.
        NSLog(@"[NativeVideoPlayer] Vollbild-Videowiedergabe: keine Adresse, Video bleibt in der Seite (%@)", videoInfo[@"src"] ?: @"");
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
    if (requestHeaders == nil) {
        requestHeaders = [self requestHeadersForPageURL:[self pageURLOfWebView:self.host.browserWebView] userAgent:@""];
    }
    if (cookies == nil) {
        cookies = [self webViewCookiesForURL:URL];
    }

    BrowserNativeVideoPlayerViewController *playerViewController = [[BrowserNativeVideoPlayerViewController alloc] initWithURL:URL
                                                                                                                          title:title
                                                                                                                  requestHeaders:requestHeaders
                                                                                                                         cookies:cookies];
    [self.host browserPresentViewController:playerViewController];
}

#pragma mark - Übergabe von Seitenvideos an den nativen Player

/// Wählt das Video (Kennung, Zeigerposition, sonst laufendes, aktives, größtes), merkt es sich als
/// `window.__browserHandoverVideo` und liefert JSON mit Adressen, Position, Untertitelspuren und Seitenangaben
/// (Titel, Vorschaubild, Beschreibung). Pausiert nicht.
static NSString *BrowserPageVideoProbeScript(NSInteger bid, CGPoint point) {
    return [NSString stringWithFormat:@"(function(bid,x,y){"
        "var vs=[].slice.call(document.querySelectorAll('video')), v=null, i;"
        "if (bid>0 && window.__browserVideoById) { v=window.__browserVideoById(bid); }"
        "if (!v && x>=0) { for (i=0;i<vs.length;i++){ var r=vs[i].getBoundingClientRect(); if (x>=r.left&&x<=r.right&&y>=r.top&&y<=r.bottom) { v=vs[i]; } } }"
        // Zeiger auf einem Player in einem iframe (Markierung der Player-Brücke): dessen Video, nicht eines der Hauptseite.
        "if (!v && x>=0) { var fe=document.elementFromPoint(x,y); if (fe && /^I?FRAME$/.test(fe.tagName) && fe.hasAttribute('data-browser-player')) { return ''; } }"
        "if (!v) { for (i=0;i<vs.length;i++){ if (!vs[i].paused && !vs[i].ended) { v=vs[i]; break; } } }"
        "if (!v && window.__browserActiveVideo && window.__browserActiveVideo.isConnected) { v=window.__browserActiveVideo; }"
        "if (!v) { var best=0; for (i=0;i<vs.length;i++){ var q=vs[i].getBoundingClientRect(); var a=q.width*q.height; if (a>best) { best=a; v=vs[i]; } } }"
        "if (!v) { return ''; }"
        "window.__browserHandoverVideo=v; v.__bnoauto=true;"
        "var srcs=[], ss=v.querySelectorAll('source'); for (i=0;i<ss.length;i++){ if (ss[i].src) { srcs.push(ss[i].src); } }"
        "var tracks=[], te=v.querySelectorAll('track'); for (i=0;i<te.length;i++){ var t=te[i]; var k=(t.kind||'subtitles').toLowerCase();"
            "if (t.src && (k==='subtitles'||k==='captions')) { tracks.push({src:t.src,lang:t.srclang||'',label:t.label||'',on:!!(t.default||(t.track&&t.track.mode==='showing'))}); } }"
        "var showing=''; try { for (i=0;i<v.textTracks.length;i++){ var tt=v.textTracks[i]; if (tt.mode==='showing' && (tt.kind==='subtitles'||tt.kind==='captions')) { showing=tt.language||'?'; } } } catch(e) {}"
        "function mc(s){ var m=document.querySelector(s); return (m&&m.content)||''; }"
        "var art=''; try { var md=navigator.mediaSession&&navigator.mediaSession.metadata; if (md&&md.artwork&&md.artwork.length) { art=md.artwork[md.artwork.length-1].src||''; } } catch(e) {}"
        "if (!art) { art=v.poster||mc('meta[property=\"og:image\"]')||mc('meta[name=\"twitter:image\"]'); }"
        "try { if (art) { art=new URL(art,location.href).href; } } catch(e) {}"
        "var m=window.__browserManifests||{};"
        "return JSON.stringify({cs:v.currentSrc||'',src:v.src||'',sources:srcs,hls:m.hls||'',hlsAll:m.all||[],dash:m.dash||'',"
            "t:v.currentTime||0,dur:isFinite(v.duration)?v.duration:-1,ua:navigator.userAgent||'',page:location.href,title:document.title||'',paused:v.paused,"
            "tracks:tracks,showing:showing,art:art,desc:mc('meta[property=\"og:description\"]')||mc('meta[name=\"description\"]')});"
        "})(%ld,%f,%f);", (long)bid, point.x, point.y];
}

/// Pausiert das gewählte Video und hält es angehalten, solange der native Player läuft (manche Seiten
/// starten es sonst selbst wieder). Liefert die Position.
static NSString * const kBrowserHandoverPauseScript = @"(function(){ var v=window.__browserHandoverVideo; if (!v) { return -1; }"
    " try { v.pause(); } catch(e) {}"
    " if (!v.__bhold) { v.__bhold=function(){ if (v.__bholding) { try { v.pause(); } catch(e) {} } }; v.addEventListener('play', v.__bhold, true); }"
    " v.__bholding=true; return v.currentTime||0; })();";
static NSString * const kBrowserHandoverReleaseJS = @"v.__bholding=false;";
static NSString * const kBrowserHandoverResumeScript = @"(function(){ var v=window.__browserHandoverVideo; if (v) { v.__bholding=false; var p=v.play(); if (p && p.catch) { p.catch(function(){}); } } })();";

- (BOOL)pageHasVideo {
    BrowserWebView *webView = self.host.browserWebView;
    if (webView == nil) {
        return NO;
    }
    if (webView.videoRects.count > 0 || webView.mediaInfo != nil) {
        return YES;
    }
    [self discardReportsOfOtherPages];
    return self.reportedHLS.length > 0 || self.frameVideo != nil;
}

- (void)openPageVideoInNativePlayer {
    [self openPageVideoWithID:0 trigger:BrowserPageVideoTriggerMenu];
}

- (BrowserNativeVideoPlayerViewController *)currentNativePlayer {
    return self.activePlayer;
}

- (NSURL *)pageURLOfWebView:(BrowserWebView *)webView {
    return webView.committedURL ?: webView.request.URL;
}

- (NSString *)currentPageKey {
    NSURL *URL = [self pageURLOfWebView:self.host.browserWebView];
    if (URL == nil) {
        return @"";
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    components.fragment = nil;
    return components.string ?: @"";
}

/// Meldungen gelten nur für die Seite, auf der sie kamen.
- (void)discardReportsOfOtherPages {
    if (self.reportedPageURL != nil && ![self.reportedPageURL isEqualToString:[self currentPageKey]]) {
        self.reportedPageURL = nil;
        self.reportedHLS = nil;
        self.reportedDASH = nil;
        self.frameVideo = nil;
        self.frameVideoDate = nil;
    }
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
    } else if ([type isEqualToString:@"manifest"]) {
        [self discardReportsOfOtherPages];
        self.reportedPageURL = [self currentPageKey];
        NSString *URLString = [event[@"url"] isKindOfClass:[NSString class]] ? event[@"url"] : @"";
        if ([event[@"kind"] isEqual:@"hls"]) {
            self.reportedHLS = URLString;
        } else if ([event[@"kind"] isEqual:@"dash"]) {
            self.reportedDASH = URLString;
        }
        NSLog(@"[NativeVideoPlayer] Manifest %@ %@ top=%@", event[@"kind"], URLString, event[@"top"]);
    } else if ([type isEqualToString:@"youtubehd"]) {
        [self handleYouTubeHDEvent:event];
    } else if ([type isEqualToString:@"framevideo"] || [type isEqualToString:@"framefullscreen"]) {
        [self discardReportsOfOtherPages];
        self.reportedPageURL = [self currentPageKey];
        self.frameVideo = event;
        self.frameVideoDate = [NSDate date];
        if ([type isEqualToString:@"framefullscreen"]) {
            NSLog(@"[NativeVideoPlayer] Vollbildwunsch im Frame %@", event[@"frame"]);
            [self openFrameVideoWithTrigger:BrowserPageVideoTriggerFullscreen];
        }
    }
}

/// DASH-Manifest? An der Endung, an `format=mpd` oder am YouTube-Pfad `/manifest/dash/`.
- (BOOL)isDASHURL:(NSURL *)URL {
    NSString *path = URL.path.lowercaseString ?: @"";
    NSString *query = URL.query.lowercaseString ?: @"";
    return [path hasSuffix:@".mpd"] || [path containsString:@"/manifest/dash/"] || [query containsString:@"format=mpd"];
}

- (BOOL)isExtensionUnsupportedByAVPlayerForURL:(NSURL *)URL {
    if ([self isDASHURL:URL]) {
        return YES;
    }
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

- (BOOL)isYouTubePage:(NSString *)pageURLString {
    NSString *host = [NSURL URLWithString:pageURLString ?: @""].host.lowercaseString ?: @"";
    return [host isEqualToString:@"youtube.com"] || [host hasSuffix:@".youtube.com"] || [host isEqualToString:@"youtu.be"] ||
        [host hasSuffix:@"youtube-nocookie.com"];
}

/// Reihenfolge: direkte Adresse des Videos (`currentSrc`, `src`, `<source>`), dann das zuletzt gesehene
/// HLS-Manifest der Seite (MSE/blob:), dann ein per Rückkanal gemeldetes (auch aus Frames).
/// DASH, WebM & Co. kann AVPlayer nicht: dann `nil` und ein Grund für den Hinweis.
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
    BOOL blobSource = [probe[@"cs"] isKindOfClass:[NSString class]] && [[probe[@"cs"] lowercaseString] hasPrefix:@"blob:"];
    if ([probe[@"hls"] isKindOfClass:[NSString class]]) {
        [candidates addObject:probe[@"hls"]];
    }
    [self discardReportsOfOtherPages];
    if (self.reportedHLS.length > 0) {
        [candidates addObject:self.reportedHLS];
    }
    for (NSString *candidate in candidates) {
        if ([self isNativeCandidateURLString:candidate]) {
            return [NSURL URLWithString:candidate];
        }
    }
    NSString *dash = [probe[@"dash"] isKindOfClass:[NSString class]] ? probe[@"dash"] : @"";
    BOOL hasDASH = dash.length > 0 || self.reportedDASH.length > 0;
    BOOL hasUnsupportedFile = NO;
    for (NSString *candidate in candidates) {
        NSURL *URL = [NSURL URLWithString:candidate];
        if (URL != nil && [self isNativePlayableVideoURLString:candidate] && [self isExtensionUnsupportedByAVPlayerForURL:URL]) {
            if ([self isDASHURL:URL]) {
                hasDASH = YES;
            } else {
                hasUnsupportedFile = YES;
            }
        }
    }
    if (reason != NULL) {
        NSString *page = [probe[@"page"] isKindOfClass:[NSString class]] ? probe[@"page"] : @"";
        if ([self isYouTubePage:page]) {
            *reason = BLS(@"Dieses Video läuft nur in der Webseite.");
        } else if (hasDASH) {
            *reason = BLS(@"Dieses Video läuft nur in der Webseite.");
        } else if (hasUnsupportedFile) {
            *reason = BLS(@"Dieses Video läuft nur in der Webseite.");
        } else if (blobSource) {
            *reason = BLS(@"Dieses Video läuft nur in der Webseite.");
        } else {
            *reason = BLS(@"Dieses Video läuft nur in der Webseite.");
        }
    }
    NSLog(@"[NativeVideoPlayer] keine Adresse: cs=%@ hls=%@ dash=%@ reportedHLS=%@ reportedDASH=%@",
          probe[@"cs"], probe[@"hls"], dash, self.reportedHLS ?: @"", self.reportedDASH ?: @"");
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

/// User-Agent der Seite, Referer (Seitenadresse) und Origin, wie sie WebKit beim Laden schicken würde.
- (NSDictionary<NSString *, NSString *> *)requestHeadersForPageURL:(NSURL *)pageURL userAgent:(NSString *)userAgent {
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
    return headers;
}

- (void)openPageVideoWithID:(NSInteger)bid trigger:(BrowserPageVideoTrigger)trigger {
    BrowserWebView *webView = self.host.browserWebView;
    BOOL automatic = trigger == BrowserPageVideoTriggerAutomatic;
    if (webView == nil || self.handoverInProgress) {
        return;
    }
    if (self.activePlayer != nil) {
        // Läuft das vorige Video im Bild-in-Bild, beendet ein ausdrücklicher Wunsch es (Position geht zurück).
        if (automatic || !self.activePlayer.pictureInPictureActive) {
            return;
        }
        [self.activePlayer endSession];
        self.activePlayer = nil;
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
        if (strongSelf == nil) {
            return;
        }
        if (strongWebView == nil) {
            // Tab während der Abfrage geschlossen: Sperre lösen, sonst kehrt jede spätere Übergabe sofort zurück.
            strongSelf.handoverInProgress = NO;
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
            // Kein Video im Hauptframe: vielleicht in einem eingebetteten Player.
            if (!automatic && strongSelf.frameVideo != nil) {
                [strongSelf openFrameVideoWithTrigger:trigger];
                return;
            }
            if (!automatic) {
                [strongSelf presentNativePlayerNoticeWithMessage:BLS(@"Auf dieser Seite wurde kein Video gefunden.")];
            }
            return;
        }
        // YouTube mit MSE-Brücke: das Seitenvideo hat eine Ersatz-blob-Adresse, HLS kommt aus der Brücke.
        NSString *probePage = [probe[@"page"] isKindOfClass:[NSString class]] ? probe[@"page"] : @"";
        NSString *probeSource = [probe[@"cs"] isKindOfClass:[NSString class]] ? probe[@"cs"] : @"";
        // Auch ohne Quelle (Seitenplayer noch nicht angehängt, etwa nach dem Wechsel per yt-navigate): Die von YouTube
        // gemeldete HLS-Adresse (manifest.googlevideo.com/…/hls_variant) spielt AVPlayer nicht. Nur ein echtes MP4
        // (Brücke unscharf, 360p in der Seite) geht den gewohnten Weg.
        if ([BrowserYouTubeHDBridge isEnabled] && [strongSelf isYouTubePage:probePage] &&
            ([probeSource hasPrefix:@"blob:"] || probeSource.length == 0)) {
            strongSelf.handoverInProgress = NO;
            [strongSelf openYouTubeHDWithTrigger:trigger];
            return;
        }
        NSString *reason = nil;
        NSURL *videoURL = [strongSelf nativeURLFromProbe:probe unsupportedReason:&reason];
        if (videoURL == nil) {
            strongSelf.handoverInProgress = NO;
            if (!automatic && strongSelf.frameVideo != nil && [strongSelf frameVideoURL] != nil) {
                [strongSelf openFrameVideoWithTrigger:trigger];
                return;
            }
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
        // Am Ende angekommen: von vorn.
        double duration = [probe[@"dur"] doubleValue];
        if (duration > 0.0 && time >= duration - 1.0) {
            time = 0.0;
        }

        NSURL *pageURL = [NSURL URLWithString:[probe[@"page"] isKindOfClass:[NSString class]] ? probe[@"page"] : @""];
        NSString *userAgent = [probe[@"ua"] isKindOfClass:[NSString class]] ? probe[@"ua"] : @"";
        NSDictionary<NSString *, NSString *> *headers = [strongSelf requestHeadersForPageURL:pageURL userAgent:userAgent];
        NSArray<NSHTTPCookie *> *cookies = [strongSelf webViewCookiesForURL:videoURL];

        BrowserNativeVideoPlayerViewController *player = [strongSelf playerForURL:videoURL
                                                                          headers:headers
                                                                          cookies:cookies
                                                                            probe:probe
                                                                          webView:weakWebView];
        player.initialPlaybackTime = time;
        [strongSelf applyTextTracksOfProbe:probe toPlayer:player];
        __block BOOL failed = NO;
        player.dismissHandler = ^(NSTimeInterval playbackTime) {
            typeof(self) innerSelf = weakSelf;
            innerSelf.activePlayer = nil;
            innerSelf.handoverInProgress = NO;
            BrowserWebView *innerWebView = weakWebView;
            if (failed || innerWebView == nil) {
                return;
            }
            // Neue Position zurück in die Seite (nicht bei Livestreams), das Video bleibt pausiert.
            NSString *seek = isfinite(playbackTime) ? [NSString stringWithFormat:@"v.currentTime=%f;", playbackTime] : @"";
            NSString *script = [NSString stringWithFormat:@"(function(){ var v=window.__browserHandoverVideo; if (v) { try { %@ %@ v.pause(); } catch(e) {} } })();", kBrowserHandoverReleaseJS, seek];
            NSLog(@"[NativeVideoPlayer] Position zurück in die Seite: %.1f", playbackTime);
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
                    [innerSelf presentNativePlayerNoticeWithMessage:BLS(@"Dieses Video läuft nur in der Webseite.")];
                }];
            });
        };
        if (strongSelf.host.browserPresentedViewController != nil) {
            // Inzwischen liegt ein anderer Dialog oben: die Präsentation schlüge still fehl, dismissHandler käme nie
            // (activePlayer und handoverInProgress blieben hängen, das Seitenvideo angehalten).
            NSLog(@"[NativeVideoPlayer] Übergabe abgebrochen, Dialog %@ offen", NSStringFromClass(strongSelf.host.browserPresentedViewController.class));
            strongSelf.handoverInProgress = NO;
            [weakWebView evaluateJavaScriptAsync:kBrowserHandoverResumeScript];
            return;
        }
        strongSelf.activePlayer = player;
        [strongSelf.host browserPresentViewController:player];
    }];
}

/// Player mit Titel, Sitename, Beschreibung und Vorschaubild der Seite.
- (BrowserNativeVideoPlayerViewController *)playerForURL:(NSURL *)videoURL
                                                headers:(NSDictionary<NSString *, NSString *> *)headers
                                                cookies:(NSArray<NSHTTPCookie *> *)cookies
                                                  probe:(NSDictionary *)probe
                                                webView:(BrowserWebView *)webView {
    NSString *title = webView.reportedPageTitle;
    if (title.length == 0) {
        title = [probe[@"title"] isKindOfClass:[NSString class]] ? probe[@"title"] : nil;
    }
    NSURL *pageURL = [NSURL URLWithString:[probe[@"page"] isKindOfClass:[NSString class]] ? probe[@"page"] : @""] ?: [self pageURLOfWebView:webView];
    NSString *siteName = webView.reportedSiteName.length > 0 ? webView.reportedSiteName : pageURL.host;
    if (title.length == 0) {
        title = siteName;
    }
    NSString *mediaTitle = [webView.mediaInfo[@"title"] isKindOfClass:[NSString class]] ? webView.mediaInfo[@"title"] : nil;
    if (mediaTitle.length > 0) {
        title = mediaTitle;
    }

    BrowserNativeVideoPlayerViewController *player = [[BrowserNativeVideoPlayerViewController alloc] initWithURL:videoURL
                                                                                                          title:title
                                                                                                 requestHeaders:headers
                                                                                                        cookies:cookies];
    if (siteName.length > 0 && ![siteName isEqualToString:title]) {
        player.videoSubtitle = siteName;
    }
    NSString *description = [probe[@"desc"] isKindOfClass:[NSString class]] ? probe[@"desc"] : nil;
    player.videoDescription = description.length > 0 ? description : nil;
    NSString *art = [webView.mediaInfo[@"art"] isKindOfClass:[NSString class]] ? webView.mediaInfo[@"art"] : nil;
    if (art.length == 0) {
        art = [probe[@"art"] isKindOfClass:[NSString class]] ? probe[@"art"] : nil;
    }
    player.artworkURL = art.length > 0 ? [NSURL URLWithString:art] : nil;
    return player;
}

- (void)applyTextTracksOfProbe:(NSDictionary *)probe toPlayer:(BrowserNativeVideoPlayerViewController *)player {
    NSMutableArray<BrowserNativeVideoTextTrack *> *tracks = [NSMutableArray array];
    NSArray *entries = [probe[@"tracks"] isKindOfClass:[NSArray class]] ? probe[@"tracks"] : @[];
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"src"] isKindOfClass:[NSString class]]) {
            continue;
        }
        NSURL *URL = [NSURL URLWithString:entry[@"src"]];
        if (URL == nil || !([URL.scheme isEqualToString:@"https"] || [URL.scheme isEqualToString:@"http"])) {
            continue;
        }
        BrowserNativeVideoTextTrack *track = [BrowserNativeVideoTextTrack new];
        track.URL = URL;
        track.language = [entry[@"lang"] isKindOfClass:[NSString class]] ? entry[@"lang"] : @"";
        track.label = [entry[@"label"] isKindOfClass:[NSString class]] ? entry[@"label"] : @"";
        track.preferred = [entry[@"on"] boolValue];
        [tracks addObject:track];
    }
    player.pageTextTracks = tracks;
    NSString *showing = [probe[@"showing"] isKindOfClass:[NSString class]] ? probe[@"showing"] : @"";
    player.preferredSubtitleLanguage = showing.length > 0 ? showing : nil;
}

#pragma mark - YouTube in HD (MSE-Brücke)

- (BrowserYouTubeHDBridge *)youTubeHDBridge {
    if (_youTubeHDBridge == nil) {
        _youTubeHDBridge = [BrowserYouTubeHDBridge new];
    }
    return _youTubeHDBridge;
}

/// Meldungen von `youtube_hd_bridge.js`: attach (Seitenplayer hängt die Ersatz-MediaSource an), capture (erste
/// Medienanfrage eines Player-Response), play (Seite will abspielen).
- (void)handleYouTubeHDEvent:(NSDictionary *)event {
    NSString *name = [event[@"event"] isKindOfClass:[NSString class]] ? event[@"event"] : @"";
    NSString *videoID = [event[@"videoId"] isKindOfClass:[NSString class]] ? event[@"videoId"] : @"";
    if ([name isEqualToString:@"capture"]) {
        NSLog(@"[YouTubeHD] Seite ruft ab: itag=%@ %@ range=%@ ump=%@ pot=%@ nach %@ ms (Video %@)", event[@"itag"], event[@"method"],
              event[@"range"], event[@"ump"], event[@"pot"], event[@"ms"], videoID);
    } else if ([name isEqualToString:@"reload"]) {
        // Videowechsel per yt-navigate: Die Seite lädt neu, damit das neue Video wieder über die Brücke läuft.
        NSLog(@"[YouTubeHD] Videowechsel %@ → %@, Seite lädt neu", event[@"from"], videoID);
        return;
    } else if ([name isEqualToString:@"disarm"]) {
        // Player-Response ohne Formatadressen (nur SABR): Seite spielt wie ohne Brücke das MP4 mit 360p.
        NSLog(@"[YouTubeHD] Brücke unscharf (%@), Seite nimmt 360p (Video %@)", event[@"reason"], videoID);
        return;
    } else if ([name isEqualToString:@"attach"]) {
        NSLog(@"[YouTubeHD] Ersatz-MediaSource am Video (Video %@)", videoID);
        if (videoID.length > 0) {
            [self armYouTubeHDCaptureWatchdog];
        }
        return;
    }
    if (videoID.length == 0 || !([name isEqualToString:@"capture"] || [name isEqualToString:@"play"])) {
        return;
    }
    // Unabhängig von „Videos automatisch im Player öffnen“: Mit der Brücke kann die Seite selbst nichts abspielen,
    // der native Player ist der Player. Wer YouTube in der Seite (360p) will, schaltet YouTubeHDBridge aus.
    if (self.youTubeHDClosedDate != nil && -[self.youTubeHDClosedDate timeIntervalSinceNow] < 2.0) {
        NSLog(@"[YouTubeHD] eben geschlossen, nicht wieder öffnen");
        return;
    }
    [self openYouTubeHDWithTrigger:BrowserPageVideoTriggerAutomatic];
}

/// Ruft der Seitenplayer nach dem Anhängen 15 s lang nichts ab, ist die Brücke kaputt (YouTube geändert): 360p.
- (void)armYouTubeHDCaptureWatchdog {
    NSUInteger generation = ++self.youTubeHDAttachGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        BrowserWebView *webView = strongSelf.host.browserWebView;
        if (strongSelf == nil || webView == nil || generation != strongSelf.youTubeHDAttachGeneration) {
            return;
        }
        NSString *script = @"(function(){ var s=window.__browserYouTubeHD; if (!s) { return -1; } var v=document.querySelector('video'); return (v && v.__bythd) ? Object.keys(s.captures).length : -1; })()";
        [webView evaluateJavaScriptAsync:script completion:^(id result) {
            if ([result respondsToSelector:@selector(integerValue)] && [result integerValue] == 0) {
                NSLog(@"[YouTubeHD] Wächter: Seitenplayer hat nach 15 s nichts abgerufen");
                [weakSelf fallBackFromYouTubeHDWithReason:@"keine Medienanfrage"];
            }
        }];
    });
}

/// Brücke für diese Seite abschalten und neu laden: YouTube liefert dann wieder das MP4 mit 360p (itag 18).
- (void)fallBackFromYouTubeHDWithReason:(NSString *)reason {
    [self fallBackFromYouTubeHDWithReason:reason resumeTime:0.0];
}

/// `resumeTime` > 1: Die Seite lädt mit `t=<s>` neu und spielt ab dort (Abbruch mitten in der Wiedergabe).
- (void)fallBackFromYouTubeHDWithReason:(NSString *)reason resumeTime:(NSTimeInterval)resumeTime {
    BrowserWebView *webView = self.host.browserWebView;
    NSString *page = [self currentPageKey];
    if (webView == nil || [self.youTubeHDFallbackPage isEqualToString:page]) {
        NSLog(@"[YouTubeHD] kein erneuter Rückfall für %@ (%@)", page, reason);
        return;
    }
    self.youTubeHDFallbackPage = page;
    NSLog(@"[YouTubeHD] Rückfall auf 360p (%@): Seite ohne Brücke neu laden", reason);
    // Merkt sich die Video-ID: Das nächste Video (neu geladen) bekommt die Brücke wieder.
    NSString *reload = @"location.reload()";
    if (resumeTime > 1.0 && isfinite(resumeTime)) {
        reload = [NSString stringWithFormat:@"(function(){ var u = new URL(location.href); u.searchParams.set('t', '%lds'); location.replace(u.href); })()", (long)resumeTime];
        NSLog(@"[YouTubeHD] Seite spielt ab %.0f s weiter", resumeTime);
    }
    NSString *script = [@"try { var m = /[?&]v=([\\w-]{11})/.exec(location.search) || /\\/(?:shorts|live|embed)\\/([\\w-]{11})/.exec(location.pathname); sessionStorage.setItem('__browserYouTubeHDOff', m ? m[1] : '1'); } catch(e) {} " stringByAppendingString:reload];
    [webView evaluateJavaScriptAsync:script];
}

- (void)openYouTubeHDWithTrigger:(BrowserPageVideoTrigger)trigger {
    BrowserWebView *webView = self.host.browserWebView;
    BOOL automatic = trigger == BrowserPageVideoTriggerAutomatic;
    UIViewController *presented = self.host.browserPresentedViewController;
    if (webView == nil || self.handoverInProgress || self.activePlayer != nil ||
        (presented != nil && (automatic || [presented isKindOfClass:[BrowserNativeVideoPlayerViewController class]]))) {
        NSLog(@"[YouTubeHD] Öffnen übergangen (läuft=%d Player=%d Dialog=%@)", self.handoverInProgress, self.activePlayer != nil,
              presented != nil ? NSStringFromClass(presented.class) : @"-");
        return;
    }
    NSLog(@"[YouTubeHD] öffne (%@)", automatic ? @"automatisch" : @"Menü");
    self.handoverInProgress = YES;
    CFTimeInterval started = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    // Automatisch: bis 20 s auf die Anfrage zum Hauptvideo warten (davor kann Werbung laufen).
    [self.youTubeHDBridge preparePresentationForWebView:webView waitSeconds:automatic ? 20.0 : 6.0
                                             completion:^(BrowserYouTubeHDPresentation *presentation, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        BrowserWebView *strongWebView = weakWebView;
        if (strongSelf == nil) {
            return;
        }
        if (presentation == nil || strongWebView == nil || strongWebView != strongSelf.host.browserWebView) {
            strongSelf.handoverInProgress = NO;
            if (presentation == nil) {
                NSLog(@"[YouTubeHD] nicht bereit: %@", error.localizedDescription);
                if (error.code == BrowserYouTubeHDErrorIndex || error.code == BrowserYouTubeHDErrorNoFormat) {
                    [strongSelf fallBackFromYouTubeHDWithReason:error.localizedDescription];
                } else if (!automatic) {
                    [strongSelf presentNativePlayerNoticeWithMessage:BLS(@"Das YouTube-Video ist noch nicht bereit.")];
                }
            }
            return;
        }
        NSLog(@"[YouTubeHD] Playlist nach %.2f s", CACurrentMediaTime() - started);
        [strongSelf presentYouTubeHD:presentation webView:strongWebView];
    }];
}

- (void)presentYouTubeHD:(BrowserYouTubeHDPresentation *)presentation webView:(BrowserWebView *)webView {
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    [webView evaluateJavaScriptAsync:@"window.__browserYouTubeHD ? window.__browserYouTubeHD.pausePage() : -1" completion:^(id result) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        double time = [result respondsToSelector:@selector(doubleValue)] ? [result doubleValue] : -1.0;
        if (time < 0.0 || !isfinite(time)) {
            time = presentation.pageTime;
        }
        if (time < 1.0 || (presentation.duration > 0.0 && time >= presentation.duration - 2.0)) {
            time = 0.0;
        }
        if (strongSelf.host.browserPresentedViewController != nil || strongSelf.activePlayer != nil) {
            NSLog(@"[YouTubeHD] Übergabe abgebrochen, Dialog offen");
            strongSelf.handoverInProgress = NO;
            return;
        }
        BrowserNativeVideoPlayerViewController *player = [[BrowserNativeVideoPlayerViewController alloc] initWithURL:presentation.masterURL
                                                                                                              title:presentation.title
                                                                                                     requestHeaders:presentation.requestHeaders
                                                                                                            cookies:@[]];
        player.generatedPlaylists = presentation.playlists;
        player.videoSubtitle = presentation.author.length > 0 ? presentation.author : @"YouTube";
        player.artworkURL = presentation.artworkURL;
        player.initialPlaybackTime = time;
        player.reportsPlaybackFailures = YES;
        __block BOOL failed = NO;
        player.dismissHandler = ^(NSTimeInterval playbackTime) {
            typeof(self) innerSelf = weakSelf;
            innerSelf.activePlayer = nil;
            innerSelf.handoverInProgress = NO;
            innerSelf.youTubeHDClosedDate = [NSDate date];
            if (failed || !isfinite(playbackTime)) {
                return;
            }
            NSLog(@"[NativeVideoPlayer] Position zurück in die Seite: %.1f", playbackTime);
            [weakWebView evaluateJavaScriptAsync:[NSString stringWithFormat:@"window.__browserYouTubeHD && window.__browserYouTubeHD.seekPage(%f)", playbackTime]];
            [weakWebView refreshClickTargets];
        };
        player.failureHandler = ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) innerSelf = weakSelf;
                failed = YES;
                NSLog(@"[YouTubeHD] Wiedergabe fehlgeschlagen: %@", error);
                BrowserNativeVideoPlayerViewController *failedPlayer = innerSelf.activePlayer;
                NSTimeInterval failedAt = CMTimeGetSeconds(failedPlayer.player.currentTime);
                innerSelf.activePlayer = nil;
                innerSelf.handoverInProgress = NO;
                innerSelf.youTubeHDClosedDate = [NSDate date];
                [failedPlayer dismissViewControllerAnimated:YES completion:^{
                    [innerSelf fallBackFromYouTubeHDWithReason:error.localizedDescription ?: @"AVPlayer" resumeTime:failedAt];
                }];
            });
        };
        NSLog(@"[YouTubeHD] nativer Player: %@ ab %.1f s", presentation.masterURL.absoluteString, time);
        strongSelf.activePlayer = player;
        [strongSelf.host browserPresentViewController:player];
    }];
}

#pragma mark - Videos in eingebetteten Frames

/// Adresse des zuletzt gemeldeten Frame-Videos: direkte Datei, sonst HLS des Frames.
- (NSURL *)frameVideoURL {
    for (NSString *key in @[@"src", @"hls"]) {
        NSString *candidate = [self.frameVideo[key] isKindOfClass:[NSString class]] ? self.frameVideo[key] : @"";
        if ([self isNativeCandidateURLString:candidate]) {
            return [NSURL URLWithString:candidate];
        }
    }
    if (self.reportedHLS.length > 0 && [self isNativeCandidateURLString:self.reportedHLS]) {
        return [NSURL URLWithString:self.reportedHLS];
    }
    return nil;
}

/// Frames erreicht `evaluateJavaScript` nicht: Pausieren über WebKit (alle Medien), Position aus der letzten
/// Meldung plus verstrichene Zeit. Die neue Position geht nicht zurück in den Frame.
- (void)openFrameVideoWithTrigger:(BrowserPageVideoTrigger)trigger {
    BrowserWebView *webView = self.host.browserWebView;
    if (webView == nil || self.handoverInProgress || self.activePlayer != nil || self.host.browserPresentedViewController != nil) {
        return;
    }
    NSURL *videoURL = [self frameVideoURL];
    if (videoURL == nil) {
        NSString *dash = [self.frameVideo[@"dash"] isKindOfClass:[NSString class]] ? self.frameVideo[@"dash"] : @"";
        NSString *frame = [self.frameVideo[@"frame"] isKindOfClass:[NSString class]] ? self.frameVideo[@"frame"] : @"";
        NSString *message = [self isYouTubePage:frame]
            ? BLS(@"Dieses Video läuft nur in der Webseite.")
            : (dash.length > 0
               ? BLS(@"Dieses Video läuft nur in der Webseite.")
               : BLS(@"Dieses Video läuft nur in der Webseite."));
        [self presentNativePlayerNoticeWithMessage:message];
        return;
    }
    double time = [self.frameVideo[@"t"] doubleValue];
    if (![self.frameVideo[@"paused"] boolValue] && self.frameVideoDate != nil) {
        time += -[self.frameVideoDate timeIntervalSinceNow];
    }
    [webView pauseAllMediaPlayback];
    NSURL *pageURL = [self pageURLOfWebView:webView];
    NSString *frameString = [self.frameVideo[@"frame"] isKindOfClass:[NSString class]] ? self.frameVideo[@"frame"] : @"";
    NSURL *frameURL = [NSURL URLWithString:frameString] ?: pageURL;
    NSDictionary *probe = @{@"page": pageURL.absoluteString ?: @"", @"title": webView.reportedPageTitle ?: @""};
    BrowserNativeVideoPlayerViewController *player = [self playerForURL:videoURL
                                                                headers:[self requestHeadersForPageURL:frameURL userAgent:@""]
                                                                cookies:[self webViewCookiesForURL:videoURL]
                                                                  probe:probe
                                                                webView:webView];
    player.initialPlaybackTime = time;
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    __block BOOL failed = NO;
    player.dismissHandler = ^(NSTimeInterval playbackTime) {
        weakSelf.activePlayer = nil;
        weakSelf.handoverInProgress = NO;
        // Position über die Player-Brücke zurück in den Frame (bleibt pausiert, wie beim Hauptframe).
        if (!failed && isfinite(playbackTime) && frameString.length > 0) {
            [weakWebView sendVideoCommand:[NSString stringWithFormat:@"seekto:%.2f", playbackTime] toFrameURL:frameString];
        }
        NSLog(@"[NativeVideoPlayer] Frame-Video geschlossen bei %.1f (Position zurück in den Frame, bleibt pausiert)", playbackTime);
    };
    player.failureHandler = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) innerSelf = weakSelf;
            failed = YES;
            NSLog(@"[NativeVideoPlayer] Frame-Video fehlgeschlagen, spielt im Frame weiter: %@", error);
            // pauseAllMediaPlayback hat den Frame angehalten: dort weiterspielen statt stehen zu bleiben.
            if (frameString.length > 0) {
                [weakWebView sendVideoCommand:@"play" toFrameURL:frameString];
            }
            BrowserNativeVideoPlayerViewController *failedPlayer = innerSelf.activePlayer;
            innerSelf.activePlayer = nil;
            innerSelf.handoverInProgress = NO;
            [failedPlayer dismissViewControllerAnimated:YES completion:^{
                [innerSelf presentNativePlayerNoticeWithMessage:BLS(@"Dieses Video läuft nur in der Webseite.")];
            }];
        });
    };
    NSLog(@"[NativeVideoPlayer] Frame-Video %@ t=%.1f trigger=%ld", videoURL.absoluteString, time, (long)trigger);
    self.activePlayer = player;
    [self.host browserPresentViewController:player];
}

- (void)presentNativePlayerNoticeWithMessage:(NSString *)message {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BLS(@"Im Player öffnen")
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"OK") style:UIAlertActionStyleCancel handler:nil]];
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
        sourceSummary = BLS(@"Keine");
    } else {
        sourceSummary = BLS(@"Kein Video unter dem Zeiger");
    }
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BLS(@"Nativer Player nicht verfügbar")
                                                                             message:[NSString stringWithFormat:BLS(@"Dieses Video läuft nur in der Webseite.\n\nQuellen:\n%@"), sourceSummary]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"OK") style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPresentViewController:alertController];
}

- (void)presentYouTubeExtractionError:(NSError *)error fallbackVideoInfo:(NSDictionary *)videoInfo {
    NSString *message = error.localizedDescription ?: BLS(@"Das Video konnte nicht geladen werden.");
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BLS(@"YouTube-Video nicht lesbar")
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    NSString *fallbackURLString = [videoInfo[@"src"] isKindOfClass:[NSString class]] ? videoInfo[@"src"] : @"";
    if ([self isNativePlayableVideoURLString:fallbackURLString]) {
        [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"Aktuelle Adresse abspielen")
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURL *fallbackURL = [NSURL URLWithString:fallbackURLString];
            NSString *title = [videoInfo[@"title"] isKindOfClass:[NSString class]] ? videoInfo[@"title"] : weakSelf.host.browserCurrentPageTitle;
            [weakSelf presentNativeVideoPlayerForURL:fallbackURL title:title];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"OK") style:UIAlertActionStyleCancel handler:nil]];
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
