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

/// Standardlänge für textForWebView: (etwa 1.500 Tokens).
extern const NSUInteger BrowserReaderDefaultTextLength;

@interface BrowserReaderMode : NSObject

/// Fragt den Zustand der aktuellen Seite ab (installiert die Skripte bei Bedarf).
+ (void)checkWebView:(BrowserWebView *)webView completion:(void (^)(BrowserReaderState state))completion;
/// Schaltet um: aus -> Artikel extrahieren und anzeigen, an -> Originalseite.
+ (void)toggleWebView:(BrowserWebView *)webView completion:(void (^)(BrowserReaderState state))completion;
/// Artikeltext ohne Overlay (Readability auf einer Kopie des Dokuments, Rückfall: Text von article/main/body),
/// auf maxLength Zeichen gekürzt (Absatzgrenzen bleiben, der letzte Absatz wird abgeschnitten).
/// info: title, site, lang (Attribut der Seite), source ("reader", "body", "…-raw"), text (Absätze mit Leerzeile),
/// total (Länge des ungekürzten Texts). nil, wenn die Skripte fehlen oder die Seite nicht antwortet.
+ (void)textForWebView:(BrowserWebView *)webView
             maxLength:(NSUInteger)maxLength
            completion:(void (^)(NSDictionary<NSString *, id> * _Nullable info))completion;
/// Wie oben mit BrowserReaderDefaultTextLength (6.000 Zeichen).
+ (void)textForWebView:(BrowserWebView *)webView completion:(void (^)(NSDictionary<NSString *, id> * _Nullable info))completion;
/// Beendet den Reader (falls aktiv).
+ (void)exitWebView:(BrowserWebView *)webView completion:(nullable void (^)(BrowserReaderState state))completion;

@end

NS_ASSUME_NONNULL_END
