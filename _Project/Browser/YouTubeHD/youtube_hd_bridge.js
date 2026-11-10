// YouTube-HD-Brücke (Seitenwelt, Hauptframe, document-start). Siehe docs/ERWEITERUNGEN.md, Abschnitt 10.5.
//
// WebKit unter tvOS hat kein MediaSource. YouTube (m.youtube.com, Client MWEB) gibt dann nur das MP4 mit 360p (itag 18)
// heraus. Dieses Skript bildet MediaSource/SourceBuffer so weit nach, dass YouTubes eigener Player getrennte Spuren
// (H.264 + AAC) wählt und abruft. Dabei entschlüsselt er den n-Parameter und hängt das PO-Token an. Die erste so
// gebaute videoplayback-Adresse geht an die App, die daraus für alle Formate des Player-Response gültige Adressen
// macht und dem nativen Player eine HLS-Playlist gibt. Abgespielt wird in der Seite nichts (kein Decoder),
// die Seite sieht ein angehaltenes bzw. wartendes Video.
(function () {
    'use strict';
    if (window.__browserYouTubeHD) { return; }
    if (!/(^|\.)youtube\.com$/.test(location.hostname)) { return; }
    // Rückfall (siehe BrowserVideoPlaybackCoordinator): für dieses eine Video ohne Brücke laden, dann 360p.
    try {
        var off = sessionStorage.getItem('__browserYouTubeHDOff');
        var offMatch = /[?&]v=([\w-]{11})/.exec(location.search) || /\/(?:shorts|live|embed)\/([\w-]{11})/.exec(location.pathname);
        if (off && (off === '1' || (offMatch && offMatch[1] === off))) { return; }
        if (off) { sessionStorage.removeItem('__browserYouTubeHDOff'); }
    } catch (e) {}
    if (typeof window.MediaSource !== 'undefined' || typeof window.ManagedMediaSource !== 'undefined') { return; }

    var state = window.__browserYouTubeHD = {
        version: 1, installed: Date.now(), requests: [], typeChecks: {}, sourceBuffers: [], players: {},
        captured: null, capturedItag: '', captures: {}, events: [], appended: 0
    };
    function post(message) {
        try { window.webkit.messageHandlers.browserVideo.postMessage(message); } catch (e) {}
    }
    function note(text) {
        if (state.events.length < 80) { state.events.push(((Date.now() - state.installed) / 1000).toFixed(1) + ' ' + text); }
    }

    // ---- Formatprüfung: nur H.264 (avc1/avc3) bis 1080p und AAC, damit der Player MP4-Spuren wählt.
    function supported(type) {
        var text = String(type || '');
        var parts = text.split(';');
        var mime = parts.shift().trim().toLowerCase();
        var params = {};
        parts.forEach(function (p) {
            var i = p.indexOf('=');
            if (i < 0) { return; }
            params[p.slice(0, i).trim().toLowerCase()] = p.slice(i + 1).trim().replace(/^"|"$/g, '');
        });
        var ok = false;
        var codecs = (params.codecs || '').split(',').map(function (c) { return c.trim().toLowerCase(); }).filter(Boolean);
        if (mime === 'video/mp4') {
            ok = codecs.every(function (c) { return /^(avc1|avc3)\./.test(c) || /^mp4a\.40\./.test(c); });
        } else if (mime === 'audio/mp4') {
            ok = codecs.length === 0 || codecs.every(function (c) { return /^mp4a\.40\.(2|5|29)$/.test(c); });
        }
        if (ok) {
            if (+params.width > 1920 || +params.height > 1080 || +params.framerate > 60 || +params.channels > 2) { ok = false; }
            if (params.eotf && params.eotf !== 'bt709') { ok = false; }
            if (params.cryptoblockformat || params.experimental) { ok = false; }
        }
        if (Object.keys(state.typeChecks).length < 60) { state.typeChecks[text] = ok; }
        return ok;
    }

    // ---- Zeitbereiche (TimeRanges-Ersatz)
    function Ranges(list) { this._l = list || []; }
    Object.defineProperty(Ranges.prototype, 'length', { get: function () { return this._l.length; } });
    Ranges.prototype.start = function (i) {
        if (i < 0 || i >= this._l.length) { throw new DOMException('Index out of range', 'IndexSizeError'); }
        return this._l[i][0];
    };
    Ranges.prototype.end = function (i) {
        if (i < 0 || i >= this._l.length) { throw new DOMException('Index out of range', 'IndexSizeError'); }
        return this._l[i][1];
    };
    function addRange(list, s, e) {
        if (!(e > s)) { return list; }
        var out = [];
        var placed = false;
        list.concat([[s, e]]).sort(function (a, b) { return a[0] - b[0]; }).forEach(function (r) {
            var last = out[out.length - 1];
            if (last && r[0] <= last[1] + 0.1) { last[1] = Math.max(last[1], r[1]); } else { out.push([r[0], r[1]]); }
            placed = true;
        });
        return placed ? out : list;
    }
    function removeRange(list, s, e) {
        var out = [];
        list.forEach(function (r) {
            if (r[1] <= s || r[0] >= e) { out.push(r); return; }
            if (r[0] < s) { out.push([r[0], s]); }
            if (r[1] > e) { out.push([e, r[1]]); }
        });
        return out;
    }
    function intersect(a, b) {
        var out = [];
        a.forEach(function (x) {
            b.forEach(function (y) {
                var s = Math.max(x[0], y[0]), e = Math.min(x[1], y[1]);
                if (e > s) { out.push([s, e]); }
            });
        });
        return out;
    }

    // ---- Kleiner fMP4-Leser: Zeitskala aus moov/mdhd, Zeiten aus moof (tfdt, trun, tfhd/trex-Vorgaben).
    function u32(b, o) { return ((b[o] << 24) >>> 0) + (b[o + 1] << 16) + (b[o + 2] << 8) + b[o + 3]; }
    function u64(b, o) { return u32(b, o) * 4294967296 + u32(b, o + 4); }
    function type4(b, o) { return String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]); }
    function children(b, start, end, cb) {
        var o = start;
        while (o + 8 <= end) {
            var size = u32(b, o), t = type4(b, o + 4), h = 8;
            if (size === 1) { size = u64(b, o + 8); h = 16; } else if (size === 0) { size = end - o; }
            if (size < h || o + size > end) { return; }
            cb(t, o + h, o + size);
            o += size;
        }
    }
    function Mp4Timeline() {
        this.timescale = 0; this.trexDuration = 0; this.header = new Uint8Array(0); this.need = 0;
        this.box = null; this.boxFill = 0; this.skip = 0; this.segments = [];
    }
    Mp4Timeline.prototype.push = function (bytes) {
        var o = 0;
        while (o < bytes.length) {
            if (this.skip > 0) { var n = Math.min(this.skip, bytes.length - o); this.skip -= n; o += n; continue; }
            if (this.box) {
                var take = Math.min(this.box.length - this.boxFill, bytes.length - o);
                this.box.set(bytes.subarray(o, o + take), this.boxFill);
                this.boxFill += take; o += take;
                if (this.boxFill === this.box.length) { this.parseBox(this.box); this.box = null; }
                continue;
            }
            // Kopf sammeln (8 oder 16 Bytes).
            var needHeader = this.header.length >= 8 && u32(this.header, 0) === 1 ? 16 : 8;
            if (this.header.length < needHeader) {
                var add = Math.min(needHeader - this.header.length, bytes.length - o);
                var merged = new Uint8Array(this.header.length + add);
                merged.set(this.header, 0); merged.set(bytes.subarray(o, o + add), this.header.length);
                this.header = merged; o += add;
                if (this.header.length < 8) { continue; }
                if (u32(this.header, 0) === 1 && this.header.length < 16) { continue; }
            }
            var size = u32(this.header, 0), t = type4(this.header, 4), hl = this.header.length;
            if (size === 1) { size = u64(this.header, 8); }
            if (size < hl) { this.header = new Uint8Array(0); this.skip = bytes.length; continue; }
            if (t === 'moov' || t === 'moof') {
                this.box = new Uint8Array(size); this.box.set(this.header, 0); this.boxFill = hl;
            } else {
                this.skip = size - hl;
            }
            this.header = new Uint8Array(0);
        }
    };
    Mp4Timeline.prototype.parseBox = function (b) {
        var self = this;
        var t = type4(b, 4);
        if (t === 'moov') {
            children(b, 8, b.length, function (ct, s, e) {
                if (ct === 'trak') {
                    children(b, s, e, function (tt, ts, te) {
                        if (tt !== 'mdia') { return; }
                        children(b, ts, te, function (mt, ms) {
                            if (mt === 'mdhd') { self.timescale = b[ms] === 1 ? u32(b, ms + 20) : u32(b, ms + 12); }
                        });
                    });
                } else if (ct === 'mvex') {
                    children(b, s, e, function (xt, xs) { if (xt === 'trex') { self.trexDuration = u32(b, xs + 12); } });
                }
            });
            return;
        }
        if (t !== 'moof' || !this.timescale) { return; }
        children(b, 8, b.length, function (ct, s, e) {
            if (ct !== 'traf') { return; }
            var base = 0, defDur = self.trexDuration, total = 0;
            children(b, s, e, function (tt, ts) {
                if (tt === 'tfhd') {
                    var flags = u32(b, ts) & 0xffffff, p = ts + 8;
                    if (flags & 0x1) { p += 8; }
                    if (flags & 0x2) { p += 4; }
                    if (flags & 0x8) { defDur = u32(b, p); }
                } else if (tt === 'tfdt') {
                    base = b[ts] === 1 ? u64(b, ts + 4) : u32(b, ts + 4);
                }
            });
            children(b, s, e, function (tt, ts) {
                if (tt !== 'trun') { return; }
                var flags = u32(b, ts) & 0xffffff, count = u32(b, ts + 4), p = ts + 8;
                if (flags & 0x1) { p += 4; }
                if (flags & 0x4) { p += 4; }
                for (var i = 0; i < count; i++) {
                    var d = defDur;
                    if (flags & 0x100) { d = u32(b, p); p += 4; }
                    if (flags & 0x200) { p += 4; }
                    if (flags & 0x400) { p += 4; }
                    if (flags & 0x800) { p += 4; }
                    total += d;
                }
            });
            self.segments.push([base / self.timescale, (base + total) / self.timescale]);
        });
    };

    // ---- SourceBuffer / SourceBufferList / MediaSource
    function fire(target, type) {
        var ev = new Event(type);
        try { target.dispatchEvent(ev); } catch (e) {}
    }
    // Ereignisziel mit on<typ>-Eigenschaften wie bei den echten Klassen (event.target zeigt auf das Objekt).
    class BridgeEventTarget extends EventTarget {
        dispatchEvent(ev) {
            var r = super.dispatchEvent(ev);
            var handler = this['on' + ev.type];
            if (typeof handler === 'function') { try { handler.call(this, ev); } catch (e) { setTimeout(function () { throw e; }); } }
            return r;
        }
    }

    class SourceBufferList extends BridgeEventTarget { constructor() { super(); this._items = []; } }
    SourceBufferList.prototype._sync = function () {
        for (var i = 0; i < 8; i++) { if (i < this._items.length) { this[i] = this._items[i]; } else { delete this[i]; } }
    };
    Object.defineProperty(SourceBufferList.prototype, 'length', { get: function () { return this._items.length; } });
    SourceBufferList.prototype[Symbol.iterator] = function () { return this._items[Symbol.iterator](); };

    var sbCounter = 0;
    class SourceBuffer extends BridgeEventTarget { constructor(ms, type) {
        super();
        this._ms = ms; this._type = type; this._updating = false; this._ranges = [];
        this._tso = 0; this._aws = 0; this._awe = Infinity; this._mode = 'segments';
        this._timeline = new Mp4Timeline(); this._id = ++sbCounter; this._bytes = 0; this._appends = 0;
        this.onupdatestart = this.onupdate = this.onupdateend = this.onerror = this.onabort = null;
        state.sourceBuffers.push(this);
    } }
    Object.defineProperties(SourceBuffer.prototype, {
        updating: { get: function () { return this._updating; } },
        buffered: { get: function () { return new Ranges(this._ranges.map(function (r) { return [r[0], r[1]]; })); } },
        timestampOffset: { get: function () { return this._tso; }, set: function (v) { this._tso = +v || 0; } },
        appendWindowStart: { get: function () { return this._aws; }, set: function (v) { this._aws = +v || 0; } },
        appendWindowEnd: { get: function () { return this._awe; }, set: function (v) { this._awe = +v; } },
        mode: { get: function () { return this._mode; }, set: function (v) { this._mode = String(v); } },
        audioTracks: { get: function () { return []; } },
        videoTracks: { get: function () { return []; } },
        textTracks: { get: function () { return []; } }
    });
    SourceBuffer.prototype._finish = function () {
        var self = this;
        setTimeout(function () {
            self._updating = false;
            fire(self, 'update');
            fire(self, 'updateend');
            self._ms._changed();
        }, 0);
    };
    SourceBuffer.prototype.appendBuffer = function (data) {
        if (this._updating) { throw new DOMException('SourceBuffer is updating', 'InvalidStateError'); }
        if (this._ms.readyState === 'closed') { throw new DOMException('MediaSource closed', 'InvalidStateError'); }
        var bytes = data instanceof ArrayBuffer ? new Uint8Array(data) :
            new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
        this._updating = true;
        if (this._ms.readyState === 'ended') { this._ms._setState('open'); }
        fire(this, 'updatestart');
        var before = this._timeline.segments.length;
        try { this._timeline.push(bytes); } catch (e) { note('parse ' + e); }
        for (var i = before; i < this._timeline.segments.length; i++) {
            var seg = this._timeline.segments[i];
            var s = Math.max(seg[0] + this._tso, this._aws), e = Math.min(seg[1] + this._tso, this._awe);
            this._ranges = addRange(this._ranges, s, e);
        }
        this._bytes += bytes.length; this._appends += 1; state.appended += bytes.length;
        this._finish();
    };
    SourceBuffer.prototype.appendBufferAsync = function (data) {
        var self = this;
        return new Promise(function (resolve) { self.appendBuffer(data); self.addEventListener('updateend', function h() { self.removeEventListener('updateend', h); resolve(); }); });
    };
    SourceBuffer.prototype.remove = function (start, end) {
        if (this._updating) { throw new DOMException('SourceBuffer is updating', 'InvalidStateError'); }
        this._updating = true;
        fire(this, 'updatestart');
        this._ranges = removeRange(this._ranges, +start, +end);
        this._finish();
    };
    SourceBuffer.prototype.abort = function () {
        if (this._updating) { this._updating = false; fire(this, 'abort'); fire(this, 'updateend'); }
        this._timeline.header = new Uint8Array(0); this._timeline.box = null; this._timeline.skip = 0;
    };
    SourceBuffer.prototype.changeType = function (type) {
        if (!supported(type)) { throw new DOMException('Type not supported', 'NotSupportedError'); }
        this._type = type;
    };

    var objectURLs = {};
    class MediaSource extends BridgeEventTarget { constructor() {
        super();
        this._state = 'closed'; this._duration = NaN; this._video = null;
        this._list = new SourceBufferList(); this._active = new SourceBufferList();
        this.onsourceopen = this.onsourceended = this.onsourceclose = null;
        state.mediaSource = this;
        note('MediaSource neu');
    } }
    MediaSource.isTypeSupported = supported;
    Object.defineProperties(MediaSource.prototype, {
        readyState: { get: function () { return this._state; } },
        sourceBuffers: { get: function () { return this._list; } },
        activeSourceBuffers: { get: function () { return this._active; } },
        duration: {
            get: function () { return this._state === 'closed' ? NaN : this._duration; },
            set: function (v) {
                if (this._state !== 'open') { throw new DOMException('MediaSource not open', 'InvalidStateError'); }
                this._duration = +v;
                if (this._video) { fire(this._video, 'durationchange'); }
            }
        }
    });
    MediaSource.prototype._setState = function (s) {
        this._state = s;
        fire(this, s === 'open' ? 'sourceopen' : (s === 'ended' ? 'sourceended' : 'sourceclose'));
    };
    MediaSource.prototype.addSourceBuffer = function (type) {
        if (!supported(type)) { throw new DOMException('Type not supported: ' + type, 'NotSupportedError'); }
        if (this._state !== 'open') { throw new DOMException('MediaSource not open', 'InvalidStateError'); }
        var sb = new SourceBuffer(this, type);
        this._list._items.push(sb); this._list._sync(); this._active._items.push(sb); this._active._sync();
        fire(this._list, 'addsourcebuffer'); fire(this._active, 'addsourcebuffer');
        note('addSourceBuffer ' + type);
        return sb;
    };
    MediaSource.prototype.removeSourceBuffer = function (sb) {
        [this._list, this._active].forEach(function (l) {
            var i = l._items.indexOf(sb);
            if (i >= 0) { l._items.splice(i, 1); l._sync(); fire(l, 'removesourcebuffer'); }
        });
    };
    MediaSource.prototype.endOfStream = function () {
        if (this._state !== 'open') { throw new DOMException('MediaSource not open', 'InvalidStateError'); }
        var end = 0;
        this._list._items.forEach(function (sb) { sb._ranges.forEach(function (r) { end = Math.max(end, r[1]); }); });
        if (end > 0) { this._duration = end; }
        this._setState('ended');
        this._changed();
    };
    MediaSource.prototype.setLiveSeekableRange = function () {};
    MediaSource.prototype.clearLiveSeekableRange = function () {};
    MediaSource.prototype._buffered = function () {
        var items = this._active._items;
        if (items.length === 0) { return []; }
        var r = items[0]._ranges;
        for (var i = 1; i < items.length; i++) { r = intersect(r, items[i]._ranges); }
        return r;
    };
    MediaSource.prototype._changed = function () { if (this._video && this._video.__bythd) { this._video.__bythd.update(); } };

    // ---- Video-Element mit Ersatz-Quelle: Zustand selbst führen, die echte Wiedergabe bleibt leer.
    function Session(video, ms, url) {
        this.video = video; this.ms = ms; this.url = url; this.time = 0; this.paused = true; this.seeking = false;
        this.ready = 0; this.rate = 1; this.clock = 0; this.timer = null; this.ended = false;
        this.frames = 0;
    }
    Session.prototype.bufferedEnd = function (t) {
        var r = this.ms._buffered();
        for (var i = 0; i < r.length; i++) { if (t >= r[i][0] - 0.2 && t < r[i][1]) { return r[i][1]; } }
        return -1;
    };
    Session.prototype.setReady = function (n) {
        var v = this.video, old = this.ready;
        if (n === old) { return; }
        this.ready = n;
        if (old < 1 && n >= 1) { fire(v, 'loadedmetadata'); }
        if (old < 2 && n >= 2) { fire(v, 'loadeddata'); }
        if (old < 3 && n >= 3) { fire(v, 'canplay'); if (!this.paused) { fire(v, 'playing'); } }
        if (old < 4 && n >= 4) { fire(v, 'canplaythrough'); }
        if (old >= 3 && n < 3 && !this.paused) { fire(v, 'waiting'); }
    };
    Session.prototype.update = function () {
        var hasInit = this.ms._active._items.length > 0 && this.ms._active._items.every(function (sb) { return sb._timeline.timescale > 0; });
        if (!hasInit) { this.setReady(0); return; }
        var end = this.bufferedEnd(this.time);
        if (end < 0) { this.setReady(1); return; }
        if (this.seeking) { this.seeking = false; fire(this.video, 'seeked'); }
        this.setReady(end - this.time > 3 || this.ms._state === 'ended' ? 4 : 3);
    };
    Session.prototype.tick = function () {
        var now = performance.now();
        if (!this.paused && this.ready >= 3 && !this.seeking) {
            var next = this.time + (now - this.clock) / 1000 * this.rate;
            var end = this.bufferedEnd(this.time);
            if (end >= 0 && next >= end) {
                next = end;
                var dur = this.ms._duration;
                if (this.ms._state === 'ended' && isFinite(dur) && next >= dur - 0.25) {
                    this.time = dur; this.paused = true; this.ended = true;
                    fire(this.video, 'timeupdate'); fire(this.video, 'pause'); fire(this.video, 'ended');
                    this.clock = now;
                    return;
                }
            }
            this.time = next;
            this.frames += Math.round((now - this.clock) / 1000 * 30);
            fire(this.video, 'timeupdate');
            this.update();
        }
        this.clock = now;
    };
    Session.prototype.start = function () {
        var self = this;
        if (this.timer) { return; }
        this.clock = performance.now();
        this.timer = setInterval(function () { self.tick(); }, 250);
    };
    Session.prototype.stop = function () { if (this.timer) { clearInterval(this.timer); this.timer = null; } };

    var mediaProto = HTMLMediaElement.prototype;
    var srcDescriptor = Object.getOwnPropertyDescriptor(mediaProto, 'src');
    var proto = {
        currentTime: function (s) { return { get: function () { return s.time; }, set: function (v) {
            v = +v; if (!isFinite(v)) { return; }
            s.time = Math.max(0, v); s.ended = false; s.seeking = true;
            fire(s.video, 'seeking'); fire(s.video, 'timeupdate');
            setTimeout(function () { s.update(); }, 0);
        } }; },
        duration: function (s) { return { get: function () { var d = s.ms._duration; return s.ms._state === 'closed' ? NaN : (isNaN(d) ? NaN : d); } }; },
        paused: function (s) { return { get: function () { return s.paused; } }; },
        ended: function (s) { return { get: function () { return s.ended; } }; },
        seeking: function (s) { return { get: function () { return s.seeking; } }; },
        readyState: function (s) { return { get: function () { return s.ready; } }; },
        networkState: function () { return { get: function () { return 2; } }; },
        error: function () { return { get: function () { return null; } }; },
        currentSrc: function (s) { return { get: function () { return s.url; } }; },
        buffered: function (s) { return { get: function () { return new Ranges(s.ms._buffered()); } }; },
        seekable: function (s) { return { get: function () { var d = s.ms._duration; return new Ranges(isFinite(d) && d > 0 ? [[0, d]] : []); } }; },
        played: function () { return { get: function () { return new Ranges([]); } }; },
        playbackRate: function (s) { return { get: function () { return s.rate; }, set: function (v) { s.rate = +v || 1; fire(s.video, 'ratechange'); } }; },
        play: function (s) { return { value: function () {
            if (s.paused) {
                s.paused = false; s.ended = false; s.clock = performance.now();
                fire(s.video, 'play');
                post({ type: 'youtubehd', event: 'play', page: location.href, videoId: videoIdOf(location.href) });
                if (s.ready >= 3) { fire(s.video, 'playing'); } else { fire(s.video, 'waiting'); }
            }
            return Promise.resolve();
        } }; },
        pause: function (s) { return { value: function () {
            if (!s.paused) { s.paused = true; fire(s.video, 'timeupdate'); fire(s.video, 'pause'); }
        } }; },
        load: function () { return { value: function () {} }; },
        getVideoPlaybackQuality: function (s) { return { value: function () {
            return { creationTime: performance.now(), totalVideoFrames: s.frames, droppedVideoFrames: 0, corruptedVideoFrames: 0 };
        } }; }
    };
    function attach(video, ms, url) {
        detach(video);
        var s = new Session(video, ms, url);
        video.__bythd = s;
        ms._video = video;
        Object.keys(proto).forEach(function (name) {
            var d = proto[name](s);
            d.configurable = true;
            try { Object.defineProperty(video, name, d); } catch (e) {}
        });
        try { srcDescriptor.set.call(video, ''); originalRemoveAttribute.call(video, 'src'); } catch (e) {}
        s.start();
        note('Video angehängt');
        post({ type: 'youtubehd', event: 'attach', page: location.href, videoId: videoIdOf(location.href) });
        setTimeout(function () {
            if (video.__bythd !== s) { return; }
            fire(video, 'loadstart');
            ms._setState('open');
        }, 0);
    }
    function detach(video) {
        var s = video.__bythd;
        if (!s) { return; }
        s.stop();
        if (s.ms._state !== 'closed') { s.ms._state = 'closed'; fire(s.ms, 'sourceclose'); }
        s.ms._video = null;
        Object.keys(proto).forEach(function (name) { try { delete video[name]; } catch (e) {} });
        video.__bythd = null;
        note('Video gelöst');
    }
    Object.defineProperty(mediaProto, 'src', {
        configurable: true, enumerable: true,
        get: function () { return this.__bythd ? this.__bythd.url : srcDescriptor.get.call(this); },
        set: function (value) {
            var ms = objectURLs[String(value)];
            if (ms) { attach(this, ms, String(value)); return; }
            detach(this);
            srcDescriptor.set.call(this, value);
        }
    });
    var originalSetAttribute = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (name, value) {
        if (this instanceof HTMLMediaElement && String(name).toLowerCase() === 'src' && objectURLs[String(value)]) {
            this.src = value; return;
        }
        return originalSetAttribute.apply(this, arguments);
    };
    var originalRemoveAttribute = Element.prototype.removeAttribute;
    Element.prototype.removeAttribute = function (name) {
        if (this instanceof HTMLMediaElement && String(name).toLowerCase() === 'src' && this.__bythd) { detach(this); }
        return originalRemoveAttribute.apply(this, arguments);
    };

    var originalCreate = URL.createObjectURL, originalRevoke = URL.revokeObjectURL;
    URL.createObjectURL = function (obj) {
        if (obj instanceof MediaSource) {
            var url = 'blob:' + location.origin + '/' + (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2));
            objectURLs[url] = obj;
            return url;
        }
        return originalCreate.apply(URL, arguments);
    };
    URL.revokeObjectURL = function (url) {
        if (objectURLs[String(url)]) { delete objectURLs[String(url)]; return; }
        return originalRevoke.apply(URL, arguments);
    };

    // Scharf: MediaSource & Co. sichtbar. Unscharf (Player-Response nur mit SABR, keine Formatadressen): wie ohne Brücke,
    // dann wählt YouTube das MP4 mit 360p und spielt es in der Seite.
    state.armed = false;
    function arm(on, why) {
        if (on === state.armed) { return; }
        state.armed = on;
        ['MediaSource', 'WebKitMediaSource', 'SourceBuffer', 'SourceBufferList'].forEach(function (name) {
            if (on) {
                Object.defineProperty(window, name, { configurable: true, writable: true, enumerable: false,
                    value: name.indexOf('MediaSource') >= 0 ? MediaSource : (name === 'SourceBuffer' ? SourceBuffer : SourceBufferList) });
            } else {
                try { delete window[name]; } catch (e) {}
            }
        });
        note((on ? 'scharf' : 'unscharf') + (why ? ' (' + why + ')' : ''));
        if (!on) { post({ type: 'youtubehd', event: 'disarm', reason: why || '', page: location.href, videoId: videoIdOf(location.href) }); }
    }
    arm(true, 'Start');

    // Media Capabilities: ohne MSE sagt WebKit für type 'media-source' ab. Wie für Dateien beantworten.
    try {
        var mc = navigator.mediaCapabilities;
        if (mc && mc.decodingInfo) {
            var originalDecodingInfo = mc.decodingInfo.bind(mc);
            mc.decodingInfo = function (config) {
                var c = config || {};
                var ok = (!c.video || supported(c.video.contentType)) && (!c.audio || supported(c.audio.contentType));
                if (!ok) { return Promise.resolve({ supported: false, smooth: false, powerEfficient: false }); }
                return Promise.resolve({ supported: true, smooth: true, powerEfficient: true });
            };
            state.decodingInfoWrapped = !!originalDecodingInfo;
        }
    } catch (e) {}

    // ---- SABR abschalten: Steht im Player-Response `serverAbrStreamingUrl`, streamt der Player per SABR (POST mit
    // Protobuf, Antwort im UMP-Format, keine Adresse je Format). Fehlt sie, nimmt er die Formatadressen und ruft
    // `videoplayback?itag=…&range=…` ab. Nur wenn die Formate eigene Adressen haben (MWEB), sonst bliebe nichts.
    // HLS ebenso: Nach einem Wechsel per yt-navigate bringt der Player-Response von MWEB auch `hlsManifestUrl`
    // (manifest.googlevideo.com/…/hls_variant). Den nimmt der Player unter Safari dann statt MSE, WebKit unter tvOS
    // spielt ihn nicht („Es ist ein Fehler aufgetreten“, AVFoundation -12906). Mit Formatadressen fliegt er raus.
    // Entscheidung je Video merken: Der Response zum nächsten Video kommt vor dem Adresswechsel (pushState).
    state.decisions = {};
    function pruneSABR(obj, depth) {
        if (!obj || typeof obj !== 'object' || depth > 3) { return; }
        var sd = obj.streamingData;
        if (sd && typeof sd === 'object' && (sd.serverAbrStreamingUrl || sd.hlsManifestUrl)) {
            var formats = sd.adaptiveFormats || [];
            var withURL = formats.filter(function (f) { return f && (f.url || f.signatureCipher || f.cipher); }).length;
            var vid = (obj.videoDetails && obj.videoDetails.videoId) || '';
            if (sd.licenseInfos || sd.drmParams) {
                // Mit DRM (Filme, Bezahlinhalte): Formate verschlüsselt, das HLS dazu braucht FairPlay. Nicht anfassen.
                note('DRM, Brücke hält sich raus (' + (vid || '?') + ')');
                if (vid) { state.decisions[vid] = false; }
                if (vid && vid === videoIdOf(location.href)) { arm(false, 'DRM'); }
            } else if (formats.length > 0 && withURL === formats.length) {
                var removed = [];
                if (sd.serverAbrStreamingUrl) { delete sd.serverAbrStreamingUrl; removed.push('SABR'); }
                if (sd.hlsManifestUrl) { delete sd.hlsManifestUrl; removed.push('HLS'); }
                state.prunedSABR = (state.prunedSABR || 0) + 1;
                if (vid) { state.decisions[vid] = true; }
                if (vid && vid === videoIdOf(location.href)) { arm(true, 'Formatadressen'); }
                note(removed.join('+') + '-Adresse entfernt (' + (vid || '?') + ')');
            } else if (sd.serverAbrStreamingUrl) {
                state.sabrOnly = (state.sabrOnly || 0) + 1;
                note('nur SABR, keine Formatadressen (' + (vid || '?') + ')');
                // Nur für das Video der Seite entscheiden (Werbung oder Vorschauen haben andere Kennungen).
                if (vid) { state.decisions[vid] = false; }
                if (vid && vid === videoIdOf(location.href)) { arm(false, 'nur SABR'); }
            }
        }
        if (obj.playerResponse) { pruneSABR(obj.playerResponse, depth + 1); }
        if (Array.isArray(obj)) { obj.forEach(function (o) { pruneSABR(o, depth + 1); }); }
        if (obj.response && typeof obj.response === 'object') { pruneSABR(obj.response, depth + 1); }
    }
    // Videowechsel innerhalb der Seite (yt-navigate: Klick auf ein anderes Video, Startseite → Video, nächstes Video):
    // Der Player holt den neuen Response per youtubei/v1/player und lehnt ihn unter Safari ab („Dieses Video kann in
    // deinem Browser nicht abgespielt werden“, mit hlsManifestUrl „Es ist ein Fehler aufgetreten“). Nur der erste
    // Response der Seite (ytInitialPlayerResponse) geht über MSE. Darum neu laden, sobald die Adresse ein anderes
    // Video nennt als beim Laden der Seite.
    state.pageVideoId = videoIdOf(location.href);
    function onAddressChange(why) {
        var vid = videoIdOf(location.href);
        // Shorts nicht: Dort wechselt jedes Wischen die Adresse.
        if (!vid || location.pathname !== '/watch' || vid === state.pageVideoId || state.reloading) { return; }
        state.reloading = true;
        note('Videowechsel per ' + why + ' (' + (state.pageVideoId || '-') + ' → ' + vid + '), lade neu');
        post({ type: 'youtubehd', event: 'reload', page: location.href, videoId: vid, from: state.pageVideoId || '' });
        setTimeout(function () { location.reload(); }, 60);
    }
    ['pushState', 'replaceState'].forEach(function (name) {
        var original = History.prototype[name];
        if (typeof original !== 'function') { return; }
        History.prototype[name] = function () {
            var result = original.apply(this, arguments);
            try { onAddressChange(name); } catch (e) {}
            return result;
        };
    });
    window.addEventListener('popstate', function () { onAddressChange('popstate'); });
    ['yt-navigate-start', 'yt-navigate-finish', 'state-navigateend'].forEach(function (name) {
        document.addEventListener(name, function () { onAddressChange(name); }, true);
    });
    // Falls YouTube die Adresse auf anderem Weg ändert: nachsehen.
    setInterval(function () { try { onAddressChange('Adresse'); } catch (e) {} }, 700);
    var originalParse = JSON.parse;
    JSON.parse = function () {
        var result = originalParse.apply(this, arguments);
        try { pruneSABR(result, 0); } catch (e) {}
        return result;
    };
    try {
        var originalJSON = Response.prototype.json;
        Response.prototype.json = function () {
            return originalJSON.apply(this, arguments).then(function (result) {
                try { pruneSABR(result, 0); } catch (e) {}
                return result;
            });
        };
    } catch (e) {}
    ['ytInitialPlayerResponse', 'ytInitialData'].forEach(function (name) {
        var stored;
        try {
            Object.defineProperty(window, name, {
                configurable: true, enumerable: true,
                get: function () { return stored; },
                set: function (value) { try { pruneSABR(value, 0); } catch (e) {} stored = value; }
            });
        } catch (e) {}
    });

    // ---- Abrufe beobachten: videoplayback (Medien) und youtubei/v1/player (Formatliste nach SPA-Wechsel).
    function absolute(url) { try { return new URL(String(url), location.href).href; } catch (e) { return ''; } }
    function videoIdOf(href) {
        try {
            var u = new URL(href || location.href);
            if (u.searchParams.get('v')) { return u.searchParams.get('v'); }
            var m = /\/(?:shorts|embed|live)\/([\w-]{11})/.exec(u.pathname);
            return m ? m[1] : '';
        } catch (e) { return ''; }
    }
    state.formatURLs = {};
    function cipherOnly(pr) {
        var formats = (pr && pr.streamingData && pr.streamingData.adaptiveFormats) || [];
        return formats.length > 0 && formats.every(function (f) { return !f.url && (f.signatureCipher || f.cipher); });
    }
    function cipherURL(f) {
        try { return new URLSearchParams(f.signatureCipher || f.cipher).get('url') || ''; } catch (e) { return ''; }
    }
    // Höchste Stufe bis 1080p, die der Player anbietet (setPlaybackQualityRange ruft dann dieses Format ab).
    function askForHD(why) {
        var p = playerElement();
        if (!p || !p.getAvailableQualityLevels || !p.setPlaybackQualityRange) { return ''; }
        var levels = p.getAvailableQualityLevels() || [];
        var label = ['hd1080', 'hd720', 'large'].filter(function (l) { return levels.indexOf(l) >= 0; })[0] || '';
        if (label && state.askedHD !== label + location.href) {
            state.askedHD = label + location.href;
            p.setPlaybackQualityRange(label, label);
            note('Qualität ' + label + ' angefordert (' + why + ')');
        }
        return label;
    }
    state.askForHD = askForHD;
    function onMediaRequest(url, method) {
        if (url.indexOf('/videoplayback') < 0) { return; }
        var u;
        try { u = new URL(url); } catch (e) { return; }
        var q = u.searchParams;
        var itag = q.get('itag') || '';
        var entry = { t: Date.now() - state.installed, itag: itag, method: method || 'GET', range: q.get('range') || '',
            sabr: q.get('sabr') || '', ump: q.get('ump') || '', pot: q.has('pot') ? 1 : 0, potLen: (q.get('pot') || '').length, rn: q.get('rn') || '', host: u.host };
        if (state.requests.length < 60) { state.requests.push(entry); }
        if (!itag || itag === '18') { return; }
        // Je Player-Response (googlevideo-Parameter id) die erste Adresse merken: n und pot gelten für alle Formate
        // dieses Response. Werbung hat eigene Responses (andere id).
        var id = q.get('id') || '';
        if (id) {
            // Für Formate mit signatureCipher: Adresse je Format, ohne die Angaben dieser einen Anfrage.
            var clean = new URL(url);
            ['range', 'rn', 'rbuf', 'ump', 'srfvp', 'alr', 'sabr'].forEach(function (k) { clean.searchParams.delete(k); });
            state.formatURLs[id + ':' + itag] = clean.href;
            var fk = Object.keys(state.formatURLs);
            if (fk.length > 40) { delete state.formatURLs[fk[0]]; }
        }
        if (!id) { return; }
        // Am Apple TV ruft die Seite die ersten Stücke mit einem kurzen Vorab-pot ab (16 Zeichen, BotGuard noch nicht
        // fertig), etwa eine Sekunde später mit dem echten (116). Mit dem kurzen liefert googlevideo nur den Anfang
        // (403 nach etwa 45 s). Darum das längste pot je Response behalten.
        var prev = state.captures[id];
        if (prev) {
            if (entry.potLen > (prev.potLen || 0)) {
                prev.url = url; prev.itag = itag; prev.potLen = entry.potLen; prev.at = Date.now();
                note('längeres pot (' + entry.potLen + ' Zeichen) für id ' + id);
            }
            return;
        }
        var keys = Object.keys(state.captures);
        if (keys.length >= 6) { delete state.captures[keys[0]]; }
        state.captures[id] = { url: url, itag: itag, method: entry.method, at: Date.now(), potLen: entry.potLen };
        state.captured = url; state.capturedItag = itag; state.capturedId = id;
        note('erste Medienanfrage itag=' + itag + ' ' + entry.method + ' range=' + entry.range + ' pot=' + entry.pot + ' ump=' + entry.ump);
        // Formate mit signatureCipher (häufig, etwa Musikvideos): Die Signatur entschlüsselt nur der Player, und nur
        // für die Formate, die er abruft. Darum um HD bitten: Dann ruft er das 1080p-Format ab und die Brücke sieht es.
        try { if (cipherOnly(state.playerResponse())) { askForHD('Signatur'); } } catch (e) {}
        post({ type: 'youtubehd', event: 'capture', itag: itag, method: entry.method, range: entry.range,
               ump: entry.ump, pot: entry.pot, page: location.href, videoId: videoIdOf(location.href), ms: entry.t });
    }
    function rememberPlayerResponse(json) {
        try {
            if (json && json.videoDetails && json.videoDetails.videoId && json.streamingData) {
                state.players[json.videoDetails.videoId] = json;
                var keys = Object.keys(state.players);
                if (keys.length > 4) { delete state.players[keys[0]]; }
            }
        } catch (e) {}
    }
    if (window.fetch) {
        var originalFetch = window.fetch;
        window.fetch = function (input, init) {
            var url = absolute(typeof input === 'string' || input instanceof URL ? input : (input && input.url));
            var method = (init && init.method) || (input && input.method) || 'GET';
            onMediaRequest(url, method);
            var promise = originalFetch.apply(this, arguments);
            if (url.indexOf('/youtubei/v1/player') >= 0) {
                promise.then(function (response) {
                    try { response.clone().json().then(rememberPlayerResponse, function () {}); } catch (e) {}
                }, function () {});
            }
            return promise;
        };
    }
    var xhrOpen = XMLHttpRequest.prototype.open, xhrSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
        this.__bythdURL = absolute(url); this.__bythdMethod = method;
        return xhrOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
        var url = this.__bythdURL || '';
        onMediaRequest(url, this.__bythdMethod);
        if (url.indexOf('/youtubei/v1/player') >= 0) {
            var xhr = this;
            xhr.addEventListener('load', function () {
                try { rememberPlayerResponse(typeof xhr.response === 'object' ? xhr.response : JSON.parse(xhr.responseText)); } catch (e) {}
            });
        }
        return xhrSend.apply(this, arguments);
    };

    // ---- Für die App: Adresse, Formate, Titel, Position.
    function playerElement() { return document.getElementById('movie_player') || document.querySelector('.html5-video-player'); }
    state.playerResponse = function () {
        var vid = videoIdOf(location.href);
        var p = playerElement();
        var pr = null;
        try { if (p && p.getPlayerResponse) { pr = p.getPlayerResponse(); } } catch (e) {}
        if (!(pr && pr.streamingData && pr.videoDetails)) {
            pr = state.players[vid] || null;
        }
        if (!pr && window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.videoDetails &&
            window.ytInitialPlayerResponse.videoDetails.videoId === vid) { pr = window.ytInitialPlayerResponse; }
        return pr;
    };
    state.info = function () {
        var pr = state.playerResponse();
        var p = playerElement();
        var out = { captures: state.captures, capturedItag: state.capturedItag, capturedId: state.capturedId || '',
            videoId: videoIdOf(location.href), page: location.href, formats: [], title: '', author: '', length: 0,
            live: false, t: 0, thumb: '', status: '', ua: navigator.userAgent };
        try { out.t = p && p.getCurrentTime ? p.getCurrentTime() : 0; } catch (e) {}
        if (pr) {
            var d = pr.videoDetails || {};
            out.title = d.title || ''; out.author = d.author || ''; out.length = +d.lengthSeconds || 0;
            out.live = !!(d.isLive || d.isLiveContent && pr.streamingData && pr.streamingData.hlsManifestUrl);
            var th = (d.thumbnail && d.thumbnail.thumbnails) || [];
            out.thumb = th.length ? th[th.length - 1].url : '';
            out.status = (pr.playabilityStatus && pr.playabilityStatus.status) || '';
            out.prVideoId = d.videoId || '';
            if (d.videoId) { out.videoId = d.videoId; }
            out.expires = pr.streamingData && pr.streamingData.expiresInSeconds;
            out.hls = (pr.streamingData && pr.streamingData.hlsManifestUrl) || '';
            out.cipher = cipherOnly(pr);
            ((pr.streamingData && pr.streamingData.adaptiveFormats) || []).forEach(function (f) {
                var furl = f.url || '';
                if (!furl && (f.signatureCipher || f.cipher)) {
                    var base = cipherURL(f);
                    var fid = '';
                    try { fid = new URL(base).searchParams.get('id') || ''; } catch (e) {}
                    furl = state.formatURLs[fid + ':' + f.itag] || '';
                    // Gewünschtes Format: H.264 bis 1080p mit der größten Höhe (der Player ruft es nach askForHD ab).
                    if (/avc1|avc3/.test(f.mimeType || '') && (f.height || 0) <= 1080 && (f.height || 0) > (out.wantHeight || 0)) {
                        out.wantHeight = f.height || 0; out.wantItag = f.itag;
                    }
                }
                if (!furl) { return; }
                out.formats.push({ itag: f.itag, url: furl, mime: f.mimeType, bitrate: f.bitrate, avg: f.averageBitrate,
                    w: f.width || 0, h: f.height || 0, fps: f.fps || 0, init: f.initRange, index: f.indexRange,
                    len: f.contentLength, dur: f.approxDurationMs, xtags: f.xtags || '', drc: !!f.isDrc,
                    audioDefault: f.audioTrack ? !!f.audioTrack.audioIsDefault : true,
                    audioName: f.audioTrack ? f.audioTrack.displayName : '', lang: f.audioTrack ? f.audioTrack.id : '',
                    channels: f.audioChannels || 0, rate: f.audioSampleRate || '' });
            });
        }
        return JSON.stringify(out);
    };
    // Seitenplayer anhalten, solange der native Player läuft (sonst lädt die Seite weiter mit).
    state.pausePage = function () {
        var p = playerElement();
        try { if (p && p.pauseVideo) { p.pauseVideo(); } } catch (e) {}
        document.querySelectorAll('video').forEach(function (v) { try { v.pause(); } catch (e) {} });
        return p && p.getCurrentTime ? p.getCurrentTime() : -1;
    };
    state.seekPage = function (t) {
        var p = playerElement();
        try { if (p && p.seekTo) { p.seekTo(t, true); } if (p && p.pauseVideo) { p.pauseVideo(); } } catch (e) {}
    };
    state.summary = function () {
        return JSON.stringify({ types: state.typeChecks, requests: state.requests.slice(0, 12), events: state.events,
            sbs: state.sourceBuffers.map(function (sb) { return { type: sb._type, bytes: sb._bytes, appends: sb._appends,
                ranges: sb._ranges.map(function (r) { return r[0].toFixed(1) + '-' + r[1].toFixed(1); }).join(',') }; }),
            captured: state.capturedItag, appended: state.appended, pruned: state.prunedSABR || 0, sabrOnly: state.sabrOnly || 0 });
    };
    note('installiert');
})();
