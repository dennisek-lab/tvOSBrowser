#import "BrowserSubtitleEngine.h"

#import <mach/mach.h>
#import <stdatomic.h>

#if __has_include(<whisper/whisper.h>)
#import <whisper/whisper.h>
#define BROWSER_HAS_WHISPER 1
#else
#define BROWSER_HAS_WHISPER 0
#endif

static NSString * const kSubtitleLogPrefix = @"[Subtitles]";

@implementation BrowserSubtitleCue

- (instancetype)initWithStart:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text {
    self = [super init];
    if (self) {
        _start = start;
        _end = MAX(end, start + 0.2);
        _text = [text copy];
        _visibleUntil = _end;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"[%.2f–%.2f] %@", self.start, self.end, self.text];
}

@end

#if BROWSER_HAS_WHISPER
static _Atomic(int) gBrowserWhisperVerboseLog = 0;

static void BrowserWhisperLog(enum ggml_log_level level, const char *text, void *userData) {
    (void)userData;
    if (text == NULL) {
        return;
    }
    if (level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN || atomic_load(&gBrowserWhisperVerboseLog)) {
        NSString *line = [[NSString stringWithUTF8String:text] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (line.length > 0) {
            NSLog(@"%@[whisper] %@", kSubtitleLogPrefix, line);
        }
    }
}

static bool BrowserWhisperAbort(void *userData) {
    _Atomic(bool) *flag = (_Atomic(bool) *)userData;
    return atomic_load(flag);
}
#endif

@interface BrowserSubtitleEngine () {
#if BROWSER_HAS_WHISPER
    struct whisper_context *_context;
#endif
    _Atomic(bool) _abortFlag;
    double _totalCompute;
    double _totalAudio;
}
@property (nonatomic, copy) NSString *modelPath;
@property (nonatomic, copy, readwrite) NSString *detectedLanguage;
@property (atomic, copy, readwrite, nullable) NSString *lockedLanguage;
/// Stimmen je erkannter Sprache (nur Abschnitte mit behaltenen Segmenten), bis zur Festlegung.
@property (nonatomic, strong) NSCountedSet<NSString *> *languageVotes;
@property (nonatomic) NSUInteger speechWindows;
@end

@implementation BrowserSubtitleEngine

+ (BOOL)isCompiledWithWhisper {
    return BROWSER_HAS_WHISPER;
}

+ (NSString *)modelsDirectory {
    return [NSBundle.mainBundle pathForResource:@"WhisperModels" ofType:nil];
}

+ (NSArray<NSString *> *)modelCandidatesForLanguage:(NSString *)language {
    NSArray *english = @[@"ggml-base.en-q5_1.bin", @"ggml-base.en-q8_0.bin", @"ggml-base.en.bin",
                         @"ggml-tiny.en-q5_1.bin", @"ggml-tiny.en-q8_0.bin", @"ggml-tiny.en.bin"];
    NSArray *multilingual = @[@"ggml-base-q5_1.bin", @"ggml-base-q8_0.bin", @"ggml-base.bin",
                              @"ggml-small-q5_1.bin", @"ggml-tiny-q5_1.bin", @"ggml-tiny.bin"];
    if ([language isEqualToString:@"en"]) {
        return [english arrayByAddingObjectsFromArray:multilingual];
    }
    // „auto“ oder eine feste andere Sprache: erst mehrsprachige Modelle, notfalls Englisch.
    return [multilingual arrayByAddingObjectsFromArray:english];
}

+ (NSString *)modelPathForLanguage:(NSString *)language {
    NSString *directory = [self modelsDirectory];
    if (directory.length == 0) {
        return nil;
    }
    for (NSString *name in [self modelCandidatesForLanguage:language]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

+ (BOOL)isMultilingualModelName:(NSString *)name {
    return ![name containsString:@".en"];
}

+ (BOOL)hasMultilingualModel {
    NSString *path = [self modelPathForLanguage:@"auto"];
    return path != nil && [self isMultilingualModelName:path.lastPathComponent];
}

+ (NSArray<NSString *> *)selectableLanguages {
    return @[@"auto", @"de", @"en", @"fr", @"es", @"it", @"nl", @"pl", @"tr", @"pt", @"ru"];
}

+ (NSString *)displayNameForLanguage:(NSString *)language {
    if (language.length == 0 || [language isEqualToString:@"auto"]) {
        return @"Automatisch";
    }
    NSLocale *german = [NSLocale localeWithLocaleIdentifier:@"de_DE"];
    NSString *name = [german localizedStringForLanguageCode:language];
    if (name.length == 0) {
        return language;
    }
    return [[name substringToIndex:1].uppercaseString stringByAppendingString:[name substringFromIndex:1]];
}

+ (double)currentMemoryFootprintMB {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return -1.0;
    }
    return (double)info.phys_footprint / (1024.0 * 1024.0);
}

- (instancetype)initWithModelPath:(NSString *)modelPath language:(NSString *)language {
    self = [super init];
    if (self) {
        _modelPath = [modelPath copy];
        _modelName = [[[modelPath lastPathComponent] stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"ggml-" withString:@""];
        BOOL multilingual = [BrowserSubtitleEngine isMultilingualModelName:modelPath.lastPathComponent];
        // .en-Modelle können nur Englisch.
        _language = multilingual ? ([language copy] ?: @"auto") : @"en";
        _detectedLanguage = _language;
        _languageVotes = [NSCountedSet set];
        atomic_store(&_abortFlag, false);
    }
    return self;
}

- (void)dealloc {
#if BROWSER_HAS_WHISPER
    if (_context != NULL) {
        whisper_free(_context);
        _context = NULL;
        NSLog(@"%@ Modell freigegeben, Speicher %.0f MB", kSubtitleLogPrefix, [BrowserSubtitleEngine currentMemoryFootprintMB]);
    }
#endif
}

- (BOOL)isLoaded {
#if BROWSER_HAS_WHISPER
    return _context != NULL;
#else
    return NO;
#endif
}

- (double)averageRealTimeFactor {
    return _totalAudio > 0.0 ? _totalCompute / _totalAudio : 0.0;
}

- (void)cancel {
    atomic_store(&_abortFlag, true);
}

- (void)lockLanguage:(NSString *)language {
    if (language.length == 0 || ![self.language isEqualToString:@"auto"] || self.lockedLanguage != nil) {
        return;
    }
    self.lockedLanguage = language;
    self.detectedLanguage = language;
    NSLog(@"%@ Sprache übernommen: %@", kSubtitleLogPrefix, language);
}

/// Sprache, mit der whisper rechnen soll: fest eingestellt, festgelegt oder „auto“ (erkennt je Abschnitt).
- (NSString *)decodingLanguage {
    return self.lockedLanguage ?: self.language;
}

/// Stimme eines Abschnitts mit Sprache zählen und ggf. festlegen (Queue der Auswertung).
- (void)voteForDetectedLanguage:(NSString *)language {
    if (language.length == 0 || self.lockedLanguage != nil || ![self.language isEqualToString:@"auto"]) {
        return;
    }
    self.speechWindows++;
    [self.languageVotes addObject:language];
    NSString *winner = nil;
    if ([self.languageVotes countForObject:language] >= 2) {
        winner = language;
    } else if (self.speechWindows >= 6) {
        NSUInteger best = 0;
        for (NSString *candidate in self.languageVotes) {
            NSUInteger count = [self.languageVotes countForObject:candidate];
            if (count > best) {
                best = count;
                winner = candidate;
            }
        }
    }
    if (winner == nil) {
        NSLog(@"%@ Sprache erkannt: %@ (Abschnitt %lu, noch nicht festgelegt)", kSubtitleLogPrefix, language, (unsigned long)self.speechWindows);
        return;
    }
    self.lockedLanguage = winner;
    NSLog(@"%@ Sprache festgelegt: %@ nach %lu Abschnitten mit Sprache (Stimmen %@)", kSubtitleLogPrefix, winner,
          (unsigned long)self.speechWindows, self.languageVotes);
    if (self.languageLockHandler != nil) {
        self.languageLockHandler(winner, self.speechWindows);
    }
}

- (BOOL)loadModel:(NSError **)error {
#if BROWSER_HAS_WHISPER
    if (_context != NULL) {
        return YES;
    }
    double memoryBefore = [BrowserSubtitleEngine currentMemoryFootprintMB];
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    whisper_log_set(BrowserWhisperLog, NULL);
    atomic_store(&gBrowserWhisperVerboseLog, 1);
    struct whisper_context_params params = whisper_context_default_params();
#if TARGET_OS_SIMULATOR
    // Die Simulator-GPU (MTLGPUFamilyApple2, ohne SIMD-Group-Reduktion) kann die ggml-Kernel nicht: CPU.
    params.use_gpu = false;
#else
    params.use_gpu = ![NSUserDefaults.standardUserDefaults boolForKey:@"AutoSubtitlesCPUOnly"];
#endif
    params.flash_attn = true;
    _context = whisper_init_from_file_with_params(self.modelPath.fileSystemRepresentation, params);
    atomic_store(&gBrowserWhisperVerboseLog, 0);
    if (_context == NULL) {
        NSLog(@"%@ Modell konnte nicht geladen werden: %@", kSubtitleLogPrefix, self.modelPath);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"BrowserSubtitleEngine" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Modell konnte nicht geladen werden"}];
        }
        return NO;
    }
    NSLog(@"%@ Modell %@ geladen in %.2f s, Sprache %@, mehrsprachig=%d, Speicher %.0f → %.0f MB, System: %s",
          kSubtitleLogPrefix, self.modelName, CFAbsoluteTimeGetCurrent() - begin, self.language,
          whisper_is_multilingual(_context), memoryBefore, [BrowserSubtitleEngine currentMemoryFootprintMB],
          whisper_print_system_info());
    return YES;
#else
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"BrowserSubtitleEngine" code:2 userInfo:@{NSLocalizedDescriptionKey: @"whisper.cpp ist nicht eingebunden (tools/build_whisper.sh)"}];
    }
    return NO;
#endif
}

static BOOL BrowserSubtitleIsNoiseText(NSString *text) {
    if (text.length == 0) {
        return YES;
    }
    unichar first = [text characterAtIndex:0];
    unichar last = [text characterAtIndex:text.length - 1];
    // [Music], (applause), *laughs*, ♪ …
    if ((first == '[' && last == ']') || (first == '(' && last == ')') || (first == '*' && last == '*')) {
        return YES;
    }
    NSCharacterSet *meaningful = NSCharacterSet.alphanumericCharacterSet;
    if ([text rangeOfCharacterFromSet:meaningful].location == NSNotFound) {
        return YES;
    }
    // Erfundene Zeichenketten bei Musik/Rauschen: dasselbe Zeichen 8-mal oder öfter hintereinander („Sssssssss…“).
    NSUInteger run = 1;
    for (NSUInteger i = 1; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        run = (c == [text characterAtIndex:i - 1] && [meaningful characterIsMember:c]) ? run + 1 : 1;
        if (run >= 8) {
            return YES;
        }
    }
    return NO;
}

- (NSArray<BrowserSubtitleCue *> *)transcribeSamples:(const float *)samples count:(NSUInteger)count startTime:(NSTimeInterval)startTime {
#if BROWSER_HAS_WHISPER
    if (_context == NULL || samples == NULL || count < 1600) {
        return nil;
    }
    atomic_store(&_abortFlag, false);
    double seconds = (double)count / 16000.0;

    // Stille überspringen (spart Rechenzeit und verhindert erfundene Sätze wie „Thank you.“).
    double energy = 0.0;
    for (NSUInteger i = 0; i < count; i++) {
        energy += (double)samples[i] * (double)samples[i];
    }
    double rms = sqrt(energy / (double)count);
    if (rms < 0.004) {
        NSLog(@"%@ Abschnitt %.1f s @ %.1f s still (RMS %.4f), übersprungen", kSubtitleLogPrefix, seconds, startTime, rms);
        return @[];
    }

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = (int)MIN(4, MAX(1, (NSInteger)NSProcessInfo.processInfo.activeProcessorCount - 2));
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.no_context = true;
    params.single_segment = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    NSString *decodingLanguage = [self decodingLanguage];
    params.language = decodingLanguage.UTF8String;
    params.detect_language = false;
    params.translate = false;
    params.temperature_inc = 0.0f;  // keine Wiederholungen mit höherer Temperatur: schneller, für Live-Untertitel genug
    params.no_speech_thold = 0.6f;
    // Kürzerer Audio-Kontext für kurze Abschnitte: der Encoder rechnet sonst immer 30 s.
    int audioContext = (int)ceil((seconds + 1.0) / 30.0 * 1500.0);
    audioContext = ((audioContext + 63) / 64) * 64;
    params.audio_ctx = MIN(1500, MAX(384, audioContext));
    // Token-Grenze je Durchlauf: Sprache braucht < 8 Tokens/s (inkl. Zeitmarken). Ohne Grenze schreibt whisper bei
    // Musik teils erfundenen Text bis zur Kontextgrenze aus („Sssss…“, ≈ 220 Tokens, am A15 2 s statt 0,1 s).
    params.max_tokens = (int)MAX(32.0, ceil(seconds * 12.0));
    params.abort_callback = BrowserWhisperAbort;
    params.abort_callback_user_data = &_abortFlag;

    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    int result = whisper_full(_context, params, samples, (int)count);
    double compute = CFAbsoluteTimeGetCurrent() - begin;
    if (result != 0) {
        NSLog(@"%@ whisper_full Fehler %d (abgebrochen=%d)", kSubtitleLogPrefix, result, atomic_load(&_abortFlag));
        return nil;
    }
    _totalCompute += compute;
    _totalAudio += seconds;

    NSString *windowLanguage = nil;
    if ([decodingLanguage isEqualToString:@"auto"]) {
        const char *lang = whisper_lang_str(whisper_full_lang_id(_context));
        if (lang != NULL) {
            windowLanguage = [NSString stringWithUTF8String:lang];
            self.detectedLanguage = windowLanguage;
        }
    }

    NSMutableArray<BrowserSubtitleCue *> *cues = [NSMutableArray array];
    int segments = whisper_full_n_segments(_context);
    for (int i = 0; i < segments; i++) {
        const char *rawText = whisper_full_get_segment_text(_context, i);
        NSString *text = rawText != NULL ? [[NSString stringWithUTF8String:rawText] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
        float noSpeech = whisper_full_get_segment_no_speech_prob(_context, i);
        if (BrowserSubtitleIsNoiseText(text) || noSpeech > 0.8f) {
            // Verworfene Segmente sichtbar machen: lange Rechenzeiten bei „0 Segmente“ kommen von erfundenem Text
            // (Musik), den whisper bis zur Token-Grenze ausschreibt.
            NSString *shown = text.length > 60 ? [[text substringToIndex:60] stringByAppendingString:@"…"] : text;
            NSLog(@"%@ Segment verworfen (no_speech %.2f, %d Tokens): %@", kSubtitleLogPrefix, noSpeech,
                  whisper_full_n_tokens(_context, i), shown);
            continue;
        }
        NSTimeInterval t0 = startTime + whisper_full_get_segment_t0(_context, i) / 100.0;
        NSTimeInterval t1 = startTime + whisper_full_get_segment_t1(_context, i) / 100.0;
        t1 = MIN(t1, startTime + seconds);
        [cues addObject:[[BrowserSubtitleCue alloc] initWithStart:t0 end:t1 text:text]];
    }
    if (windowLanguage != nil && cues.count > 0) {
        [self voteForDetectedLanguage:windowLanguage];  // nur Abschnitte mit Sprache zählen (nicht Musik/Stille)
    }
    NSLog(@"%@ Abschnitt %.1f s @ %.1f s: %lu Segmente in %.2f s (RTF %.2f, Schnitt %.2f), ctx %d, Sprache %@, Speicher %.0f MB%@%@",
          kSubtitleLogPrefix, seconds, startTime, (unsigned long)cues.count, compute, compute / seconds,
          self.averageRealTimeFactor, params.audio_ctx, self.detectedLanguage,
          [BrowserSubtitleEngine currentMemoryFootprintMB],
          cues.count > 0 ? @" – " : @"", cues.count > 0 ? [[cues valueForKey:@"text"] componentsJoinedByString:@" | "] : @"");
    return cues;
#else
    (void)samples; (void)count; (void)startTime;
    return nil;
#endif
}

@end
