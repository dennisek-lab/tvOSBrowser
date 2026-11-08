#import "BrowserClickTargetTracker.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kBrowserTargetsMessageName = @"browserTargets";

static NSString *BrowserClickTargetScript(void) {
    return @"(function(){"
    "if (window.__browserTargets) { return; }"
    "var SEL='a[href],button,input:not([type=hidden]),select,textarea,summary,label[for],"
        "[role=button],[role=link],[role=tab],[role=menuitem],[role=option],[role=checkbox],[role=switch],[role=radio],"
        "[onclick],[tabindex]:not([tabindex=\"-1\"]),[contenteditable=\"\"],[contenteditable=true]';"
    "var pending=false, last='';"
    "function fixedLike(el){"
        "for (var n=el, i=0; n && n!==document.body && i<12; n=n.parentElement, i++){"
            "var p=getComputedStyle(n).position; if (p==='fixed'||p==='sticky') { return 1; }"
        "}"
        "return 0;"
    "}"
    "function usable(el, r){"
        "if (r.width<6||r.height<6) { return false; }"
        "if (r.bottom<0||r.right<0||r.top>innerHeight||r.left>innerWidth) { return false; }"
        "var s=getComputedStyle(el);"
        "if (s.visibility==='hidden'||s.display==='none'||s.pointerEvents==='none'||parseFloat(s.opacity)<0.05) { return false; }"
        "var cx=Math.min(Math.max(r.left+r.width/2,0),innerWidth-1), cy=Math.min(Math.max(r.top+r.height/2,0),innerHeight-1);"
        "var hit=document.elementFromPoint(cx,cy);"
        "return !!hit && (hit===el || el.contains(hit) || hit.contains(el));"
    "}"
    "function collect(){"
        "pending=false;"
        "if (!document.documentElement) { return; }"
        "var out=[], els=document.querySelectorAll(SEL);"
        "for (var i=0; i<els.length && out.length<500; i++){"
            "var el=els[i], r=el.getBoundingClientRect();"
            "if (!usable(el,r)) { continue; }"
            "out.push([Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height),fixedLike(el)]);"
        "}"
        "var key=innerWidth+':'+scrollX+':'+scrollY+':'+out.join(';');"
        "if (key===last) { return; }"
        "last=key;"
        "try { webkit.messageHandlers.browserTargets.postMessage({w:innerWidth,sx:scrollX,sy:scrollY,t:out}); } catch(e) {}"
    "}"
    "function schedule(delay){"
        "if (pending) { return; }"
        "pending=true;"
        "setTimeout(function(){ requestAnimationFrame(collect); }, delay);"
    "}"
    "window.__browserTargets={report:function(){ last=''; pending=false; collect(); }};"
    "addEventListener('scroll',function(){ schedule(150); },{passive:true,capture:true});"
    "addEventListener('resize',function(){ schedule(150); });"
    "addEventListener('load',function(){ schedule(50); });"
    "try { new MutationObserver(function(){ schedule(350); }).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['class','style','hidden','aria-hidden','disabled']}); } catch(e) {}"
    "schedule(0);"
    "})();";
}

/// Schwacher Vermittler, weil WKUserContentController seinen Handler festhält.
@interface BrowserClickTargetMessageProxy : NSObject
@property (nonatomic, weak) BrowserClickTargetTracker *tracker;
@end

@interface BrowserClickTargetTracker ()
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *rawTargets;
@property (nonatomic) CGFloat cssViewportWidth;
@property (nonatomic) CGPoint contentOffsetAtReport;
- (void)handleMessageBody:(id)body;
@end

@implementation BrowserClickTargetMessageProxy
- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    (void)controller;
    id body = [message respondsToSelector:@selector(body)] ? ((id (*)(id, SEL))objc_msgSend)(message, @selector(body)) : nil;
    [self.tracker handleMessageBody:body];
}
@end

@implementation BrowserClickTargetTracker

- (instancetype)init {
    self = [super init];
    if (self) {
        _rawTargets = @[];
    }
    return self;
}

+ (NSString *)refreshScript {
    return @"window.__browserTargets && window.__browserTargets.report();";
}

- (void)installIntoConfiguration:(id)configuration {
    if (configuration == nil) {
        return;
    }
    id controller = ((id (*)(id, SEL))objc_msgSend)(configuration, NSSelectorFromString(@"userContentController"));
    Class scriptClass = NSClassFromString(@"WKUserScript");
    SEL addHandler = NSSelectorFromString(@"addScriptMessageHandler:name:");
    SEL addScript = NSSelectorFromString(@"addUserScript:");
    SEL scriptInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if (controller == nil || scriptClass == Nil ||
        ![controller respondsToSelector:addHandler] || ![controller respondsToSelector:addScript] ||
        ![scriptClass instancesRespondToSelector:scriptInit]) {
        return;
    }

    Protocol *protocol = objc_getProtocol("WKScriptMessageHandler");
    if (protocol != NULL && !class_conformsToProtocol(BrowserClickTargetMessageProxy.class, protocol)) {
        class_addProtocol(BrowserClickTargetMessageProxy.class, protocol);
    }
    BrowserClickTargetMessageProxy *proxy = [BrowserClickTargetMessageProxy new];
    proxy.tracker = self;
    ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addHandler, proxy, kBrowserTargetsMessageName);

    id script = ((id (*)(id, SEL))objc_msgSend)((id)scriptClass, @selector(alloc));
    // injectionTime 1 = WKUserScriptInjectionTimeAtDocumentEnd, nur Hauptframe.
    script = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(script, scriptInit, BrowserClickTargetScript(), 1, YES);
    if (script != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, script);
    }
}

- (void)handleMessageBody:(id)body {
    if (![body isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSDictionary *dictionary = body;
    NSArray *targets = [dictionary[@"t"] isKindOfClass:NSArray.class] ? dictionary[@"t"] : @[];
    NSMutableArray *valid = [NSMutableArray arrayWithCapacity:targets.count];
    for (id entry in targets) {
        if ([entry isKindOfClass:NSArray.class] && [entry count] >= 5) {
            [valid addObject:entry];
        }
    }
    self.rawTargets = valid;
    self.cssViewportWidth = [dictionary[@"w"] doubleValue];
    self.contentOffsetAtReport = self.scrollView != nil ? self.scrollView.contentOffset : CGPointZero;
    if (self.targetsDidChange != nil) {
        self.targetsDidChange();
    }
}

- (void)reset {
    self.rawTargets = @[];
    if (self.targetsDidChange != nil) {
        self.targetsDidChange();
    }
}

- (NSArray<NSValue *> *)targetRectsForViewWidth:(CGFloat)viewWidth {
    if (self.rawTargets.count == 0 || self.cssViewportWidth <= 0.0 || viewWidth <= 0.0) {
        return @[];
    }
    CGFloat scale = viewWidth / self.cssViewportWidth;
    // Seit der Meldung gescrollt? Dann wandern alle nicht fixierten Ziele um die Differenz mit.
    CGPoint offsetNow = self.scrollView != nil ? self.scrollView.contentOffset : self.contentOffsetAtReport;
    CGFloat shiftX = self.contentOffsetAtReport.x - offsetNow.x;
    CGFloat shiftY = self.contentOffsetAtReport.y - offsetNow.y;

    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:self.rawTargets.count];
    for (NSArray<NSNumber *> *entry in self.rawTargets) {
        BOOL fixed = entry[4].boolValue;
        CGRect rect = CGRectMake(entry[0].doubleValue * scale + (fixed ? 0.0 : shiftX),
                                 entry[1].doubleValue * scale + (fixed ? 0.0 : shiftY),
                                 entry[2].doubleValue * scale,
                                 entry[3].doubleValue * scale);
        [rects addObject:[NSValue valueWithCGRect:rect]];
    }
    return rects;
}

@end
