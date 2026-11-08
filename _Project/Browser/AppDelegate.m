//
//  AppDelegate.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "AppDelegate.h"
#import "BrowserDNSProxy.h"
#import "BrowserFeasibilityProbe.h"
#import "BrowserPerf.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (void)restoreCookiesFromDefaults {
    NSData *cookieData = [[NSUserDefaults standardUserDefaults] objectForKey:@"ApplicationCookie"];
    if (cookieData.length == 0) {
        return;
    }
#if DEBUG
    CFTimeInterval perfStart = CACurrentMediaTime();
#endif
    [BrowserWebView restoreCookiesFromData:cookieData];
#if DEBUG
    BrowserPerfLog(@"Cookies wiederhergestellt: %lu Bytes, %.0f ms", (unsigned long)cookieData.length, (CACurrentMediaTime() - perfStart) * 1000.0);
#endif
}

- (void)saveCookiesToDefaults {
#if DEBUG
    CFTimeInterval perfStart = CACurrentMediaTime();
#endif
    NSData *cookieData = [BrowserWebView cookieDataRepresentation];
#if DEBUG
    BrowserPerfLog(@"Cookies gelesen: %lu Bytes, %.0f ms", (unsigned long)cookieData.length, (CACurrentMediaTime() - perfStart) * 1000.0);
#endif
    if (cookieData == nil) {
        return;
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:cookieData forKey:@"ApplicationCookie"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	// Override point for customization after application launch.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"MobileMode"]) {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.mobileUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    else {
        [[NSUserDefaults standardUserDefaults] setObject:BrowserPreferencesStore.desktopUserAgent forKey:@"UserAgent"];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"MobileMode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
#if DEBUG
    BrowserPerfStartStallMonitorIfRequested();
    CFTimeInterval perfStart = CACurrentMediaTime();
#endif
    [[BrowserDNSProxy sharedProxy] startAndWaitWithTimeout:1.0];
#if DEBUG
    CFTimeInterval perfProxy = CACurrentMediaTime();
#endif
    [self restoreCookiesFromDefaults];
#if DEBUG
    BrowserPerfLog(@"didFinishLaunching: DNS-Proxy %.0f ms, Cookies %.0f ms", (perfProxy - perfStart) * 1000.0, (CACurrentMediaTime() - perfProxy) * 1000.0);
#endif
    [BrowserFeasibilityProbe runIfRequested];
	return YES;
}

// Aktiv/Hintergrund-Wechsel laufen ab tvOS 27 über SceneDelegate.

- (void)applicationWillTerminate:(UIApplication *)application {
	// Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [self saveCookiesToDefaults];
}

@end
