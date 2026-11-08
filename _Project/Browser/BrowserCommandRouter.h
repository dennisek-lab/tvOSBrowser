//
//  BrowserCommandRouter.h
//  Browser
//
//  Führt Befehle aus der Befehlstabelle (BrowserCommand) aus: Siri (App Intent), Diktat im
//  Adressfeld, Selbsttest (cmd:<name>[|arg]) und später das iPhone. Die eigentlichen Aktionen
//  liegen im Host (ViewController). Loggt "[Command] …" und blendet eine kurze Rückmeldung ein.
//

#import <UIKit/UIKit.h>
#import "BrowserCommand.h"

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserCommandHost <NSObject>

/// Vor jedem Befehl: offene Dialoge schließen, Adress-Bearbeiten beenden.
- (void)browserCommandPrepare;
/// Ansicht für die Rückmeldung (Glas-Hinweis unten mittig).
- (nullable UIView *)browserCommandFeedbackContainerView;

@property (nonatomic, readonly) BOOL browserCommandReaderAvailable;
@property (nonatomic, readonly) BOOL browserCommandReaderActive;
- (void)browserCommandToggleReader;

- (void)browserCommandBeginAddressEditing;
/// Wie die Eingabe im Adressfeld: Adresse laden oder suchen.
- (void)browserCommandOpenAddressOrSearch:(NSString *)text;
- (void)browserCommandSearch:(NSString *)query;
/// Adresse ohne Schema wird mit https:// ergänzt.
- (BOOL)browserCommandOpenAddress:(NSString *)address;

- (BOOL)browserCommandGoBack;
- (BOOL)browserCommandGoForward;
- (BOOL)browserCommandReload;
- (void)browserCommandGoHome;
- (void)browserCommandNewTab;
- (void)browserCommandCloseTab;
- (void)browserCommandShowTabs;

/// Favorit setzen (desired = nil: umschalten). Rückgabe: neuer Zustand oder nil (Seite kann kein Favorit sein).
- (nullable NSNumber *)browserCommandSetFavorite:(nullable NSNumber *)desired;

/// Host der Seite für den Werbeblocker (nil = keine Seite).
- (nullable NSString *)browserCommandAdBlockSiteName;
- (BOOL)browserCommandAdBlockActiveForSite;
- (void)browserCommandSetAdBlockActiveForSite:(BOOL)active;

- (BOOL)browserCommandScrollToTop;
/// Anteil der Seitenhöhe (+ runter, − hoch). NO, wenn sich nichts bewegt.
- (BOOL)browserCommandScrollPageByFraction:(CGFloat)fraction;

- (void)browserCommandShowMenu;
- (void)browserCommandShowHelp;

- (BOOL)browserCommandPageHasVideo;
- (void)browserCommandOpenVideoInPlayer;
/// "toggle", "play", "pause", "seek:±N" (wie BrowserWebView sendVideoCommand:).
- (void)browserCommandSendVideoCommand:(NSString *)command;

@optional
/// Intelligente Funktionen (BrowserIntelligenceController): Karte „Zusammenfassung“ zeigen; die Karte ist die Rückmeldung.
- (void)browserCommandSummarize;
/// Seite über translate.goog öffnen. NO, wenn nicht möglich (Rückmeldung kommt vom Controller).
- (BOOL)browserCommandTranslate;
/// Übersetzung beenden: Originalseite statt translate.goog laden.
- (BOOL)browserCommandShowOriginal;
/// „Frag die Seite“: passendste Stelle suchen und hervorheben; Antwort-Karte bzw. Hinweis kommt vom Controller.
- (void)browserCommandAskPage:(NSString *)question;

@end

@interface BrowserCommandRouter : NSObject

- (instancetype)initWithHost:(id<BrowserCommandHost>)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Führt den Befehl aus. NO bei unbekanntem Befehl oder wenn er gerade nicht möglich ist.
- (BOOL)performCommandNamed:(NSString *)name argument:(nullable NSString *)argument source:(BrowserCommandSource)source;
/// Wie oben; note wird an die Rückmeldung gehängt (z. B. „sinngemäß erkannt“ beim Ähnlichkeitsabgleich).
- (BOOL)performCommandNamed:(NSString *)name argument:(nullable NSString *)argument source:(BrowserCommandSource)source
               feedbackNote:(nullable NSString *)note;

/// Kurze Rückmeldung einblenden (auch für andere Stellen nutzbar).
- (void)showFeedback:(NSString *)text symbolName:(nullable NSString *)symbolName success:(BOOL)success;

@end

NS_ASSUME_NONNULL_END
