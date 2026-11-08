#import "BrowserClickTargetTracker.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const kBrowserTargetsMessageName = @"browserTargets";
static NSString * const kBrowserVideoMessageName = @"browserVideo";

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

/// Gemeinsamer Teil von Haupt- und Frame-Skript: beobachtet `fetch`/`XMLHttpRequest` und merkt HLS- und
/// DASH-Manifeste in `window.__browserManifests` ({hls, dash, all}). Erkannt an der Adresse (`.m3u8`, `.mpd`,
/// `format=m3u8|mpd`, `/manifest/dash/`) oder am Content-Type der Antwort (`mpegurl`, `dash+xml`).
/// Neue Manifeste gehen über den Rückkanal: {type:'manifest', kind:'hls'|'dash', url, top:1|0}.
static NSString *BrowserManifestObserverJS(void) {
    return @"var man=window.__browserManifests={hls:'',dash:'',all:[]};"
    "function post(m){ try { webkit.messageHandlers.browserVideo.postMessage(m); } catch(e) {} }"
    "function dir(u){ return u.split('#')[0].split('?')[0].replace(/[^\\/]*$/,''); }"
    "function kindOf(a,ct){"
        "var p=a.split('#')[0].split('?')[0].toLowerCase(), q=a.toLowerCase(); ct=(ct||'').toLowerCase();"
        "if (/\\.m3u8$/.test(p) || ct.indexOf('mpegurl')>=0 || /[?&]format=m3u8/.test(q)) { return 'hls'; }"
        "if (/\\.mpd$/.test(p) || ct.indexOf('dash+xml')>=0 || /[?&]format=mpd/.test(q) || /\\/manifest\\/dash\\//.test(p)) { return 'dash'; }"
        "return '';"
    "}"
    "function note(u,ct){"
        "try {"
            "if (!u) { return; }"
            "var a=new URL(String((u&&u.url)||u),location.href).href;"
            "if (!/^https?:/.test(a)) { return; }"
            "var k=kindOf(a,ct); if (!k || man.all.indexOf(a)>=0) { return; }"
            "man.all.push(a); if (man.all.length>20) { man.all.shift(); }"
            "if (k==='hls') {"
                // Hauptplaylist (alle Qualitäten) behalten; Teil-Playlists tragen meist chunk/media/index_N im
                // Namen oder liegen unter dem Ordner der Hauptplaylist. Eine Playlist anderswo = neuer Stream.
                "var p=a.split('#')[0].split('?')[0].toLowerCase();"
                "var variant=/(chunk|media_|segment|audio|video_|_\\d{3,4}p?|\\d{3,4}p)[^\\/]*$/.test(p);"
                "if (!man.hls || (!variant && dir(a).indexOf(dir(man.hls))!==0)) { man.hls=a; post({type:'manifest',kind:'hls',url:a,top:window===top?1:0}); }"
            "} else if (man.dash!==a) { man.dash=a; post({type:'manifest',kind:'dash',url:a,top:window===top?1:0}); }"
        "} catch(e) {}"
    "}"
    "try { var of=window.fetch; if (of) { window.fetch=function(i){ note(i); var r=of.apply(this,arguments);"
        "try { r.then(function(x){ try { note(x.url, x.headers.get('content-type')); } catch(e) {} }, function(){}); } catch(e) {}"
        "return r; }; } } catch(e) {}"
    "try { var oo=XMLHttpRequest.prototype.open; XMLHttpRequest.prototype.open=function(m,u){ note(u);"
        "try { this.addEventListener('load',function(){ try { note(this.responseURL, this.getResponseHeader('content-type')); } catch(e) {} }); } catch(e) {}"
        "return oo.apply(this,arguments); }; } catch(e) {}";
}

/// Läuft vor den Seitenskripten (Hauptframe): merkt sich HLS-/DASH-Manifeste (für MSE-Videos mit blob:-Adresse),
/// fängt Vollbildwünsche für Videos ab und meldet den Start sichtbarer Videos an die App.
/// Meldungen gehen an den Rückkanal `browserVideo`: {type:'fullscreen'|'playing', bid:Nummer} und 'manifest' (siehe oben).
static NSString *BrowserVideoHookScript(void) {
    return [NSString stringWithFormat:@"(function(){"
    "if (window.__browserVideoHook) { return; }"
    "window.__browserVideoHook=1;"
    "%@"
    "var nextId=1;"
    "function bid(v){ if (!v.__bid) { v.__bid=nextId++; } return v.__bid; }"
    "window.__browserVideoById=function(id){ var vs=document.querySelectorAll('video'); for (var i=0;i<vs.length;i++){ if (vs[i].__bid===id) { return vs[i]; } } return null; };"
    "function videoOf(el){ if (!el) { return null; } if (el.tagName==='VIDEO') { return el; } if (el===document.documentElement||el===document.body||!el.querySelector) { return null; } return el.querySelector('video'); }"
    "function intercept(el){ var v=videoOf(el); if (!v) { return false; } v.__bnoauto=true; post({type:'fullscreen',bid:bid(v)}); return true; }"
    "try {"
        "['webkitEnterFullscreen','webkitEnterFullScreen'].forEach(function(n){"
            "var o=HTMLVideoElement.prototype[n]; if (!o) { return; }"
            "HTMLVideoElement.prototype[n]=function(){ if (intercept(this)) { return; } return o.apply(this,arguments); };"
        "});"
        "['requestFullscreen','webkitRequestFullscreen','webkitRequestFullScreen'].forEach(function(n){"
            "var o=Element.prototype[n]; if (!o) { return; }"
            "Element.prototype[n]=function(){ if (intercept(this)) { return Promise.resolve(); } return o.apply(this,arguments); };"
        "});"
    "} catch(e) {}"
    "document.addEventListener('webkitbeginfullscreen',function(e){ if (e.target && e.target.tagName==='VIDEO') { try { e.target.webkitExitFullscreen(); } catch(x) {} intercept(e.target); } },true);"
    "document.addEventListener('playing',function(e){"
        "var v=e.target; if (!v || v.tagName!=='VIDEO' || v.__bnoauto) { return; }"
        "if (v.clientWidth<320 || v.clientHeight<180) { return; }"
        // Stumme Endlosschleifen und Vorschauen nicht übernehmen.
        "if (v.muted && (v.loop || v.autoplay)) { return; }"
        "v.__bnoauto=true;"
        "post({type:'playing',bid:bid(v)});"
    "},true);"
    "})();", BrowserManifestObserverJS()];
}

/// Läuft in eingebetteten Frames (nicht im Hauptframe): Manifeste wie oben, dazu Videos in Frames
/// (eingebettete Player). Meldet {type:'framevideo'|'framefullscreen', src, t, paused, hls, dash}.
/// Kein automatisches Öffnen beim Abspielen (Werbung läuft oft in Frames), nur auf Vollbildwunsch oder per Menü.
static NSString *BrowserFrameVideoScript(void) {
    return [NSString stringWithFormat:@"(function(){"
    "if (window===top || window.__browserFrameVideoHook) { return; }"
    "window.__browserFrameVideoHook=1;"
    "%@"
    "function videoOf(el){ if (!el) { return null; } if (el.tagName==='VIDEO') { return el; } if (!el.querySelector) { return null; } return el.querySelector('video'); }"
    "function info(type,v){ var s=v.currentSrc||''; return {type:type,src:/^https?:/.test(s)?s:'',t:v.currentTime||0,paused:v.paused?1:0,hls:man.hls,dash:man.dash,frame:location.href}; }"
    "function big(v){ return v.clientWidth>=200 && v.clientHeight>=112 && !(v.muted && (v.loop || v.autoplay)); }"
    "['playing','pause'].forEach(function(n){ document.addEventListener(n,function(e){ var v=e.target; if (v && v.tagName==='VIDEO' && big(v)) { post(info('framevideo',v)); } },true); });"
    "function intercept(el){ var v=videoOf(el); if (!v) { return false; } post(info('framefullscreen',v)); return true; }"
    "try {"
        "['webkitEnterFullscreen','webkitEnterFullScreen'].forEach(function(n){"
            "var o=HTMLVideoElement.prototype[n]; if (!o) { return; }"
            "HTMLVideoElement.prototype[n]=function(){ if (intercept(this)) { return; } return o.apply(this,arguments); };"
        "});"
        "['requestFullscreen','webkitRequestFullscreen','webkitRequestFullScreen'].forEach(function(n){"
            "var o=Element.prototype[n]; if (!o) { return; }"
            "Element.prototype[n]=function(){ if (intercept(this)) { return Promise.resolve(); } return o.apply(this,arguments); };"
        "});"
    "} catch(e) {}"
    "})();", BrowserManifestObserverJS()];
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
    "function rgba(c){ var m=/rgba?\\(([^)]+)\\)/.exec(c||''); if(!m){ return null; } var p=m[1].split(/[ ,\\/]+/).filter(Boolean).map(parseFloat); return [p[0],p[1],p[2],p.length>3?p[3]:1]; }"
    "function siteName(){"
        "var sel=['meta[property=\"og:site_name\"]','meta[name=\"application-name\"]','meta[name=\"apple-mobile-web-app-title\"]'];"
        "for (var i=0;i<sel.length;i++){ var m=document.querySelector(sel[i]); if (m && m.content && m.content.trim().length && m.content.length<40) { return m.content.trim(); } }"
        "return '';"
    "}"
    "function pageColor(){"
        // Wie Safari: Farbe am oberen Rand der Seite abtasten (oberstes Element mit deckendem Hintergrund).
        "var xs=[innerWidth*0.5, innerWidth*0.15, innerWidth*0.85];"
        "for (var s=0;s<xs.length;s++){"
            // Bildschirmfüllende Overlays (Cookie-Dialoge, Modals) und iframes überspringen: Sie sind nicht die Seitenfarbe.
            "var stack=document.elementsFromPoint ? document.elementsFromPoint(xs[s],2) : [document.elementFromPoint(xs[s],2)];"
            "var start=null;"
            "for (var k=0;k<stack.length;k++){ var e=stack[k]; if (!e) { continue; } if (e.tagName==='IFRAME') { continue; }"
                "var es=getComputedStyle(e); var er=e.getBoundingClientRect();"
                "if ((es.position==='fixed'||es.position==='absolute') && er.width>=innerWidth*0.9 && er.height>=innerHeight*0.8 && e!==document.body && e!==document.documentElement) { continue; }"
                "start=e; break; }"
            "for (var n=start; n; n=n.parentElement){"
                "var cs=rgba(getComputedStyle(n).backgroundColor);"
                "if (cs && cs[3]>0.5) { return cs; }"
                "if (getComputedStyle(n).backgroundImage!=='none' && n!==document.body && n!==document.documentElement) { break; }"
            "}"
        "}"
        "var meta=document.querySelector('meta[name=theme-color]:not([media]),meta[name=theme-color][media*=dark]');"
        "if (meta && meta.content){ var probe=document.createElement('i'); probe.style.color=meta.content; document.documentElement.appendChild(probe); var c=rgba(getComputedStyle(probe).color); probe.remove(); if (c && c[3]>0.5) { return c; } }"
        "var els=[document.body, document.documentElement];"
        "for (var i=0;i<els.length;i++){ if (!els[i]) { continue; } var c2=rgba(getComputedStyle(els[i]).backgroundColor); if (c2 && c2[3]>0.5) { return c2; } }"
        "return [255,255,255,1];"
    "}"
    // Knopffarbe fürs Leuchten: Hintergrund, sonst Textfarbe; Weiß, Schwarz, Grau und Durchsichtiges zählen als keine (-1).
    "function glow(s){"
        "var c=[rgba(s.backgroundColor), rgba(s.color)];"
        "for (var i=0;i<2;i++){ var q=c[i]; if (!q || q[3]<0.5) { continue; }"
            "var mx=Math.max(q[0],q[1],q[2]), mn=Math.min(q[0],q[1],q[2]);"
            "if (mx-mn<40 || mx<50) { continue; }"
            "return (Math.round(q[0])<<16)|(Math.round(q[1])<<8)|Math.round(q[2]);"
        "}"
        "return -1;"
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
            "out.push([Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height),fixedLike(el),glow(getComputedStyle(el))]);"
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
        "var bg=pageColor();"
        "var fs=!!(document.fullscreenElement||document.webkitFullscreenElement);"
        "var key=document.title+':'+bg+':'+fs+':'+innerWidth+':'+scrollX+':'+scrollY+':'+playing+':'+vids.join(';')+':'+out.join(';')+':'+JSON.stringify(m);"
        "if (key===last) { return; }"
        "last=key;"
        "try { webkit.messageHandlers.browserTargets.postMessage({ti:document.title||'',sn:siteName(),w:innerWidth,sx:scrollX,sy:scrollY,t:out,v:vids,p:playing,m:m,fs:fs,bg:bg}); } catch(e) {}"
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

/// Wie oben, für den Rückkanal `browserVideo` (Vollbildwunsch, Videostart).
@interface BrowserVideoMessageProxy : NSObject
@property (nonatomic, weak) BrowserClickTargetTracker *tracker;
@end

@interface BrowserClickTargetTracker ()
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *rawTargets;
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *rawVideos;
@property (nonatomic, readwrite) BOOL videoPlaying;
@property (nonatomic, readwrite, copy, nullable) NSDictionary *mediaInfo;
@property (nonatomic, readwrite) BOOL pageFullscreen;
@property (nonatomic, readwrite, copy, nullable) NSString *pageTitle;
@property (nonatomic, readwrite, copy, nullable) NSString *siteName;
@property (nonatomic, readwrite, nullable) UIColor *pageBackgroundColor;
@property (nonatomic) CGFloat cssViewportWidth;
@property (nonatomic) CGPoint contentOffsetAtReport;
- (void)handleMessageBody:(id)body;
- (void)handleVideoMessageBody:(id)body;
@end

@implementation BrowserClickTargetMessageProxy
- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    (void)controller;
    id body = [message respondsToSelector:@selector(body)] ? ((id (*)(id, SEL))objc_msgSend)(message, @selector(body)) : nil;
    [self.tracker handleMessageBody:body];
}
@end

@implementation BrowserVideoMessageProxy
- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    (void)controller;
    id body = [message respondsToSelector:@selector(body)] ? ((id (*)(id, SEL))objc_msgSend)(message, @selector(body)) : nil;
    [self.tracker handleVideoMessageBody:body];
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

    id script = [scriptClass alloc];
    // injectionTime 1 = WKUserScriptInjectionTimeAtDocumentEnd, nur Hauptframe.
    script = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(script, scriptInit, BrowserClickTargetScript(), 1, YES);
    if (script != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, script);
    }
    if (protocol != NULL && !class_conformsToProtocol(BrowserVideoMessageProxy.class, protocol)) {
        class_addProtocol(BrowserVideoMessageProxy.class, protocol);
    }
    BrowserVideoMessageProxy *videoProxy = [BrowserVideoMessageProxy new];
    videoProxy.tracker = self;
    ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addHandler, videoProxy, kBrowserVideoMessageName);
    id videoHook = [scriptClass alloc];
    videoHook = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(videoHook, scriptInit, BrowserVideoHookScript(), 0, YES);
    if (videoHook != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, videoHook);
    }
    // Eingebettete Frames (forMainFrameOnly NO; das Skript selbst überspringt den Hauptframe).
    id frameHook = [scriptClass alloc];
    frameHook = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(frameHook, scriptInit, BrowserFrameVideoScript(), 0, NO);
    if (frameHook != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, frameHook);
    }
    id hook = [scriptClass alloc];
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
    self.pageTitle = [dictionary[@"ti"] isKindOfClass:NSString.class] ? dictionary[@"ti"] : nil;
    self.siteName = [dictionary[@"sn"] isKindOfClass:NSString.class] ? dictionary[@"sn"] : nil;
    NSArray *bg = [dictionary[@"bg"] isKindOfClass:NSArray.class] ? dictionary[@"bg"] : nil;
    if (bg.count >= 3) {
        self.pageBackgroundColor = [UIColor colorWithRed:[bg[0] doubleValue] / 255.0 green:[bg[1] doubleValue] / 255.0 blue:[bg[2] doubleValue] / 255.0 alpha:1.0];
    }
    self.cssViewportWidth = [dictionary[@"w"] doubleValue];
    self.contentOffsetAtReport = self.scrollView != nil ? self.scrollView.contentOffset : CGPointZero;
    if (self.targetsDidChange != nil) {
        self.targetsDidChange();
    }
}

- (void)handleVideoMessageBody:(id)body {
    if (![body isKindOfClass:NSDictionary.class] || self.videoEventHandler == nil) {
        return;
    }
    self.videoEventHandler(body);
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

- (UIColor *)glowColorAtViewPoint:(CGPoint)point viewWidth:(CGFloat)viewWidth {
    NSArray<NSValue *> *rects = [self rectsFromRaw:self.rawTargets viewWidth:viewWidth];
    NSInteger best = -1;
    CGFloat bestArea = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < rects.count; i++) {
        CGRect rect = rects[i].CGRectValue;
        CGFloat area = CGRectGetWidth(rect) * CGRectGetHeight(rect);
        if (CGRectContainsPoint(rect, point) && area < bestArea) {
            best = (NSInteger)i;
            bestArea = area;
        }
    }
    if (best < 0 || self.rawTargets[best].count < 6) {
        return nil;
    }
    NSInteger packed = self.rawTargets[best][5].integerValue;
    if (packed < 0) {
        return nil;
    }
    return [UIColor colorWithRed:((packed >> 16) & 255) / 255.0 green:((packed >> 8) & 255) / 255.0 blue:(packed & 255) / 255.0 alpha:1.0];
}

- (NSArray<NSValue *> *)videoRectsForViewWidth:(CGFloat)viewWidth {
    return [self rectsFromRaw:self.rawVideos viewWidth:viewWidth];
}

- (CGFloat)cssScaleForViewWidth:(CGFloat)viewWidth {
    return (self.cssViewportWidth > 0.0 && viewWidth > 0.0) ? viewWidth / self.cssViewportWidth : 1.0;
}

@end
