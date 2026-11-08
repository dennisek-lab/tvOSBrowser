#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPreferencesStore : NSObject

+ (NSString *)desktopUserAgent;
+ (NSString *)mobileUserAgent;

@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic) BOOL mobileModeEnabled;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) NSUInteger textFontSize;
@property (nonatomic) BOOL fullscreenVideoPlaybackEnabled;
@property (nonatomic) BOOL scalePagesToFit;
/// Videos der Seite automatisch im nativen Player öffnen, sobald sie starten. Standard: ja.
@property (nonatomic) BOOL autoOpenVideosInNativePlayer;
/// Grundzoom für alle Seiten (1.0 = 100 %). Standard 1.5, begrenzt auf 0.5 bis 3.0.
@property (nonatomic) double pageZoom;
@property (nonatomic) BOOL dontShowHintsOnLaunch;
@property (nonatomic, copy) NSString *homePageURLString;
/// Werbeblocker (Standard: an) und Seiten, für die er abgeschaltet ist (Hosts ohne „www.“).
@property (nonatomic) BOOL adBlockEnabled;
@property (nonatomic, copy) NSArray<NSString *> *adBlockExceptionHosts;
/// Werbeblocker bei erkannter Adblock-Sperre automatisch für die Seite pausieren (Standard: an) und die so gesetzten Hosts
/// (Teilmenge von adBlockExceptionHosts, zur Unterscheidung von Ausnahmen des Nutzers).
@property (nonatomic) BOOL adBlockAutoPauseOnWall;
@property (nonatomic, copy) NSArray<NSString *> *adBlockAutoExceptionHosts;
/// Automatisches Ablehnen von Cookie-Bannern (Standard: an) und Seiten, für die es abgeschaltet ist (Hosts ohne „www.“).
@property (nonatomic) BOOL cookieBannerBlockEnabled;
@property (nonatomic, copy) NSArray<NSString *> *cookieBannerExceptionHosts;
/// Bezahlschranken („Mit Werbung weiterlesen oder Abo“): zustimmen, damit kein Banner stehen bleibt. Standard: an.
@property (nonatomic) BOOL cookieBannerAcceptPayWalls;
/// Einrasten des Zeigers: umlaufender Regenbogen-Glow (Standard) statt einfarbigem Leuchten.
@property (nonatomic) BOOL rainbowGlowEnabled;
/// Liquid-Glass-Animationen (Federn, Glas materialisiert, Standard: an); aus: schlichte Überblendungen, s. BrowserMotion.
@property (nonatomic) BOOL liquidGlassAnimationsEnabled;

- (void)ensureUserAgentConsistency;

@end

NS_ASSUME_NONNULL_END
