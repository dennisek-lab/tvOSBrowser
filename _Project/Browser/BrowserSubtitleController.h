#import <AVKit/AVKit.h>

@class BrowserPreferencesStore;

NS_ASSUME_NONNULL_BEGIN

/// Automatische Untertitel im nativen Player (whisper.cpp, lokal).
///
/// Einhängen (BrowserNativeVideoPlayerViewController, nach dem Anlegen des AVPlayer):
///     self.subtitleController = [BrowserSubtitleController attachToPlayerViewController:self playbackURL:… requestHeaders:… cookies:…];
/// Aufräumen beim Schließen: [self.subtitleController detach];
///
/// Legt die Untertitelebene in `contentOverlayView`, einen Schalter „Automatische Untertitel“ in
/// `transportBarCustomMenuItems` (bestehende Einträge bleiben erhalten) und startet die Erkennung,
/// wenn `BrowserPreferencesStore.autoSubtitlesEnabled` an ist. Tonquelle: Audio-Tap bei Dateien,
/// eigene Segmentauswertung bei HLS. Logpräfix `[Subtitles]`.
@interface BrowserSubtitleController : NSObject

+ (instancetype)attachToPlayerViewController:(AVPlayerViewController *)playerViewController
                                 playbackURL:(NSURL *)playbackURL
                              requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                                     cookies:(nullable NSArray<NSHTTPCookie *> *)cookies;

/// Erkennung stoppen, Zeitbeobachter, Ebene und Menüeintrag entfernen, Modell freigeben.
- (void)detach;

@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// Für einen Schalter im Seitenmenü (BrowserMenuCoordinator): Titel und Zustand.
+ (NSString *)menuTitle;
+ (NSString *)menuDetailForPreferences:(BrowserPreferencesStore *)preferences;

@end

NS_ASSUME_NONNULL_END
