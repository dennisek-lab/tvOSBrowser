//
//  ViewController.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "BrowserAddressPanelView.h"
#import "BrowserCommandParser.h"
#import "BrowserCommandRouter.h"
#import "BrowserContentBlocker.h"
#import "BrowserGuideViewController.h"
#import "BrowserSetupViewController.h"
#import "BrowserCookieConsentBlocker.h"
#import "BrowserDNSProxy.h"
#import "BrowserPerf.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import "BrowserHistoryStore.h"
#import "BrowserIntelligence.h"
#import "BrowserIntelligenceController.h"
#import "BrowserMenuCoordinator.h"
#import "BrowserMotion.h"
#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserNowPlayingController.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserReaderMode.h"
#import "BrowserRemoteInputController.h"
#import "BrowserSessionStore.h"
#import "BrowserAddressInputController.h"
#import "BrowserMotion.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "BrowserSpeechRecognizerStub.h"
#import "BrowserWhisperSpeechRecognizer.h"
#import "BrowserWebSubtitleController.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";
/// Spike Siri-Steuerung: BrowserAppIntents.swift schickt Befehle über diese Notification (siehe docs/SIRI_STEUERUNG.md).
static NSString * const kBrowserSiriCommandNotification = @"BrowserSiriCommandNotification";

@interface ViewController () <BrowserCommandHost, BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserCommandRouter *commandRouter;
@property (nonatomic) BrowserIntelligenceController *intelligenceController;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserNowPlayingController *nowPlayingController;
@property (nonatomic) CFTimeInterval lastFullscreenExitAttempt;
/// Offene Systemtastatur der Adressleiste (nil = zu). Gehört zum Bearbeiten-Zustand (addressPanel).
@property (nonatomic, nullable) BrowserAddressInputController *addressInput;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;
@property (nonatomic) CGFloat lastPageScrollOffset;
@property (nonatomic) CGFloat pageScrollTravel;
@property (nonatomic) NSUInteger readerCheckGeneration;
/// Adressleiste im Bearbeiten-Zustand: Aufklapp-Bereich mit Favoriten, Oft besucht, Zuletzt (nil = geschlossen).
@property (nonatomic, nullable) BrowserAddressPanelView *addressPanel;
/// Untertitel für Videos in der Webseite (Weg B), angelegt beim ersten Einschalten.
@property (nonatomic, nullable) BrowserWebSubtitleController *webSubtitleController;
/// Hinweis, falls die Web-Untertitel nur mit dem Platzhalter laufen (kein whisper/Modell), sonst nil.
@property (nonatomic, copy, nullable) NSString *webSubtitleRecognizerHint;

@end

#if DEBUG
/// Selbsttest `press:`: künstliche Taste (Typ und Phase fest), geht wie eine echte an den fokussierten Responder
/// und läuft von dort die Responder-Kette hoch. Gestenerkenner (z. B. Menü im UIAlertController) und
/// UIApplication sendEvent: sehen sie nicht.
@interface BrowserSelfTestPress : UIPress
@property (nonatomic) UIPressType selfTestType;
@property (nonatomic) UIPressPhase selfTestPhase;
@property (nonatomic) NSTimeInterval selfTestTimestamp;
@end

@implementation BrowserSelfTestPress
- (UIPressType)type { return self.selfTestType; }
- (UIPressPhase)phase { return self.selfTestPhase; }
- (NSTimeInterval)timestamp { return self.selfTestTimestamp; }
@end

#import <mach/mach.h>

/// Eigener Speicher (phys_footprint wie `footprint`/Jetsam) in MB, -1 bei Fehler.
static double BrowserSelfTestFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1.0;
    }
    return info.phys_footprint / (1024.0 * 1024.0);
}

/// Geschlossene WebViews (schwach gehalten): bleiben welche am Leben, ist irgendwo ein Zyklus.
static NSHashTable<BrowserWebView *> *BrowserSelfTestClosedWebViews(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}
#endif

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    BrowserPerfLog(@"viewDidLoad Beginn");
    self.definesPresentationContext = YES;
    self.scrollViewAllowBounces = YES;

    self.preferencesStore = [BrowserPreferencesStore new];
    [self.preferencesStore ensureUserAgentConsistency];

    self.viewModel = [BrowserViewModel new];
    self.viewModel.topNavigationBarVisible = self.preferencesStore.topNavigationBarVisible;
    self.viewModel.textFontSize = self.preferencesStore.textFontSize;
    self.viewModel.fullscreenVideoPlaybackEnabled = self.preferencesStore.fullscreenVideoPlaybackEnabled;

    self.commandRouter = [[BrowserCommandRouter alloc] initWithHost:self];
    __weak typeof(self) weakIntelligenceSelf = self;
    self.intelligenceController = [[BrowserIntelligenceController alloc] initWithContainerProvider:^UIView *{
        return weakIntelligenceSelf.view.window ?: weakIntelligenceSelf.view;
    } webViewProvider:^BrowserWebView *{
        return weakIntelligenceSelf.webview;
    } feedbackHandler:^(NSString *text, NSString *symbolName, BOOL success) {
        [weakIntelligenceSelf.commandRouter showFeedback:text symbolName:symbolName success:success];
    }];
    self.domInteractionService = [BrowserDOMInteractionService new];
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.nowPlayingController = [BrowserNowPlayingController new];
    __weak typeof(self) weakNowPlayingSelf = self;
    self.nowPlayingController.commandHandler = ^(NSString *command) {
        [weakNowPlayingSelf.webview sendVideoCommand:command];
    };
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
    [self.view addSubview:self.remoteInputController.cursorView];
    self.videoPlaybackCoordinator = [[BrowserVideoPlaybackCoordinator alloc] initWithHost:self
                                                                      domInteractionService:self.domInteractionService];
    self.tabCoordinator = [[BrowserTabCoordinator alloc] initWithHost:self
                                                             viewModel:self.viewModel
                                                      preferencesStore:self.preferencesStore
                                                     navigationService:self.navigationService
                                                          sessionStore:self.sessionStore
                                                    browserContainerView:self.browserContainerView
                                                              rootView:self.view
                                                            topMenuView:self.topMenuView
                                                            cursorView:self.remoteInputController.cursorView
                                               manualScrollPanRecognizer:self.remoteInputController.manualScrollPanRecognizer
                                                           webViewDelegate:self
                                                       scrollViewAllowBounces:self.scrollViewAllowBounces];
    self.tabOverviewController = [[BrowserTabOverviewController alloc] initWithHost:self
                                                                            viewModel:self.viewModel
                                                                             rootView:self.view
                                                                           topMenuView:self.topMenuView
                                                                           cursorView:self.remoteInputController.cursorView];
    self.pageActionCoordinator = [[BrowserPageActionCoordinator alloc] initWithHost:self
                                                               domInteractionService:self.domInteractionService
                                                                   navigationService:self.navigationService
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator];

    self.topMenuView.delegate = self;
    self.topMenuView.loadingSpinner.hidesWhenStopped = YES;
    self.remoteInputController.cursorView.hidden = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalSelectPressEndedNotification:)
                                                 name:kBrowserGlobalSelectPressEndedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSiriCommandNotification:)
                                                 name:kBrowserSiriCommandNotification
                                               object:nil];

    BrowserPerfLog(@"viewDidLoad Dienste angelegt");
    [self.tabCoordinator restoreInitialStateOrCreateFirstTab];
    BrowserPerfLog(@"viewDidLoad Ende (Tab angelegt)");
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    BrowserPerfLog(@"viewDidAppear");
    [self.tabCoordinator webViewDidAppear];
    if (!self.displayedHintsOnLaunch) {
        // Neue Fassung: einmal „Was ist neu“, sonst wie gewohnt die Bedienungshilfe (abschaltbar).
        NSString *seen = [NSUserDefaults.standardUserDefaults stringForKey:@"WhatsNewSeenVersion"];
        if (!self.preferencesStore.setupCompleted) {
            // Erster Start (oder Einrichtung noch nie abgeschlossen): erst einrichten, danach die Bedienungshilfe.
            [self showSetup];
        } else if (![seen isEqualToString:BrowserGuideViewController.whatsNewVersion]) {
            [NSUserDefaults.standardUserDefaults setObject:BrowserGuideViewController.whatsNewVersion forKey:@"WhatsNewSeenVersion"];
            [self showWhatsNew];
        } else if (!self.preferencesStore.dontShowHintsOnLaunch) {
            [self showHintsAlert];
        }
    }
    self.displayedHintsOnLaunch = YES;
    [self startWebSubtitlesIfEnabled];
#if DEBUG
    [self runPointerSelfTestIfRequested];
#endif
}

#if DEBUG
/// Selbsttest ohne Fernbedienung: POINTER_SELFTEST="x,y;x,y;…" fährt die Punkte im Abstand von 3 s ab.
/// Ein Punkt "click" löst einen Klick aus. Vorher werden offene Hinweise geschlossen.
- (void)runPointerSelfTestIfRequested {
    NSString *spec = NSProcessInfo.processInfo.environment[@"POINTER_SELFTEST"];
    static BOOL started = NO;
    if (spec.length == 0 || started) {
        return;
    }
    started = YES; // viewDidAppear kommt nach jedem geschlossenen Dialog erneut
    // Lange Testläufe ohne Eingabe: sonst startet der Bildschirmschoner und hält die App an.
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    NSArray<NSString *> *steps = [spec componentsSeparatedByString:@";"];
    // Abstand der Schritte in Sekunden (Vorgabe 3), für Stresstests kürzer: POINTER_SELFTEST_INTERVAL=0.5
    double interval = [NSProcessInfo.processInfo.environment[@"POINTER_SELFTEST_INTERVAL"] doubleValue];
    if (interval <= 0.0) {
        interval = 3.0;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dismissViewControllerAnimated:NO completion:nil];
        [steps enumerateObjectsUsingBlock:^(NSString *step, NSUInteger index, __unused BOOL *stop) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((index * interval + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (index + 1 == steps.count) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        NSLog(@"[SelfTest] fertig %lu Schritte", (unsigned long)steps.count);
                    });
                }
                if ([self runStressSelfTestStep:step]) {
                    return;
                }
                if ([self.intelligenceController runSelfTestStep:step]) {
                    return; // ai, summarize, translate, translate:hint, translate:reset
                }
                if ([step isEqualToString:@"click"]) {
                    NSLog(@"[SelfTest] click");
                    [self browserHandlePrimaryAction];
                    return;
                }
                if ([step hasPrefix:@"url:"]) {
                    NSURL *url = [NSURL URLWithString:[step substringFromIndex:4]];
                    NSLog(@"[SelfTest] load %@", url);
                    if (url != nil) {
                        [self.webview loadRequest:[NSURLRequest requestWithURL:url]];
                    }
                    return;
                }
                if ([step hasPrefix:@"ring:"]) {
                    // ring:radius,grad,ms – Kreis im Uhrzeigersinn auf dem Clickpad (Radius in Einheiten, Rand = 1).
                    NSArray<NSString *> *args = [[step substringFromIndex:5] componentsSeparatedByString:@","];
                    if (args.count >= 3) {
                        [self.remoteInputController debugRunRingWithRadius:args[0].doubleValue degrees:args[1].doubleValue
                                                                  duration:args[2].doubleValue / 1000.0];
                    }
                    return;
                }
                if ([step hasPrefix:@"swipe:"]) {
                    // swipe:dx,dy,ms[,flick|clean|flickclean] – Strecke in Clickpad-Einheiten (ganze Breite = 2),
                    // Dauer in ms; flick: Loslassen in voller Fahrt, clean: ohne nachgebildete Hardware-Eigenheiten.
                    NSArray<NSString *> *args = [[step substringFromIndex:6] componentsSeparatedByString:@","];
                    if (args.count >= 3) {
                        NSString *flags = args.count >= 4 ? args[3] : @"";
                        [self.remoteInputController debugRunSwipeWithPadDelta:CGVectorMake(args[0].doubleValue, args[1].doubleValue)
                                                                     duration:args[2].doubleValue / 1000.0
                                                                        flick:[flags containsString:@"flick"]
                                                                    artifacts:![flags containsString:@"clean"]];
                    }
                    return;
                }
                if ([step isEqualToString:@"playpause"]) {
                    NSLog(@"[SelfTest] playpause overVideo=%d playing=%d", [self pointerIsOverVideo], self.webview.videoPlaying);
                    [self browserRemoteInputControllerHandlePlayPausePress];
                    return;
                }
                if ([step isEqualToString:@"left"] || [step isEqualToString:@"right"]) {
                    NSLog(@"[SelfTest] %@ overVideo=%d", step, [self pointerIsOverVideo]);
                    if ([step isEqualToString:@"left"]) {
                        [self browserRemoteInputControllerNavigateBack];
                    } else {
                        [self browserRemoteInputControllerNavigateForward];
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        NSLog(@"[SelfTest] Zeiger %@ scroll=%.0f", NSStringFromCGPoint(self.remoteInputController.cursorView.center), self.lastPageScrollOffset);
                    });
                    return;
                }
                if ([step hasPrefix:@"fill:"]) {
                    UIAlertController *alert = [self.presentedViewController isKindOfClass:UIAlertController.class] ? (UIAlertController *)self.presentedViewController : nil;
                    NSArray<NSString *> *values = [[step substringFromIndex:5] componentsSeparatedByString:@"|"];
                    NSLog(@"[SelfTest] fill alert=%@ fields=%lu types=%@", alert.title, (unsigned long)alert.textFields.count, [alert.textFields valueForKey:@"textContentType"]);
                    for (NSUInteger i = 0; i + 1 < values.count && i < alert.textFields.count; i++) {
                        alert.textFields[i].text = values[i];
                    }
                    NSInteger actionIndex = values.lastObject.integerValue;
                    if (alert != nil && actionIndex >= 0 && actionIndex < (NSInteger)alert.actions.count) {
                        UIAlertAction *action = alert.actions[actionIndex];
                        void (^handler)(UIAlertAction *) = [action valueForKey:@"handler"];
                        NSLog(@"[SelfTest] tap %@", action.title);
                        [alert dismissViewControllerAnimated:NO completion:^{
                            if (handler != nil) {
                                handler(action);
                            }
                        }];
                    }
                    return;
                }
                if ([step hasPrefix:@"siri:"]) {
                    // Befehl wie aus einem App Intent: siri:<befehl> oder siri:<befehl>|<argument>
                    NSArray<NSString *> *parts = [[step substringFromIndex:5] componentsSeparatedByString:@"|"];
                    NSMutableDictionary *info = [@{@"command": parts.firstObject ?: @"", @"source": @"selftest"} mutableCopy];
                    if (parts.count > 1) {
                        info[@"argument"] = parts[1];
                    }
                    NSLog(@"[SelfTest] siri %@", info[@"command"]);
                    [NSNotificationCenter.defaultCenter postNotificationName:kBrowserSiriCommandNotification object:nil userInfo:info];
                    return;
                }
                if ([step hasPrefix:@"cmd:"]) {
                    // Befehl direkt über den Router: cmd:<name> oder cmd:<name>|<argument>
                    NSArray<NSString *> *parts = [[step substringFromIndex:4] componentsSeparatedByString:@"|"];
                    NSLog(@"[SelfTest] cmd %@", step.length > 4 ? [step substringFromIndex:4] : @"");
                    [self.commandRouter performCommandNamed:parts.firstObject ?: @"" argument:parts.count > 1 ? parts[1] : nil source:BrowserCommandSourceSelfTest];
                    return;
                }
                if ([step hasPrefix:@"parse:"]) {
                    // Parser prüfen, ohne auszuführen: parse:<text>|<text>|…
                    for (NSString *text in [[step substringFromIndex:6] componentsSeparatedByString:@"|"]) {
                        NSString *line = [BrowserCommandParser describeParseOfText:text];
                        NSLog(@"[SelfTest] parse \"%@\" -> %@", text, line);
                        if ([line hasPrefix:@"keine"]) {
                            // Zweite Stufe wie im Diktat, nur loggen.
                            [BrowserIntelligence.sharedIntelligence matchCommandForText:text completion:^(BrowserCommandMatch *match) {
                                NSLog(@"[SelfTest] parse \"%@\" ähnlich: %@", text, match != nil ? match.logDescription : @"kommt nicht in Frage -> Suche");
                            }];
                        }
                    }
                    return;
                }
                if ([step hasPrefix:@"enter:"]) {
                    // Text wie aus dem Adressfeld bestätigt: Parser, dann Befehl oder Suche.
                    NSString *text = [step substringFromIndex:6];
                    NSLog(@"[SelfTest] enter %@", text);
                    [self handleEnteredAddressText:text];
                    return;
                }
                if ([step hasPrefix:@"dictate:"]) {
                    // Wie Diktat: Adresseingabe öffnen (falls zu) und den ganzen Satz auf einmal einsetzen.
                    NSString *spoken = [step substringFromIndex:8];
                    if (self.addressInput == nil) {
                        [self beginAddressEditing];
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        BrowserAddressInputController *input = self.addressInput;
                        NSLog(@"[SelfTest] dictate field=%@ text=%@", input != nil ? @"ok" : @"nil", spoken);
                        [input insertDictatedText:spoken];
                    });
                    return;
                }
                if ([step isEqualToString:@"gestures"]) {
                    NSArray *(^circle)(CGFloat, CGFloat, CGFloat) = ^NSArray *(CGFloat turns, CGFloat sign, CGFloat radius) {
                        NSMutableArray *deltas = [NSMutableArray array];
                        NSInteger count = (NSInteger)(turns * 48);
                        for (NSInteger i = 0; i < count; i++) {
                            CGFloat a0 = sign * 2 * M_PI * i / 48.0, a1 = sign * 2 * M_PI * (i + 1) / 48.0;
                            [deltas addObject:[NSValue valueWithCGPoint:CGPointMake(radius * (cos(a1) - cos(a0)), radius * (sin(a1) - sin(a0)))]];
                        }
                        return deltas;
                    };
                    NSMutableArray *line = [NSMutableArray array];
                    for (NSInteger i = 0; i < 80; i++) {
                        [line addObject:[NSValue valueWithCGPoint:CGPointMake(6.0, 2.5 * sin(i * 0.7))]];
                    }
                    NSLog(@"[SelfTest] gestures cw1.5=%ld ccw1=%ld line=%ld quarter=%ld",
                          (long)[self.remoteInputController debugRunGestureWithDeltas:circle(1.5, 1, 60)],
                          (long)[self.remoteInputController debugRunGestureWithDeltas:circle(1.0, -1, 60)],
                          (long)[self.remoteInputController debugRunGestureWithDeltas:line],
                          (long)[self.remoteInputController debugRunGestureWithDeltas:circle(0.25, 1, 200)]);
                    return;
                }
                if ([step isEqualToString:@"next"] || [step isEqualToString:@"prev"]) {
                    [self.remoteInputController stepTargetBy:[step isEqualToString:@"next"] ? 1 : -1];
                    NSLog(@"[SelfTest] %@ cursor=%@", step, NSStringFromCGPoint(self.remoteInputController.cursorView.frame.origin));
                    return;
                }
                if ([step isEqualToString:@"probe"]) {
                    UIScrollView *sv = self.webview.scrollView;
                    [self.webview evaluateJavaScriptAsync:@"(function(){var r=document.getElementById('red');var b=r?r.getBoundingClientRect():null;var h=document.elementFromPoint(20,20);return 'red.top='+(b?b.top:'-')+' scrollY='+scrollY+' innerH='+innerHeight+' innerW='+innerWidth+' hit20='+(h?h.id||h.tagName:'-')+' vv.top='+(window.visualViewport?visualViewport.offsetTop:'-');})()" completion:^(id result) {
                        NSLog(@"[SelfTest] probe %@ webFrame=%@ offset=%@ inset=%@", result, NSStringFromCGRect(self.webview.frame), NSStringFromCGPoint(sv.contentOffset), NSStringFromUIEdgeInsets(sv.contentInset));
                    }];
                    return;
                }
                if ([step isEqualToString:@"label"]) {
                    NSLog(@"[SelfTest] label %@", self.topMenuView.URLLabel.text);
                    return;
                }
                if ([step isEqualToString:@"anims"]) {
                    // Leistung: Ebenen mit laufenden Animationen im ganzen Fenster (auch unsichtbare), mit Sichtbarkeit.
                    __block NSUInteger count = 0;
                    __block void (^dumpLayer)(CALayer *, BOOL, NSString *);
                    __block __weak void (^weakDumpLayer)(CALayer *, BOOL, NSString *);
                    weakDumpLayer = dumpLayer = ^(CALayer *layer, BOOL visible, NSString *owner) {
                        BOOL shown = visible && !layer.hidden && layer.opacity > 0.0;
                        id delegate = layer.delegate;
                        NSString *name = [delegate isKindOfClass:UIView.class] ? NSStringFromClass([delegate class]) : owner;
                        NSArray<NSString *> *keys = layer.animationKeys;
                        if (keys.count > 0) {
                            count += 1;
                            double rotation = [[layer.presentationLayer ?: layer valueForKeyPath:@"transform.rotation.z"] doubleValue];
                            NSLog(@"[SelfTest] anim %@ (%@) sichtbar=%d keys=%@ speed=%.0f drehung=%.3f", name, NSStringFromClass(layer.class), shown,
                                  [keys componentsJoinedByString:@","], layer.superlayer.speed * layer.speed, rotation);
                        }
                        for (CALayer *sublayer in layer.sublayers) {
                            weakDumpLayer(sublayer, shown, name);
                        }
                        if (layer.mask != nil) {
                            weakDumpLayer(layer.mask, shown, name);
                        }
                    };
                    dumpLayer(self.view.window.layer, YES, @"Fenster");
                    NSLog(@"[SelfTest] anims %lu Ebenen mit Animationen (Glow-Animation=%d, Bewegung reduzieren=%d)", (unsigned long)count,
                          BrowserMotion.glowAnimationEnabled, UIAccessibilityIsReduceMotionEnabled());
                    return;
                }
                if ([step isEqualToString:@"views"]) {
                    __block void (^dump)(UIView *, NSInteger);
                    __block __weak void (^weakDump)(UIView *, NSInteger);
                    weakDump = dump = ^(UIView *view, NSInteger depth) {
                        CGRect frame = [view convertRect:view.bounds toView:self.view];
                        if (!CGRectContainsPoint(frame, CGPointMake(300, 6)) || view.hidden) {
                            return;
                        }
                        NSLog(@"[SelfTest] view %@%@ frame=%@ bg=%@ alpha=%.2f", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0], NSStringFromClass(view.class), NSStringFromCGRect(frame), view.backgroundColor, view.alpha);
                        for (UIView *subview in view.subviews) {
                            weakDump(subview, depth + 1);
                        }
                    };
                    dump(self.view.window, 0);
                    return;
                }
                if ([step hasPrefix:@"press:"]) {
                    [self runSelfTestPress:[step substringFromIndex:6]];
                    return;
                }
                if ([step isEqualToString:@"menu"]) {
                    BOOL handled = [self browserRemoteInputControllerHandleMenuPress];
                    NSLog(@"[SelfTest] menu handled=%d", handled);
                    return;
                }
                if ([step isEqualToString:@"reader"]) {
                    NSLog(@"[SelfTest] reader vorher verfügbar=%d aktiv=%d", self.topMenuView.readerAvailable, self.topMenuView.readerActive);
                    [self performTopBarAction:BrowserTopBarActionReader];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        NSLog(@"[SelfTest] reader nachher verfügbar=%d aktiv=%d", self.topMenuView.readerAvailable, self.topMenuView.readerActive);
                    });
                    return;
                }
                if ([step isEqualToString:@"address"]) {
                    // Wie zweimal oben: Leiste ausklappen, Diktierfeld und Aufklapp-Bereich.
                    [self browserRemoteInputControllerOpenAddressBar];
                    NSLog(@"[SelfTest] address active=%d tiles=%lu field=%@", self.addressPanel != nil,
                          (unsigned long)self.addressPanel.tileCount, NSStringFromCGRect(self.topMenuView.addressFieldFrame));
                    return;
                }
                if ([step hasPrefix:@"dir:"]) {
                    // Pfeiltaste im Aufklapp-Bereich: dir:up|down|left|right
                    NSString *direction = [step substringFromIndex:4];
                    CGVector vector = [direction isEqualToString:@"up"] ? CGVectorMake(0, -1)
                        : [direction isEqualToString:@"down"] ? CGVectorMake(0, 1)
                        : [direction isEqualToString:@"left"] ? CGVectorMake(-1, 0) : CGVectorMake(1, 0);
                    [self.remoteInputController stepTargetInDirection:vector];
                    NSLog(@"[SelfTest] dir %@ cursor=%@", direction, NSStringFromCGPoint(self.remoteInputController.cursorView.frame.origin));
                    return;
                }
                if ([step isEqualToString:@"favorite"]) {
                    [self toggleFavoriteForCurrentPage];
                    NSLog(@"[SelfTest] favorite %@ = %d", self.webview.request.URL.host, self.topMenuView.favorite);
                    return;
                }
                if ([step isEqualToString:@"advmenu"]) {
                    [self showAdvancedMenu];
                    return;
                }
                if ([step isEqualToString:@"setup"]) {
                    [self showSetup];
                    return;
                }
                if ([step hasPrefix:@"setup"] && [self.presentedViewController isKindOfClass:BrowserSetupViewController.class]) {
                    // setup:N Schritt zeigen, setupopt:i i-te Auswahl betätigen, setupnext Weiter/Fertig
                    BrowserSetupViewController *setup = (BrowserSetupViewController *)self.presentedViewController;
                    if ([step hasPrefix:@"setup:"]) {
                        [setup debugShowPage:[[step substringFromIndex:6] integerValue]];
                    } else if ([step hasPrefix:@"setupopt:"]) {
                        [setup debugActivateOption:[[step substringFromIndex:9] integerValue]];
                    } else if ([step isEqualToString:@"setupnext"]) {
                        [setup debugNext];
                    }
                    NSLog(@"[SelfTest] %@", step);
                    return;
                }
                if ([step isEqualToString:@"homechooser"]) {
                    // Auswahl „Startseite festlegen“ direkt öffnen (sonst über die Seitenleiste).
                    SEL chooser = NSSelectorFromString(@"presentHomePageChooser");
                    if ([self.menuCoordinator respondsToSelector:chooser]) {
                        ((void (*)(id, SEL))objc_msgSend)(self.menuCoordinator, chooser);
                    }
                    return;
                }
                if ([step isEqualToString:@"scrollend"]) {
                    // Scrollt die Liste im gezeigten Dialog ans Ende (für Screenshots langer Menüs).
                    UIViewController *top = self.view.window.rootViewController ?: self;
                    while (top.presentedViewController != nil) {
                        top = top.presentedViewController;
                    }
                    NSLog(@"[SelfTest] scrollend in %@", NSStringFromClass(top.class));
                    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:top.view];
                    while (queue.count > 0) {
                        UIView *view = queue.firstObject;
                        [queue removeObjectAtIndex:0];
                        if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) {
                            UIScrollView *scroll = (UIScrollView *)view;
                            CGFloat maxY = MAX(scroll.contentSize.height + scroll.adjustedContentInset.bottom - CGRectGetHeight(scroll.bounds), 0.0);
                            [scroll setContentOffset:CGPointMake(0.0, maxY) animated:YES];
                            NSLog(@"[SelfTest] scrollend %@ maxY=%.0f size=%@", NSStringFromClass(scroll.class), maxY, NSStringFromCGSize(scroll.contentSize));
                            break;
                        }
                        [queue addObjectsFromArray:view.subviews];
                    }
                    return;
                }
                if ([step isEqualToString:@"guide"]) {
                    [self showHintsAlert];
                    return;
                }
                if ([step isEqualToString:@"whatsnew"]) {
                    [self showWhatsNew];
                    return;
                }
                if ([step isEqualToString:@"clearall"]) {
                    // Alle Website-Daten (Cookies, Speicher, Cache) löschen: Seiten wie beim ersten Besuch.
                    [BrowserWebView resetWebsiteDataWithCompletion:^{ NSLog(@"[SelfTest] clearall fertig"); }];
                    return;
                }
                if ([step hasPrefix:@"clearsite:"]) {
                    // Nur die Website-Daten eines Hosts löschen (z. B. gespeicherte Einwilligung), Logins anderswo bleiben.
                    NSString *host = [step substringFromIndex:10];
                    id store = [BrowserWebView performSelector:NSSelectorFromString(@"defaultWebsiteDataStore")];
                    NSSet *types = [BrowserWebView performSelector:NSSelectorFromString(@"allWebsiteDataTypes")];
                    void (^fetched)(NSArray *) = ^(NSArray *records) {
                        NSMutableArray *matching = [NSMutableArray array];
                        for (id record in records) {
                            NSString *name = [record valueForKey:@"displayName"];
                            if ([name containsString:host]) { [matching addObject:record]; }
                        }
                        void (^done)(void) = ^{ NSLog(@"[SelfTest] clearsite %@: %lu Einträge gelöscht", host, (unsigned long)matching.count); };
                        ((void (*)(id, SEL, id, id, id))objc_msgSend)(store, NSSelectorFromString(@"removeDataOfTypes:forDataRecords:completionHandler:"), types, matching, done);
                    };
                    ((void (*)(id, SEL, id, id))objc_msgSend)(store, NSSelectorFromString(@"fetchDataRecordsOfTypes:completionHandler:"), types, fetched);
                    return;
                }
                if ([step isEqualToString:@"zoom"]) {
                    UIScrollView *sv = [self.webview scrollView];
                    id wk = [self.webview valueForKey:@"runtimeWebView"];
                    NSNumber *viewScale = [wk respondsToSelector:NSSelectorFromString(@"_viewScale")] ? [wk valueForKey:@"_viewScale"] : nil;
                    NSLog(@"[SelfTest] zoom zoomScale=%.3f min=%.3f max=%.3f viewScale=%@ content=%@ bounds=%@ pageZoomPref=%.2f", sv.zoomScale, sv.minimumZoomScale, sv.maximumZoomScale, viewScale, NSStringFromCGSize(sv.contentSize), NSStringFromCGRect(sv.bounds), self.webview.pageZoom);
                    return;
                }
                if ([step isEqualToString:@"state"]) {
                    NSLog(@"[SelfTest] state presented=%@ windowRoot=%@ fs=%d keyWindowPresented=%@", NSStringFromClass(self.presentedViewController.class), NSStringFromClass(self.view.window.rootViewController.class), self.webview.pageFullscreen, NSStringFromClass(self.view.window.rootViewController.presentedViewController.class));
                    return;
                }
                if ([step hasPrefix:@"pref:"]) {
                    // pref:Schlüssel=Wert – Einstellung setzen (am Gerät gibt es kein simctl defaults).
                    // YES/NO → Bool, Zahl → Zahl, sonst Zeichenkette; leerer Wert löscht den Schlüssel.
                    NSString *assignment = [step substringFromIndex:5];
                    NSRange equals = [assignment rangeOfString:@"="];
                    if (equals.location == NSNotFound || equals.location == 0) {
                        NSLog(@"[SelfTest] pref ungültig: %@", assignment);
                        return;
                    }
                    NSString *key = [assignment substringToIndex:equals.location];
                    NSString *raw = [assignment substringFromIndex:NSMaxRange(equals)];
                    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                    id value = nil;
                    NSString *upper = raw.uppercaseString;
                    if ([upper isEqualToString:@"YES"] || [upper isEqualToString:@"NO"]) {
                        value = @([upper isEqualToString:@"YES"]);
                    } else if (raw.length > 0) {
                        NSScanner *scanner = [NSScanner scannerWithString:raw];
                        scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                        double number = 0;
                        value = ([scanner scanDouble:&number] && scanner.isAtEnd) ? @(number) : raw;
                    }
                    if (value != nil) {
                        [defaults setObject:value forKey:key];
                    } else {
                        [defaults removeObjectForKey:key];
                    }
                    NSLog(@"[SelfTest] pref %@ = %@ (%@)", key, value ?: @"(gelöscht)", value != nil ? NSStringFromClass([value class]) : @"–");
                    return;
                }
                if ([step isEqualToString:@"speech"]) {
                    // SpeechTranscriber (tvOS 26) prüfen, Swift-Klasse ohne Bridging-Header (BrowserSpeechProbe.swift).
                    Class probe = NSClassFromString(@"BrowserSpeechProbe");
                    SEL run = NSSelectorFromString(@"runWithCompletion:");
                    if (probe == Nil || ![probe respondsToSelector:run]) {
                        NSLog(@"[SelfTest] speech: BrowserSpeechProbe fehlt");
                        return;
                    }
                    void (^completion)(NSString *) = ^(NSString *line) {
                        NSLog(@"[SelfTest] speech %@", line);
                    };
                    ((void (*)(id, SEL, id))objc_msgSend)(probe, run, completion);
                    return;
                }
                if ([step hasPrefix:@"js:"]) {
                    // Fehler mitloggen: „js (null)“ allein verrät nicht, ob der Ausdruck scheitert (Syntax, z. B. ein
                    // „return“ außerhalb einer Funktion → Code 4) oder der Seitenprozess weg ist (Code 5 „unsupported
                    // type“ auch für 1+1, siehe [WebProcess]).
                    [self.webview evaluateJavaScriptAsync:[step substringFromIndex:3] resultHandler:^(id result, NSError *error) {
                        if (error != nil) {
                            NSLog(@"[SelfTest] js Fehler %ld: %@ %@", (long)error.code, error.localizedDescription, error.userInfo[@"WKJavaScriptExceptionMessage"] ?: @"");
                        } else {
                            NSLog(@"[SelfTest] js %@", result);
                        }
                    }];
                    return;
                }
                // Nativer Player: öffnen (wie Menü „Im Player öffnen“), Zustand, an Position springen, schließen.
                if ([step isEqualToString:@"native"]) {
                    NSLog(@"[SelfTest] native hasVideo=%d", [self.videoPlaybackCoordinator pageHasVideo]);
                    [self.videoPlaybackCoordinator openPageVideoInNativePlayer];
                    return;
                }
                if ([step isEqualToString:@"nplayer"] || [step hasPrefix:@"nseek:"] || [step isEqualToString:@"nclose"]) {
                    BrowserNativeVideoPlayerViewController *player = [self.videoPlaybackCoordinator currentNativePlayer];
                    NSLog(@"[SelfTest] %@ %@", step, player != nil ? [player debugStateLine] : @"kein Player");
                    if ([step hasPrefix:@"nseek:"]) {
                        [player.player seekToTime:CMTimeMakeWithSeconds([step substringFromIndex:6].doubleValue, NSEC_PER_SEC)];
                    } else if ([step isEqualToString:@"nclose"]) {
                        [player dismissViewControllerAnimated:YES completion:nil];
                    }
                    return;
                }
                if ([step isEqualToString:@"websubs"] || [step hasPrefix:@"websubs:"]) {
                    // Untertitel-Abgriff (Weg B) fürs aktuelle Video: websubs (whisper, Sprache aus der Einstellung),
                    // websubs:en / websubs:auto (Sprache für diesen Test), websubs:stub (Platzhalter), websubs:sp,force
                    // (ScriptProcessor, ohne Herkunftsprüfung), websubs:slow (Stub mit whisper-ähnlichem Takt),
                    // websubs:status, websubs:off
                    NSArray<NSString *> *options = step.length > 8 ? [[step substringFromIndex:8] componentsSeparatedByString:@","] : @[];
                    if ([options containsObject:@"status"]) {
                        BrowserWebSubtitleController *controller = self.webSubtitleController;
                        [controller.capture fetchScriptStatus:^(NSString *json) {
                            NSLog(@"[SelfTest] websubs %@ skript=%@", controller.statisticsSummary ?: @"aus", json);
                        }];
                        return;
                    }
                    if ([options containsObject:@"off"]) {
                        [self.webSubtitleController stop];
                        NSLog(@"[SelfTest] websubs aus");
                        return;
                    }
                    NSString *language = [options containsObject:@"auto"] ? @"auto" : ([options containsObject:@"en"] ? @"en" : nil);
                    [self prepareWebSubtitleControllerUsingStub:[options containsObject:@"stub"] || [options containsObject:@"slow"]
                                                       language:language];
                    if ([options containsObject:@"slow"]) {
                        // Wie whisper: Abschnitt 3 s, Überlappung 0,5 s, 1,2 s Rechenzeit.
                        BrowserSpeechRecognizerStub *stub = [BrowserSpeechRecognizerStub new];
                        stub.simulatedProcessingTime = 1.2;
                        [self.webSubtitleController stop];
                        self.webSubtitleController.recognizer = stub;
                        self.webSubtitleController.windowDuration = 3.0;
                        self.webSubtitleController.overlapDuration = 0.5;
                    }
                    self.webSubtitleController.capture.forceScriptProcessor = [options containsObject:@"sp"];
                    self.webSubtitleController.capture.ignoreCrossOriginCheck = [options containsObject:@"force"];
                    [self.webSubtitleController stop];
                    [self.webSubtitleController startForWebView:self.webview userInitiated:YES];
                    [self showWebSubtitleRecognizerHintIfNeeded];
                    NSLog(@"[SelfTest] websubs start %@", [options componentsJoinedByString:@","]);
                    return;
                }
                if ([step isEqualToString:@"video"]) {
                    [self.webview evaluateJavaScriptAsync:@"(function(){var v=document.querySelector('video');return v?('t='+v.currentTime.toFixed(1)+' paused='+v.paused+' ready='+v.readyState+' net='+v.networkState+' err='+(v.error?v.error.code:0)+' playErr='+(window.__browserLastPlayError||'')):'none';})()"
                                               completion:^(id result) {
                        NSLog(@"[SelfTest] video %@ rects=%lu playing=%d idle=%d", result, (unsigned long)[self.webview videoRects].count, self.webview.videoPlaying, UIApplication.sharedApplication.idleTimerDisabled);
                    }];
                    return;
                }
                NSArray<NSString *> *parts = [step componentsSeparatedByString:@","];
                if (parts.count != 2) {
                    return;
                }
                CGPoint point = CGPointMake(parts[0].doubleValue, parts[1].doubleValue);
                NSLog(@"[SelfTest] move %@ targets=%lu", NSStringFromCGPoint(point), (unsigned long)[self browserRemoteInputControllerPointerTargets].count);
                [self.remoteInputController movePointerToPoint:point];
            });
        }];
    });
}

/// Schritte für Stabilitätstests: mem, memwarn, wkprobe, procs, stop, newtab, closetab, back, forward.
- (BOOL)runStressSelfTestStep:(NSString *)step {
    if ([step isEqualToString:@"addrtiles"]) {
        // Fokus wie beim Wischen nach unten aus der Tastatur auf das unsichtbare Feld darunter (echter Fokuswechsel).
        BrowserAddressInputController *input = self.addressInput;
        NSLog(@"[SelfTest] addrtiles tastatur=%d", input != nil);
        [input debugMoveFocusBelowKeyboard];
        return YES;
    }
    if ([step isEqualToString:@"addrstate"]) {
        id focused = [UIFocusSystem focusSystemForEnvironment:self.presentedViewController ?: self].focusedItem;
        NSLog(@"[SelfTest] addrstate tabs=%d kompakt=%d karte=%d tastatur=%d presented=%@ text=\"%@\" fokus=%@ zeiger=%@ leisteEdit=%d",
              self.tabOverviewController.visible, self.topMenuView.compact, self.addressPanel != nil, self.addressInput != nil, NSStringFromClass(self.presentedViewController.class),
              self.addressInput.text ?: @"", focused != nil ? NSStringFromClass([focused class]) : @"-",
              NSStringFromCGPoint(self.remoteInputController.cursorView.frame.origin), self.topMenuView.addressEditing);
        return YES;
    }
    if ([step hasPrefix:@"selectdup"]) {
        // Ein Auswahl-Druck kommt direkt (pressesEnded) und 0,3 s später nochmal über UIApplication sendEvent:
        // (wie auf dem Gerät, wenn der erste Klick den Hauptthread lange belegt). Darf nur einmal wirken.
        // selectdup:alt schickt die Kopie ohne Zeitstempel (Verhalten vor der Korrektur).
        BOOL old = [step isEqualToString:@"selectdup:alt"];
        BrowserSelfTestPress *press = [BrowserSelfTestPress new];
        press.selfTestType = UIPressTypeSelect;
        press.selfTestPhase = UIPressPhaseEnded;
        press.selfTestTimestamp = CACurrentMediaTime();
        NSLog(@"[SelfTest] selectdup direkt");
        [self.remoteInputController handlePressesEnded:[NSSet setWithObject:press] withEvent:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[SelfTest] selectdup Kopie über sendEvent (%@)", old ? @"ohne Zeitstempel" : @"gleicher Zeitstempel");
            [NSNotificationCenter.defaultCenter postNotificationName:kBrowserGlobalSelectPressEndedNotification object:nil
                                                            userInfo:old ? nil : @{@"timestamp": @(press.timestamp)}];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self runStressSelfTestStep:@"addrstate"];
        });
        return YES;
    }
    if ([step isEqualToString:@"mem"]) {
        NSHashTable *closed = BrowserSelfTestClosedWebViews();
        id pool = [[[self.webview valueForKey:@"runtimeWebView"] valueForKey:@"configuration"] valueForKey:@"processPool"];
        SEL countSelector = NSSelectorFromString(@"_webProcessCount");
        SEL activeSelector = NSSelectorFromString(@"_webProcessCountIgnoringPrewarmedAndCached");
        NSUInteger processes = [pool respondsToSelector:countSelector] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(pool, countSelector) : 0;
        NSUInteger active = [pool respondsToSelector:activeSelector] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(pool, activeSelector) : 0;
        NSMutableArray<NSString *> *alive = [NSMutableArray array];
        for (id object in closed.allObjects) {
            [alive addObject:NSStringFromClass([object class])];
        }
        // Sitzungen des DNS-Proxys leben auf dessen Warteschlange.
        id proxy = [NSClassFromString(@"BrowserDNSProxy") valueForKey:@"sharedProxy"];
        dispatch_queue_t proxyQueue = [proxy valueForKey:@"queue"];
        __block NSUInteger proxySessionCount = 0;
        if (proxyQueue != nil) {
            dispatch_sync(proxyQueue, ^{ proxySessionCount = [[proxy valueForKey:@"sessions"] count]; });
        }
        NSLog(@"[SelfTest] mem footprint=%.1f MB tabs=%lu geschlossene WebViews lebend=%lu [%@] Proxy-Sitzungen=%lu Seitenprozesse=%lu (ohne vorgewärmte %lu) presented=%@ url=%@",
              BrowserSelfTestFootprintMB(), (unsigned long)self.viewModel.tabs.count, (unsigned long)closed.allObjects.count,
              [alive componentsJoinedByString:@","], (unsigned long)proxySessionCount,
              (unsigned long)processes, (unsigned long)active,
              NSStringFromClass(self.presentedViewController.class), self.webview.request.URL.host ?: @"-");
        return YES;
    }
    if ([step isEqualToString:@"memwarn"]) {
        // Wie „Simulate Memory Warning“ im Simulator: UIKit verschickt die Warnung an App, Controller und Caches.
        SEL perform = NSSelectorFromString(@"_performMemoryWarning");
        UIApplication *application = UIApplication.sharedApplication;
        double before = BrowserSelfTestFootprintMB();
        if ([application respondsToSelector:perform]) {
            ((void (*)(id, SEL))objc_msgSend)(application, perform);
        } else {
            [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidReceiveMemoryWarningNotification object:application];
        }
        NSLog(@"[SelfTest] memwarn vorher=%.1f MB nachher=%.1f MB", before, BrowserSelfTestFootprintMB());
        return YES;
    }
    if ([step isEqualToString:@"wkprobe"]) {
        // Private Stellschrauben für Prozesse und Caches (nur Bestandsaufnahme).
        for (NSString *className in @[@"WKProcessPool", @"_WKProcessPoolConfiguration", @"WKPreferences", @"WKWebViewConfiguration", @"WKWebsiteDataStore", @"_WKWebsiteDataStoreConfiguration"]) {
            Class cls = NSClassFromString(className);
            NSMutableArray<NSString *> *found = [NSMutableArray array];
            for (int meta = 0; meta < 2 && cls != Nil; meta++) {
                unsigned int count = 0;
                Method *methods = class_copyMethodList(meta ? object_getClass(cls) : cls, &count);
                for (unsigned int i = 0; i < count; i++) {
                    NSString *name = NSStringFromSelector(method_getName(methods[i]));
                    NSString *lower = name.lowercaseString;
                    if ([lower containsString:@"cache"] || [lower containsString:@"prewarm"] || [lower containsString:@"swap"] ||
                        [lower containsString:@"processcount"] || [lower containsString:@"suspend"] || [lower containsString:@"memory"]) {
                        [found addObject:[(meta ? @"+" : @"-") stringByAppendingString:name]];
                    }
                }
                free(methods);
            }
            NSLog(@"[SelfTest] wkprobe %@: %@", className, [found componentsJoinedByString:@" "]);
        }
        [self logSelfTestProcessPool];
        return YES;
    }
    if ([step isEqualToString:@"procs"]) {
        [self logSelfTestProcessPool];
        return YES;
    }
    if ([step isEqualToString:@"stop"]) {
        NSLog(@"[SelfTest] stop loading=%d url=%@", self.webview.loading, self.webview.request.URL.absoluteString ?: @"-");
        id runtimeWebView = [self.webview valueForKey:@"runtimeWebView"];
        if ([runtimeWebView respondsToSelector:@selector(stopLoading)]) {
            ((void (*)(id, SEL))objc_msgSend)(runtimeWebView, @selector(stopLoading));
        }
        return YES;
    }
    if ([step isEqualToString:@"newtab"]) {
        [self browserCommandNewTab];
        NSLog(@"[SelfTest] newtab tabs=%lu", (unsigned long)self.viewModel.tabs.count);
        return YES;
    }
    if ([step isEqualToString:@"closetab"]) {
        BrowserWebView *closing = self.webview;
        if (closing != nil) {
            [BrowserSelfTestClosedWebViews() addObject:closing];
            id runtimeWebView = [closing valueForKey:@"runtimeWebView"];
            if (runtimeWebView != nil) {
                [BrowserSelfTestClosedWebViews() addObject:runtimeWebView];
            }
        }
        [self browserCommandCloseTab];
        NSLog(@"[SelfTest] closetab tabs=%lu", (unsigned long)self.viewModel.tabs.count);
        return YES;
    }
    if ([step isEqualToString:@"back"] || [step isEqualToString:@"forward"]) {
        BOOL ok = [step isEqualToString:@"back"] ? [self browserCommandGoBack] : [self browserCommandGoForward];
        NSLog(@"[SelfTest] %@ ok=%d", step, ok);
        return YES;
    }
    return NO;
}

/// Zustand des gemeinsamen WKProcessPool: Seitenprozesse, zwischengespeicherte/ausgesetzte Seiten, Vorwärmen.
- (void)logSelfTestProcessPool {
    id runtimeWebView = [self.webview valueForKey:@"runtimeWebView"];
    id configuration = [runtimeWebView valueForKey:@"configuration"];
    id pool = [configuration valueForKey:@"processPool"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[@"_webProcessCount", @"_webPageContentProcessCount", @"_webProcessCountIgnoringPrewarmed",
                            @"_webProcessCountIgnoringPrewarmedAndCached", @"_maximumSuspendedPageCount", @"_processCacheCapacity",
                            @"_processCacheSize", @"_prewarmedProcessCountLimit", @"_hasPrewarmedWebProcess"]) {
        SEL selector = NSSelectorFromString(key);
        if ([pool respondsToSelector:selector]) {
            NSMethodSignature *signature = [pool methodSignatureForSelector:selector];
            NSUInteger value = 0;
            if (signature.methodReturnLength <= sizeof(NSUInteger)) {
                value = ((NSUInteger (*)(id, SEL))objc_msgSend)(pool, selector);
                if (signature.methodReturnLength == 1) {
                    value &= 0xFF;
                }
            }
            [parts addObject:[NSString stringWithFormat:@"%@=%lu", [key substringFromIndex:1], (unsigned long)value]];
        }
    }
    id poolConfiguration = [pool respondsToSelector:NSSelectorFromString(@"_configuration")] ? [pool valueForKey:@"_configuration"] : nil;
    for (NSString *key in @[@"pageCacheEnabled", @"usesWebProcessCache", @"prewarmsProcessesAutomatically", @"processSwapsOnNavigation",
                            @"suspendsWebProcessesAggressivelyOnMemoryPressure", @"maximumProcessCount"]) {
        if ([poolConfiguration respondsToSelector:NSSelectorFromString(key)]) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, [poolConfiguration valueForKey:key]]];
        }
    }
    id preferences = [configuration valueForKey:@"preferences"];
    if ([preferences respondsToSelector:NSSelectorFromString(@"_usesPageCache")]) {
        [parts addObject:[NSString stringWithFormat:@"usesPageCache=%@", [preferences valueForKey:@"_usesPageCache"]]];
    }
    NSLog(@"[SelfTest] procs pool=%p %@", pool, [parts componentsJoinedByString:@" "]);
}

/// press:<taste>[@ms] – Taste über die Responder-Kette wie von der Fernbedienung: menu, playpause, playpause2
/// (doppelt), select, up, down, left, right; @ms hält die Taste so lange (Vorgabe 80 ms, lang: playpause@900).
- (void)runSelfTestPress:(NSString *)spec {
    NSArray<NSString *> *parts = [spec componentsSeparatedByString:@"@"];
    NSString *name = parts.firstObject ?: @"";
    NSTimeInterval hold = parts.count > 1 ? parts[1].doubleValue / 1000.0 : 0.08;
    NSDictionary<NSString *, NSNumber *> *types = @{
        @"menu": @(UIPressTypeMenu), @"playpause": @(UIPressTypePlayPause), @"playpause2": @(UIPressTypePlayPause),
        @"select": @(UIPressTypeSelect), @"up": @(UIPressTypeUpArrow), @"down": @(UIPressTypeDownArrow),
        @"left": @(UIPressTypeLeftArrow), @"right": @(UIPressTypeRightArrow),
    };
    NSNumber *type = types[name];
    if (type == nil) {
        NSLog(@"[SelfTest] press unbekannt: %@", name);
        return;
    }
    // Wie UIKit: an das fokussierte Element, sonst an den obersten Controller; Ende an denselben Responder.
    id focused = [UIFocusSystem focusSystemForEnvironment:self].focusedItem;
    UIViewController *top = self;
    while (top.presentedViewController != nil) {
        top = top.presentedViewController;
    }
    UIResponder *target = [focused isKindOfClass:UIResponder.class] ? focused : top;
    NSInteger count = [name isEqualToString:@"playpause2"] ? 2 : 1;
    NSLog(@"[SelfTest] press %@ an %@ (oben %@)", spec, NSStringFromClass(target.class), NSStringFromClass(top.class));
    for (NSInteger i = 0; i < count; i++) {
        NSTimeInterval start = i * (hold + 0.12);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(start * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BrowserSelfTestPress *press = [BrowserSelfTestPress new];
            press.selfTestType = (UIPressType)type.integerValue;
            press.selfTestPhase = UIPressPhaseBegan;
            [target pressesBegan:[NSSet setWithObject:press] withEvent:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                press.selfTestPhase = UIPressPhaseEnded;
                [target pressesEnded:[NSSet setWithObject:press] withEvent:nil];
            });
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((count * (hold + 0.12) + 1.2) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[SelfTest] press %@ danach presented=%@ tabs=%d karte=%d adresse=%d url=%@ zurück=%d tabzahl=%lu",
              spec, NSStringFromClass(self.presentedViewController.class), self.tabOverviewController.visible,
              self.intelligenceController.summaryVisible, self.addressPanel != nil,
              self.webview.request.URL.absoluteString ?: @"-", self.webview.canGoBack, (unsigned long)self.viewModel.tabs.count);
    });
}
#endif

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

/// Befehl aus einem App Intent (Siri) oder dem Selbsttest (siri:): geht an die Befehlstabelle (BrowserCommandRouter).
- (void)handleSiriCommandNotification:(NSNotification *)notification {
    NSString *command = [notification.userInfo[@"command"] isKindOfClass:NSString.class] ? notification.userInfo[@"command"] : @"";
    NSString *argument = [notification.userInfo[@"argument"] isKindOfClass:NSString.class] ? notification.userInfo[@"argument"] : nil;
    NSString *source = [notification.userInfo[@"source"] isKindOfClass:NSString.class] ? notification.userInfo[@"source"] : @"-";
    NSLog(@"[Siri] Befehl %@ arg=%@ quelle=%@", command, argument ?: @"-", source);
    [self.commandRouter performCommandNamed:command
                                   argument:argument
                                     source:[source isEqualToString:@"selftest"] ? BrowserCommandSourceSelfTest : BrowserCommandSourceSiri];
}

- (void)handleGlobalSelectPressEndedNotification:(NSNotification *)notification {
    (void)notification;
    NSNumber *timestamp = [notification.userInfo[@"timestamp"] isKindOfClass:NSNumber.class] ? notification.userInfo[@"timestamp"] : nil;
    [self.remoteInputController handleGlobalSelectPressEndedWithTimestamp:timestamp.doubleValue];
}

#pragma mark - Helpers

- (BrowserWebView *)webview {
    return self.tabCoordinator.activeWebView;
}

- (CGPoint)browserDOMPointForCursor {
    return [self.domInteractionService DOMPointForCursorOrigin:self.remoteInputController.cursorView.frame.origin
                                                        inView:self.view
                                                       webView:self.webview];
}

- (void)loadHomePage {
    [self.tabCoordinator loadHomePage];
}

- (void)showAdvancedMenu {
    [self deactivateTopBarFocusMode];
    [self.menuCoordinator showAdvancedMenu];
}

- (BOOL)canActivateTopBarFocusMode {
    return self.presentedViewController == nil &&
        !self.tabOverviewController.visible &&
        self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden;
}

- (void)activateTopBarFocusMode {
    if (![self canActivateTopBarFocusMode]) {
        return;
    }
    if (self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = YES;
    [self.topMenuView setFocusModeActive:YES];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)deactivateTopBarFocusMode {
    if (!self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = NO;
    [self.topMenuView setFocusModeActive:NO];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)performTopBarAction:(BrowserTopBarAction)action {
    [self deactivateTopBarFocusMode];

    switch (action) {
        case BrowserTopBarActionBack:
            if (self.webview.canGoBack) {
                [self.webview goBack];
            }
            break;
        case BrowserTopBarActionRefresh:
            [self.webview reload];
            break;
        case BrowserTopBarActionForward:
            if (self.webview.canGoForward) {
                [self.webview goForward];
            }
            break;
        case BrowserTopBarActionHome:
            [self loadHomePage];
            break;
        case BrowserTopBarActionTabs:
            [self browserShowTabOverview];
            break;
        case BrowserTopBarActionURL:
            // Klick auf die Adresse: Bearbeiten-Zustand mit Tastatur (bzw. nur die Tastatur, wenn der Zustand offen ist).
            [self beginAddressEditing];
            break;
        case BrowserTopBarActionFullscreen:
            if (self.viewModel.topNavigationBarVisible) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Obere Leiste ausblenden?"
                                                                                         message:@"Das Menü öffnest du weiterhin mit doppeltem Druck auf Play/Pause."
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Ausblenden"
                                                                    style:UIAlertActionStyleDestructive
                                                                  handler:^(__unused UIAlertAction *action) {
                    [self browserHideTopNav];
                }]];
                [self browserPresentViewController:alertController];
            } else {
                [self browserShowTopNav];
            }
            break;
        case BrowserTopBarActionMenu:
            [self showAdvancedMenu];
            break;
        case BrowserTopBarActionFavorite:
            [self toggleFavoriteForCurrentPage];
            break;
        case BrowserTopBarActionReader:
            [self toggleReaderMode];
            break;
    }
}

- (void)updateTextFontSize {
    if (self.webview == nil) {
        return;
    }

    NSString *jsString = [[NSString alloc] initWithFormat:
                          @"(function(){"
                           "var value='%lu%%';"
                           "var multiplier=%lu/100;"
                           "if (document.documentElement && document.documentElement.style) {"
                               "document.documentElement.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.documentElement.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (document.body && document.body.style) {"
                               "document.body.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.body.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (!document.body || !window.getComputedStyle) { return value; }"
                           // Bei 100 % nur früher vergrößerte Elemente zurücksetzen. Sonst würde jede Seite bei jedem
                           // Laden für alle Elemente getComputedStyle lesen und die Größen festschreiben (am Apple TV
                           // bis 700 ms Wartezeit auf großen Seiten, und die Seite könnte ihre Schrift nicht mehr ändern).
                           "var elements = document.querySelectorAll(multiplier === 1 ? '[data-browser-original-font-size]' : 'body, body *');"
                           "for (var i = 0; i < elements.length; i++) {"
                               "var element = elements[i];"
                               "if (!element || !element.tagName) { continue; }"
                               "var tagName = element.tagName.toLowerCase();"
                               "if (tagName === 'script' || tagName === 'style' || tagName === 'noscript') { continue; }"
                               "var originalSize = element.getAttribute('data-browser-original-font-size');"
                               "if (!originalSize) {"
                                   "var computedSize = window.getComputedStyle(element).fontSize || '';"
                                   "if (computedSize.indexOf('px') == -1) { continue; }"
                                   "var parsedSize = parseFloat(computedSize);"
                                   "if (!isFinite(parsedSize) || parsedSize <= 0) { continue; }"
                                   "originalSize = String(parsedSize);"
                                   "element.setAttribute('data-browser-original-font-size', originalSize);"
                               "}"
                               "var baseSize = parseFloat(originalSize);"
                               "if (!isFinite(baseSize) || baseSize <= 0) { continue; }"
                               "element.style.setProperty('font-size', (baseSize * multiplier) + 'px', 'important');"
                           "}"
                           "return value;"
                          "})()",
                          (unsigned long)self.viewModel.textFontSize,
                          (unsigned long)self.viewModel.textFontSize];
    [self.webview stringByEvaluatingJavaScriptFromString:jsString];
}

/// Sieht die Eingabe wie eine Adresse aus (kein Leerzeichen, mit Punkt oder Schema)?
- (BOOL)enteredTextLooksLikeAddress:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) {
        return NO;
    }
    return [trimmed containsString:@"://"] || [trimmed hasPrefix:@"localhost"] ||
        ([trimmed containsString:@"."] && ![trimmed hasSuffix:@"."]);
}

/// Adresse öffnen oder mit Google suchen, je nach Eingabe.
- (void)openAddressOrSearch:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return;
    }
    [self endAddressEditingAnimated:YES];
    NSURLRequest *request = nil;
    if ([self enteredTextLooksLikeAddress:trimmed]) {
        NSString *address = [trimmed containsString:@"://"] ? trimmed : [@"https://" stringByAppendingString:trimmed];
        request = [self.navigationService requestForEnteredAddressString:address];
    }
    if (request == nil) {
        request = [self.navigationService googleSearchRequestForQuery:trimmed];
    }
    if (request != nil) {
        [self.webview loadRequest:request];
    }
}

/// Eingabe aus dem Adressfeld (Diktat oder Tastatur): erst die Befehlstabelle fragen (ganze Phrasen, Präfixe wie
/// „frag …“), dann der Ähnlichkeitsabgleich (BrowserIntelligence matchCommandForText:), sonst Adresse oder Suche.
- (void)handleEnteredAddressText:(NSString *)text {
    BrowserParsedCommand *parsed = [BrowserCommandParser parseText:text ?: @""];
    if (parsed != nil) {
        NSLog(@"[Command] Diktat \"%@\" -> %@%@%@", text, parsed.name, parsed.argument != nil ? @"|" : @"", parsed.argument ?: @"");
        [self.commandRouter performCommandNamed:parsed.name argument:parsed.argument source:BrowserCommandSourceDictation];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [BrowserIntelligence.sharedIntelligence matchCommandForText:text ?: @"" completion:^(BrowserCommandMatch *match) {
        typeof(self) self_ = weakSelf;
        if (self_ == nil) {
            return;
        }
        if (match != nil) {
            NSLog(@"[Command] Diktat \"%@\" ähnlich: %@", text, match.logDescription);
        }
        if (match.accepted) {
            [self_.commandRouter performCommandNamed:match.name argument:match.argument.length > 0 ? match.argument : nil
                                              source:BrowserCommandSourceDictation feedbackNote:nil];
            return;
        }
        [self_ openAddressOrSearch:text];
    }];
}

/// Eingabe aus der Adressleiste fertig (Diktat oder Tastatur): wie bisher Befehl, Adresse oder Suche.
- (void)submitAddressInputText:(NSString *)text {
    [self endAddressEditingAnimated:YES];
    [self handleEnteredAddressText:text];
}


/// Kurzer Name der aktuellen Seite für Verlauf und Favoriten.
- (void)browserRemoteInputControllerCompactTopBar {
    [self endAddressEditingAnimated:YES];
    [self.topMenuView setCompact:YES animated:YES];
    self.pageScrollTravel = 0.0;
}

#pragma mark - Reader-Modus

/// Reader-Knopf der Leiste: Artikel anzeigen bzw. zur Originalseite zurück.
- (void)toggleReaderMode {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return;
    }
    self.readerCheckGeneration++;
    __weak typeof(self) weakSelf = self;
    [BrowserReaderMode toggleWebView:webView completion:^(BrowserReaderState state) {
        if (weakSelf.webview != webView) {
            return;
        }
        [weakSelf.topMenuView setReaderAvailable:state != BrowserReaderStateUnavailable active:state == BrowserReaderStateActive];
        [webView refreshClickTargets];
        [weakSelf.remoteInputController pointerTargetsDidChange];
    }];
}

/// Fragt die Lesbarkeit der aktuellen Seite ab und zeigt oder verbirgt den Reader-Knopf.
- (void)updateReaderAvailability {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return;
    }
    NSUInteger generation = ++self.readerCheckGeneration;
    __weak typeof(self) weakSelf = self;
    [BrowserReaderMode checkWebView:webView completion:^(BrowserReaderState state) {
        if (weakSelf.webview != webView || weakSelf.readerCheckGeneration != generation) {
            return;
        }
        [weakSelf.topMenuView setReaderAvailable:state != BrowserReaderStateUnavailable active:state == BrowserReaderStateActive];
        [weakSelf.remoteInputController pointerTargetsDidChange];
    }];
}

/// Nach dem Laden: sofort und nochmals nach 2,5 s prüfen (Seiten, die ihren Text erst per Skript aufbauen).
- (void)scheduleReaderAvailabilityChecks {
    BrowserWebView *webView = self.webview;
    for (NSNumber *delay in @[@0.4, @2.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.webview == webView && !webView.isLoading && !self.topMenuView.readerActive) {
                [self updateReaderAvailability];
            }
        });
    }
}

/// Stern in der Leiste: aktuelle Seite zu den Favoriten hinzufügen oder entfernen.
- (void)toggleFavoriteForCurrentPage {
    NSURL *url = self.webview.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return;
    }
    BrowserHistoryStore *store = BrowserHistoryStore.sharedStore;
    if ([store isFavoriteURL:url]) {
        [store removeFavoriteWithURL:url];
    } else {
        [store addFavoriteWithURL:url title:[self currentSiteDisplayName]];
    }
    [self updateFavoriteButton];
}

- (void)updateFavoriteButton {
    NSURL *url = self.webview.request.URL;
    self.topMenuView.favorite = url != nil && [BrowserHistoryStore.sharedStore isFavoriteURL:url];
}

- (NSString *)currentSiteDisplayName {
    NSString *name = self.webview.reportedSiteName;
    if (name.length == 0) {
        name = self.webview.reportedPageTitle;
    }
    if (name.length == 0) {
        name = self.webview.title;
    }
    return name;
}

#pragma mark - Adresse bearbeiten (Systemtastatur, Diktat und Aufklapp-Bereich)

/// Einziger Weg in die Adresseingabe (Klick auf Adresse oder Kapsel, zweimal oben, Play/Pause lang,
/// Schnellmenü, Fehlerdialog, Sprachbefehl „Adresse“/„Suche“ ohne Begriff): Leiste ausklappen, darunter sofort
/// die Systemtastatur mit Fokus (Siri-Taste halten = diktieren), darunter die Karte mit Favoriten/Oft/Zuletzt.
- (void)beginAddressEditing {
    if (self.tabOverviewController.visible) {
        [self browserRemoteInputControllerDismissTabOverview];
    }
    if (self.addressPanel != nil) {
        [self showAddressKeyboard];
        return;
    }
    if (self.presentedViewController != nil && !self.presentedViewController.isBeingDismissed) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }
    [self deactivateTopBarFocusMode];
    if (!self.viewModel.topNavigationBarVisible || self.topMenuView.hidden) {
        [self browserShowTopNav];
    }
    [self.topMenuView setCompact:NO animated:YES];
    self.pageScrollTravel = 0.0;
    [self.topMenuView setAddressEditing:YES animated:YES];

    UIView *container = self.topMenuView.superview ?: self.view;
    BrowserAddressPanelView *panel = [[BrowserAddressPanelView alloc] initWithFrame:container.bounds];
    __weak typeof(self) weakSelf = self;
    panel.openURLHandler = ^(NSURL *url) {
        [weakSelf endAddressEditingAnimated:YES];
        [weakSelf.webview loadRequest:[NSURLRequest requestWithURL:url]];
    };
    // Unter der Leiste (die Leiste bleibt hell), über der Seite; Zeiger und Hervorhebung liegen darüber.
    [container insertSubview:panel belowSubview:self.topMenuView];
    self.addressPanel = panel;
    [panel reloadData];
    // Platz für die Tastatur gleich beim Aufklappen lassen, sonst springt die Karte danach nach unten.
    [panel setKeyboardSpace:BrowserAddressInputController.keyboardAreaHeight animated:NO];
    CGRect bar = [self.topMenuView convertRect:self.topMenuView.chromeFrame toView:panel];
    [panel presentBelowBarFrame:bar animated:YES];
    [self.remoteInputController refreshInteractionState];
#if DEBUG
    NSLog(@"[Address] Bearbeiten an, Kacheln=%lu", (unsigned long)panel.tileCount);
#endif
    [self showAddressKeyboard];
}

/// Systemtastatur unter der Leiste öffnen (Bearbeiten-Zustand muss offen sein). Doppelte Aufrufe öffnen nichts doppelt.
- (void)showAddressKeyboard {
    BrowserAddressPanelView *panel = self.addressPanel;
    if (panel == nil || self.addressInput != nil) {
        return;
    }
    UIViewController *presented = self.presentedViewController;
    if (presented != nil) {
        if (presented.isBeingDismissed) {
            // Dialog schließt gerade (z. B. Schnellmenü „Adresse oder Suche“): danach öffnen.
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf showAddressKeyboard];
            });
            return;
        }
        [self dismissViewControllerAnimated:NO completion:nil];
    }
    BrowserAddressInputController *input = [BrowserAddressInputController new];
    input.barFrame = [self.topMenuView convertRect:self.topMenuView.chromeFrame toView:nil];
    __weak typeof(self) weakSelf = self;
    __weak BrowserAddressInputController *weakInput = input;
    input.endHandler = ^(BrowserAddressInputEnd end, NSString *text) {
        typeof(self) self_ = weakSelf;
        // Veraltete Eingabe (inzwischen neu geöffnet oder Zustand beendet): nichts tun.
        if (self_ == nil || self_.addressInput != weakInput) {
            return;
        }
        self_.addressInput = nil;
        switch (end) {
            case BrowserAddressInputEndSubmitted:
                [self_ submitAddressInputText:text ?: @""];
                break;
            case BrowserAddressInputEndToTiles:
                [self_ addressKeyboardDidLeaveToTiles];
                break;
            case BrowserAddressInputEndCancelled:
                [self_ endAddressEditingAnimated:YES];
                break;
        }
    };
    input.keyboardAreaHeightHandler = ^(CGFloat height) {
        if (weakSelf.addressInput == weakInput) {
            [weakSelf.addressPanel setKeyboardSpace:height animated:YES];
        }
    };
    self.addressInput = input;
    [panel setKeyboardSpace:BrowserAddressInputController.keyboardAreaHeight animated:YES];
    [self presentViewController:input animated:YES completion:nil];
}

/// Aus der Tastatur nach unten gewischt: Tastatur zu, Karte rückt unter die Leiste, Zeiger auf die erste Kachel.
- (void)addressKeyboardDidLeaveToTiles {
    BrowserAddressPanelView *panel = self.addressPanel;
    if (panel == nil) {
        return;
    }
    [panel setKeyboardSpace:0.0 animated:YES];
    [self.remoteInputController refreshInteractionState];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([BrowserMotion durationForKind:BrowserMotionKindSnap] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self_ = weakSelf;
        if (self_.addressPanel != panel || self_.addressInput != nil) {
            return;
        }
        [self_.remoteInputController pointerTargetsDidChange];
        NSArray<NSValue *> *tiles = [panel pointerTargetRectsInView:self_.view];
        CGRect target = tiles.count > 0 ? tiles.firstObject.CGRectValue
                                        : [self_.topMenuView convertRect:self_.topMenuView.addressFieldFrame toView:self_.view];
        [self_.remoteInputController movePointerToPoint:CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target))];
    });
}

- (void)endAddressEditingAnimated:(BOOL)animated {
    BrowserAddressInputController *input = self.addressInput;
    self.addressInput = nil;
    [input closeSilentlyAnimated:animated];
    BrowserAddressPanelView *panel = self.addressPanel;
    if (panel == nil) {
        return;
    }
    self.addressPanel = nil;
    [self.topMenuView setAddressEditing:NO animated:animated];
    [panel dismissAnimated:animated completion:nil];
    [self.remoteInputController refreshInteractionState];
    [self.remoteInputController pointerTargetsDidChange];
#if DEBUG
    NSLog(@"[Address] Bearbeiten aus");
#endif
}

/// Klick im Bearbeiten-Zustand (Tastatur zu): Feld öffnet die Tastatur wieder, Kachel die Seite, daneben schließt.
- (void)handleAddressEditingSelectionAtPoint:(CGPoint)point {
    CGRect field = [self.topMenuView convertRect:self.topMenuView.addressFieldFrame toView:self.view];
    if (CGRectContainsPoint(CGRectInset(field, -6.0, -6.0), point)) {
        [self showAddressKeyboard];
        return;
    }
    if ([self.addressPanel handleSelectionAtPoint:point inView:self.view]) {
        return;
    }
    if ([self.addressPanel cardContainsPoint:point inView:self.view]) {
        return;
    }
    [self endAddressEditingAnimated:YES];
}


- (void)requestURLorSearchInput {
    NSString *host = self.webview.request.URL.host;
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Schnellmenü"
                                                                             message:host.length > 0 ? host : @""
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;

    [alertController addAction:[UIAlertAction actionWithTitle:@"Adresse oder Suche"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf beginAddressEditing];
    }]];

    NSURL *currentURL = self.webview.request.URL;
    if ([BrowserHistoryStore hostKeyForURL:currentURL] != nil) {
        BOOL isFavorite = [BrowserHistoryStore.sharedStore isFavoriteURL:currentURL];
        [alertController addAction:[UIAlertAction actionWithTitle:isFavorite ? @"Aus Favoriten entfernen" : @"Zu Favoriten hinzufügen"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            if (isFavorite) {
                [BrowserHistoryStore.sharedStore removeFavoriteWithURL:currentURL];
                [weakSelf updateFavoriteButton];
            } else {
                [BrowserHistoryStore.sharedStore addFavoriteWithURL:currentURL title:[weakSelf currentSiteDisplayName]];
                [weakSelf updateFavoriteButton];
            }
        }]];
    }

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Neu laden"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    }

    if (self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Vor"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf.webview goForward];
        }]];
    }

    if ([self.videoPlaybackCoordinator pageHasVideo]) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Im Player öffnen"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf.videoPlaybackCoordinator openPageVideoInNativePlayer];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"Neuer Tab"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf browserCreateNewTabLoadingHomePage:YES];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Tabs anzeigen"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf browserShowTabOverview];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Startseite"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf loadHomePage];
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Weitere Einstellungen …"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [weakSelf showAdvancedMenu];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)showHintsAlert {
    BrowserGuideViewController *guide = [[BrowserGuideViewController alloc] init];
    guide.dontShowOnLaunch = self.preferencesStore.dontShowHintsOnLaunch;
    __weak typeof(self) weakSelf = self;
    guide.toggleHandler = ^(BOOL dontShowOnLaunch) {
        weakSelf.preferencesStore.dontShowHintsOnLaunch = dontShowOnLaunch;
    };
    [self presentViewController:guide animated:YES completion:nil];
}

- (void)showSetup {
    if (self.presentedViewController != nil) {
        return;
    }
    BrowserSetupViewController *setup = [[BrowserSetupViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    setup.completionHandler = ^(BOOL homePageChanged) {
        [weakSelf applySetupResultWithHomePageChanged:homePageChanged];
    };
    [self presentViewController:setup animated:YES completion:nil];
}

/// Nach der Einrichtung: geänderte Schalter wirksam machen, Startseite laden, dann die Bedienungshilfe.
- (void)applySetupResultWithHomePageChanged:(BOOL)homePageChanged {
    // „Was ist neu“ wäre direkt nach der Einrichtung doppelt; die Bedienungshilfe folgt sofort.
    [NSUserDefaults.standardUserDefaults setObject:BrowserGuideViewController.whatsNewVersion forKey:@"WhatsNewSeenVersion"];
    [[BrowserContentBlocker sharedBlocker] preferencesDidChange];
    [[BrowserCookieConsentBlocker sharedBlocker] preferencesDidChange];
    BrowserDNSProxy *proxy = [BrowserDNSProxy sharedProxy];
    [proxy startAndWaitWithTimeout:1.0];
    [proxy applyToWebsiteDataStore:[BrowserWebView defaultWebsiteDataStore]];
    [self browserSetWebSubtitlesEnabled:self.preferencesStore.webSubtitlesEnabled];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BrowserDesignDidChangeNotification" object:nil];
    if (homePageChanged) {
        [self loadHomePage];
    } else {
        [self.webview reload];
    }
    [self showHintsAlert];
}

- (void)showWhatsNew {
    if (self.presentedViewController != nil) {
        return;
    }
    BrowserGuideViewController *whatsNew = [[BrowserGuideViewController alloc] init];
    whatsNew.whatsNew = YES;
    __weak typeof(self) weakSelf = self;
    whatsNew.showGuideHandler = ^{
        [weakSelf showHintsAlert];
    };
    [self presentViewController:whatsNew animated:YES completion:nil];
}

- (void)browserShowSetup {
    [self showSetup];
}

- (void)browserShowWhatsNew {
    [self showWhatsNew];
}

- (BOOL)topBarAcceptsPointer {
    return self.viewModel.topNavigationBarVisible && !self.topMenuView.hidden && self.topMenuView.alpha > 0.05;
}

/// Klick auf einen Knopf der oberen Leiste direkt auslösen, ohne den Umweg über den Fokusmodus.
- (BOOL)performTopBarActionAtPoint:(CGPoint)point {
    if (![self topBarAcceptsPointer]) {
        return NO;
    }
    __block BOOL found = NO;
    __block BrowserTopBarAction foundAction = BrowserTopBarActionURL;
    [self.topMenuView enumeratePointerTargetsUsingBlock:^(CGRect frame, BrowserTopBarAction action) {
        if (!found && CGRectContainsPoint([self.topMenuView convertRect:frame toView:self.view], point)) {
            found = YES;
            foundAction = action;
        }
    }];
    if (found && self.topMenuView.compact) {
        // Klick auf die Kapsel: wie auf die Adresse (die Leiste klappt dabei auf).
        [self beginAddressEditing];
        return YES;
    }
    if (found) {
        [self performTopBarAction:foundAction];
    }
    return found;
}

- (void)observeClickTargetsOfWebView:(BrowserWebView *)webView {
    if (webView == nil || webView.clickTargetsDidChange != nil) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    __weak BrowserWebView *weakWebView = webView;
    webView.clickTargetsDidChange = ^{
        if (weakSelf.webview == weakWebView) {
            [weakSelf.remoteInputController pointerTargetsDidChange];
            // Kein Bildschirmschoner, solange auf der Seite ein Video läuft.
            UIApplication.sharedApplication.idleTimerDisabled = weakWebView.videoPlaying;
            [weakSelf.nowPlayingController updateWithMediaInfo:weakWebView.mediaInfo];
            [weakSelf applyPageColorOfWebView:weakWebView];
        }
    };
    // Vollbildwunsch oder Start eines Videos auf der Seite: nativer Player.
    webView.videoEventHandler = ^(NSDictionary *event) {
        if (weakSelf.webview == weakWebView) {
            [weakSelf.videoPlaybackCoordinator handlePageVideoEvent:event];
        }
    };
    webView.loadingProgressDidChange = ^(double progress, BOOL loading) {
        if (weakSelf.webview == weakWebView) {
            [weakSelf.topMenuView setLoadingProgress:progress loading:loading];
        }
    };
    webView.scrollOffsetDidChange = ^(CGFloat offsetFromTop) {
        if (weakSelf.webview == weakWebView) {
            [weakSelf pageDidScrollToOffset:offsetFromTop];
        }
    };
}

/// Safari-Verhalten: Beim Scrollen nach unten schrumpft die Leiste zur Kapsel, nach oben oder am Seitenanfang kommt sie zurück.
- (void)pageDidScrollToOffset:(CGFloat)offset {
    CGFloat delta = offset - self.lastPageScrollOffset;
    self.lastPageScrollOffset = offset;
    if (offset < 24.0) {
        self.pageScrollTravel = 0.0;
        [self.topMenuView setCompact:NO animated:YES];
        return;
    }
    if ((delta > 0.0) != (self.pageScrollTravel > 0.0)) {
        self.pageScrollTravel = 0.0;
    }
    self.pageScrollTravel += delta;
    if (self.pageScrollTravel > 24.0 && offset > 60.0) {
        [self.topMenuView setCompact:YES animated:YES];
    } else if (self.pageScrollTravel < -140.0) {
        [self.topMenuView setCompact:NO animated:YES];
    }
}

- (void)browserHandlePrimaryAction {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        return;
    }

    if (self.addressPanel != nil) {
        [self handleAddressEditingSelectionAtPoint:self.remoteInputController.cursorView.frame.origin];
        return;
    }

    if ([self performTopBarActionAtPoint:self.remoteInputController.cursorView.frame.origin]) {
        return;
    }

    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    if (point.y < self.webview.topObscuredInset && !self.topMenuView.compact) {
        [self activateTopBarFocusMode];
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.topBarFocusActive) {
        UIView *preferredFocusItem = [self.topMenuView preferredFocusItem];
        if (preferredFocusItem != nil) {
            return @[preferredFocusItem];
        }
    }
    return [super preferredFocusEnvironments];
}

#pragma mark - BrowserTopBarViewDelegate

- (void)browserTopBarView:(__unused BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action {
    [self performTopBarAction:action];
}

#pragma mark - BrowserCommandHost (Befehlstabelle: Siri, Diktat, Selbsttest)

- (void)browserCommandPrepare {
    if (self.presentedViewController != nil) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }
    if (self.tabOverviewController.visible) {
        [self browserRemoteInputControllerDismissTabOverview];
    }
    [self endAddressEditingAnimated:YES];
    [self deactivateTopBarFocusMode];
}

- (UIView *)browserCommandFeedbackContainerView {
    // Fenster statt eigener Ansicht: liegt so auch über Tab-Übersicht und Zeiger.
    return self.view.window ?: self.view;
}

- (BOOL)browserCommandReaderAvailable {
    return self.topMenuView.readerAvailable;
}

- (BOOL)browserCommandReaderActive {
    return self.topMenuView.readerActive;
}

- (void)browserCommandToggleReader {
    [self toggleReaderMode];
}

#pragma mark Intelligente Funktionen (BrowserIntelligenceController)

- (void)browserCommandSummarize {
    [self.intelligenceController summarizeCurrentPage];
}

- (BOOL)browserCommandTranslate {
    return [self.intelligenceController translateCurrentPage];
}

- (void)browserCommandAskPage:(NSString *)question {
    [self.intelligenceController askCurrentPage:question];
}

- (void)browserSummarizePage {
    [self.intelligenceController summarizeCurrentPage];
}

- (void)browserTranslatePage {
    [self.intelligenceController translateCurrentPage];
}

- (void)browserCommandBeginAddressEditing {
    [self beginAddressEditing];
}

- (void)browserCommandOpenAddressOrSearch:(NSString *)text {
    [self openAddressOrSearch:text];
}

- (void)browserCommandSearch:(NSString *)query {
    NSURLRequest *request = [self.navigationService googleSearchRequestForQuery:query];
    if (request != nil) {
        [self.webview loadRequest:request];
    }
}

- (BOOL)browserCommandOpenAddress:(NSString *)address {
    NSString *withScheme = [address containsString:@"://"] ? address : [@"https://" stringByAppendingString:address];
    NSURLRequest *request = [self.navigationService requestForEnteredAddressString:withScheme];
    if (request == nil) {
        return NO;
    }
    [self.webview loadRequest:request];
    return YES;
}

- (BOOL)browserCommandGoBack {
    if (!self.webview.canGoBack) {
        return NO;
    }
    [self.webview goBack];
    return YES;
}

- (BOOL)browserCommandGoForward {
    if (!self.webview.canGoForward) {
        return NO;
    }
    [self.webview goForward];
    return YES;
}

- (BOOL)browserCommandReload {
    if (self.webview.request.URL == nil) {
        return NO;
    }
    [self.webview reload];
    return YES;
}

- (void)browserCommandGoHome {
    [self loadHomePage];
}

- (void)browserCommandNewTab {
    [self browserCreateNewTabLoadingHomePage:YES];
}

- (void)browserCommandCloseTab {
    [self browserTabOverviewControllerCloseTabAtIndex:self.viewModel.activeTabIndex];
}

- (void)browserCommandShowTabs {
    [self browserShowTabOverview];
}

- (NSNumber *)browserCommandSetFavorite:(NSNumber *)desired {
    NSURL *url = self.webview.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return nil;
    }
    BOOL current = [BrowserHistoryStore.sharedStore isFavoriteURL:url];
    BOOL target = desired != nil ? desired.boolValue : !current;
    if (target != current) {
        [self toggleFavoriteForCurrentPage];
    }
    return @([BrowserHistoryStore.sharedStore isFavoriteURL:url]);
}

- (NSString *)browserCommandAdBlockSiteName {
    return [BrowserContentBlocker exceptionKeyForURL:self.webview.request.URL];
}

- (BOOL)browserCommandAdBlockActiveForSite {
    return ![[BrowserContentBlocker sharedBlocker] isExceptionForURL:self.webview.request.URL];
}

- (void)browserCommandSetAdBlockActiveForSite:(BOOL)active {
    // Wie der Menüpunkt „Werbeblocker hier“ (BrowserMenuCoordinator adBlockSiteMenuItem): Ausnahme setzen, neu laden.
    NSURL *url = self.webview.request.URL;
    [[BrowserContentBlocker sharedBlocker] setException:!active forURL:url];
    [self.webview reload];
}

/// Animiert zu einem Scrollstand und aktualisiert danach Zeiger und Sitzung.
- (BOOL)scrollActivePageToOffsetY:(CGFloat)targetY {
    UIScrollView *scrollView = self.webview.scrollView;
    if (scrollView == nil) {
        return NO;
    }
    CGFloat minOffsetY = -scrollView.contentInset.top;
    CGFloat maxOffsetY = MAX(minOffsetY, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds) + scrollView.contentInset.bottom);
    CGPoint offset = scrollView.contentOffset;
    CGFloat clamped = MIN(MAX(targetY, minOffsetY), maxOffsetY);
    if (fabs(clamped - offset.y) < 1.0) {
        return NO;
    }
    offset.y = clamped;
    [UIView animateWithDuration:0.35 delay:0.0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [scrollView setContentOffset:offset animated:NO]; }
                     completion:^(__unused BOOL finished) {
        [self.remoteInputController pointerTargetsDidChange];
        [self.tabCoordinator persistSession];
    }];
    return YES;
}

- (BOOL)browserCommandScrollToTop {
    UIScrollView *scrollView = self.webview.scrollView;
    return [self scrollActivePageToOffsetY:-scrollView.contentInset.top];
}

- (BOOL)browserCommandScrollPageByFraction:(CGFloat)fraction {
    UIScrollView *scrollView = self.webview.scrollView;
    CGFloat delta = (CGRectGetHeight(scrollView.bounds) - scrollView.contentInset.top) * fraction;
    return [self scrollActivePageToOffsetY:scrollView.contentOffset.y + delta];
}

- (void)browserCommandShowMenu {
    [self showAdvancedMenu];
}

- (void)browserCommandShowHelp {
    [self showHintsAlert];
}

- (BOOL)browserCommandPageHasVideo {
    return [self.videoPlaybackCoordinator pageHasVideo];
}

- (void)browserCommandOpenVideoInPlayer {
    [self.videoPlaybackCoordinator openPageVideoInNativePlayer];
}

- (void)browserCommandSendVideoCommand:(NSString *)command {
    // Video unter dem Zeiger, sonst das erste sichtbare Video der Seite (ohne Punkt findet das Skript
    // nur ein laufendes oder das einzige <video>, Seiten haben aber oft versteckte weitere).
    BrowserWebView *webView = self.webview;
    if ([self pointerIsOverVideo]) {
        [webView sendVideoCommand:command atPoint:[self pointerPointInWebView]];
        return;
    }
    NSValue *firstVideo = webView.videoRects.firstObject;
    if (!webView.videoPlaying && firstVideo != nil) {
        CGRect rect = firstVideo.CGRectValue;
        [webView sendVideoCommand:command atPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect))];
        return;
    }
    [webView sendVideoCommand:command];
}

#pragma mark - BrowserMenuCoordinatorHost

- (BrowserWebView *)browserWebView {
    return self.webview;
}

- (NSString *)browserPreviousURL {
    return self.tabCoordinator.previousURL;
}

- (void)setBrowserPreviousURL:(NSString *)browserPreviousURL {
    self.tabCoordinator.previousURL = browserPreviousURL ?: @"";
}

- (NSUInteger)browserTextFontSize {
    return self.viewModel.textFontSize;
}

- (void)setBrowserTextFontSize:(NSUInteger)browserTextFontSize {
    self.viewModel.textFontSize = browserTextFontSize;
    self.preferencesStore.textFontSize = self.viewModel.textFontSize;
}

- (BOOL)browserTopMenuShowing {
    return self.viewModel.topNavigationBarVisible;
}

- (BOOL)browserFullscreenVideoPlaybackEnabled {
    return self.viewModel.fullscreenVideoPlaybackEnabled;
}

- (void)setBrowserFullscreenVideoPlaybackEnabled:(BOOL)browserFullscreenVideoPlaybackEnabled {
    self.viewModel.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
    self.preferencesStore.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
}

- (void)browserPresentViewController:(UIViewController *)viewController {
    [self deactivateTopBarFocusMode];
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserLoadHomePage {
    [self loadHomePage];
}

- (void)browserShowHints {
    [self showHintsAlert];
}

- (void)browserShowTabOverview {
    // Die Übersicht ist selbst ein Dialog. Liegt schon einer oben, scheitert die Präsentation still und die
    // Übersicht gälte als offen, ohne zu sehen zu sein (Zeiger weg, Tasten gehen ins Leere).
    if (self.presentedViewController != nil && !self.tabOverviewController.visible) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }
    [self deactivateTopBarFocusMode];
    [self.tabCoordinator prepareTabOverviewThumbnails];
    [self.tabOverviewController show];
}

- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    BrowserWebView *previous = self.webview;
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
    [self activeWebViewChangedFrom:previous];
}

/// Füllt den Streifen hinter der oberen Leiste mit der Farbe der Seite, wie Safari.
- (void)applyPageColorOfWebView:(BrowserWebView *)webView {
    [self.tabCoordinator refreshActiveTabUI];
    [self.topMenuView attachToScrollView:webView.scrollView];
    [self updateFavoriteButton];
    UIColor *color = webView.pageBackgroundColor ?: UIColor.blackColor;
    if ([self.view.backgroundColor isEqual:color]) {
        return;
    }
    [UIView animateWithDuration:0.25 animations:^{
        self.view.backgroundColor = color;
        // Container der WebViews aus dem Storyboard (schwarz) und alles bis zur Hauptansicht.
        for (UIView *view = webView.superview; view != nil && view != self.view; view = view.superview) {
            view.backgroundColor = color;
        }
        [webView setSurroundingColor:color];
    }];
    [self.topMenuView setPageBackgroundColor:color];
}

/// Nach Tabwechsel: Video im alten Tab anhalten, Zeigerziele, Bildschirmschoner und Now Playing auf den neuen Tab umstellen.
- (void)activeWebViewChangedFrom:(BrowserWebView *)previous {
    BrowserWebView *current = self.webview;
    if (previous == current) {
        return;
    }
    [self.topMenuView setCompact:NO animated:YES];
    self.pageScrollTravel = 0.0;
    self.lastPageScrollOffset = 0.0;
    if (previous != nil && previous.videoPlaying) {
        [previous sendVideoCommand:@"pause"];
    }
    [self observeClickTargetsOfWebView:current];
    [current refreshClickTargets];
    [self.remoteInputController pointerTargetsDidChange];
    [self.topMenuView setReaderAvailable:NO active:NO];
    [self updateReaderAvailability];
    [self.intelligenceController activeWebViewDidChange];
    UIApplication.sharedApplication.idleTimerDisabled = current.videoPlaying;
    [self.nowPlayingController updateWithMediaInfo:current.mediaInfo];
    [self applyPageColorOfWebView:current];
    [self startWebSubtitlesIfEnabled];
}

/// Untertitel (Weg B) im aktiven Tab starten, falls eingeschaltet (App-Start, Tabwechsel). Mehrfachaufruf harmlos.
- (void)startWebSubtitlesIfEnabled {
    if (!self.preferencesStore.webSubtitlesEnabled || self.webview == nil) {
        return;
    }
    [self prepareWebSubtitleControllerUsingStub:NO language:nil];
    if (!self.webSubtitleController.running || self.webSubtitleController.webView != self.webview) {
        [self.webSubtitleController startForWebView:self.webview userInitiated:NO];
    }
}

/// Legt den Untertitel-Controller (Weg B) an bzw. setzt die passende Erkennung: whisper (Modell nach
/// `autoSubtitlesLanguage` bzw. `language`, wie im nativen Player), den Platzhalter nur, wenn whisper oder ein
/// Modell fehlt oder `useStub` (Selbsttest). Eine vorhandene whisper-Erkennung mit gleicher Sprache bleibt
/// (Modell bleibt geladen); bei anderer Sprache wird der Controller vorher angehalten.
- (void)prepareWebSubtitleControllerUsingStub:(BOOL)useStub language:(nullable NSString *)language {
    NSString *wanted = language.length > 0 ? language : (self.preferencesStore.autoSubtitlesLanguage ?: @"en");
    if (self.webSubtitleController == nil) {
        self.webSubtitleController = [[BrowserWebSubtitleController alloc] initWithRecognizer:[BrowserSpeechRecognizerStub new]];
    }
    BrowserWebSubtitleController *controller = self.webSubtitleController;
    id<BrowserSpeechRecognizing> current = controller.recognizer;
    if (useStub) {
        if (![current isKindOfClass:BrowserSpeechRecognizerStub.class]) {
            [controller stop];
            controller.recognizer = [BrowserSpeechRecognizerStub new];
        }
        self.webSubtitleRecognizerHint = nil;
        return;
    }
    if ([current isKindOfClass:BrowserWhisperSpeechRecognizer.class]
        && [((BrowserWhisperSpeechRecognizer *)current).language isEqualToString:wanted]) {
        return;
    }
    BrowserWhisperSpeechRecognizer *whisper = [[BrowserWhisperSpeechRecognizer alloc] initWithLanguage:wanted];
    if (whisper == nil) {
        NSString *reason = [BrowserWhisperSpeechRecognizer unavailableReasonForLanguage:wanted] ?: @"nicht verfügbar";
        NSLog(@"[WebSubs] whisper nicht verfügbar (%@, Sprache %@): Platzhalter-Erkennung, zeigt nur den Pegel", reason, wanted);
        self.webSubtitleRecognizerHint = [NSString stringWithFormat:@"Untertitel: %@", reason];
        if (![current isKindOfClass:BrowserSpeechRecognizerStub.class]) {
            [controller stop];
            controller.recognizer = [BrowserSpeechRecognizerStub new];
        }
        return;
    }
    self.webSubtitleRecognizerHint = nil;
    __weak typeof(controller) weakController = controller;
    whisper.loadHandler = ^(BOOL loaded, NSString *message) {
        if (!loaded && weakController.running) {
            [weakController.overlay showHint:message duration:6.0];
        }
    };
    if (controller.running) {
        [controller stop];
    }
    controller.recognizer = whisper;
}

/// Hinweis, wenn statt whisper nur der Platzhalter läuft (einmal je Einschalten).
- (void)showWebSubtitleRecognizerHintIfNeeded {
    NSString *hint = self.webSubtitleRecognizerHint;
    if (hint.length > 0 && self.webSubtitleController.running) {
        [self.webSubtitleController.overlay showHint:hint duration:6.0];
    }
}

/// Schalter „Untertitel“ (Weg B): Einstellung speichern und den Abgriff im aktiven Tab starten bzw. beenden.
- (void)browserSetWebSubtitlesEnabled:(BOOL)enabled {
    self.preferencesStore.webSubtitlesEnabled = enabled;
    if (!enabled) {
        [self.webSubtitleController stop];
        return;
    }
    [self prepareWebSubtitleControllerUsingStub:NO language:nil];
    if (self.webview != nil) {
        [self.webSubtitleController startForWebView:self.webview userInitiated:YES];
        [self showWebSubtitleRecognizerHintIfNeeded];
    }
}

- (void)browserHideTopNav {
    [self deactivateTopBarFocusMode];
    self.viewModel.topNavigationBarVisible = NO;
    self.preferencesStore.topNavigationBarVisible = NO;
    [self.tabCoordinator setTopNavigationVisible:NO];
}

- (void)browserShowTopNav {
    self.viewModel.topNavigationBarVisible = YES;
    self.preferencesStore.topNavigationBarVisible = YES;
    [self.tabCoordinator setTopNavigationVisible:YES];
}

- (void)browserUpdateTextFontSize {
    [self updateTextFontSize];
}

- (void)browserCaptureSnapshotForCurrentTab {
    [self.tabCoordinator captureSnapshotForCurrentTab];
}

- (void)browserRecreateActiveWebViewPreservingCurrentURL {
    [self.tabCoordinator recreateActiveWebViewPreservingCurrentURL];
}

- (void)browserBringCursorToFront {
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];
}

- (void)browserPlayVideoUnderCursorIfAvailable {
    [self.videoPlaybackCoordinator playVideoUnderCursorIfAvailable];
}

#pragma mark - BrowserVideoPlaybackCoordinatorHost

- (BOOL)browserIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (CGPoint)browserDOMCursorPoint {
    return [self browserDOMPointForCursor];
}

- (UIViewController *)browserPresentedViewController {
    return self.presentedViewController;
}

- (NSString *)browserCurrentPageTitle {
    return self.webview.title;
}

#pragma mark - BrowserTabCoordinatorHost

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (void)browserTabCoordinatorUpdateTextFontSize {
    [self updateTextFontSize];
}

- (BOOL)browserTabCoordinatorIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (BOOL)browserTabCoordinatorIsTabOverviewVisible {
    return self.tabOverviewController.visible;
}

#pragma mark - BrowserTabOverviewControllerHost

- (BOOL)browserTabOverviewControllerCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (void)browserTabOverviewControllerSetCursorModeEnabled:(BOOL)enabled {
    [self.remoteInputController setCursorModeEnabled:enabled];
}

- (void)browserTabOverviewControllerPresentViewController:(UIViewController *)viewController {
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserTabOverviewControllerCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    BrowserWebView *previous = self.webview;
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
    [self activeWebViewChangedFrom:previous];
}

- (void)browserTabOverviewControllerSwitchToTabAtIndex:(NSInteger)tabIndex {
    BrowserWebView *previous = self.webview;
    [self.tabCoordinator switchToTabAtIndex:tabIndex];
    [self activeWebViewChangedFrom:previous];
}

- (void)browserTabOverviewControllerCloseTabAtIndex:(NSInteger)tabIndex {
    BrowserWebView *previous = self.webview;
    [self.tabCoordinator closeTabAtIndex:tabIndex];
    [self activeWebViewChangedFrom:previous];
}

#pragma mark - BrowserPageActionCoordinatorHost

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request {
    BrowserWebView *previous = self.webview;
    BOOL created = [self.tabCoordinator createNewTabWithRequest:request];
    [self activeWebViewChangedFrom:previous];
    return created;
}

#pragma mark - BrowserRemoteInputControllerHost

- (UIScrollView *)browserRemoteInputControllerActiveScrollView {
    return self.webview.scrollView;
}

- (UIViewController *)browserRemoteInputControllerPresentedViewController {
    return self.presentedViewController;
}

- (BOOL)browserRemoteInputControllerTopBarFocusActive {
    return self.topBarFocusActive;
}

- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus {
    return [self canActivateTopBarFocusMode];
}

- (void)browserRemoteInputControllerActivateTopBarFocus {
    [self activateTopBarFocusMode];
}

- (void)browserRemoteInputControllerDeactivateTopBarFocus {
    [self deactivateTopBarFocusMode];
}

- (BOOL)browserRemoteInputControllerTabOverviewVisible {
    return self.tabOverviewController.visible;
}

- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point {
    return [self.tabOverviewController containsPoint:point];
}

- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point {
    return [self.tabOverviewController handleSelectionAtPoint:point];
}

- (void)browserRemoteInputControllerDismissTabOverview {
    [self.tabOverviewController dismiss];
}

- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction {
    [self.tabOverviewController handleAlternateAction];
}

- (void)browserRemoteInputControllerHandlePrimaryAction {
    [self browserHandlePrimaryAction];
}

- (BOOL)browserRemoteInputControllerHandleMenuPress {
    // Oberste Ebene zuerst: Dialog, dann Karte „Zusammenfassung“ (bzw. „Übersetzen?“ für diesen Host ablehnen),
    // erst danach das Vollbild der Seite, das darunter liegt.
    if (self.presentedViewController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }
    if ([self.intelligenceController handleMenuPress]) {
        return YES;
    }
    // Vollbild der Seite verlassen. Klappt das nicht, geht der nächste Druck normal weiter.
    if (self.webview.pageFullscreen && CACurrentMediaTime() - self.lastFullscreenExitAttempt > 2.0) {
        self.lastFullscreenExitAttempt = CACurrentMediaTime();
        [self.webview exitPageFullscreen];
        return YES;
    }
    if (self.addressPanel != nil) {
        [self endAddressEditingAnimated:YES];
        return YES;
    }
    // Reader läuft: Zurück beendet zuerst den Reader und zeigt die Originalseite.
    if (self.topMenuView.readerActive) {
        [self toggleReaderMode];
        return YES;
    }
    if (self.webview.canGoBack) {
        [self.webview goBack];
        return YES;
    }
    // Erste Seite: wie jede tvOS-App zurück zum Home-Bildschirm.
    [self.tabCoordinator persistSession];
    return NO;
}

/// Steht der Zeiger auf einem Video? Gilt auch, wenn er gerade ausgeblendet ist (Video läuft, Zeiger ruht).
- (BOOL)pointerIsOverVideo {
    BrowserWebView *webView = self.webview;
    if (webView == nil || !self.remoteInputController.cursorModeEnabled) {
        return NO;
    }
    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:webView];
    for (NSValue *value in [webView videoRects]) {
        if (CGRectContainsPoint(value.CGRectValue, point)) {
            return YES;
        }
    }
    return NO;
}

- (CGPoint)pointerPointInWebView {
    return [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
}

- (void)browserRemoteInputControllerHandlePlayPausePress {
    // Hinweis „Übersetzen?“ sichtbar: Play/Pause nimmt ihn an.
    if (self.presentedViewController == nil && self.addressPanel == nil && [self.intelligenceController handlePlayPausePress]) {
        return;
    }
    if (self.presentedViewController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if (self.addressPanel != nil) {
        [self showAddressKeyboard];
        return;
    }
    // Läuft ein Video oder steht der Zeiger auf einem, steuert Play/Pause das Video.
    if (self.webview != nil && (self.webview.videoPlaying || [self pointerIsOverVideo])) {
        [self.webview sendVideoCommand:@"toggle" atPoint:[self pointerPointInWebView]];
        return;
    }
    [self requestURLorSearchInput];
}

/// Play/Pause lang oder doppelt bei offenem Dialog bzw. offener Zusammenfassung: nur diese Ebene schließen
/// (wie Play/Pause kurz), nicht die Suche oder das Seitenmenü darüber bzw. stattdessen öffnen.
- (BOOL)closeDialogForPlayPause {
    if (self.presentedViewController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
        return YES;
    }
    if (self.intelligenceController.summaryVisible) {
        [self.intelligenceController dismissSummary];
        return YES;
    }
    return NO;
}

- (void)browserRemoteInputControllerHandlePlayPauseLongPress {
    if ([self closeDialogForPlayPause]) {
        return;
    }
    // Direkt in die Adresseingabe, bereit fürs Diktat mit der Siri-Taste.
    [self beginAddressEditing];
}

- (void)browserRemoteInputControllerHandleAdvancedMenuPress {
    if ([self closeDialogForPlayPause]) {
        return;
    }
    // Aufklapp-Bereich der Adresse nicht unter der Seitenleiste offen lassen.
    [self endAddressEditingAnimated:YES];
    [self showAdvancedMenu];
}

- (BOOL)browserRemoteInputControllerOverlayCardVisible {
    return self.presentedViewController == nil && self.intelligenceController.summaryVisible;
}

- (void)browserRemoteInputControllerDismissOverlayCard {
    [self.intelligenceController dismissSummary];
}

- (UIView *)browserRemoteInputControllerLensSourceView {
    // Im Aufklapp-Bereich keine Linse: Kacheln liegen über der Seite, nicht in ihr.
    return self.addressPanel != nil ? nil : self.webview;
}

- (BOOL)browserRemoteInputControllerLensAllowedForTarget:(CGRect)target {
    // Ziele in der oberen Leiste: Die Linse würde die Webseite darunter zeigen und Titel bzw. Symbole verdecken.
    if (self.topMenuView != nil && !self.topMenuView.hidden) {
        CGRect chrome = [self.view convertRect:self.topMenuView.chromeFrame fromView:self.topMenuView];
        if (CGRectIntersectsRect(CGRectInset(chrome, -8.0, -8.0), target)) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)browserRemoteInputControllerAddressPanelActive {
    return self.addressPanel != nil && self.presentedViewController == nil;
}

- (CGFloat)browserRemoteInputControllerCornerRadiusForTarget:(CGRect)target {
    if (self.addressPanel == nil) {
        return -1.0;
    }
    CGRect field = [self.topMenuView convertRect:self.topMenuView.addressFieldFrame toView:self.view];
    if (CGRectEqualToRect(CGRectIntegral(field), CGRectIntegral(target))) {
        return CGRectGetHeight(field) / 2.0;
    }
    return [self.addressPanel cornerRadiusForTargetRect:target inView:self.view];
}

- (UIColor *)browserRemoteInputControllerGlowColorForTarget:(CGRect)target {
    if (self.addressPanel != nil) {
        return nil; // Standardblau wie die Magnetic Buttons
    }
    BrowserWebView *webView = self.webview;
    if (webView == nil || webView.window == nil) {
        return nil;
    }
    CGPoint center = [webView convertPoint:CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target)) fromView:self.view];
    if (!CGRectContainsPoint(webView.bounds, center)) {
        return nil;
    }
    if ([self topBarAcceptsPointer]) {
        CGRect bar = self.topMenuView.compact ? [self.topMenuView convertRect:self.topMenuView.chromeFrame toView:self.view]
                                              : [self.topMenuView.superview convertRect:self.topMenuView.frame toView:self.view];
        if (CGRectContainsPoint(CGRectInset(bar, -20, -20), CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target)))) {
            return nil;
        }
    }
    return [webView glowColorAtPoint:center];
}

- (BOOL)browserRemoteInputControllerTargetIsText:(CGRect)target {
    BrowserWebView *webView = self.webview;
    if (self.addressPanel != nil || webView == nil || webView.window == nil) {
        return NO;
    }
    CGPoint center = [webView convertPoint:CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target)) fromView:self.view];
    if (!CGRectContainsPoint(webView.bounds, center) || ![self browserRemoteInputControllerLensAllowedForTarget:target]) {
        return NO; // Knöpfe der oberen Leiste
    }
    return [webView isTextTargetAtPoint:center];
}

- (NSArray<NSValue *> *)browserRemoteInputControllerPointerTargets {
    if (self.addressPanel != nil) {
        // Bearbeiten-Zustand: nur Diktierfeld und Kacheln; die Seite darunter ist gedimmt und nicht erreichbar.
        NSMutableArray<NSValue *> *panelTargets = [NSMutableArray array];
        [self.topMenuView enumeratePointerTargetsUsingBlock:^(CGRect frame, __unused BrowserTopBarAction action) {
            [panelTargets addObject:[NSValue valueWithCGRect:[self.topMenuView convertRect:frame toView:self.view]]];
        }];
        [panelTargets addObjectsFromArray:[self.addressPanel pointerTargetRectsInView:self.view]];
        return panelTargets;
    }
    NSMutableArray<NSValue *> *targets = [NSMutableArray array];
    BrowserWebView *webView = self.webview;
    BOOL topBarVisible = [self topBarAcceptsPointer];
    CGRect topBarFrame = CGRectNull;
    if (topBarVisible) {
        topBarFrame = self.topMenuView.compact ? [self.topMenuView convertRect:self.topMenuView.chromeFrame toView:self.view]
                                               : [self.topMenuView.superview convertRect:self.topMenuView.frame toView:self.view];
    }

    if (webView != nil && webView.window != nil) {
        [self observeClickTargetsOfWebView:webView];
        CGRect visible = [webView convertRect:webView.bounds toView:self.view];
        for (NSValue *value in [webView clickTargetRects]) {
            CGRect rect = CGRectIntersection([webView convertRect:value.CGRectValue toView:self.view], visible);
            if (CGRectIsEmpty(rect)) {
                continue;
            }
            // Was unter der oberen Leiste liegt, ist nicht erreichbar.
            if (topBarVisible && CGRectContainsPoint(topBarFrame, CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)))) {
                continue;
            }
            [targets addObject:[NSValue valueWithCGRect:rect]];
        }
    }

    if (topBarVisible) {
        [self.topMenuView enumeratePointerTargetsUsingBlock:^(CGRect frame, __unused BrowserTopBarAction action) {
            [targets addObject:[NSValue valueWithCGRect:[self.topMenuView convertRect:frame toView:self.view]]];
        }];
    }
    return targets;
}

/// Clickpad links: über einem laufenden Video 10 s zurück, sonst zum vorigen Element (Links, Knöpfe, Videos).
/// Seite zurück geht über die Zurück-Taste.
- (void)browserRemoteInputControllerNavigateBack {
    if ([self pointerIsOverVideo] && self.webview.videoPlaying) {
        [self.webview sendVideoCommand:@"seek:-10" atPoint:[self pointerPointInWebView]];
        return;
    }
    [self.remoteInputController stepTargetBy:-1];
}

/// Ziele für den Sprung: Zeigerziele der Seite plus Videos ohne eigene Bedienelemente;
/// die obere Leiste nur am Seitenanfang, damit der Sprung nach oben sonst die Seite scrollt.
- (NSArray<NSValue *> *)browserRemoteInputControllerStepTargets {
    NSArray<NSValue *> *pointerTargets = [self browserRemoteInputControllerPointerTargets];
    if (self.addressPanel != nil) {
        return pointerTargets;
    }
    BOOL atTop = self.lastPageScrollOffset < 24.0;
    CGRect barFrame = [self topBarAcceptsPointer] ? [self.topMenuView convertRect:self.topMenuView.chromeFrame toView:self.view] : CGRectNull;
    NSMutableArray<NSValue *> *targets = [NSMutableArray array];
    for (NSValue *value in pointerTargets) {
        CGRect rect = value.CGRectValue;
        if (!atTop && !CGRectIsNull(barFrame) && CGRectIntersectsRect(rect, barFrame)) {
            continue;
        }
        [targets addObject:value];
    }
    BrowserWebView *webView = self.webview;
    if (webView != nil) {
        CGRect visible = [webView convertRect:webView.bounds toView:self.view];
        for (NSValue *value in [webView videoRects]) {
            CGRect video = CGRectIntersection([webView convertRect:value.CGRectValue toView:self.view], visible);
            if (CGRectIsEmpty(video) || CGRectGetMidY(video) < CGRectGetMaxY(barFrame)) {
                continue;
            }
            BOOL hasControls = NO;
            for (NSValue *target in pointerTargets) {
                CGRect r = target.CGRectValue;
                if (CGRectContainsPoint(video, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)))) {
                    hasControls = YES;
                    break;
                }
            }
            if (!hasControls) {
                [targets addObject:[NSValue valueWithCGRect:video]];
            }
        }
    }
    return targets;
}

- (void)browserRemoteInputControllerOpenAddressBar {
    // Zweimal oben: wie Klick auf die Adresse (Leiste ausklappen, Tastatur offen, Karte darunter).
    [self beginAddressEditing];
}

/// Clickpad rechts: über einem laufenden Video 10 s vor, sonst zum nächsten Element.
- (void)browserRemoteInputControllerNavigateForward {
    if ([self pointerIsOverVideo] && self.webview.videoPlaying) {
        [self.webview sendVideoCommand:@"seek:10" atPoint:[self pointerPointInWebView]];
        return;
    }
    [self.remoteInputController stepTargetBy:1];
}

- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled {
    self.webview.userInteractionEnabled = enabled;
}

- (void)browserRemoteInputControllerPersistSession {
    [self.tabCoordinator persistSession];
}

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    return [self browserPageActionCoordinatorCreateNewTabWithRequest:request];
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)navigationType;
    [self.tabCoordinator prepareTabForRequest:request webView:webView];
    return YES;
}

- (void)webViewDidStartLoad:(id)webView {
    if ([webView isKindOfClass:BrowserWebView.class]) {
        [self observeClickTargetsOfWebView:webView];
    }
    [self.tabCoordinator webViewDidStartLoad:webView];
    if (webView == self.webview) {
        // Neue Seite: Reader zu Ende, Lesbarkeit unbekannt.
        self.readerCheckGeneration++;
        [self.topMenuView setReaderAvailable:NO active:NO];
        [self.intelligenceController pageDidStartLoadInWebView:webView];
    }
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    if (webView == self.webview) {
        [self scheduleReaderAvailabilityChecks];
        [self.intelligenceController pageDidFinishLoadInWebView:webView];
    }
    if (webView == self.webview && self.webview.request.URL != nil) {
        [BrowserHistoryStore.sharedStore recordVisitWithURL:self.webview.request.URL title:[self currentSiteDisplayName]];
    }
    if (self.tabOverviewController.visible) {
        BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
        NSInteger tabIndex = tab != nil ? [self.viewModel.tabs indexOfObject:tab] : NSNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.tabOverviewController.visible) {
                return;
            }
            if (tabIndex != NSNotFound) {
                [self.tabOverviewController updateCardAtIndex:tabIndex];
            } else {
                [self.tabOverviewController reload];
            }
        });
    }
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
#if DEBUG
    NSLog(@"[Load] Fehler %@ %ld %@ (%@)", error.domain, (long)error.code,
          [error.userInfo[NSURLErrorFailingURLErrorKey] absoluteString] ?: @"-", error.localizedDescription);
#endif
    BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSURL *failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    NSURLRequest *currentRequest = [webView request];
    NSString *currentRequestURLString = currentRequest.URL.absoluteString ?: @"";
    if (failingURL != nil &&
        currentRequestURLString.length > 0 &&
        ![failingURL.absoluteString isEqualToString:currentRequestURLString]) {
        return;
    }

    if (tab == self.tabCoordinator.activeTab) {
        [self.topMenuView.loadingSpinner stopAnimating];
    }
    if (tab != self.tabCoordinator.activeTab) {
        return;
    }
    if ([self.navigationService shouldIgnoreLoadError:error]) {
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Seite konnte nicht geladen werden"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Bei Google suchen"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            if (searchRequest != nil) {
                [weakSelf.webview loadRequest:searchRequest];
            }
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Neu laden"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Adresse oder Suche"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf beginAddressEditing];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"Abbrechen" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Presses / Touches

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesBegan:presses withEvent:event];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesCancelled:presses withEvent:event];
    [super pressesCancelled:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
#if DEBUG
    NSLog(@"[Keys] Ende Typ=%ld presented=%@ tabs=%d", (long)presses.anyObject.type,
          NSStringFromClass(self.presentedViewController.class), self.tabOverviewController.visible);
#endif
    if ([self.remoteInputController handlePressesEnded:presses withEvent:event]) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesBegan:touches withEvent:event]) {
        return;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesMoved:touches withEvent:event]) {
        return;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesCancelled:touches withEvent:event];
}

@end
