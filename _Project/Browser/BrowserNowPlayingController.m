#import "BrowserNowPlayingController.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

static const double kBrowserNowPlayingSkipInterval = 10.0;

NSNotificationName const BrowserNativePlayerDidAppearNotification = @"BrowserNativePlayerDidAppearNotification";
NSNotificationName const BrowserNativePlayerWillDisappearNotification = @"BrowserNativePlayerWillDisappearNotification";

@interface BrowserNowPlayingController ()
@property (nonatomic) BOOL commandsRegistered;
@property (nonatomic) BOOL active;
@property (nonatomic, copy, nullable) NSString *artworkURL;
@property (nonatomic, nullable) MPMediaItemArtwork *artwork;
@property (nonatomic, copy, nullable) NSDictionary *lastInfo;
@end

@implementation BrowserNowPlayingController

- (instancetype)init {
    self = [super init];
    if (self) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(nativePlayerDidAppear:)
                                                   name:BrowserNativePlayerDidAppearNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(nativePlayerWillDisappear:)
                                                   name:BrowserNativePlayerWillDisappearNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)nativePlayerDidAppear:(__unused NSNotification *)notification {
    self.suspended = YES;
}

- (void)nativePlayerWillDisappear:(__unused NSNotification *)notification {
    self.suspended = NO;
}

+ (void)activateAudioSession {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&error]) {
        NSLog(@"[NowPlaying] category error %@", error);
    }
    if (![session setActive:YES error:&error]) {
        NSLog(@"[NowPlaying] activate error %@", error);
    }
}

- (void)send:(NSString *)command {
    if (self.commandHandler != nil) {
        self.commandHandler(command);
    }
}

- (void)registerCommandsIfNeeded {
    if (self.commandsRegistered) {
        return;
    }
    self.commandsRegistered = YES;
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    __weak typeof(self) weakSelf = self;
    [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        [weakSelf send:@"play"];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        [weakSelf send:@"pause"];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        [weakSelf send:@"toggle"];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    center.skipForwardCommand.preferredIntervals = @[@(kBrowserNowPlayingSkipInterval)];
    center.skipBackwardCommand.preferredIntervals = @[@(kBrowserNowPlayingSkipInterval)];
    [center.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        double interval = [event isKindOfClass:MPSkipIntervalCommandEvent.class] ? ((MPSkipIntervalCommandEvent *)event).interval : kBrowserNowPlayingSkipInterval;
        [weakSelf send:[NSString stringWithFormat:@"seek:%g", interval]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [center.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        double interval = [event isKindOfClass:MPSkipIntervalCommandEvent.class] ? ((MPSkipIntervalCommandEvent *)event).interval : kBrowserNowPlayingSkipInterval;
        [weakSelf send:[NSString stringWithFormat:@"seek:-%g", interval]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (![event isKindOfClass:MPChangePlaybackPositionCommandEvent.class]) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        [weakSelf send:[NSString stringWithFormat:@"seekto:%.2f", ((MPChangePlaybackPositionCommandEvent *)event).positionTime]];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        [weakSelf send:@"action:nexttrack"];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
        [weakSelf send:@"action:previoustrack"];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)setCommandsEnabled:(BOOL)enabled next:(BOOL)next previous:(BOOL)previous {
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    center.playCommand.enabled = enabled;
    center.pauseCommand.enabled = enabled;
    center.togglePlayPauseCommand.enabled = enabled;
    center.skipForwardCommand.enabled = enabled;
    center.skipBackwardCommand.enabled = enabled;
    center.changePlaybackPositionCommand.enabled = enabled;
    center.nextTrackCommand.enabled = enabled && next;
    center.previousTrackCommand.enabled = enabled && previous;
}

- (void)setSuspended:(BOOL)suspended {
    if (_suspended == suspended) {
        return;
    }
    _suspended = suspended;
    if (suspended) {
        // Der native Player übernimmt Info und Befehle.
        [self setCommandsEnabled:NO next:NO previous:NO];
    } else {
        NSDictionary *info = self.lastInfo;
        self.lastInfo = nil;
        self.active = NO;
        [self updateWithMediaInfo:info];
    }
}

- (void)loadArtworkIfNeeded:(NSString *)urlString {
    if ([urlString isEqualToString:self.artworkURL ?: @""]) {
        return;
    }
    self.artworkURL = urlString;
    self.artwork = nil;
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (url == nil || !([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"])) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
        if (image == nil) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![weakSelf.artworkURL isEqualToString:urlString]) {
                return;
            }
            weakSelf.artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage *(__unused CGSize size) {
                return image;
            }];
            NSDictionary *info = weakSelf.lastInfo;
            weakSelf.lastInfo = nil;
            [weakSelf updateWithMediaInfo:info];
        });
    }] resume];
}

static NSString *BrowserString(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (void)updateWithMediaInfo:(NSDictionary *)mediaInfo {
    if ([mediaInfo isEqualToDictionary:self.lastInfo ?: @{}] && mediaInfo != nil) {
        return;
    }
    self.lastInfo = mediaInfo;
    if (self.suspended) {
        return;
    }
    MPNowPlayingInfoCenter *infoCenter = MPNowPlayingInfoCenter.defaultCenter;
    if (mediaInfo == nil) {
        if (self.active) {
            self.active = NO;
            infoCenter.nowPlayingInfo = nil;
            infoCenter.playbackState = MPNowPlayingPlaybackStateStopped;
            [self setCommandsEnabled:NO next:NO previous:NO];
        }
        return;
    }

    if (!self.active) {
        self.active = YES;
        [BrowserNowPlayingController activateAudioSession];
        [self registerCommandsIfNeeded];
    }
    BOOL paused = [mediaInfo[@"paused"] boolValue];
    double rate = [mediaInfo[@"rate"] doubleValue];
    double duration = [mediaInfo[@"dur"] doubleValue];
    [self setCommandsEnabled:YES next:[mediaInfo[@"next"] boolValue] previous:[mediaInfo[@"prev"] boolValue]];
    [self loadArtworkIfNeeded:BrowserString(mediaInfo[@"art"])];

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = BrowserString(mediaInfo[@"title"]);
    info[MPMediaItemPropertyArtist] = BrowserString(mediaInfo[@"artist"]);
    NSString *album = BrowserString(mediaInfo[@"album"]);
    if (album.length > 0) {
        info[MPMediaItemPropertyAlbumTitle] = album;
    }
    if (duration > 0 && isfinite(duration)) {
        info[MPMediaItemPropertyPlaybackDuration] = @(duration);
    } else {
        info[MPNowPlayingInfoPropertyIsLiveStream] = @YES;
    }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @([mediaInfo[@"t"] doubleValue]);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(paused ? 0.0 : (rate > 0 ? rate : 1.0));
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @1.0;
    info[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeVideo);
    if (self.artwork != nil) {
        info[MPMediaItemPropertyArtwork] = self.artwork;
    }
    infoCenter.nowPlayingInfo = info;
    infoCenter.playbackState = paused ? MPNowPlayingPlaybackStatePaused : MPNowPlayingPlaybackStatePlaying;
#if DEBUG
    NSLog(@"[NowPlaying] %@ t=%.1f/%.1f paused=%d", info[MPMediaItemPropertyTitle], [mediaInfo[@"t"] doubleValue], duration, paused);
#endif
}

@end
