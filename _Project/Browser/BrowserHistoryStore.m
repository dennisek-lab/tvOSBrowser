//
//  BrowserHistoryStore.m
//

#import "BrowserHistoryStore.h"

NSString * const BrowserHistoryStoreDidChangeNotification = @"BrowserHistoryStoreDidChangeNotification";

static NSString * const kHistoryDefaultsKey = @"BrowserHistoryEntries";
static NSString * const kFavoritesDefaultsKey = @"BrowserFavoriteEntries";
/// tvOS-Speicher für UserDefaults ist knapp, deshalb klein halten.
static NSUInteger const kMaxHistoryEntries = 200;
static NSUInteger const kMaxFavorites = 30;
/// Ein erneuter Besuch desselben Hosts zählt erst nach dieser Pause als neuer Besuch.
static NSTimeInterval const kVisitGap = 30 * 60;

@implementation BrowserSiteEntry

+ (instancetype)entryFromDictionary:(NSDictionary *)dict {
    NSString *host = [dict[@"host"] isKindOfClass:NSString.class] ? dict[@"host"] : nil;
    if (host.length == 0) {
        return nil;
    }
    BrowserSiteEntry *entry = [BrowserSiteEntry new];
    entry.host = host;
    entry.urlString = [dict[@"url"] isKindOfClass:NSString.class] ? dict[@"url"] : [@"https://" stringByAppendingString:host];
    entry.name = [dict[@"name"] isKindOfClass:NSString.class] ? dict[@"name"] : @"";
    entry.visitCount = [dict[@"count"] unsignedIntegerValue];
    entry.lastVisit = [dict[@"last"] doubleValue];
    return entry;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{@"host": self.host, @"url": self.urlString ?: @"", @"name": self.name ?: @"",
             @"count": @(self.visitCount), @"last": @(self.lastVisit)};
}

@end

@interface BrowserHistoryStore ()
@property (nonatomic) NSMutableDictionary<NSString *, BrowserSiteEntry *> *history;
@property (nonatomic) NSMutableArray<BrowserSiteEntry *> *favoriteList;
@end

@implementation BrowserHistoryStore

+ (instancetype)sharedStore {
    static BrowserHistoryStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [BrowserHistoryStore new];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _history = [NSMutableDictionary dictionary];
        _favoriteList = [NSMutableArray array];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        for (NSDictionary *dict in [defaults arrayForKey:kHistoryDefaultsKey] ?: @[]) {
            BrowserSiteEntry *entry = [dict isKindOfClass:NSDictionary.class] ? [BrowserSiteEntry entryFromDictionary:dict] : nil;
            if (entry != nil) {
                _history[entry.host] = entry;
            }
        }
        for (NSDictionary *dict in [defaults arrayForKey:kFavoritesDefaultsKey] ?: @[]) {
            BrowserSiteEntry *entry = [dict isKindOfClass:NSDictionary.class] ? [BrowserSiteEntry entryFromDictionary:dict] : nil;
            if (entry != nil) {
                [_favoriteList addObject:entry];
            }
        }
    }
    return self;
}

+ (NSString *)hostKeyForURL:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return nil;
    }
    NSString *host = url.host.lowercaseString;
    if ([host hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    return host.length > 0 ? host : nil;
}

/// Suchergebnisseiten zählen nicht als besuchte Website.
+ (BOOL)isSearchResultURL:(NSURL *)url host:(NSString *)host {
    return ([host isEqualToString:@"google.com"] || [host hasPrefix:@"google."] || [host hasSuffix:@".google.com"]) &&
        [url.path hasPrefix:@"/search"];
}

- (void)persist {
    NSMutableArray *historyArray = [NSMutableArray array];
    for (BrowserSiteEntry *entry in self.history.allValues) {
        [historyArray addObject:entry.dictionaryRepresentation];
    }
    NSMutableArray *favoriteArray = [NSMutableArray array];
    for (BrowserSiteEntry *entry in self.favoriteList) {
        [favoriteArray addObject:entry.dictionaryRepresentation];
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:historyArray forKey:kHistoryDefaultsKey];
    [defaults setObject:favoriteArray forKey:kFavoritesDefaultsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:BrowserHistoryStoreDidChangeNotification object:self];
}

- (void)recordVisitWithURL:(NSURL *)url title:(NSString *)title {
    NSString *host = [BrowserHistoryStore hostKeyForURL:url];
    if (host == nil || [BrowserHistoryStore isSearchResultURL:url host:host]) {
        return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *trimmedTitle = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BrowserSiteEntry *entry = self.history[host];
    if (entry == nil) {
        entry = [BrowserSiteEntry new];
        entry.host = host;
        self.history[host] = entry;
    }
    if (entry.visitCount == 0 || now - entry.lastVisit > kVisitGap) {
        entry.visitCount += 1;
    }
    entry.lastVisit = now;
    entry.urlString = url.absoluteString;
    if (trimmedTitle.length > 0) {
        entry.name = trimmedTitle;
    }
    // Favoriten ohne Namen bekommen den Namen der Seite nachgereicht.
    if (trimmedTitle.length > 0) {
        for (BrowserSiteEntry *favorite in self.favoriteList) {
            if ([favorite.host isEqualToString:host] && favorite.name.length == 0) {
                favorite.name = trimmedTitle;
            }
        }
    }
    if (self.history.count > kMaxHistoryEntries) {
        NSArray<BrowserSiteEntry *> *sorted = [self.history.allValues sortedArrayUsingComparator:^NSComparisonResult(BrowserSiteEntry *a, BrowserSiteEntry *b) {
            return a.lastVisit < b.lastVisit ? NSOrderedAscending : NSOrderedDescending;
        }];
        NSUInteger excess = self.history.count - kMaxHistoryEntries;
        for (NSUInteger i = 0; i < excess; i++) {
            [self.history removeObjectForKey:sorted[i].host];
        }
    }
    [self persist];
}

- (NSArray<BrowserSiteEntry *> *)recentEntries:(NSUInteger)limit {
    NSArray *sorted = [self.history.allValues sortedArrayUsingComparator:^NSComparisonResult(BrowserSiteEntry *a, BrowserSiteEntry *b) {
        return a.lastVisit > b.lastVisit ? NSOrderedAscending : NSOrderedDescending;
    }];
    return sorted.count > limit ? [sorted subarrayWithRange:NSMakeRange(0, limit)] : sorted;
}

- (NSArray<BrowserSiteEntry *> *)topEntries:(NSUInteger)limit {
    NSArray *sorted = [self.history.allValues sortedArrayUsingComparator:^NSComparisonResult(BrowserSiteEntry *a, BrowserSiteEntry *b) {
        if (a.visitCount != b.visitCount) {
            return a.visitCount > b.visitCount ? NSOrderedAscending : NSOrderedDescending;
        }
        return a.lastVisit > b.lastVisit ? NSOrderedAscending : NSOrderedDescending;
    }];
    return sorted.count > limit ? [sorted subarrayWithRange:NSMakeRange(0, limit)] : sorted;
}

- (NSArray<BrowserSiteEntry *> *)favorites {
    return [self.favoriteList copy];
}

- (void)addFavoriteWithURL:(NSURL *)url title:(NSString *)title {
    NSString *host = [BrowserHistoryStore hostKeyForURL:url];
    if (host == nil || [self isFavoriteURL:url] || self.favoriteList.count >= kMaxFavorites) {
        return;
    }
    BrowserSiteEntry *entry = [BrowserSiteEntry new];
    entry.host = host;
    entry.urlString = url.absoluteString;
    entry.name = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    entry.lastVisit = NSDate.date.timeIntervalSince1970;
    [self.favoriteList addObject:entry];
    [self persist];
}

- (void)removeFavoriteWithURL:(NSURL *)url {
    NSString *host = [BrowserHistoryStore hostKeyForURL:url];
    if (host == nil) {
        return;
    }
    NSUInteger before = self.favoriteList.count;
    [self.favoriteList filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(BrowserSiteEntry *entry, __unused id bindings) {
        return ![entry.host isEqualToString:host];
    }]];
    if (self.favoriteList.count != before) {
        [self persist];
    }
}

- (BOOL)isFavoriteURL:(NSURL *)url {
    NSString *host = [BrowserHistoryStore hostKeyForURL:url];
    if (host == nil) {
        return NO;
    }
    for (BrowserSiteEntry *entry in self.favoriteList) {
        if ([entry.host isEqualToString:host]) {
            return YES;
        }
    }
    return NO;
}

@end
