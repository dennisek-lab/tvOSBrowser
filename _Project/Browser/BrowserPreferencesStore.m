#import "BrowserPreferencesStore.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static NSString * const kMobileModeDefaultsKey = @"MobileMode";
static NSString * const kShowTopNavigationBarDefaultsKey = @"ShowTopNavigationBar";
static NSString * const kTextFontSizeDefaultsKey = @"TextFontSize";
static NSString * const kEnableFullscreenVideoPlaybackDefaultsKey = @"EnableFullscreenVideoPlayback";
static NSString * const kScalePagesToFitDefaultsKey = @"ScalePagesToFit";
static NSString * const kAutoOpenNativePlayerDefaultsKey = @"AutoOpenVideosInNativePlayer";
static NSString * const kPageZoomDefaultsKey = @"PageZoom";
static double const kDefaultPageZoom = 1.5;
static NSString * const kDontShowHintsOnLaunchDefaultsKey = @"DontShowHintsOnLaunch";
static NSString * const kCursorStyleDefaultsKey = @"CursorStyle";
static NSString * const kHomepageDefaultsKey = @"homepage";
static NSString * const kAdBlockEnabledDefaultsKey = @"AdBlockEnabled";
static NSString * const kAdBlockExceptionHostsDefaultsKey = @"AdBlockExceptionHosts";
static NSString * const kAdBlockAutoPauseDefaultsKey = @"AdBlockAutoPauseOnWall";
static NSString * const kAdBlockAutoExceptionHostsDefaultsKey = @"AdBlockAutoExceptionHosts";
static NSString * const kCookieBannerBlockEnabledDefaultsKey = @"CookieBannerBlockEnabled";
static NSString * const kCookieBannerAcceptPayWallsDefaultsKey = @"CookieBannerAcceptPayWalls";
static NSString * const kRainbowGlowEnabledDefaultsKey = @"RainbowGlowEnabled";
static NSString * const kLiquidGlassAnimationsEnabledDefaultsKey = @"LiquidGlassAnimationsEnabled";
static NSString * const kGlowAnimationEnabledDefaultsKey = @"GlowAnimationEnabled";
static NSString * const kCookieBannerExceptionHostsDefaultsKey = @"CookieBannerExceptionHosts";
static NSString * const kPointerSpeedDefaultsKey = @"PointerSpeed";
static NSString * const kPointerGlideEnabledDefaultsKey = @"PointerGlideEnabled";
static NSString * const kAutoSubtitlesEnabledDefaultsKey = @"AutoSubtitlesEnabled";
static NSString * const kAutoSubtitlesLanguageDefaultsKey = @"AutoSubtitlesLanguage";
/// Einmalige Umstellung des alten Standards „en“ auf „auto“ erledigt (siehe autoSubtitlesLanguage).
static NSString * const kAutoSubtitlesLanguageMigratedDefaultsKey = @"AutoSubtitlesLanguageMigratedToAuto";
static NSString * const kWebSubtitlesEnabledDefaultsKey = @"WebSubtitlesEnabled";
static NSString * const kClassicDesignEnabledDefaultsKey = @"ClassicDesign";
static NSString * const kSetupCompletedDefaultsKey = @"SetupCompleted";
static NSString * const kCloseUnusedTabsDefaultsKey = @"CloseUnusedTabs";
static NSTimeInterval const kUnusedTabExpiryInterval = 30.0 * 60.0;

static NSUInteger const kDefaultTextFontSize = 100;
static NSUInteger const kMinimumTextFontSize = 50;
static NSUInteger const kMaximumTextFontSize = 200;

@implementation BrowserPreferencesStore

+ (NSString *)desktopUserAgent {
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
}

+ (NSString *)mobileUserAgent {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
}

- (NSUserDefaults *)defaults {
    return [NSUserDefaults standardUserDefaults];
}

- (void)ensureUserAgentConsistency {
    if (self.userAgent.length > 0) {
        return;
    }
    self.userAgent = self.mobileModeEnabled ? BrowserPreferencesStore.mobileUserAgent : BrowserPreferencesStore.desktopUserAgent;
}

- (NSString *)userAgent {
    NSString *userAgent = [[self defaults] stringForKey:kUserAgentDefaultsKey];
    if (userAgent.length > 0) {
        return userAgent;
    }
    return self.mobileModeEnabled ? BrowserPreferencesStore.mobileUserAgent : BrowserPreferencesStore.desktopUserAgent;
}

- (void)setUserAgent:(NSString *)userAgent {
    [[self defaults] setObject:userAgent ?: @"" forKey:kUserAgentDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)mobileModeEnabled {
    return [[self defaults] boolForKey:kMobileModeDefaultsKey];
}

- (void)setMobileModeEnabled:(BOOL)mobileModeEnabled {
    [[self defaults] setBool:mobileModeEnabled forKey:kMobileModeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)topNavigationBarVisible {
    NSNumber *showTopNavBar = [[self defaults] objectForKey:kShowTopNavigationBarDefaultsKey];
    return showTopNavBar ? showTopNavBar.boolValue : YES;
}

- (void)setTopNavigationBarVisible:(BOOL)topNavigationBarVisible {
    [[self defaults] setObject:@(topNavigationBarVisible) forKey:kShowTopNavigationBarDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)textFontSize {
    NSNumber *textFontSizeValue = [[self defaults] objectForKey:kTextFontSizeDefaultsKey];
    if (textFontSizeValue == nil) {
        return kDefaultTextFontSize;
    }
    NSUInteger textFontSize = textFontSizeValue.unsignedIntegerValue;
    return MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
}

- (void)setTextFontSize:(NSUInteger)textFontSize {
    textFontSize = MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
    [[self defaults] setObject:@(textFontSize) forKey:kTextFontSizeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)fullscreenVideoPlaybackEnabled {
    return [[self defaults] boolForKey:kEnableFullscreenVideoPlaybackDefaultsKey];
}

- (void)setFullscreenVideoPlaybackEnabled:(BOOL)fullscreenVideoPlaybackEnabled {
    [[self defaults] setBool:fullscreenVideoPlaybackEnabled forKey:kEnableFullscreenVideoPlaybackDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)scalePagesToFit {
    return [[self defaults] boolForKey:kScalePagesToFitDefaultsKey];
}

- (void)setScalePagesToFit:(BOOL)scalePagesToFit {
    [[self defaults] setBool:scalePagesToFit forKey:kScalePagesToFitDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)autoOpenVideosInNativePlayer {
    NSNumber *value = [[self defaults] objectForKey:kAutoOpenNativePlayerDefaultsKey];
    return value != nil ? value.boolValue : YES;
}

- (void)setAutoOpenVideosInNativePlayer:(BOOL)autoOpenVideosInNativePlayer {
    [[self defaults] setBool:autoOpenVideosInNativePlayer forKey:kAutoOpenNativePlayerDefaultsKey];
    [[self defaults] synchronize];
}

- (double)pageZoom {
    id value = [[self defaults] objectForKey:kPageZoomDefaultsKey];
    double zoom = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : kDefaultPageZoom;
    return MIN(3.0, MAX(0.5, zoom));
}

- (void)setPageZoom:(double)pageZoom {
    [[self defaults] setDouble:MIN(3.0, MAX(0.5, pageZoom)) forKey:kPageZoomDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)cursorStyle {
    NSInteger value = [[self defaults] integerForKey:kCursorStyleDefaultsKey];
    return value >= 0 && value <= 2 ? (NSUInteger)value : 0;
}

- (void)setCursorStyle:(NSUInteger)cursorStyle {
    [[self defaults] setInteger:(NSInteger)MIN(cursorStyle, 2) forKey:kCursorStyleDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)dontShowHintsOnLaunch {
    return [[self defaults] boolForKey:kDontShowHintsOnLaunchDefaultsKey];
}

- (void)setDontShowHintsOnLaunch:(BOOL)dontShowHintsOnLaunch {
    [[self defaults] setBool:dontShowHintsOnLaunch forKey:kDontShowHintsOnLaunchDefaultsKey];
    [[self defaults] synchronize];
}

- (NSString *)homePageURLString {
    NSString *value = [[self defaults] stringForKey:kHomepageDefaultsKey];
    return value ?: @"";
}

- (void)setHomePageURLString:(NSString *)homePageURLString {
    [[self defaults] setObject:homePageURLString ?: @"" forKey:kHomepageDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)adBlockEnabled {
    NSNumber *value = [[self defaults] objectForKey:kAdBlockEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setAdBlockEnabled:(BOOL)adBlockEnabled {
    [[self defaults] setBool:adBlockEnabled forKey:kAdBlockEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (NSArray<NSString *> *)adBlockExceptionHosts {
    NSArray *value = [[self defaults] arrayForKey:kAdBlockExceptionHostsDefaultsKey];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

- (void)setAdBlockExceptionHosts:(NSArray<NSString *> *)adBlockExceptionHosts {
    [[self defaults] setObject:adBlockExceptionHosts ?: @[] forKey:kAdBlockExceptionHostsDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)adBlockAutoPauseOnWall {
    NSNumber *value = [[self defaults] objectForKey:kAdBlockAutoPauseDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setAdBlockAutoPauseOnWall:(BOOL)adBlockAutoPauseOnWall {
    [[self defaults] setBool:adBlockAutoPauseOnWall forKey:kAdBlockAutoPauseDefaultsKey];
    [[self defaults] synchronize];
}

- (NSArray<NSString *> *)adBlockAutoExceptionHosts {
    NSArray *value = [[self defaults] arrayForKey:kAdBlockAutoExceptionHostsDefaultsKey];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

- (void)setAdBlockAutoExceptionHosts:(NSArray<NSString *> *)adBlockAutoExceptionHosts {
    [[self defaults] setObject:adBlockAutoExceptionHosts ?: @[] forKey:kAdBlockAutoExceptionHostsDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)cookieBannerBlockEnabled {
    NSNumber *value = [[self defaults] objectForKey:kCookieBannerBlockEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setCookieBannerBlockEnabled:(BOOL)cookieBannerBlockEnabled {
    [[self defaults] setBool:cookieBannerBlockEnabled forKey:kCookieBannerBlockEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)cookieBannerAcceptPayWalls {
    NSNumber *value = [[self defaults] objectForKey:kCookieBannerAcceptPayWallsDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setCookieBannerAcceptPayWalls:(BOOL)cookieBannerAcceptPayWalls {
    [[self defaults] setBool:cookieBannerAcceptPayWalls forKey:kCookieBannerAcceptPayWallsDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)rainbowGlowEnabled {
    NSNumber *value = [[self defaults] objectForKey:kRainbowGlowEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setRainbowGlowEnabled:(BOOL)rainbowGlowEnabled {
    [[self defaults] setBool:rainbowGlowEnabled forKey:kRainbowGlowEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)classicDesignEnabled {
    return [[self defaults] boolForKey:kClassicDesignEnabledDefaultsKey];
}

- (void)setClassicDesignEnabled:(BOOL)classicDesignEnabled {
    [[self defaults] setBool:classicDesignEnabled forKey:kClassicDesignEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)setupCompleted {
    return [[self defaults] boolForKey:kSetupCompletedDefaultsKey];
}

- (void)setSetupCompleted:(BOOL)setupCompleted {
    [[self defaults] setBool:setupCompleted forKey:kSetupCompletedDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)glowAnimationEnabled {
    NSNumber *value = [[self defaults] objectForKey:kGlowAnimationEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setGlowAnimationEnabled:(BOOL)glowAnimationEnabled {
    [[self defaults] setBool:glowAnimationEnabled forKey:kGlowAnimationEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)liquidGlassAnimationsEnabled {
    NSNumber *value = [[self defaults] objectForKey:kLiquidGlassAnimationsEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setLiquidGlassAnimationsEnabled:(BOOL)liquidGlassAnimationsEnabled {
    [[self defaults] setBool:liquidGlassAnimationsEnabled forKey:kLiquidGlassAnimationsEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (NSArray<NSString *> *)cookieBannerExceptionHosts {
    NSArray *value = [[self defaults] arrayForKey:kCookieBannerExceptionHostsDefaultsKey];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

- (void)setCookieBannerExceptionHosts:(NSArray<NSString *> *)cookieBannerExceptionHosts {
    [[self defaults] setObject:cookieBannerExceptionHosts ?: @[] forKey:kCookieBannerExceptionHostsDefaultsKey];
    [[self defaults] synchronize];
}

- (double)pointerSpeed {
    id value = [[self defaults] objectForKey:kPointerSpeedDefaultsKey];
    double speed = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 1.0;
    return MIN(3.0, MAX(0.3, speed));
}

- (void)setPointerSpeed:(double)pointerSpeed {
    [[self defaults] setDouble:MIN(3.0, MAX(0.3, pointerSpeed)) forKey:kPointerSpeedDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)pointerGlideEnabled {
    NSNumber *value = [[self defaults] objectForKey:kPointerGlideEnabledDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setPointerGlideEnabled:(BOOL)pointerGlideEnabled {
    [[self defaults] setBool:pointerGlideEnabled forKey:kPointerGlideEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)autoSubtitlesEnabled {
    return [[self defaults] boolForKey:kAutoSubtitlesEnabledDefaultsKey];
}

- (void)setAutoSubtitlesEnabled:(BOOL)autoSubtitlesEnabled {
    [[self defaults] setBool:autoSubtitlesEnabled forKey:kAutoSubtitlesEnabledDefaultsKey];
    [[self defaults] synchronize];
}

/// Standard ist „auto“ (Sprache je Video erkennen). Einmalige Umstellung: Ein gespeichertes „en“ aus der Zeit, als
/// „en“ der Standard war, wird beim ersten Lesen zu „auto“. Bewusst gewählt lässt sich „en“ von damals nicht sicher
/// erkennen (es kam auch über Selbsttests/`defaults write` und als Ausweg aus der früher je Abschnitt springenden
/// automatischen Erkennung in die Einstellungen); ein falsches „Englisch“ war der gemeldete Fehler, eine falsche
/// Umstellung kostet dagegen nur eine Auswahl im Player-Menü. Wer danach „Englisch“ wählt, behält es.
- (NSString *)autoSubtitlesLanguage {
    NSUserDefaults *defaults = [self defaults];
    NSString *value = [defaults stringForKey:kAutoSubtitlesLanguageDefaultsKey];
    if (![defaults boolForKey:kAutoSubtitlesLanguageMigratedDefaultsKey]) {
        [defaults setBool:YES forKey:kAutoSubtitlesLanguageMigratedDefaultsKey];
        if ([value isEqualToString:@"en"]) {
            // Ausdrücklich setzen statt löschen: Löschen ließe einen Wert aus einer anderen Ebene durchscheinen
            // (z. B. im Simulator per `simctl spawn … defaults write` gesetzt).
            [defaults setObject:@"auto" forKey:kAutoSubtitlesLanguageDefaultsKey];
            value = @"auto";
            NSLog(@"[Subtitles] Sprache: gespeichertes „en“ (alter Standard) auf „auto“ umgestellt");
        }
    }
    return value.length > 0 ? value : @"auto";
}

- (void)setAutoSubtitlesLanguage:(NSString *)autoSubtitlesLanguage {
    NSUserDefaults *defaults = [self defaults];
    [defaults setBool:YES forKey:kAutoSubtitlesLanguageMigratedDefaultsKey];
    if (autoSubtitlesLanguage.length > 0) {
        [defaults setObject:autoSubtitlesLanguage forKey:kAutoSubtitlesLanguageDefaultsKey];
    } else {
        [defaults removeObjectForKey:kAutoSubtitlesLanguageDefaultsKey];
    }
    [defaults synchronize];
}

- (BOOL)webSubtitlesEnabled {
    return [[self defaults] boolForKey:kWebSubtitlesEnabledDefaultsKey];
}

- (void)setWebSubtitlesEnabled:(BOOL)webSubtitlesEnabled {
    [[self defaults] setBool:webSubtitlesEnabled forKey:kWebSubtitlesEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)closeUnusedTabsEnabled {
    NSNumber *value = [[self defaults] objectForKey:kCloseUnusedTabsDefaultsKey];
    return value ? value.boolValue : YES;
}

- (void)setCloseUnusedTabsEnabled:(BOOL)closeUnusedTabsEnabled {
    [[self defaults] setBool:closeUnusedTabsEnabled forKey:kCloseUnusedTabsDefaultsKey];
    [[self defaults] synchronize];
}

- (NSTimeInterval)unusedTabExpiryInterval {
    if (!self.closeUnusedTabsEnabled) {
        return 0.0;
    }
#if DEBUG
    double debugSeconds = [NSProcessInfo.processInfo.environment[@"TAB_EXPIRY_SECONDS"] doubleValue];
    if (debugSeconds > 0.0) {
        return debugSeconds;
    }
#endif
    return kUnusedTabExpiryInterval;
}

@end
