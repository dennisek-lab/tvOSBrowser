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

/// Player-Brücke: läuft in **allen** Frames (document-start), möglichst in einer eigenen Content World, und
/// erreicht so auch Player in fremden iframes (Vimeo, Dailymotion, YouTube-Embeds, Mediatheken) und in
/// Shadow DOM. Ein Frame meldet seinem Elternframe, ob er ein Video (v), ein laufendes Video (p) oder nur einen
/// Play-Knopf (b) hat; der Hauptframe markiert solche iframes mit `data-browser-player` (1 = Player, 2 = läuft),
/// damit das Zielskript sie als Video meldet. Befehle gehen per `postMessage` mit geheimem Kennwort abwärts.
/// `window.__bpb` (nur in der Brückenwelt sichtbar):
/// - `cmd(c, x, y, strict)`: Videobefehl (toggle, play, pause, seek:S, seekto:S) am Punkt (CSS-Pixel), sonst am
///   laufenden Video; strict = nur am Punkt oder an einem laufenden Video (sonst auch einziges/größtes Video).
///   Ergebnis: play, pause, seek, click (Play-Knopf des Players geklickt), frame (an iframe weitergereicht), none.
/// - `click(x, y)`: Klick in fremdes iframe bzw. Shadow DOM; liefert `page`, wenn das Ziel im Hauptdokument
///   (oder einem iframe gleicher Herkunft) liegt, dann klickt weiter der bisherige Weg.
/// - `href(url, c)`: Befehl an den Frame mit dieser Adresse (Übergabe an den nativen Player, Rückkehr).
/// Ohne eigene Content World (isolated = NO) sind Klicks in fremde Frames gesperrt: Das Kennwort wäre dann für
/// die Seite lesbar, und eine Seite könnte damit in eingebettete fremde Inhalte klicken.
static NSString *BrowserPlayerBridgeScript(NSString *token, BOOL isolated) {
    NSString *body = @"(function(){"
    "if (window.__bpb) { return; }"
    "var K='__TOKEN__', ISO=__ISO__, B={}, lastPlayed=null, lastState='', timer=0;"
    "try { Object.defineProperty(window,'__bpb',{value:B,configurable:false,enumerable:false,writable:false}); } catch(e) { window.__bpb=B; }"
    "var PLAY=/(^|[^a-z])(play|abspielen|wiedergabe|wiedergeben|starten|ansehen|watch|lire|lecture|reproducir|riproduci)([^a-z]|$)|play-?btn|play-?button|playbutton|big-?play|play-?icon|playicon|ytp-large-play|jw-icon-display|jw-display-icon|vjs-big-play|vp-big-play|hugeplaybacktoggle|playback-?toggle|play-?pause|playpause/;"
    "var NOPLAY=/playlist|autoplay|playback-?rate|playback-?speed|replay|next|weiter|naechst|nächst|trailer|vorschau/;"
    "var BTN='button,[role=button],a,[class*=play i],[aria-label*=play i],[aria-label*=abspielen i],[title*=play i],[title*=abspielen i],[data-testid*=play i]';"
    "function up(el){ if (!el) { return null; } if (el.parentElement) { return el.parentElement; } var r=el.getRootNode&&el.getRootNode(); return (r&&r.host)||null; }"
    "function win(el){ return (el&&el.ownerDocument&&el.ownerDocument.defaultView)||window; }"
    "function frames(doc){ return [].slice.call((doc||document).querySelectorAll('iframe,frame')); }"
    "function frameOf(src){ var fs=frames(document); for (var i=0;i<fs.length;i++){ try { if (fs[i].contentWindow===src) { return fs[i]; } } catch(e) {} } return null; }"
    "function vis(el){ var r=el.getBoundingClientRect(), w=win(el); if (r.width<2||r.height<2||r.bottom<=0||r.right<=0||r.top>=w.innerHeight||r.left>=w.innerWidth) { return null; }"
        "var s=w.getComputedStyle(el); if (s.visibility==='hidden'||s.display==='none'||parseFloat(s.opacity)<0.05) { return null; } return r; }"
    "function inside(r,x,y){ return r && x>=r.left && x<=r.right && y>=r.top && y<=r.bottom; }"
    // Videos samt offener Shadow Roots.
    "function vids(root,out,d){ out=out||[]; d=d||0; if (!root||d>6) { return out; } var a=root.querySelectorAll('video'), i; for (i=0;i<a.length;i++){ out.push(a[i]); }"
        "var all=root.querySelectorAll('*'); if (all.length<30000) { for (i=0;i<all.length;i++){ if (all[i].shadowRoot) { vids(all[i].shadowRoot,out,d+1); } } } return out; }"
    // Element am Punkt: steigt in offene Shadow Roots und iframes gleicher Herkunft ab; bei fremden iframes
    // endet es dort und liefert die Koordinaten im Frame.
    "function hit(x,y){"
        "var doc=document, el=doc.elementFromPoint(x,y), g=0, sh=false;"
        "while (el && g++<40) {"
            "var sr=el.shadowRoot;"
            "if (sr && sr.elementFromPoint) { var s=sr.elementFromPoint(x,y); if (s && s!==el && s.getRootNode && s.getRootNode()===sr) { el=s; sh=true; continue; } }"
            "if (el.tagName==='IFRAME'||el.tagName==='FRAME') {"
                "var r=el.getBoundingClientRect(), cs=win(el).getComputedStyle(el);"
                "var lx=x-r.left-el.clientLeft-(parseFloat(cs.paddingLeft)||0), ly=y-r.top-el.clientTop-(parseFloat(cs.paddingTop)||0);"
                "var d=null; try { d=el.contentDocument; } catch(e) {}"
                "if (d && d.elementFromPoint) { var f=d.elementFromPoint(lx,ly); if (f) { el=f; x=lx; y=ly; doc=d; continue; } return {el:el,x:x,y:y,doc:doc,sh:sh}; }"
                "return {el:el,x:lx,y:ly,doc:doc,frame:el,sh:sh};"
            "}"
            "break;"
        "}"
        "return el ? {el:el,x:x,y:y,doc:doc,sh:sh} : null;"
    "}"
    "function label(el){ var g=function(n){ return (el.getAttribute&&el.getAttribute(n))||''; };"
        "var t=(el.childElementCount<4 ? (el.textContent||'') : '').trim(); if (t.length>24) { t=''; }"
        "var c=typeof el.className==='string' ? el.className : g('class');"
        "return [g('aria-label'),g('title'),g('data-testid'),g('data-plyr'),el.id||'',c,t].join(' ').toLowerCase(); }"
    "function playish(el){ if (!el||el.nodeType!==1) { return false; } var l=label(el); return PLAY.test(l) && !NOPLAY.test(l); }"
    // Play-Knopf eines Players: in der Ahnenkette des Ziels, sonst im Player-Behälter (höchstens 1,6-fache Fläche
    // des Bezugsrechtecks), sichtbar und über dem Bezug.
    "function playButtonNear(el,ref){"
        "for (var n=el, i=0; n && i<8; n=up(n), i++){ if (playish(n) && vis(n)) { return n; } }"
        "var rr=ref||(el&&el.getBoundingClientRect()); if (!rr||rr.width<120||rr.height<68) { return null; }"
        "var c=el, best=null, ba=0;"
        "for (var k=0; c && k<8; k++){"
            "var p=up(c); if (!p||p===document.body||p===document.documentElement) { break; }"
            "var pr=p.getBoundingClientRect(); if (pr.width*pr.height>rr.width*rr.height*1.6+1) { break; } c=p;"
        "}"
        "if (!c||!c.querySelectorAll) { return null; }"
        "var roots=[c], q, j; for (q=c.querySelectorAll('*'), j=0; j<q.length && roots.length<20; j++){ if (q[j].shadowRoot) { roots.push(q[j].shadowRoot); } }"
        "for (var m=0;m<roots.length;m++){ var bs=roots[m].querySelectorAll(BTN);"
            "for (j=0;j<bs.length;j++){ var b=bs[j]; if (!playish(b)) { continue; } var r=vis(b); if (!r||r.width<16||r.height<16) { continue; }"
                "if (r.right<rr.left||r.left>rr.right||r.bottom<rr.top||r.top>rr.bottom) { continue; }"
                "var a=r.width*r.height; if (a>ba) { ba=a; best=b; } } }"
        "return best;"
    "}"
    "function fire(el,x,y){"
        "var w=win(el), o={bubbles:true,cancelable:true,composed:true,view:w,clientX:x,clientY:y,screenX:x,screenY:y,button:0,buttons:1,detail:1,pointerId:1,pointerType:'mouse',isPrimary:true,width:1,height:1,pressure:0.5};"
        "function ev(t,C){ try { var Ctor=w[C]||window[C]; if (Ctor) { el.dispatchEvent(new Ctor(t,o)); return; } } catch(e) {}"
            "try { var m=el.ownerDocument.createEvent('MouseEvents'); m.initMouseEvent(t,true,true,w,1,x,y,x,y,false,false,false,false,0,null); el.dispatchEvent(m); } catch(e2) {} }"
        "if (x<0) { var r=el.getBoundingClientRect(); x=r.left+r.width/2; y=r.top+r.height/2; o.clientX=o.screenX=x; o.clientY=o.screenY=y; }"
        "ev('pointerover','PointerEvent'); ev('mouseover','MouseEvent'); ev('pointerdown','PointerEvent'); ev('mousedown','MouseEvent');"
        "try { var f=el.closest&&el.closest('a,button,input,select,textarea,[tabindex]'); if (f&&f.focus) { f.focus({preventScroll:true}); } } catch(e) {}"
        "o.buttons=0; ev('pointerup','PointerEvent'); ev('mouseup','MouseEvent');"
        "if (typeof el.click==='function') { el.click(); } else { ev('click','MouseEvent'); }"
    "}"
    "function send(fr,msg){ msg.__bpbCmd=K; try { fr.contentWindow.postMessage(msg,'*'); return true; } catch(e) { return false; } }"
    "function playing(v){ return !v.paused && !v.ended; }"
    "function big(v){ var r=v.getBoundingClientRect(); return r.width>=200 && r.height>=112; }"
    "function noSource(v){ return v.networkState===3 || (!v.currentSrc && !v.src && !v.querySelector('source')); }"
    "function act(v,c){"
        "if (c==='toggle') { c=(v.paused||v.ended) ? 'play' : 'pause'; }"
        "if (c==='play') {"
            // Noch ohne Quelle (Player lädt erst beim Klick) oder Seite verweigert play(): Knopf des Players.
            "var b=noSource(v) ? playButtonNear(v,v.getBoundingClientRect()) : null; if (b) { fire(b,-1,-1); return 'click'; }"
            "try { var p=v.play(); if (p&&p.catch) { p.catch(function(e){ B.lastError=String(e); var b2=playButtonNear(v,v.getBoundingClientRect()); if (b2) { fire(b2,-1,-1); } }); } } catch(e) { B.lastError=String(e); }"
            "return 'play';"
        "}"
        "if (c==='pause') { v.pause(); return 'pause'; }"
        "if (c.indexOf('seek:')===0) { var dd=parseFloat(c.slice(5)); if (isFinite(dd)) { v.currentTime=Math.max(0,Math.min(isFinite(v.duration)?v.duration:1e9,v.currentTime+dd)); } return 'seek'; }"
        "if (c.indexOf('seekto:')===0) { var s=parseFloat(c.slice(7)); if (isFinite(s)) { v.currentTime=Math.max(0,s); } return 'seek'; }"
        "return 'none';"
    "}"
    "function videoAt(doc,x,y){ var vs=vids(doc), best=null, ba=1e12; for (var i=0;i<vs.length;i++){ var r=vs[i].getBoundingClientRect(); if (inside(r,x,y) && r.width*r.height<ba && r.width>=40) { ba=r.width*r.height; best=vs[i]; } } return best; }"
    "function frameOK(fr,strict){ var s=fr.__bps; if (s) { return !!(s.v||s.b); } if (strict) { return false; } var r=fr.getBoundingClientRect(); return r.width>=300 && r.height>=150; }"
    "B.cmd=function(c,x,y,strict){"
        "c=String(c||'toggle'); var h=(x>=0&&y>=0) ? hit(x,y) : null;"
        "if (h && h.frame) { if (frameOK(h.frame,strict) && send(h.frame,{op:'cmd',c:c,x:h.x,y:h.y,s:strict?1:0})) { return 'frame'; } h=null; }"
        "if (h) {"
            "var v=videoAt(h.doc,h.x,h.y); if (v) { return act(v,c); }"
            "if (c==='toggle'||c==='play') { var b=playButtonNear(h.el,null); if (b) { fire(b,-1,-1); return 'click'; } }"
        "}"
        "var vs=vids(document), i, fs=frames(document);"
        "for (i=0;i<vs.length;i++){ if (playing(vs[i])) { return act(vs[i],c); } }"
        "for (i=0;i<fs.length;i++){ if (fs[i].__bps && fs[i].__bps.p && send(fs[i],{op:'cmd',c:c,x:-1,y:-1,s:1})) { return 'frame'; } }"
        "if (strict) { return 'none'; }"
        "if (lastPlayed && lastPlayed.isConnected) { return act(lastPlayed,c); }"
        "var best=null, ba=0; for (i=0;i<vs.length;i++){ var r=vis(vs[i]); if (r && r.width*r.height>ba) { ba=r.width*r.height; best=vs[i]; } }"
        "if (best) { return act(best,c); }"
        "var bf=null; ba=0; for (i=0;i<fs.length;i++){ var q=fs[i].__bps; var fr=vis(fs[i]); if (q && (q.v||q.b) && fr && fr.width*fr.height>ba) { ba=fr.width*fr.height; bf=fs[i]; } }"
        "if (bf && send(bf,{op:'cmd',c:c,x:-1,y:-1,s:0})) { return 'frame'; }"
        "if ((c==='toggle'||c==='play') && x<0) { var pb=null; ba=0; var bs=document.querySelectorAll(BTN); for (i=0;i<bs.length;i++){ var br=playish(bs[i]) && vis(bs[i]); if (br && br.width*br.height>ba && br.width>=32) { ba=br.width*br.height; pb=bs[i]; } } if (pb) { fire(pb,-1,-1); return 'click'; } }"
        "return 'none';"
    "};"
    "B.click=function(x,y){"
        "var h=hit(x,y); if (!h) { return 'none'; }"
        "if (h.frame) { if (!ISO) { return 'noiso'; } return send(h.frame,{op:'click',x:h.x,y:h.y}) ? 'frame' : 'none'; }"
        "if (window===top && !h.sh) { return 'page'; }"
        "fire(h.el,h.x,h.y); return h.sh ? 'shadow' : 'click';"
    "};"
    "B.href=function(u,c){ var r='none'; if (location.href===u) { r=B.cmd(c,-1,-1,false); } var fs=frames(document); for (var i=0;i<fs.length;i++){ send(fs[i],{op:'href',u:u,c:c}); } return r; };"
    // Zustand für den Elternframe bzw. die Markierung der iframes im Hauptframe.
    "function state(){ var vs=vids(document), v=0, p=0, b=0, i;"
        "for (i=0;i<vs.length;i++){ if (big(vs[i])) { v=1; if (playing(vs[i])) { p=1; } } }"
        "var fs=frames(document); for (i=0;i<fs.length;i++){ var s=fs[i].__bps; if (s) { v=v||s.v; p=p||s.p; b=b||s.b; } }"
        "if (!v && !b && window!==top) { var bs=document.querySelectorAll(BTN); for (i=0;i<bs.length && i<400;i++){ var r=playish(bs[i]) && vis(bs[i]); if (r && r.width>=32 && r.height>=32) { b=1; break; } } }"
        "return {v:v?1:0,p:p?1:0,b:b?1:0}; }"
    "function mark(){ var fs=frames(document); for (var i=0;i<fs.length;i++){ var s=fs[i].__bps, val=s&&(s.v||s.b) ? (s.p?'2':'1') : '';"
        "if ((fs[i].getAttribute('data-browser-player')||'')!==val) { if (val) { fs[i].setAttribute('data-browser-player',val); } else { fs[i].removeAttribute('data-browser-player'); } } } }"
    "function update(){ timer=0; if (window===top) { mark(); return; } var s=state(), k=JSON.stringify(s); if (k===lastState) { return; } lastState=k; try { parent.postMessage({__bpbState:s},'*'); } catch(e) {} }"
    "function schedule(ms){ if (!timer) { timer=setTimeout(update,ms||250); } }"
    "addEventListener('message',function(e){"
        "var d=e.data; if (!d||typeof d!=='object') { return; }"
        "if (d.__bpbState) { var fr=frameOf(e.source); if (fr) { fr.__bps=d.__bpbState; schedule(100); } return; }"
        "if (d.__bpbCmd!==K) { return; }"
        "try { e.stopImmediatePropagation(); } catch(x) {}"
        "if (d.op==='cmd') { B.cmd(d.c,d.x,d.y,!!d.s); }"
        "else if (d.op==='click' && ISO) { B.click(d.x,d.y); }"
        "else if (d.op==='href') { B.href(d.u,d.c); }"
        "schedule(300);"
    "},true);"
    "['play','playing','pause','ended','loadedmetadata','emptied'].forEach(function(n){ document.addEventListener(n,function(e){ if (e.target&&e.target.tagName==='VIDEO') { if (n==='play') { lastPlayed=e.target; } schedule(200); } },true); });"
    "addEventListener('DOMContentLoaded',function(){ schedule(50); });"
    "addEventListener('load',function(){ schedule(50); [1000,3000,6000,12000].forEach(function(t){ setTimeout(function(){ schedule(10); },t); }); });"
    "})();";
    body = [body stringByReplacingOccurrencesOfString:@"__TOKEN__" withString:token];
    return [body stringByReplacingOccurrencesOfString:@"__ISO__" withString:isolated ? @"1" : @"0"];
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
        // Player in iframes (von der Player-Brücke markiert: 1 = Player, 2 = läuft) zählen wie Videos.
        "var pf=document.querySelectorAll('iframe[data-browser-player],frame[data-browser-player]');"
        "for (var pi=0; pi<pf.length && vids.length<20; pi++){"
            "var f=pf[pi], fr=f.getBoundingClientRect(), fp=f.getAttribute('data-browser-player')==='2';"
            "if (fp) { playing=true; }"
            "if (fr.width<120||fr.height<80||fr.bottom<0||fr.right<0||fr.top>innerHeight||fr.left>innerWidth) { continue; }"
            "vids.push([Math.round(fr.left),Math.round(fr.top),Math.round(fr.width),Math.round(fr.height),fixedLike(f),fp?1:0]);"
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
    "try { new MutationObserver(function(){ schedule(350); }).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['class','style','hidden','aria-hidden','disabled','data-browser-player']}); } catch(e) {}"
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

#pragma mark - Player-Brücke

/// Kennwort für Befehle zwischen den Brückenskripten der Frames, je Prozessstart neu. In der eigenen Content World
/// kann die Seite es nicht lesen, also auch keine Klicks in fremde eingebettete Inhalte auslösen.
static NSString *BrowserPlayerBridgeToken(void) {
    static NSString *token;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint8_t bytes[16];
        arc4random_buf(bytes, sizeof(bytes));
        NSMutableString *hex = [NSMutableString stringWithCapacity:32];
        for (size_t i = 0; i < sizeof(bytes); i++) {
            [hex appendFormat:@"%02x", bytes[i]];
        }
        token = [hex copy];
    });
    return token;
}

+ (id)playerBridgeContentWorld {
    static id world;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class worldClass = NSClassFromString(@"WKContentWorld");
        Class scriptClass = NSClassFromString(@"WKUserScript");
        Class webViewClass = NSClassFromString(@"WKWebView");
        SEL named = NSSelectorFromString(@"worldWithName:");
        BOOL supported = worldClass != Nil && [worldClass respondsToSelector:named] &&
            [scriptClass instancesRespondToSelector:NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:inContentWorld:")] &&
            [webViewClass instancesRespondToSelector:NSSelectorFromString(@"evaluateJavaScript:inFrame:inContentWorld:completionHandler:")];
        if (supported) {
            world = ((id (*)(id, SEL, id))objc_msgSend)(worldClass, named, @"BrowserPlayerBridge");
        }
        NSLog(@"[PlayerBridge] Content World %@", world != nil ? @"eigene" : @"nicht verfügbar, Seitenwelt ohne Klicks in fremde Frames");
    });
    return world;
}

static NSString *BrowserBridgeSafeArgument(NSString *value) {
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"'\\\n\r  "];
    return [[value ?: @"" componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@""];
}

+ (NSString *)playerBridgeCommandScript:(NSString *)command cssPoint:(CGPoint)point strict:(BOOL)strict {
    return [NSString stringWithFormat:@"(window.__bpb ? window.__bpb.cmd('%@',%f,%f,%@) : 'nobridge')",
            BrowserBridgeSafeArgument(command), point.x, point.y, strict ? @"true" : @"false"];
}

+ (NSString *)playerBridgeClickScriptAtCSSPoint:(CGPoint)point {
    return [NSString stringWithFormat:@"(window.__bpb ? window.__bpb.click(%f,%f) : 'nobridge')", point.x, point.y];
}

+ (NSString *)playerBridgeScriptForFrameURL:(NSString *)frameURL command:(NSString *)command {
    return [NSString stringWithFormat:@"(window.__bpb ? window.__bpb.href('%@','%@') : 'nobridge')",
            BrowserBridgeSafeArgument(frameURL), BrowserBridgeSafeArgument(command)];
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
    // Player-Brücke in allen Frames, wenn möglich in eigener Content World.
    id world = [BrowserClickTargetTracker playerBridgeContentWorld];
    SEL worldInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:inContentWorld:");
    id bridge = [scriptClass alloc];
    if (world != nil) {
        bridge = ((id (*)(id, SEL, id, NSInteger, BOOL, id))objc_msgSend)(bridge, worldInit, BrowserPlayerBridgeScript(BrowserPlayerBridgeToken(), YES), 0, NO, world);
    } else {
        bridge = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(bridge, scriptInit, BrowserPlayerBridgeScript(BrowserPlayerBridgeToken(), NO), 0, NO);
    }
    if (bridge != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, bridge);
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
