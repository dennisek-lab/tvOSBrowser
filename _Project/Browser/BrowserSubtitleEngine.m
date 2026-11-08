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
        _shownAt = NAN;
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
/// Bei fest eingestellter Untertitelsprache: die tatsächlich gesprochene (whisper_lang_auto_detect auf den ersten
/// Abschnitten mit Sprache). Weicht sie ab, übersetzt whisper – dann ohne Satzkontext (siehe contextBeforeTime:).
@property (atomic, copy, nullable) NSString *spokenLanguage;
@property (nonatomic, strong) NSCountedSet<NSString *> *spokenVotes;
@property (nonatomic) NSUInteger spokenChecks;
@property (nonatomic) NSUInteger speechWindows;
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
/// Zeilen passt. Sonst stünde „getötet.“ nur eine Sekunde da. Das zweite Stück erscheint dadurch höchstens ≈ 2 s vor
/// seinem Sprechbeginn (wie bei rollenden Live-Untertiteln), der Anfang bleibt exakt.
static NSArray<BrowserSubtitleCue *> *BrowserSubtitleMergeShortCues(NSArray<BrowserSubtitleCue *> *cues, NSUInteger maxCharacters) {
    NSMutableArray<BrowserSubtitleCue *> *merged = [NSMutableArray arrayWithCapacity:cues.count];
    for (BrowserSubtitleCue *cue in cues) {
        BrowserSubtitleCue *previous = merged.lastObject;
        if (previous != nil) {
            NSTimeInterval previousDuration = previous.end - previous.start;
            BOOL previousShort = previousDuration < 2.0 || previous.text.length < 28;
            BOOL cueShort = cue.end - cue.start < 1.5 || cue.text.length < 20;
            BOOL fits = previous.text.length + 1 + cue.text.length <= maxCharacters;
            BOOL close = cue.start - previous.end < 1.0 && cue.end - previous.start <= 8.0 && previousDuration < 2.5;
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
static const NSUInteger kBrowserSubtitleMinSentenceCharacters = 24;

/// Teilt ein whisper-Segment in Untertitel: an Satzenden (ab 24 Zeichen), sonst spätestens nach ≈ 84 Zeichen an einer
/// Wortgrenze (bevorzugt nach Komma). Zeiten aus den Token-Zeitmarken; das erste Stück beginnt mit dem Segment.
- (NSArray<BrowserSubtitleCue *> *)cuesForSegment:(int)segment text:(NSString *)text start:(NSTimeInterval)segmentStart
                                              end:(NSTimeInterval)segmentEnd windowStart:(NSTimeInterval)windowStart {
    if (text.length <= kBrowserSubtitleMaxCueCharacters && segmentEnd - segmentStart <= 7.0) {
        return @[[[BrowserSubtitleCue alloc] initWithStart:segmentStart end:segmentEnd text:text]];
    }
    whisper_token eot = whisper_token_eot(_context);
    int tokens = whisper_full_n_tokens(_context, segment);
    // Wörter bilden (Token mit führendem Leerzeichen beginnen ein Wort; Bytes erst am Wortende als UTF-8 lesen).
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    NSMutableArray<NSNumber *> *wordStarts = [NSMutableArray array];
    NSMutableArray<NSNumber *> *wordEnds = [NSMutableArray array];
    NSMutableData *bytes = [NSMutableData data];
    double wordStart = NAN, wordEnd = NAN;
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
        whisper_token_data data = whisper_full_get_token_data(_context, segment, k);
        if (data.id >= eot) {
            continue;  // Zeitmarken und Steuertokens
        }
        const char *piece = whisper_full_get_token_text(_context, segment, k);
        if (piece == NULL || piece[0] == 0) {
            continue;
        }
        if (piece[0] == ' ' && bytes.length > 0) {
            finishWord();
        }
        if (bytes.length == 0) {
            wordStart = windowStart + data.t0 / 100.0;
        }
        wordEnd = windowStart + data.t1 / 100.0;
        [bytes appendBytes:piece length:strlen(piece)];
    }
    if (bytes.length > 0) {
        finishWord();
    }
    if (words.count < 2) {
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
        } else if (!lastWord && length + 1 + words[w + 1].length > kBrowserSubtitleMaxCueCharacters) {
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

/// Text der Untertitel, die kurz vor `time` enden (höchstens ≈ 200 Zeichen, nur aus den letzten 12 s).
- (NSString *)contextBeforeTime:(NSTimeInterval)time {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SubtitlesNoContext"]) {
        return @"";   // Vergleichsmessung ohne Satzkontext
    }
    // Übersetzen (feste Sprache ≠ gesprochene, oder noch nicht geprüft): ohne Kontext. Im Simulator gemessen
    // (Tears of Steel, englisch, Untertitel Deutsch): mit Kontext verfiel whisper in Schleifen („… nicht mehr hier“,
    // dann nur „Und“) und ließ ganze Sätze aus; ohne Kontext kamen deutlich mehr und vollständigere Sätze.
    NSString *decoding = [self decodingLanguage];
    if (![decoding isEqualToString:@"auto"] && self.lockedLanguage == nil) {
        NSString *spoken = self.spokenLanguage;
        if (spoken == nil || ![spoken isEqualToString:decoding]) {
            return @"";
        }
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSUInteger length = 0;
    for (BrowserSubtitleCue *cue in self.recentCues.reverseObjectEnumerator) {
        if (cue.end > time + 0.3 || cue.end < time - 12.0) {
            continue;
        }
        if (length + cue.text.length > 200) {
            break;
        }
        [parts insertObject:cue.text atIndex:0];
        length += cue.text.length + 1;
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
/// Feste Untertitelsprache: gesprochene Sprache auf den Mel-Daten des eben ausgewerteten Abschnitts bestimmen (ein
/// zusätzlicher Encoder-Lauf, nur bis feststeht: zwei gleiche Ergebnisse oder höchstens sechs Versuche).
- (void)checkSpokenLanguageAfterWindowOfSeconds:(double)seconds decodingLanguage:(NSString *)decodingLanguage threads:(int)threads {
    if ([decodingLanguage isEqualToString:@"auto"] || self.lockedLanguage != nil || self.spokenLanguage != nil ||
        seconds < 2.5 || self.spokenChecks >= 6) {
        return;
    }
    self.spokenChecks += 1;
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    int lang = whisper_lang_auto_detect(_context, 0, threads, NULL);
    const char *name = lang >= 0 ? whisper_lang_str(lang) : NULL;
    if (name == NULL) {
        return;
    }
    NSString *spoken = [NSString stringWithUTF8String:name];
    if (self.spokenVotes == nil) {
        self.spokenVotes = [NSCountedSet set];
    }
    [self.spokenVotes addObject:spoken];
    if ([self.spokenVotes countForObject:spoken] >= 2) {
        self.spokenLanguage = spoken;
    }
    NSLog(@"%@ gesprochene Sprache %@ (%.2f s)%@", kSubtitleLogPrefix, spoken, CFAbsoluteTimeGetCurrent() - begin,
          self.spokenLanguage == nil ? @"" : ([spoken isEqualToString:decodingLanguage]
              ? @" = Untertitelsprache: mit Satzkontext"
              : [NSString stringWithFormat:@" ≠ %@: whisper übersetzt, ohne Satzkontext", decodingLanguage]));
}
#endif

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
    // Zeitmarken je Token: lange Segmente werden in untertitelgroße Stücke mit eigener Zeit geteilt (sonst stünde das
    // Ende eines 8-s-Satzes schon am Satzanfang im Bild).
    params.token_timestamps = true;
    // Satzkontext: der zuletzt erkannte Satz direkt vor diesem Abschnitt als Vorgabe (initial prompt). Hilft bei
    // Abschnitten, die mitten im Gedanken beginnen (Mithören, Vorauslesen nach einer Satzpause). Nicht beim Übersetzen
    // (feste Sprache ≠ gesprochene), dort schadet er (siehe contextBeforeTime:).
    __attribute__((objc_precise_lifetime)) NSString *context = [self contextBeforeTime:startTime];
    params.initial_prompt = context.length > 0 ? context.UTF8String : NULL;
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

    [self checkSpokenLanguageAfterWindowOfSeconds:seconds decodingLanguage:decodingLanguage threads:params.n_threads];

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
        t0 = MIN(t0, t1 - 0.2);
        [cues addObjectsFromArray:[self cuesForSegment:i text:text start:t0 end:t1 windowStart:startTime]];
    }
    cues = [BrowserSubtitleMergeShortCues(BrowserSubtitleRemoveRepeats(cues), kBrowserSubtitleMaxCueCharacters) mutableCopy];
    [self rememberCues:cues windowStart:startTime];
    if (windowLanguage != nil && cues.count > 0 && seconds >= 2.5) {
        // nur Abschnitte mit Sprache zählen (nicht Musik/Stille) und nicht die kurzen Teilabschnitte des Mithörens
        [self voteForDetectedLanguage:windowLanguage];
    }
    NSLog(@"%@ Abschnitt %.1f s @ %.1f s: %lu Segmente in %.2f s (RTF %.2f, Schnitt %.2f), ctx %d, Kontext %lu Z., Sprache %@, Speicher %.0f MB%@%@",
          kSubtitleLogPrefix, seconds, startTime, (unsigned long)cues.count, compute, compute / seconds,
          self.averageRealTimeFactor, params.audio_ctx, (unsigned long)context.length, self.detectedLanguage,
          [BrowserSubtitleEngine currentMemoryFootprintMB],
          cues.count > 0 ? @" – " : @"", cues.count > 0 ? [[cues valueForKey:@"text"] componentsJoinedByString:@" | "] : @"");
    return cues;
#else
    (void)samples; (void)count; (void)startTime;
    return nil;
#endif
}

@end
