#import "BrowserSubtitleAudioTapSource.h"

#import <MediaToolbox/MediaToolbox.h>
#import <os/lock.h>
#import <stdatomic.h>

static NSString * const kTapLogPrefix = @"[Subtitles][Tap]";

/// Gemeinsamer Zustand zwischen Audio-Thread (Tap) und Quelle. Referenzgezählt, weil der Tap
/// ihn länger halten kann als die Quelle (AVFoundation gibt den Tap verzögert frei).
typedef struct {
    _Atomic(int) refCount;
    _Atomic(bool) active;
    os_unfair_lock lock;
    float *buffer;            // mono, Quellrate
    size_t capacity;
    size_t count;
    double bufferStartTime;   // Videozeit von buffer[0]
    double expectedNextTime;
    bool hasTime;
    bool discontinuity;
    // Format (aus prepare)
    double sampleRate;
    UInt32 channels;
    bool nonInterleaved;
    bool isFloat;
    UInt32 bitsPerChannel;
} BrowserTapContext;

static void BrowserTapContextRelease(BrowserTapContext *context) {
    if (context == NULL) {
        return;
    }
    if (atomic_fetch_sub(&context->refCount, 1) == 1) {
        free(context->buffer);
        free(context);
    }
}

static void BrowserTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    BrowserTapContext *context = (BrowserTapContext *)clientInfo;
    atomic_fetch_add(&context->refCount, 1);
    *tapStorageOut = context;
}

static void BrowserTapFinalize(MTAudioProcessingTapRef tap) {
    BrowserTapContextRelease((BrowserTapContext *)MTAudioProcessingTapGetStorage(tap));
}

static void BrowserTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *format) {
    BrowserTapContext *context = (BrowserTapContext *)MTAudioProcessingTapGetStorage(tap);
    os_unfair_lock_lock(&context->lock);
    context->sampleRate = format->mSampleRate;
    context->channels = MAX(1u, format->mChannelsPerFrame);
    context->nonInterleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    context->isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    context->bitsPerChannel = format->mBitsPerChannel;
    context->count = 0;
    context->hasTime = false;
    // Bis zu 20 s Puffer (wird alle 0,25 s geleert).
    size_t capacity = (size_t)(MAX(format->mSampleRate, 8000.0) * 20.0);
    if (context->capacity < capacity) {
        free(context->buffer);
        context->buffer = (float *)calloc(capacity, sizeof(float));
        context->capacity = context->buffer != NULL ? capacity : 0;
    }
    os_unfair_lock_unlock(&context->lock);
    NSLog(@"%@ prepare rate=%.0f ch=%u float=%d nonInterleaved=%d bits=%u maxFrames=%ld",
          kTapLogPrefix, format->mSampleRate, (unsigned)format->mChannelsPerFrame, context->isFloat,
          context->nonInterleaved, (unsigned)format->mBitsPerChannel, (long)maxFrames);
}

static void BrowserTapUnprepare(MTAudioProcessingTapRef tap) {
}

static inline float BrowserTapSample(const AudioBufferList *list, BrowserTapContext *context, CMItemCount frame, UInt32 channel) {
    if (context->nonInterleaved) {
        if (channel >= list->mNumberBuffers) {
            return 0.0f;
        }
        const void *data = list->mBuffers[channel].mData;
        if (context->isFloat) {
            return ((const float *)data)[frame];
        }
        return context->bitsPerChannel == 32 ? ((const int32_t *)data)[frame] / 2147483648.0f : ((const int16_t *)data)[frame] / 32768.0f;
    }
    const void *data = list->mBuffers[0].mData;
    size_t index = (size_t)frame * context->channels + channel;
    if (context->isFloat) {
        return ((const float *)data)[index];
    }
    return context->bitsPerChannel == 32 ? ((const int32_t *)data)[index] / 2147483648.0f : ((const int16_t *)data)[index] / 32768.0f;
}

static void BrowserTapProcess(MTAudioProcessingTapRef tap,
                              CMItemCount numberFrames,
                              MTAudioProcessingTapFlags flags,
                              AudioBufferList *bufferListInOut,
                              CMItemCount *numberFramesOut,
                              MTAudioProcessingTapFlags *flagsOut) {
    CMTimeRange timeRange = kCMTimeRangeInvalid;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut);
    if (status != noErr) {
        return;
    }
    BrowserTapContext *context = (BrowserTapContext *)MTAudioProcessingTapGetStorage(tap);
    if (context == NULL || !atomic_load(&context->active) || context->buffer == NULL || context->sampleRate <= 0.0) {
        return;
    }
    CMItemCount frames = *numberFramesOut;
    if (frames <= 0) {
        return;
    }
    double time = CMTIME_IS_NUMERIC(timeRange.start) ? CMTimeGetSeconds(timeRange.start) : NAN;

    os_unfair_lock_lock(&context->lock);
    if (isnan(time)) {
        time = context->hasTime ? context->expectedNextTime : 0.0;
    }
    if (!context->hasTime || fabs(time - context->expectedNextTime) > 0.1) {
        if (context->hasTime) {
            context->discontinuity = true;
        }
        context->count = 0;
        context->hasTime = true;
    }
    if (context->count + (size_t)frames > context->capacity) {
        context->count = 0;
        context->discontinuity = true;
    }
    if (context->count == 0) {
        context->bufferStartTime = time;
    }
    float *out = context->buffer + context->count;
    UInt32 channels = context->channels;
    float scale = 1.0f / (float)channels;
    for (CMItemCount frame = 0; frame < frames; frame++) {
        float sum = 0.0f;
        for (UInt32 channel = 0; channel < channels; channel++) {
            sum += BrowserTapSample(bufferListInOut, context, frame, channel);
        }
        out[frame] = sum * scale;
    }
    context->count += (size_t)frames;
    context->expectedNextTime = time + (double)frames / context->sampleRate;
    os_unfair_lock_unlock(&context->lock);
}

@interface BrowserSubtitleAudioTapSource ()
@property (nonatomic, weak) AVPlayerItem *playerItem;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t drainTimer;
@property (nonatomic, strong) AVAudioConverter *converter;
@property (nonatomic) double converterRate;
@property (nonatomic) BOOL running;
@property (nonatomic) NSUInteger deliveredChunks;
@end

@implementation BrowserSubtitleAudioTapSource {
    BrowserTapContext *_context;
}

@synthesize delegate = _delegate;

- (instancetype)initWithPlayerItem:(AVPlayerItem *)playerItem {
    self = [super init];
    if (self) {
        _playerItem = playerItem;
        _queue = dispatch_queue_create("tvbrowser.subtitles.tap", DISPATCH_QUEUE_SERIAL);
        _context = (BrowserTapContext *)calloc(1, sizeof(BrowserTapContext));
        atomic_store(&_context->refCount, 1);
        atomic_store(&_context->active, false);
        _context->lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    BrowserTapContextRelease(_context);
}

- (BOOL)deliversAhead {
    return NO;
}

- (NSString *)kindName {
    return @"tap";
}

- (void)start {
    if (self.running) {
        return;
    }
    self.running = YES;
    AVPlayerItem *item = self.playerItem;
    AVAsset *asset = item.asset;
    if (asset == nil) {
        [self.delegate audioSource:self didFailWithReason:@"Kein Video"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf installTapWithTracks:tracks error:error];
        });
    }];
}

- (void)installTapWithTracks:(NSArray<AVAssetTrack *> *)tracks error:(NSError *)error {
    if (!self.running) {
        return;
    }
    AVPlayerItem *item = self.playerItem;
    AVAssetTrack *track = tracks.firstObject;
    if (item == nil || track == nil) {
        NSLog(@"%@ keine Audiospur (Fehler %@), Tap nicht möglich", kTapLogPrefix, error.localizedDescription ?: @"–");
        [self.delegate audioSource:self didFailWithReason:@"Keine Audiospur für den Audio-Tap"];
        return;
    }
    MTAudioProcessingTapCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.clientInfo = _context;
    callbacks.init = BrowserTapInit;
    callbacks.finalize = BrowserTapFinalize;
    callbacks.prepare = BrowserTapPrepare;
    callbacks.unprepare = BrowserTapUnprepare;
    callbacks.process = BrowserTapProcess;
    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap);
    if (status != noErr || tap == NULL) {
        NSLog(@"%@ MTAudioProcessingTapCreate Fehler %d", kTapLogPrefix, (int)status);
        [self.delegate audioSource:self didFailWithReason:@"Audio-Tap konnte nicht angelegt werden"];
        return;
    }
    AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    parameters.audioTapProcessor = tap;
    CFRelease(tap);
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[parameters];
    atomic_store(&_context->active, true);
    item.audioMix = mix;
    NSLog(@"%@ Tap aktiv auf Spur %d (%lu Audiospuren)", kTapLogPrefix, track.trackID, (unsigned long)tracks.count);

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf drain];
    });
    dispatch_resume(timer);
    self.drainTimer = timer;
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    atomic_store(&_context->active, false);
    if (self.drainTimer != nil) {
        dispatch_source_cancel(self.drainTimer);
        self.drainTimer = nil;
    }
    AVPlayerItem *item = self.playerItem;
    void (^removeMix)(void) = ^{
        if (item.audioMix != nil) {
            item.audioMix = nil;
        }
    };
    if (NSThread.isMainThread) {
        removeMix();
    } else {
        dispatch_async(dispatch_get_main_queue(), removeMix);
    }
    NSLog(@"%@ gestoppt nach %lu Paketen", kTapLogPrefix, (unsigned long)self.deliveredChunks);
}

- (void)updatePlaybackTime:(NSTimeInterval)time rate:(float)rate {
    // Der Tap folgt der Wiedergabe von selbst.
}

- (void)drain {
    BrowserTapContext *context = _context;
    os_unfair_lock_lock(&context->lock);
    size_t count = context->count;
    if (count == 0) {
        os_unfair_lock_unlock(&context->lock);
        return;
    }
    NSMutableData *raw = [NSMutableData dataWithBytes:context->buffer length:count * sizeof(float)];
    double startTime = context->bufferStartTime;
    double rate = context->sampleRate;
    BOOL discontinuity = context->discontinuity;
    context->count = 0;
    context->discontinuity = false;
    os_unfair_lock_unlock(&context->lock);

    NSData *samples = [self resample:raw rate:rate reset:discontinuity];
    if (samples.length == 0) {
        return;
    }
    self.deliveredChunks++;
    [self.delegate audioSource:self didProduceSamples:samples atTime:startTime discontinuity:discontinuity];
}

- (NSData *)resample:(NSData *)raw rate:(double)rate reset:(BOOL)reset {
    if (fabs(rate - 16000.0) < 1.0) {
        return raw;
    }
    if (self.converter == nil || self.converterRate != rate) {
        AVAudioFormat *input = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate channels:1 interleaved:NO];
        AVAudioFormat *output = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:16000.0 channels:1 interleaved:NO];
        self.converter = [[AVAudioConverter alloc] initFromFormat:input toFormat:output];
        self.converter.sampleRateConverterQuality = AVAudioQualityHigh;
        self.converter.primeMethod = AVAudioConverterPrimeMethod_None;
        self.converterRate = rate;
    } else if (reset) {
        [self.converter reset];
    }
    AVAudioFrameCount frames = (AVAudioFrameCount)(raw.length / sizeof(float));
    AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.converter.inputFormat frameCapacity:frames];
    input.frameLength = frames;
    memcpy(input.floatChannelData[0], raw.bytes, raw.length);
    AVAudioFrameCount capacity = (AVAudioFrameCount)ceil(frames * 16000.0 / rate) + 64;
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.converter.outputFormat frameCapacity:capacity];
    __block BOOL supplied = NO;
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [self.converter convertToBuffer:output error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *outStatus) {
        if (supplied) {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        supplied = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return input;
    }];
    if (status == AVAudioConverterOutputStatus_Error) {
        NSLog(@"%@ Umrechnung fehlgeschlagen: %@", kTapLogPrefix, error);
        return nil;
    }
    return [NSData dataWithBytes:output.floatChannelData[0] length:output.frameLength * sizeof(float)];
}

@end
