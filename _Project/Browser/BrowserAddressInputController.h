//
//  BrowserAddressInputController.h
//  Eingabe für die Adressleiste: Systemsuche (UISearchController) mit einzeiliger Tastatur direkt unter der
//  Leiste. Sie ist sofort fokussiert, die Siri-Taste diktiert also ohne weiteren Klick (Hinweis
//  „zum Diktieren … halten“ vom System). Der Hintergrund bleibt durchsichtig, die Aufklapp-Karte darunter sichtbar.
//  Ersetzt den früheren Eingabedialog (UIAlertController mit Vollbild-Tastatur).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Wie die Eingabe endete.
typedef NS_ENUM(NSInteger, BrowserAddressInputEnd) {
    BrowserAddressInputEndCancelled,   ///< Menü oder von außen geschlossen: Bearbeiten-Zustand ganz beenden
    BrowserAddressInputEndToTiles,     ///< Fokus nach unten aus der Tastatur: Tastatur zu, Karte bleibt (Zeiger auf Kacheln)
    BrowserAddressInputEndSubmitted,   ///< Text bestätigt (Diktat, Knopf „Öffnen“/„Suchen“)
};

@interface BrowserAddressInputController : UIViewController

/// Glasfläche der Leiste in Fensterkoordinaten: Die Tastaturkarte liegt darunter in derselben Breite.
@property (nonatomic) CGRect barFrame;

/// Wird genau einmal gerufen, wenn die Eingabe endet; text nur bei Submitted. Der Controller ist dann
/// bereits geschlossen bzw. schließt sich gerade.
@property (nonatomic, copy, nullable) void (^endHandler)(BrowserAddressInputEnd end, NSString *_Nullable text);

/// Die Tastaturkarte wächst mit Text um den Knopf „Los“ bzw. schrumpft zurück: neuer Platzbedarf samt Abstand.
@property (nonatomic, copy, nullable) void (^keyboardAreaHeightHandler)(CGFloat height);

/// Platz unter der Leiste für die Tastaturkarte samt Abstand (so weit rückt die Aufklapp-Karte nach unten).
@property (class, nonatomic, readonly) CGFloat keyboardAreaHeight;

/// Text einsetzen wie ein Diktat (ganzer Satz auf einmal), für den Selbsttest.
- (void)insertDictatedText:(NSString *)text;

/// Aktueller Text der Suchzeile.
@property (nonatomic, readonly) NSString *text;

#if DEBUG
/// Selbsttest: Fokus auf das Feld unter der Tastatur lenken (wie Wischen nach unten).
- (void)debugMoveFocusBelowKeyboard;
#endif

/// Schließen ohne Rückruf an endHandler (der Host beendet den Zustand selbst).
- (void)closeSilentlyAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
