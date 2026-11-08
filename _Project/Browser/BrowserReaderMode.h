#import <UIKit/UIKit.h>

@class BrowserWebView;

NS_ASSUME_NONNULL_BEGIN

/// Reader-Modus: Mozillas Readability.js (Ordner Reader/) erkennt und extrahiert den Artikel, reader.js zeigt ihn
/// als Overlay im selben Dokument. Der Zustand lebt in der Seite (window.__browserReader), nicht in der App.
typedef NS_ENUM(NSInteger, BrowserReaderState) {
    BrowserReaderStateUnavailable = 0, ///< Seite nicht lesbar
    BrowserReaderStateAvailable,       ///< lesbar, Reader aus
    BrowserReaderStateActive           ///< Reader an
};

@interface BrowserReaderMode : NSObject

/// Fragt den Zustand der aktuellen Seite ab (installiert die Skripte bei Bedarf).
+ (void)checkWebView:(BrowserWebView *)webView completion:(void (^)(BrowserReaderState state))completion;
/// Schaltet um: aus -> Artikel extrahieren und anzeigen, an -> Originalseite.
+ (void)toggleWebView:(BrowserWebView *)webView completion:(void (^)(BrowserReaderState state))completion;
/// Beendet den Reader (falls aktiv).
+ (void)exitWebView:(BrowserWebView *)webView completion:(nullable void (^)(BrowserReaderState state))completion;

@end

NS_ASSUME_NONNULL_END
