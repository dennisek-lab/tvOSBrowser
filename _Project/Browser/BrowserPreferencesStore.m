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
static NSString * const kCookieBannerExceptionHostsDefaultsKey = @"CookieBannerExceptionHosts";
static NSString * const kAutoSubtitlesEnabledDefaultsKey = @"AutoSubtitlesEnabled";
static NSString * const kAutoSubtitlesLanguageDefaultsKey = @"AutoSubtitlesLanguage";
static NSString * const kWebSubtitlesEnabledDefaultsKey = @"WebSubtitlesEnabled";

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

- (BOOL)autoSubtitlesEnabled {
    return [[self defaults] boolForKey:kAutoSubtitlesEnabledDefaultsKey];
}

- (void)setAutoSubtitlesEnabled:(BOOL)autoSubtitlesEnabled {
    [[self defaults] setBool:autoSubtitlesEnabled forKey:kAutoSubtitlesEnabledDefaultsKey];
    [[self defaults] synchronize];
}

- (NSString *)autoSubtitlesLanguage {
    NSString *value = [[self defaults] stringForKey:kAutoSubtitlesLanguageDefaultsKey];
    return value.length > 0 ? value : @"en";
}

- (void)setAutoSubtitlesLanguage:(NSString *)autoSubtitlesLanguage {
    [[self defaults] setObject:autoSubtitlesLanguage.length > 0 ? autoSubtitlesLanguage : @"en" forKey:kAutoSubtitlesLanguageDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)webSubtitlesEnabled {
    return [[self defaults] boolForKey:kWebSubtitlesEnabledDefaultsKey];
}

- (void)setWebSubtitlesEnabled:(BOOL)webSubtitlesEnabled {
    [[self defaults] setBool:webSubtitlesEnabled forKey:kWebSubtitlesEnabledDefaultsKey];
    [[self defaults] synchronize];
}

@end
