#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Vom nativen Player gesendet, wenn er erscheint bzw. verschwindet.
extern NSNotificationName const BrowserNativePlayerDidAppearNotification;
extern NSNotificationName const BrowserNativePlayerWillDisappearNotification;

/// Meldet laufende Webseiten-Videos ans System („Now Playing“) und leitet die Systembefehle
/// (iPhone-Fernbedienung, Kontrollzentrum, Siri) an die Seite weiter.
/// Den nativen Player (AVPlayerViewController) meldet AVKit selbst; solange er offen ist, pausiert diese Klasse.
@interface BrowserNowPlayingController : NSObject

/// Befehl an die Seite: "play", "pause", "toggle", "seek:±S", "seekto:S", "action:nexttrack", "action:previoustrack".
@property (nonatomic, copy, nullable) void (^commandHandler)(NSString *command);

/// Neuer Stand von der Seite (BrowserWebView.mediaInfo), nil = nichts mehr aktiv.
- (void)updateWithMediaInfo:(nullable NSDictionary *)mediaInfo;

/// YES, während der native Player läuft und selbst meldet.
@property (nonatomic) BOOL suspended;

/// Audio-Session auf Wiedergabe stellen, damit die App Now-Playing-App werden darf.
+ (void)activateAudioSession;

@end

NS_ASSUME_NONNULL_END
