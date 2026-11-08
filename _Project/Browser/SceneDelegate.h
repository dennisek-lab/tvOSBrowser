#import <UIKit/UIKit.h>

/// Ab tvOS 27 startet UIKit Apps ohne UIScene-Lebenszyklus nicht mehr.
/// Das Fenster kommt aus dem Main-Storyboard (UISceneStoryboardFile in der Info.plist).
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (strong, nonatomic) UIWindow *window;

@end
