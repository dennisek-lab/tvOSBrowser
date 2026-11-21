#import "BrowserSubtitleController.h"
#import "BrowserLocalization.h"

#import "BrowserAppleSpeechTranscriber.h"
#import "BrowserNativeVideoPlayerViewController.h"
#import "BrowserPreferencesStore.h"
#import "BrowserSubtitleAudioTapSource.h"
#import "BrowserSubtitleEngine.h"
#import "BrowserSubtitleHLSAudioSource.h"
#import "BrowserSubtitleOverlayView.h"
#import "BrowserSubtitlePipeline.h"
#import "BrowserSubtitleProgressiveAudioSource.h"
#import "BrowserSubtitleTranslator.h"

#import <objc/runtime.h>

static NSString * const kSubtitleControllerLogPrefix = @"[Subtitles]";
static NSString * const kSubtitleMenuIdentifier = @"tvbrowser.autoSubtitles";
static NSString * const kSubtitleStartHoldReason = @"Untertitel";
/// Höchstens so lange wartet der Start auf die ersten Untertitel (vorauslesende Quellen). Der Player puffert in der
/// Zeit ohnehin; am Gerät waren die ersten 4 s nach 0,4–0,7 s fertig.
static const NSTimeInterval kSubtitleStartHoldTimeout = 1.0;
/// Zusätzlich, wenn Apple übersetzen könnte (feste Untertitelsprache): der erste Abschnitt wartet auf die Übersetzung.
static const NSTimeInterval kSubtitleStartHoldTranslationExtra = 0.6;
static const void *kSubtitleControllerAssociationKey = &kSubtitleControllerAssociationKey;

@interface BrowserSubtitleController ()
@property (nonatomic, weak) AVPlayerViewController *playerViewController;
@property (nonatomic, strong) NSURL *playbackURL;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (nonatomic, copy) NSArray<NSHTTPCookie *> *cookies;
@property (nonatomic, strong) BrowserPreferencesStore *preferences;
@property (nonatomic, strong) BrowserSubtitleOverlayView *overlay;
@property (nonatomic, strong, nullable) id timeObserver;
@property (nonatomic, weak) AVPlayer *observedPlayer;
@property (nonatomic, strong) NSMutableArray<BrowserSubtitleCue *> *cues;  // Hauptthread, nach Start sortiert
@property (nonatomic, strong, nullable) id<BrowserSubtitleAudioSource> source;
@property (nonatomic, strong, nullable) BrowserSubtitleEngine *engine;
/// Apples Spracherkennung statt whisper (Einstellung SubtitlesRecognizer=apple, docs/ERWEITERUNGEN.md 10.10), sonst nil.
@property (atomic, strong, nullable) BrowserAppleSpeechTranscriber *appleSpeech;
@property (nonatomic, strong) BrowserSubtitlePipeline *pipeline;
@property (nonatomic, strong) dispatch_queue_t engineQueue;
/// Schon versuchte Quellen („mp4“, „tap“, „hls“), damit jede Rückfallstufe nur einmal kommt.
@property (nonatomic, strong) NSMutableSet<NSString *> *triedSources;
@property (nonatomic) BOOL suppressedByExistingSubtitles;
@property (nonatomic) BOOL userForcedOn;  // im Player-Menü eingeschaltet: auch neben vorhandenen Untertiteln
/// Ob erkannte Untertitel eingeblendet werden. Aus, sobald der Nutzer im Menü „Aus“ wählt oder vorhandene Untertitel
/// laufen: dann bleibt die Anzeige leer, auch wenn noch vorausgewertete oder gerade fertig gewordene Sätze vorliegen.
@property (nonatomic) BOOL cuesVisible;
/// Bei „auto“: für dieses Video festgelegte Sprache (überlebt Neustarts der Erkennung, z. B. Tonquellenwechsel).
@property (nonatomic, copy, nullable) NSString *sessionLanguage;
@property (nonatomic) BOOL streamingPlaylist;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;
@property (nonatomic) BOOL detached;
@property (nonatomic) BOOL holdingStart;
@property (nonatomic) NSTimeInterval lastSourceUpdate;
@property (nonatomic) NSTimeInterval lastSummary;
@property (nonatomic) NSTimeInterval lastMenuCheck;
@property (nonatomic) float lastRate;
// Versatzmessung (Hauptthread): Anzeigezeitpunkt − Sprechbeginn laut whisper, je neu eingeblendetem Satz.
@property (nonatomic, strong) NSMutableArray<NSNumber *> *offsets;
@property (nonatomic) NSTimeInterval lastMeasuredStart;
@end

@implementation BrowserSubtitleController

/// Hängt sich über den Einhängepunkt des nativen Players ein (BrowserNativeVideoPlayerViewController.h),
/// der Player selbst muss dafür nicht geändert werden.
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:BrowserNativePlayerDidCreatePlayerItemNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            BrowserNativeVideoPlayerViewController *player = note.object;
            if (![player isKindOfClass:BrowserNativeVideoPlayerViewController.class] ||
                objc_getAssociatedObject(player, kSubtitleControllerAssociationKey) != nil) {
                return;
            }
            BrowserSubtitleController *controller = [BrowserSubtitleController attachToPlayerViewController:player
                                                                                               playbackURL:player.videoURL
                                                                                            requestHeaders:player.requestHeaders
                                                                                                   cookies:player.requestCookies];
            objc_setAssociatedObject(player, kSubtitleControllerAssociationKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:BrowserNativePlayerWillEndSessionNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            BrowserSubtitleController *controller = objc_getAssociatedObject(note.object, kSubtitleControllerAssociationKey);
            [controller detach];
            objc_setAssociatedObject(note.object, kSubtitleControllerAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }];
    });
}

+ (NSString *)menuTitle {
    return BLS(@"Automatische Untertitel");
}

+ (NSString *)menuDetailForPreferences:(BrowserPreferencesStore *)preferences {
    return preferences.autoSubtitlesEnabled ? BLS(@"An") : BLS(@"Aus");
}

+ (instancetype)attachToPlayerViewController:(AVPlayerViewController *)playerViewController
                                 playbackURL:(NSURL *)playbackURL
                              requestHeaders:(NSDictionary<NSString *,NSString *> *)requestHeaders
                                     cookies:(NSArray<NSHTTPCookie *> *)cookies {
    BrowserSubtitleController *controller = [[self alloc] init];
    controller.playerViewController = playerViewController;
    controller.playbackURL = playbackURL;
    controller.requestHeaders = requestHeaders ?: @{};
    controller.cookies = cookies ?: @[];
    [controller attach];
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _preferences = [BrowserPreferencesStore new];
        _cues = [NSMutableArray array];
        _offsets = [NSMutableArray array];
        _lastMeasuredStart = -INFINITY;
        _triedSources = [NSMutableSet set];
        _engineQueue = dispatch_queue_create("tvbrowser.subtitles.whisper",
                                             dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        __weak typeof(self) weakSelf = self;
        dispatch_queue_t engineQueue = _engineQueue;
        _pipeline = [[BrowserSubtitlePipeline alloc] initWithTranscriber:^(NSData *samples, NSTimeInterval startTime,
                                                                           void (^completion)(NSArray<BrowserSubtitleCue *> *)) {
            BrowserSubtitleEngine *engine = weakSelf.engine;
            BrowserSubtitleTranscriber whisper = ^(NSData *whisperSamples, NSTimeInterval whisperStart, void (^whisperCompletion)(NSArray<BrowserSubtitleCue *> *)) {
                dispatch_async(engineQueue, ^{
                    whisperCompletion(engine != nil ? [engine transcribeSamples:whisperSamples.bytes count:whisperSamples.length / sizeof(float) startTime:whisperStart] : nil);
                });
            };
            BrowserAppleSpeechTranscriber *apple = weakSelf.appleSpeech;
            if (apple != nil) {
                [apple transcribeSamples:samples startTime:startTime whisper:whisper completion:completion];
            } else {
                whisper(samples, startTime, completion);
            }
        }];
        _pipeline.cueHandler = ^(NSArray<BrowserSubtitleCue *> *cues, NSTimeInterval replaceFrom, NSTimeInterval windowStart, NSTimeInterval windowEnd) {
            [weakSelf addCues:cues replacingTentativeFrom:replaceFrom];
        };
        _pipeline.firstWindowHandler = ^(NSTimeInterval windowStart, NSTimeInterval windowEnd) {
            [weakSelf firstWindowReadyFrom:windowStart to:windowEnd];
        };
        _pipeline.failureHandler = ^(id<BrowserSubtitleAudioSource> source, NSString *reason) {
            [weakSelf source:source didFailWithReason:reason];
        };
    }
    return self;
}

- (void)dealloc {
    // Die letzte Referenz kann in einem Block einer Hintergrund-Queue liegen: dann kein detach (UIKit abseits des
    // Main-Threads). Quelle und Engine dürfen von jedem Thread gestoppt werden.
    if (_detached) {
        return;
    }
    if (NSThread.isMainThread) {
        [self detach];
        return;
    }
    _source.delegate = nil;
    [_source stop];
    [_engine cancel];
}

#pragma mark Einhängen

- (void)attach {
    AVPlayerViewController *playerViewController = self.playerViewController;
    UIView *container = playerViewController.contentOverlayView;
    if ([playerViewController isKindOfClass:BrowserNativeVideoPlayerViewController.class]) {
        BrowserNativeVideoPlayerViewController *player = (BrowserNativeVideoPlayerViewController *)playerViewController;
        container = player.subtitleOverlayView ?: container;  // gemeinsame Untertitelebene des Players
        self.streamingPlaylist = player.isStreamingPlaylist;
    }
    self.overlay = [[BrowserSubtitleOverlayView alloc] initWithFrame:container.bounds];
    [container addSubview:self.overlay];
    self.cuesVisible = self.preferences.autoSubtitlesEnabled && !self.existingSubtitlesShown;
    [self installMenu];
    [self observePlayer:playerViewController.player];
    NSLog(@"%@ eingehängt, an=%d, Sprache %@, whisper=%d, Modell %@", kSubtitleControllerLogPrefix,
          self.preferences.autoSubtitlesEnabled, self.preferences.autoSubtitlesLanguage,
          [BrowserSubtitleEngine isCompiledWithWhisper],
          [BrowserSubtitleEngine modelPathForLanguage:self.preferences.autoSubtitlesLanguage].lastPathComponent ?: @"–");
    if (self.cuesVisible) {
        [self startRecognition];
    }
}

/// Stream-Untertitel oder WebVTT der Seite aktiv: dann keine automatische Erkennung.
- (BOOL)existingSubtitlesShown {
    AVPlayerViewController *playerViewController = self.playerViewController;
    if ([playerViewController isKindOfClass:BrowserNativeVideoPlayerViewController.class]) {
        return ((BrowserNativeVideoPlayerViewController *)playerViewController).isShowingExistingSubtitles;
    }
    return NO;
}

- (void)checkExistingSubtitles {
    BOOL existing = self.existingSubtitlesShown;
    if (existing && self.running && !self.userForcedOn) {
        NSLog(@"%@ vorhandene Untertitel aktiv, Erkennung pausiert", kSubtitleControllerLogPrefix);
        self.suppressedByExistingSubtitles = YES;
        self.cuesVisible = NO;
        [self stopRecognitionClearing:NO];
        [self.overlay showStatus:BLS(@"Video hat eigene Untertitel") duration:4.0];
        [self installMenu];
    } else if (!existing && self.suppressedByExistingSubtitles) {
        // Eigene Untertitel des Videos im Untertitel-Menü des Players auf „Aus“ gestellt: Der Nutzer will gerade keine
        // Untertitel. Früher sprang hier die automatische Erkennung wieder an. Jetzt bleibt sie aus, bis er im Menü
        // „Automatische Untertitel“ „An“ wählt (das Menü zeigt „Aus“).
        self.suppressedByExistingSubtitles = NO;
        NSLog(@"%@ vorhandene Untertitel ausgeschaltet – automatische bleiben aus", kSubtitleControllerLogPrefix);
        [self installMenu];
    }
}

- (void)detach {
    if (self.detached) {
        return;
    }
    self.detached = YES;
    [self stopRecognitionClearing:NO];
    if (self.timeObserver != nil) {
        [self.observedPlayer removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }
    [self.overlay removeFromSuperview];
    self.overlay = nil;  // UIView hier auf dem Main-Thread freigeben, nicht im letzten Queue-Block
    AVPlayerViewController *playerViewController = self.playerViewController;
    if (playerViewController != nil) {
        playerViewController.transportBarCustomMenuItems = [self menuItemsWithoutOwn:playerViewController.transportBarCustomMenuItems];
    }
    NSLog(@"%@ ausgehängt, %lu Untertitel, Speicher %.0f MB, %@", kSubtitleControllerLogPrefix,
          (unsigned long)self.cues.count, [BrowserSubtitleEngine currentMemoryFootprintMB], [self offsetSummary]);
}

- (void)observePlayer:(AVPlayer *)player {
    if (player == nil || self.timeObserver != nil) {
        return;
    }
    self.observedPlayer = player;
    __weak typeof(self) weakSelf = self;
    self.timeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.05, NSEC_PER_SEC)
                                                             queue:dispatch_get_main_queue()
                                                        usingBlock:^(CMTime time) {
        [weakSelf playerTimeDidChange:time];
    }];
}

#pragma mark Menü im Player

- (NSArray<UIMenuElement *> *)menuItemsWithoutOwn:(NSArray<UIMenuElement *> *)items {
    NSMutableArray<UIMenuElement *> *result = [NSMutableArray array];
    for (UIMenuElement *element in items ?: @[]) {
        if ([element isKindOfClass:UIMenu.class] && [((UIMenu *)element).identifier isEqualToString:kSubtitleMenuIdentifier]) {
            continue;
        }
        [result addObject:element];
    }
    return result;
}

- (BOOL)menuInstalled {
    for (UIMenuElement *element in self.playerViewController.transportBarCustomMenuItems ?: @[]) {
        if ([element isKindOfClass:UIMenu.class] && [((UIMenu *)element).identifier isEqualToString:kSubtitleMenuIdentifier]) {
            return YES;
        }
    }
    return NO;
}

/// Was „Automatisch“ gerade bedeutet: erkannte Sprache, „wird erkannt …“ (läuft, noch offen) oder nichts.
- (nullable NSString *)automaticLanguageDetail {
    if (self.sessionLanguage.length > 0) {
        return [BrowserSubtitleEngine displayNameForLanguage:self.sessionLanguage];
    }
    return self.running && [self.engine.language isEqualToString:@"auto"] ? BLS(@"wird erkannt …") : nil;
}

- (UIMenu *)buildMenu {
    __weak typeof(self) weakSelf = self;
    // Häkchen danach, ob in diesem Video automatische Untertitel gezeigt werden (nicht nach der globalen Einstellung:
    // neben eigenen Untertiteln des Videos stehen sie still und das Menü zeigt „Aus“).
    BOOL enabled = self.cuesVisible;
    UIAction *on = [UIAction actionWithTitle:BLS(@"An") image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf setEnabledFromMenu:YES];
    }];
    on.state = enabled ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *off = [UIAction actionWithTitle:BLS(@"Aus") image:nil identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf setEnabledFromMenu:NO];
    }];
    off.state = enabled ? UIMenuElementStateOff : UIMenuElementStateOn;
    // Als Einzelauswahl: das System setzt das Häkchen sofort beim Auswählen, nicht erst beim nächsten Menüaufbau.
    UIMenu *toggle = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                   options:UIMenuOptionsDisplayInline | UIMenuOptionsSingleSelection children:@[on, off]];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithObjects:toggle, nil];

    NSString *language = self.preferences.autoSubtitlesLanguage;
    if ([BrowserSubtitleEngine hasMultilingualModel]) {
        NSString *automaticDetail = [self automaticLanguageDetail];
        NSMutableArray<UIMenuElement *> *languages = [NSMutableArray array];
        for (NSString *code in [BrowserSubtitleEngine selectableLanguages]) {
            NSString *title = [BrowserSubtitleEngine displayNameForLanguage:code];
            if ([code isEqualToString:@"auto"] && automaticDetail != nil) {
                title = [NSString stringWithFormat:@"%@ (%@)", title, automaticDetail];
            }
            UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *a) {
                [weakSelf setLanguageFromMenu:code];
            }];
            action.state = [language isEqualToString:code] ? UIMenuElementStateOn : UIMenuElementStateOff;
            [languages addObject:action];
        }
        // Kurz halten, die Zeile im Menü ist schmal: „Sprache: Auto · Deutsch“, „Sprache: Auto …“, „Sprache: Deutsch“.
        NSString *current = [BrowserSubtitleEngine displayNameForLanguage:language];
        if ([language isEqualToString:@"auto"]) {
            current = self.sessionLanguage.length > 0
                ? [NSString stringWithFormat:BLS(@"Auto · %@"), [BrowserSubtitleEngine displayNameForLanguage:self.sessionLanguage]]
                : (automaticDetail != nil ? BLS(@"Auto …") : current);
        }
        [children addObject:[UIMenu menuWithTitle:[NSString stringWithFormat:BLS(@"Sprache: %@"), current] image:nil identifier:nil
                                          options:UIMenuOptionsSingleSelection children:languages]];
    } else {
        // Nur das englische Modell im Paket (tools/fetch_whisper_model.sh base-q5_1 für weitere Sprachen).
        UIAction *info = [UIAction actionWithTitle:BLS(@"Sprache: nur Englisch (Modell)") image:nil identifier:nil
                                           handler:^(__unused __kindof UIAction *a) {}];
        info.attributes = UIMenuElementAttributesDisabled;
        [children addObject:info];
    }
    // Eigenes Symbol (Sprache → Text), damit der Knopf nicht wie der Untertitel-Knopf des Systems daneben aussieht.
    UIImage *image = [UIImage systemImageNamed:@"waveform.and.mic"] ?: [UIImage systemImageNamed:@"captions.bubble"];
    return [UIMenu menuWithTitle:[BrowserSubtitleController menuTitle] image:image identifier:kSubtitleMenuIdentifier
                         options:0 children:children];
}

- (void)installMenu {
    AVPlayerViewController *playerViewController = self.playerViewController;
    if (playerViewController == nil || self.detached) {
        return;
    }
    NSMutableArray<UIMenuElement *> *items = [[self menuItemsWithoutOwn:playerViewController.transportBarCustomMenuItems] mutableCopy];
    [items addObject:[self buildMenu]];
    playerViewController.transportBarCustomMenuItems = items;
}

- (void)setEnabledFromMenu:(BOOL)enabled {
    NSLog(@"%@ Menü: %@", kSubtitleControllerLogPrefix, enabled ? @"an" : @"aus");
    self.preferences.autoSubtitlesEnabled = enabled;
    self.userForcedOn = enabled;
    self.cuesVisible = enabled;
    if (enabled) {
        self.suppressedByExistingSubtitles = NO;
        [self startRecognition];
        NSTimeInterval now = [self timelinePositionForTime:self.observedPlayer.currentTime];
        if (isfinite(now)) {
            [self updateOverlayAtTime:now];  // schon ausgewertete Sätze gleich wieder zeigen
        }
    } else {
        // Erkennung und Anzeige sofort aus. Die schon erkannten Sätze bleiben im Speicher (wieder „An“ zeigt sie
        // gleich), werden aber nicht mehr eingeblendet – vorher lief die Anzeige mit den vorausgewerteten weiter.
        [self stopRecognitionClearing:NO];
        [self.overlay showStatus:BLS(@"Automatische Untertitel aus") duration:2.5];
    }
    [self installMenu];
}

- (void)setLanguageFromMenu:(NSString *)language {
    if ([language isEqualToString:self.preferences.autoSubtitlesLanguage]) {
        return;
    }
    NSLog(@"%@ Menü: Sprache %@", kSubtitleControllerLogPrefix, language);
    self.preferences.autoSubtitlesLanguage = language;
    if ([language isEqualToString:@"auto"]) {
        self.sessionLanguage = nil;  // bewusst „Automatisch“: neu erkennen
    }
    if (self.running) {
        [self stopRecognitionClearing:YES];
        [self startRecognition];
    }
    [self installMenu];
}

#pragma mark Start/Stopp

- (void)startRecognition {
    if (self.running || self.detached) {
        return;
    }
    if (![BrowserSubtitleEngine isCompiledWithWhisper]) {
        [self.overlay showStatus:BLS(@"Automatische Untertitel nicht verfügbar") duration:5.0];
        NSLog(@"%@ whisper.xcframework fehlt (tools/build_whisper.sh)", kSubtitleControllerLogPrefix);
        return;
    }
    NSString *language = self.preferences.autoSubtitlesLanguage;
    // Apples Spracherkennung (SubtitlesRecognizer=apple): whisper erkennt dann nur die gesprochene Sprache („auto“)
    // und ist Rückfall; Apple erkennt, übersetzt wird wie bisher über translationTarget.
    NSString *whisperLanguage = [BrowserAppleSpeechTranscriber whisperLanguageForSubtitleLanguage:language];
    NSString *modelPath = [BrowserSubtitleEngine modelPathForLanguage:whisperLanguage];
    if (modelPath == nil) {
        [self.overlay showStatus:BLS(@"Automatische Untertitel nicht verfügbar") duration:5.0];
        NSLog(@"%@ kein Modell im Paket (tools/fetch_whisper_model.sh)", kSubtitleControllerLogPrefix);
        return;
    }
    self.running = YES;
    [self.triedSources removeAllObjects];
    BrowserSubtitleEngine *engine = [[BrowserSubtitleEngine alloc] initWithModelPath:modelPath language:whisperLanguage];
    self.engine = engine;
    __weak typeof(self) weakSelf = self;
    BrowserAppleSpeechTranscriber *apple = [BrowserAppleSpeechTranscriber transcriberForSubtitleLanguage:language];
    __weak BrowserSubtitleEngine *weakEngine = engine;
    apple.spokenLanguageProvider = ^NSString *{
        return weakEngine.lockedLanguage;
    };
    self.appleSpeech = apple;
    if ([engine.language isEqualToString:@"auto"]) {
        if (self.sessionLanguage.length > 0) {
            [engine lockLanguage:self.sessionLanguage];  // einmal je Video erkennen, nicht nach jedem Neustart
        }
        engine.languageLockHandler = ^(NSString *detected, __unused NSUInteger speechWindows) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (strongSelf == nil || strongSelf.engine != engine) {
                    return;
                }
                strongSelf.sessionLanguage = detected;
                NSLog(@"%@ Sprache für dieses Video: %@", kSubtitleControllerLogPrefix, detected);
                [strongSelf.overlay showStatus:[NSString stringWithFormat:BLS(@"Sprache erkannt: %@"),
                                                [BrowserSubtitleEngine displayNameForLanguage:detected]] duration:3.0];
                [strongSelf installMenu];
            });
        };
    }
    [self installMenu];  // „wird erkannt …“ im Menü
    [self.overlay showStatus:BLS(@"Untertitel werden vorbereitet …") duration:10.0];
    // Modell zuerst in die whisper-Queue (der erste Abschnitt wartet dort darauf), Quelle sofort: Netz und Laden parallel.
    dispatch_async(self.engineQueue, ^{
        NSError *error = nil;
        BOOL loaded = [engine loadModel:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.engine != engine) {
                return;
            }
            if (!loaded) {
                [strongSelf.overlay showStatus:[NSString stringWithFormat:BLS(@"Automatische Untertitel: %@"), error.localizedDescription ?: BLS(@"Fehler")] duration:5.0];
                [strongSelf stopRecognitionClearing:NO];
                return;
            }
            NSString *languageText = [engine.language isEqualToString:@"auto"]
                ? (engine.lockedLanguage != nil ? [BrowserSubtitleEngine displayNameForLanguage:engine.lockedLanguage] : BLS(@"Sprache wird erkannt …"))
                : [BrowserSubtitleEngine displayNameForLanguage:engine.language];
            [strongSelf.overlay showStatus:[NSString stringWithFormat:BLS(@"Automatische Untertitel an (%@)"), languageText] duration:3.0];
            NSLog(@"%@ Erkennung mit %@, Sprache %@ (eingestellt %@)", kSubtitleControllerLogPrefix, engine.modelName,
                  engine.lockedLanguage ?: engine.language, language);
        });
    });
    [self startNextSource];
}

- (BOOL)playbackURLLooksLikeHLS {
    NSString *string = self.playbackURL.absoluteString.lowercaseString;
    return self.streamingPlaylist || [string containsString:@".m3u8"] || [string containsString:@"format=m3u8"] || [string containsString:@"/hls/"];
}

/// Reihenfolge: HLS → eigene Segmente; Datei über HTTP(S) → MP4-Vorauslesen, sonst bzw. bei Fehler Audio-Tap;
/// findet der Tap keine Audiospur, noch einmal die HLS-Quelle (HLS ohne .m3u8 in der Adresse).
- (void)startNextSource {
    NSString *kind = nil;
    // Test/Messung: nur Mithören (Audio-Tap), z. B. pref:SubtitlesForceTap=YES
    BOOL forceTap = [NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesForceTap"];
    if (forceTap && ![self.triedSources containsObject:@"tap"]) {
        kind = @"tap";
    } else if ([self playbackURLLooksLikeHLS] && ![self.triedSources containsObject:@"hls"]) {
        kind = @"hls";
    } else if (![self playbackURLLooksLikeHLS] && [BrowserSubtitleProgressiveAudioSource canHandleURL:self.playbackURL] &&
               ![self.triedSources containsObject:@"mp4"]) {
        kind = @"mp4";
    } else if (![self.triedSources containsObject:@"tap"]) {
        kind = @"tap";
    } else if (![self.triedSources containsObject:@"hls"]) {
        kind = @"hls";
    }
    AVPlayerItem *item = self.playerViewController.player.currentItem;
    id<BrowserSubtitleAudioSource> source = nil;
    if ([kind isEqualToString:@"hls"]) {
        BrowserSubtitleHLSAudioSource *hlsSource = [[BrowserSubtitleHLSAudioSource alloc] initWithPlaylistURL:self.playbackURL
                                                                                                requestHeaders:self.requestHeaders
                                                                                                       cookies:self.cookies];
        NSString *language = self.preferences.autoSubtitlesLanguage;
        hlsSource.preferredLanguage = [language isEqualToString:@"auto"] ? nil : language;
        if ([self.playerViewController isKindOfClass:BrowserNativeVideoPlayerViewController.class]) {
            hlsSource.generatedResources = ((BrowserNativeVideoPlayerViewController *)self.playerViewController).generatedPlaylists;
        }
        source = hlsSource;
    } else if ([kind isEqualToString:@"mp4"]) {
        source = [[BrowserSubtitleProgressiveAudioSource alloc] initWithURL:self.playbackURL requestHeaders:self.requestHeaders cookies:self.cookies];
    } else if ([kind isEqualToString:@"tap"] && item != nil) {
        source = [[BrowserSubtitleAudioTapSource alloc] initWithPlayerItem:item];
    }
    if (source == nil) {
        [self releaseStartHold];
        [self stopRecognitionClearing:NO];
        return;
    }
    [self.triedSources addObject:kind];
    self.source = source;
    [self.pipeline attachSource:source];
    if (source.deliversAhead) {
        [self holdStartIfPossible];
    } else {
        [self releaseStartHold];  // der Tap braucht die Wiedergabe, um Ton zu bekommen
    }
    NSLog(@"%@ Tonquelle %@ für %@", kSubtitleControllerLogPrefix, source.kindName, self.playbackURL.absoluteString);
    [source start];
    [self pushPlaybackTimeToSource];
}

/// Start der Wiedergabe kurz aufhalten, bis die ersten Sekunden erkannt sind (höchstens 1 s, nur vor dem ersten play).
- (void)holdStartIfPossible {
    AVPlayerViewController *playerViewController = self.playerViewController;
    if (self.holdingStart || ![playerViewController isKindOfClass:BrowserNativeVideoPlayerViewController.class] ||
        playerViewController.player.rate > 0.0f) {
        return;
    }
    self.holdingStart = YES;
    NSString *language = self.appleSpeech.subtitleLanguage ?: self.engine.language;  // bei Apple läuft whisper auf „auto“
    BOOL mayTranslate = language.length > 0 && ![language isEqualToString:@"auto"] &&
                        ![NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesNoAppleTranslation"] &&
                        !BrowserSubtitleTranslator.sharedTranslator.suspended;
    [(BrowserNativeVideoPlayerViewController *)playerViewController holdPlaybackStart:kSubtitleStartHoldReason
                                                                              timeout:kSubtitleStartHoldTimeout + (mayTranslate ? kSubtitleStartHoldTranslationExtra : 0.0)];
}

- (void)releaseStartHold {
    if (!self.holdingStart) {
        return;
    }
    self.holdingStart = NO;
    AVPlayerViewController *playerViewController = self.playerViewController;
    if ([playerViewController isKindOfClass:BrowserNativeVideoPlayerViewController.class]) {
        [(BrowserNativeVideoPlayerViewController *)playerViewController releasePlaybackStartHold:kSubtitleStartHoldReason];
    }
}

- (void)firstWindowReadyFrom:(NSTimeInterval)start to:(NSTimeInterval)end {
    NSLog(@"%@ erster Abschnitt %.2f–%.2f s fertig", kSubtitleControllerLogPrefix, start, end);
    [self releaseStartHold];
}

- (void)source:(id<BrowserSubtitleAudioSource>)source didFailWithReason:(NSString *)reason {
    if (source != self.source) {
        return;
    }
    NSLog(@"%@ Tonquelle %@ fehlgeschlagen: %@", kSubtitleControllerLogPrefix, source.kindName, reason);
    self.source = nil;
    source.delegate = nil;
    [source stop];
    [self.pipeline detachSource];
    BOOL fallback = ([source.kindName isEqualToString:@"mp4"] && ![self.triedSources containsObject:@"tap"]) ||
                    ([source.kindName isEqualToString:@"tap"] && ![self.triedSources containsObject:@"hls"]);
    if (fallback) {
        [self startNextSource];
        return;
    }
    [self releaseStartHold];
    // Gründe der Tonquellen sind meist schon übersetzt; den HLS-Grund mit „FairPlay“ übersetzt erst die Anzeige,
    // weil BrowserWebSubtitleController ihn am Wortlaut erkennt.
    [self.overlay showStatus:[NSString stringWithFormat:BLS(@"Automatische Untertitel: %@"), BLS(reason)] duration:6.0];
    [self stopRecognitionClearing:NO];
}

- (void)stopRecognitionClearing:(BOOL)clearCues {
    [self releaseStartHold];
    if (!self.running && self.source == nil && self.engine == nil) {
        if (clearCues) {
            [self.cues removeAllObjects];
            [self.pipeline clearCoverage];
        }
        return;
    }
    self.running = NO;
    id<BrowserSubtitleAudioSource> source = self.source;
    self.source = nil;
    source.delegate = nil;
    [source stop];
    [self.pipeline detachSource];
    BrowserSubtitleEngine *engine = self.engine;
    self.engine = nil;
    [engine cancel];
    if (clearCues) {
        [self.pipeline clearCoverage];
        [self.cues removeAllObjects];
    }
    // Modell auf der whisper-Queue freigeben, nachdem eine laufende Auswertung abgebrochen ist.
    dispatch_async(self.engineQueue, ^{
        (void)engine;
    });
    [self.overlay setSubtitleText:nil];
    NSLog(@"%@ Erkennung gestoppt (RTF Schnitt %.2f) – %@", kSubtitleControllerLogPrefix, engine.averageRealTimeFactor, [self offsetSummary]);
    [self installMenu];  // „wird erkannt …“ entfernen
}

#pragma mark Zeitachse

/// Abspielposition auf der Zeitachse der Quelle: Medienzeit, bei Live-HLS mit PROGRAM-DATE-TIME das Datum.
- (NSTimeInterval)timelinePositionForTime:(CMTime)time {
    if (!CMTIME_IS_NUMERIC(time)) {
        return NAN;
    }
    id<BrowserSubtitleAudioSource> source = self.source;
    if ([source respondsToSelector:@selector(usesDateTimeline)] && source.usesDateTimeline) {
        NSDate *date = self.observedPlayer.currentItem.currentDate;
        return date != nil ? date.timeIntervalSince1970 : NAN;
    }
    return CMTimeGetSeconds(time);
}

- (void)pushPlaybackTimeToSource {
    id<BrowserSubtitleAudioSource> source = self.source;
    AVPlayer *player = self.playerViewController.player;
    if (source == nil || player == nil) {
        return;
    }
    CMTime now = player.currentTime;
    NSTimeInterval seconds = CMTIME_IS_NUMERIC(now) ? CMTimeGetSeconds(now) : 0.0;
    // Vor dem ersten Abspielen steht der Player noch bei 0, springt aber gleich zur Startposition der Seite.
    if (seconds < 0.5 && [self.playerViewController isKindOfClass:BrowserNativeVideoPlayerViewController.class]) {
        NSTimeInterval initial = ((BrowserNativeVideoPlayerViewController *)self.playerViewController).initialPlaybackTime;
        if (initial > 1.0) {
            seconds = initial;
        }
    }
    NSDate *date = player.currentItem.currentDate;
    if ([source respondsToSelector:@selector(updatePlaybackTime:date:rate:)]) {
        [source updatePlaybackTime:seconds date:date != nil ? date.timeIntervalSince1970 : NAN rate:player.rate];
    } else {
        [source updatePlaybackTime:seconds rate:player.rate];
    }
}

#pragma mark Anzeige (Hauptthread)

static NSString *BrowserSubtitleNormalizedText(NSString *text) {
    NSCharacterSet *drop = NSCharacterSet.alphanumericCharacterSet.invertedSet;
    return [[[text lowercaseString] componentsSeparatedByCharactersInSet:drop] componentsJoinedByString:@""];
}

- (void)addCues:(NSArray<BrowserSubtitleCue *> *)cues replacingTentativeFrom:(NSTimeInterval)replaceFrom {
    if (self.detached) {
        return;
    }
    NSTimeInterval now = [self timelinePositionForTime:self.observedPlayer.currentTime];
    if (!isnan(replaceFrom)) {
        // Mithören: vorläufige Untertitel des letzten Durchlaufs durch die neuen ersetzen.
        NSIndexSet *old = [self.cues indexesOfObjectsPassingTest:^BOOL(BrowserSubtitleCue *cue, NSUInteger index, BOOL *stop) {
            return cue.tentative && cue.start >= replaceFrom;
        }];
        for (BrowserSubtitleCue *replaced in [self.cues objectsAtIndexes:old]) {
            for (BrowserSubtitleCue *cue in cues) {
                if (fabs(cue.start - replaced.start) < 0.5 && !isnan(replaced.shownAt)) {
                    cue.shownAt = replaced.shownAt;   // gleicher Satz, schon sichtbar: kein neuer Messpunkt
                }
            }
        }
        [self.cues removeObjectsAtIndexes:old];
    }
    for (BrowserSubtitleCue *cue in cues) {
        if ([self isRepeatedCue:cue]) {
            continue;  // whisper wiederholt sich gern (gleicher Satz doppelt, „directional“ in Musik)
        }
        // Kam der Untertitel nach seinem Sprechbeginn an (Mithören), steht er ab jetzt mindestens eine Lesezeit lang.
        NSTimeInterval reading = MIN(4.0, MAX(1.2, cue.text.length * 0.06));
        // Längst vorbei (z. B. Abschnitt nach Spracherkennung neu ausgewertet, langsame Auswertung): nicht nachreichen.
        BOOL stale = isfinite(now) && now > cue.end + 1.0;
        cue.visibleUntil = isfinite(now) && now > cue.start + 0.3 && !stale ? MAX(cue.end + 0.8, now + reading) : cue.end + 0.8;
        NSUInteger index = [self.cues indexOfObject:cue inSortedRange:NSMakeRange(0, self.cues.count)
                                            options:NSBinarySearchingInsertionIndex
                                    usingComparator:^NSComparisonResult(BrowserSubtitleCue *a, BrowserSubtitleCue *b) {
            return [@(a.start) compare:@(b.start)];
        }];
        [self.cues insertObject:cue atIndex:index];
    }
    if (isfinite(now)) {
        [self updateOverlayAtTime:now];
    }
}

- (BOOL)isRepeatedCue:(BrowserSubtitleCue *)cue {
    NSString *normalized = BrowserSubtitleNormalizedText(cue.text);
    if (normalized.length == 0) {
        return YES;
    }
    for (BrowserSubtitleCue *other in self.cues) {
        if (fabs(other.start - cue.start) < 15.0 && [BrowserSubtitleNormalizedText(other.text) isEqualToString:normalized]) {
            return YES;
        }
    }
    return NO;
}

/// Sichtbar ist ein Untertitel ab seinem Sprechbeginn bis kurz nach seinem Ende; beginnt der nächste, löst dieser ab
/// (außer der alte kam verspätet an und braucht noch Lesezeit). Höchstens zwei gleichzeitig.
/// Mindestanzeigedauer einer Zeile: Lesezeit (≈ 20 Zeichen/s plus 1 s), 2–4 s.
static NSTimeInterval BrowserSubtitleMinimumDisplay(BrowserSubtitleCue *cue) {
    return MIN(4.0, MAX(2.0, 1.0 + cue.text.length * 0.05));
}

/// Rollend wie Live-Untertitel: der neue Untertitel erscheint sofort (unten), der vorige bleibt darüber stehen, bis
/// seine Mindestanzeigedauer um ist. Höchstens zwei, und nur, wenn zusammen ≤ 3 Zeilen (sonst nur der neue).
- (void)updateOverlayAtTime:(NSTimeInterval)time {
    if (!self.cuesVisible) {
        [self.overlay setSubtitleText:nil];
        return;
    }
    NSMutableArray<BrowserSubtitleCue *> *visible = [NSMutableArray array];
    BrowserSubtitleCue *following = nil;   // der nächstspätere schon begonnene Untertitel
    for (NSInteger i = (NSInteger)self.cues.count - 1; i >= 0 && visible.count < 2; i--) {
        BrowserSubtitleCue *cue = self.cues[(NSUInteger)i];
        if (cue.start > time + 0.05) {
            continue;
        }
        if (cue.start < time - 30.0) {
            break;
        }
        if (isnan(cue.shownAt) && (time > cue.visibleUntil || time > cue.end + 1.0)) {
            // Nie gezeigt und schon vorbei (Spulen, verspätet, oder beim Mithören verspätet angekommen und von
            // neueren Sätzen verdrängt): nicht mehr einblenden – sonst tauchte er Sekunden später außer der Reihe auf.
            following = cue;
            continue;
        }
        BOOL late = cue.visibleUntil > cue.end + 0.85;   // kam nach dem Sprechbeginn an
        NSTimeInterval shownSince = isnan(cue.shownAt) ? time : MAX(cue.start, cue.shownAt);
        NSTimeInterval until = MAX(cue.visibleUntil, shownSince + BrowserSubtitleMinimumDisplay(cue));
        if (following != nil && !late) {
            // vom Nachfolger verdrängt, aber nicht vor der Mindestanzeigedauer
            until = MIN(until, MAX(following.start, shownSince + BrowserSubtitleMinimumDisplay(cue)));
        }
        if (until > time) {
            if (visible.count == 1 && cue.text.length + visible.firstObject.text.length > 120) {
                break;   // zu viel Text für drei Zeilen: nur der neue
            }
            [visible insertObject:cue atIndex:0];
        }
        following = cue;
    }
    for (BrowserSubtitleCue *cue in visible) {
        if (isnan(cue.shownAt)) {
            cue.shownAt = time;
            [self measureOffsetOfCue:cue atTime:time];
        }
    }
    [self.overlay setSubtitleText:visible.count > 0 ? [[visible valueForKey:@"text"] componentsJoinedByString:@"\n"] : nil];
}

/// Versatz = Medienzeit beim Einblenden − Sprechbeginn laut whisper (positiv: zu spät).
- (void)measureOffsetOfCue:(BrowserSubtitleCue *)cue atTime:(NSTimeInterval)time {
    if (fabs(cue.start - self.lastMeasuredStart) <= 0.3) {
        return;
    }
    self.lastMeasuredStart = cue.start;
    double offset = time - cue.start;
    if (fabs(offset) > 30.0) {
        return;  // Spulen
    }
    [self.offsets addObject:@(offset)];
    NSLog(@"%@ Anzeige Δ=%+.2f s (Sprechbeginn %.2f, eingeblendet %.2f, Ende %.2f, %@%@) „%@“", kSubtitleControllerLogPrefix, offset,
          cue.start, time, cue.end, self.source.kindName ?: @"-", cue.tentative ? @", vorläufig" : @"", cue.text);
}

- (NSString *)offsetSummary {
    BrowserAppleSpeechTranscriber *apple = self.appleSpeech;
    NSString *language = apple.subtitleLanguage ?: self.engine.language;
    NSString *summary = BrowserSubtitleOffsetSummary(self.offsets);
    if (language.length > 0 && ![language isEqualToString:@"auto"]) {
        summary = [NSString stringWithFormat:@"%@, %@", summary, [BrowserSubtitleTranslator.sharedTranslator summary]];
    }
    return apple != nil ? [NSString stringWithFormat:@"%@, %@", summary, [apple summary]] : summary;
}

- (void)playerTimeDidChange:(CMTime)time {
    if (self.detached || !CMTIME_IS_NUMERIC(time)) {
        return;
    }
    NSTimeInterval position = [self timelinePositionForTime:time];
    if (isfinite(position)) {
        [self updateOverlayAtTime:position];
    }

    NSTimeInterval wall = CACurrentMediaTime();
    float rate = self.observedPlayer.rate;
    if (self.source != nil && (wall - self.lastSourceUpdate > 0.5 || rate != self.lastRate)) {
        self.lastSourceUpdate = wall;
        [self pushPlaybackTimeToSource];
    }
    if (self.source != nil && !self.source.deliversAhead && self.lastRate > 0.0f && rate == 0.0f) {
        [self.pipeline flushPartial];  // Pause: angefangenen Satz trotzdem auswerten
    }
    self.lastRate = rate;
    if (wall - self.lastMenuCheck > 2.0) {
        self.lastMenuCheck = wall;
        if (!self.menuInstalled) {
            [self installMenu];  // falls der Player seine Einträge neu gesetzt hat
        }
        [self checkExistingSubtitles];
    }
    if (self.running && wall - self.lastSummary > 30.0) {
        self.lastSummary = wall;
        NSLog(@"%@ Stand t=%.1f s: %lu Untertitel, %lu Abschnitte, %lu verworfen, %lu wartend, RTF Schnitt %.2f, Speicher %.0f MB, %@",
              kSubtitleControllerLogPrefix, CMTimeGetSeconds(time), (unsigned long)self.cues.count,
              (unsigned long)self.pipeline.processedWindows, (unsigned long)self.pipeline.droppedWindows,
              (unsigned long)self.pipeline.pendingWindowCount, self.engine.averageRealTimeFactor,
              [BrowserSubtitleEngine currentMemoryFootprintMB], [self offsetSummary]);
    }
}

@end
