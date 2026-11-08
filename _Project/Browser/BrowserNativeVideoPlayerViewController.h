#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Neues `AVPlayerItem` ist erstellt und hängt am Player (`object` = der Player-Controller).
/// Einhängepunkt für Erweiterungen wie automatische Untertitel: hier `player`, `playerItem`,
/// `subtitleOverlayView` und die Netzangaben (`videoURL`, `requestHeaders`, `requestCookies`) abgreifen.
extern NSNotificationName const BrowserNativePlayerDidCreatePlayerItemNotification;
/// Die Sitzung endet (Player geschlossen oder Bild-in-Bild beendet), gleich danach wird pausiert
/// (`object` = der Player-Controller). Erweiterungen hier Zeitbeobachter entfernen und Arbeit stoppen.
extern NSNotificationName const BrowserNativePlayerWillEndSessionNotification;

/// Eine Untertitelspur der Seite (`<track>`-Element mit WebVTT-Datei).
@interface BrowserNativeVideoTextTrack : NSObject
@property (nonatomic, copy) NSURL *URL;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *label;
/// War in der Seite eingeblendet (`mode == showing`) oder ist als `default` markiert.
@property (nonatomic) BOOL preferred;
@end

/// Vollbildplayer für Videos der Seite (`AVPlayerViewController`: Transportleiste, Siri, HDR, Bild-in-Bild).
///
/// Aufbau der Datei (`.m`): Lebenszyklus und Aufbau des `AVPlayerItem` → Startposition →
/// Metadaten (Titel, Vorschaubild) → Bild-in-Bild und Sitzungsende → Untertitel (Stream-Spuren, WebVTT der Seite)
/// → Fernbedienung → Protokoll.
@interface BrowserNativeVideoPlayerViewController : AVPlayerViewController

- (instancetype)initWithURL:(NSURL *)URL title:(nullable NSString *)title;
- (instancetype)initWithURL:(NSURL *)URL
                      title:(nullable NSString *)title
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                    cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;

#pragma mark Vor dem Anzeigen setzen

/// Startposition in Sekunden. Der Player springt dorthin, bevor er losspielt (nicht bei Livestreams).
@property (nonatomic) NSTimeInterval initialPlaybackTime;
/// Zweite Zeile unter dem Titel (z. B. Name der Website).
@property (nonatomic, copy, nullable) NSString *videoSubtitle;
/// Beschreibung für die Infoleiste.
@property (nonatomic, copy, nullable) NSString *videoDescription;
/// Vorschaubild (Media Session, `poster` oder `og:image`), wird nachgeladen.
@property (nonatomic, copy, nullable) NSURL *artworkURL;
/// Untertitelspuren der Seite (nur für Dateien wie MP4; HLS bringt eigene Spuren mit).
@property (nonatomic, copy) NSArray<BrowserNativeVideoTextTrack *> *pageTextTracks;
/// Sprache der Untertitel, die in der Seite eingeblendet waren (BCP 47, z. B. `de`). Dann werden
/// passende Stream-Untertitel (HLS) ausgewählt. Leer: Auswahl nach den Systemeinstellungen.
@property (nonatomic, copy, nullable) NSString *preferredSubtitleLanguage;

/// Einmalig beim Ende der Sitzung mit der letzten Position in Sekunden (`NAN` bei Livestreams).
/// Das Ende ist das Schließen des Players oder, nach einem Wechsel in Bild-in-Bild, das Schließen des Bild-in-Bild-Fensters.
@property (nonatomic, copy, nullable) void (^dismissHandler)(NSTimeInterval playbackTime);
/// Wird aufgerufen, wenn AVPlayer das Video nicht abspielen kann (Status „failed“). Einmalig.
@property (nonatomic, copy, nullable) void (^failureHandler)(NSError * _Nullable error);

#pragma mark Einhängepunkt für Erweiterungen (z. B. Untertitel)

/// Ursprüngliche Adresse des Videos (http/https, nicht die Loader-Adresse).
@property (nonatomic, readonly) NSURL *videoURL;
/// HLS-Playlist (`.m3u8`)? Sonst eine Datei (MP4/MOV), bei der ein Audio-Tap greift.
@property (nonatomic, readonly, getter=isStreamingPlaylist) BOOL streamingPlaylist;
/// Header (User-Agent, Referer, Origin) und Cookies der Seite, mit denen der Player lädt.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, readonly, copy) NSArray<NSHTTPCookie *> *requestCookies;
/// Aktuelles Element (= `player.currentItem`), gesetzt ab `viewDidLoad`.
@property (nonatomic, readonly, nullable) AVPlayerItem *playerItem;
/// Ebene für Untertitel im `contentOverlayView` (über dem Bild, unter der Transportleiste, ganze Fläche,
/// keine Berührungen). Eigene Untertitelanzeigen hier als Unteransicht einhängen.
@property (nonatomic, readonly) UIView *subtitleOverlayView;
/// Zeigt der Player schon Untertitel (Stream-Spur ausgewählt oder WebVTT der Seite eingeblendet)?
@property (nonatomic, readonly, getter=isShowingExistingSubtitles) BOOL showingExistingSubtitles;
/// Läuft das Video gerade im Bild-in-Bild-Fenster?
@property (nonatomic, readonly, getter=isPictureInPictureActive) BOOL pictureInPictureActive;

/// Beendet die Sitzung (auch im Bild-in-Bild): Position melden, pausieren, Player lösen.
- (void)endSession;
/// Eine Zeile Zustand für Logs und Selbsttest (`nplayer`).
- (NSString *)debugStateLine;

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
