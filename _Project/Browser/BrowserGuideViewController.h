#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Kurze Bedienungshilfe als Glas-Karte über der Seite.
@interface BrowserGuideViewController : UIViewController

/// Aktueller Zustand des Schalters "Start-Hinweis aus". Vor dem Präsentieren setzen.
@property (nonatomic) BOOL dontShowOnLaunch;
/// Wird aufgerufen, wenn der Nutzer den zweiten Knopf wählt (neuer Wert von dontShowHintsOnLaunch).
@property (nonatomic, copy, nullable) void (^toggleHandler)(BOOL dontShowOnLaunch);

@end

NS_ASSUME_NONNULL_END
