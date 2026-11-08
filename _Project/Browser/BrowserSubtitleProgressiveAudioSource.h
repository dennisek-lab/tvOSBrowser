#import <Foundation/Foundation.h>

#import "BrowserSubtitleAudioSource.h"

NS_ASSUME_NONNULL_BEGIN

/// Ton bei Dateien über HTTP(S) (MP4/MOV/M4A), unabhängig vom Abspielen: liest das `moov`-Atom (auch am Dateiende)
/// per Range-Anfrage, sucht die Audiospur und lädt nur deren Pakete (`stco`/`stsz`/`stsc`/`stts`), ein Stück vor der
/// Abspielposition. Dekodiert mit `AudioConverter` (AAC, HE-AAC, MP3, AC-3, E-AC-3) zu 16 kHz mono.
/// Zeiten sind Präsentationszeiten (Edit-Liste `elst` berücksichtigt), passen also zu `AVPlayer.currentTime`.
///
/// Nicht: fragmentierte MP4 (`moof`), verschlüsselte Spuren (`enca`), `moov` über 16 MB, Server ohne Range.
/// Dann meldet die Quelle einen Fehler und der Controller nimmt den Audio-Tap.
@interface BrowserSubtitleProgressiveAudioSource : NSObject <BrowserSubtitleAudioSource>
- (instancetype)initWithURL:(NSURL *)URL
             requestHeaders:(nullable NSDictionary<NSString *, NSString *> *)requestHeaders
                    cookies:(nullable NSArray<NSHTTPCookie *> *)cookies NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// http/https und keine Playlist (`.m3u8`, `.mpd`).
+ (BOOL)canHandleURL:(NSURL *)URL;
/// So weit vor der Abspielposition laden (Standard 60 s) und höchstens so viel unausgewerteten Ton stauen (25 s).
@property (nonatomic) NSTimeInterval lookahead;
@property (nonatomic) NSTimeInterval maxPending;
@end

NS_ASSUME_NONNULL_END
