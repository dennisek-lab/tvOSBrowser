//
//  BrowserIntelligence.m
//  Browser
//

#import "BrowserIntelligence.h"
#import "BrowserCommand.h"
#import "BrowserCommandParser.h"
#import "BrowserReaderMode.h"
#import "BrowserWebView.h"
#import "BrowserAppleTranslator.h"
#import <NaturalLanguage/NaturalLanguage.h>

NSString * const BrowserIntelligenceErrorDomain = @"BrowserIntelligence";
static NSString * const kDeclinedHostsKey = @"TranslateDeclinedHosts";

@implementation BrowserAISummary
@end

@implementation BrowserPageLanguageInfo
@end

@implementation BrowserAIPassage
@end

@implementation BrowserAIAnswer
@end

@implementation BrowserCommandMatch

- (NSString *)logDescription {
    NSString *target = self.name != nil ? [NSString stringWithFormat:@"%@%@%@", self.name, self.argument.length > 0 ? @"|" : @"", self.argument ?: @""] : @"-";
    NSString *semantic = self.semanticScore >= 0 ? [NSString stringWithFormat:@"%.2f (Abstand %.2f, %@)", self.semanticScore, self.semanticMargin,
                                                    self.semanticName ?: @"-"] : @"-";
    return [NSString stringWithFormat:@"%@ -> %@ (Begriffe %.2f Abstand %.2f, Embedding %@, unbekannt=%@, Beispiel \"%@\", %@)",
            self.accepted ? @"ausführen" : @"Suche", target, self.lexicalScore, self.lexicalMargin, semantic,
            self.unknownWords.count > 0 ? [self.unknownWords componentsJoinedByString:@","] : @"0", self.example ?: @"-", self.reason];
}

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
        _workQueue = dispatch_queue_create("tvbrowser.intelligence", DISPATCH_QUEUE_SERIAL);
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
             "folgen sie|abonnier|weiterlesen|mehr zum thema|alle rechte|melden sie sich|"
             "mit ihrer zustimmung|ihre (zustimmung|einwilligung)|externe[rn]? (inhalt|podcast|video)|datenschutz|erfahren sie,? wie|your consent|privacy policy)"
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

/// Fußnotenzeichen [1], [12] und doppelte Leerzeichen entfernen; Absätze (Leerzeile) bleiben.
static NSString *BrowserNLCleanText(NSString *rawText) {
    NSString *text = [rawText stringByReplacingOccurrencesOfString:@"\\[[0-9]{1,3}\\]" withString:@""
                                                           options:NSRegularExpressionSearch range:NSMakeRange(0, rawText.length)];
    return [text stringByReplacingOccurrencesOfString:@"[ \\t\\u00a0]+" withString:@" "
                                              options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
}

/// Sätze des Texts (NLTokenizer, danach Ordnungszahlen und Abkürzungen wieder zusammengefügt) mit ihren Inhaltswörtern
/// als Lemma (Nomen, Verben, Adjektive). Gemeinsame Grundlage für Zusammenfassen und „Frag die Seite“.
/// includeNumbers: auch Zahlen und Wörter mit Ziffern ("2017", "4k") zählen, Mindestlänge 2 statt 3 ("TV").
/// documentFrequency/termFrequency (optional) werden gefüllt: in wie vielen Sätzen bzw. wie oft ein Begriff vorkommt.
- (NSMutableArray<BrowserNLSentence *> *)sentencesOfText:(NSString *)text
                                                language:(NSString *)language
                                          includeNumbers:(BOOL)includeNumbers
                                       documentFrequency:(NSMutableDictionary<NSString *, NSNumber *> *)documentFrequency
                                           termFrequency:(NSMutableDictionary<NSString *, NSNumber *> *)termFrequency {
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
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSUInteger minimumLength = includeNumbers ? 2 : 3;
    __block NSUInteger sentenceCursor = 0;
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
        NSString *word = [text substringWithRange:tokenRange];
        BOOL numeric = includeNumbers && [word rangeOfCharacterFromSet:digits].location != NSNotFound;
        if (!numeric && tag != nil && ![contentClasses containsObject:tag]) {
            return;
        }
        if (word.length < minimumLength) {
            return;
        }
        NSString *term = word.lowercaseString;
        if (!numeric) {
            NLTag lemma = [tagger tagAtIndex:tokenRange.location unit:NLTokenUnitWord scheme:NLTagSchemeLemma tokenRange:NULL];
            term = (lemma.length > 1 ? lemma : word).lowercaseString;
        }
        termFrequency[term] = @(termFrequency[term].unsignedIntegerValue + 1);
        if (![sentence.terms containsObject:term]) {
            [sentence.terms addObject:term];
            documentFrequency[term] = @(documentFrequency[term].unsignedIntegerValue + 1);
        }
    }];
    for (NSUInteger i = 0; i < all.count; i++) {
        all[i].wordCount = wordCounts[i].unsignedIntegerValue;
    }
    return all;
}

- (BrowserAISummary *)summarySyncForText:(NSString *)rawText
                                   title:(NSString *)title
                            maxSentences:(NSUInteger)maxSentences
                                   error:(NSError **)error {
    NSString *text = BrowserNLCleanText(rawText);
    double confidence = 0.0;
    NSString *language = [self dominantLanguageForText:text confidence:&confidence];

    // 1./2. Sätze und Inhaltswörter.
    NSMutableDictionary<NSString *, NSNumber *> *documentFrequency = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *termFrequency = [NSMutableDictionary dictionary];
    NSMutableArray<BrowserNLSentence *> *all = [self sentencesOfText:text language:language includeNumbers:NO
                                                   documentFrequency:documentFrequency termFrequency:termFrequency];

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

#pragma mark „Frag die Seite“

/// Wörter, die in Fragen stehen, aber nichts über den Inhalt sagen (Lemmata, klein).
static NSSet<NSString *> *BrowserNLQuestionStopTerms(void) {
    static NSSet<NSString *> *terms;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        terms = [NSSet setWithArray:@[
            @"wann", @"wer", @"wen", @"wem", @"was", @"wie", @"wo", @"woher", @"wohin", @"warum", @"weshalb", @"wieso", @"wozu",
            @"welch", @"welche", @"welcher", @"welches", @"welchen", @"viel", @"viele", @"wieviel", @"sein", @"werden", @"wurde",
            @"haben", @"hat", @"ist", @"sind", @"war", @"geben", @"gibt", @"stehen", @"steht", @"können", @"kann", @"machen", @"sagen",
            @"seite", @"artikel", @"frage", @"fragen", @"heißen", @"genau", @"eigentlich", @"stecken", @"kommen", @"finden", @"befinden", @"nennen", @"liegen",
            @"when", @"who", @"whom", @"what", @"how", @"where", @"why", @"which", @"much", @"many", @"be", @"is", @"are", @"was",
            @"were", @"do", @"does", @"did", @"have", @"has", @"had", @"can", @"could", @"will", @"would", @"get", @"say", @"page",
            @"article", @"tell", @"know", @"call", @"called",
            // Funktionswörter, falls der Tagger sie als Inhaltswort liefert (deutsches Lemma fehlt im Simulator).
            @"der", @"die", @"das", @"den", @"dem", @"des", @"ein", @"eine", @"einen", @"einem", @"einer", @"und", @"oder", @"von",
            @"mit", @"für", @"auf", @"im", @"am", @"um", @"es", @"er", @"sie", @"man", @"the", @"an", @"of", @"to", @"in", @"on",
            @"and", @"or", @"it", @"its", @"for", @"with"]];
    });
    return terms;
}

// Relevanzschwellen für „Frag die Seite“ (Anteil der Fragebegriffe im Satz, Kosinus im Satz-Embedding).
static const double kAskMinimumCoverage = 0.45;               ///< ohne Embedding bzw. bei schwachem Kosinus
static const double kAskMinimumCoverageWithEmbedding = 0.25;  ///< wenn das Embedding den Satz deutlich stützt
static const double kAskStrongSemantic = 0.65;
static const double kAskWeakSemantic = 0.30;                  ///< darunter zählt nur ein fast vollständiger Begriffstreffer
static const double kAskFullCoverage = 0.80;

/// Kleines Wörterbuch Deutsch ↔ Englisch (Lemmata) für Fragen in der anderen Sprache als die Seite: Frageverben
/// und häufige Technikwörter. Kein Übersetzer, nur damit „wann wurde … vorgestellt“ auf einer englischen Seite
/// „announced“ findet.
static NSDictionary<NSString *, NSArray<NSString *> *> *BrowserNLTranslations(void) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary<NSString *, NSArray<NSString *> *> *german = @{
            @"vorstellen": @[@"announce", @"introduce", @"unveil", @"present"], @"ankündigen": @[@"announce"],
            @"erscheinen": @[@"release", @"launch", @"appear"], @"veröffentlichen": @[@"release", @"publish"],
            @"einführen": @[@"introduce", @"launch"], @"kosten": @[@"cost", @"price"], @"preis": @[@"price", @"cost"],
            @"entwickeln": @[@"develop"], @"erfinden": @[@"invent"], @"gründen": @[@"found"], @"herstellen": @[@"manufacture", @"produce"],
            @"verkaufen": @[@"sell"], @"einstellen": @[@"discontinue"], @"unterstützen": @[@"support"], @"speicher": @[@"storage", @"memory"],
            @"arbeitsspeicher": @[@"ram", @"memory"], @"prozessor": @[@"processor", @"chip", @"cpu"], @"chip": @[@"chip"],
            @"fernbedienung": @[@"remote"], @"generation": @[@"generation"], @"erste": @[@"first"], @"zweite": @[@"second"],
            @"dritte": @[@"third"], @"vierte": @[@"fourth"], @"jahr": @[@"year"], @"gerät": @[@"device"], @"modell": @[@"model"],
            @"auflösung": @[@"resolution"], @"anschluss": @[@"port"], @"gewicht": @[@"weight"], @"größe": @[@"size"],
            @"hersteller": @[@"manufacturer"], @"nachfolger": @[@"successor"], @"vorgänger": @[@"predecessor"],
        };
        // Ohne Lemmatisierer (im tvOS-Simulator fehlt er für Deutsch und Englisch) stehen Partizipien und
        // Vergangenheitsformen im Text: deutsche Formen dazuschreiben, englische Verben um -d/-ed ergänzen.
        NSDictionary<NSString *, NSArray<NSString *> *> *germanForms = @{
            @"vorstellen": @[@"vorgestellt", @"vorgestellten", @"stellte"], @"ankündigen": @[@"angekündigt", @"kündigte"],
            @"erscheinen": @[@"erschienen", @"erschien"], @"veröffentlichen": @[@"veröffentlicht", @"veröffentlichte"],
            @"einführen": @[@"eingeführt", @"führte"], @"kosten": @[@"kostet", @"kostete"], @"entwickeln": @[@"entwickelt", @"entwickelte"],
            @"erfinden": @[@"erfunden", @"erfand"], @"gründen": @[@"gegründet", @"gründete"], @"herstellen": @[@"hergestellt"],
            @"verkaufen": @[@"verkauft", @"verkaufte"], @"einstellen": @[@"eingestellt"], @"unterstützen": @[@"unterstützt"],
            @"dritte": @[@"dritten"], @"zweite": @[@"zweiten"], @"erste": @[@"ersten"], @"vierte": @[@"vierten"],
        };
        NSSet<NSString *> *englishVerbs = [NSSet setWithArray:@[@"announce", @"introduce", @"unveil", @"present", @"release", @"launch",
                                                                @"appear", @"publish", @"cost", @"develop", @"invent", @"found",
                                                                @"manufacture", @"produce", @"discontinue", @"support"]];
        NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *both = [NSMutableDictionary dictionary];
        void (^link)(NSString *, NSString *) = ^(NSString *a, NSString *b) {
            if (both[a] == nil) { both[a] = [NSMutableSet set]; }
            if (both[b] == nil) { both[b] = [NSMutableSet set]; }
            [both[a] addObject:b];
            [both[b] addObject:a];
        };
        [german enumerateKeysAndObjectsUsingBlock:^(NSString *de, NSArray<NSString *> *list, __unused BOOL *stop) {
            NSMutableArray<NSString *> *deForms = [NSMutableArray arrayWithObject:de];
            [deForms addObjectsFromArray:germanForms[de] ?: @[]];
            NSMutableArray<NSString *> *enForms = [NSMutableArray array];
            for (NSString *en in list) {
                [enForms addObject:en];
                if ([englishVerbs containsObject:en]) {
                    [enForms addObject:[en hasSuffix:@"e"] ? [en stringByAppendingString:@"d"] : [en stringByAppendingString:@"ed"]];
                    [enForms addObject:[en stringByAppendingString:@"s"]];
                }
            }
            for (NSString *d in deForms) {
                for (NSString *e in enForms) {
                    link(d, e);
                }
            }
        }];
        NSMutableDictionary<NSString *, NSArray<NSString *> *> *result = [NSMutableDictionary dictionary];
        [both enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableSet<NSString *> *value, __unused BOOL *stop) {
            result[key] = value.allObjects;
        }];
        map = result;
    });
    return map;
}

/// Frageart aus den ersten Wörtern: Datum, Zahl, Ort, Person oder allgemein.
static NSString *BrowserNLQuestionType(NSString *question) {
    NSString *lower = question.lowercaseString;
    NSArray<NSArray *> *rules = @[
        @[@"datum", @"^(seit |bis |ab |)wann\\b|\\b(in )?welchem jahr\\b|\\bwelches (jahr|datum)\\b|^(since |until |)when\\b|\\bwhat (year|date)\\b|\\bwhich year\\b|\\bwie alt\\b|\\bhow old\\b"],
        @[@"zahl", @"\\bwie (viel|viele|teuer|groß|hoch|lang|schwer|weit|schnell|breit)\\b|\\bwieviel|\\bkoste|\\bpreis|\\bhow (much|many|big|large|long|tall|heavy|far|fast)\\b|\\bprice\\b|\\bcost"],
        @[@"ort", @"^(wo|woher|wohin)\\b|^where\\b|\\bin welche[mr]? (land|stadt|ort)\\b"],
        @[@"person", @"^(wer|wem|wen|wessen)\\b|^(who|whom|whose)\\b"],
    ];
    for (NSArray *rule in rules) {
        if ([lower rangeOfString:rule[1] options:NSRegularExpressionSearch].location != NSNotFound) {
            return rule[0];
        }
    }
    return @"allgemein";
}

/// Passt der Satz zur Frageart? Datum: Jahreszahl oder Monat; Zahl: Ziffern; Ort/Person: Namen (NLTagger).
static BOOL BrowserNLSentenceMatchesType(NSString *sentence, NSString *type, NSString *language) {
    if ([type isEqualToString:@"datum"]) {
        static NSRegularExpression *date;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            date = [NSRegularExpression regularExpressionWithPattern:
                @"\\b(1[5-9][0-9]{2}|20[0-9]{2})\\b|\\b(januar|jänner|februar|märz|april|mai|juni|juli|august|september|oktober|november|dezember|"
                 "january|february|march|may|june|july|october|december)\\b" options:NSRegularExpressionCaseInsensitive error:nil];
        });
        return [date firstMatchInString:sentence options:0 range:NSMakeRange(0, sentence.length)] != nil;
    }
    if ([type isEqualToString:@"zahl"]) {
        return [sentence rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound;
    }
    if ([type isEqualToString:@"ort"] || [type isEqualToString:@"person"]) {
        NLTag wanted = [type isEqualToString:@"ort"] ? NLTagPlaceName : NLTagPersonalName;
        NLTagger *tagger = [[NLTagger alloc] initWithTagSchemes:@[NLTagSchemeNameType]];
        tagger.string = sentence;
        if (language != nil) {
            [tagger setLanguage:language range:NSMakeRange(0, sentence.length)];
        }
        __block BOOL found = NO;
        [tagger enumerateTagsInRange:NSMakeRange(0, sentence.length) unit:NLTokenUnitWord scheme:NLTagSchemeNameType
                             options:NLTaggerOmitWhitespace | NLTaggerOmitPunctuation | NLTaggerJoinNames
                          usingBlock:^(NLTag tag, __unused NSRange range, BOOL *stop) {
            if ([tag isEqualToString:wanted]) {
                found = YES;
                *stop = YES;
            }
        }];
        return found;
    }
    return NO;
}

- (void)findPassagesForQuestion:(NSString *)question
                         inText:(NSString *)text
                     maxResults:(NSUInteger)maxResults
                     completion:(void (^)(BrowserAIAnswer *, NSError *))completion {
    dispatch_async(self.workQueue, ^{
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSError *error = nil;
        BrowserAIAnswer *answer = [self answerSyncForQuestion:question text:text maxResults:maxResults error:&error];
        answer.duration = CFAbsoluteTimeGetCurrent() - start;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(answer, answer == nil ? error : nil);
        });
    });
}

- (BrowserAIAnswer *)answerSyncForQuestion:(NSString *)question text:(NSString *)rawText maxResults:(NSUInteger)maxResults
                                     error:(NSError **)error {
    NSString *text = BrowserNLCleanText(rawText);
    double confidence = 0.0;
    NSString *language = [self dominantLanguageForText:text confidence:&confidence];
    // Kurze Fragen erkennt NLLanguageRecognizer schlecht: auf Deutsch/Englisch beschränken, Seitensprache als Hinweis.
    NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
    recognizer.languageConstraints = @[NLLanguageGerman, NLLanguageEnglish];
    if (language != nil) {
        recognizer.languageHints = @{language: @0.6, ([language isEqualToString:NLLanguageGerman] ? NLLanguageEnglish : NLLanguageGerman): @0.4};
    }
    [recognizer processString:question];
    NSString *questionLanguage = recognizer.dominantLanguage ?: language;

    BrowserAIAnswer *answer = [BrowserAIAnswer new];
    answer.question = question;
    answer.language = language;
    answer.questionLanguage = questionLanguage;
    answer.questionType = BrowserNLQuestionType(question);
    answer.inputLength = text.length;
    answer.passages = @[];

    // Fragebegriffe: dieselbe Analyse wie für die Seite, ohne Frage- und Hilfswörter.
    NSMutableSet<NSString *> *questionTerms = [NSMutableSet set];
    for (BrowserNLSentence *part in [self sentencesOfText:question language:questionLanguage includeNumbers:YES
                                        documentFrequency:nil termFrequency:nil]) {
        [questionTerms unionSet:part.terms];
    }
    [questionTerms minusSet:BrowserNLQuestionStopTerms()];
    answer.questionTerms = [questionTerms.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (questionTerms.count == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:BrowserIntelligenceErrorDomain code:BrowserIntelligenceErrorQuestionTooShort
                                     userInfo:@{NSLocalizedDescriptionKey: @"Frage zu kurz"}];
        }
        return nil;
    }
    // Jeder Fragebegriff ist eine Gruppe; fragt man auf Deutsch eine englische Seite (oder umgekehrt), kommen die
    // Übersetzungen aus einem kleinen Wörterbuch dazu (Frageverben und häufige Technikwörter).
    BOOL crossLanguage = questionLanguage != nil && language != nil && ![questionLanguage isEqualToString:language];
    NSMutableArray<NSSet<NSString *> *> *groups = [NSMutableArray array];
    for (NSString *term in answer.questionTerms) {
        NSMutableSet<NSString *> *group = [NSMutableSet setWithObject:term];
        if (crossLanguage) {
            [group addObjectsFromArray:BrowserNLTranslations()[term] ?: @[]];
        }
        [groups addObject:group];
    }

    NSMutableDictionary<NSString *, NSNumber *> *documentFrequency = [NSMutableDictionary dictionary];
    NSMutableArray<BrowserNLSentence *> *all = [self sentencesOfText:text language:language includeNumbers:YES
                                                   documentFrequency:documentFrequency termFrequency:nil];
    // Kandidaten: Sätze und Listenpunkte ab 4 Wörtern (lockerer als beim Zusammenfassen, auch ohne Satzzeichen).
    NSMutableArray<BrowserNLSentence *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (BrowserNLSentence *sentence in all) {
        if (sentence.wordCount < 4 || sentence.text.length < 20 || sentence.text.length > 700 || [seen containsObject:sentence.text]) {
            continue;
        }
        [seen addObject:sentence.text];
        [candidates addObject:sentence];
    }
    answer.candidateCount = candidates.count;
    if (candidates.count == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:BrowserIntelligenceErrorDomain code:BrowserIntelligenceErrorTooShort
                                     userInfo:@{NSLocalizedDescriptionKey: @"Zu wenig Text auf der Seite"}];
        }
        return nil;
    }

    // 1. Begriffe: IDF-gewichteter Anteil der Fragebegriffe im Satz (0…1). Begriffe, die auf der Seite gar nicht
    //    vorkommen (andere Sprache, Tippfehler im Diktat), zählen mit halbem Höchstgewicht: sie senken den Wert,
    //    machen eine Frage in der anderen Sprache aber nicht unmöglich.
    double n = (double)all.count;
    double maxIDF = log(1.0 + (n + 0.5) / 0.5);
    NSMutableArray<NSNumber *> *weights = [NSMutableArray arrayWithCapacity:groups.count];
    double totalWeight = 0.0;
    for (NSSet<NSString *> *group in groups) {
        double df = 0.0;
        for (NSString *term in group) {
            df = MAX(df, documentFrequency[term].doubleValue);
        }
        double weight = df > 0 ? log(1.0 + (n - df + 0.5) / (df + 0.5)) : 0.5 * maxIDF;
        [weights addObject:@(weight)];
        totalWeight += weight;
    }
    double (^coverage)(NSSet<NSString *> *, NSUInteger *) = ^double(NSSet<NSString *> *terms, NSUInteger *matched) {
        double sum = 0.0;
        NSUInteger count = 0;
        for (NSUInteger g = 0; g < groups.count; g++) {
            if ([groups[g] intersectsSet:terms]) {
                sum += weights[g].doubleValue;
                count++;
            }
        }
        if (matched != NULL) {
            *matched = count;
        }
        return totalWeight > 0 ? sum / totalWeight : 0.0;
    };
    for (BrowserNLSentence *sentence in candidates) {
        NSUInteger matched = 0;
        double own = coverage(sentence.terms, &matched);
        // Nachbarsatz im selben Absatz: Subjekt steht oft im Satz davor („Es wurde 2017 vorgestellt.“).
        double withContext = own;
        for (NSInteger offset = -1; offset <= 1; offset += 2) {
            NSInteger j = (NSInteger)sentence.index + offset;
            if (j < 0 || j >= (NSInteger)all.count) {
                continue;
            }
            BrowserNLSentence *neighbour = all[(NSUInteger)j];
            BOOL sameParagraph = offset < 0 ? !sentence.firstInParagraph : !neighbour.firstInParagraph;
            if (!sameParagraph) {
                continue;
            }
            NSMutableSet<NSString *> *joined = [sentence.terms mutableCopy];
            [joined unionSet:neighbour.terms];
            withContext = MAX(withContext, coverage(joined, NULL));
        }
        // Fokus: Anteil der Fragebegriffe an allen Begriffen des Satzes. „Am 12. September 2017 wurde das Apple TV 4K
        // vorgestellt.“ schlägt so den längeren Satz über die zweite Generation, der dieselben Begriffe enthält.
        double focus = sentence.terms.count > 0 ? (double)matched / sqrt((double)sentence.terms.count * (double)groups.count) : 0.0;
        sentence.termScore = 0.7 * own + 0.15 * withContext + 0.15 * MIN(1.0, focus);
        sentence.positionScore = own; // reiner Anteil im Satz selbst, für die Relevanzschwelle
    }

    // 2. Satz-Embedding (nur, wenn Frage und Seite dieselbe Sprache haben und die Sprache eins hat), nur für Sätze, die
    //    die Relevanzschwelle der Begriffe überhaupt erreichen können (spart bei langen Artikeln fast die ganze Rechenzeit).
    NLEmbedding *embedding = !crossLanguage ? [self sentenceEmbeddingForLanguage:language] : nil;
    NSData *questionVector = nil;
    NSUInteger embedded = 0;
    if (embedding != nil) {
        float *buffer = calloc(embedding.dimension, sizeof(float));
        if ([embedding getVector:buffer forString:question]) {
            questionVector = BrowserNLNormalizedVector(buffer, embedding.dimension);
        }
        if (questionVector != nil) {
            for (BrowserNLSentence *sentence in candidates) {
                if (sentence.positionScore < kAskMinimumCoverageWithEmbedding) {
                    continue;
                }
                if ([embedding getVector:buffer forString:sentence.text]) {
                    sentence.vector = BrowserNLNormalizedVector(buffer, embedding.dimension);
                    embedded++;
                }
                sentence.centrality = sentence.vector != nil ? BrowserNLDot(questionVector, sentence.vector) : 0.0;
            }
        }
        free(buffer);
    }
    BOOL useEmbedding = questionVector != nil;
    answer.method = useEmbedding ? [NSString stringWithFormat:@"Satz-Embedding (%lu Sätze) + Begriffe", (unsigned long)embedded]
                                 : (crossLanguage ? @"Begriffe (IDF) + Wörterbuch" : @"Begriffe (IDF)");

    // 3. Frageart nur für die aussichtsreichsten Sätze prüfen (Namenserkennung ist teurer).
    NSArray<BrowserNLSentence *> *ranked = [candidates sortedArrayUsingComparator:^NSComparisonResult(BrowserNLSentence *a, BrowserNLSentence *b) {
        double va = a.termScore + (useEmbedding ? 0.5 * a.centrality : 0.0);
        double vb = b.termScore + (useEmbedding ? 0.5 * b.centrality : 0.0);
        return va > vb ? NSOrderedAscending : (va < vb ? NSOrderedDescending : NSOrderedSame);
    }];
    NSString *type = answer.questionType;
    NSMutableDictionary<NSNumber *, NSNumber *> *typeMatches = [NSMutableDictionary dictionary];
    NSUInteger checked = 0;
    for (BrowserNLSentence *sentence in ranked) {
        if (checked++ >= 40 || [type isEqualToString:@"allgemein"]) {
            break;
        }
        typeMatches[@(sentence.index)] = @(BrowserNLSentenceMatchesType(sentence.text, type, language));
    }

    // 4. Gesamtwert und Relevanzschwelle.
    NSMutableArray<BrowserAIPassage *> *passages = [NSMutableArray array];
    for (BrowserNLSentence *sentence in candidates) {
        BOOL typeMatch = typeMatches[@(sentence.index)].boolValue;
        double semantic = useEmbedding ? MIN(1.0, MAX(0.0, (sentence.centrality - 0.25) / 0.55)) : 0.0;
        double value = useEmbedding ? 0.58 * sentence.termScore + 0.27 * semantic + 0.15 * (typeMatch ? 1.0 : 0.0)
                                    : 0.85 * sentence.termScore + 0.15 * (typeMatch ? 1.0 : 0.0);
        if (sentence.wordCount > 45) {
            value *= 0.88; // Satzungetüme und zusammengeklebte Listen nicht bevorzugen
        }
        value += 0.02 / (1.0 + (double)sentence.index / 20.0); // bei Gleichstand die frühere Stelle
        // Relevant: genug Fragebegriffe im Satz selbst; mit Embedding auch weniger, wenn der Kosinus hoch ist, aber
        // nie bei sehr niedrigem Kosinus („Hauptstadt von Frankreich“ auf der Apple-TV-Seite: nur „France“ passt).
        double own = sentence.positionScore;
        BOOL relevant = useEmbedding
            ? ((own >= kAskMinimumCoverage && (sentence.centrality >= kAskWeakSemantic || own >= kAskFullCoverage)) ||
               (own >= kAskMinimumCoverageWithEmbedding && sentence.centrality >= kAskStrongSemantic))
            : own >= kAskMinimumCoverage;
        if (!relevant) {
            continue;
        }
        BrowserAIPassage *passage = [BrowserAIPassage new];
        passage.text = sentence.text;
        passage.index = sentence.index;
        passage.score = value;
        passage.lexicalScore = sentence.termScore;
        passage.semanticScore = useEmbedding ? sentence.centrality : -1.0;
        passage.typeMatch = typeMatch;
        [passages addObject:passage];
    }
    [passages sortUsingComparator:^NSComparisonResult(BrowserAIPassage *a, BrowserAIPassage *b) {
        return a.score > b.score ? NSOrderedAscending : (a.score < b.score ? NSOrderedDescending : NSOrderedSame);
    }];
    // 5. Höchstens maxResults, nur deutlich passende (≥ 55 % des besten Werts), ohne fast gleiche Sätze.
    NSMutableArray<BrowserAIPassage *> *chosen = [NSMutableArray array];
    double best = passages.firstObject.score;
    for (BrowserAIPassage *passage in passages) {
        if (chosen.count >= MAX((NSUInteger)1, maxResults) || passage.score < 0.55 * best) {
            break;
        }
        BOOL duplicate = NO;
        for (BrowserAIPassage *other in chosen) {
            if ([other.text containsString:passage.text] || [passage.text containsString:other.text]) {
                duplicate = YES;
            }
        }
        if (!duplicate) {
            [chosen addObject:passage];
        }
    }
    answer.passages = chosen;
#if DEBUG
    for (BrowserAIPassage *passage in chosen) {
        NSLog(@"[AI] Fundstelle #%lu Wert=%.2f (Begriffe %.2f, Emb %.2f, Art %d) %@", (unsigned long)passage.index, passage.score,
              passage.lexicalScore, passage.semanticScore, passage.typeMatch,
              passage.text.length > 110 ? [[passage.text substringToIndex:110] stringByAppendingString:@"…"] : passage.text);
    }
#endif
    return answer;
}

#pragma mark Ähnlichkeit (Befehle)

- (void)sentenceSimilaritiesOfText:(NSString *)text
                        toExamples:(NSArray<NSString *> *)examples
                          cacheKey:(NSString *)cacheKey
                        completion:(void (^)(NSArray<NSNumber *> *, NSString *))completion {
    dispatch_async(self.workQueue, ^{
        // Kurze Sätze: auf Deutsch/Englisch beschränken (sonst rät der Erkenner bei „Tabs vs Spaces“ irgendwas).
        NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
        recognizer.languageConstraints = @[NLLanguageGerman, NLLanguageEnglish];
        [recognizer processString:text];
        NSString *language = recognizer.dominantLanguage;
        NLEmbedding *embedding = [self sentenceEmbeddingForLanguage:language];
        NSMutableArray<NSNumber *> *scores = nil;
        if (embedding != nil) {
            NSUInteger dimension = embedding.dimension;
            float *buffer = calloc(dimension, sizeof(float));
            NSData *query = [embedding getVector:buffer forString:text] ? BrowserNLNormalizedVector(buffer, dimension) : nil;
            if (query != nil) {
                NSString *key = cacheKey.length > 0 ? [NSString stringWithFormat:@"vec:%@:%@:%lu", cacheKey, language, (unsigned long)examples.count] : nil;
                NSArray *vectors = key != nil ? self.sentenceEmbeddings[key] : nil;
                if (![vectors isKindOfClass:NSArray.class] || vectors.count != examples.count) {
                    NSMutableArray *computed = [NSMutableArray arrayWithCapacity:examples.count];
                    for (NSString *example in examples) {
                        NSData *vector = [embedding getVector:buffer forString:example] ? BrowserNLNormalizedVector(buffer, dimension) : nil;
                        [computed addObject:vector ?: (id)NSNull.null];
                    }
                    vectors = computed;
                    if (key != nil) {
                        self.sentenceEmbeddings[key] = computed;
                    }
                }
                scores = [NSMutableArray arrayWithCapacity:examples.count];
                for (id vector in vectors) {
                    [scores addObject:@([vector isKindOfClass:NSData.class] ? BrowserNLDot(query, vector) : 0.0)];
                }
            }
            free(buffer);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(scores, language);
        });
    });
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

#pragma mark - Befehlsindex (Ähnlichkeit Diktat ↔ Befehlstabelle)

// Schwellen für den Abgleich Diktat ↔ Befehlstabelle. Vorsichtig gewählt: lieber eine Suche zu viel als ein
// falscher Befehl. Gemessen mit den Testfällen aus docs/SIRI_STEUERUNG.md (ERWEITERUNGEN.md Abschnitt 19): Das Satz-
// Embedding allein trennt kurze Phrasen schlecht („neuer Tab Chrome“ 0,86 zu „neuen Tab“, „scroll ganz nach unten“
// am nächsten an „nach oben“), deshalb entscheidet es nie allein, sondern bestätigt nur einen knappen Begriffstreffer.
static const double kCommandLexicalThreshold = 0.80;   ///< Begriffe allein: Kosinus zur besten Phrase
static const double kCommandLexicalMargin = 0.12;      ///< Abstand zum besten anderen Befehl
static const double kCommandAgreeLexical = 0.62;       ///< Begriffe, wenn das Embedding denselben Befehl bestätigt
static const double kCommandSemanticThreshold = 0.75;  ///< Satz-Embedding: Kosinus zur besten Beispielphrase
static const double kCommandSemanticMargin = 0.05;     ///< Abstand zum besten anderen Befehl im Embedding
static const double kCommandNearMiss = 0.12;           ///< so weit unter der Schwelle gilt es als „knapp darunter“
static const NSUInteger kCommandMaxWords = 10;

/// Wörter ohne Unterscheidungskraft (Artikel, Pronomen, Höflichkeit). „an“, „aus“, „ein“, „zu“ bleiben: sie tragen Bedeutung.
static NSSet<NSString *> *BrowserCommandStopWords(void) {
    static NSSet<NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = [NSSet setWithArray:@[
            @"der", @"die", @"das", @"den", @"dem", @"des", @"eine", @"einen", @"einem", @"einer", @"eines", @"zur", @"zum", @"bei",
            @"mir", @"mich", @"uns", @"du", @"dir", @"ich", @"wir", @"ihr", @"kannst", @"könntest", @"kann", @"können", @"würdest",
            @"würde", @"möchte", @"möchtest", @"will", @"willst", @"soll", @"sollst", @"noch", @"einmal", @"bitte", @"mal", @"gerne",
            @"diese", @"diesen", @"dieser", @"dieses", @"this", @"that", @"the", @"a", @"to", @"of", @"me", @"my", @"us", @"you",
            @"can", @"could", @"would", @"will", @"i", @"want", @"wanna", @"lets", @"let", @"please", @"just", @"for", @"it"]];
    });
    return words;
}

/// Leichter Stammformer für Befehlswörter (Deutsch/Englisch): eine Endung weg, Stamm mindestens 3 Zeichen.
/// „neuen“/„neues“/„neuer“ → „neu“, „tabs“ → „tab“, „lade“/„laden“ → „lad“, „seite“/„seiten“ → „seit“.
static NSString *BrowserCommandStem(NSString *word) {
    if (word.length < 4) {
        return word;
    }
    for (NSString *suffix in @[@"en", @"er", @"es", @"em", @"e", @"n", @"s"]) {
        if ([word hasSuffix:suffix] && word.length - suffix.length >= 3) {
            return [word substringToIndex:word.length - suffix.length];
        }
    }
    return word;
}

/// Synonyme vor dem Normalisieren (nur eindeutige; „mal“ ist danach als Füllwort weg): „nochmal“, „noch einmal“,
/// „erneut“ → „neu“ („lade die Seite nochmal“ = „lade die Seite neu“).
static NSString *BrowserCommandApplySynonyms(NSString *text) {
    return [text stringByReplacingOccurrencesOfString:@"\\bnoch\\s*(ein)?mals?\\b|\\berneut\\b" withString:@"neu"
                                              options:NSRegularExpressionSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
}

/// Inhaltsbegriffe (Stämme, ohne Stoppwörter) eines normalisierten Textes.
static NSArray<NSString *> *BrowserCommandTerms(NSString *normalized) {
    NSMutableOrderedSet<NSString *> *terms = [NSMutableOrderedSet orderedSet];
    for (NSString *word in [normalized componentsSeparatedByString:@" "]) {
        if (word.length == 0 || [BrowserCommandStopWords() containsObject:word]) {
            continue;
        }
        [terms addObject:BrowserCommandStem(word)];
    }
    return terms.array;
}

/// Ein Befehl mit Argument ("reader|on") und den Begriffen seiner Phrasen.
@interface BrowserCommandClass : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *argument;
@property (nonatomic, copy) NSArray<NSString *> *phrases;
@property (nonatomic, copy) NSArray<NSSet<NSString *> *> *phraseTerms;
@end

@implementation BrowserCommandClass
@end

/// Index über die Befehlstabelle: Klassen, IDF der Begriffe (über Klassen), Beispiele fürs Embedding.
@interface BrowserCommandIndex : NSObject
@property (nonatomic, copy) NSArray<BrowserCommandClass *> *classes;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *idf;
@property (nonatomic) double unknownIDF;
@property (nonatomic, copy) NSArray<NSString *> *examples;          ///< für das Satz-Embedding (linear erweitert)
@property (nonatomic, copy) NSArray<NSNumber *> *exampleClassIndex; ///< Klasse je Beispiel
@end

@implementation BrowserCommandIndex

+ (BrowserCommandIndex *)sharedIndex {
    static BrowserCommandIndex *index;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        index = [BrowserCommandIndex new];
        NSMutableArray<BrowserCommandClass *> *classes = [NSMutableArray array];
        NSMutableArray<NSString *> *examples = [NSMutableArray array];
        NSMutableArray<NSNumber *> *exampleClass = [NSMutableArray array];
        for (BrowserCommand *command in [BrowserCommand allCommands]) {
            NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byArgument = [NSMutableDictionary dictionary];
            [command.phrases enumerateKeysAndObjectsUsingBlock:^(NSString *phrase, NSString *argument, __unused BOOL *stop) {
                if (byArgument[argument] == nil) {
                    byArgument[argument] = [NSMutableArray array];
                }
                [byArgument[argument] addObject:phrase];
            }];
            for (NSString *argument in [byArgument.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                BrowserCommandClass *item = [BrowserCommandClass new];
                item.name = command.name;
                item.argument = argument;
                item.phrases = [byArgument[argument] sortedArrayUsingSelector:@selector(compare:)];
                NSMutableArray<NSSet<NSString *> *> *terms = [NSMutableArray arrayWithCapacity:item.phrases.count];
                for (NSString *phrase in item.phrases) {
                    [terms addObject:[NSSet setWithArray:BrowserCommandTerms(phrase)]];
                }
                item.phraseTerms = terms;
                for (NSString *example in command.examplePhrases[argument] ?: @[]) {
                    [examples addObject:example];
                    [exampleClass addObject:@(classes.count)];
                }
                [classes addObject:item];
            }
        }
        NSMutableDictionary<NSString *, NSNumber *> *df = [NSMutableDictionary dictionary];
        for (BrowserCommandClass *item in classes) {
            NSMutableSet<NSString *> *vocabulary = [NSMutableSet set];
            for (NSSet<NSString *> *terms in item.phraseTerms) {
                [vocabulary unionSet:terms];
            }
            for (NSString *term in vocabulary) {
                df[term] = @(df[term].integerValue + 1);
            }
        }
        double count = (double)classes.count;
        NSMutableDictionary<NSString *, NSNumber *> *idf = [NSMutableDictionary dictionary];
        [df enumerateKeysAndObjectsUsingBlock:^(NSString *term, NSNumber *value, __unused BOOL *stop) {
            idf[term] = @(log(1.0 + count / value.doubleValue));
        }];
        index.classes = classes;
        index.idf = idf;
        index.unknownIDF = log(1.0 + count);
        index.examples = examples;
        index.exampleClassIndex = exampleClass;
    });
    return index;
}

/// IDF-gewichteter Kosinus zwischen zwei Begriffsmengen; unbekannte Begriffe wiegen wie die seltensten.
- (double)similarityOfTerms:(NSArray<NSString *> *)query toTerms:(NSSet<NSString *> *)phrase {
    double dot = 0.0, queryNorm = 0.0, phraseNorm = 0.0;
    for (NSString *term in query) {
        double w = self.idf[term] != nil ? self.idf[term].doubleValue : self.unknownIDF;
        queryNorm += w * w;
        if ([phrase containsObject:term]) {
            dot += w * w;
        }
    }
    for (NSString *term in phrase) {
        double w = self.idf[term].doubleValue;
        phraseNorm += w * w;
    }
    return queryNorm > 0 && phraseNorm > 0 ? dot / (sqrt(queryNorm) * sqrt(phraseNorm)) : 0.0;
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

#pragma mark Sprachbefehle (Ähnlichkeit)


- (void)matchCommandForText:(NSString *)text completion:(void (^)(BrowserCommandMatch *))completion {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *words = [BrowserCommandParser normalizedWordsOfText:BrowserCommandApplySynonyms(trimmed)];
    // Einzelwörter kennt der Parser (oder es ist eine Suche wie „Tab“), lange Sätze sind fast immer Suchen.
    if (trimmed.length == 0 || [BrowserCommandParser textLooksLikeAddress:trimmed] || words.count < 2 || words.count > kCommandMaxWords) {
        completion(nil);
        return;
    }
    BrowserCommandIndex *index = [BrowserCommandIndex sharedIndex];
    NSString *normalized = [words componentsJoinedByString:@" "];
    NSArray<NSString *> *terms = BrowserCommandTerms(normalized);
    BrowserCommandMatch *match = [BrowserCommandMatch new];
    match.semanticScore = -1.0;
    match.contentWordCount = terms.count;
    NSMutableArray<NSString *> *unknown = [NSMutableArray array];
    for (NSString *term in terms) {
        if (index.idf[term] == nil) {
            [unknown addObject:term];
        }
    }
    match.unknownWords = unknown;
    if (terms.count == 0) {
        match.reason = @"keine Inhaltswörter";
        completion(match);
        return;
    }

    // 1. Begriffe: beste Phrase je Klasse.
    NSUInteger classCount = index.classes.count;
    double *lexical = calloc(classCount, sizeof(double));
    NSMutableArray<NSString *> *bestPhrase = [NSMutableArray arrayWithCapacity:classCount];
    for (NSUInteger c = 0; c < classCount; c++) {
        BrowserCommandClass *item = index.classes[c];
        double best = 0.0;
        NSString *phrase = item.phrases.firstObject ?: @"";
        for (NSUInteger p = 0; p < item.phrases.count; p++) {
            double value = [index similarityOfTerms:terms toTerms:item.phraseTerms[p]];
            // Bei Gleichstand die kürzere Phrase (lesbarer im Log).
            if (value > best + 1e-9 || (fabs(value - best) < 1e-9 && item.phrases[p].length < phrase.length)) {
                best = value;
                phrase = item.phrases[p];
            }
        }
        lexical[c] = best;
        [bestPhrase addObject:phrase];
    }
    NSUInteger lexBest = 0;
    for (NSUInteger c = 1; c < classCount; c++) {
        if (lexical[c] > lexical[lexBest]) {
            lexBest = c;
        }
    }
    // Abstand zum besten anderen Befehl (anderer Name oder anderes Argument: „Reader an“ ≠ „Reader aus“).
    double lexSecond = 0.0;
    for (NSUInteger c = 0; c < classCount; c++) {
        if (c != lexBest) {
            lexSecond = MAX(lexSecond, lexical[c]);
        }
    }
    BrowserCommandClass *lexClass = index.classes[lexBest];
    match.name = lexClass.name;
    match.argument = lexClass.argument;
    match.example = bestPhrase[lexBest];
    match.lexicalScore = lexical[lexBest];
    match.lexicalMargin = lexical[lexBest] - lexSecond;

    id<BrowserAIProvider> provider = self.provider;
    void (^decide)(NSArray<NSNumber *> *, NSString *) = ^(NSArray<NSNumber *> *similarities, NSString *language) {
        NSUInteger semBest = NSNotFound;
        double semSecond = 0.0;
        if (similarities.count == index.examples.count && similarities.count > 0) {
            double *perClass = calloc(classCount, sizeof(double));
            for (NSUInteger e = 0; e < similarities.count; e++) {
                NSUInteger c = index.exampleClassIndex[e].unsignedIntegerValue;
                double value = similarities[e].doubleValue;
                if (value > perClass[c]) {
                    perClass[c] = value;
                }
            }
            semBest = 0;
            for (NSUInteger c = 1; c < classCount; c++) {
                if (perClass[c] > perClass[semBest]) {
                    semBest = c;
                }
            }
            for (NSUInteger c = 0; c < classCount; c++) {
                if (c != semBest) {
                    semSecond = MAX(semSecond, perClass[c]);
                }
            }
            match.semanticScore = perClass[semBest];
            match.semanticMargin = perClass[semBest] - semSecond;
            BrowserCommandClass *semClass = index.classes[semBest];
            match.semanticName = [NSString stringWithFormat:@"%@%@%@", semClass.name, semClass.argument.length > 0 ? @"|" : @"", semClass.argument];
            free(perClass);
        }
        // Unbekannte Wörter („Zukunft“, „Chrome“, „Safari“) machen aus jedem Treffer eine Suche: sie sind fast immer
        // der eigentliche Suchbegriff. Danach entweder ein klarer Begriffstreffer oder ein knapper, den das Embedding
        // mit demselben Befehl bestätigt.
        NSUInteger unknownCount = match.unknownWords.count;
        BOOL lexicalOK = unknownCount == 0 && match.lexicalScore >= kCommandLexicalThreshold && match.lexicalMargin >= kCommandLexicalMargin;
        BOOL agreeOK = unknownCount == 0 && semBest == lexBest && match.lexicalScore >= kCommandAgreeLexical &&
            match.lexicalMargin >= kCommandLexicalMargin && match.semanticScore >= kCommandSemanticThreshold &&
            match.semanticMargin >= kCommandSemanticMargin;
        if (lexicalOK) {
            match.accepted = YES;
            match.reason = @"Begriffe";
        } else if (agreeOK) {
            match.accepted = YES;
            match.reason = [NSString stringWithFormat:@"Begriffe + Embedding %@", language ?: @"?"];
        } else if (unknownCount > 0) {
            match.reason = @"unbekannte Wörter";
        } else if (match.lexicalScore >= kCommandLexicalThreshold - kCommandNearMiss ||
                   (semBest == lexBest && match.semanticScore >= kCommandSemanticThreshold - kCommandNearMiss / 2.0)) {
            match.reason = @"knapp darunter";
        } else {
            match.reason = @"zu unähnlich";
        }
        if (similarities == nil) {
            match.reason = [match.reason stringByAppendingFormat:@", kein Satz-Embedding (%@)", language ?: @"?"];
        }
        free(lexical);
        completion(match);
    };
    if ([provider respondsToSelector:@selector(sentenceSimilaritiesOfText:toExamples:cacheKey:completion:)]) {
        [provider sentenceSimilaritiesOfText:normalized toExamples:index.examples cacheKey:@"commands" completion:decide];
    } else {
        decide(nil, nil);
    }
}

#pragma mark Frag die Seite

static const NSUInteger kAskTextLength = 30000;

- (void)askQuestion:(NSString *)question
          inWebView:(BrowserWebView *)webView
         completion:(void (^)(BrowserAIAnswer *, NSDictionary<NSString *, id> *, NSError *))completion {
    id<BrowserAIProvider> provider = self.provider;
    if (webView == nil || ![provider respondsToSelector:@selector(findPassagesForQuestion:inText:maxResults:completion:)]) {
        completion(nil, nil, [NSError errorWithDomain:BrowserIntelligenceErrorDomain code:BrowserIntelligenceErrorNoPage
                                             userInfo:@{NSLocalizedDescriptionKey: @"Keine Seite geladen"}]);
        return;
    }
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [BrowserReaderMode textForWebView:webView maxLength:kAskTextLength completion:^(NSDictionary<NSString *, id> *info) {
        NSString *text = [info[@"text"] isKindOfClass:NSString.class] ? info[@"text"] : nil;
        CFAbsoluteTime fetched = CFAbsoluteTimeGetCurrent();
        if (text.length < 80) {
            NSLog(@"[AI] frag: kein Text (%lu Zeichen, Quelle %@)", (unsigned long)text.length, info[@"source"] ?: @"-");
            completion(nil, info, [NSError errorWithDomain:BrowserIntelligenceErrorDomain code:BrowserIntelligenceErrorNoText
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Kein Text auf der Seite gefunden"}]);
            return;
        }
        [provider findPassagesForQuestion:question inText:text maxResults:3 completion:^(BrowserAIAnswer *answer, NSError *error) {
            NSLog(@"[AI] frag \"%@\": %lu Treffer Quelle=%@ Text=%lu/%@ Zeichen Abruf=%.0f ms Rechnen=%.0f ms Sprache=%@ Frage=%@ Art=%@ "
                  "Begriffe=[%@] Kandidaten=%lu Verfahren=%@%@", question, (unsigned long)answer.passages.count, info[@"source"] ?: @"-",
                  (unsigned long)text.length, info[@"total"] ?: @"?", (fetched - start) * 1000.0, answer.duration * 1000.0,
                  answer.language ?: @"?", answer.questionLanguage ?: @"?", answer.questionType ?: @"-",
                  [answer.questionTerms componentsJoinedByString:@","] ?: @"", (unsigned long)answer.candidateCount, answer.method ?: @"-",
                  error != nil ? [@" Fehler=" stringByAppendingString:error.localizedDescription] : @"");
            completion(answer, info, error);
        }];
    }];
}

/// Sucht den Satz im sichtbaren Text (im Reader im Overlay #__reader), legt <span class="__bask"> um die Textstücke,
/// lässt sie kurz leuchten (Glasrand weiß, Glow blau, danach gelbliche Markierung) und scrollt hin. Nach 9 s blendet
/// die Markierung aus, nach 10 s werden die Spans wieder entfernt. Fußnoten (sup) und unsichtbare Knoten zählen nicht,
/// Leerraum wird zusammengefasst; findet sich der Satz nicht genau, genügen Anfang und Ende.
static NSString * const kAskHighlightScript =
    @"(function(args){try{"
     "var needle=String(args[0]||'');"
     "var A=window.__browserAsk;if(A&&A.clear){A.clear();}"
     "var css='.__bask{border-radius:.28em;-webkit-box-decoration-break:clone;box-decoration-break:clone;padding:.06em .08em;margin:0 -.08em;"
     "background-color:rgba(255,214,10,.34);box-shadow:0 0 0 1px rgba(255,255,255,.3),0 0 14px 2px rgba(64,156,255,.3);"
     "animation:__baskGlow 2.4s cubic-bezier(.2,.7,.2,1) both;}"
     "@keyframes __baskGlow{0%%{background-color:rgba(64,156,255,0);box-shadow:0 0 0 0 rgba(255,255,255,0),0 0 0 0 rgba(64,156,255,0);}"
     "18%%{background-color:rgba(120,190,255,.55);box-shadow:0 0 0 3px rgba(255,255,255,.65),0 0 36px 12px rgba(64,156,255,.85);}"
     "100%%{background-color:rgba(255,214,10,.34);box-shadow:0 0 0 1px rgba(255,255,255,.3),0 0 14px 2px rgba(64,156,255,.3);}}"
     ".__bask.__bask-out{animation:none;transition:background-color .9s ease,box-shadow .9s ease;background-color:rgba(255,214,10,0);box-shadow:none;}';"
     "var st=document.getElementById('__bask_style');if(!st){st=document.createElement('style');st.id='__bask_style';"
     "(document.head||document.documentElement).appendChild(st);}st.textContent=css;"
     "var root=document.getElementById('__reader')||document.body;if(!root){return JSON.stringify({found:false,why:'kein body'});}"
     "var skip='script,style,noscript,template,sup,textarea,select,.mw-editsection,#__reader .rd-meta,#__reader .rd-foot';"
     "var vis=new Map();"
     "function visible(el){if(vis.has(el)){return vis.get(el);}var v=true;"
     "if(el.closest(skip)){v=false;}else if(el.getClientRects().length===0){v=false;}"
     "else{var cs=getComputedStyle(el);if(cs.visibility==='hidden'){v=false;}}vis.set(el,v);return v;}"
     "function isSpace(k){return k===32||k===9||k===10||k===13||k===12||k===160||(k>=8192&&k<=8202)||k===8239||k===12288;}"
     "var nodes=[],hay=[],mapN=[],mapO=[],last=true,n;"
     "var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null);"
     "while((n=w.nextNode())){var p=n.parentElement;if(!p||!visible(p)){continue;}var d=n.data;if(!d){continue;}"
     "var ni=nodes.length;nodes.push(n);"
     "for(var i=0;i<d.length;i++){var k=d.charCodeAt(i);if(k===173){continue;}"
     "if(isSpace(k)){if(last){continue;}hay.push(' ');last=true;}else{hay.push(d[i]);last=false;}mapN.push(ni);mapO.push(i);}}"
     "var H=hay.join('');"
     "var N=needle.replace(/\\u00ad/g,'').replace(/\\[\\d{1,3}\\]/g,'').replace(/\\s+/g,' ').trim();"
     "if(N.length<4){return JSON.stringify({found:false,why:'zu kurz'});}"
     "var idx=H.indexOf(N),len=N.length,how='genau';"
     "if(idx<0){var Hl=H.toLowerCase(),Nl=N.toLowerCase();idx=Hl.indexOf(Nl);how='klein';"
     "if(idx<0){var head=Nl.slice(0,Math.min(60,Nl.length)),tail=Nl.slice(Math.max(0,Nl.length-40));"
     "var s=Hl.indexOf(head);"
     "if(s>=0){var e=Hl.indexOf(tail,s);if(e>=0&&e-s<Nl.length*1.6+40){idx=s;len=e+tail.length-s;how='anfang+ende';}"
     "else{idx=s;len=Math.min(Nl.length,Hl.length-s);how='anfang';}}"
     "else if(tail.length>=24){var e2=Hl.indexOf(tail);if(e2>=0){idx=Math.max(0,e2+tail.length-Nl.length);len=e2+tail.length-idx;how='ende';}}}}"
     "if(idx<0){return JSON.stringify({found:false,why:'nicht gefunden',nodes:nodes.length,chars:H.length});}"
     "var sN=mapN[idx],sO=mapO[idx],eN=mapN[idx+len-1],eO=mapO[idx+len-1]+1,spans=[];"
     "for(var q=sN;q<=eN;q++){var t=nodes[q];var a=(q===sN)?sO:0,b=(q===eN)?eO:t.data.length;if(b<=a){continue;}"
     "var mid=t;if(a>0){mid=t.splitText(a);}if(b-a<mid.data.length){mid.splitText(b-a);}"
     "if(!mid.data.trim()){continue;}"
     "var sp=document.createElement('span');sp.className='__bask';mid.parentNode.insertBefore(sp,mid);sp.appendChild(mid);spans.push(sp);}"
     "if(!spans.length){return JSON.stringify({found:false,why:'keine Spans'});}"
     "var timers=[];"
     "function clear(){timers.forEach(clearTimeout);timers=[];spans.forEach(function(sp){var par=sp.parentNode;if(!par){return;}"
     "while(sp.firstChild){par.insertBefore(sp.firstChild,sp);}par.removeChild(sp);if(par.normalize){par.normalize();}});spans=[];"
     "if(window.__browserAsk===api){window.__browserAsk=null;}}"
     "function fade(){spans.forEach(function(sp){sp.classList.add('__bask-out');});timers.push(setTimeout(clear,1000));}"
     "var api={clear:clear,fade:fade};window.__browserAsk=api;"
     "timers.push(setTimeout(fade,9000));"
     "try{spans[0].scrollIntoView({block:'center',inline:'nearest',behavior:'smooth'});}catch(x){spans[0].scrollIntoView();}"
     "var r=spans[0].getBoundingClientRect();"
     "return JSON.stringify({found:true,how:how,spans:spans.length,y:Math.round(r.top+window.scrollY),chars:H.length,"
     "text:H.substr(idx,Math.min(len,90))});"
     "}catch(e){return JSON.stringify({found:false,why:'e:'+e});}})(%@)";

- (void)highlightPassage:(NSString *)passage
               inWebView:(BrowserWebView *)webView
              completion:(void (^)(NSDictionary<NSString *, id> *))completion {
    NSData *json = [NSJSONSerialization dataWithJSONObject:@[passage ?: @""] options:0 error:nil];
    NSString *arguments = json != nil ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    if (webView == nil || arguments == nil) {
        if (completion != nil) {
            completion(nil);
        }
        return;
    }
    [webView evaluateJavaScriptAsync:[NSString stringWithFormat:kAskHighlightScript, arguments] completion:^(id result) {
        NSDictionary *parsed = nil;
        if ([result isKindOfClass:NSString.class] && [(NSString *)result hasPrefix:@"{"]) {
            parsed = [NSJSONSerialization JSONObjectWithData:[(NSString *)result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }
        NSDictionary *info = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        NSLog(@"[AI] markieren: %@", info ?: result ?: @"(keine Antwort)");
        if (completion != nil) {
            completion(info);
        }
    }];
}

- (void)clearPassageHighlightInWebView:(BrowserWebView *)webView {
    [webView evaluateJavaScriptAsync:@"(function(){var A=window.__browserAsk;if(A&&A.fade){A.fade();}return 1;})()" completion:nil];
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
        } else if (info.hasLogin && !BrowserAppleTranslator.sharedTranslator.available) {
            // Nur bei Google ein Grund: Apple übersetzt in der Seite, Anmeldung und Cookies bleiben.
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

+ (NSURL *)originalURLForTranslationProxyURL:(NSURL *)url {
    if (![self isTranslationProxyURL:url]) {
        return nil;
    }
    NSString *host = url.host.lowercaseString;
    NSString *proxyPart = [host substringToIndex:host.length - @".translate.goog".length];
    if (proxyPart.length == 0 || [host isEqualToString:@"translate.goog"]) {
        return nil;
    }
    // Googles Schema rückwärts: "--" war ein Bindestrich, "-" ein Punkt.
    NSString *marker = @"\u00A7\u00A7";
    NSString *original = [[[proxyPart stringByReplacingOccurrencesOfString:@"--" withString:marker]
                           stringByReplacingOccurrencesOfString:@"-" withString:@"."]
                          stringByReplacingOccurrencesOfString:marker withString:@"-"];
    NSURLComponents *source = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *scheme = @"https";
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in source.queryItems) {
        if ([item.name isEqualToString:@"_x_tr_sch"]) {
            scheme = item.value.length > 0 ? item.value : scheme;
        } else if (![item.name hasPrefix:@"_x_tr_"]) {
            [items addObject:item];
        }
    }
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = scheme;
    components.host = original;
    components.percentEncodedPath = source.percentEncodedPath.length > 0 ? source.percentEncodedPath : @"/";
    components.queryItems = items.count > 0 ? items : nil;
    components.percentEncodedFragment = source.percentEncodedFragment;
    return components.URL;
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
