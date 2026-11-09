// Tonabgriff für Untertitel in der Webseite (Weg B, siehe docs/ERWEITERUNGEN.md, Abschnitt 10.6).
//
// Läuft als Nutzerskript in allen Frames, tut aber nichts, bis die App window.__browserWebAudio.start()
// aufruft. Dann hängt es Web Audio an das spielende bzw. größte <video>, rechnet auf 16 kHz mono Float32
// um und schickt Blöcke von ca. 0,5 s als Base64 über den Rückkanal `browserWebAudio` an die App.
//
// Nachrichten an die App (alle mit frame: 0 = Hauptframe, 1 = iframe):
//   {type:'ready', url}                                      Hauptframe geladen (App startet erneut)
//   {type:'state', state, reason, mode, inRate, ctx, [src, page, ua, sd]}   Zustand, siehe setState()
//   {type:'block', seq, n, sr, t, te, rate, rms, peak, zero, data, ts, lag}
//   {type:'time', t, paused, seeking, rate, rect:[x,y,w,h], w, h, fx, fs, ts, [sd], [src, page, ua]}
//                                                            alle 250 ms und bei Ereignissen
//   src/page/ua: Medienadresse (currentSrc), Adresse des Frames und User-Agent. Damit lädt die App den Ton selbst
//   (MP4/HLS-Vorausquelle), wenn Web Audio nichts liefert (natives HLS, fremde Herkunft, Seite nutzt Web Audio
//   selbst) – und auch sonst, weil sie dann vor der Abspielposition erkennen kann. In 'time' nur bei Änderung.
//   sd: video.getStartDate() in ms seit 1970 (Live-HLS mit PROGRAM-DATE-TIME), sonst fehlt es.
//
// Wichtig:
// - createMediaElementSource() geht pro Element nur einmal. Danach hört man das Video nur noch über den
//   AudioContext. Deshalb bleibt die Quelle für immer an ctx.destination, auch nach stop(), und der
//   AudioContext wird nie angehalten.
// - Die Quelle wird erst angelegt, wenn der AudioContext läuft, sonst wäre das Video stumm.
// - Fremde Herkunft ohne CORS, natives HLS (kein MSE) und DRM liefern nur Stille. Das wird vorab geprüft
//   und das Video dann gar nicht erst angefasst (sonst wäre es stumm). Mit force:true wird trotzdem
//   angehängt (Test der Stille-Erkennung). Ohne DRM wird das Video trotzdem beobachtet („nur Zeit“): Zeit,
//   Rechteck und Medienadresse gehen an die App, die den Ton dann selbst lädt.
(function () {
  'use strict';
  if (window.__browserWebAudio) { return; }

  var TARGET_RATE = 16000;
  var isTop = false;
  try { isTop = window.top === window; } catch (e) { isTop = false; }
  // Eigene Referenzen sichern, falls die Seite globale Funktionen später überschreibt.
  var nativeBtoa = window.btoa.bind(window);
  var fromCharCode = String.fromCharCode;
  var now = Date.now;

  var handler = null;
  function post(msg) {
    try {
      if (!handler) {
        handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browserWebAudio;
      }
      if (handler) {
        msg.frame = isTop ? 0 : 1;
        handler.postMessage(msg);
      }
    } catch (e) {}
  }

  // Tiefpass (Butterworth-Biquad, 7 kHz) gegen Aliasing, dann Mittelwert über je inRate/outRate Eingangswerte.
  // Wird unverändert auch im AudioWorklet benutzt (per toString()), deshalb ohne Bezüge nach außen.
  function makeResampler(inRate, outRate, blockLen, emit) {
    var ratio = inRate / outRate;
    var fc = Math.min(7000, outRate * 0.45);
    var w0 = 2 * Math.PI * fc / inRate, cw = Math.cos(w0), al = Math.sin(w0) / (2 * Math.SQRT1_2);
    var a0 = 1 + al;
    var b0 = (1 - cw) / 2 / a0, b1 = (1 - cw) / a0, b2 = b0, a1 = -2 * cw / a0, a2 = (1 - al) / a0;
    var x1 = 0, x2 = 0, y1 = 0, y2 = 0, acc = 0, n = 0, pos = 0;
    var out = new Float32Array(blockLen), fill = 0;
    return {
      // channels: Array von Float32Array (ein Eintrag je Kanal), len: Anzahl Werte, endTime: Kontextzeit nach dem letzten Wert.
      push: function (channels, len, endTime) {
        var cc = channels ? channels.length : 0, inv = cc > 0 ? 1 / cc : 0;
        for (var i = 0; i < len; i++) {
          var x = 0;
          for (var c = 0; c < cc; c++) { x += channels[c][i]; }
          x *= inv;
          var y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
          if (y < 1e-25 && y > -1e-25) { y = 0; }
          x2 = x1; x1 = x; y2 = y1; y1 = y;
          acc += y; n++; pos += 1;
          if (pos >= ratio) {
            pos -= ratio;
            out[fill++] = acc / n;
            acc = 0; n = 0;
            if (fill === blockLen) {
              var block = out;
              out = new Float32Array(blockLen);
              fill = 0;
              emit(block, endTime - (len - 1 - i) / inRate);
            }
          }
        }
      },
      reset: function () { x1 = x2 = y1 = y2 = acc = 0; n = 0; pos = 0; fill = 0; }
    };
  }

  var WORKLET_NAME = 'browser-web-audio-tap';
  var WORKLET_SRC = makeResampler.toString() + '\n' +
    'class BrowserWebAudioTap extends AudioWorkletProcessor {\n' +
    '  constructor(options) {\n' +
    '    super();\n' +
    '    var p = options.processorOptions, port = this.port;\n' +
    '    this.rs = makeResampler(sampleRate, p.target, p.block, function (b, end) { port.postMessage({ samples: b, end: end }, [b.buffer]); });\n' +
    '    port.onmessage = (e) => { if (e.data === "reset") { this.rs.reset(); } };\n' +
    '  }\n' +
    '  process(inputs) {\n' +
    '    var inp = inputs[0];\n' +
    '    if (inp && inp.length && inp[0].length) { this.rs.push(inp, inp[0].length, currentTime + inp[0].length / sampleRate); }\n' +
    '    return true;\n' +
    '  }\n' +
    '}\n' +
    'registerProcessor("' + WORKLET_NAME + '", BrowserWebAudioTap);\n';

  var S = {
    active: false,
    opts: { block: 0.5, silence: 4, mode: 'auto', force: false },
    ctx: null,
    mode: '',
    fallbackReason: '',
    tap: null,
    tapPending: null,
    sink: null,
    video: null,
    poll: 0,
    timer: 0,
    seq: 0,
    zeroSec: 0,
    silentReported: false,
    lastState: '',
    lastReason: '',
    gestureArmed: false,
    childSeen: 0,
    blocks: 0,
    encodeMs: 0,
    lastRms: 0,
    lastPeak: 0,
    timeOnly: false,   // Video nur beobachten (Zeit, Adresse), kein Web Audio
    sentSrc: ''        // zuletzt in 'time' gemeldete Adresse
  };
  var sources = new WeakMap();   // video -> MediaElementAudioSourceNode (nur einmal je Element möglich)
  var hooked = new WeakMap();    // video -> true (Ereignisse angehängt)
  var failed = new WeakMap();    // video -> Grund (z. B. von der Seite schon an Web Audio gehängt)

  function setState(state, reason, extra) {
    reason = reason || '';
    if (state === S.lastState && reason === S.lastReason) { return; }
    S.lastState = state;
    S.lastReason = reason;
    var m = { type: 'state', state: state, reason: reason, mode: S.mode, inRate: S.ctx ? S.ctx.sampleRate : 0, ctx: S.ctx ? S.ctx.state : 'none' };
    if (extra) { for (var k in extra) { m[k] = extra[k]; } }
    post(m);
  }

  // Adresse, Frame und User-Agent fürs Laden in der App; Startdatum bei Live-HLS.
  function mediaInfo(v, m) {
    m = m || {};
    if (!v) { return m; }
    m.src = sourceURL(v).slice(0, 4000);
    m.page = location.href.slice(0, 2000);
    m.ua = navigator.userAgent;
    var sd = startDate(v);
    if (sd) { m.sd = sd; }
    return m;
  }

  function startDate(v) {
    try {
      var d = v.getStartDate ? v.getStartDate() : null;
      var ms = d ? d.getTime() : NaN;
      return isFinite(ms) && ms > 0 ? ms : 0;
    } catch (e) { return 0; }
  }

  // Video ohne Web Audio beobachten: Zeit und Adresse melden, Ton lädt die App selbst.
  function observeOnly(v) {
    if (S.video && S.video !== v) { detachTap(); }
    hookVideo(v);
    S.video = v;
    S.timeOnly = true;
    S.retryTap = false;
    S.sentSrc = '';
    reportTime();
  }

  function visibleArea(r) {
    var w = Math.min(r.right, innerWidth) - Math.max(r.left, 0);
    var h = Math.min(r.bottom, innerHeight) - Math.max(r.top, 0);
    return w > 0 && h > 0 ? w * h : 0;
  }

  function isPlaying(v) { return !v.paused && !v.ended && v.readyState > 2; }

  // Laufendes, hörbares, sichtbar größtes Video bevorzugen.
  function pickVideo() {
    var vs = document.querySelectorAll('video'), best = null, bestScore = -1;
    for (var i = 0; i < vs.length; i++) {
      var v = vs[i];
      if (failed.has(v)) { continue; }
      var r = v.getBoundingClientRect(), area = visibleArea(r);
      if (!isPlaying(v) && (r.width < 120 || r.height < 80)) { continue; }
      var score = area + (isPlaying(v) ? 1e9 : 0) + (!v.muted && v.volume > 0 ? 5e8 : 0) + (v.currentTime > 0 ? 1e8 : 0);
      if (score > bestScore) { bestScore = score; best = v; }
    }
    return best;
  }

  function sourceURL(v) { return v.currentSrc || v.src || ''; }

  // Vorab erkennbare Gründe, die nur Stille liefern würden. Dann wird das Video nicht angefasst.
  function blockReason(v) {
    if (v.mediaKeys || v.webkitKeys) { return 'drm'; }
    var src = sourceURL(v);
    if (!S.opts.force && /^https?:/i.test(src)) {
      // Natives HLS (ohne MSE) liefert in WebKit über Web Audio nur Nullen (getestet tvOS 27.2).
      if (isHLS(src)) { return 'hls'; }
      try {
        var u = new URL(src, location.href);
        if (u.origin !== location.origin && !v.crossOrigin) { return 'cors'; }
      } catch (e) {}
    }
    return '';
  }

  function isHLS(src) { return /\.m3u8?(\?|#|$)/i.test(src); }

  function silenceReason(v) {
    if (v.muted || v.volume === 0) { return 'muted'; }
    var src = sourceURL(v);
    if (/^https?:/i.test(src)) {
      if (isHLS(src)) { return 'hls'; }
      try { if (new URL(src, location.href).origin !== location.origin && !v.crossOrigin) { return 'cors'; } } catch (e) {}
    }
    return 'silence';
  }

  function ensureContext() {
    if (S.ctx) { return S.ctx; }
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) { return null; }
    try { S.ctx = new AC(); } catch (e) { return null; }
    S.ctx.onstatechange = function () {
      if (S.ctx.state === 'running') { tick(); } else if (S.active) { setState('suspended', 'ctx:' + S.ctx.state); }
    };
    return S.ctx;
  }

  function tryResume() {
    if (!S.ctx || S.ctx.state === 'running') { return; }
    try {
      var p = S.ctx.resume();
      if (p && p.then) { p.then(function () { if (S.ctx.state === 'running') { tick(); } }, function () {}); }
    } catch (e) {}
  }

  // AudioContext ohne Nutzergeste gesperrt: beim nächsten Klick/Tastendruck/Abspielen fortsetzen.
  function armGesture() {
    if (S.gestureArmed) { return; }
    S.gestureArmed = true;
    ['pointerdown', 'mousedown', 'touchend', 'click', 'keydown'].forEach(function (n) {
      document.addEventListener(n, tryResume, true);
    });
    document.addEventListener('play', tryResume, true);
  }

  function toBase64(f32) {
    var u8 = new Uint8Array(f32.buffer, f32.byteOffset, f32.byteLength), s = '', CH = 0x8000;
    for (var i = 0; i < u8.length; i += CH) { s += fromCharCode.apply(null, u8.subarray(i, i + CH)); }
    return nativeBtoa(s);
  }

  function onBlock(samples, endCtxTime) {
    var v = S.video;
    if (!S.active || !v || !S.ctx || S.timeOnly) { return; }
    var n = samples.length, sum = 0, peak = 0;
    for (var i = 0; i < n; i++) {
      var s = samples[i];
      sum += s * s;
      if (s < 0) { s = -s; }
      if (s > peak) { peak = s; }
    }
    var rms = Math.sqrt(sum / n);
    S.lastRms = rms;
    S.lastPeak = peak;
    // Pause, Spulen, Puffern: keine Blöcke (die Kette liefert dann Nullen ohne Bezug zur Medienzeit).
    if (!isPlaying(v) || v.seeking) { return; }
    var dur = n / TARGET_RATE;
    var lag = Math.max(0, S.ctx.currentTime - endCtxTime);
    var rate = v.playbackRate || 1;
    var te = v.currentTime - lag * rate;
    var t = te - dur * rate;

    if (peak === 0) {
      S.zeroSec += dur;
      if (S.zeroSec >= S.opts.silence && !S.silentReported) {
        S.silentReported = true;
        setState('silent', silenceReason(v), mediaInfo(v, { seconds: Math.round(S.zeroSec * 10) / 10 }));
      }
    } else {
      S.zeroSec = 0;
      if (S.silentReported) { S.silentReported = false; }
      setState('running', '');
    }

    var t0 = now();
    var data = peak === 0 ? '' : toBase64(samples);
    S.encodeMs += now() - t0;
    S.blocks++;
    post({ type: 'block', seq: ++S.seq, n: n, sr: TARGET_RATE, t: t, te: te, rate: rate, rms: rms, peak: peak,
           zero: peak === 0 ? 1 : 0, data: data, ts: now(), lag: lag });
  }

  function makeScriptProcessor(why) {
    var ctx = S.ctx;
    var sp = ctx.createScriptProcessor(4096, 2, 1);
    var rs = makeResampler(ctx.sampleRate, TARGET_RATE, S.blockSamples, onBlock);
    sp.onaudioprocess = function (e) {
      var ib = e.inputBuffer, chans = [];
      for (var c = 0; c < ib.numberOfChannels; c++) { chans.push(ib.getChannelData(c)); }
      rs.push(chans, ib.length, e.playbackTime + ib.duration);
    };
    sp.connect(S.sink);
    S.tap = sp;
    S.mode = 'scriptprocessor';
    S.fallbackReason = why || '';
  }

  // Abgriffknoten einmal je Kontext anlegen (AudioWorklet, sonst ScriptProcessorNode). Ausgang über
  // eine stumme Verstärkung an destination, damit der Knoten verarbeitet wird, aber nichts doppelt klingt.
  function ensureTap(done) {
    if (S.tap) { done(); return; }
    if (S.tapPending) { S.tapPending.push(done); return; }
    S.tapPending = [done];
    var ctx = S.ctx;
    S.blockSamples = Math.max(1600, Math.round(TARGET_RATE * S.opts.block));
    S.sink = ctx.createGain();
    S.sink.gain.value = 0;
    S.sink.connect(ctx.destination);
    function finish() {
      var list = S.tapPending || [];
      S.tapPending = null;
      list.forEach(function (fn) { fn(); });
    }
    if (S.opts.mode !== 'sp' && ctx.audioWorklet && window.AudioWorkletNode) {
      var url = '';
      try { url = URL.createObjectURL(new Blob([WORKLET_SRC], { type: 'application/javascript' })); } catch (e) {}
      ctx.audioWorklet.addModule(url).then(function () {
        try {
          var node = new AudioWorkletNode(ctx, WORKLET_NAME, {
            numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1],
            channelCount: 2, channelCountMode: 'explicit', channelInterpretation: 'speakers',
            processorOptions: { block: S.blockSamples, target: TARGET_RATE }
          });
          node.port.onmessage = function (e) { onBlock(e.data.samples, e.data.end); };
          node.connect(S.sink);
          S.tap = node;
          S.mode = 'worklet';
        } catch (err) {
          makeScriptProcessor('worklet-node:' + (err && err.name));
        }
        finish();
      }, function (err) {
        makeScriptProcessor('worklet-module:' + (err && err.name));
        finish();
      });
    } else {
      makeScriptProcessor(S.opts.mode === 'sp' ? 'forced' : 'no-worklet');
      finish();
    }
  }

  function fixedLike(el) {
    for (var e = el; e && e !== document.documentElement; e = e.parentElement) {
      var p = getComputedStyle(e).position;
      if (p === 'fixed' || p === 'sticky') { return 1; }
    }
    return 0;
  }

  function fullscreen() { return !!(document.fullscreenElement || document.webkitFullscreenElement); }

  function reportTime() {
    var v = S.video;
    if (!S.active || !v) { return; }
    var r = v.getBoundingClientRect();
    var m = { type: 'time', t: v.currentTime, paused: v.paused || v.ended, seeking: v.seeking, rate: v.playbackRate,
              rect: [r.left, r.top, r.width, r.height], w: innerWidth, h: innerHeight, fx: fixedLike(v), fs: fullscreen(), ts: now() };
    var sd = startDate(v);
    if (sd) { m.sd = sd; }
    var src = sourceURL(v);
    if (src !== S.sentSrc) { S.sentSrc = src; mediaInfo(v, m); }
    sendTime(m);
  }

  // Im Hauptframe direkt an die App, in iframes an den Elternframe, der das Rechteck verschiebt.
  function sendTime(m) {
    if (isTop) { post(m); return; }
    try { window.parent.postMessage({ __browserWebAudio: 'time', m: m }, '*'); } catch (e) {}
  }

  function hookVideo(v) {
    if (hooked.has(v)) { return; }
    hooked.set(v, true);
    ['play', 'playing', 'pause', 'seeking', 'seeked', 'ratechange', 'emptied', 'ended', 'loadedmetadata'].forEach(function (n) {
      v.addEventListener(n, function () {
        if (v !== S.video) { return; }
        if (n === 'seeking' || n === 'emptied') { resetResampler(); S.zeroSec = 0; }
        reportTime();
      });
    });
    v.addEventListener('encrypted', function () { if (v === S.video) { setState('drm', 'encrypted'); } });
  }

  function resetResampler() {
    try { if (S.tap && S.tap.port) { S.tap.port.postMessage('reset'); } } catch (e) {}
  }

  function detachTap() {
    var v = S.video;
    if (!v || !S.tap) { return; }
    var src = sources.get(v);
    if (!src) { return; }
    try {
      src.disconnect(S.tap);
    } catch (e) {
      // Ältere WebKit-Versionen kennen disconnect(node) nicht: alles trennen, Lautsprecher wieder anhängen.
      try { src.disconnect(); src.connect(S.ctx.destination); } catch (e2) {}
    }
  }

  function attach(v) {
    var ctx = S.ctx, src = sources.get(v);
    if (!src) {
      try {
        src = ctx.createMediaElementSource(v);
      } catch (e) {
        // Meist: Die Seite hat das Element schon selbst an Web Audio gehängt.
        failed.set(v, 'source:' + (e && e.name));
        setState('error', 'source:' + (e && e.name), mediaInfo(v));
        observeOnly(v);
        return false;
      }
      sources.set(v, src);
      src.connect(ctx.destination);   // Ton weiter an die Lautsprecher, sonst ist das Video stumm
    }
    if (S.video && S.video !== v) { detachTap(); }
    hookVideo(v);
    if (S.video !== v || S.timeOnly) {
      S.video = v;
      S.timeOnly = false;
      S.retryTap = false;
      S.sentSrc = '';
      S.zeroSec = 0;
      S.silentReported = false;
      resetResampler();
      src.connect(S.tap);
    }
    return true;
  }

  function relay(cmd) {
    var frames = document.querySelectorAll('iframe,frame');
    for (var i = 0; i < frames.length; i++) {
      try { frames[i].contentWindow.postMessage({ __browserWebAudio: 'cmd', cmd: cmd, opts: S.opts }, '*'); } catch (e) {}
    }
    return frames.length;
  }

  function tick() {
    if (!S.active) { return; }
    var v = pickVideo();
    if (S.video && !S.video.isConnected) { S.video = null; }
    if (!v) {
      if (S.video) { return; }
      var frameCount = relay('start');
      // Nur der Hauptframe meldet „kein Video“; iframes (Werbung usw.) schweigen.
      if (isTop && now() - S.childSeen > 3000) {
        setState('novideo', frameCount > 0 ? 'iframes:' + frameCount : '');
      }
      return;
    }
    // Nicht hin- und herspringen: nur wechseln, wenn das neue Video spielt und das bisherige nicht.
    if (S.video && v !== S.video && (!isPlaying(v) || isPlaying(S.video))) { v = S.video; }
    // Schon angehängt bzw. bewusst nur beobachtet (retryTap: wartet nur auf den AudioContext, dann doch anhängen).
    if (v === S.video && ((S.tap && !S.timeOnly) || (S.timeOnly && !S.retryTap))) { return; }
    var reason = blockReason(v);
    if (reason) {
      setState('blocked', reason, mediaInfo(v));
      if (reason !== 'drm') { observeOnly(v); }
      return;
    }
    var ctx = ensureContext();
    if (!ctx) { setState('unsupported', 'no-audiocontext', mediaInfo(v)); observeOnly(v); return; }
    if (ctx.state !== 'running') {
      // Quelle erst anlegen, wenn der Kontext läuft, sonst wäre das Video stumm.
      armGesture();
      tryResume();
      setState('suspended', 'gesture', mediaInfo(v));
      // Bis zur Geste schon Zeit und Adresse melden: die App kann den Ton selbst laden.
      if (S.video !== v) { observeOnly(v); }
      S.retryTap = true;
      return;
    }
    ensureTap(function () {
      if (!S.active) { return; }
      if (attach(v)) {
        relay('stop');
        setState('running', '', mediaInfo(v, { fallback: S.fallbackReason }));
        reportTime();
      }
    });
  }

  function start(opts) {
    if (opts) {
      for (var k in opts) { if (Object.prototype.hasOwnProperty.call(opts, k)) { S.opts[k] = opts[k]; } }
    }
    S.sentSrc = '';   // Adresse erneut melden (die App vergisst sie beim Start)
    if (!S.active) {
      S.active = true;
      S.lastState = '';
      S.lastReason = '';
      S.poll = setInterval(tick, 1000);
      S.timer = setInterval(reportTime, 250);
      setState('started', '');
    }
    tick();
    return 'ok';
  }

  function stop() {
    if (!S.active) { relay('stop'); return 'idle'; }
    S.active = false;
    clearInterval(S.poll);
    clearInterval(S.timer);
    detachTap();
    S.video = null;
    S.timeOnly = false;
    S.retryTap = false;
    S.sentSrc = '';
    relay('stop');
    S.lastState = '';
    setState('stopped', '');
    return 'ok';
  }

  window.addEventListener('message', function (e) {
    var d = e.data;
    if (!d || typeof d !== 'object' || !d.__browserWebAudio) { return; }
    if (d.__browserWebAudio === 'cmd' && e.source === window.parent && !isTop) {
      if (d.cmd === 'start') { start(d.opts); } else if (d.cmd === 'stop') { stop(); }
      return;
    }
    if (d.__browserWebAudio === 'time' && d.m) {
      // Meldung eines Kindframes: Rechteck um die Lage des iframes verschieben und weiterreichen.
      var frames = document.querySelectorAll('iframe,frame');
      for (var i = 0; i < frames.length; i++) {
        if (frames[i].contentWindow !== e.source) { continue; }
        var fr = frames[i].getBoundingClientRect(), m = d.m;
        var sx = m.w > 0 && frames[i].clientWidth > 0 ? frames[i].clientWidth / m.w : 1;
        m.rect = [fr.left + frames[i].clientLeft + m.rect[0] * sx, fr.top + frames[i].clientTop + m.rect[1] * sx, m.rect[2] * sx, m.rect[3] * sx];
        m.w = innerWidth;
        m.h = innerHeight;
        m.fx = m.fx || fixedLike(frames[i]);
        m.fs = m.fs || fullscreen();
        S.childSeen = now();
        sendTime(m);
        break;
      }
    }
  });

  window.__browserWebAudio = {
    version: 1,
    start: start,
    stop: stop,
    status: function () {
      var v = S.video;
      return JSON.stringify({
        active: S.active, state: S.lastState, reason: S.lastReason, mode: S.mode, fallback: S.fallbackReason,
        ctx: S.ctx ? S.ctx.state : 'none', inRate: S.ctx ? S.ctx.sampleRate : 0,
        baseLatency: S.ctx && S.ctx.baseLatency || 0, outputLatency: S.ctx && S.ctx.outputLatency || 0,
        blocks: S.blocks, encodeMsAvg: S.blocks ? Math.round(S.encodeMs / S.blocks * 100) / 100 : 0,
        rms: S.lastRms, peak: S.lastPeak, frames: document.querySelectorAll('iframe,frame').length,
        video: v ? { t: v.currentTime, paused: v.paused, muted: v.muted, volume: v.volume, src: sourceURL(v).slice(0, 120) } : null
      });
    }
  };

  if (isTop) { post({ type: 'ready', url: location.href }); }
})();
