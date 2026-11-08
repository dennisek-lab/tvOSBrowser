#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserShape.h"
#import "BrowserNativeVideoAssetLoader.h"
#import "BrowserNowPlayingController.h"

#import <AVFoundation/AVFoundation.h>

NSNotificationName const BrowserNativePlayerDidCreatePlayerItemNotification = @"BrowserNativePlayerDidCreatePlayerItemNotification";
NSNotificationName const BrowserNativePlayerWillEndSessionNotification = @"BrowserNativePlayerWillEndSessionNotification";

static NSString * const kBrowserNativeVideoPlayerLogPrefix = @"[NativeVideoPlayer]";
static NSString * const kBrowserNativePlayerInputLogPrefix = @"[InputTrace][NativePlayer]";

static NSString *BrowserNativePlayerPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserNativePlayerPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

@implementation BrowserNativeVideoTextTrack
@end

/// Ein Untertitel aus einer WebVTT-Datei.
@interface BrowserNativeVideoCue : NSObject
@property (nonatomic) NSTimeInterval start;
@property (nonatomic) NSTimeInterval end;
@property (nonatomic, copy) NSString *text;
@end

@implementation BrowserNativeVideoCue
@end

@interface BrowserNativeVideoPlayerViewController () <AVPlayerViewControllerDelegate>

@property (nonatomic, strong, readwrite) NSURL *videoURL;
@property (nonatomic, copy) NSString *videoTitle;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy, readwrite) NSArray<NSHTTPCookie *> *requestCookies;
@property (nonatomic, readwrite, getter=isStreamingPlaylist) BOOL streamingPlaylist;
@property (nonatomic, strong, readwrite) UIView *subtitleOverlayView;
@property (nonatomic, strong) BrowserNativeVideoAssetLoader *assetLoader;
@property (nonatomic, strong, nullable) UIImage *artworkImage;

@property (nonatomic) BOOL live;
@property (nonatomic) BOOL didApplyInitialTime;
@property (nonatomic) BOOL playWhenReady;
@property (nonatomic) BOOL initialSeekInFlight;
@property (nonatomic) BOOL didEndSession;
@property (nonatomic) BOOL didReportFailure;
/// Hat die Wiedergabe je begonnen (timeControlStatus „playing“)? Sonst greift der Startwächter.
@property (nonatomic) BOOL didStartPlayback;
@property (nonatomic) BOOL didSelectStreamSubtitles;

@property (nonatomic, readwrite, getter=isPictureInPictureActive) BOOL pictureInPictureActive;
@property (nonatomic) BOOL pictureInPictureStarting;
@property (nonatomic) BOOL restoringFromPictureInPicture;
@property (nonatomic, weak) UIViewController *restoreHost;

@property (nonatomic, copy) NSArray<BrowserNativeVideoCue *> *sidecarCues;
@property (nonatomic, nullable) BrowserNativeVideoTextTrack *activeSidecarTrack;
@property (nonatomic, strong) UILabel *sidecarLabel;
@property (nonatomic, strong, nullable) id sidecarTimeObserver;
/// Beobachtete Objekte (KVO), eigens gehalten, damit das Abmelden auch ohne `self.player` klappt.
@property (nonatomic, strong, nullable) AVPlayerItem *observedItem;
@property (nonatomic, strong, nullable) AVPlayer *observedPlayer;

@end

@implementation BrowserNativeVideoPlayerViewController

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1,2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    NSLog(@"%@ %@", kBrowserNativeVideoPlayerLogPrefix, message);
}

#pragma mark - Lebenszyklus und Aufbau

- (instancetype)initWithURL:(NSURL *)URL title:(NSString *)title {
    return [self initWithURL:URL title:title requestHeaders:nil cookies:nil];
}

- (instancetype)initWithURL:(NSURL *)URL
                      title:(NSString *)title
             requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                    cookies:(NSArray<NSHTTPCookie *> *)cookies {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _videoURL = URL;
        _videoTitle = [title copy] ?: @"";
        _requestHeaders = [requestHeaders copy] ?: @{};
        _requestCookies = [cookies copy] ?: @[];
        _pageTextTracks = @[];
        NSString *path = URL.path.lowercaseString ?: @"";
        _streamingPlaylist = [path hasSuffix:@".m3u8"] || [URL.absoluteString.lowercaseString containsString:@".m3u8"];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (AVPlayerItem *)playerItem {
    return self.player.currentItem;
}

/// Asset mit Headern und Cookies der Seite. HLS-Playlists laufen über den eigenen Loader (Header je Anfrage,
/// Cookies je Host), Segmente und Dateien wie MP4 lädt AVFoundation selbst mit denselben Angaben.
- (AVPlayerItem *)makePlayerItem {
    NSMutableDictionary *assetOptions = [NSMutableDictionary dictionary];
    if (self.requestHeaders.count > 0) {
        assetOptions[@"AVURLAssetHTTPHeaderFieldsKey"] = self.requestHeaders;
        NSString *userAgent = self.requestHeaders[@"User-Agent"];
        if (userAgent.length > 0) {
            assetOptions[AVURLAssetHTTPUserAgentKey] = userAgent;
        }
    }
    if (self.requestCookies.count > 0) {
        assetOptions[AVURLAssetHTTPCookiesKey] = self.requestCookies;
    }

    AVURLAsset *asset = nil;
    if (self.streamingPlaylist && (self.requestHeaders.count > 0 || self.requestCookies.count > 0)) {
        self.assetLoader = [[BrowserNativeVideoAssetLoader alloc] initWithRequestHeaders:self.requestHeaders cookies:self.requestCookies];
        NSURL *assetURL = [self.assetLoader assetURLForPlaybackURL:self.videoURL];
        asset = [AVURLAsset URLAssetWithURL:assetURL options:assetOptions];
        [self.assetLoader attachToAsset:asset];
    } else {
        asset = [AVURLAsset URLAssetWithURL:self.videoURL options:assetOptions];
    }
    [self log:@"asset hls=%d loader=%d headers=%@ cookies=%lu", self.streamingPlaylist, self.assetLoader != nil,
     [self.requestHeaders.allKeys componentsJoinedByString:@","], (unsigned long)self.requestCookies.count];
    return [AVPlayerItem playerItemWithAsset:asset];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = UIColor.blackColor;
    self.showsPlaybackControls = YES;
    self.delegate = self;
    // Bild-in-Bild: Audio-Session „playback“ (activateAudioSession) und Hintergrundmodus „audio“ (Info.plist).
    self.allowsPictureInPicturePlayback = YES;

    AVPlayerItem *playerItem = [self makePlayerItem];
    [BrowserNowPlayingController activateAudioSession];
    self.player = [AVPlayer playerWithPlayerItem:playerItem];
    [self updateExternalMetadata];
    [self loadArtworkIfNeeded];
    [self installSubtitleOverlay];
    [self log:@"created player url=%@ start=%.1f", self.videoURL.absoluteString ?: @"", self.initialPlaybackTime];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemFailedToPlayToEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:playerItem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlayerItemNewErrorLogEntry:)
                                                 name:AVPlayerItemNewErrorLogEntryNotification
                                               object:playerItem];

    self.observedItem = playerItem;
    self.observedPlayer = self.player;
    [playerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:NULL];
    [self.player addObserver:self
                  forKeyPath:@"timeControlStatus"
                     options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                     context:NULL];

    [NSNotificationCenter.defaultCenter postNotificationName:BrowserNativePlayerDidCreatePlayerItemNotification object:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSLog(@"%@ viewDidAppear", kBrowserNativePlayerInputLogPrefix);
    self.restoreHost = self.presentingViewController;
    [NSNotificationCenter.defaultCenter postNotificationName:BrowserNativePlayerDidAppearNotification object:self];
    if (self.restoringFromPictureInPicture) {
        [self log:@"viewDidAppear nach Bild-in-Bild"];
        return;
    }
    if ([self needsInitialSeek]) {
        // Erst an die Position der Seite springen, dann spielen (sonst kurz ab 0).
        [self log:@"viewDidAppear, warte auf Startposition %.1f", self.initialPlaybackTime];
        self.playWhenReady = YES;
        [self armStartWatchdog];
        return;
    }
    [self log:@"viewDidAppear play"];
    [self.player play];
    [self armStartWatchdog];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    NSLog(@"%@ viewWillDisappear", kBrowserNativePlayerInputLogPrefix);
    if (self.pictureInPictureStarting || self.pictureInPictureActive) {
        // Bild-in-Bild übernimmt: weiterspielen, Sitzung endet erst mit dem Fenster.
        [self log:@"viewWillDisappear, Bild-in-Bild läuft weiter"];
        return;
    }
    if (self.isBeingDismissed || self.presentingViewController == nil) {
        [self endSession];
    }
}

- (void)detachObservers {
    if (self.observedItem != nil) {
        @try {
            [self.observedItem removeObserver:self forKeyPath:@"status"];
        } @catch (__unused NSException *exception) {}
        self.observedItem = nil;
    }
    if (self.observedPlayer != nil) {
        @try {
            [self.observedPlayer removeObserver:self forKeyPath:@"timeControlStatus"];
        } @catch (__unused NSException *exception) {}
        if (self.sidecarTimeObserver != nil) {
            [self.observedPlayer removeTimeObserver:self.sidecarTimeObserver];
            self.sidecarTimeObserver = nil;
        }
        self.observedPlayer = nil;
    }
}

- (void)dealloc {
    [self detachObservers];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Startwächter

/// Startet die Wiedergabe nicht (Server verweigert AVPlayer die Segmente, Stream hängt beim Puffern, Status bleibt
/// „unknown“), meldet AVKit oft keinen Fehler, und der Nutzer säße vor einem schwarzen Bild, während das Video der
/// Seite angehalten wartet. Nach `kBrowserNativePlayerStartTimeout` ohne Wiedergabe gilt die Übergabe als
/// gescheitert: `failureHandler` schließt den Player und lässt das Video in der Seite weiterlaufen.
static const NSTimeInterval kBrowserNativePlayerStartTimeout = 15.0;

- (void)armStartWatchdog {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrowserNativePlayerStartTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.didStartPlayback || strongSelf.didEndSession || strongSelf.didReportFailure ||
            strongSelf.pictureInPictureActive) {
            return;
        }
        AVPlayerItem *item = strongSelf.player.currentItem;
        [strongSelf log:@"Startwächter: nach %.0f s keine Wiedergabe (status=%ld, wartet: %@), zurück zur Seite",
         kBrowserNativePlayerStartTimeout, (long)item.status, strongSelf.player.reasonForWaitingToPlay ?: @"-"];
        strongSelf.didReportFailure = YES;
        if (strongSelf.failureHandler != nil) {
            strongSelf.failureHandler([NSError errorWithDomain:@"BrowserNativeVideoPlayer" code:-1
                                                      userInfo:@{NSLocalizedDescriptionKey: @"Wiedergabe startet nicht"}]);
        }
    });
}

#pragma mark - Startposition

- (BOOL)needsInitialSeek {
    return (!self.didApplyInitialTime && self.initialPlaybackTime > 1.0) || self.initialSeekInFlight;
}

- (void)playerItemBecameReady:(AVPlayerItem *)item {
    self.live = CMTIME_IS_INDEFINITE(item.duration);
    [self log:@"item status=ready duration=%f live=%d likelyToKeepUp=%d",
     CMTimeGetSeconds(item.duration), self.live, item.isPlaybackLikelyToKeepUp];
    [self selectStreamSubtitlesIfNeeded];

    if (self.didApplyInitialTime || self.initialPlaybackTime <= 1.0) {
        return;
    }
    self.didApplyInitialTime = YES;
    NSTimeInterval duration = CMTimeGetSeconds(item.duration);
    BOOL seekable = !self.live && (!isfinite(duration) || self.initialPlaybackTime < duration - 1.0);
    if (!seekable) {
        // Livestream (eigene Zeitachse) oder Position hinter dem Ende: von vorn bzw. live.
        [self log:@"Startposition %.1f übersprungen (live=%d duration=%.1f)", self.initialPlaybackTime, self.live, duration];
        [self playIfWaiting];
        return;
    }
    CMTime start = CMTimeMakeWithSeconds(self.initialPlaybackTime, NSEC_PER_SEC);
    self.initialSeekInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:start toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.initialSeekInFlight = NO;
            [weakSelf log:@"Startposition %.1f gesetzt finished=%d", weakSelf.initialPlaybackTime, finished];
            [weakSelf playIfWaiting];
        });
    }];
}

- (void)playIfWaiting {
    if (self.playWhenReady && !self.didEndSession) {
        self.playWhenReady = NO;
        [self.player play];
    }
}

#pragma mark - Metadaten (Infoleiste, Now Playing)

- (void)updateExternalMetadata {
    AVPlayerItem *item = self.player.currentItem;
    if (item == nil) {
        return;
    }
    NSMutableArray<AVMetadataItem *> *items = [NSMutableArray array];
    void (^add)(AVMetadataIdentifier, id) = ^(AVMetadataIdentifier identifier, id value) {
        if (value == nil || ([value isKindOfClass:NSString.class] && [value length] == 0)) {
            return;
        }
        AVMutableMetadataItem *metadataItem = [AVMutableMetadataItem new];
        metadataItem.identifier = identifier;
        metadataItem.value = value;
        metadataItem.extendedLanguageTag = @"und";
        if ([value isKindOfClass:NSData.class]) {
            metadataItem.dataType = (__bridge NSString *)kCMMetadataBaseDataType_JPEG;
        }
        [items addObject:metadataItem];
    };
    add(AVMetadataCommonIdentifierTitle, self.videoTitle);
    add(AVMetadataIdentifieriTunesMetadataTrackSubTitle, self.videoSubtitle);
    add(AVMetadataCommonIdentifierDescription, self.videoDescription);
    if (self.artworkImage != nil) {
        add(AVMetadataCommonIdentifierArtwork, UIImageJPEGRepresentation(self.artworkImage, 0.85));
    }
    item.externalMetadata = items;
}

- (NSMutableURLRequest *)requestWithPageHeadersForURL:(NSURL *)URL {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:15.0];
    for (NSString *key in @[@"User-Agent", @"Referer"]) {
        if (self.requestHeaders[key].length > 0) {
            [request setValue:self.requestHeaders[key] forHTTPHeaderField:key];
        }
    }
    NSString *host = URL.host.lowercaseString ?: @"";
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    for (NSHTTPCookie *cookie in self.requestCookies) {
        NSString *domain = [cookie.domain.lowercaseString hasPrefix:@"."] ? [cookie.domain.lowercaseString substringFromIndex:1] : cookie.domain.lowercaseString;
        if (domain.length > 0 && ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]])) {
            [cookies addObject:cookie];
        }
    }
    NSString *cookieHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"];
    if (cookieHeader.length > 0) {
        [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
    }
    return request;
}

- (void)loadArtworkIfNeeded {
    NSURL *URL = self.artworkURL;
    if (URL == nil || !([URL.scheme isEqualToString:@"https"] || [URL.scheme isEqualToString:@"http"])) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:[self requestWithPageHeadersForURL:URL]
                                   completionHandler:^(NSData *data, __unused NSURLResponse *response, NSError *error) {
        UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (image == nil) {
                [weakSelf log:@"Vorschaubild fehlt %@ %@", URL.absoluteString, error.localizedDescription ?: @""];
                return;
            }
            weakSelf.artworkImage = image;
            [weakSelf updateExternalMetadata];
            [weakSelf log:@"Vorschaubild %.0fx%.0f", image.size.width, image.size.height];
        });
    }] resume];
}

#pragma mark - Bild-in-Bild und Sitzungsende

- (void)endSession {
    if (self.didEndSession) {
        return;
    }
    self.didEndSession = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:BrowserNativePlayerWillEndSessionNotification object:self];
    [NSNotificationCenter.defaultCenter postNotificationName:BrowserNativePlayerWillDisappearNotification object:self];
    NSTimeInterval time = CMTimeGetSeconds(self.player.currentTime);
    if (self.live) {
        time = NAN;
    } else if (!isfinite(time) || time < 0.0) {
        time = 0.0;
    }
    [self log:@"Sitzung endet t=%.1f pip=%d", time, self.pictureInPictureActive];
    if (self.dismissHandler != nil) {
        self.dismissHandler(time);
    }
    [self.player pause];
    if (self.pictureInPictureActive) {
        // Ohne Player schließt AVKit das Bild-in-Bild-Fenster.
        [self detachObservers];
        self.player = nil;
    }
}

- (BOOL)playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart:(AVPlayerViewController *)playerViewController {
    return YES;
}

- (void)playerViewControllerWillStartPictureInPicture:(AVPlayerViewController *)playerViewController {
    [self log:@"Bild-in-Bild startet"];
    self.pictureInPictureStarting = YES;
}

- (void)playerViewControllerDidStartPictureInPicture:(AVPlayerViewController *)playerViewController {
    [self log:@"Bild-in-Bild aktiv"];
    self.pictureInPictureStarting = NO;
    self.pictureInPictureActive = YES;
}

- (void)playerViewController:(AVPlayerViewController *)playerViewController failedToStartPictureInPictureWithError:(NSError *)error {
    [self log:@"Bild-in-Bild fehlgeschlagen %@", error];
    self.pictureInPictureStarting = NO;
    self.pictureInPictureActive = NO;
    if (self.presentingViewController == nil) {
        // AVKit hat den Player zum Start schon geschlossen (viewWillDisappear sah „startet“): Sitzung sonst nie beendet.
        [self endSession];
    }
}

- (void)playerViewController:(AVPlayerViewController *)playerViewController
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    UIViewController *host = self.restoreHost;
    if (host == nil || self.didEndSession) {
        completionHandler(NO);
        return;
    }
    while (host.presentedViewController != nil && host.presentedViewController != self) {
        host = host.presentedViewController;
    }
    [self log:@"Bild-in-Bild zurück ins Vollbild"];
    self.restoringFromPictureInPicture = YES;
    if (self.presentingViewController != nil) {
        completionHandler(YES);
        return;
    }
    [host presentViewController:self animated:YES completion:^{
        completionHandler(YES);
    }];
}

- (void)playerViewControllerDidStopPictureInPicture:(AVPlayerViewController *)playerViewController {
    BOOL restored = self.restoringFromPictureInPicture;
    [self log:@"Bild-in-Bild beendet restored=%d", restored];
    self.pictureInPictureActive = NO;
    self.pictureInPictureStarting = NO;
    self.restoringFromPictureInPicture = NO;
    if (!restored) {
        [self endSession];
    }
}

#pragma mark - Untertitel

- (BOOL)isShowingExistingSubtitles {
    if (self.activeSidecarTrack != nil) {
        return YES;
    }
    AVPlayerItem *item = self.player.currentItem;
    // Vor „bereit“ lädt mediaSelectionGroupForMediaCharacteristic: die Playlist synchron (blockiert den Main-Thread).
    if (item.status != AVPlayerItemStatusReadyToPlay) {
        return NO;
    }
    AVMediaSelectionGroup *group = [item.asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
    if (group == nil) {
        return NO;
    }
    AVMediaSelectionOption *option = [item.currentMediaSelection selectedMediaOptionInMediaSelectionGroup:group];
    return option != nil && ![option hasMediaCharacteristic:AVMediaCharacteristicContainsOnlyForcedSubtitles];
}

static BOOL BrowserLanguageMatches(NSString *candidate, NSString *wanted) {
    if (candidate.length == 0 || wanted.length == 0) {
        return NO;
    }
    NSString *a = [[candidate.lowercaseString componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
    NSString *b = [[wanted.lowercaseString componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
    return a.length > 0 && [a isEqualToString:b];
}

/// Stream-Untertitel (HLS-Spuren, eingebettete Spuren): Waren in der Seite Untertitel an, die passende Sprache wählen.
/// Sonst bleibt die automatische Auswahl von AVFoundation (Systemeinstellung „Untertitel“ und Sprache).
- (void)selectStreamSubtitlesIfNeeded {
    AVPlayerItem *item = self.player.currentItem;
    AVAsset *asset = item.asset;
    __weak typeof(self) weakSelf = self;
    [asset loadMediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible
                                       completionHandler:^(AVMediaSelectionGroup *group, __unused NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (AVMediaSelectionOption *option in group.options) {
                [names addObject:[NSString stringWithFormat:@"%@(%@)", option.displayName, option.extendedLanguageTag ?: option.locale.languageCode ?: @"?"]];
            }
            [strongSelf log:@"Stream-Untertitel: %@", names.count > 0 ? [names componentsJoinedByString:@", "] : @"keine"];
            if (group.options.count == 0) {
                [strongSelf loadPreferredSidecarTrack];
                return;
            }
            NSString *wanted = strongSelf.preferredSubtitleLanguage;
            if (wanted.length == 0 || strongSelf.didSelectStreamSubtitles) {
                return;
            }
            AVMediaSelectionOption *match = nil;
            AVMediaSelectionOption *first = nil;
            for (AVMediaSelectionOption *option in [AVMediaSelectionGroup playableMediaSelectionOptionsFromArray:group.options]) {
                if ([option hasMediaCharacteristic:AVMediaCharacteristicContainsOnlyForcedSubtitles]) {
                    continue;
                }
                first = first ?: option;
                NSString *language = option.extendedLanguageTag ?: option.locale.languageCode;
                if (BrowserLanguageMatches(language, wanted)) {
                    match = option;
                    break;
                }
            }
            // Untertitel waren an, aber in anderer Sprache: lieber irgendeine Spur als keine.
            match = match ?: first;
            if (match != nil) {
                strongSelf.didSelectStreamSubtitles = YES;
                [strongSelf.player.currentItem selectMediaOption:match inMediaSelectionGroup:group];
                [strongSelf log:@"Stream-Untertitel gewählt: %@", match.displayName];
            }
        });
    }];
}

- (void)installSubtitleOverlay {
    UIView *overlay = [[UIView alloc] initWithFrame:self.contentOverlayView.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.userInteractionEnabled = NO;
    overlay.backgroundColor = UIColor.clearColor;
    [self.contentOverlayView addSubview:overlay];
    self.subtitleOverlayView = overlay;

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:48.0 weight:UIFontWeightSemibold];
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
    BrowserShapeApply(label.layer, BrowserShapeSmallRadius);
    label.layer.masksToBounds = YES;
    label.hidden = YES;
    [overlay addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:overlay.bottomAnchor constant:-90.0],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:overlay.widthAnchor multiplier:0.8],
    ]];
    self.sidecarLabel = label;
}

/// WebVTT-Spuren der Seite (nur Dateien ohne eigene Stream-Untertitel). Auswahl über das Transportleisten-Menü
/// „Untertitel der Seite“; eingeblendet wird sofort, wenn die Spur in der Seite an war oder `default` ist.
- (void)loadPreferredSidecarTrack {
    if (self.pageTextTracks.count == 0) {
        return;
    }
    [self installSidecarMenu];
    for (BrowserNativeVideoTextTrack *track in self.pageTextTracks) {
        if (track.preferred) {
            [self activateSidecarTrack:track];
            return;
        }
    }
}

- (void)installSidecarMenu {
    if (@available(tvOS 15.0, *)) {
        __weak typeof(self) weakSelf = self;
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        UIAction *off = [UIAction actionWithTitle:@"Aus" image:nil identifier:@"off" handler:^(__unused UIAction *action) {
            [weakSelf activateSidecarTrack:nil];
        }];
        off.state = self.activeSidecarTrack == nil ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:off];
        for (BrowserNativeVideoTextTrack *track in self.pageTextTracks) {
            NSString *title = track.label.length > 0 ? track.label : (track.language.length > 0 ? track.language : @"Untertitel");
            UIAction *action = [UIAction actionWithTitle:title image:nil identifier:track.URL.absoluteString handler:^(__unused UIAction *a) {
                [weakSelf activateSidecarTrack:track];
            }];
            action.state = self.activeSidecarTrack == track ? UIMenuElementStateOn : UIMenuElementStateOff;
            [actions addObject:action];
        }
        UIMenu *menu = [UIMenu menuWithTitle:@"Untertitel der Seite"
                                       image:[UIImage systemImageNamed:@"captions.bubble"]
                                  identifier:nil
                                     options:UIMenuOptionsSingleSelection
                                    children:actions];
        // Fremde Einträge (z. B. „Automatische Untertitel“) behalten, nur den eigenen ersetzen.
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        for (UIMenuElement *element in self.transportBarCustomMenuItems ?: @[]) {
            if (!([element isKindOfClass:UIMenu.class] && [((UIMenu *)element).title isEqualToString:menu.title])) {
                [items addObject:element];
            }
        }
        [items addObject:menu];
        self.transportBarCustomMenuItems = items;
    }
}

- (void)activateSidecarTrack:(nullable BrowserNativeVideoTextTrack *)track {
    self.activeSidecarTrack = track;
    self.sidecarCues = @[];
    self.sidecarLabel.hidden = YES;
    [self installSidecarMenu];
    if (track == nil) {
        [self log:@"WebVTT aus"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:[self requestWithPageHeadersForURL:track.URL]
                                   completionHandler:^(NSData *data, __unused NSURLResponse *response, NSError *error) {
        NSString *text = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSArray<BrowserNativeVideoCue *> *cues = [BrowserNativeVideoPlayerViewController cuesFromWebVTT:text];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.activeSidecarTrack != track) {
                return;
            }
            [strongSelf log:@"WebVTT %@ cues=%lu %@", track.URL.lastPathComponent, (unsigned long)cues.count, error.localizedDescription ?: @""];
            strongSelf.sidecarCues = cues;
            [strongSelf startSidecarTimeObserver];
        });
    }] resume];
}

- (void)startSidecarTimeObserver {
    if (self.sidecarTimeObserver != nil || self.player == nil) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.sidecarTimeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.2, NSEC_PER_SEC)
                                                                          queue:dispatch_get_main_queue()
                                                                     usingBlock:^(CMTime time) {
        [weakSelf showSidecarCueAtTime:CMTimeGetSeconds(time)];
    }];
}

- (void)showSidecarCueAtTime:(NSTimeInterval)time {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (self.activeSidecarTrack != nil) {
        for (BrowserNativeVideoCue *cue in self.sidecarCues) {
            if (cue.start > time) {
                break;
            }
            if (time < cue.end) {
                [lines addObject:cue.text];
            }
        }
    }
    NSString *text = [lines componentsJoinedByString:@"\n"];
    self.sidecarLabel.hidden = text.length == 0;
    if (text.length > 0 && ![self.sidecarLabel.text isEqualToString:text]) {
        // Etwas Luft um den Text auf der dunklen Fläche.
        self.sidecarLabel.text = [NSString stringWithFormat:@" %@ ", [text stringByReplacingOccurrencesOfString:@"\n" withString:@" \n "]];
    }
}

static NSTimeInterval BrowserWebVTTTime(NSString *value) {
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@":"];
    NSTimeInterval seconds = 0.0;
    for (NSString *part in parts) {
        seconds = seconds * 60.0 + [part stringByReplacingOccurrencesOfString:@"," withString:@"."].doubleValue;
    }
    return seconds;
}

/// Kleiner WebVTT-Leser: Zeitzeilen `00:01.000 --> 00:04.000`, Text bis zur Leerzeile, Tags entfernt. Nach Start sortiert.
+ (NSArray<BrowserNativeVideoCue *> *)cuesFromWebVTT:(NSString *)text {
    if (text.length == 0 || ![text containsString:@"-->"]) {
        return @[];
    }
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:NULL];
    NSMutableArray<BrowserNativeVideoCue *> *cues = [NSMutableArray array];
    NSArray<NSString *> *lines = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] componentsSeparatedByString:@"\n"];
    BrowserNativeVideoCue *current = nil;
    NSMutableArray<NSString *> *body = nil;
    for (NSString *rawLine in [lines arrayByAddingObject:@""]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange arrow = [line rangeOfString:@"-->"];
        if (arrow.location != NSNotFound) {
            current = [BrowserNativeVideoCue new];
            current.start = BrowserWebVTTTime([[line substringToIndex:arrow.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
            NSString *rest = [[line substringFromIndex:NSMaxRange(arrow)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            current.end = BrowserWebVTTTime([rest componentsSeparatedByString:@" "].firstObject ?: @"");
            body = [NSMutableArray array];
            continue;
        }
        if (current == nil) {
            continue;
        }
        if (line.length == 0) {
            NSString *cueText = [body componentsJoinedByString:@"\n"];
            cueText = [tags stringByReplacingMatchesInString:cueText options:0 range:NSMakeRange(0, cueText.length) withTemplate:@""];
            cueText = [[[[cueText stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"]
                         stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"]
                        stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "]
                       stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            if (cueText.length > 0 && current.end > current.start) {
                current.text = cueText;
                [cues addObject:current];
            }
            current = nil;
            continue;
        }
        [body addObject:line];
    }
    [cues sortUsingComparator:^NSComparisonResult(BrowserNativeVideoCue *a, BrowserNativeVideoCue *b) {
        return a.start < b.start ? NSOrderedAscending : (a.start > b.start ? NSOrderedDescending : NSOrderedSame);
    }];
    return cues;
}

#pragma mark - Fernbedienung (aus UIApplication+BrowserSelectPressForwarding)

- (void)togglePlayback {
    if (self.player.rate > 0.0) {
        [self log:@"toggle pause"];
        [self.player pause];
    } else {
        [self log:@"toggle play"];
        [self.player play];
    }
}

- (void)skipByInterval:(NSTimeInterval)delta {
    if (self.player.currentItem == nil) {
        return;
    }

    NSTimeInterval currentTime = CMTimeGetSeconds(self.player.currentTime);
    if (!isfinite(currentTime)) {
        currentTime = 0.0;
    }

    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    NSTimeInterval targetTime = currentTime + delta;
    if (isfinite(duration) && duration > 0.0) {
        targetTime = MIN(MAX(targetTime, 0.0), MAX(duration - 0.05, 0.0));
    } else {
        targetTime = MAX(targetTime, 0.0);
    }

    [self log:@"seek delta=%0.3f from=%0.3f to=%0.3f", delta, currentTime, targetTime];
    CMTime seekTime = CMTimeMakeWithSeconds(targetTime, NSEC_PER_SEC);
    [self.player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (void)scrubByHorizontalDelta:(CGFloat)delta {
    // Approximate touch-surface horizontal movement to timeline seek.
    NSTimeInterval secondsDelta = (NSTimeInterval)delta / 4.0;
    if (fabs(secondsDelta) < 0.01) {
        return;
    }
    [self skipByInterval:secondsDelta];
}

- (void)closePlayer {
    [self log:@"close player"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Protokoll

- (NSString *)debugStateLine {
    AVPlayerItem *item = self.player.currentItem;
    AVMediaSelectionGroup *group = [item.asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
    AVMediaSelectionOption *legible = group != nil ? [item.currentMediaSelection selectedMediaOptionInMediaSelectionGroup:group] : nil;
    NSString *status = item.status == AVPlayerItemStatusReadyToPlay ? @"ready" : (item.status == AVPlayerItemStatusFailed ? @"failed" : @"unknown");
    return [NSString stringWithFormat:@"t=%.1f dur=%.1f rate=%.1f status=%@ live=%d hls=%d loader=%d pipAllowed=%d pipSupported=%d pip=%d legible=%lu/%@ sidecar=%@ cues=%lu meta=%lu art=%d",
            CMTimeGetSeconds(self.player.currentTime), CMTimeGetSeconds(item.duration), self.player.rate, status, self.live,
            self.streamingPlaylist, self.assetLoader != nil, self.allowsPictureInPicturePlayback,
            [AVPictureInPictureController isPictureInPictureSupported], self.pictureInPictureActive,
            (unsigned long)group.options.count, legible.displayName ?: @"-", self.activeSidecarTrack.label ?: @"-",
            (unsigned long)self.sidecarCues.count, (unsigned long)item.externalMetadata.count, self.artworkImage != nil];
}

- (void)handlePlayerItemFailedToPlayToEndTime:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self log:@"failedToPlayToEnd error=%@", error];
}

- (void)handlePlayerItemNewErrorLogEntry:(NSNotification *)notification {
    AVPlayerItemErrorLog *errorLog = self.player.currentItem.errorLog;
    AVPlayerItemErrorLogEvent *lastEvent = errorLog.events.lastObject;
    [self log:@"errorLog domain=%@ status=%ld comment=%@ serverAddress=%@ uri=%@",
     lastEvent.errorDomain ?: @"",
     (long)lastEvent.errorStatusCode,
     lastEvent.errorComment ?: @"",
     lastEvent.serverAddress ?: @"",
     lastEvent.URI ?: @""];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([object isKindOfClass:AVPlayerItem.class] && [keyPath isEqualToString:@"status"]) {
        AVPlayerItem *item = object;
        switch (item.status) {
            case AVPlayerItemStatusUnknown:
                [self log:@"item status=unknown"];
                break;
            case AVPlayerItemStatusReadyToPlay:
                [self playerItemBecameReady:item];
                break;
            case AVPlayerItemStatusFailed:
                [self log:@"item status=failed error=%@", item.error];
                if (!self.didReportFailure) {
                    self.didReportFailure = YES;
                    if (self.failureHandler != nil) {
                        self.failureHandler(item.error);
                    }
                }
                break;
        }
        return;
    }

    if (object == self.player && [keyPath isEqualToString:@"timeControlStatus"]) {
        NSString *status = @"unknown";
        switch (self.player.timeControlStatus) {
            case AVPlayerTimeControlStatusPaused:
                status = @"paused";
                break;
            case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                status = @"waiting";
                break;
            case AVPlayerTimeControlStatusPlaying:
                status = @"playing";
                self.didStartPlayback = YES;
                break;
        }
        [self log:@"timeControlStatus=%@ reason=%@", status, self.player.reasonForWaitingToPlay ?: @""];
        return;
    }

    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesBegan type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"%@ pressesEnded type=%@ phase=%@",
              kBrowserNativePlayerInputLogPrefix,
              BrowserNativePlayerPressTypeString(press.type),
              BrowserNativePlayerPressPhaseString(press.phase));
    }
    [super pressesEnded:presses withEvent:event];
}

@end
