#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lehnt Cookie-/Einwilligungsbanner (CMPs) automatisch ab, mit DuckDuckGos autoconsent (Ordner Autoconsent, fest auf „optOut“). Ein WKUserScript (document-start, alle Frames)
/// bringt Bundle und Brücke in die Seitenwelt; die Bibliothek erkennt CMPs und wählt „Ablehnen“, nie „Zustimmen“. Die App erhält nur Meldungen fürs Log.
/// Das Skript steckt nur dann im Controller, wenn der Blocker an ist und für die Zielseite keine Ausnahme gilt; der Wechsel geschieht ohne Neuaufbau der WebView (Neuladen genügt).
@interface BrowserCookieConsentBlocker : NSObject

+ (instancetype)sharedBlocker;

/// Installiert Nachrichten-Handler und (falls aktiv) das Skript in den WKUserContentController.
- (void)applyToUserContentController:(id)userContentController;

/// Vor einer Hauptframe-Navigation aufrufen: nimmt das Skript für Ausnahme-Seiten heraus bzw. setzt es wieder ein.
- (void)updateUserContentController:(id)userContentController forNavigationToURL:(nullable NSURL *)url;

/// Nach Änderung des Schalters: alle bekannten Controller neu bestücken.
- (void)preferencesDidChange;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// Anzahl der seit App-Start abgelehnten bzw. ausgeblendeten Banner.
@property (nonatomic, readonly) NSUInteger handledCount;

/// Host (ohne „www.“) einer URL, wie er in der Ausnahmeliste steht.
+ (nullable NSString *)exceptionKeyForURL:(nullable NSURL *)url;
- (BOOL)isExceptionForURL:(nullable NSURL *)url;
- (void)setException:(BOOL)exception forURL:(nullable NSURL *)url;

@end

NS_ASSUME_NONNULL_END
