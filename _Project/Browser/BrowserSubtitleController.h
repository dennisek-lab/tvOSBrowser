#import <AVKit/AVKit.h>

@class BrowserPreferencesStore;

NS_ASSUME_NONNULL_BEGIN

/// Automatische Untertitel im nativen Player (whisper.cpp, lokal).
///
/// Hängt sich selbst ein (`+load`): über `BrowserNativePlayerDidCreatePlayerItemNotification` des
/// BrowserNativeVideoPlayerViewController wird je Player ein Controller angelegt (als assoziiertes Objekt),
/// `BrowserNativePlayerWillEndSessionNotification` räumt ihn ab. Der Player muss nicht geändert werden.
///
/// Legt die Untertitelebene in `subtitleOverlayView` (sonst `contentOverlayView`), ein Menü
/// „Automatische Untertitel“ (An/Aus, „Sprache: …“ mit Automatisch und festen Sprachen, bei Automatisch die für
/// dieses Video erkannte Sprache) in `transportBarCustomMenuItems` (bestehende Einträge bleiben erhalten) und
/// startet die Erkennung, wenn `BrowserPreferencesStore.autoSubtitlesEnabled` an ist und keine
/// Stream-/Seiten-Untertitel laufen. Tonquelle: Audio-Tap bei Dateien, eigene Segmentauswertung bei HLS.
/// Logpräfix `[Subtitles]`.
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
