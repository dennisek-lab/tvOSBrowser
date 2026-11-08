#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ergebnis einer Prüfung: ob neue Listen aktiv wurden, und ein Satz für den Nutzer.
typedef void (^BrowserFilterListCheckCompletion)(BOOL updated, NSString *message);

/// Aktualisiert die Werbeblocker-Listen (WebKit-Regelsätze und Scriptlets) ohne App-Update.
///
/// Quelle ist das GitHub-Release „filterlisten-latest“ (Workflow im öffentlichen Repo dennisek-lab/tvos-browser-filterlisten). Nach dem ersten
/// Seitenaufbau wird höchstens einmal am Tag `manifest.json` geladen; bei neuerem Stand werden die genannten Dateien
/// geladen, per SHA-256 geprüft, in Library/Caches/FilterLists abgelegt und erst nach erfolgreichem Kompilieren
/// (Regelsätze) bzw. Einlesen (Scriptlets) umgeschaltet. Bei jedem Fehler bleiben die bisherigen Listen aktiv.
/// Mitgelieferte Listen sind der Rückfall; der neuere Stand (generatedAt) gewinnt, auch nach einem App-Update.
/// Gesendet wird nur die HTTPS-Anfrage selbst (ohne Cookies, ohne Kennungen). Doku: docs/ERWEITERUNGEN.md, 6.10.
///
/// DEBUG: `FILTERLIST_URL=<Manifest-URL>` ersetzt die Quelle (auch http://127.0.0.1…),
/// `FILTERLIST_CHECK_NOW=1` prüft kurz nach dem ersten Seitenaufbau ohne Tagesgrenze.
@interface BrowserFilterListUpdater : NSObject

+ (instancetype)sharedUpdater;

/// Formatversion, die diese App versteht (Manifest: minAppFormat darf nicht größer sein).
@property (class, nonatomic, readonly) NSInteger appFormat;

/// Regelsatz-Stand, den BrowserContentBlocker beim Start verwenden soll:
/// @{@"directory": NSURL, @"manifest": NSDictionary, @"downloaded": NSNumber}. Heruntergeladene Listen nur, wenn sie
/// vollständig vorliegen und neuer sind als die mitgelieferten. Darf von jedem Thread aufgerufen werden.
- (nullable NSDictionary *)preferredContentBlockerSet;

/// Mitgelieferter Regelsatz-Stand (Rückfall), Aufbau wie preferredContentBlockerSet.
- (nullable NSDictionary *)bundledContentBlockerSet;

/// Datei der Scriptlet-Regeln (scriptlets.json.z), heruntergeladen oder mitgeliefert, nach derselben Regel.
/// downloaded gibt an, ob es die heruntergeladene ist. Darf von jedem Thread aufgerufen werden.
- (nullable NSURL *)preferredScriptletsFileURLDownloaded:(nullable BOOL *)downloaded;

/// Heruntergeladene Listen sind unbrauchbar (Datei fehlt, Kompilieren schlägt fehl): verwerfen, damit der nächste
/// Start die mitgelieferten nimmt und bald neu geprüft wird.
- (void)discardDownloadedContentBlocker;
- (void)discardDownloadedScriptlets;

/// Von BrowserWebView nach jedem fertigen Seitenaufbau: stößt bei Fälligkeit (einmal am Tag) verzögert eine Prüfung an.
- (void)pageDidFinishLoading;

/// Sofort prüfen (Seitenleiste „Filterlisten aktualisieren“), ohne Tagesgrenze. Completion auf dem Hauptthread.
- (void)checkNowWithCompletion:(nullable BrowserFilterListCheckCompletion)completion;

@property (nonatomic, readonly, getter=isChecking) BOOL checking;

/// Stand der aktiven Regelsätze (generatedAt), nil wenn unbekannt.
@property (nonatomic, readonly, nullable) NSDate *activeListsDate;

/// „08.11.2026“ für Anzeigen.
+ (NSString *)displayStringForDate:(nullable NSDate *)date;

@end

NS_ASSUME_NONNULL_END
