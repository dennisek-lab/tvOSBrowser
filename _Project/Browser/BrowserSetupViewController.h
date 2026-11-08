#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Ersteinrichtung beim ersten Start: Favoriten, Startseite, Schutz (Werbeblocker, Cloudflare-DNS,
/// Cookie-Banner), Videos (Untertitel, Apple-Player) und Design (Liquid Glass oder alt).
/// Schreibt die Einstellungen selbst (BrowserPreferencesStore, BrowserHistoryStore, BrowserDNSProxy)
/// und setzt `setupCompleted`. Was danach in der App passieren muss (Blocker neu laden, Seite neu laden,
/// Bedienungshilfe zeigen), erledigt der Aufrufer im `completionHandler`.
@interface BrowserSetupViewController : UIViewController

/// Nach dem Schließen aufgerufen. `homePageChanged`: Startseite weicht vom Stand vor der Einrichtung ab.
@property (nonatomic, copy, nullable) void (^completionHandler)(BOOL homePageChanged);

#if DEBUG
/// Selbsttest: Schritt anzeigen (0 Willkommen … 5 Design).
- (void)debugShowPage:(NSInteger)page;
/// Selbsttest: n-te Auswahl des aktuellen Schritts betätigen (Reihenfolge wie auf dem Bildschirm, ohne Weiter/Zurück).
- (void)debugActivateOption:(NSInteger)index;
/// Selbsttest: „Weiter“ bzw. „Fertig“.
- (void)debugNext;
#endif

@end

NS_ASSUME_NONNULL_END
