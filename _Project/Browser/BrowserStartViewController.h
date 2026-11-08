//
//  BrowserStartViewController.h
//  Startansicht: Such-/Adressfeld, Zuletzt besucht, Meistbesucht, Favoriten.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserStartViewController : UIViewController

/// Wird mit der zu öffnenden Adresse aufgerufen (Kachel, Adresseingabe oder Google-Suche). Die Ansicht schließt sich vorher selbst.
@property (nonatomic, copy, nullable) void (^openURLHandler)(NSURL *url);

@end

NS_ASSUME_NONNULL_END
