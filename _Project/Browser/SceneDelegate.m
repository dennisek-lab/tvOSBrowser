#import "SceneDelegate.h"
#import "AppDelegate.h"

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
    [[self appDelegate] restoreCookiesFromDefaults];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    [[self appDelegate] restoreCookiesFromDefaults];
}

@end
