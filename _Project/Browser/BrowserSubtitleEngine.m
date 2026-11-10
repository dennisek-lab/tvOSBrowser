#import "BrowserSubtitleEngine.h"

#import "BrowserSubtitleTranslator.h"

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
        _shownAt = NAN;
    }
    return self;
}

- (BrowserSubtitleCue *)cueWithTranslatedText:(NSString *)text {
    BrowserSubtitleCue *cue = [[BrowserSubtitleCue alloc] initWithStart:self.start end:self.end text:text];
    cue.visibleUntil = self.visibleUntil;
    cue.tentative = self.tentative;
    cue.shownAt = self.shownAt;
    cue.language = self.translationTarget ?: self.language;
    cue.originalText = self.originalText ?: self.text;
    return cue;
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

/// Ein geladenes whisper-Modell (Gewichte, nur gelesen), geteilt von allen Engines mit derselben Datei und denselben
/// Ladeparametern. Jede Engine rechnet in ihrem eigenen `whisper_state`. Vorher lud jede Engine ihr eigenes Modell:
/// Seiten-Untertitel und nativer Player zusammen 2 × whisper small (Apple TV 10. November 2026: App 596 MB beim Abspielen).
@interface BrowserWhisperSharedModel : NSObject
@property (nonatomic, readonly) struct whisper_context *context;
@property (nonatomic, copy, readonly) NSString *key;
@end

@implementation BrowserWhisperSharedModel

- (instancetype)initWithContext:(struct whisper_context *)context key:(NSString *)key {
    self = [super init];
    if (self) {
        _context = context;
        _key = [key copy];
    }
    return self;
}

- (void)dealloc {
    if (_context != NULL) {
        whisper_free(_context);
        _context = NULL;
        NSLog(@"%@ Modell freigegeben (%@), Speicher %.0f MB", kSubtitleLogPrefix, _key.lastPathComponent,
              [BrowserSubtitleEngine currentMemoryFootprintMB]);
    }
}

@end

/// Geladene Modelle, schwach gehalten: Gibt die letzte Engine ihres frei, wird das Modell freigegeben.
static NSMapTable<NSString *, BrowserWhisperSharedModel *> *BrowserWhisperModelTable(void) {
    static NSMapTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSMapTable strongToWeakObjectsMapTable];
    });
    return table;
}
#endif

@interface BrowserSubtitleEngine () {
#if BROWSER_HAS_WHISPER
    /// Geteiltes Modell (hält es am Leben) und der Zeiger darauf; gerechnet wird nur in `_state`.
    BrowserWhisperSharedModel *_model;
    struct whisper_context *_context;
    struct whisper_state *_state;
    /// Wort-Zeitmarken per DTW (Ausrichtung über Attention-Köpfe); ohne DTW sind whispers Token-Zeiten oft unbrauchbar.
    BOOL _usesDTW;
    /// Höchstlänge eines Stücks beim Teilen: 84 (zwei Zeilen); folgt Apples Übersetzung, ganze Sätze bis 150 Zeichen,
    /// sonst übersetzt Apple Satzhälften einzeln („… dass du ausgeflippt bist“ / „Von meiner Roboterhand raus?“).
    NSUInteger _splitCharacters;
    NSString *_vadModelPath;   // Silero-VAD (ggml-silero-*.bin), nil = aus
    struct whisper_vad_context *_vad;
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
/// Bei fest eingestellter Untertitelsprache: die tatsächlich gesprochene (whisper_lang_auto_detect auf den ersten
/// Abschnitten mit Sprache, vor dem Erkennen). Weicht sie ab, erkennt whisper in ihr und Apple übersetzt (mit
/// Satzkontext); ohne Apple übersetzt whisper selbst, dann ohne Satzkontext (siehe contextBeforeTime:language:).
@property (atomic, copy, nullable) NSString *spokenLanguage;
@property (nonatomic, strong) NSCountedSet<NSString *> *spokenVotes;
@property (nonatomic) NSUInteger spokenChecks;
@property (nonatomic) NSUInteger speechWindows;
/// Zuletzt gewählter Weg bei abweichender Sprache (Quellsprache = Apple, "" = whisper selbst), nur fürs Log.
@property (nonatomic, copy, nullable) NSString *lastTranslateFrom;
/// Zuletzt erkannte Untertitel (Satzkontext für den nächsten Abschnitt, siehe contextBeforeTime:).
@property (nonatomic, strong) NSMutableArray<BrowserSubtitleCue *> *recentCues;
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
    // small zuerst, wenn im Paket: am Apple TV (Tears of Steel, Deutsch über Apple-Übersetzung) 14/14 Sätze statt 13/14,
    // Text näher am Original („Solltest du nicht da unten sein?“ statt „Sollen wir da runtergehen?“), RTF ≈ 0,08 mit
    // Metal, Speicher ≈ 360 statt 150 MB. pref SubtitlesModel=base nimmt wieder base (Vergleich, wenig Speicher).
    if (![[NSUserDefaults.standardUserDefaults stringForKey:@"SubtitlesModel"] isEqualToString:@"base"]) {
        NSArray *small = [language isEqualToString:@"en"]
            ? @[@"ggml-small.en-q5_1.bin", @"ggml-small-q5_1.bin"] : @[@"ggml-small-q5_1.bin"];
        english = [small arrayByAddingObjectsFromArray:english];
        multilingual = [small arrayByAddingObjectsFromArray:multilingual];
    }
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
        if (![_language isEqualToString:@"auto"]) {
            [BrowserSubtitleTranslator.sharedTranslator prepare];  // Sprachpaare holen, bevor der erste Abschnitt kommt
        }
    }
    return self;
}

- (void)dealloc {
#if BROWSER_HAS_WHISPER
    if (_vad != NULL) {
        whisper_vad_free(_vad);
        _vad = NULL;
    }
    if (_state != NULL) {
        whisper_free_state(_state);
        _state = NULL;
    }
    _context = NULL;
    _model = nil;  // letzte Engine des Modells: dealloc gibt es frei
#endif
}

- (BOOL)isLoaded {
#if BROWSER_HAS_WHISPER
    return _state != NULL;
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
    if (_state != NULL) {
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
    // DTW-Wortzeiten: whisper.cpp kann sie nicht mit Flash Attention. Ohne DTW bekam am Apple TV das erste Wort eines
    // Segments dessen ganze Dauer, die übrigen Sätze landeten am Abschnittsende und wurden als Überlappung verworfen.
    // Rechenzeit reicht: base läuft mit Metal bei RTF 0,02–0,04. Vergleich ohne DTW: pref SubtitlesNoDTW=YES.
    BOOL english = [self.modelName containsString:@".en"];
    enum whisper_alignment_heads_preset preset = WHISPER_AHEADS_NONE;
    if ([self.modelName hasPrefix:@"tiny"]) {
        preset = english ? WHISPER_AHEADS_TINY_EN : WHISPER_AHEADS_TINY;
    } else if ([self.modelName hasPrefix:@"base"]) {
        preset = english ? WHISPER_AHEADS_BASE_EN : WHISPER_AHEADS_BASE;
    } else if ([self.modelName hasPrefix:@"small"]) {
        preset = english ? WHISPER_AHEADS_SMALL_EN : WHISPER_AHEADS_SMALL;
    }
    _usesDTW = preset != WHISPER_AHEADS_NONE && ![NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesNoDTW"];
    params.flash_attn = !_usesDTW;
    if (_usesDTW) {
        params.dtw_token_timestamps = true;
        params.dtw_aheads_preset = preset;
    }
    // Silero-VAD als Prüfer: Abschnitte ohne Sprache überspringen, Untertitel ohne Sprache darunter verwerfen. Gegen
    // erfundene Sätze in Musik und Geräuschen („Ich bin mir nicht sicher, ob ich es bekommen kann.“). whisper bekommt
    // weiter den ganzen Abschnitt: mit params.vad (Ton zusammengeschnitten) fielen kurze Sätze am Abschnittsrand weg
    // (< 1 s Ton übrig) und Wörter in den Schnittlücken bekamen falsche Zeiten (bis 6,7 s). Aus: pref SubtitlesNoVAD=YES.
    _vadModelPath = nil;
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesNoVAD"]) {
        NSString *directory = [self.modelPath stringByDeletingLastPathComponent];
        for (NSString *file in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]
                                sortedArrayUsingSelector:@selector(compare:)].reverseObjectEnumerator) {
            if ([file hasPrefix:@"ggml-silero"] && [file hasSuffix:@".bin"]) {
                _vadModelPath = [directory stringByAppendingPathComponent:file];
                break;
            }
        }
    }
    if (_vadModelPath != nil && _vad == NULL) {
        struct whisper_vad_context_params vadParams = whisper_vad_default_context_params();
        vadParams.n_threads = 2;
        vadParams.use_gpu = false;
        _vad = whisper_vad_init_from_file_with_params(_vadModelPath.fileSystemRepresentation, vadParams);
        if (_vad == NULL) {
            NSLog(@"%@ Silero-VAD konnte nicht geladen werden: %@", kSubtitleLogPrefix, _vadModelPath.lastPathComponent);
            _vadModelPath = nil;
        }
    }
    NSString *modelKey = [NSString stringWithFormat:@"%@|gpu=%d|dtw=%d", self.modelPath, params.use_gpu, _usesDTW ? (int)preset : -1];
    BOOL shared = NO;
    BrowserWhisperSharedModel *model = nil;
    NSMapTable<NSString *, BrowserWhisperSharedModel *> *models = BrowserWhisperModelTable();
    @synchronized (models) {
        model = [models objectForKey:modelKey];
        if (model != nil) {
            shared = YES;
        } else {
            // Unter der Sperre laden: Eine zweite Engine wartet die halbe Sekunde, statt das Modell noch einmal zu laden.
            struct whisper_context *context = whisper_init_from_file_with_params_no_state(self.modelPath.fileSystemRepresentation, params);
            if (context != NULL) {
                model = [[BrowserWhisperSharedModel alloc] initWithContext:context key:modelKey];
                [models setObject:model forKey:modelKey];
            }
        }
    }
    _model = model;
    _context = model.context;
    _state = _context != NULL ? whisper_init_state(_context) : NULL;
    atomic_store(&gBrowserWhisperVerboseLog, 0);
    if (_state == NULL) {
        _model = nil;
        _context = NULL;
        NSLog(@"%@ Modell konnte nicht geladen werden: %@", kSubtitleLogPrefix, self.modelPath);
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"BrowserSubtitleEngine" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Modell konnte nicht geladen werden"}];
        }
        return NO;
    }
    NSLog(@"%@ Modell %@ %@ in %.2f s, Sprache %@, DTW-Wortzeiten %d, VAD %@, mehrsprachig=%d, Speicher %.0f → %.0f MB, System: %s",
          kSubtitleLogPrefix, self.modelName, shared ? @"geteilt (eigener Zustand)" : @"geladen", CFAbsoluteTimeGetCurrent() - begin, self.language, _usesDTW,
          _vadModelPath.lastPathComponent ?: @"aus",
          whisper_is_multilingual(_context), memoryBefore, [BrowserSubtitleEngine currentMemoryFootprintMB],
          whisper_print_system_info());
    if (![self.language isEqualToString:@"auto"] && whisper_is_multilingual(_context)) {
        [self primeEncoder];
    }
    return YES;
#else
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"BrowserSubtitleEngine" code:2 userInfo:@{NSLocalizedDescriptionKey: @"whisper.cpp ist nicht eingebunden (tools/build_whisper.sh)"}];
    }
    return NO;
#endif
}

#if BROWSER_HAS_WHISPER
/// Feste Untertitelsprache: einmal 1 s Stille mit kleinem Audio-Kontext rechnen. whisper_lang_auto_detect nimmt den
/// Audio-Kontext des letzten whisper_full; vor dem ersten Lauf rechnet die Spracherkennung sonst den vollen 30-s-Encoder
/// (Simulator: 1,2 s statt 0,3 s für den ersten Abschnitt). Läuft beim Laden, parallel zum Laden der Tonquelle.
- (void)primeEncoder {
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    float silence[16000] = {0};
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = (int)MIN(4, MAX(1, (NSInteger)NSProcessInfo.processInfo.activeProcessorCount - 2));
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.no_context = true;
    params.language = self.language.UTF8String;
    params.audio_ctx = 384;
    params.max_tokens = 1;
    params.temperature_inc = 0.0f;
    int result = whisper_full_with_state(_context, _state, params, silence, 16000);
    NSLog(@"%@ Encoder vorgewärmt (Audio-Kontext 384) in %.2f s%@", kSubtitleLogPrefix, CFAbsoluteTimeGetCurrent() - begin,
          result == 0 ? @"" : [NSString stringWithFormat:@", Fehler %d", result]);
}
#endif

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

/// Kleinbuchstaben und Ziffern, Wörter durch ein Leerzeichen getrennt (Vergleich von Wiederholungen).
static NSString *BrowserSubtitleNormalizedText(NSString *text) {
    NSMutableString *result = [NSMutableString string];
    BOOL space = NO;
    NSString *lower = text.lowercaseString;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:c]) {
            if (space && result.length > 0) {
                [result appendString:@" "];
            }
            space = NO;
            [result appendFormat:@"%C", c];
        } else {
            space = YES;
        }
    }
    return result;
}

/// Wiederholungsschleifen von whisper kürzen („und seiner Schwiegereltern und seiner Schwiegereltern und …“): eine
/// Wortfolge aus 2–8 Wörtern, die direkt hintereinander mehrfach steht, bleibt einmal stehen; ein einzelnes Wort ab
/// drei Wiederholungen. Gibt den gekürzten Text zurück (unverändert, wenn nichts wiederholt wird).
static NSString *BrowserSubtitleCollapseRepeats(NSString *text) {
    // Mit Bindestrich verkettete Schleifen („Palästinenserflagge-Palästinenserflagge-…“) auf ein Wort kürzen.
    static NSRegularExpression *hyphenLoop;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hyphenLoop = [NSRegularExpression regularExpressionWithPattern:@"(\\p{L}+)(?:-\\1){2,}"
                                                               options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    text = [hyphenLoop stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"$1"] ?: text;
    NSMutableArray<NSString *> *words = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] mutableCopy];
    [words removeObject:@""];
    if (words.count < 3) {
        return text;
    }
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithCapacity:words.count];
    for (NSString *word in words) {
        [keys addObject:BrowserSubtitleNormalizedText(word)];
    }
    BOOL changed = NO;
    for (NSUInteger n = 8; n >= 1; n--) {
        NSUInteger minimumRepeats = n == 1 ? 3 : 2;
        NSUInteger i = 0;
        while (i + n * minimumRepeats <= keys.count) {
            NSUInteger repeats = 1;
            while (i + n * (repeats + 1) <= keys.count) {
                BOOL same = YES;
                for (NSUInteger k = 0; k < n && same; k++) {
                    same = keys[i + k].length > 0 && [keys[i + k] isEqualToString:keys[i + n * repeats + k]];
                }
                if (!same) {
                    break;
                }
                repeats++;
            }
            if (repeats >= minimumRepeats) {
                NSRange extra = NSMakeRange(i, n * (repeats - 1));  // letzte Wiederholung behalten (Satzzeichen)
                [words removeObjectsInRange:extra];
                [keys removeObjectsInRange:extra];
                changed = YES;
            }
            i++;
        }
    }
    return changed ? [words componentsJoinedByString:@" "] : text;
}

#if BROWSER_HAS_WHISPER
/// Wiederholungen innerhalb eines Abschnitts entfernen: Schleifen in einem Untertitel kürzen, Untertitel verwerfen, deren
/// Text schon im vorigen steht (whisper wiederholt einen Satz oder ein Satzende als eigenes Segment).
static NSArray<BrowserSubtitleCue *> *BrowserSubtitleRemoveRepeats(NSArray<BrowserSubtitleCue *> *cues) {
    NSMutableArray<BrowserSubtitleCue *> *kept = [NSMutableArray arrayWithCapacity:cues.count];
    NSString *previous = nil;
    for (BrowserSubtitleCue *__strong cue in cues) {
        NSString *collapsed = BrowserSubtitleCollapseRepeats(cue.text);
        NSString *normalized = BrowserSubtitleNormalizedText(collapsed);
        if (normalized.length == 0) {
            continue;
        }
        if (previous != nil && normalized.length >= 6 && [previous containsString:normalized]) {
            NSLog(@"%@ Wiederholung verworfen: %@", kSubtitleLogPrefix, cue.text);
            // Zeit dem vorigen zuschlagen, damit er nicht vor der Wiederholung verschwindet
            BrowserSubtitleCue *last = kept.lastObject;
            kept[kept.count - 1] = [[BrowserSubtitleCue alloc] initWithStart:last.start end:MAX(last.end, cue.end) text:last.text];
            continue;
        }
        if (![collapsed isEqualToString:cue.text]) {
            NSLog(@"%@ Wiederholung gekürzt: %@ → %@", kSubtitleLogPrefix, cue.text, collapsed);
            cue = [[BrowserSubtitleCue alloc] initWithStart:cue.start end:cue.end text:collapsed];
        }
        [kept addObject:cue];
        previous = normalized;
    }
    return kept;
}

/// Zeilen auffüllen: kurze Stücke (ein, zwei Wörter, < 2 s) mit dem folgenden zusammenlegen, solange beides in zwei
/// Zeilen passt und das folgende höchstens 1 s nach dem Anfang beginnt (es erscheint so höchstens 1 s zu früh).
/// Länger stehen bleiben Zeilen über die rollende Anzeige (Mindestanzeigedauer 2–4 s, die vorige bleibt über der neuen).
/// Vorher bis zu ≈ 3,5 s Vorlauf: Am Apple TV las man „… wir müssen unseren Leidenschaften folgen“ vor dem Sprechen.
static const NSTimeInterval kBrowserSubtitleMaxMergeLead = 1.0;   // höchstens so viel früher darf ein Stück erscheinen

static NSArray<BrowserSubtitleCue *> *BrowserSubtitleMergeShortCues(NSArray<BrowserSubtitleCue *> *cues, NSUInteger maxCharacters) {
    NSMutableArray<BrowserSubtitleCue *> *merged = [NSMutableArray arrayWithCapacity:cues.count];
    for (BrowserSubtitleCue *cue in cues) {
        BrowserSubtitleCue *previous = merged.lastObject;
        if (previous != nil) {
            NSTimeInterval previousDuration = previous.end - previous.start;
            BOOL previousShort = previousDuration < 2.0 || previous.text.length < 28;
            BOOL cueShort = cue.end - cue.start < 1.5 || cue.text.length < 20;
            BOOL fits = previous.text.length + 1 + cue.text.length <= maxCharacters;
            BOOL close = cue.start - previous.start <= kBrowserSubtitleMaxMergeLead && cue.end - previous.start <= 8.0;
            if ((previousShort || cueShort) && fits && close) {
                merged[merged.count - 1] = [[BrowserSubtitleCue alloc] initWithStart:previous.start end:MAX(previous.end, cue.end)
                                                                                text:[NSString stringWithFormat:@"%@ %@", previous.text, cue.text]];
                continue;
            }
        }
        [merged addObject:cue];
    }
    return merged;
}

static const NSUInteger kBrowserSubtitleMaxCueCharacters = 84;   // zwei Zeilen à ≈ 42 Zeichen

/// Wortzeiten prüfen: aufsteigend, im Segment und nicht alle an einem Ende gestaucht. Sonst (keine DTW-Zeiten, whisper
/// gab dem ersten Wort das ganze Segment) anteilig nach Textlänge verteilen: Sprechtempo ist grob gleichmäßig, das trifft
/// Satzanfänge auf ≈ 1 s. Enden = Anfang des nächsten Worts.
static BOOL BrowserSubtitleFixWordTimes(NSArray<NSString *> *words, NSMutableArray<NSNumber *> *starts,
                                        NSMutableArray<NSNumber *> *ends, NSTimeInterval *segmentStartInOut,
                                        NSTimeInterval *segmentEndInOut, NSTimeInterval windowStart, NSTimeInterval windowEnd,
                                        BOOL dtw) {
    NSUInteger count = words.count;
    NSTimeInterval segmentStart = *segmentStartInOut, segmentEnd = *segmentEndInOut;
    BOOL plausible = YES;
    double previous = windowStart - 0.2;
    // DTW-Zeiten gelten im ganzen Abschnitt: whispers Segmentgrenzen liegen oft Sekunden daneben (Tears of Steel:
    // Segment 12,9–19,9 s, DTW-Wort 23,3 s, offizieller Untertitel 23,0 s). Nur aufsteigend und im Abschnitt.
    double low = dtw ? windowStart - 0.2 : segmentStart - 0.5;
    double high = dtw ? windowEnd + 0.2 : segmentEnd + 0.2;
    for (NSUInteger i = 0; i < count && plausible; i++) {
        double start = starts[i].doubleValue;
        if (!isfinite(start) || start < previous - 0.05 || start < low || start > high) {
            plausible = NO;
        }
        previous = start;
    }
    double span = starts.lastObject.doubleValue - starts.firstObject.doubleValue;
    if (plausible && count >= 4 && span < 0.05 * count) {
        plausible = NO;   // alle Wörter auf einem Fleck: keine echten Zeiten
    }
    if (plausible && dtw) {
        // Segment an die Wörter anlegen: Anfang kurz vor dem ersten Wort (DTW-Zeiten liegen eher etwas nach dem
        // Einsatz), Ende nach dem letzten Wort plus Ausklang, beides im Abschnitt.
        segmentStart = MAX(windowStart, starts.firstObject.doubleValue - 0.15);
        segmentEnd = MIN(windowEnd, MAX(starts.lastObject.doubleValue + 0.6, segmentStart + 0.5));
        *segmentStartInOut = segmentStart;
        *segmentEndInOut = segmentEnd;
    }
    double duration = MAX(0.3, segmentEnd - segmentStart);
    if (!plausible) {
#if DEBUG
        NSLog(@"[Subtitles] Wortzeiten unplausibel (%.2f–%.2f s, %lu Wörter, erstes %.2f): anteilig verteilt", segmentStart, segmentEnd,
              (unsigned long)count, starts.firstObject.doubleValue);
#endif
        NSUInteger total = 0;
        for (NSString *word in words) {
            total += word.length + 1;
        }
        NSUInteger before = 0;
        for (NSUInteger i = 0; i < count; i++) {
            starts[i] = @(segmentStart + duration * (double)before / (double)MAX((NSUInteger)1, total));
            before += words[i].length + 1;
        }
    }
    for (NSUInteger i = 0; i < count; i++) {
        double start = MAX(segmentStart, MIN(starts[i].doubleValue, segmentEnd));
        starts[i] = @(start);
    }
    for (NSUInteger i = 0; i < count; i++) {
        ends[i] = @(i + 1 < count ? MAX(starts[i].doubleValue, starts[i + 1].doubleValue) : segmentEnd);
    }
    return plausible;
}

/// Steht im Text ein Satzende (. ? ! …) mit Leerzeichen dahinter und mindestens 8 Zeichen davor?
static BOOL BrowserSubtitleHasInnerSentenceEnd(NSString *text) {
    for (NSUInteger i = 8; i + 1 < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ((c == '.' || c == '?' || c == '!' || c == 0x2026) && [text characterAtIndex:i + 1] == ' ') {
            return YES;
        }
    }
    return NO;
}
static const NSUInteger kBrowserSubtitleMinSentenceCharacters = 8;   // „You're a jerk, Tom.“ eigene Zeile, „Look!“ nicht

/// Teilt ein whisper-Segment in Untertitel: an Satzenden (ab 8 Zeichen), sonst spätestens nach ≈ 84 Zeichen an einer
/// Wortgrenze (bevorzugt nach Komma). Zeiten aus den Token-Zeitmarken; das erste Stück beginnt mit dem Segment.
/// Auch kurze Segmente mit zwei Sätzen werden geteilt: whisper fasst „You're a jerk, Tom. Look, Celia, …“ in ein
/// Segment, als Ganzes erschiene der zweite Satz Sekunden vor dem Sprechen.
- (NSArray<BrowserSubtitleCue *> *)cuesForSegment:(int)segment text:(NSString *)text start:(NSTimeInterval)segmentStart
                                              end:(NSTimeInterval)segmentEnd windowStart:(NSTimeInterval)windowStart
                                        windowEnd:(NSTimeInterval)windowEnd {
    NSUInteger maxCharacters = _splitCharacters > 0 ? _splitCharacters : kBrowserSubtitleMaxCueCharacters;
    BOOL single = text.length <= maxCharacters && segmentEnd - segmentStart <= 7.0 && !BrowserSubtitleHasInnerSentenceEnd(text);
    whisper_token eot = whisper_token_eot(_context);
    int tokens = whisper_full_n_tokens_from_state(_state, segment);
    // Wörter bilden (Token mit führendem Leerzeichen beginnen ein Wort; Bytes erst am Wortende als UTF-8 lesen).
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    NSMutableArray<NSNumber *> *wordStarts = [NSMutableArray array];
    NSMutableArray<NSNumber *> *wordEnds = [NSMutableArray array];
    NSMutableData *bytes = [NSMutableData data];
    __block double wordStart = NAN, wordEnd = NAN;   // __block: finishWord liest die aktuellen Werte (vorher immer NaN)
    void (^finishWord)(void) = ^{
        NSString *word = [[[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (word.length > 0) {
            [words addObject:word];
            [wordStarts addObject:@(wordStart)];
            [wordEnds addObject:@(wordEnd)];
        }
        bytes.length = 0;
    };
    for (int k = 0; k < tokens; k++) {
        whisper_token_data data = whisper_full_get_token_data_from_state(_state, segment, k);
        if (data.id >= eot) {
            continue;  // Zeitmarken und Steuertokens
        }
        const char *piece = whisper_full_get_token_text_from_state(_context, _state, segment, k);
        if (piece == NULL || piece[0] == 0) {
            continue;
        }
        if (piece[0] == ' ' && bytes.length > 0) {
            finishWord();
        }
        // Unter VAD liegen die Token-Zeiten auf der gekürzten Zeitachse. whisper_full_get_token_t0/t1 rechnen sie zurück,
        // t_dtw nicht: dessen Versatz ist innerhalb eines Sprachstücks derselbe wie der von t0.
        int64_t t0 = whisper_full_get_token_t0_from_state(_state, segment, k);
        int64_t t1 = whisper_full_get_token_t1_from_state(_state, segment, k);
        int64_t offset = t0 - data.t0;
        BOOL dtw = _usesDTW && data.t_dtw >= 0;
        if (bytes.length == 0) {
            wordStart = windowStart + (dtw ? data.t_dtw + offset : t0) / 100.0;
        }
        wordEnd = windowStart + (dtw ? data.t_dtw + offset : t1) / 100.0;
        [bytes appendBytes:piece length:strlen(piece)];
    }
    if (bytes.length > 0) {
        finishWord();
    }
    if (words.count == 0) {
        return @[[[BrowserSubtitleCue alloc] initWithStart:segmentStart end:segmentEnd text:text]];
    }
    BOOL timed = BrowserSubtitleFixWordTimes(words, wordStarts, wordEnds, &segmentStart, &segmentEnd, windowStart, windowEnd, _usesDTW);
    if (timed && _usesDTW) {
        wordStarts[0] = @(segmentStart);
    }
    if (single || words.count < 2) {
        return @[[[BrowserSubtitleCue alloc] initWithStart:segmentStart end:segmentEnd text:text]];
    }
    NSMutableArray<BrowserSubtitleCue *> *cues = [NSMutableArray array];
    NSUInteger pieceStart = 0;
    NSUInteger length = 0;
    NSInteger bestBreak = -1;      // letzter Index, nach dem gut getrennt werden kann
    for (NSUInteger w = 0; w < words.count; w++) {
        length += (length > 0 ? 1 : 0) + words[w].length;
        unichar last = [words[w] characterAtIndex:words[w].length - 1];
        BOOL sentenceEnd = last == '.' || last == '?' || last == '!' || last == 0x2026;
        BOOL clauseEnd = last == ',' || last == ';' || last == ':';
        BOOL lastWord = w + 1 == words.count;
        if ((clauseEnd || sentenceEnd) && length >= 30) {
            bestBreak = (NSInteger)w;   // gute Stelle, falls das Stück gleich zu lang wird (kein Mini-Stück)
        }
        NSInteger breakAfter = -1;
        if (!lastWord && sentenceEnd && length >= kBrowserSubtitleMinSentenceCharacters) {
            breakAfter = (NSInteger)w;
        } else if (!lastWord && length + 1 + words[w + 1].length > maxCharacters) {
            breakAfter = bestBreak >= (NSInteger)pieceStart ? bestBreak : (NSInteger)w;
        }
        if (breakAfter < 0 && !lastWord) {
            continue;
        }
        NSUInteger endIndex = lastWord ? w : (NSUInteger)breakAfter;
        NSArray<NSString *> *pieceWords = [words subarrayWithRange:NSMakeRange(pieceStart, endIndex - pieceStart + 1)];
        double start = cues.count == 0 ? segmentStart : wordStarts[pieceStart].doubleValue;
        double end = endIndex + 1 == words.count ? segmentEnd : wordEnds[endIndex].doubleValue;
        if (!isfinite(start) || start < segmentStart) { start = segmentStart; }
        if (!isfinite(end) || end > segmentEnd) { end = segmentEnd; }
        BrowserSubtitleCue *previous = cues.lastObject;
        if (previous != nil && start < previous.end) {
            start = previous.end;
        }
        [cues addObject:[[BrowserSubtitleCue alloc] initWithStart:start end:MAX(end, start + 0.3)
                                                             text:[pieceWords componentsJoinedByString:@" "]]];
        pieceStart = endIndex + 1;
        length = 0;
        bestBreak = -1;
        // Wörter zwischen Trennstelle und aktuellem Wort zählen schon zum nächsten Stück.
        for (NSUInteger r = pieceStart; r <= w && r < words.count; r++) {
            length += (length > 0 ? 1 : 0) + words[r].length;
        }
    }
    return cues;
}
#endif

/// Text der Untertitel, die kurz vor `time` enden (höchstens ≈ 200 Zeichen, nur aus den letzten 12 s), nur solche,
/// die whisper in `language` erkannt hat (nach einem Rückfall stehen sonst übersetzte Sätze im englischen Kontext).
- (NSString *)contextBeforeTime:(NSTimeInterval)time language:(NSString *)language {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesNoContext"]) {
        return @"";   // Vergleichsmessung ohne Satzkontext
    }
    // Übersetzen durch whisper (feste Sprache ≠ gesprochene, oder noch nicht geprüft): ohne Kontext. Im Simulator
    // gemessen (Tears of Steel, englisch, Untertitel Deutsch): mit Kontext verfiel whisper in Schleifen („… nicht mehr
    // hier“, dann nur „Und“) und ließ ganze Sätze aus; ohne Kontext kamen deutlich mehr und vollständigere Sätze.
    // Erkennt whisper in der gesprochenen Sprache (Apple übersetzt danach), ist es wieder reines Erkennen: mit Kontext.
    if ([language isEqualToString:@"auto"]) {
        // Sprache noch nicht festgelegt: kein Kontext. Sonst trägt er eine Fehlerkennung des Anfangs weiter (Live-HLS
        // im Simulator: erster kurzer Abschnitt über Musik „Thank you.“, danach jeder Abschnitt „Thank you.“).
        return @"";
    }
    if (self.lockedLanguage == nil) {
        NSString *spoken = self.spokenLanguage;
        if (spoken == nil || ![spoken isEqualToString:language]) {
            return @"";
        }
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger length = 0;
    for (BrowserSubtitleCue *cue in self.recentCues.reverseObjectEnumerator) {
        if (cue.end > time + 0.3 || cue.end < time - 12.0) {
            continue;
        }
        if (cue.language != nil && ![cue.language isEqualToString:language]) {
            break;   // davor in einer anderen Sprache erkannt (Rückfall whisper): nicht mischen
        }
        if (length + cue.text.length > 200) {
            break;
        }
        [parts insertObject:cue.text atIndex:0];
        length += cue.text.length + 1;
    }
    // Lauter gleiche Sätze (typisch erfundenes „Thank you.“, „Vielen Dank.“ über Musik): nicht weitergeben.
    NSSet *distinct = [NSSet setWithArray:[parts valueForKey:@"lowercaseString"]];
    if (parts.count >= 2 && distinct.count == 1) {
        return @"";
    }
    return [parts componentsJoinedByString:@" "];
}

- (void)rememberCues:(NSArray<BrowserSubtitleCue *> *)cues windowStart:(NSTimeInterval)windowStart {
    if (self.recentCues == nil) {
        self.recentCues = [NSMutableArray array];
    }
    // Ältere Fassung desselben Bereichs (Mithören rechnet ihn neu) ersetzen.
    NSIndexSet *stale = [self.recentCues indexesOfObjectsPassingTest:^BOOL(BrowserSubtitleCue *cue, NSUInteger index, BOOL *stop) {
        return cue.start >= windowStart - 0.05;
    }];
    [self.recentCues removeObjectsAtIndexes:stale];
    [self.recentCues addObjectsFromArray:cues];
    [self.recentCues sortUsingComparator:^NSComparisonResult(BrowserSubtitleCue *a, BrowserSubtitleCue *b) {
        return [@(a.start) compare:@(b.start)];
    }];
    if (self.recentCues.count > 40) {
        [self.recentCues removeObjectsInRange:NSMakeRange(0, self.recentCues.count - 40)];
    }
}

#if BROWSER_HAS_WHISPER
/// Feste Untertitelsprache: gesprochene Sprache vor dem Erkennen bestimmen (Mel-Daten des Abschnitts, ein zusätzlicher
/// Encoder-Lauf), nur bis sie feststeht: zwei gleiche Stimmen oder höchstens sechs Versuche. Eine Stimme zählt nur bei
/// p ≥ 0,6 und mindestens 5 s Ton (DW-Livestream: Musik-Einstieg 3,6 s → „sw“ p 0,81, danach 11 s → „sw“ p 0,52, fest
/// auf Suaheli, obwohl Englisch gesprochen wurde). Unsichere Ergebnisse gelten nur für den Abschnitt. Gibt die festgestellte
/// Sprache zurück, sonst die dieses Abschnitts (nil bei zu kurzem Abschnitt oder nach sechs Versuchen ohne Ergebnis).
/// Vorher lief die Prüfung nach dem Erkennen; jetzt entscheidet sie schon für diesen Abschnitt, ob whisper in der
/// gesprochenen Sprache erkennt und Apple übersetzt (BrowserSubtitleTranslator) oder whisper selbst übersetzt.
- (nullable NSString *)spokenLanguageForSamples:(const float *)samples count:(NSUInteger)count seconds:(double)seconds
                               decodingLanguage:(NSString *)decodingLanguage threads:(int)threads {
    if (self.spokenLanguage != nil) {
        return self.spokenLanguage;
    }
    if ([decodingLanguage isEqualToString:@"auto"] || self.lockedLanguage != nil || seconds < 2.5 || self.spokenChecks >= 6) {
        return nil;
    }
    self.spokenChecks += 1;
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    if (whisper_pcm_to_mel_with_state(_context, _state, samples, (int)count, threads) != 0) {
        return nil;
    }
    float probabilities[128] = {0};
    int maxId = whisper_lang_max_id();
    int lang = whisper_lang_auto_detect_with_state(_context, _state, 0, threads, maxId < 128 ? probabilities : NULL);
    const char *name = lang >= 0 ? whisper_lang_str(lang) : NULL;
    if (name == NULL) {
        return nil;
    }
    NSString *spoken = [NSString stringWithUTF8String:name];
    float probability = maxId < 128 ? probabilities[lang] : 1.0f;
    BOOL vote = probability >= 0.6f && seconds >= 5.0;
    if (self.spokenVotes == nil) {
        self.spokenVotes = [NSCountedSet set];
    }
    if (vote) {
        [self.spokenVotes addObject:spoken];
    }
    if ([self.spokenVotes countForObject:spoken] >= 2) {
        self.spokenLanguage = spoken;
    }
    NSLog(@"%@ gesprochene Sprache %@ (p %.2f, %.2f s)%@", kSubtitleLogPrefix, spoken,
          maxId < 128 ? probabilities[lang] : -1.0f, CFAbsoluteTimeGetCurrent() - begin,
          self.spokenLanguage == nil ? (vote ? @" (noch nicht festgelegt)" : @" (unsicher, keine Stimme)") : ([spoken isEqualToString:decodingLanguage]
              ? @" = Untertitelsprache: mit Satzkontext"
              : [NSString stringWithFormat:@" ≠ %@ festgelegt", decodingLanguage]));
    return spoken;
}
#endif

- (NSArray<BrowserSubtitleCue *> *)transcribeSamples:(const float *)samples count:(NSUInteger)count startTime:(NSTimeInterval)startTime {
#if BROWSER_HAS_WHISPER
    if (_state == NULL || samples == NULL || count < 1600) {
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

    // Silero: Stücke mit Sprache (Zeiten im Video). Keins → whisper gar nicht erst rechnen lassen.
    NSMutableArray<NSArray<NSNumber *> *> *speech = nil;
    if (_vad != NULL) {
        CFAbsoluteTime vadBegin = CFAbsoluteTimeGetCurrent();
        struct whisper_vad_params vadParams = whisper_vad_default_params();
        // Schwelle 0,35 statt 0,5: gerufene Sätze über Musik („Go! Move your asses!“) hört Silero sonst nicht.
        double threshold = [NSUserDefaults.standardUserDefaults doubleForKey:@"SubtitlesVADThreshold"];
        vadParams.threshold = threshold > 0.0 ? (float)threshold : 0.35f;
        vadParams.min_speech_duration_ms = 150;
        vadParams.min_silence_duration_ms = 200;
        vadParams.speech_pad_ms = 200;
        struct whisper_vad_segments *segments = whisper_vad_segments_from_samples(_vad, vadParams, samples, (int)count);
        if (segments != NULL) {
            speech = [NSMutableArray array];
            int n = whisper_vad_segments_n_segments(segments);
            for (int i = 0; i < n; i++) {
                [speech addObject:@[@(startTime + whisper_vad_segments_get_segment_t0(segments, i) / 100.0),
                                    @(startTime + whisper_vad_segments_get_segment_t1(segments, i) / 100.0)]];
            }
            whisper_vad_free_segments(segments);
            if (n == 0) {
                NSLog(@"%@ Abschnitt %.1f s @ %.1f s: Silero hört keine Sprache (%.2f s), übersprungen", kSubtitleLogPrefix,
                      seconds, startTime, CFAbsoluteTimeGetCurrent() - vadBegin);
                return @[];
            }
        }
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
    // Feste Untertitelsprache ≠ gesprochene: whisper erkennt in der gesprochenen Sprache, Apple übersetzt die fertigen
    // Sätze danach (Pipeline, BrowserSubtitleTranslator). Geht das nicht (Paar fehlt, offline, Rückfall nach Fehler),
    // „übersetzt“ whisper wie bisher selbst: es rechnet fest in der Untertitelsprache.
    NSString *translateFrom = nil;
    if (![decodingLanguage isEqualToString:@"auto"] && [BrowserSubtitleEngine isMultilingualModelName:self.modelPath.lastPathComponent]) {
        NSString *spoken = [self spokenLanguageForSamples:samples count:count seconds:seconds decodingLanguage:decodingLanguage
                                                  threads:params.n_threads];
        if (spoken != nil && ![spoken isEqualToString:decodingLanguage] &&
            [BrowserSubtitleTranslator.sharedTranslator canTranslateFrom:spoken to:decodingLanguage]) {
            translateFrom = spoken;
        }
        if (spoken != nil && ![spoken isEqualToString:decodingLanguage] && ![(translateFrom ?: @"") isEqualToString:self.lastTranslateFrom ?: @"-"]) {
            NSLog(@"%@ %@", kSubtitleLogPrefix, translateFrom != nil
                  ? [NSString stringWithFormat:@"Apple-Übersetzung: whisper erkennt %@, Apple übersetzt nach %@", spoken, decodingLanguage]
                  : [NSString stringWithFormat:@"Rückfall whisper: whisper übersetzt %@ → %@ selbst (Apple %@)", spoken, decodingLanguage,
                     [NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesNoAppleTranslation"] ? @"abgeschaltet"
                     : (BrowserSubtitleTranslator.sharedTranslator.suspended ? @"nach Fehler ausgesetzt" : @"nicht verfügbar")]);
        }
        if (spoken != nil && ![spoken isEqualToString:decodingLanguage]) {
            self.lastTranslateFrom = translateFrom ?: @"";
        }
    }
    NSString *whisperLanguage = translateFrom ?: decodingLanguage;
    _splitCharacters = translateFrom != nil ? 150 : kBrowserSubtitleMaxCueCharacters;
    params.language = whisperLanguage.UTF8String;
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
    // Zeitmarken je Token: lange Segmente werden in untertitelgroße Stücke mit eigener Zeit geteilt (sonst stünde das
    // Ende eines 8-s-Satzes schon am Satzanfang im Bild).
    params.token_timestamps = true;
    // Satzkontext: der zuletzt erkannte Satz direkt vor diesem Abschnitt als Vorgabe (initial prompt). Hilft bei
    // Abschnitten, die mitten im Gedanken beginnen (Mithören, Vorauslesen nach einer Satzpause). Nicht, wenn whisper
    // selbst übersetzt (feste Sprache ≠ gesprochene), dort schadet er (siehe contextBeforeTime:language:).
    __attribute__((objc_precise_lifetime)) NSString *context = [self contextBeforeTime:startTime language:whisperLanguage];
    params.initial_prompt = context.length > 0 ? context.UTF8String : NULL;
    params.abort_callback = BrowserWhisperAbort;
    params.abort_callback_user_data = &_abortFlag;

    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    int result = whisper_full_with_state(_context, _state, params, samples, (int)count);
    double compute = CFAbsoluteTimeGetCurrent() - begin;
    if (result != 0) {
        NSLog(@"%@ whisper_full Fehler %d (abgebrochen=%d)", kSubtitleLogPrefix, result, atomic_load(&_abortFlag));
        return nil;
    }
    _totalCompute += compute;
    _totalAudio += seconds;

    NSString *windowLanguage = nil;
    if ([decodingLanguage isEqualToString:@"auto"]) {
        const char *lang = whisper_lang_str(whisper_full_lang_id_from_state(_state));
        if (lang != NULL) {
            windowLanguage = [NSString stringWithUTF8String:lang];
            self.detectedLanguage = windowLanguage;
        }
    }

    NSMutableArray<BrowserSubtitleCue *> *cues = [NSMutableArray array];
    int segments = whisper_full_n_segments_from_state(_state);
    for (int i = 0; i < segments; i++) {
        const char *rawText = whisper_full_get_segment_text_from_state(_state, i);
        NSString *text = rawText != NULL ? [[NSString stringWithUTF8String:rawText] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
        float noSpeech = whisper_full_get_segment_no_speech_prob_from_state(_state, i);
        if (BrowserSubtitleIsNoiseText(text) || noSpeech > 0.8f) {
            // Verworfene Segmente sichtbar machen: lange Rechenzeiten bei „0 Segmente“ kommen von erfundenem Text
            // (Musik), den whisper bis zur Token-Grenze ausschreibt.
            NSString *shown = text.length > 60 ? [[text substringToIndex:60] stringByAppendingString:@"…"] : text;
            NSLog(@"%@ Segment verworfen (no_speech %.2f, %d Tokens): %@", kSubtitleLogPrefix, noSpeech,
                  whisper_full_n_tokens_from_state(_state, i), shown);
            continue;
        }
        NSTimeInterval t0 = startTime + whisper_full_get_segment_t0_from_state(_state, i) / 100.0;
        NSTimeInterval t1 = startTime + whisper_full_get_segment_t1_from_state(_state, i) / 100.0;
        t1 = MIN(t1, startTime + seconds);
        t0 = MIN(t0, t1 - 0.2);
        [cues addObjectsFromArray:[self cuesForSegment:i text:text start:t0 end:t1 windowStart:startTime windowEnd:startTime + seconds]];
    }
    if (speech.count > 0) {
        // Untertitel, unter denen Silero keine Sprache hört (Musik, Geräusche), sind erfunden.
        NSIndexSet *silent = [cues indexesOfObjectsPassingTest:^BOOL(BrowserSubtitleCue *cue, NSUInteger index, BOOL *stop) {
            double overlap = 0.0;
            for (NSArray<NSNumber *> *range in speech) {
                overlap += MAX(0.0, MIN(cue.end, range[1].doubleValue) - MAX(cue.start, range[0].doubleValue));
            }
            return overlap < MIN(0.3, 0.25 * (cue.end - cue.start));
        }];
        for (BrowserSubtitleCue *cue in [cues objectsAtIndexes:silent]) {
            NSLog(@"%@ Silero: keine Sprache unter %.2f–%.2f s, verworfen: %@", kSubtitleLogPrefix, cue.start, cue.end, cue.text);
        }
        [cues removeObjectsAtIndexes:silent];
    }
    if (context.length > 0) {
        // whisper schreibt gern den Kontext ab („Ich bin der Nal, das war schön“ in jedem Abschnitt): Sätze, die
        // vollständig im Kontext stehen, verwerfen (auch die Wiederholung des Überlappungsstücks).
        NSString *normalizedContext = BrowserSubtitleNormalizedText(context);
        NSIndexSet *copied = [cues indexesOfObjectsPassingTest:^BOOL(BrowserSubtitleCue *cue, NSUInteger index, BOOL *stop) {
            NSString *normalized = BrowserSubtitleNormalizedText(cue.text);
            return normalized.length >= 8 && [normalizedContext containsString:normalized];
        }];
        for (BrowserSubtitleCue *cue in [cues objectsAtIndexes:copied]) {
            NSLog(@"%@ aus dem Kontext abgeschrieben, verworfen: %@", kSubtitleLogPrefix, cue.text);
        }
        [cues removeObjectsAtIndexes:copied];
    }
    // Nach dem Zusammenlegen noch einmal: aus einzelnen „Wir.“-Segmenten wird sonst „Wir. Wir. Wir. …“.
    cues = [BrowserSubtitleRemoveRepeats(BrowserSubtitleMergeShortCues(BrowserSubtitleRemoveRepeats(cues), kBrowserSubtitleMaxCueCharacters)) mutableCopy];
    for (BrowserSubtitleCue *cue in cues) {
        cue.language = windowLanguage ?: whisperLanguage;
        cue.translationTarget = translateFrom != nil ? decodingLanguage : nil;
    }
    [self rememberCues:cues windowStart:startTime];
    if (windowLanguage != nil && cues.count > 0 && seconds >= 2.5) {
        // nur Abschnitte mit Sprache zählen (nicht Musik/Stille) und nicht die kurzen Teilabschnitte des Mithörens
        [self voteForDetectedLanguage:windowLanguage];
    }
    NSLog(@"%@ Abschnitt %.1f s @ %.1f s: %lu Segmente in %.2f s (RTF %.2f, Schnitt %.2f), ctx %d, Silero %ld Stücke, Kontext %lu Z., Sprache %@%@, Speicher %.0f MB%@%@",
          kSubtitleLogPrefix, seconds, startTime, (unsigned long)cues.count, compute, compute / seconds,
          self.averageRealTimeFactor, params.audio_ctx, speech != nil ? (long)speech.count : -1L, (unsigned long)context.length, self.detectedLanguage,
          translateFrom != nil ? [NSString stringWithFormat:@" (erkannt %@, Apple-Übersetzung folgt)", translateFrom] : @"",
          [BrowserSubtitleEngine currentMemoryFootprintMB],
          cues.count > 0 ? @" – " : @"", cues.count > 0 ? [[cues valueForKey:@"text"] componentsJoinedByString:@" | "] : @"");
    return cues;
#else
    (void)samples; (void)count; (void)startTime;
    return nil;
#endif
}

@end
