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
    BrowserTopBarActionMenu
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
@property (nonatomic, readonly) UILabel *URLLabel;
@property (nonatomic, readonly) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, readonly, getter=isFocusModeActive) BOOL focusModeActive;

- (CGRect)interactiveFrameForView:(UIView *)view;
/// Knöpfe für den magnetischen Zeiger: Rechteck in Koordinaten der Leiste und zugehörige Aktion.
/// Farbe der Seite hinter der Leiste: passt Symbole, Schrift und Glas an (hell/dunkel).
- (void)setPageBackgroundColor:(nullable UIColor *)color;
/// Seitenname, dahinter dezent die Domain (nil = keine). Bei verschlüsselter Verbindung (HTTPS) ist der Name grün.
- (void)setDisplayTitle:(nullable NSString *)title domain:(nullable NSString *)domain secure:(BOOL)secure;
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

@end

NS_ASSUME_NONNULL_END
