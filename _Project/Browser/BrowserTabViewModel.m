#import "BrowserTabViewModel.h"

@implementation BrowserTabViewModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = [[[NSUUID UUID] UUIDString] copy];
        _requestURL = @"";
        _previousURL = @"";
        _title = @"Neuer Tab";
        _URLString = @"";
        _savedScrollOffset = CGPointZero;
        _hasSavedScrollOffset = NO;
        _needsScrollRestore = NO;
        _openedAt = NSDate.date.timeIntervalSince1970;
        _userInteracted = YES;
    }
    return self;
}

- (instancetype)initWithSessionRepresentation:(NSDictionary *)sessionRepresentation {
    self = [self init];
    if (self == nil) {
        return nil;
    }
    
    NSString *requestURL = [sessionRepresentation[@"requestURL"] isKindOfClass:[NSString class]] ? sessionRepresentation[@"requestURL"] : @"";
    NSString *previousURL = [sessionRepresentation[@"previousURL"] isKindOfClass:[NSString class]] ? sessionRepresentation[@"previousURL"] : @"";
    NSString *title = [sessionRepresentation[@"title"] isKindOfClass:[NSString class]] ? sessionRepresentation[@"title"] : @"Neuer Tab";
    NSString *URLString = [sessionRepresentation[@"URLString"] isKindOfClass:[NSString class]] ? sessionRepresentation[@"URLString"] : @"";
    NSNumber *scrollOffsetX = [sessionRepresentation[@"scrollOffsetX"] isKindOfClass:[NSNumber class]] ? sessionRepresentation[@"scrollOffsetX"] : nil;
    NSNumber *scrollOffsetY = [sessionRepresentation[@"scrollOffsetY"] isKindOfClass:[NSNumber class]] ? sessionRepresentation[@"scrollOffsetY"] : nil;
    NSNumber *openedAt = [sessionRepresentation[@"openedAt"] isKindOfClass:[NSNumber class]] ? sessionRepresentation[@"openedAt"] : nil;
    NSNumber *used = [sessionRepresentation[@"used"] isKindOfClass:[NSNumber class]] ? sessionRepresentation[@"used"] : nil;
    
    self.requestURL = requestURL;
    self.previousURL = previousURL;
    // Alte Sitzungen haben „New Tab“ gespeichert.
    self.title = (title.length > 0 && ![title isEqualToString:@"New Tab"]) ? title : @"Neuer Tab";
    self.URLString = URLString;
    if (scrollOffsetX != nil && scrollOffsetY != nil) {
        self.savedScrollOffset = CGPointMake(scrollOffsetX.doubleValue, scrollOffsetY.doubleValue);
        self.hasSavedScrollOffset = YES;
        self.needsScrollRestore = YES;
    }
    if (openedAt != nil) {
        self.openedAt = openedAt.doubleValue;
    }
    // Alte Sitzungen kennen das Flag nicht: deren Tabs gelten als benutzt und schließen sich nie von selbst.
    self.userInteracted = used != nil ? used.boolValue : YES;
    
    return self;
}

- (NSDictionary *)sessionRepresentation {
    NSMutableDictionary *representation = [NSMutableDictionary dictionary];
    representation[@"requestURL"] = self.requestURL ?: @"";
    representation[@"previousURL"] = self.previousURL ?: @"";
    representation[@"title"] = self.title ?: @"Neuer Tab";
    representation[@"URLString"] = self.URLString ?: @"";
    if (self.hasSavedScrollOffset) {
        representation[@"scrollOffsetX"] = @(self.savedScrollOffset.x);
        representation[@"scrollOffsetY"] = @(self.savedScrollOffset.y);
    }
    representation[@"openedAt"] = @(self.openedAt);
    representation[@"used"] = @(self.userInteracted);
    return representation;
}

@end
