#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#if DEBUG
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#endif

NSString * const BrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";
/// Menü-Druck, der im nativen Player begann: Schließt der Player sich damit (AVKit oder ViewController), den Rest
/// des Drucks verwerfen. Sonst landet das Ende nach dem Schließen bei der Seite und blättert sie zurück.
static BOOL sBrowserMenuPressBeganInNativePlayer = NO;

static NSString *BrowserPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

static UIViewController *BrowserFindViewControllerOfClass(UIViewController *viewController, Class targetClass) {
    if (viewController == nil || targetClass == Nil) {
        return nil;
    }

    if ([viewController isKindOfClass:targetClass]) {
        return viewController;
    }

    if (viewController.presentedViewController != nil) {
        UIViewController *match = BrowserFindViewControllerOfClass(viewController.presentedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    for (UIViewController *childViewController in viewController.childViewControllers) {
        UIViewController *match = BrowserFindViewControllerOfClass(childViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(navigationController.visibleViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabBarController = (UITabBarController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(tabBarController.selectedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

static UIViewController *BrowserFindPresentedNativeVideoPlayerViewController(UIApplication *application, Class nativeVideoPlayerClass) {
    for (UIWindow *window in application.windows) {
        if (window.hidden || window.rootViewController == nil) {
            continue;
        }

        UIViewController *match = BrowserFindViewControllerOfClass(window.rootViewController, nativeVideoPlayerClass);
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

@interface UIApplication (BrowserSelectPressForwarding)

- (void)browser_sendEvent:(UIEvent *)event;

@end

@implementation UIApplication (BrowserSelectPressForwarding)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalMethod = class_getInstanceMethod(self, @selector(sendEvent:));
        Method replacementMethod = class_getInstanceMethod(self, @selector(browser_sendEvent:));
        if (originalMethod != NULL && replacementMethod != NULL) {
            method_exchangeImplementations(originalMethod, replacementMethod);
        }
    });
}

/// Der native Player (`AVPlayerViewController`) bekommt alle Tasten und Berührungen unverändert: Klick, Pfeile,
/// Wischen und Menü bedient AVKit selbst (Transportleiste mit Untertitel-/Audio-Knöpfen, Infobereich, Spulen,
/// Menü schließt erst offene Bereiche, dann den Player). Früher wurden hier Klick (→ Pause), Links/Rechts
/// (→ ±5 s), horizontales Wischen (→ Spulen) und der Beginn von Menü (→ Player schließen) abgefangen; damit kam
/// man nie an die Menüs der Transportleiste. Übrig bleibt nur: den Rest eines Menü-Drucks verwerfen, der den
/// Player geschlossen hat, und nach jedem Klick außerhalb des Players die Mitteilung für die Seite.
- (void)browser_sendEvent:(UIEvent *)event {
    if (event.type != UIEventTypePresses) {
        [self browser_sendEvent:event];
        return;
    }

    SEL allPressesSelector = NSSelectorFromString(@"allPresses");
    if (![event respondsToSelector:allPressesSelector]) {
        [self browser_sendEvent:event];
        return;
    }

    Class nativeVideoPlayerClass = NSClassFromString(@"BrowserNativeVideoPlayerViewController");
    UIViewController *nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);
    NSSet<UIPress *> *presses = ((id (*)(id, SEL))objc_msgSend)(event, allPressesSelector);
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
            NSLog(@"[InputTrace][App] press=%@ phase=%@ top=%@",
                  BrowserPressTypeString(press.type),
                  BrowserPressPhaseString(press.phase),
                  nativeVideoPlayerViewController == nil ? @"(nil)" : NSStringFromClass([nativeVideoPlayerViewController class]));
        }
        if (press.type != UIPressTypeMenu) {
            continue;
        }
        if (press.phase == UIPressPhaseBegan) {
            sBrowserMenuPressBeganInNativePlayer = (nativeVideoPlayerViewController != nil);
            continue;
        }
        if (!sBrowserMenuPressBeganInNativePlayer || press.phase == UIPressPhaseStationary) {
            continue;
        }
        BOOL finished = press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled;
        if (finished) {
            sBrowserMenuPressBeganInNativePlayer = NO;
        }
        if (nativeVideoPlayerViewController == nil) {
            NSLog(@"[InputTrace][App] swallow Menu %@ after native player", BrowserPressPhaseString(press.phase));
            return;
        }
    }

    [self browser_sendEvent:event];

    if (nativeVideoPlayerViewController != nil) {
        return;
    }
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            NSLog(@"[InputTrace][App] post BrowserGlobalSelectPressEndedNotification");
            // Zeitstempel des Drucks mitgeben: Derselbe Druck kommt meist auch direkt (pressesEnded) an und darf
            // nur einmal wirken, egal wie lange der erste Klick den Hauptthread belegt hat.
            NSDictionary *info = @{@"timestamp": @(press.timestamp)};
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalSelectPressEndedNotification object:nil userInfo:info];
            });
            break;
        }
    }
}

@end

#if DEBUG
/// Selbsttest `hid:`: Tastendruck wie von der Fernbedienung über den echten Ereignisweg von UIKit
/// (`_pressesEventForWindow:` + `_prepareButtonEvent:…` → `sendEvent:` → Fokus → z. B. AVKit), nicht direkt an einen
/// Responder wie `press:`. Nur DEBUG, private Methoden. Tasten: up, down, left, right, select, menu, playpause;
/// `@ms` hält die Taste (Vorgabe 90 ms).
@implementation UIApplication (BrowserSelfTestHID)

+ (BOOL)browser_selfTestSendHIDKey:(NSString *)spec {
    NSArray<NSString *> *parts = [spec componentsSeparatedByString:@"@"];
    NSDictionary<NSString *, NSNumber *> *types = @{
        @"right": @(UIPressTypeRightArrow), @"left": @(UIPressTypeLeftArrow), @"down": @(UIPressTypeDownArrow),
        @"up": @(UIPressTypeUpArrow), @"select": @(UIPressTypeSelect), @"menu": @(UIPressTypeMenu),
        @"playpause": @(UIPressTypePlayPause),
    };
    NSNumber *type = types[parts.firstObject ?: @""];
    NSTimeInterval hold = parts.count > 1 ? parts[1].doubleValue / 1000.0 : 0.09;
    UIApplication *application = UIApplication.sharedApplication;
    SEL eventForWindow = NSSelectorFromString(@"_pressesEventForWindow:");
    SEL prepare = NSSelectorFromString(@"_prepareButtonEvent:type:phase:timestamp:contextID:");
    SEL finish = NSSelectorFromString(@"_finishButtonEvent:");
    UIWindow *window = nil;
    for (UIScene *scene in application.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                }
            }
        }
    }
    if (type == nil || window == nil || ![application respondsToSelector:eventForWindow] || ![application respondsToSelector:prepare]) {
        NSLog(@"[SelfTest] hid %@ nicht möglich (Fenster=%d)", spec, window != nil);
        return NO;
    }
    unsigned int contextID = ((unsigned int (*)(id, SEL))objc_msgSend)(window, NSSelectorFromString(@"_contextId"));
    void (^send)(UIPressPhase) = ^(UIPressPhase phase) {
        id event = ((id (*)(id, SEL, id))objc_msgSend)(application, eventForWindow, window);
        BOOL prepared = ((BOOL (*)(id, SEL, id, long, long, double, unsigned int))objc_msgSend)(
            application, prepare, event, type.longValue, (long)phase, CACurrentMediaTime(), contextID);
        if (!prepared) {
            NSLog(@"[SelfTest] hid %@ Phase %ld nicht vorbereitet", spec, (long)phase);
            return;
        }
        // Ohne HID-Ereignis stürzt UIKit bei Menü ab (_sendEventToGameControllerObserver: CFRetain(NULL)).
        void *(*createKeyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t) =
            dlsym(RTLD_DEFAULT, "IOHIDEventCreateKeyboardEvent");
        SEL setHID = NSSelectorFromString(@"_setHIDEvent:");
        if (createKeyboard != NULL && [event respondsToSelector:setHID]) {
            uint32_t usage = 0x40 + (uint32_t)MIN(type.longValue, 5);  // Consumer-Seite: Menü 0x40 … rechts 0x45
            if (type.longValue == UIPressTypePlayPause) {
                usage = 0xCD;
            }
            void *hid = createKeyboard(kCFAllocatorDefault, mach_absolute_time(), 0x0C, usage, phase == UIPressPhaseBegan, 0);
            if (hid != NULL) {
                ((void (*)(id, SEL, void *))objc_msgSend)(event, setHID, hid);
                CFRelease(hid);
            }
        }
        [application sendEvent:event];
        if (phase == UIPressPhaseEnded && [application respondsToSelector:finish]) {
            ((void (*)(id, SEL, id))objc_msgSend)(application, finish, event);
        }
    };
    send(UIPressPhaseBegan);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        send(UIPressPhaseEnded);
    });
    return YES;
}

@end
#endif
