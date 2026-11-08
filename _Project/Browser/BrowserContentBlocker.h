#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Werbeblocker auf Basis von WKContentRuleList (nur per Laufzeit angesprochen).
/// Die Regelsätze liegen als Dateien im Paket (ContentBlocker/, erzeugt von tools/build_adblock_rules.py) und
/// werden beim ersten Start in einen WKContentRuleListStore unter Library/Caches kompiliert. Der Kennung
/// hängt ein Hash des Inhalts an, sodass nur bei geänderten Listen neu kompiliert wird. Räumt tvOS die Caches
/// auf, wird beim nächsten Start einfach neu kompiliert. Neuere Listen lädt BrowserFilterListUpdater ohne
/// App-Update nach; welcher Stand beim Start gilt, entscheidet dessen preferredContentBlockerSet.
@interface BrowserContentBlocker : NSObject

+ (instancetype)sharedBlocker;

/// Startet (einmalig) das asynchrone Nachschlagen bzw. Kompilieren. Wird von applyToUserContentController: miterledigt.
- (void)prepare;

/// Hängt alle fertigen Regelsätze an den WKUserContentController. Merkt sich den Controller (schwach) und
/// ergänzt später fertig kompilierte Regelsätze automatisch.
- (void)applyToUserContentController:(id)userContentController;

/// Vor einer Hauptframe-Navigation aufrufen: nimmt die Regelsätze weg, wenn für die Zielseite eine Ausnahme gilt
/// (bzw. hängt sie wieder an). Regelsätze lassen sich nur ganz oder gar nicht anwenden, weil `ignore-previous-rules`
/// nicht über Regelsätze hinweg wirkt.
- (void)updateUserContentController:(id)userContentController forNavigationToURL:(nullable NSURL *)url;

/// Nach Änderung des Schalters: alle bekannten Controller neu bestücken.
- (void)preferencesDidChange;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// Anzahl bereits angewendbarer Regelsätze und Gesamtzahl, für Statusanzeigen.
@property (nonatomic, readonly) NSUInteger readyListCount;
@property (nonatomic, readonly) NSUInteger totalListCount;

/// Stand der verwendeten Regelsätze (generatedAt des Manifests, Unix-Sekunden; 0 = unbekannt) und Version.
@property (nonatomic, readonly) NSTimeInterval activeGeneratedAt;
@property (nonatomic, readonly, nullable) NSDate *activeListsDate;
@property (nonatomic, readonly, nullable) NSString *activeVersion;
@property (nonatomic, readonly) BOOL activeListsDownloaded;

/// Neuer Listenstand (BrowserFilterListUpdater): kompiliert alle Regelsätze aus `directory` vollständig in den Store
/// und schaltet erst danach alle Tabs in einem Schritt um. Bei einem Fehler bleibt der bisherige Stand aktiv
/// (completion NO mit Grund). Wartet, bis ein laufender Durchgang fertig ist. Hauptthread.
- (void)installListSetAtDirectory:(NSURL *)directory
                         manifest:(NSDictionary *)manifest
                       completion:(void (^)(BOOL ok, NSString * _Nullable error))completion;

/// Host (ohne „www.“) einer URL, wie er in der Ausnahmeliste steht.
+ (nullable NSString *)exceptionKeyForURL:(nullable NSURL *)url;
- (BOOL)isExceptionForURL:(nullable NSURL *)url;
- (void)setException:(BOOL)exception forURL:(nullable NSURL *)url;
/// Die Ausnahme dieser Seite stammt von der automatischen Adblock-Sperren-Erkennung (Liste adBlockAutoExceptionHosts).
- (BOOL)isAutoExceptionForURL:(nullable NSURL *)url;

@end

NS_ASSUME_NONNULL_END
