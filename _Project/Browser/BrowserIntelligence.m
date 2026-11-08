//
//  BrowserIntelligence.m
//  Browser
//

#import "BrowserIntelligence.h"
#import "BrowserReaderMode.h"
#import "BrowserWebView.h"
#import <NaturalLanguage/NaturalLanguage.h>

NSString * const BrowserIntelligenceErrorDomain = @"BrowserIntelligence";
static NSString * const kDeclinedHostsKey = @"TranslateDeclinedHosts";

@implementation BrowserAISummary
@end

@implementation BrowserPageLanguageInfo
@end

#pragma mark - NaturalLanguage-Anbieter

/// Ein Satz aus dem Artikel mit allem, was die Bewertung braucht.
@interface BrowserNLSentence : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSRange range;
@property (nonatomic) NSUInteger index;          ///< laufende Nummer aller Sätze (Position im Text)
@property (nonatomic) BOOL firstInParagraph;
@property (nonatomic) NSUInteger wordCount;
@property (nonatomic, strong) NSMutableSet<NSString *> *terms; ///< Lemmata der Inhaltswörter
@property (nonatomic, strong, nullable) NSData *vector;          ///< normierter Satzvektor (float)
@property (nonatomic) double centrality;
@property (nonatomic) double termScore;
@property (nonatomic) double positionScore;
@property (nonatomic) double score;
@end

@implementation BrowserNLSentence
@end

/// Lokaler Anbieter: Zusammenfassen extraktiv (Satz-Embedding-Zentralität + TF-IDF-Zentroid + Position,
/// Auswahl mit MMR gegen Wiederholungen), Spracherkennung mit NLLanguageRecognizer.
@interface BrowserNLProvider : NSObject <BrowserAIProvider>
@property (nonatomic, strong) dispatch_queue_t workQueue;
/// Nur auf workQueue benutzen. Wert NSNull = Sprache hat kein Satz-Embedding.
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *sentenceEmbeddings;
@end

@implementation BrowserNLProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("io.github.tvosbrowser.app.intelligence", DISPATCH_QUEUE_SERIAL);
        _sentenceEmbeddings = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)providerName {
    return @"lokal";
}

- (BOOL)isAvailable {
    return YES;
}

- (NSString *)dominantLanguageForText:(NSString *)text confidence:(double *)confidence {
    if (confidence != NULL) {
        *confidence = 0.0;
    }
    if (text.length < 20) {
        return nil;
    }
    NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
    [recognizer processString:text.length > 4000 ? [text substringToIndex:4000] : text];
    NLLanguage language = recognizer.dominantLanguage;
    if (language == nil || [language isEqualToString:NLLanguageUndetermined]) {
        return nil;
    }
    NSNumber *probability = [recognizer languageHypothesesWithMaximum:3][language];
    if (confidence != NULL) {
        *confidence = probability.doubleValue;
    }
    return language;
}

/// Satz-Embedding der Sprache (zwischengespeichert, auf workQueue).
- (NLEmbedding *)sentenceEmbeddingForLanguage:(NSString *)language {
    if (language.length == 0) {
        return nil;
    }
    id cached = self.sentenceEmbeddings[language];
    if (cached == nil) {
        cached = [NLEmbedding sentenceEmbeddingForLanguage:language] ?: (id)NSNull.null;
        self.sentenceEmbeddings[language] = cached;
    }
    return [cached isKindOfClass:NLEmbedding.class] ? cached : nil;
}

/// Kontextuelles Embedding (BERT-artig, tvOS 17+) als Ersatz, wenn die Sprache kein Satz-Embedding hat
/// (im tvOS-27.2-Simulator z. B. Deutsch). Nur wenn die Modelldaten schon auf dem Gerät liegen; geladen bleibt es
/// bis zum Ende der App. Auf workQueue.
- (id)contextualEmbeddingForLanguage:(NSString *)language API_AVAILABLE(tvos(17.0)) {
    if (language.length == 0) {
        return nil;
    }
    NSString *key = [@"ctx:" stringByAppendingString:language];
    id cached = self.sentenceEmbeddings[key];
    if (cached == nil) {
        NLContextualEmbedding *embedding = [NLContextualEmbedding contextualEmbeddingWithLanguage:language];
        NSError *error = nil;
        if (embedding == nil || !embedding.hasAvailableAssets || ![embedding loadWithError:&error]) {
            NSLog(@"[AI] kontextuelles Embedding %@ nicht nutzbar (%@)", language,
                  embedding == nil ? @"keins" : (!embedding.hasAvailableAssets ? @"Modelldaten fehlen" : error.localizedDescription));
            cached = NSNull.null;
            // Beim nächsten Mal erneut prüfen, falls der Download inzwischen fertig ist.
            if (embedding != nil && !embedding.hasAvailableAssets) {
                [embedding requestEmbeddingAssetsWithCompletionHandler:^(NLContextualEmbeddingAssetsResult result, NSError *requestError) {
                    NSLog(@"[AI] Modelldaten %@ angefordert: Ergebnis=%ld %@", language, (long)result, requestError.localizedDescription ?: @"");
                    dispatch_async(self.workQueue, ^{
                        [self.sentenceEmbeddings removeObjectForKey:key];
                    });
                }];
            }
        } else {
            cached = embedding;
        }
        self.sentenceEmbeddings[key] = cached;
    }
    return [cached isKindOfClass:NLContextualEmbedding.class] ? cached : nil;
}

/// Satzvektor aus dem kontextuellen Embedding: Mittelwert der Token-Vektoren.
static NSData *BrowserNLContextualVector(NLContextualEmbedding *embedding, NSString *text, NSString *language) API_AVAILABLE(tvos(17.0)) {
    NSError *error = nil;
    NLContextualEmbeddingResult *result = [embedding embeddingResultForString:text language:language error:&error];
    if (result == nil) {
        return nil;
    }
    NSUInteger dimension = embedding.dimension;
    double *sum = calloc(dimension, sizeof(double));
    __block NSUInteger tokens = 0;
    [result enumerateTokenVectorsInRange:NSMakeRange(0, text.length) usingBlock:^(NSArray<NSNumber *> *vector, __unused NSRange range, __unused BOOL *stop) {
        if (vector.count != dimension) {
            return;
        }
        for (NSUInteger i = 0; i < dimension; i++) {
            sum[i] += vector[i].doubleValue;
        }
        tokens++;
    }];
    NSData *data = nil;
    if (tokens > 0) {
        float *mean = calloc(dimension, sizeof(float));
        for (NSUInteger i = 0; i < dimension; i++) {
            mean[i] = (float)(sum[i] / (double)tokens);
        }
        data = BrowserNLNormalizedVector(mean, dimension);
        free(mean);
    }
    free(sum);
    return data;
}

/// Der Satz-Tokenizer trennt deutsche Ordnungszahlen und Abkürzungen ("am 13. September", "z. B.", "Nr. 5"):
/// solche Stücke an den vorigen Satz hängen.
static BOOL BrowserNLShouldJoinSentences(NSString *previous, NSString *next) {
    static NSRegularExpression *abbreviation;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        abbreviation = [NSRegularExpression regularExpressionWithPattern:
            @"(^|[\\s(])([0-9]{1,2}|[A-Za-zÄÖÜ]|z\\. ?B|d\\. ?h|u\\. ?a|bzw|ca|vgl|Nr|Dr|Prof|St|Jh|Jhd|usw|etc|bspw|evtl|ggf|inkl|sog|Mio|Mrd|Abs|Bd|Hrsg)\\.$"
                                                                 options:0 error:nil];
    });
    if (previous.length == 0 || next.length == 0) {
        return NO;
    }
    unichar first = [next characterAtIndex:0];
    if ([NSCharacterSet.lowercaseLetterCharacterSet characterIsMember:first]) {
        return YES;
    }
    return [abbreviation firstMatchInString:previous options:0 range:NSMakeRange(0, previous.length)] != nil;
}

static BOOL BrowserNLSentenceLooksUsable(NSString *sentence, NSUInteger words) {
    NSUInteger length = sentence.length;
    if (length < 40 || length > 420 || words < 6) {
        return NO;
    }
    unichar last = [sentence characterAtIndex:length - 1];
    NSCharacterSet *terminal = [NSCharacterSet characterSetWithCharactersInString:@".!?…\"“”»«’'"];
    if (![terminal characterIsMember:last]) {
        return NO; // Listenpunkte, Überschriften, Bildunterschriften ohne Satzende
    }
    NSUInteger letters = 0;
    NSCharacterSet *letterSet = NSCharacterSet.letterCharacterSet;
    for (NSUInteger i = 0; i < length; i++) {
        if ([letterSet characterIsMember:[sentence characterAtIndex:i]]) {
            letters++;
        }
    }
    if (letters < length * 0.6) {
        return NO;
    }
    // Seitenbausteine (Folgen, Abo, Newsletter, Cookies), die Readability manchmal mitnimmt.
    static NSRegularExpression *boilerplate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        boilerplate = [NSRegularExpression regularExpressionWithPattern:
            @"(follow (topics|us|authors)|sign up|subscribe|newsletter|we use cookies|wir verwenden cookies|all rights reserved|read more|click here|share this|"
             "folgen sie|abonnier|weiterlesen|mehr zum thema|alle rechte|melden sie sich)"
                                                                options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return [boilerplate firstMatchInString:sentence options:0 range:NSMakeRange(0, length)] == nil;
}

static double BrowserNLDot(NSData *a, NSData *b) {
    if (a == nil || b == nil || a.length != b.length) {
        return 0.0;
    }
    const float *x = a.bytes;
    const float *y = b.bytes;
    NSUInteger n = a.length / sizeof(float);
    double sum = 0.0;
    for (NSUInteger i = 0; i < n; i++) {
        sum += (double)x[i] * (double)y[i];
    }
    return sum;
}

static NSData *BrowserNLNormalizedVector(const float *values, NSUInteger count) {
    double norm = 0.0;
    for (NSUInteger i = 0; i < count; i++) {
        norm += (double)values[i] * (double)values[i];
    }
    norm = sqrt(norm);
    if (norm < 1e-9) {
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:count * sizeof(float)];
    float *out = data.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) {
        out[i] = (float)(values[i] / norm);
    }
    return data;
}

static void BrowserNLMinMax(NSArray<BrowserNLSentence *> *sentences, NSString *key) {
    double lo = DBL_MAX, hi = -DBL_MAX;
    for (BrowserNLSentence *s in sentences) {
        double v = [[s valueForKey:key] doubleValue];
        lo = MIN(lo, v);
        hi = MAX(hi, v);
    }
    for (BrowserNLSentence *s in sentences) {
        double v = [[s valueForKey:key] doubleValue];
        [s setValue:@(hi - lo > 1e-9 ? (v - lo) / (hi - lo) : 0.5) forKey:key];
    }
}

static double BrowserNLJaccard(NSSet<NSString *> *a, NSSet<NSString *> *b) {
    if (a.count == 0 || b.count == 0) {
        return 0.0;
    }
    NSMutableSet *inter = [a mutableCopy];
    [inter intersectSet:b];
    return (double)inter.count / (double)(a.count + b.count - inter.count);
}

- (void)summarizeText:(NSString *)text
                title:(NSString *)title
         maxSentences:(NSUInteger)maxSentences
           completion:(void (^)(BrowserAISummary *, NSError *))completion {
    dispatch_async(self.workQueue, ^{
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSError *error = nil;
        BrowserAISummary *summary = [self summarySyncForText:text title:title maxSentences:maxSentences error:&error];
        summary.duration = CFAbsoluteTimeGetCurrent() - start;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(summary, summary == nil ? error : nil);
        });
    });
}

- (BrowserAISummary *)summarySyncForText:(NSString *)rawText
                                   title:(NSString *)title
                            maxSentences:(NSUInteger)maxSentences
                                   error:(NSError **)error {
    // Fußnotenzeichen [1], [12] und doppelte Leerzeichen entfernen; Absätze (Leerzeile) bleiben.
    NSString *text = [rawText stringByReplacingOccurrencesOfString:@"\\[[0-9]{1,3}\\]" withString:@""
                                                           options:NSRegularExpressionSearch range:NSMakeRange(0, rawText.length)];
    text = [text stringByReplacingOccurrencesOfString:@"[ \\t\\u00a0]+" withString:@" "
                                              options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
    double confidence = 0.0;
    NSString *language = [self dominantLanguageForText:text confidence:&confidence];

    // 1. Sätze.
    NLTokenizer *tokenizer = [[NLTokenizer alloc] initWithUnit:NLTokenUnitSentence];
    tokenizer.string = text;
    if (language != nil) {
        [tokenizer setLanguage:language];
    }
    NSMutableArray<BrowserNLSentence *> *all = [NSMutableArray array];
    [tokenizer enumerateTokensInRange:NSMakeRange(0, text.length) usingBlock:^(NSRange range, __unused NLTokenizerAttributes flags, __unused BOOL *stop) {
        NSString *sentence = [[text substringWithRange:range] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (sentence.length == 0) {
            return;
        }
        BrowserNLSentence *previous = all.lastObject;
        if (previous != nil && BrowserNLShouldJoinSentences(previous.text, sentence) &&
            ![[text substringWithRange:NSMakeRange(previous.range.location, range.location - previous.range.location)] containsString:@"\n"]) {
            previous.text = [NSString stringWithFormat:@"%@ %@", previous.text, sentence];
            previous.range = NSUnionRange(previous.range, range);
            return;
        }
        BrowserNLSentence *item = [BrowserNLSentence new];
        item.text = sentence;
        item.range = range;
        item.index = all.count;
        // Absatzanfang: zwischen dem Beginn des vorigen Satzes und diesem liegt ein Zeilenumbruch
        // (der Tokenizer hängt Leerraum und Umbrüche meist an den vorigen Satz).
        NSUInteger previousStart = all.count > 0 ? all.lastObject.range.location : 0;
        NSRange between = NSMakeRange(previousStart, range.location - MIN(range.location, previousStart));
        item.firstInParagraph = all.count == 0 || [[text substringWithRange:between] containsString:@"\n"];
        item.terms = [NSMutableSet set];
        [all addObject:item];
    }];

    // 2. Inhaltswörter (Nomen, Verben, Adjektive) als Lemma, einmal über den ganzen Text.
    NLTagger *tagger = [[NLTagger alloc] initWithTagSchemes:@[NLTagSchemeLexicalClass, NLTagSchemeLemma]];
    tagger.string = text;
    if (language != nil) {
        [tagger setLanguage:language range:NSMakeRange(0, text.length)];
    }
    NSSet<NLTag> *contentClasses = [NSSet setWithArray:@[NLTagNoun, NLTagVerb, NLTagAdjective, NLTagOtherWord]];
    __block NSUInteger sentenceCursor = 0;
    NSMutableDictionary<NSString *, NSNumber *> *documentFrequency = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *termFrequency = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *wordCounts = [NSMutableArray arrayWithCapacity:all.count];
    for (NSUInteger i = 0; i < all.count; i++) {
        [wordCounts addObject:@0];
    }
    NLTaggerOptions options = NLTaggerOmitWhitespace | NLTaggerOmitPunctuation | NLTaggerOmitOther;
    [tagger enumerateTagsInRange:NSMakeRange(0, text.length) unit:NLTokenUnitWord scheme:NLTagSchemeLexicalClass options:options
                      usingBlock:^(NLTag tag, NSRange tokenRange, __unused BOOL *stop) {
        while (sentenceCursor < all.count && NSMaxRange(all[sentenceCursor].range) <= tokenRange.location) {
            sentenceCursor++;
        }
        if (sentenceCursor >= all.count) {
            return;
        }
        BrowserNLSentence *sentence = all[sentenceCursor];
        wordCounts[sentenceCursor] = @(wordCounts[sentenceCursor].unsignedIntegerValue + 1);
        if (tag != nil && ![contentClasses containsObject:tag]) {
            return;
        }
        NSString *word = [text substringWithRange:tokenRange];
        if (word.length < 3) {
            return;
        }
        NLTag lemma = [tagger tagAtIndex:tokenRange.location unit:NLTokenUnitWord scheme:NLTagSchemeLemma tokenRange:NULL];
        NSString *term = (lemma.length > 1 ? lemma : word).lowercaseString;
        termFrequency[term] = @(termFrequency[term].unsignedIntegerValue + 1);
        if (![sentence.terms containsObject:term]) {
            [sentence.terms addObject:term];
            documentFrequency[term] = @(documentFrequency[term].unsignedIntegerValue + 1);
        }
    }];
    for (NSUInteger i = 0; i < all.count; i++) {
        all[i].wordCount = wordCounts[i].unsignedIntegerValue;
    }

    // 3. Kandidaten: ganze Sätze mittlerer Länge, ohne Dubletten.
    NSMutableArray<BrowserNLSentence *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (BrowserNLSentence *sentence in all) {
        if (!BrowserNLSentenceLooksUsable(sentence.text, sentence.wordCount) || [seen containsObject:sentence.text]) {
            continue;
        }
        [seen addObject:sentence.text];
        [candidates addObject:sentence];
    }
    if (candidates.count < 3) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:BrowserIntelligenceErrorDomain code:BrowserIntelligenceErrorTooShort
                                     userInfo:@{NSLocalizedDescriptionKey: @"Zu wenig zusammenhängender Text"}];
        }
        return nil;
    }

    // 4a. TF-IDF-Zentroid (Radev): Gewicht eines Begriffs = Häufigkeit im Text × IDF; Satzwert = Summe der
    //     Gewichte seiner Begriffe, gedämpft mit der Wurzel der Begriffszahl (lange Sätze nicht bevorzugen).
    double n = (double)all.count;
    for (BrowserNLSentence *sentence in candidates) {
        double sum = 0.0;
        for (NSString *term in sentence.terms) {
            double df = documentFrequency[term].doubleValue;
            double tf = termFrequency[term].doubleValue;
            if (tf < 2.0) {
                continue; // einmalige Wörter sagen nichts über das Thema
            }
            sum += tf * log((n + 1.0) / df);
        }
        sentence.termScore = sentence.terms.count > 0 ? sum / pow((double)sentence.terms.count, 0.75) : 0.0;
    }

    // 4b. Satz-Embedding: Nähe zum Mittelwert aller Kandidaten (Zentralität). Ohne Satz-Embedding der Sprache
    //     ersatzweise das kontextuelle Embedding (Mittelwert der Token-Vektoren), sonst nur TF-IDF.
    NLEmbedding *embedding = [self sentenceEmbeddingForLanguage:language];
    id contextual = nil;
    if (embedding == nil && language != nil) {
        if (@available(tvOS 17.0, *)) {
            contextual = [self contextualEmbeddingForLanguage:language];
        }
    }
    NSUInteger dimension = embedding.dimension;
    if (embedding == nil && contextual != nil) {
        if (@available(tvOS 17.0, *)) {
            dimension = ((NLContextualEmbedding *)contextual).dimension;
        }
    }
    NSUInteger vectorCount = 0;
    double rawCentrality = 0.0;
    if ((embedding != nil || contextual != nil) && dimension > 0) {
        float *buffer = calloc(dimension, sizeof(float));
        double *centroid = calloc(dimension, sizeof(double));
        for (BrowserNLSentence *sentence in candidates) {
            if (embedding != nil) {
                if ([embedding getVector:buffer forString:sentence.text]) {
                    sentence.vector = BrowserNLNormalizedVector(buffer, dimension);
                }
            } else if (@available(tvOS 17.0, *)) {
                sentence.vector = BrowserNLContextualVector(contextual, sentence.text, language);
            }
            if (sentence.vector != nil) {
                const float *v = sentence.vector.bytes;
                for (NSUInteger i = 0; i < dimension; i++) {
                    centroid[i] += v[i];
                }
                vectorCount++;
            }
        }
        if (vectorCount > 0) {
            for (NSUInteger i = 0; i < dimension; i++) {
                buffer[i] = (float)(centroid[i] / (double)vectorCount);
            }
            NSData *center = BrowserNLNormalizedVector(buffer, dimension);
            for (BrowserNLSentence *sentence in candidates) {
                sentence.centrality = sentence.vector != nil ? BrowserNLDot(sentence.vector, center) : 0.0;
                rawCentrality += sentence.centrality / (double)candidates.count;
            }
        }
        free(buffer);
        free(centroid);
    }
    BOOL useEmbedding = vectorCount >= candidates.count / 2;
    // Ab hier gilt ein Satzpaar als Wiederholung: deutlich ähnlicher als der Durchschnitt zum Mittelpunkt
    // (kontextuelle Vektoren liegen alle enger beieinander als die des Satz-Embeddings).
    double redundancyFloor = MIN(0.95, MAX(0.75, rawCentrality + 0.1));

    // 4c. Position: Einleitung und Absatzanfänge tragen meist die Kernaussage.
    for (BrowserNLSentence *sentence in candidates) {
        sentence.positionScore = 1.0 / (1.0 + (double)sentence.index / 4.0) + (sentence.firstInParagraph ? 0.15 : 0.0);
    }

    BrowserNLMinMax(candidates, @"termScore");
    BrowserNLMinMax(candidates, @"positionScore");
    if (useEmbedding) {
        BrowserNLMinMax(candidates, @"centrality");
    }
    for (BrowserNLSentence *sentence in candidates) {
        double base = useEmbedding
            ? 0.40 * sentence.centrality + 0.38 * sentence.termScore + 0.22 * sentence.positionScore
            : 0.68 * sentence.termScore + 0.32 * sentence.positionScore;
        double lengthFactor = 0.8 + 0.2 * MIN(1.0, (double)sentence.wordCount / 15.0);
        // Erster Satz des Artikels (Definition bzw. Teaser) fast immer: kleiner Vorsprung.
        sentence.score = base * lengthFactor + (sentence.index == 0 ? 0.2 : 0.0);
    }

    // 5. Auswahl (MMR): bester Satz, dann jeweils der beste, der den gewählten nicht zu ähnlich ist.
    //    Bei kurzen Texten keine Lückenfüller: Sätze unter 30 % des besten Werts fallen weg (mindestens 3 bleiben).
    NSMutableArray<BrowserNLSentence *> *pool = [candidates mutableCopy];
    double bestScore = [[candidates valueForKeyPath:@"@max.score"] doubleValue];
    NSArray<BrowserNLSentence *> *strong = [candidates filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(BrowserNLSentence *s, __unused NSDictionary *bindings) { return s.score >= 0.3 * bestScore; }]];
    if (strong.count >= 3) {
        pool = [strong mutableCopy];
    }
    NSUInteger count = MIN(maxSentences > 0 ? maxSentences : 5, pool.count);
    NSMutableArray<BrowserNLSentence *> *chosen = [NSMutableArray array];
    while (chosen.count < count && pool.count > 0) {
        BrowserNLSentence *best = nil;
        double bestValue = -DBL_MAX;
        for (BrowserNLSentence *sentence in pool) {
            double redundancy = 0.0;
            for (BrowserNLSentence *other in chosen) {
                double jaccard = MIN(1.0, 2.0 * BrowserNLJaccard(sentence.terms, other.terms));
                double cosine = useEmbedding ? MAX(0.0, (BrowserNLDot(sentence.vector, other.vector) - redundancyFloor) / (1.0 - redundancyFloor)) : 0.0;
                redundancy = MAX(redundancy, MAX(jaccard, cosine));
            }
            double value = 0.72 * sentence.score - 0.28 * redundancy;
            if (value > bestValue) {
                bestValue = value;
                best = sentence;
            }
        }
        [chosen addObject:best];
        [pool removeObject:best];
    }
    [chosen sortUsingComparator:^NSComparisonResult(BrowserNLSentence *a, BrowserNLSentence *b) {
        return a.index < b.index ? NSOrderedAscending : (a.index > b.index ? NSOrderedDescending : NSOrderedSame);
    }];

#if DEBUG
    for (BrowserNLSentence *sentence in chosen) {
        NSLog(@"[AI] Satz #%lu Wert=%.2f (Emb %.2f, TF-IDF %.2f, Pos %.2f) %@", (unsigned long)sentence.index, sentence.score,
              sentence.centrality, sentence.termScore, sentence.positionScore,
              sentence.text.length > 90 ? [[sentence.text substringToIndex:90] stringByAppendingString:@"…"] : sentence.text);
    }
#endif

    BrowserAISummary *summary = [BrowserAISummary new];
    summary.sentences = [chosen valueForKey:@"text"];
    summary.language = language;
    summary.providerName = self.providerName;
    summary.method = !useEmbedding ? @"TF-IDF" : (embedding != nil ? @"Satz-Embedding + TF-IDF" : @"Kontext-Embedding + TF-IDF");
    summary.candidateCount = candidates.count;
    summary.inputLength = text.length;
    return summary;
}

- (NSString *)diagnosticsDescription {
    __block NSMutableArray<NSString *> *lines = [NSMutableArray array];
    dispatch_sync(self.workQueue, ^{
        for (NSString *language in @[NLLanguageGerman, NLLanguageEnglish]) {
            NLEmbedding *sentence = [self sentenceEmbeddingForLanguage:language];
            NLEmbedding *word = [NLEmbedding wordEmbeddingForLanguage:language];
            NSString *contextual = @"nicht verfügbar (vor tvOS 17)";
            if (@available(tvOS 17.0, *)) {
                NLContextualEmbedding *ctx = [NLContextualEmbedding contextualEmbeddingWithLanguage:language];
                contextual = ctx == nil ? @"keins" : [NSString stringWithFormat:@"dim=%lu assets=%@", (unsigned long)ctx.dimension,
                                                      ctx.hasAvailableAssets ? @"ja" : @"nein (Download nötig)"];
            }
            [lines addObject:[NSString stringWithFormat:@"%@: Satz-Embedding=%@ Wort-Embedding=%@ kontextuell=%@", language,
                              sentence ? [NSString stringWithFormat:@"ja dim=%lu rev=%lu", (unsigned long)sentence.dimension,
                                          (unsigned long)sentence.revision] : @"nein",
                              word ? [NSString stringWithFormat:@"ja dim=%lu", (unsigned long)word.dimension] : @"nein",
                              contextual]];
        }
    });
    return [lines componentsJoinedByString:@" | "];
}

@end

#pragma mark - Fassade

@interface BrowserIntelligence ()
@property (nonatomic, strong) id<BrowserAIProvider> provider;
@end

@implementation BrowserIntelligence

+ (BrowserIntelligence *)sharedIntelligence {
    static BrowserIntelligence *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [BrowserIntelligence new];
        shared.provider = [BrowserNLProvider new];
    });
    return shared;
}

+ (NSString *)systemLanguageCode {
    NSString *preferred = NSLocale.preferredLanguages.firstObject ?: @"de";
    NSString *code = [NSLocale localeWithLocaleIdentifier:preferred].languageCode;
    return code.length > 0 ? code.lowercaseString : @"de";
}

+ (NSString *)displayNameForLanguage:(NSString *)language {
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:NSLocale.preferredLanguages.firstObject ?: @"de"];
    NSString *name = [locale localizedStringForLanguageCode:language];
    return name.length > 0 ? name : language;
}

/// "de-DE" → "de", "zh-Hans" → "zh".
static NSString *BrowserBaseLanguage(NSString *language) {
    if (language.length == 0) {
        return nil;
    }
    NSString *lower = language.lowercaseString;
    NSRange dash = [lower rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]];
    return dash.location == NSNotFound ? lower : [lower substringToIndex:dash.location];
}

+ (NSUInteger)summaryLengthForCandidateCount:(NSUInteger)candidateCount {
    if (candidateCount < 14) {
        return 4;
    }
    return candidateCount < 30 ? 5 : 6;
}

#pragma mark Zusammenfassen

- (void)summarizeWebView:(BrowserWebView *)webView
              completion:(void (^)(BrowserAISummary *, NSDictionary<NSString *, id> *, NSError *))completion {
    if (webView == nil) {
        completion(nil, nil, [NSError errorWithDomain:BrowserIntelligenceErrorDomain code:BrowserIntelligenceErrorNoPage
                                             userInfo:@{NSLocalizedDescriptionKey: @"Keine Seite geladen"}]);
        return;
    }
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [BrowserReaderMode textForWebView:webView completion:^(NSDictionary<NSString *, id> *info) {
        NSString *text = [info[@"text"] isKindOfClass:NSString.class] ? info[@"text"] : nil;
        CFAbsoluteTime fetched = CFAbsoluteTimeGetCurrent();
        if (text.length < 200) {
            NSLog(@"[AI] zusammenfassen: kein Text (%lu Zeichen, Quelle %@)", (unsigned long)text.length, info[@"source"] ?: @"-");
            completion(nil, info, [NSError errorWithDomain:BrowserIntelligenceErrorDomain code:BrowserIntelligenceErrorNoText
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Kein Artikeltext gefunden"}]);
            return;
        }
        // Erst die Kandidatenzahl grob schätzen (Satzzeichen), dann 4 bis 6 Sätze.
        NSUInteger roughSentences = [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@".!?"]].count;
        NSUInteger length = [BrowserIntelligence summaryLengthForCandidateCount:roughSentences];
        NSString *title = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : nil;
        [self.provider summarizeText:text title:title maxSentences:length completion:^(BrowserAISummary *summary, NSError *error) {
            NSLog(@"[AI] zusammenfassen: %@ Quelle=%@ Text=%lu/%@ Zeichen Abruf=%.0f ms Rechnen=%.0f ms Sprache=%@ Kandidaten=%lu Sätze=%lu Verfahren=%@%@",
                  summary != nil ? @"ok" : @"fehlgeschlagen", info[@"source"] ?: @"-", (unsigned long)text.length, info[@"total"] ?: @"?",
                  (fetched - start) * 1000.0, summary.duration * 1000.0, summary.language ?: @"?",
                  (unsigned long)summary.candidateCount, (unsigned long)summary.sentences.count, summary.method ?: @"-",
                  error != nil ? [@" Fehler=" stringByAppendingString:error.localizedDescription] : @"");
            completion(summary, info, error);
        }];
    }];
}

#pragma mark Sprache und Übersetzen

static NSString * const kLanguageProbeScript =
    @"(function(){try{"
     "var pw=!!document.querySelector('input[type=password]');"
     "var path=(location.pathname+' '+location.search).toLowerCase();"
     "var login=pw||/(^|[^a-z])(login|log-in|signin|sign-in|sign_in|anmelden|anmeldung|einloggen|oauth|sso)([^a-z]|$)/.test(path);"
     "var root=document.querySelector('article, main, [role=main]')||document.body;"
     "var t=((root&&(root.innerText||root.textContent))||'').replace(/\\s+/g,' ').trim();"
     "if(t.length<400&&root!==document.body&&document.body){t=(document.body.innerText||'').replace(/\\s+/g,' ').trim();}"
     "return JSON.stringify({pw:pw,login:login,lang:document.documentElement.lang||'',text:t.slice(0,2500)});"
     "}catch(e){return 'e:'+e;}})()";

- (void)languageInfoForWebView:(BrowserWebView *)webView completion:(void (^)(BrowserPageLanguageInfo *))completion {
    NSURL *url = webView.request.URL;
    NSString *host = [BrowserIntelligence normalizedHostForURL:url];
    BrowserPageLanguageInfo *info = [BrowserPageLanguageInfo new];
    info.reason = @"?";
    NSString *scheme = url.scheme.lowercaseString;
    if (webView == nil || host == nil || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        info.reason = @"keine Webseite";
        completion(info);
        return;
    }
    if ([BrowserIntelligence isTranslationProxyURL:url]) {
        info.reason = @"proxy";
        completion(info);
        return;
    }
    [webView evaluateJavaScriptAsync:kLanguageProbeScript completion:^(id result) {
        NSDictionary *probe = nil;
        if ([result isKindOfClass:NSString.class] && [(NSString *)result hasPrefix:@"{"]) {
            probe = [NSJSONSerialization JSONObjectWithData:[(NSString *)result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }
        if (![probe isKindOfClass:NSDictionary.class]) {
            info.reason = @"keine Antwort";
            completion(info);
            return;
        }
        NSString *sample = [probe[@"text"] isKindOfClass:NSString.class] ? probe[@"text"] : @"";
        info.hasLogin = [probe[@"login"] boolValue];
        info.declaredLanguage = [probe[@"lang"] length] > 0 ? probe[@"lang"] : nil;
        info.sampleLength = sample.length;
        double confidence = 0.0;
        info.language = [self.provider dominantLanguageForText:sample confidence:&confidence];
        info.confidence = confidence;
        NSString *system = BrowserBaseLanguage(BrowserIntelligence.systemLanguageCode);
        if ([self translationDeclinedForHost:host]) {
            info.reason = @"abgelehnt";
        } else if (info.hasLogin) {
            info.reason = [probe[@"pw"] boolValue] ? @"login (Passwortfeld)" : @"login (Adresse)";
        } else if (sample.length < 200) {
            info.reason = @"zu wenig Text";
        } else if (info.language == nil || confidence < 0.65) {
            info.reason = @"Sprache unsicher";
        } else if ([BrowserBaseLanguage(info.language) isEqualToString:system]) {
            info.reason = @"gleiche Sprache";
        } else {
            info.reason = @"fremd";
            info.shouldOfferTranslation = YES;
        }
        completion(info);
    }];
}

+ (NSString *)normalizedHostForURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) {
        return nil;
    }
    return [host hasPrefix:@"www."] ? [host substringFromIndex:4] : host;
}

+ (BOOL)isTranslationProxyURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    return [host isEqualToString:@"translate.goog"] || [host hasSuffix:@".translate.goog"];
}

+ (NSURL *)translationProxyURLForURL:(NSURL *)url targetLanguage:(NSString *)targetLanguage {
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) || host.length == 0 ||
        [self isTranslationProxyURL:url]) {
        return nil;
    }
    // IP-Adressen und lokale Namen kann der Proxy nicht erreichen.
    if ([host rangeOfString:@"."].location == NSNotFound || [host rangeOfString:@":"].location != NSNotFound ||
        [host rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound) {
        return nil;
    }
    // Googles Schema: vorhandene Bindestriche verdoppeln, dann Punkte zu Bindestrichen.
    NSString *proxyHost = [[[host stringByReplacingOccurrencesOfString:@"-" withString:@"--"]
                            stringByReplacingOccurrencesOfString:@"." withString:@"-"] stringByAppendingString:@".translate.goog"];
    NSURLComponents *source = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    components.host = proxyHost;
    components.percentEncodedPath = source.percentEncodedPath.length > 0 ? source.percentEncodedPath : @"/";
    NSString *target = BrowserBaseLanguage(targetLanguage) ?: @"de";
    NSMutableString *query = [NSMutableString stringWithString:source.percentEncodedQuery ?: @""];
    [query appendFormat:@"%@_x_tr_sl=auto&_x_tr_tl=%@&_x_tr_hl=%@&_x_tr_pto=wapp", query.length > 0 ? @"&" : @"", target, target];
    if ([scheme isEqualToString:@"http"]) {
        [query appendString:@"&_x_tr_sch=http"];
    }
    components.percentEncodedQuery = query;
    components.percentEncodedFragment = source.percentEncodedFragment;
    return components.URL;
}

- (NSArray<NSString *> *)declinedHosts {
    NSArray *hosts = [NSUserDefaults.standardUserDefaults arrayForKey:kDeclinedHostsKey];
    return [hosts isKindOfClass:NSArray.class] ? hosts : @[];
}

- (void)declineTranslationForHost:(NSString *)host {
    if (host.length == 0 || [self translationDeclinedForHost:host]) {
        return;
    }
    NSMutableArray *hosts = [[self declinedHosts] mutableCopy];
    [hosts addObject:host];
    [NSUserDefaults.standardUserDefaults setObject:hosts forKey:kDeclinedHostsKey];
}

- (BOOL)translationDeclinedForHost:(NSString *)host {
    return host.length > 0 && [[self declinedHosts] containsObject:host];
}

- (void)resetDeclinedTranslations {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kDeclinedHostsKey];
}

- (NSString *)diagnosticsDescription {
    return [NSString stringWithFormat:@"Anbieter=%@ verfügbar=%d Systemsprache=%@ (%@) abgelehnt=%@ | %@", self.provider.providerName,
            self.provider.isAvailable, BrowserIntelligence.systemLanguageCode, NSLocale.preferredLanguages.firstObject ?: @"-",
            [[self declinedHosts] componentsJoinedByString:@","] ?: @"", [self.provider diagnosticsDescription]];
}

@end
