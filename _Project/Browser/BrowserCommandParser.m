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
        words = [NSSet setWithArray:@[@"bitte", @"please", @"mal", @"doch", @"jetzt", @"hey", @"ok", @"okay", @"siri", @"now"]];
    });
    return words;
}

/// Einzelnes Wort normalisieren: klein, Satzzeichen weg (Punkt zwischen Buchstaben bleibt, z. B. heise.de),
/// Bindestrich und Schrägstrich werden Leerzeichen.
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
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        NSString *normalized = [self normalizedToken:raw];
        for (NSString *word in [normalized componentsSeparatedByString:@" "]) {
            if (word.length > 0 && ![[self fillerWords] containsObject:word]) {
                [words addObject:word];
            }
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
    for (NSString *spoken in @[@" punkt ", @" dot "]) {
        lower = [lower stringByReplacingOccurrencesOfString:spoken withString:@"."];
    }
    if (![lower containsString:@"://"]) {
        lower = [lower stringByReplacingOccurrencesOfString:@" " withString:@""];
    }
    return [self textLooksLikeAddress:lower] ? lower : nil;
}

/// Zahl aus Ziffern oder Zahlwort (Deutsch/Englisch), sonst -1.
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
    };
    NSNumber *number = words[word];
    return number != nil ? number.integerValue : -1;
}

/// „30 Sekunden zurück“, „spul 10 Sekunden vor“, „skip forward 30 seconds“, „eine Minute zurück“.
+ (BrowserParsedCommand *)seekCommandInNormalizedText:(NSString *)normalized {
    static NSRegularExpression *numberFirst;
    static NSRegularExpression *directionFirst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *units = @"(sekunden|sekunde|sek|seconds|second|secs|sec|minuten|minute|min|minutes)";
        NSString *directions = @"(vor|vorwärts|weiter|nach vorne|zurück|forward|ahead|back|backward|backwards)";
        numberFirst = [NSRegularExpression regularExpressionWithPattern:
                       [NSString stringWithFormat:@"^(?:(?:spul|spule|spring|springe|geh|gehe|skip|jump|go) )?(\\S+) %@ %@$", units, directions]
                                                                options:0 error:nil];
        directionFirst = [NSRegularExpression regularExpressionWithPattern:
                          [NSString stringWithFormat:@"^(?:skip|jump|go|spul|spule|spring|springe) %@ (\\S+) %@$", directions, units]
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
    BOOL backwards = [@[@"zurück", @"back", @"backward", @"backwards"] containsObject:direction];
    return [BrowserParsedCommand commandWithName:@"seek"
                                        argument:[NSString stringWithFormat:@"%ld", (long)(backwards ? -amount : amount)]
                                          phrase:normalized];
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
    // Füllwörter und reine Satzzeichen vorne überspringen („Bitte suche …“).
    while (index < tokens.count) {
        NSString *normalized = [self normalizedToken:tokens[index]];
        if (normalized.length == 0 || [[self fillerWords] containsObject:normalized]) {
            index++;
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
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@" .!?,;:\"'„“”‚‘’«»"];
    rest = [rest stringByTrimmingCharactersInSet:trim];
    return rest.length > 0 ? rest : nil;
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
