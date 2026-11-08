#import <AVFoundation/AVFoundation.h>

#import "BrowserSubtitleAudioSource.h"

NS_ASSUME_NONNULL_BEGIN

/// Ton über MTAudioProcessingTap (AVAudioMix am AVPlayerItem). Geht nur bei Dateien (MP4/MOV/M4A …),
/// nicht bei HLS. Liefert in Echtzeit, d. h. Untertitel kommen um Abschnittslänge + Rechenzeit verspätet.
@interface BrowserSubtitleAudioTapSource : NSObject <BrowserSubtitleAudioSource>
- (instancetype)initWithPlayerItem:(AVPlayerItem *)playerItem NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
