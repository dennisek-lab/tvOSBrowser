#import "SceneDelegate.h"
#import "AppDelegate.h"
#import "BrowserDNSProxy.h"
#import "BrowserPerf.h"
#import "BrowserWebView.h"

@implementation SceneDelegate

- (AppDelegate *)appDelegate {
    return (AppDelegate *)UIApplication.sharedApplication.delegate;
}

- (void)sceneWillResignActive:(UIScene *)scene {
    BrowserPerfLog(@"sceneWillResignActive");
    [[self appDelegate] saveCookiesToDefaults];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    BrowserPerfLog(@"sceneDidEnterBackground");
    [[self appDelegate] saveCookiesToDefaults];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    BrowserPerfLog(@"sceneWillEnterForeground");
    // Läuft nichts mehr (tvOS kann Sockets im Hintergrund schließen), neu starten und neuen Port setzen.
    if ([[BrowserDNSProxy sharedProxy] startAndWaitWithTimeout:1.0]) {
        [[BrowserDNSProxy sharedProxy] applyToWebsiteDataStore:[BrowserWebView defaultWebsiteDataStore]];
    }
    [[self appDelegate] restoreCookiesFromDefaults];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    BrowserPerfLog(@"sceneDidBecomeActive");
    [[self appDelegate] restoreCookiesFromDefaults];
}

@end
