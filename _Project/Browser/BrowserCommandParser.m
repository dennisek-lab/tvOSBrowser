//
//  BrowserCommandParser.m
//  Browser
//

#import "BrowserCommandParser.h"
#import "BrowserCommand.h"

@interface BrowserParsedCommand ()
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy, nullable) NSString *argument;
@property (nonatomic, readwrite, copy) NSString *matchedPhrase;
@end

@implementation BrowserParsedCommand

+ (instancetype)commandWithName:(NSString *)name argument:(NSString *)argument phrase:(NSString *)phrase {
    BrowserParsedCommand *parsed = [BrowserParsedCommand new];
    parsed.name = name;
    parsed.argument = argument.length > 0 ? argument : nil;
    parsed.matchedPhrase = phrase;
    return parsed;
}

@end

@implementation BrowserCommandParser

/// Füllwörter, die beim Abgleich mit ganzen Phrasen nicht zählen.
+ (NSSet<NSString *> *)fillerWords {
    static NSSet<NSString *> *words;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        words = [NSSet setWithArray:@[@"bitte", @"please", @"mal", @"doch", @"jetzt", @"hey", @"ok", @"okay", @"siri", @"now",
                                      @"ahora", @"oye", @"porfa", @"maintenant", @"svp", @"stp"]];
    });
    return words;
}

/// Füllwörter aus mehreren Wörtern („por favor“, „s'il vous plaît“ nach der Normalisierung).
+ (NSArray<NSArray<NSString *> *> *)fillerSequences {
    static NSArray<NSArray<NSString *> *> *sequences;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sequences = @[@[@"por", @"favor"], @[@"s", @"il", @"vous", @"plaît"], @[@"s", @"il", @"vous", @"plait"],
                      @[@"s", @"il", @"te", @"plaît"], @[@"s", @"il", @"te", @"plait"]];
    });
    return sequences;
}

/// Länge der Füllwortfolge, mit der words ab index beginnt (0 = keine).
+ (NSUInteger)fillerSequenceLengthInWords:(NSArray<NSString *> *)words atIndex:(NSUInteger)index {
    for (NSArray<NSString *> *sequence in [self fillerSequences]) {
        if (index + sequence.count <= words.count &&
            [[words subarrayWithRange:NSMakeRange(index, sequence.count)] isEqualToArray:sequence]) {
            return sequence.count;
        }
    }
    return 0;
}

/// Französische Elision: „l'onglet“, „d'accueil“, „qu'est-ce“ werden zwei Wörter („l onglet“). Andere Apostrophe
/// („geht's“, „don't“) fallen wie bisher einfach weg.
+ (BOOL)isElisionStem:(NSString *)stem {
    static NSSet<NSString *> *stems;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stems = [NSSet setWithArray:@[@"l", @"d", @"j", @"n", @"s", @"c", @"m", @"t", @"qu", @"jusqu", @"lorsqu", @"puisqu"]];
    });
    return [stems containsObject:stem];
}

/// Einzelnes Wort normalisieren: klein, Satzzeichen weg (Punkt zwischen Buchstaben bleibt, z. B. heise.de),
/// Bindestrich und Schrägstrich werden Leerzeichen, französische Elision wird getrennt (siehe isElisionStem:).
+ (NSString *)normalizedToken:(NSString *)token {
    NSString *lower = [token lowercaseString];
    NSMutableString *result = [NSMutableString stringWithCapacity:lower.length];
    NSCharacterSet *alnum = NSCharacterSet.alphanumericCharacterSet;
    NSCharacterSet *spaceLike = [NSCharacterSet characterSetWithCharactersInString:@"-‐‑–—/_"];
    NSUInteger length = lower.length;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([alnum characterIsMember:c]) {
            [result appendFormat:@"%C", c];
        } else if ([spaceLike characterIsMember:c]) {
            [result appendString:@" "];
        } else if ((c == '\'' || c == 0x2019) && i + 1 < length && [alnum characterIsMember:[lower characterAtIndex:i + 1]] &&
                   [self isElisionStem:[[result componentsSeparatedByString:@" "] lastObject]]) {
            [result appendString:@" "];
        } else if (c == '.' && i > 0 && i + 1 < length &&
                   [alnum characterIsMember:[lower characterAtIndex:i - 1]] && [alnum characterIsMember:[lower characterAtIndex:i + 1]]) {
            [result appendString:@"."];
        }
        // Sonst (Satzzeichen, Anführungszeichen) weglassen.
    }
    return result;
}

/// Wörter des Textes nach der Normalisierung, ohne Füllwörter.
+ (NSArray<NSString *> *)normalizedWordsOfText:(NSString *)text {
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        NSString *normalized = [self normalizedToken:raw];
        for (NSString *word in [normalized componentsSeparatedByString:@" "]) {
            if (word.length > 0) {
                [all addObject:word];
            }
        }
    }
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSUInteger i = 0; i < all.count; i++) {
        NSUInteger skip = [self fillerSequenceLengthInWords:all atIndex:i];
        if (skip > 0) {
            i += skip - 1;
        } else if (![[self fillerWords] containsObject:all[i]]) {
            [words addObject:all[i]];
        }
    }
    return words;
}

+ (NSString *)normalizedText:(NSString *)text {
    return [[self normalizedWordsOfText:text] componentsJoinedByString:@" "];
}

+ (BOOL)textLooksLikeAddress:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) {
        return NO;
    }
    return [trimmed containsString:@"://"] || [trimmed hasPrefix:@"localhost"] ||
        ([trimmed containsString:@"."] && ![trimmed hasSuffix:@"."] && ![trimmed hasPrefix:@"."]);
}

+ (NSString *)addressFromSpokenText:(NSString *)text {
    NSString *lower = [[text lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Satzzeichen am Ende (Diktat setzt gern einen Punkt).
    while (lower.length > 0 && [@".!?,;:" containsString:[lower substringFromIndex:lower.length - 1]]) {
        lower = [lower substringToIndex:lower.length - 1];
    }
    for (NSString *spoken in @[@" punkt ", @" dot ", @" punto ", @" point "]) {
        lower = [lower stringByReplacingOccurrencesOfString:spoken withString:@"."];
    }
    if (![lower containsString:@"://"]) {
        lower = [lower stringByReplacingOccurrencesOfString:@" " withString:@""];
    }
    return [self textLooksLikeAddress:lower] ? lower : nil;
}

/// Zahl aus Ziffern oder Zahlwort (Deutsch, Englisch, Spanisch, Französisch), sonst -1.
+ (NSInteger)numberFromWord:(NSString *)word {
    NSScanner *scanner = [NSScanner scannerWithString:word];
    NSInteger value = 0;
    if ([scanner scanInteger:&value] && scanner.isAtEnd) {
        return value;
    }
    NSDictionary<NSString *, NSNumber *> *words = @{
        @"eine": @1, @"ein": @1, @"einer": @1, @"one": @1, @"a": @1,
        @"zwei": @2, @"two": @2, @"drei": @3, @"three": @3, @"fünf": @5, @"five": @5,
        @"zehn": @10, @"ten": @10, @"fünfzehn": @15, @"fifteen": @15, @"zwanzig": @20, @"twenty": @20,
        @"dreißig": @30, @"dreissig": @30, @"thirty": @30, @"vierzig": @40, @"forty": @40,
        @"fünfzig": @50, @"fifty": @50, @"sechzig": @60, @"sixty": @60, @"neunzig": @90, @"ninety": @90,
        // Spanisch
        @"uno": @1, @"una": @1, @"un": @1, @"dos": @2, @"tres": @3, @"cuatro": @4, @"cinco": @5, @"seis": @6, @"siete": @7,
        @"ocho": @8, @"nueve": @9, @"diez": @10, @"quince": @15, @"veinte": @20, @"treinta": @30, @"cuarenta": @40,
        @"cincuenta": @50, @"sesenta": @60, @"noventa": @90,
        // Französisch („un“ wie im Spanischen)
        @"une": @1, @"deux": @2, @"trois": @3, @"quatre": @4, @"cinq": @5, @"six": @6, @"sept": @7, @"huit": @8, @"neuf": @9,
        @"dix": @10, @"quinze": @15, @"vingt": @20, @"trente": @30, @"quarante": @40, @"cinquante": @50, @"soixante": @60,
    };
    NSNumber *number = words[word];
    return number != nil ? number.integerValue : -1;
}

/// „30 Sekunden zurück“, „spul 10 Sekunden vor“, „skip forward 30 seconds“, „eine Minute zurück“,
/// „30 segundos atrás“, „retrocede 10 segundos“, „recule de 30 secondes“, „avance d'une minute“.
+ (BrowserParsedCommand *)seekCommandInNormalizedText:(NSString *)normalized {
    static NSRegularExpression *numberFirst;
    static NSRegularExpression *directionFirst;
    static NSRegularExpression *verbFirst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *units = @"(sekunden|sekunde|sek|seconds|second|secs|sec|minuten|minute|min|minutes"
                          @"|segundos|segundo|seg|minutos|minuto|secondes|seconde)";
        NSString *directions = @"(vor|vorwärts|weiter|nach vorne|zurück|forward|ahead|back|backward|backwards"
                               @"|adelante|hacia adelante|para adelante|atrás|atras|hacia atrás|hacia atras|para atrás|para atras"
                               @"|en avant|en arrière|en arriere|arrière|arriere)";
        NSString *verbs = @"spul|spule|spring|springe|geh|gehe|skip|jump|go|salta|saltar|ve|ir|vuelve|volver|saute|sauter|va|aller|reviens|revenir";
        numberFirst = [NSRegularExpression regularExpressionWithPattern:
                       [NSString stringWithFormat:@"^(?:(?:%@) )?(\\S+) %@ %@$", verbs, units, directions]
                                                                options:0 error:nil];
        directionFirst = [NSRegularExpression regularExpressionWithPattern:
                          [NSString stringWithFormat:@"^(?:%@) %@ (\\S+) %@$", verbs, directions, units]
                                                                   options:0 error:nil];
        // Verb trägt die Richtung: „retrocede 30 segundos“, „avance de 30 secondes“, „recule d une minute“.
        verbFirst = [NSRegularExpression regularExpressionWithPattern:
                     [NSString stringWithFormat:@"^(retrocede|retroceder|rebobina|rebobinar|recule|reculer|rembobine|rembobiner"
                                                @"|adelanta|adelantar|avanza|avanzar|avance|avancer) (?:de |d )?(\\S+) %@$", units]
                                                              options:0 error:nil];
    });
    NSString *numberWord = nil, *unit = nil, *direction = nil;
    NSRange all = NSMakeRange(0, normalized.length);
    NSTextCheckingResult *match = [numberFirst firstMatchInString:normalized options:0 range:all];
    if (match != nil) {
        numberWord = [normalized substringWithRange:[match rangeAtIndex:1]];
        unit = [normalized substringWithRange:[match rangeAtIndex:2]];
        direction = [normalized substringWithRange:[match rangeAtIndex:3]];
    } else if ((match = [directionFirst firstMatchInString:normalized options:0 range:all]) != nil) {
        direction = [normalized substringWithRange:[match rangeAtIndex:1]];
        numberWord = [normalized substringWithRange:[match rangeAtIndex:2]];
        unit = [normalized substringWithRange:[match rangeAtIndex:3]];
    } else if ((match = [verbFirst firstMatchInString:normalized options:0 range:all]) != nil) {
        NSString *verb = [normalized substringWithRange:[match rangeAtIndex:1]];
        BOOL back = [verb hasPrefix:@"retroced"] || [verb hasPrefix:@"rebobin"] || [verb hasPrefix:@"recul"] || [verb hasPrefix:@"rembobin"];
        direction = back ? @"back" : @"forward";
        numberWord = [normalized substringWithRange:[match rangeAtIndex:2]];
        unit = [normalized substringWithRange:[match rangeAtIndex:3]];
    } else {
        return nil;
    }
    NSInteger amount = [self numberFromWord:numberWord];
    if (amount <= 0 || amount > 3600) {
        return nil;
    }
    if ([unit hasPrefix:@"min"]) {
        amount *= 60;
    }
    BOOL backwards = [@[@"zurück", @"back", @"backward", @"backwards", @"atrás", @"atras", @"hacia atrás", @"hacia atras",
                        @"para atrás", @"para atras", @"en arrière", @"en arriere", @"arrière", @"arriere"] containsObject:direction];
    return [BrowserParsedCommand commandWithName:@"seek"
                                        argument:[NSString stringWithFormat:@"%ld", (long)(backwards ? -amount : amount)]
                                          phrase:normalized];
}

/// Wie viele Originalwörter ab index eine mehrteilige Füllwortfolge bilden („S'il vous plaît,“ = 3), sonst 0.
+ (NSUInteger)tokensOfFillerSequenceInTokens:(NSArray<NSString *> *)tokens atIndex:(NSUInteger)index {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSUInteger i = index; i < tokens.count && i < index + 4; i++) {
        for (NSString *word in [[self normalizedToken:tokens[i]] componentsSeparatedByString:@" "]) {
            if (word.length > 0) {
                [words addObject:word];
            }
        }
        NSUInteger length = [self fillerSequenceLengthInWords:words atIndex:0];
        if (length > 0 && length == words.count) {
            return i - index + 1;
        }
    }
    return 0;
}

/// Präfix wie „suche nach“ am Anfang: liefert den Rest im Originalwortlaut (ohne Satzzeichen am Ende).
+ (NSString *)argumentAfterPrefix:(NSString *)prefix inText:(NSString *)text {
    NSArray<NSString *> *prefixWords = [prefix componentsSeparatedByString:@" "];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (raw.length > 0) {
            [tokens addObject:raw];
        }
    }
    NSUInteger index = 0;
    // Füllwörter und reine Satzzeichen vorne überspringen („Bitte suche …“, „Por favor, busca …“).
    while (index < tokens.count) {
        NSString *normalized = [self normalizedToken:tokens[index]];
        if (normalized.length == 0 || [[self fillerWords] containsObject:normalized]) {
            index++;
            continue;
        }
        NSUInteger skipped = [self tokensOfFillerSequenceInTokens:tokens atIndex:index];
        if (skipped > 0) {
            index += skipped;
            continue;
        }
        break;
    }
    for (NSString *word in prefixWords) {
        if (index >= tokens.count || ![[self normalizedToken:tokens[index]] isEqualToString:word]) {
            return nil;
        }
        index++;
    }
    if (index >= tokens.count) {
        return nil;
    }
    NSString *rest = [[tokens subarrayWithRange:NSMakeRange(index, tokens.count - index)] componentsJoinedByString:@" "];
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@" .!?,;:\"'„“”‚‘’«»¿¡"];
    rest = [rest stringByTrimmingCharactersInSet:trim];
    return rest.length > 0 ? rest : nil;
}

/// Beginnt der Text mit einem Fragewort (Deutsch, Englisch, Spanisch, Französisch)? Für „frage …“, „ask …“, „pregunta …“, „demande …“.
+ (BOOL)textStartsWithQuestionWord:(NSString *)text {
    static NSSet<NSString *> *words;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        words = [NSSet setWithArray:@[@"wann", @"wer", @"wen", @"wem", @"wessen", @"was", @"wie", @"wo", @"woher", @"wohin", @"warum",
                                      @"weshalb", @"wieso", @"wozu", @"womit", @"wofür", @"worüber", @"welche", @"welcher", @"welches",
                                      @"welchen", @"wieviel", @"wieviele", @"ob", @"gibt", @"steht", @"kostet", @"hat", @"ist", @"sind",
                                      @"when", @"who", @"whom", @"whose", @"what", @"how", @"where", @"why", @"which", @"does", @"do",
                                      @"did", @"is", @"are", @"was", @"were", @"can", @"has", @"have",
                                      // Spanisch (Akzent oft weggelassen; „¿“ fällt bei der Normalisierung weg)
                                      @"qué", @"que", @"quién", @"quien", @"quiénes", @"quienes", @"cómo", @"como", @"cuándo", @"cuando",
                                      @"dónde", @"donde", @"adónde", @"adonde", @"cuál", @"cual", @"cuáles", @"cuales", @"cuánto", @"cuanto",
                                      @"cuánta", @"cuanta", @"cuántos", @"cuantos", @"cuántas", @"cuantas", @"por", @"hay", @"es", @"son",
                                      @"está", @"esta", @"tiene", @"cuesta", @"si",
                                      // Französisch („qu'est-ce que“ → „qu est ce que“, „c'est quoi“ → „c est quoi“)
                                      @"qui", @"quoi", @"quand", @"où", @"comment", @"combien", @"pourquoi", @"quel", @"quelle", @"quels",
                                      @"quelles", @"lequel", @"laquelle", @"est", @"qu", @"y", @"c", @"coûte", @"coute"]];
    });
    NSString *first = [self normalizedWordsOfText:text].firstObject;
    return first != nil && [words containsObject:first];
}

+ (BrowserParsedCommand *)parseText:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || [self textLooksLikeAddress:trimmed]) {
        return nil;
    }
    NSString *normalized = [self normalizedText:trimmed];
    if (normalized.length == 0) {
        return nil;
    }
    // 1. Ganze Phrase aus der Tabelle.
    for (BrowserCommand *command in [BrowserCommand allCommands]) {
        NSString *argument = command.phrases[normalized];
        if (argument != nil) {
            return [BrowserParsedCommand commandWithName:command.name argument:argument phrase:normalized];
        }
    }
    // 2. Spulen mit Zahl.
    BrowserParsedCommand *seek = [self seekCommandInNormalizedText:normalized];
    if (seek != nil) {
        return seek;
    }
    // 3. Präfixe: „suche X“ erzwingt die Suche, „öffne X“ eine Adresse (nur wenn X wie eine Adresse klingt).
    for (BrowserCommand *command in [BrowserCommand allCommands]) {
        for (NSString *prefix in command.prefixes) {
            if (![normalized hasPrefix:[prefix stringByAppendingString:@" "]]) {
                continue;
            }
            NSString *argument = [self argumentAfterPrefix:prefix inText:trimmed];
            if (argument == nil) {
                continue;
            }
            if ([command.name isEqualToString:@"ask"] && [@[@"frage", @"ask", @"pregunta", @"demande"] containsObject:prefix] &&
                ![self textStartsWithQuestionWord:argument]) {
                // „Frage der Woche“, „ask jeeves“, „pregunta del día“: Nomen bzw. Name, keine Frage an die Seite.
                return nil;
            }
            if ([command.name isEqualToString:@"open"]) {
                NSString *address = [self addressFromSpokenText:argument];
                if (address == nil) {
                    // „Öffne Wikipedia“ / „open source software“: keine Adresse, also normale Suche mit dem ganzen Text.
                    return nil;
                }
                argument = address;
            }
            return [BrowserParsedCommand commandWithName:command.name argument:argument phrase:[prefix stringByAppendingString:@" …"]];
        }
    }
    return nil;
}

+ (NSString *)describeParseOfText:(NSString *)text {
    BrowserParsedCommand *parsed = [self parseText:text];
    if (parsed == nil) {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        return [self textLooksLikeAddress:trimmed] ? @"keine -> Adresse" : @"keine -> Suche";
    }
    return [NSString stringWithFormat:@"%@%@%@ (\"%@\")", parsed.name, parsed.argument != nil ? @"|" : @"",
            parsed.argument ?: @"", parsed.matchedPhrase];
}

@end
