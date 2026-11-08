#import "BrowserFilterListUpdater.h"
#import "BrowserContentBlocker.h"
#import "BrowserScriptletInjector.h"

#import <CommonCrypto/CommonDigest.h>

/// Feste Quelle (GitHub-Release, siehe .github/workflows/filterlisten.yml). Weiterleitung auf
/// release-assets.githubusercontent.com ist erlaubt, aber nur über HTTPS.
static NSString * const kFilterListManifestURL = @"https://github.com/dennisek-lab/tvos-browser/releases/download/filterlisten-latest/manifest.json";
/// Erhöhen, wenn die App ein neues Listenformat versteht; das Manifest nennt in minAppFormat die nötige Version.
static const NSInteger kFilterListAppFormat = 1;

static NSString * const kLastCheckKey = @"FilterListLastCheck";
static NSString * const kLastAttemptKey = @"FilterListLastAttempt";
static NSString * const kContentBlockerDirKey = @"FilterListContentBlockerDirectory";
static NSString * const kScriptletsDirKey = @"FilterListScriptletsDirectory";

static NSString * const kContentBlockerFolder = @"contentblocker";
static NSString * const kScriptletsFolder = @"scriptlets";
static NSString * const kLocalManifestName = @"manifest.json";

/// Einmal am Tag (mit etwas Spiel, damit eine tägliche Nutzung zur gleichen Uhrzeit nicht knapp daneben liegt).
static const NSTimeInterval kCheckInterval = 23.0 * 3600.0;
/// Nach einem Fehlschlag (Server nicht erreichbar) frühestens nach einer Stunde erneut.
static const NSTimeInterval kRetryInterval = 3600.0;
/// Abstand zum ersten Seitenaufbau, damit die Prüfung die Seite nicht ausbremst.
static const NSTimeInterval kCheckDelay = 10.0;
static const NSUInteger kMaxManifestBytes = 512 * 1024;
static const unsigned long long kMaxFileBytes = 64ull * 1024 * 1024;

#pragma mark Hilfsfunktionen

static NSString *BrowserFilterListSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

/// Nur einfache Dateinamen (keine Pfade, kein „..“): sie werden relativ zur Manifest-URL geladen und lokal abgelegt.
static BOOL BrowserFilterListSafeName(id name) {
    if (![name isKindOfClass:NSString.class] || [name length] == 0 || [name length] > 120 || [name hasPrefix:@"."]) {
        return NO;
    }
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"] invertedSet];
    return [name rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static BOOL BrowserFilterListHex(id value, NSUInteger length) {
    if (![value isKindOfClass:NSString.class] || [value length] != length) {
        return NO;
    }
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [value rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static NSDictionary *BrowserFilterListReadJSON(NSURL *url) {
    NSData *data = url != nil ? [NSData dataWithContentsOfURL:url] : nil;
    id json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

static NSTimeInterval BrowserFilterListGeneratedAt(NSDictionary *manifest) {
    id value = manifest[@"generatedAt"];
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
}

/// Prüft die Regelsatz-Einträge eines Manifests (mitgeliefert: ohne sha256; heruntergeladen: mit).
static BOOL BrowserFilterListValidLists(id lists, BOOL requireDigest) {
    if (![lists isKindOfClass:NSArray.class] || [lists count] == 0 || [lists count] > 16) {
        return NO;
    }
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (NSDictionary *entry in lists) {
        if (![entry isKindOfClass:NSDictionary.class] || !BrowserFilterListSafeName(entry[@"name"]) ||
            !BrowserFilterListSafeName(entry[@"file"]) || !BrowserFilterListHex(entry[@"hash"], 12) ||
            [names containsObject:entry[@"name"]]) {
            return NO;
        }
        if (requireDigest && (!BrowserFilterListHex(entry[@"sha256"], 64) || ![entry[@"bytes"] isKindOfClass:NSNumber.class] ||
                              [entry[@"bytes"] unsignedLongLongValue] == 0 || [entry[@"bytes"] unsignedLongLongValue] > kMaxFileBytes)) {
            return NO;
        }
        [names addObject:entry[@"name"]];
    }
    return YES;
}

@interface BrowserFilterListUpdater () <NSURLSessionTaskDelegate>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, readwrite, getter=isChecking) BOOL checking;
@property (nonatomic) BOOL scheduled;
@property (nonatomic, strong) NSMutableArray<BrowserFilterListCheckCompletion> *completions;

@end

@implementation BrowserFilterListUpdater

+ (instancetype)sharedUpdater {
    static BrowserFilterListUpdater *updater;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        updater = [BrowserFilterListUpdater new];
    });
    return updater;
}

+ (NSInteger)appFormat {
    return kFilterListAppFormat;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("browser.filterlists.work", DISPATCH_QUEUE_SERIAL);
        _completions = [NSMutableArray array];
    }
    return self;
}

/// Eigene, flüchtige Sitzung: keine Cookies, kein Cache, keine Zugangsdaten; nur die Anfrage selbst geht raus.
/// Die Namensauflösung läuft wie bei allen App-Verbindungen über Cloudflare-DoH (BrowserDNSProxy setzt das für den
/// Standard-Privacy-Context).
- (NSURLSession *)session {
    if (_session == nil) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.URLCache = nil;
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPShouldSetCookies = NO;
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        configuration.URLCredentialStorage = nil;
        configuration.timeoutIntervalForRequest = 30.0;
        configuration.timeoutIntervalForResource = 180.0;
        configuration.HTTPMaximumConnectionsPerHost = 1;
        configuration.HTTPAdditionalHeaders = @{@"User-Agent": @"tvOS-Browser-Filterlisten"};
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    }
    return _session;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // Weiterleitungen nur auf HTTPS (GitHub leitet Release-Dateien auf einen eigenen Host um).
    completionHandler([request.URL.scheme.lowercaseString isEqualToString:@"https"] ? request : nil);
}

#pragma mark Orte

- (NSURL *)manifestURL {
#if DEBUG
    NSString *override = NSProcessInfo.processInfo.environment[@"FILTERLIST_URL"];
    if (override.length > 0) {
        return [NSURL URLWithString:override];
    }
#endif
    return [NSURL URLWithString:kFilterListManifestURL];
}

/// Library/Caches/FilterLists: tvOS erlaubt Apps dauerhaftes Schreiben nur dort (Application Support/Documents
/// sind auf dem Gerät nicht vorgesehen, siehe auch WebKit-Regelspeicher). Räumt tvOS die Caches auf, fallen die
/// heruntergeladenen Listen weg; dann gelten die mitgelieferten und die nächste Prüfung lädt neu.
- (NSURL *)rootDirectory {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@"FilterLists" isDirectory:YES];
}

- (NSURL *)directoryForComponent:(NSString *)component {
    return [self.rootDirectory URLByAppendingPathComponent:component isDirectory:YES];
}

- (NSURL *)activeDirectoryForComponent:(NSString *)component key:(NSString *)key {
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:key];
    if (!BrowserFilterListSafeName(name)) {
        return nil;
    }
    return [[self directoryForComponent:component] URLByAppendingPathComponent:name isDirectory:YES];
}

#pragma mark Mitgeliefert und heruntergeladen

- (NSURL *)bundledContentBlockerDirectory {
    NSURL *manifest = [NSBundle.mainBundle URLForResource:@"manifest" withExtension:@"json" subdirectory:@"ContentBlocker"];
    return manifest.URLByDeletingLastPathComponent;
}

- (NSDictionary *)bundledContentBlockerManifest {
    return BrowserFilterListReadJSON([self.bundledContentBlockerDirectory URLByAppendingPathComponent:kLocalManifestName]);
}

- (NSDictionary *)bundledScriptletsManifest {
    return BrowserFilterListReadJSON([NSBundle.mainBundle URLForResource:@"manifest" withExtension:@"json" subdirectory:@"Scriptlets"]);
}

/// Heruntergeladener Regelsatz-Stand, wenn vollständig vorhanden: @{directory, manifest}.
- (NSDictionary *)downloadedContentBlockerSet {
    NSURL *directory = [self activeDirectoryForComponent:kContentBlockerFolder key:kContentBlockerDirKey];
    NSDictionary *manifest = BrowserFilterListReadJSON([directory URLByAppendingPathComponent:kLocalManifestName]);
    if (manifest == nil || !BrowserFilterListValidLists(manifest[@"lists"], YES)) {
        return nil;
    }
    for (NSDictionary *entry in manifest[@"lists"]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[directory URLByAppendingPathComponent:entry[@"file"]].path]) {
            return nil;
        }
    }
    return @{@"directory": directory, @"manifest": manifest};
}

- (NSDictionary *)downloadedScriptlets {
    NSURL *directory = [self activeDirectoryForComponent:kScriptletsFolder key:kScriptletsDirKey];
    NSDictionary *manifest = BrowserFilterListReadJSON([directory URLByAppendingPathComponent:kLocalManifestName]);
    if (manifest == nil || !BrowserFilterListSafeName(manifest[@"file"])) {
        return nil;
    }
    NSURL *file = [directory URLByAppendingPathComponent:manifest[@"file"]];
    if (![NSFileManager.defaultManager fileExistsAtPath:file.path]) {
        return nil;
    }
    return @{@"file": file, @"manifest": manifest};
}

- (NSDictionary *)bundledContentBlockerSet {
    NSDictionary *bundled = [self bundledContentBlockerManifest];
    if (![bundled[@"lists"] isKindOfClass:NSArray.class]) {
        return nil;
    }
    return @{@"directory": self.bundledContentBlockerDirectory, @"manifest": bundled, @"downloaded": @NO};
}

- (NSDictionary *)preferredContentBlockerSet {
    NSDictionary *bundled = [self bundledContentBlockerManifest];
    NSDictionary *downloaded = [self downloadedContentBlockerSet];
    if (downloaded != nil && BrowserFilterListGeneratedAt(downloaded[@"manifest"]) > BrowserFilterListGeneratedAt(bundled)) {
        return @{@"directory": downloaded[@"directory"], @"manifest": downloaded[@"manifest"], @"downloaded": @YES};
    }
    return [self bundledContentBlockerSet];
}

- (NSURL *)preferredScriptletsFileURLDownloaded:(BOOL *)downloadedOut {
    NSDictionary *downloaded = [self downloadedScriptlets];
    BOOL useDownloaded = downloaded != nil &&
        BrowserFilterListGeneratedAt(downloaded[@"manifest"]) > BrowserFilterListGeneratedAt([self bundledScriptletsManifest]);
    if (downloadedOut != NULL) {
        *downloadedOut = useDownloaded;
    }
    if (useDownloaded) {
        return downloaded[@"file"];
    }
    return [NSBundle.mainBundle URLForResource:@"scriptlets.json" withExtension:@"z" subdirectory:@"Scriptlets"];
}

/// Stand, mit dem ein neues Manifest verglichen wird: der neuere aus mitgeliefert und heruntergeladen.
- (NSDictionary *)currentContentBlockerManifest {
    return [self preferredContentBlockerSet][@"manifest"];
}

- (NSDictionary *)currentScriptletsManifest {
    NSDictionary *bundled = [self bundledScriptletsManifest];
    NSDictionary *downloaded = [self downloadedScriptlets][@"manifest"];
    return BrowserFilterListGeneratedAt(downloaded) > BrowserFilterListGeneratedAt(bundled) ? downloaded : bundled;
}

- (void)discardDownloadedContentBlocker {
    [self discardComponent:kContentBlockerFolder key:kContentBlockerDirKey];
}

- (void)discardDownloadedScriptlets {
    [self discardComponent:kScriptletsFolder key:kScriptletsDirKey];
}

- (void)discardComponent:(NSString *)component key:(NSString *)key {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[FilterLists] %@: heruntergeladener Stand unbrauchbar, verworfen (mitgelieferte Listen gelten)", component);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        // bald neu prüfen statt erst morgen
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kLastCheckKey];
        [self removeInactiveDirectoriesOfComponent:component key:key];
    });
}

/// Löscht alle Stände eines Bestandteils außer dem aktiven. Ist der heruntergeladene Stand nicht neuer als der
/// mitgelieferte (App-Update brachte neuere Listen), wird auch er gelöscht.
- (void)removeInactiveDirectoriesOfComponent:(NSString *)component key:(NSString *)key {
    NSURL *active = [self activeDirectoryForComponent:component key:key];
    BOOL stale = NO;
    if ([component isEqualToString:kContentBlockerFolder]) {
        stale = active != nil && ![[self preferredContentBlockerSet][@"downloaded"] boolValue];
    } else {
        BOOL downloaded = NO;
        [self preferredScriptletsFileURLDownloaded:&downloaded];
        stale = active != nil && !downloaded;
    }
    if (stale) {
        NSLog(@"[FilterLists] %@: mitgelieferte Listen gelten (neuer nach App-Update oder heruntergeladene unvollständig), heruntergeladene entfernt", component);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        active = nil;
    }
    NSURL *folder = [self directoryForComponent:component];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil]) {
        if (active == nil || ![url.lastPathComponent isEqualToString:active.lastPathComponent]) {
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        }
    }
}

- (NSDate *)activeListsDate {
    NSDate *date = [BrowserContentBlocker sharedBlocker].activeListsDate;
    if (date == nil) {
        NSTimeInterval generatedAt = BrowserFilterListGeneratedAt([self currentContentBlockerManifest]);
        date = generatedAt > 0 ? [NSDate dateWithTimeIntervalSince1970:generatedAt] : nil;
    }
    return date;
}

+ (NSString *)displayStringForDate:(NSDate *)date {
    if (date == nil) {
        return @"–";
    }
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"de_DE"];
    formatter.dateFormat = @"dd.MM.yyyy";
    return [formatter stringFromDate:date];
}

#pragma mark Auslöser

- (BOOL)forceCheckRequested {
#if DEBUG
    return [NSProcessInfo.processInfo.environment[@"FILTERLIST_CHECK_NOW"] boolValue];
#else
    return NO;
#endif
}

- (BOOL)checkIsDue {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDate *lastCheck = [defaults objectForKey:kLastCheckKey];
    NSDate *lastAttempt = [defaults objectForKey:kLastAttemptKey];
    BOOL checkDue = ![lastCheck isKindOfClass:NSDate.class] || -lastCheck.timeIntervalSinceNow >= kCheckInterval || lastCheck.timeIntervalSinceNow > 60;
    BOOL attemptDue = ![lastAttempt isKindOfClass:NSDate.class] || -lastAttempt.timeIntervalSinceNow >= kRetryInterval || lastAttempt.timeIntervalSinceNow > 60;
    return checkDue && attemptDue;
}

- (void)pageDidFinishLoading {
    static BOOL forcedOnce = NO;
    BOOL force = [self forceCheckRequested] && !forcedOnce;
    if (self.scheduled || self.checking || (!force && ![self checkIsDue])) {
        return;
    }
    forcedOnce = forcedOnce || force;
    self.scheduled = YES;
    NSTimeInterval delay = force ? 2.0 : kCheckDelay;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.scheduled = NO;
        if (force || [self checkIsDue]) {
            [self runCheckWithCompletion:nil];
        }
    });
}

- (void)checkNowWithCompletion:(BrowserFilterListCheckCompletion)completion {
    [self runCheckWithCompletion:completion];
}

#pragma mark Prüfen und Laden

- (void)finishWithUpdated:(BOOL)updated message:(NSString *)message {
    NSLog(@"[FilterLists] %@", message);
    self.checking = NO;
    NSArray<BrowserFilterListCheckCompletion> *completions = [self.completions copy];
    [self.completions removeAllObjects];
    for (BrowserFilterListCheckCompletion completion in completions) {
        completion(updated, message);
    }
}

/// Lädt eine URL vollständig; Fehler als kurzer deutscher Text. Completion auf dem Hauptthread.
- (void)fetchURL:(NSURL *)url maxBytes:(unsigned long long)maxBytes completion:(void (^)(NSData *data, NSString *error))completion {
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *problem = nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error != nil) {
            problem = [NSString stringWithFormat:@"Server nicht erreichbar (%@)", error.localizedDescription];
        } else if (status != 200) {
            problem = [NSString stringWithFormat:@"Server antwortet mit %ld", (long)status];
        } else if (data.length == 0 || data.length > maxBytes) {
            problem = @"unerwartete Dateigröße";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(problem == nil ? data : nil, problem);
        });
    }] resume];
}

- (void)runCheckWithCompletion:(BrowserFilterListCheckCompletion)completion {
    if (completion != nil) {
        [self.completions addObject:[completion copy]];
    }
    if (self.checking) {
        return;
    }
    NSURL *manifestURL = self.manifestURL;
    NSString *scheme = manifestURL.scheme.lowercaseString;
    BOOL allowedScheme = [scheme isEqualToString:@"https"];
#if DEBUG
    allowedScheme = allowedScheme || [scheme isEqualToString:@"http"];
#endif
    if (manifestURL == nil || !allowedScheme) {
        [self finishWithUpdated:NO message:@"Keine gültige Adresse für die Filterlisten."];
        return;
    }
    self.checking = YES;
    [NSUserDefaults.standardUserDefaults setObject:[NSDate date] forKey:kLastAttemptKey];
    NSLog(@"[FilterLists] prüfe %@", manifestURL.absoluteString);
    [self fetchURL:manifestURL maxBytes:kMaxManifestBytes completion:^(NSData *data, NSString *error) {
        if (data == nil) {
            [self finishWithUpdated:NO message:[NSString stringWithFormat:@"Aktualisierung nicht möglich: %@. Die bisherigen Listen bleiben aktiv.", error]];
            return;
        }
        id manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"minAppFormat"] isKindOfClass:NSNumber.class]) {
            [self finishWithUpdated:NO message:@"Aktualisierung nicht möglich: Manifest unlesbar. Die bisherigen Listen bleiben aktiv."];
            return;
        }
        [NSUserDefaults.standardUserDefaults setObject:[NSDate date] forKey:kLastCheckKey];
        if ([manifest[@"minAppFormat"] integerValue] > kFilterListAppFormat) {
            [self finishWithUpdated:NO message:@"Neue Listen brauchen eine neuere App-Version. Die bisherigen Listen bleiben aktiv."];
            return;
        }
        [self updateFromManifest:manifest manifestURL:manifestURL];
    }];
}

- (void)updateFromManifest:(NSDictionary *)manifest manifestURL:(NSURL *)manifestURL {
    NSDictionary *remoteBlocker = [manifest[@"contentBlocker"] isKindOfClass:NSDictionary.class] ? manifest[@"contentBlocker"] : nil;
    NSDictionary *remoteScriptlets = [manifest[@"scriptlets"] isKindOfClass:NSDictionary.class] ? manifest[@"scriptlets"] : nil;
    NSDictionary *currentBlocker = [self currentContentBlockerManifest];
    NSDictionary *currentScriptlets = [self currentScriptletsManifest];
    BOOL blockerNewer = remoteBlocker != nil &&
        BrowserFilterListGeneratedAt(remoteBlocker) > BrowserFilterListGeneratedAt(currentBlocker) &&
        ![remoteBlocker[@"version"] isEqual:currentBlocker[@"version"]];
    BOOL scriptletsNewer = remoteScriptlets != nil &&
        BrowserFilterListGeneratedAt(remoteScriptlets) > BrowserFilterListGeneratedAt(currentScriptlets) &&
        ![remoteScriptlets[@"version"] isEqual:currentScriptlets[@"version"]];
    // Aufräumen: alte Stände, und heruntergeladene, die ein App-Update überholt hat
    [self removeInactiveDirectoriesOfComponent:kContentBlockerFolder key:kContentBlockerDirKey];
    [self removeInactiveDirectoriesOfComponent:kScriptletsFolder key:kScriptletsDirKey];
    NSLog(@"[FilterLists] Server %@: Regelsätze %@ (%@), Scriptlets %@ (%@)", manifest[@"version"],
          remoteBlocker[@"version"], blockerNewer ? @"neuer" : @"nicht neuer",
          remoteScriptlets[@"version"], scriptletsNewer ? @"neuer" : @"nicht neuer");
    if (!blockerNewer && !scriptletsNewer) {
        [self finishWithUpdated:NO message:[NSString stringWithFormat:@"Die Filterlisten sind aktuell (Stand %@).",
                                            [BrowserFilterListUpdater displayStringForDate:self.activeListsDate]]];
        return;
    }
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    __block BOOL anyUpdated = NO;
    void (^finish)(void) = ^{
        NSString *message;
        if (problems.count == 0) {
            message = [NSString stringWithFormat:@"Neue Filterlisten aktiv (Stand %@).",
                       [BrowserFilterListUpdater displayStringForDate:self.activeListsDate]];
        } else {
            message = [NSString stringWithFormat:@"%@ (%@). Wo nichts Neues geladen wurde, bleiben die bisherigen Listen aktiv.",
                       anyUpdated ? @"Teilweise aktualisiert" : @"Aktualisierung fehlgeschlagen",
                       [problems componentsJoinedByString:@"; "]];
        }
        [self finishWithUpdated:anyUpdated message:message];
    };
    void (^scriptletsStep)(void) = ^{
        if (!scriptletsNewer) {
            finish();
            return;
        }
        [self installScriptlets:remoteScriptlets manifestURL:manifestURL completion:^(NSString *error) {
            if (error != nil) {
                [problems addObject:[@"Scriptlets: " stringByAppendingString:error]];
            } else {
                anyUpdated = YES;
            }
            finish();
        }];
    };
    if (!blockerNewer) {
        scriptletsStep();
        return;
    }
    [self installContentBlocker:remoteBlocker manifestURL:manifestURL completion:^(NSString *error) {
        if (error != nil) {
            [problems addObject:[@"Regelsätze: " stringByAppendingString:error]];
        } else {
            anyUpdated = YES;
        }
        scriptletsStep();
    }];
}

/// Ordnername für einen Stand: <generatedAt>-<version>
- (NSString *)directoryNameForManifest:(NSDictionary *)manifest {
    NSString *version = [manifest[@"version"] description] ?: @"x";
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"] invertedSet];
    version = [[version componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@""];
    if (version.length > 40) {
        version = [version substringToIndex:40];
    }
    return [NSString stringWithFormat:@"%.0f-%@", BrowserFilterListGeneratedAt(manifest), version];
}

/// Neuer, leerer Arbeitsordner für einen Stand (unter dem Ordner des Bestandteils, damit das Umbenennen atomar bleibt).
- (NSURL *)freshStagingDirectoryForComponent:(NSString *)component {
    NSURL *folder = [self directoryForComponent:component];
    NSURL *staging = [folder URLByAppendingPathComponent:[@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:nil];
    return staging;
}

/// Staging-Ordner unter seinen endgültigen Namen setzen (ein vorhandener gleichnamiger, inaktiver Ordner weicht).
- (NSURL *)promoteStaging:(NSURL *)staging toName:(NSString *)name component:(NSString *)component key:(NSString *)key {
    NSURL *target = [[self directoryForComponent:component] URLByAppendingPathComponent:name isDirectory:YES];
    NSURL *active = [self activeDirectoryForComponent:component key:key];
    if ([active.lastPathComponent isEqualToString:name]) {
        // gleicher Stand ist schon aktiv (sollte wegen des Versionsvergleichs nicht vorkommen)
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
        return target;
    }
    [NSFileManager.defaultManager removeItemAtURL:target error:nil];
    NSError *error = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:staging toURL:target error:&error]) {
        NSLog(@"[FilterLists] Umbenennen fehlgeschlagen: %@", error);
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
        return nil;
    }
    return target;
}

/// Prüft eine geladene Datei: Größe, SHA-256 der Datei, optional SHA-256-Präfix des entpackten Inhalts.
/// Liefert den entpackten Inhalt oder nil.
static NSData *BrowserFilterListVerify(NSData *packed, NSDictionary *entry, NSString **problem) {
    if (packed.length != [entry[@"bytes"] unsignedLongLongValue]) {
        *problem = @"Dateigröße stimmt nicht";
        return nil;
    }
    if (![BrowserFilterListSHA256(packed) isEqualToString:entry[@"sha256"]]) {
        *problem = @"Prüfsumme (SHA-256) stimmt nicht";
        return nil;
    }
    NSData *json = [packed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
    if (json == nil) {
        *problem = @"Datei lässt sich nicht entpacken";
        return nil;
    }
    if (entry[@"hash"] != nil && ![[BrowserFilterListSHA256(json) substringToIndex:12] isEqualToString:entry[@"hash"]]) {
        *problem = @"Inhaltskennung stimmt nicht";
        return nil;
    }
    return json;
}

- (void)installContentBlocker:(NSDictionary *)remote manifestURL:(NSURL *)manifestURL completion:(void (^)(NSString *error))completion {
    if (!BrowserFilterListValidLists(remote[@"lists"], YES) || BrowserFilterListGeneratedAt(remote) <= 0) {
        completion(@"Manifest unvollständig");
        return;
    }
    NSURL *staging = [self freshStagingDirectoryForComponent:kContentBlockerFolder];
    [self downloadLists:remote[@"lists"] index:0 staging:staging manifestURL:manifestURL completion:^(NSString *error) {
        if (error != nil) {
            [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
            completion(error);
            return;
        }
        [self finishContentBlocker:remote staging:staging completion:completion];
    }];
}

/// Lädt die Regelsätze nacheinander in den Staging-Ordner und prüft jeden sofort.
- (void)downloadLists:(NSArray<NSDictionary *> *)lists index:(NSUInteger)index staging:(NSURL *)staging
          manifestURL:(NSURL *)manifestURL completion:(void (^)(NSString *error))completion {
    if (index == lists.count) {
        completion(nil);
        return;
    }
    NSDictionary *entry = lists[index];
    NSURL *url = [NSURL URLWithString:entry[@"file"] relativeToURL:manifestURL].absoluteURL;
    [self fetchURL:url maxBytes:kMaxFileBytes completion:^(NSData *data, NSString *error) {
        if (data == nil) {
            completion([NSString stringWithFormat:@"%@: %@", entry[@"name"], error]);
            return;
        }
        dispatch_async(self.workQueue, ^{
            NSString *problem = nil;
            BOOL ok = BrowserFilterListVerify(data, entry, &problem) != nil;
            if (ok && ![data writeToURL:[staging URLByAppendingPathComponent:entry[@"file"]] atomically:YES]) {
                ok = NO;
                problem = @"Speichern fehlgeschlagen";
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ok) {
                    NSLog(@"[FilterLists] %@ verworfen: %@", entry[@"name"], problem);
                    completion([NSString stringWithFormat:@"%@: %@", entry[@"name"], problem]);
                    return;
                }
                NSLog(@"[FilterLists] %@ geladen und geprüft (%lu Bytes)", entry[@"name"], (unsigned long)data.length);
                [self downloadLists:lists index:index + 1 staging:staging manifestURL:manifestURL completion:completion];
            });
        });
    }];
}

- (void)finishContentBlocker:(NSDictionary *)remote staging:(NSURL *)staging completion:(void (^)(NSString *error))completion {
    NSData *manifestData = [NSJSONSerialization dataWithJSONObject:remote options:NSJSONWritingPrettyPrinted error:nil];
    if (manifestData == nil || ![manifestData writeToURL:[staging URLByAppendingPathComponent:kLocalManifestName] atomically:YES]) {
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
        completion(@"Speichern fehlgeschlagen");
        return;
    }
    NSString *name = [self directoryNameForManifest:remote];
    NSURL *directory = [self promoteStaging:staging toName:name component:kContentBlockerFolder key:kContentBlockerDirKey];
    if (directory == nil) {
        completion(@"Speichern fehlgeschlagen");
        return;
    }
    // Erst vollständig kompilieren, dann umschalten. Schlägt etwas fehl, bleibt der bisherige Stand aktiv.
    [[BrowserContentBlocker sharedBlocker] installListSetAtDirectory:directory manifest:remote completion:^(BOOL ok, NSString *error) {
        if (!ok) {
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            completion(error ?: @"Kompilieren fehlgeschlagen");
            return;
        }
        [NSUserDefaults.standardUserDefaults setObject:name forKey:kContentBlockerDirKey];
        [self removeInactiveDirectoriesOfComponent:kContentBlockerFolder key:kContentBlockerDirKey];
        NSLog(@"[FilterLists] Regelsätze umgeschaltet auf %@ (%@)", remote[@"version"], remote[@"date"]);
        completion(nil);
    }];
}

- (void)installScriptlets:(NSDictionary *)remote manifestURL:(NSURL *)manifestURL completion:(void (^)(NSString *error))completion {
    if (!BrowserFilterListSafeName(remote[@"file"]) || !BrowserFilterListHex(remote[@"sha256"], 64) ||
        ![remote[@"bytes"] isKindOfClass:NSNumber.class] || [remote[@"bytes"] unsignedLongLongValue] > kMaxFileBytes ||
        BrowserFilterListGeneratedAt(remote) <= 0) {
        completion(@"Manifest unvollständig");
        return;
    }
    NSURL *url = [NSURL URLWithString:remote[@"file"] relativeToURL:manifestURL].absoluteURL;
    [self fetchURL:url maxBytes:kMaxFileBytes completion:^(NSData *data, NSString *error) {
        if (data == nil) {
            completion(error);
            return;
        }
        dispatch_async(self.workQueue, ^{
            NSString *problem = nil;
            NSMutableDictionary *entry = [remote mutableCopy];
            [entry removeObjectForKey:@"hash"];
            NSDictionary *parsed = nil;
            if (BrowserFilterListVerify(data, entry, &problem) != nil) {
                parsed = [BrowserScriptletInjector scriptletDataFromPackedData:data];
                if (parsed == nil) {
                    problem = @"Inhalt unlesbar";
                }
            }
            NSURL *staging = nil;
            if (parsed != nil) {
                staging = [self freshStagingDirectoryForComponent:kScriptletsFolder];
                NSData *manifestData = [NSJSONSerialization dataWithJSONObject:remote options:NSJSONWritingPrettyPrinted error:nil];
                if (![data writeToURL:[staging URLByAppendingPathComponent:remote[@"file"]] atomically:YES] ||
                    ![manifestData writeToURL:[staging URLByAppendingPathComponent:kLocalManifestName] atomically:YES]) {
                    problem = @"Speichern fehlgeschlagen";
                    parsed = nil;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (parsed == nil) {
                    if (staging != nil) {
                        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
                    }
                    NSLog(@"[FilterLists] Scriptlets verworfen: %@", problem);
                    completion(problem);
                    return;
                }
                NSString *name = [self directoryNameForManifest:remote];
                if ([self promoteStaging:staging toName:name component:kScriptletsFolder key:kScriptletsDirKey] == nil) {
                    completion(@"Speichern fehlgeschlagen");
                    return;
                }
                [NSUserDefaults.standardUserDefaults setObject:name forKey:kScriptletsDirKey];
                [[BrowserScriptletInjector sharedInjector] activateScriptletData:parsed];
                [self removeInactiveDirectoriesOfComponent:kScriptletsFolder key:kScriptletsDirKey];
                NSLog(@"[FilterLists] Scriptlets umgeschaltet auf %@ (%@)", remote[@"version"], remote[@"date"]);
                completion(nil);
            });
        });
    }];
}

@end
