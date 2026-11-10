#import <Foundation/Foundation.h>

#import "BrowserSubtitleAudioSource.h"

NS_ASSUME_NONNULL_BEGIN

/// Ton bei HLS: lädt die Audio-Segmente der Playlist selbst (mit Headern/Cookies der Seite),
/// ein Stück vor der Abspielposition, und dekodiert sie zu 16 kHz mono.
///
/// Unterstützt: VOD-Playlists (`#EXT-X-ENDLIST`) und Live-Playlists (nachladen nach Zielzeit, neue Segmente
/// anhängen; Zeitachse `#EXT-X-PROGRAM-DATE-TIME` → `usesDateTimeline`, sonst geschätzt), Master mit eigener Audio-Rendition
/// (`#EXT-X-MEDIA:TYPE=AUDIO,URI=…`, bevorzugt AAC) oder gemuxtem Ton (kleinste Variante),
/// Segmente als MPEG-TS (AAC/ADTS, MP3, AC-3), gepacktes Audio (.aac/.mp3/.ac3 mit ID3)
/// und fMP4 (`#EXT-X-MAP`), `#EXT-X-BYTERANGE`, AES-128.
/// Nicht: SAMPLE-AES/FairPlay (Kopierschutz), LATM-AAC.
@interface BrowserSubtitleHLSAudioSource : NSObject <BrowserSubtitleAudioSource>
- (instancetype)initWithPlaylistURL:(NSURL *)playlistURL
                     requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                            cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Sprache für die Wahl der Audio-Rendition („en“, „de“ …; nil = Standard-Rendition).
@property (nonatomic, copy, nullable) NSString *preferredLanguage;
/// In der App erzeugte Playlists (Adresse → Inhalt), etwa YouTube in HD (`https://youtube-hd.invalid/…`): werden
/// nicht geladen, sondern direkt gelesen. Segmente und alles andere kommen weiter übers Netz.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSData *> *generatedResources;
@end

NS_ASSUME_NONNULL_END
