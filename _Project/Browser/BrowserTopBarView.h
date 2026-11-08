#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BrowserTopBarAction) {
    BrowserTopBarActionBack = 0,
    BrowserTopBarActionRefresh,
    BrowserTopBarActionForward,
    BrowserTopBarActionHome,
    BrowserTopBarActionTabs,
    BrowserTopBarActionURL,
    BrowserTopBarActionFullscreen,
    BrowserTopBarActionMenu,
    BrowserTopBarActionFavorite,
    BrowserTopBarActionReader
};

@class BrowserTopBarView;

@protocol BrowserTopBarViewDelegate <NSObject>

- (void)browserTopBarView:(BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action;

@end

@interface BrowserTopBarView : UIVisualEffectView

@property (nonatomic, weak, nullable) id<BrowserTopBarViewDelegate> delegate;
@property (nonatomic, readonly) UIImageView *backImageView;
@property (nonatomic, readonly) UIImageView *refreshImageView;
@property (nonatomic, readonly) UIImageView *forwardImageView;
@property (nonatomic, readonly) UIImageView *homeImageView;
@property (nonatomic, readonly) UIImageView *tabsImageView;
@property (nonatomic, readonly) UIImageView *fullscreenImageView;
@property (nonatomic, readonly) UIImageView *menuImageView;
/// Reader-Knopf links neben dem Menü-Symbol.
@property (nonatomic, readonly) UIImageView *readerImageView;
@property (nonatomic, readonly) UILabel *URLLabel;
@property (nonatomic, readonly) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, readonly, getter=isFocusModeActive) BOOL focusModeActive;

- (CGRect)interactiveFrameForView:(UIView *)view;
/// Knöpfe für den magnetischen Zeiger: Rechteck in Koordinaten der Leiste und zugehörige Aktion.
/// Farbe der Seite hinter der Leiste: passt Symbole, Schrift und Glas an (hell/dunkel).
- (void)setPageBackgroundColor:(nullable UIColor *)color;
/// Stern-Knopf: gefüllt und gelb, wenn die aktuelle Seite ein Favorit ist.
@property (nonatomic, getter=isFavorite) BOOL favorite;
/// Ladefortschritt als feine Linie unten in der Leiste; loading = NO lässt sie auslaufen und verschwinden.
- (void)setLoadingProgress:(double)progress loading:(BOOL)loading;
/// Seitenname, dahinter dezent die Domain (nil = keine). Bei verschlüsselter Verbindung (HTTPS) ist der Name grün.
- (void)setDisplayTitle:(nullable NSString *)title domain:(nullable NSString *)domain secure:(BOOL)secure;
/// Volle Adresse der Seite. Das alte Design zeigt sie (wie das Original) statt des Seitennamens.
- (void)setDisplayURLString:(nullable NSString *)URLString;

#pragma mark - Altes Design
/// YES: Leiste wie in der ursprünglichen Fassung (graue Kapsel, weiße Original-Symbole, volle Adresse, Vollbild- und
/// Menü-Knopf rechts), ohne Glas. Folgt BrowserMotion.classicDesignEnabled und wechselt von selbst, sobald sich die
/// Einstellung „ClassicDesign“ ändert (NSUserDefaultsDidChangeNotification).
@property (nonatomic, readonly, getter=isClassicDesign) BOOL classicDesign;
/// Design neu aus der Einstellung übernehmen (Symbole, Fläche, Titel, Layout).
- (void)applyDesign;
/// Reader-Modus: available = Seite lesbar (sonst Knopf ausgeblendet), active = Reader läuft (Knopf hervorgehoben).
- (void)setReaderAvailable:(BOOL)available active:(BOOL)active;
@property (nonatomic, readonly) BOOL readerAvailable;
@property (nonatomic, readonly) BOOL readerActive;
- (void)enumeratePointerTargetsUsingBlock:(void (^)(CGRect frame, BrowserTopBarAction action))block;
- (void)setFocusModeActive:(BOOL)focusModeActive;
/// Kompakte Leiste beim Scrollen: kleine Glas-Kapsel nur mit dem Seitennamen (wie Safari).
@property (nonatomic, readonly, getter=isCompact) BOOL compact;
- (void)setCompact:(BOOL)compact animated:(BOOL)animated;
/// Sichtbare Glasfläche in Koordinaten der Leiste.
@property (nonatomic, readonly) CGRect chromeFrame;
/// Scrollansicht, über deren oberem Rand die Leiste schwebt (für den Kanteneffekt des Systems).
- (void)attachToScrollView:(nullable UIScrollView *)scrollView;
- (nullable UIView *)preferredFocusItem;

#pragma mark - Adresse bearbeiten (Diktierfeld)
/// Bearbeiten-Zustand: Die Kapsel wird zum Feld „Sprechen, um zu diktieren“ (Mikrofon und Platzhalter mittig),
/// die übrigen Knöpfe werden ausgeblendet. Als Zeigerziel gilt dann nur das Feld (Aktion BrowserTopBarActionURL).
@property (nonatomic, readonly, getter=isAddressEditing) BOOL addressEditing;
- (void)setAddressEditing:(BOOL)addressEditing animated:(BOOL)animated;
/// Diktierfeld in Koordinaten der Leiste (CGRectNull außerhalb des Bearbeiten-Zustands).
@property (nonatomic, readonly) CGRect addressFieldFrame;

@end

NS_ASSUME_NONNULL_END
