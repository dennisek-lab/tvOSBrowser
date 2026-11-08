//
//  BrowserPopupNotice.h
//  Browser
//
//  Kleine Einblendung unten rechts, wenn eine Seite ein Pop-up (oder einen Link mit target=_blank) im
//  Hintergrund-Tab geöffnet hat. Glas-Kapsel im Stil der App (altes Design: dunkler Blur), 6 s sichtbar,
//  mehrere Pop-ups kurz hintereinander werden zusammengefasst („3 Pop-ups geöffnet“), nicht gestapelt.
//  Die Einblendung ist ein Zeigerziel; Klick darauf oder Play/Pause springt zum (zuletzt geöffneten) Tab.
//  Logik in ViewController.m (popupNotice…), Doku docs/ERWEITERUNGEN.md Abschnitt 23.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPopupNotice : NSObject

- (instancetype)initWithContainerView:(UIView *)containerView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Ein neuer Hintergrund-Tab. sameSite: von derselben Website wie der aktuelle Tab; popup: window.open bzw.
/// createWebView (NO: vom Nutzer geklickter Link mit target=_blank); displayName: Titel oder bis dahin der Host.
- (void)noteTabWithIdentifier:(NSString *)identifier sameSite:(BOOL)sameSite popup:(BOOL)popup displayName:(NSString *)displayName;
/// Titel des Tabs ist bekannt (Seite geladen): Text nachziehen, falls die Einblendung genau diesen Tab zeigt.
- (void)updateDisplayName:(NSString *)displayName forTabWithIdentifier:(NSString *)identifier;
/// Einblendung sofort ausblenden (Sprung zum Tab, Tab geschlossen).
- (void)dismiss;

@property (nonatomic, readonly, getter=isVisible) BOOL visible;
/// Tab, zu dem Klick bzw. Play/Pause springt (zuletzt geöffneter), nil wenn nicht sichtbar.
@property (nonatomic, readonly, nullable) NSString *targetTabIdentifier;
/// Rahmen in Koordinaten der Containeransicht (CGRectNull, wenn nicht sichtbar).
@property (nonatomic, readonly) CGRect frameInContainer;
@property (nonatomic, readonly) CGFloat cornerRadius;
/// Aktueller Text (Selbsttest, Log).
@property (nonatomic, readonly, nullable) NSString *text;
/// Sichtbarkeit hat sich geändert (Zeigerziele neu melden).
@property (nonatomic, copy, nullable) void (^visibilityHandler)(BOOL visible);

@end

NS_ASSUME_NONNULL_END
