#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Prüft auf dem Gerät, ob die für Werbeblocker, JS-Rückkanal und Cloudflare-DNS nötigen
/// WebKit- und Network-Funktionen unter tvOS erreichbar sind. Schreibt das Ergebnis nach
/// Library/Caches/feasibility.json im App-Container und ins Log (Präfix "[Probe]").
/// Läuft nur mit Launch-Parameter -RunFeasibilityProbe YES oder Umgebungsvariable RUN_FEASIBILITY_PROBE.
@interface BrowserFeasibilityProbe : NSObject

+ (void)runIfRequested;

@end

NS_ASSUME_NONNULL_END
