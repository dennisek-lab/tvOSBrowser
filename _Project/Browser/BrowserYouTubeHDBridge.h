#import <Foundation/Foundation.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const BrowserYouTubeHDErrorDomain;

typedef NS_ERROR_ENUM(BrowserYouTubeHDErrorDomain, BrowserYouTubeHDError) {
    /// Seite ohne Brücke oder ohne Player-Response.
    BrowserYouTubeHDErrorNoInfo = 1,
    /// Der Seitenplayer hat (noch) keine Medienadresse zu diesem Video abgerufen (z. B. läuft Werbung).
    BrowserYouTubeHDErrorNoCapture = 2,
    /// Kein H.264- oder AAC-Format mit Adresse.
    BrowserYouTubeHDErrorNoFormat = 3,
    /// Segmentindex (sidx) nicht ladbar (HTTP-Fehler, z. B. 403) oder nicht lesbar.
    BrowserYouTubeHDErrorIndex = 4,
};

/// Fertige HLS-Darstellung eines YouTube-Videos aus getrennten fMP4-Spuren (H.264 + AAC).
@interface BrowserYouTubeHDPresentation : NSObject
/// Hauptplaylist (`https://youtube-hd.invalid/<id>/master.m3u8`), wird nur über den Asset-Loader ausgeliefert.
@property (nonatomic, copy) NSURL *masterURL;
/// Erzeugte Playlists: absolute Adresse → Inhalt.
@property (nonatomic, copy) NSDictionary<NSString *, NSData *> *playlists;
/// Header für googlevideo (User-Agent, Referer), ohne Origin.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy, nullable) NSURL *artworkURL;
/// Position des Seitenplayers (Sekunden).
@property (nonatomic) NSTimeInterval pageTime;
@property (nonatomic) NSTimeInterval duration;
/// Höchste Videoauflösung in der Playlist.
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
/// Kurzbeschreibung für Logs (Formate, Segmente, Zeiten).
@property (nonatomic, copy) NSString *summary;
@end

/// YouTube in HD ohne MSE (Abschnitt 10.5 in docs/ERWEITERUNGEN.md). Das Seitenskript `YouTubeHD/youtube_hd_bridge.js`
/// bildet MediaSource nach, damit YouTubes Player getrennte Spuren abruft; dabei entstehen gültige Adressen (n, pot).
/// Diese Klasse überträgt n und pot auf die Formate des Player-Response, lädt je Spur den Segmentindex (sidx) und baut
/// daraus HLS (Hauptplaylist, Video-Varianten, Tonspur) mit `#EXT-X-BYTERANGE` auf die googlevideo-Dateien.
@interface BrowserYouTubeHDBridge : NSObject

/// Einstellung `YouTubeHDBridge` (Vorgabe: an).
+ (BOOL)isEnabled;
/// Seitenskript (document-start, Hauptframe). In DEBUG kann `YTHD_SCRIPT_PATH` eine Datei auf dem Mac nennen.
+ (NSString *)userScriptSource;

/// Liest Adressen und Formate aus der Seite (wartet bis `waitSeconds` auf die erste Medienanfrage dieses Videos),
/// lädt die Segmentindizes und baut die Playlists.
- (void)preparePresentationForWebView:(BrowserWebView *)webView
                          waitSeconds:(NSTimeInterval)waitSeconds
                           completion:(void (^)(BrowserYouTubeHDPresentation * _Nullable presentation, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
