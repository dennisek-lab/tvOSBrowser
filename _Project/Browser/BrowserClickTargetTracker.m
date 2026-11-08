#import "BrowserClickTargetTracker.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kBrowserTargetsMessageName = @"browserTargets";

/// Läuft vor den Seitenskripten: merkt sich die Media-Session-Handler der Seite (z. B. „nächster Titel“),
/// damit die Systembefehle sie auslösen können.
static NSString *BrowserMediaSessionHookScript(void) {
    return @"(function(){"
    "if (window.__browserMediaHandlers) { return; }"
    "window.__browserMediaHandlers={};"
    "try {"
        "var ms=navigator.mediaSession; if (!ms || !ms.setActionHandler) { return; }"
        "var orig=ms.setActionHandler.bind(ms);"
        "ms.setActionHandler=function(a,h){ window.__browserMediaHandlers[a]=h||null; try { return orig(a,h); } catch(e) {} };"
    "} catch(e) {}"
    "})();";
}

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
        "var vids=[], playing=false, vs=document.querySelectorAll('video');"
        "for (var j=0; j<vs.length && vids.length<20; j++){"
            "var v=vs[j], vr=v.getBoundingClientRect();"
            "var isPlaying=!v.paused && !v.ended && v.readyState>2;"
            "if (isPlaying) { playing=true; }"
            "if (vr.width<120||vr.height<80||vr.bottom<0||vr.right<0||vr.top>innerHeight||vr.left>innerWidth) { continue; }"
            "vids.push([Math.round(vr.left),Math.round(vr.top),Math.round(vr.width),Math.round(vr.height),fixedLike(v),isPlaying?1:0]);"
        "}"
        "var m=null, av=window.__browserActiveVideo;"
        "if (!av || !av.isConnected) { av=null; for (var k=0;k<vs.length;k++){ if (!vs[k].paused) { av=vs[k]; break; } } }"
        "if (av && (av.currentTime>0 || !av.paused)) {"
            "var ms=navigator.mediaSession, md=ms&&ms.metadata, art='';"
            "try { if (md && md.artwork && md.artwork.length) { art=md.artwork[md.artwork.length-1].src||''; } } catch(e) {}"
            "var h=window.__browserMediaHandlers||{};"
            "m={title:(md&&md.title)||document.title||location.hostname,artist:(md&&md.artist)||location.hostname,album:(md&&md.album)||'',"
               "art:art,dur:isFinite(av.duration)?av.duration:0,t:av.currentTime,paused:av.paused||av.ended,rate:av.playbackRate,"
               "next:!!h.nexttrack,prev:!!h.previoustrack};"
        "}"
        // Nur echtes Element-Vollbild. Video-Vollbild kann tvOS-WebKit nicht, webkitDisplayingFullscreen bleibt nach dem Fehlversuch aber hängen.
        "var fs=!!(document.fullscreenElement||document.webkitFullscreenElement);"
        "var key=fs+':'+innerWidth+':'+scrollX+':'+scrollY+':'+playing+':'+vids.join(';')+':'+out.join(';')+':'+JSON.stringify(m);"
        "if (key===last) { return; }"
        "last=key;"
        "try { webkit.messageHandlers.browserTargets.postMessage({w:innerWidth,sx:scrollX,sy:scrollY,t:out,v:vids,p:playing,m:m,fs:fs}); } catch(e) {}"
    "}"
    "function schedule(delay){"
        "if (pending) { return; }"
        "pending=true;"
        "setTimeout(function(){ requestAnimationFrame(collect); }, delay);"
    "}"
    "window.__browserTargets={report:function(){ last=''; pending=false; collect(); }};"
    "addEventListener('scroll',function(){ schedule(150); },{passive:true,capture:true});"
    "addEventListener('resize',function(){ schedule(150); });"
    "document.addEventListener('play',function(e){ if (e.target && e.target.tagName==='VIDEO') { window.__browserActiveVideo=e.target; } },true);"
    "['play','playing','pause','ended','emptied','seeked','ratechange','durationchange','loadedmetadata'].forEach(function(n){ document.addEventListener(n,function(){ schedule(60); },true); });"
    "addEventListener('load',function(){ schedule(50); });"
    "['fullscreenchange','webkitfullscreenchange','webkitbeginfullscreen','webkitendfullscreen'].forEach(function(n){ document.addEventListener(n,function(){ schedule(30); },true); });"
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
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *rawVideos;
@property (nonatomic, readwrite) BOOL videoPlaying;
@property (nonatomic, readwrite, copy, nullable) NSDictionary *mediaInfo;
@property (nonatomic, readwrite) BOOL pageFullscreen;
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
        _rawVideos = @[];
    }
    return self;
}

+ (NSString *)videoCommandScriptWithCSSPoint:(CGPoint)point command:(NSString *)command {
    NSString *safeCommand = [[command componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"'\\\n\r"]] componentsJoinedByString:@""];
    return [NSString stringWithFormat:@"(function(x,y,cmd){"
        "var best=null, vs=document.querySelectorAll('video');"
        "for (var i=0;i<vs.length;i++){ var r=vs[i].getBoundingClientRect(); if (x>=r.left&&x<=r.right&&y>=r.top&&y<=r.bottom) { best=vs[i]; } }"
        "if (cmd.indexOf('action:')===0) { var h=(window.__browserMediaHandlers||{})[cmd.slice(7)]; if (h) { try { h({action:cmd.slice(7)}); } catch(e) {} return 'action'; } return 'none'; }"
        "if (!best) { for (var j=0;j<vs.length;j++){ if (!vs[j].paused) { best=vs[j]; break; } } }"
        "if (!best && window.__browserActiveVideo && window.__browserActiveVideo.isConnected) { best=window.__browserActiveVideo; }"
        "if (!best && vs.length===1) { best=vs[0]; }"
        "if (!best) { return 'none'; }"
        "function play(){ var p=best.play(); if (p&&p.catch) { p.catch(function(e){ window.__browserLastPlayError=String(e); }); } return 'play'; }"
        "if (cmd==='toggle') { if (best.paused) { return play(); } best.pause(); return 'pause'; }"
        "if (cmd==='play') { return play(); }"
        "if (cmd==='pause') { best.pause(); return 'pause'; }"
        "if (cmd.indexOf('seek:')===0) { var d=parseFloat(cmd.slice(5)); if (isFinite(d)) { best.currentTime=Math.max(0,Math.min((best.duration||1e9),best.currentTime+d)); } return 'seek'; }"
        "if (cmd.indexOf('seekto:')===0) { var s=parseFloat(cmd.slice(7)); if (isFinite(s)) { best.currentTime=Math.max(0,s); } return 'seek'; }"
        "return 'unknown';"
        "})(%f,%f,'%@');", point.x, point.y, safeCommand];
}

+ (NSString *)exitFullscreenScript {
    return @"(function(){"
        "try { if (document.fullscreenElement && document.exitFullscreen) { document.exitFullscreen(); return 'exit'; } } catch(e) {}"
        "try { if (document.webkitFullscreenElement && document.webkitExitFullscreen) { document.webkitExitFullscreen(); return 'webkitExit'; } } catch(e) {}"
        "var vs=document.querySelectorAll('video');"
        "for (var i=0;i<vs.length;i++){ if (vs[i].webkitDisplayingFullscreen) { vs[i].webkitExitFullscreen(); return 'video'; } }"
        "return 'none';"
        "})();";
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
    id hook = ((id (*)(id, SEL))objc_msgSend)((id)scriptClass, @selector(alloc));
    // injectionTime 0 = WKUserScriptInjectionTimeAtDocumentStart.
    hook = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(hook, scriptInit, BrowserMediaSessionHookScript(), 0, YES);
    if (hook != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, hook);
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
    NSArray *videos = [dictionary[@"v"] isKindOfClass:NSArray.class] ? dictionary[@"v"] : @[];
    NSMutableArray *validVideos = [NSMutableArray arrayWithCapacity:videos.count];
    for (id entry in videos) {
        if ([entry isKindOfClass:NSArray.class] && [entry count] >= 6) {
            [validVideos addObject:entry];
        }
    }
    self.rawVideos = validVideos;
    self.videoPlaying = [dictionary[@"p"] boolValue];
    self.mediaInfo = [dictionary[@"m"] isKindOfClass:NSDictionary.class] ? dictionary[@"m"] : nil;
    self.pageFullscreen = [dictionary[@"fs"] boolValue];
    self.cssViewportWidth = [dictionary[@"w"] doubleValue];
    self.contentOffsetAtReport = self.scrollView != nil ? self.scrollView.contentOffset : CGPointZero;
    if (self.targetsDidChange != nil) {
        self.targetsDidChange();
    }
}

- (void)reset {
    self.rawTargets = @[];
    self.rawVideos = @[];
    self.videoPlaying = NO;
    self.mediaInfo = nil;
    self.pageFullscreen = NO;
    if (self.targetsDidChange != nil) {
        self.targetsDidChange();
    }
}

- (NSArray<NSValue *> *)rectsFromRaw:(NSArray<NSArray<NSNumber *> *> *)raw viewWidth:(CGFloat)viewWidth {
    if (raw.count == 0 || self.cssViewportWidth <= 0.0 || viewWidth <= 0.0) {
        return @[];
    }
    CGFloat scale = viewWidth / self.cssViewportWidth;
    // Seit der Meldung gescrollt? Dann wandern alle nicht fixierten Ziele um die Differenz mit.
    CGPoint offsetNow = self.scrollView != nil ? self.scrollView.contentOffset : self.contentOffsetAtReport;
    CGFloat shiftX = self.contentOffsetAtReport.x - offsetNow.x;
    CGFloat shiftY = self.contentOffsetAtReport.y - offsetNow.y;

    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSArray<NSNumber *> *entry in raw) {
        BOOL fixed = entry[4].boolValue;
        CGRect rect = CGRectMake(entry[0].doubleValue * scale + (fixed ? 0.0 : shiftX),
                                 entry[1].doubleValue * scale + (fixed ? 0.0 : shiftY),
                                 entry[2].doubleValue * scale,
                                 entry[3].doubleValue * scale);
        [rects addObject:[NSValue valueWithCGRect:rect]];
    }
    return rects;
}

- (NSArray<NSValue *> *)targetRectsForViewWidth:(CGFloat)viewWidth {
    return [self rectsFromRaw:self.rawTargets viewWidth:viewWidth];
}

- (NSArray<NSValue *> *)videoRectsForViewWidth:(CGFloat)viewWidth {
    return [self rectsFromRaw:self.rawVideos viewWidth:viewWidth];
}

- (CGFloat)cssScaleForViewWidth:(CGFloat)viewWidth {
    return (self.cssViewportWidth > 0.0 && viewWidth > 0.0) ? viewWidth / self.cssViewportWidth : 1.0;
}

@end
