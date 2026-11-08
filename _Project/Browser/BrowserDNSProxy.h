#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lokaler SOCKS5-Proxy, über den WebKit alle Verbindungen aufbaut. Die Namensauflösung der
/// ausgehenden Verbindungen läuft verschlüsselt über Cloudflare (DNS over HTTPS), ohne Rückfall
/// auf den DNS des Providers. Nötig, weil tvOS `NEDNSSettingsManager` nicht anbietet und WebKit
/// Namen in einem eigenen Prozess auflöst.
@interface BrowserDNSProxy : NSObject

+ (instancetype)sharedProxy;

/// Ob der Nutzer DNS über Cloudflare eingeschaltet hat (Standard: an).
@property (class, nonatomic, getter=isEnabled) BOOL enabled;

/// Startet den Proxy, falls eingeschaltet, und wartet höchstens `timeout` Sekunden, bis er bereit ist.
/// Setzt außerdem Cloudflare-DoH für die App-eigenen Verbindungen (Standard-Privacy-Context).
- (BOOL)startAndWaitWithTimeout:(NSTimeInterval)timeout;

/// Hängt den Proxy an einen `WKWebsiteDataStore` (per Laufzeit angesprochen). Bei ausgeschaltetem
/// oder nicht laufendem Proxy werden die Proxy-Einstellungen entfernt.
- (void)applyToWebsiteDataStore:(nullable id)dataStore;

/// Port auf 127.0.0.1, 0 solange der Proxy nicht läuft.
@property (nonatomic, readonly) uint16_t port;

/// Anzahl aufgebauter und fehlgeschlagener Verbindungen seit dem Start, für Diagnose.
@property (nonatomic, readonly) NSUInteger connectionCount;
@property (nonatomic, readonly) NSUInteger failureCount;

@end

NS_ASSUME_NONNULL_END
