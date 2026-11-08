#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Kurze Bedienungshilfe als Glas-Karte über der Seite.
@interface BrowserGuideViewController : UIViewController

/// Aktueller Zustand des Schalters "Start-Hinweis aus". Vor dem Präsentieren setzen.
@property (nonatomic) BOOL dontShowOnLaunch;
/// Wird aufgerufen, wenn der Nutzer den zweiten Knopf wählt (neuer Wert von dontShowHintsOnLaunch).
@property (nonatomic, copy, nullable) void (^toggleHandler)(BOOL dontShowOnLaunch);

/// „Was ist neu“ statt der Bedienungshilfe: alle Neuerungen dieser Fassung gegenüber dem Original.
/// Der zweite Knopf heißt dann „Bedienung ansehen“ und ruft `showGuideHandler` nach dem Schließen auf.
@property (nonatomic) BOOL whatsNew;
@property (nonatomic, copy, nullable) void (^showGuideHandler)(void);

/// Stand von „Was ist neu“; ändert sich, wenn neue Punkte dazukommen (dann erscheint der Dialog einmal beim Start).
+ (NSString *)whatsNewVersion;

@end

NS_ASSUME_NONNULL_END
