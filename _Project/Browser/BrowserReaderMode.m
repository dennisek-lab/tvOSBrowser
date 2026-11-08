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

@implementation BrowserReaderMode

+ (void)runMethod:(NSString *)method onWebView:(BrowserWebView *)webView completion:(void (^)(BrowserReaderState))completion {
    NSString *script = BrowserReaderInstallScript();
    if (script.length < 1000 || webView == nil) {
        if (completion) { completion(BrowserReaderStateUnavailable); }
        return;
    }
    CGFloat viewWidth = CGRectGetWidth(webView.bounds);
    NSString *full = [NSString stringWithFormat:
        @"(function(){try{if(!window.__browserReader){window.__browserReaderViewWidth=%.0f;%@}"
         "return window.__browserReader.%@();}catch(e){return 'e:'+e;}})()", viewWidth, script, method];
    [webView evaluateJavaScriptAsync:full completion:^(id result) {
#if DEBUG
        NSLog(@"[Reader] %@ -> %@", method, result);
#endif
        if (completion) { completion(BrowserReaderStateFromResult(result)); }
    }];
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
