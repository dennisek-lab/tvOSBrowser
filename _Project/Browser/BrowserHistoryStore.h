//
//  BrowserHistoryStore.h
//  Verlauf (je Host zusammengefasst) und Favoriten, gespeichert in NSUserDefaults.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ein Eintrag für eine Website (Host ohne "www.").
@interface BrowserSiteEntry : NSObject
@property (nonatomic, copy) NSString *host;
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger visitCount;
@property (nonatomic) NSTimeInterval lastVisit;
@end

extern NSString * const BrowserHistoryStoreDidChangeNotification;

@interface BrowserHistoryStore : NSObject

+ (instancetype)sharedStore;

/// Host ohne "www." in Kleinbuchstaben, nil bei ungeeigneten Adressen.
+ (nullable NSString *)hostKeyForURL:(NSURL *)url;

- (void)recordVisitWithURL:(NSURL *)url title:(nullable NSString *)title;
- (NSArray<BrowserSiteEntry *> *)recentEntries:(NSUInteger)limit;
- (NSArray<BrowserSiteEntry *> *)topEntries:(NSUInteger)limit;
- (NSArray<BrowserSiteEntry *> *)favorites;
- (void)addFavoriteWithURL:(NSURL *)url title:(nullable NSString *)title;
- (void)removeFavoriteWithURL:(NSURL *)url;
- (BOOL)isFavoriteURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
