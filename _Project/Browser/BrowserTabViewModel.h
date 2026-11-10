#import <UIKit/UIKit.h>

@interface BrowserTabViewModel : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy) NSString *requestURL;
@property (nonatomic, copy) NSString *previousURL;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *URLString;
@property (nonatomic, strong) UIImage *snapshotImage;
@property (nonatomic) CGPoint savedScrollOffset;
@property (nonatomic) BOOL hasSavedScrollOffset;
@property (nonatomic) BOOL needsScrollRestore;
/// Zeitpunkt, zu dem der Tab geöffnet wurde (Sekunden seit 1970, Wanduhr; bleibt über Neustarts erhalten).
@property (nonatomic) NSTimeInterval openedAt;
/// Der Nutzer hat den Tab angezeigt oder darin etwas getan. Nur unbenutzte Tabs (Pop-ups und Links, die im
/// Hintergrund geöffnet wurden) schließen sich nach Ablauf von selbst. Neue Tabs gelten als benutzt, ebenso Tabs aus
/// alten Sitzungen ohne diesen Eintrag.
@property (nonatomic) BOOL userInteracted;
/// Zuletzt angezeigt (Sekunden seit 1970, 0 = nie). Bestimmt, welche Tabs ihre WebView behalten: nur die zuletzt
/// benutzten fünf bleiben geladen, ältere werden entladen und beim nächsten Anzeigen neu geladen.
@property (nonatomic) NSTimeInterval lastActivatedAt;
/// Anfrage eines Pop-ups bzw. Links mit target=_blank, das noch nicht geladen wurde (lädt erst beim ersten Anzeigen,
/// so bleiben z. B. POST-Daten erhalten). Wird nicht gespeichert; nach einem Neustart lädt der Tab seine Adresse.
@property (nonatomic, strong) NSURLRequest *pendingRequest;

- (instancetype)initWithSessionRepresentation:(NSDictionary *)sessionRepresentation;
- (NSDictionary *)sessionRepresentation;

@end
