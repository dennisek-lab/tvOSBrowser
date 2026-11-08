#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Erweiterte Werbeblocker-Regeln (Scriptlets und prozedurales CSS), die der WebKit-Content-Blocker nicht kann.
/// Die Regeln liegen als Domain->Regeln-Zuordnung im Paket (Scriptlets/, erzeugt von tools/build_scriptlets.py).
/// Je Navigation wird nur ein WKUserScript mit den Regeln für die Hosts der aktuellen Seite (Hauptframe und
/// Unterframes) eingespielt: document-start, alle Frames, Seitenwelt. Jeder Frame wendet die Regeln seines Hosts an.
/// Der Schalter „Werbeblocker“ und die Ausnahme pro Seite von BrowserContentBlocker schalten auch die Scriptlets ab.
@interface BrowserScriptletInjector : NSObject

+ (instancetype)sharedInjector;

/// Lädt die Regeln im Hintergrund (einmalig). Spätestens die erste Navigation wartet darauf.
- (void)prepare;

/// Vor jeder Navigation aufrufen (Haupt- und Unterframes, aus decidePolicyForNavigationAction). Bei einer
/// Hauptframe-Navigation wird das Skript für den neuen Host gebaut, bei Unterframes um deren Host ergänzt, falls
/// für ihn Regeln existieren. Ändert sich nichts, bleibt das Skript stehen.
- (void)updateUserContentController:(id)userContentController
                 forNavigationToURL:(nullable NSURL *)url
                          mainFrame:(BOOL)mainFrame;

/// Anzahl Scriptlet- und CSS-Regeln, die für einen Host gelten (für Tests und Statusanzeigen).
- (NSUInteger)ruleCountForHost:(nullable NSString *)host;

@end

NS_ASSUME_NONNULL_END
