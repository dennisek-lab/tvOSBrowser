#import "BrowserReaderMode.h"
#import "BrowserWebView.h"

/// Zusammengesetztes Installationsskript (Readability-readerable, Readability, reader.js), einmal gelesen.
/// `module` wird verdeckt, damit die Dateien nichts an ein von der Seite definiertes `module` hängen.
static NSString *BrowserReaderInstallScript(void) {
    static NSString *script;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = NSBundle.mainBundle;
        NSMutableString *combined = [NSMutableString stringWithString:@"(function(module){\n"];
        for (NSString *name in @[@"Readability-readerable", @"Readability", @"reader"]) {
            NSString *path = [bundle pathForResource:name ofType:@"js" inDirectory:@"Reader"];
            NSString *source = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
            if (source.length == 0) {
                NSLog(@"[Reader] Datei fehlt: Reader/%@.js", name);
                continue;
            }
            [combined appendString:source];
            [combined appendString:@"\n"];
        }
        [combined appendString:@"})(undefined);"];
        script = [combined copy];
    });
    return script;
}

static BrowserReaderState BrowserReaderStateFromResult(id result) {
    NSString *text = [result isKindOfClass:NSString.class] ? result : @"";
    if ([text isEqualToString:@"a"]) { return BrowserReaderStateActive; }
    if ([text isEqualToString:@"y"]) { return BrowserReaderStateAvailable; }
    return BrowserReaderStateUnavailable;
}

const NSUInteger BrowserReaderDefaultTextLength = 6000;

@implementation BrowserReaderMode

/// Ruft window.__browserReader.<call> auf (call mit Argumentliste, z. B. "check()" oder "text(6000)").
+ (void)evaluateCall:(NSString *)call onWebView:(BrowserWebView *)webView completion:(void (^)(id _Nullable result))completion {
    NSString *script = BrowserReaderInstallScript();
    if (script.length < 1000 || webView == nil) {
        if (completion) { completion(nil); }
        return;
    }
    CGFloat viewWidth = CGRectGetWidth(webView.bounds);
    NSString *full = [NSString stringWithFormat:
        @"(function(){try{if(!window.__browserReader){window.__browserReaderViewWidth=%.0f;%@}"
         "return window.__browserReader.%@;}catch(e){return 'e:'+e;}})()", viewWidth, script, call];
    [webView evaluateJavaScriptAsync:full completion:completion];
}

+ (void)runMethod:(NSString *)method onWebView:(BrowserWebView *)webView completion:(void (^)(BrowserReaderState))completion {
    [self evaluateCall:[method stringByAppendingString:@"()"] onWebView:webView completion:^(id result) {
#if DEBUG
        NSLog(@"[Reader] %@ -> %@", method, result);
#endif
        if (completion) { completion(BrowserReaderStateFromResult(result)); }
    }];
}

+ (void)textForWebView:(BrowserWebView *)webView
             maxLength:(NSUInteger)maxLength
            completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    NSUInteger limit = maxLength > 0 ? maxLength : BrowserReaderDefaultTextLength;
    [self evaluateCall:[NSString stringWithFormat:@"text(%lu)", (unsigned long)limit] onWebView:webView completion:^(id result) {
        NSDictionary<NSString *, id> *info = nil;
        if ([result isKindOfClass:NSString.class] && [(NSString *)result hasPrefix:@"{"]) {
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            info = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        }
#if DEBUG
        NSLog(@"[Reader] text -> %@ %lu Zeichen (Seite %@)", info[@"source"] ?: result,
              (unsigned long)[info[@"text"] length], info[@"total"] ?: @"?");
#endif
        if (completion) { completion(info); }
    }];
}

+ (void)textForWebView:(BrowserWebView *)webView completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    [self textForWebView:webView maxLength:BrowserReaderDefaultTextLength completion:completion];
}

+ (void)checkWebView:(BrowserWebView *)webView completion:(void (^)(BrowserReaderState))completion {
    [self runMethod:@"check" onWebView:webView completion:completion];
}

+ (void)toggleWebView:(BrowserWebView *)webView completion:(void (^)(BrowserReaderState))completion {
    [self runMethod:@"toggle" onWebView:webView completion:completion];
}

+ (void)exitWebView:(BrowserWebView *)webView completion:(void (^)(BrowserReaderState))completion {
    [self runMethod:@"exit" onWebView:webView completion:completion];
}

@end
