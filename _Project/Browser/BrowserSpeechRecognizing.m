#import "BrowserSpeechRecognizing.h"

@implementation BrowserWebSubtitleCue

+ (instancetype)cueWithStart:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text {
    return [[self alloc] initWithStart:start end:end text:text];
}

- (instancetype)initWithStart:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text {
    self = [super init];
    if (self) {
        _start = start;
        _end = MAX(start, end);
        _text = [text copy] ?: @"";
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"[%.2f–%.2f] %@", self.start, self.end, self.text];
}

@end
