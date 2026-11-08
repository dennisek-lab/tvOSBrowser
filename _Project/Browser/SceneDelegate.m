#import "SceneDelegate.h"
#import "AppDelegate.h"
#import "BrowserDNSProxy.h"
#import "BrowserWebView.h"

@implementation SceneDelegate

- (AppDelegate *)appDelegate {
    return (AppDelegate *)UIApplication.sharedApplication.delegate;
}

- (void)sceneWillResignActive:(UIScene *)scene {
    [[self appDelegate] saveCookiesToDefaults];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    [[self appDelegate] saveCookiesToDefaults];
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Läuft nichts mehr (tvOS kann Sockets im Hintergrund schließen), neu starten und neuen Port setzen.
    if ([[BrowserDNSProxy sharedProxy] startAndWaitWithTimeout:1.0]) {
        [[BrowserDNSProxy sharedProxy] applyToWebsiteDataStore:[BrowserWebView defaultWebsiteDataStore]];
    }
    [[self appDelegate] restoreCookiesFromDefaults];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    [[self appDelegate] restoreCookiesFromDefaults];
}

@end
