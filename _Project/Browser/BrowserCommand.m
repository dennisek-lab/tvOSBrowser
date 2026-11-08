//
//  BrowserCommand.m
//  Browser
//

#import "BrowserCommand.h"

@interface BrowserCommand ()
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *title;
@property (nonatomic, readwrite, copy) NSString *symbolName;
@property (nonatomic, readwrite) BrowserCommandArgument argumentKind;
@property (nonatomic, readwrite) BOOL requiresVideo;
@property (nonatomic, readwrite, copy) NSDictionary<NSString *, NSString *> *phrases;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *prefixes;
@property (nonatomic, readwrite, copy) NSDictionary<NSString *, NSArray<NSString *> *> *examplePhrases;
@end

/// Erweitert Muster mit Alternativen in Klammern: "(starte|start) (den |)reader"
/// → "starte den reader", "starte reader", "start den reader", "start reader". Keine Verschachtelung.
static void BrowserCommandExpandPattern(NSString *pattern, NSMutableArray<NSString *> *output) {
    NSRange open = [pattern rangeOfString:@"("];
    if (open.location == NSNotFound) {
        NSArray<NSString *> *words = [pattern componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSMutableArray<NSString *> *kept = [NSMutableArray array];
        for (NSString *word in words) {
            if (word.length > 0) {
                [kept addObject:word];
            }
        }
        NSString *phrase = [kept componentsJoinedByString:@" "];
        if (phrase.length > 0) {
            [output addObject:phrase];
        }
        return;
    }
    NSRange close = [pattern rangeOfString:@")" options:0 range:NSMakeRange(open.location, pattern.length - open.location)];
    if (close.location == NSNotFound) {
        [output addObject:pattern];
        return;
    }
    NSString *head = [pattern substringToIndex:open.location];
    NSString *tail = [pattern substringFromIndex:NSMaxRange(close)];
    NSString *inner = [pattern substringWithRange:NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))];
    for (NSString *alternative in [inner componentsSeparatedByString:@"|"]) {
        BrowserCommandExpandPattern([NSString stringWithFormat:@"%@%@%@", head, alternative, tail], output);
    }
}

/// Wie BrowserCommandExpandPattern, aber linear: erst alle Gruppen mit der ersten Alternative, dann jede weitere
/// Alternative einer Gruppe einzeln (die übrigen Gruppen bleiben bei der ersten). Aus 10 × 5 × 10 × 3 Kombinationen
/// werden so 25 Beispiele, die trotzdem jedes Wort der Tabelle enthalten.
static void BrowserCommandExpandPatternLinear(NSString *pattern, NSMutableArray<NSString *> *output) {
    NSMutableArray<NSString *> *literals = [NSMutableArray array];
    NSMutableArray<NSArray<NSString *> *> *groups = [NSMutableArray array];
    NSUInteger cursor = 0;
    while (cursor < pattern.length) {
        NSRange open = [pattern rangeOfString:@"(" options:0 range:NSMakeRange(cursor, pattern.length - cursor)];
        NSRange close = open.location == NSNotFound ? open
            : [pattern rangeOfString:@")" options:0 range:NSMakeRange(open.location, pattern.length - open.location)];
        if (open.location == NSNotFound || close.location == NSNotFound) {
            break;
        }
        [literals addObject:[pattern substringWithRange:NSMakeRange(cursor, open.location - cursor)]];
        [groups addObject:[[pattern substringWithRange:NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))]
                           componentsSeparatedByString:@"|"]];
        cursor = NSMaxRange(close);
    }
    NSString *tail = cursor < pattern.length ? [pattern substringFromIndex:cursor] : @"";
    NSString * (^compose)(NSInteger, NSUInteger) = ^NSString *(NSInteger groupIndex, NSUInteger alternative) {
        NSMutableString *text = [NSMutableString string];
        for (NSUInteger g = 0; g < groups.count; g++) {
            [text appendString:literals[g]];
            [text appendString:groups[g][(NSInteger)g == groupIndex ? alternative : 0]];
        }
        [text appendString:tail];
        NSArray<NSString *> *words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
    };
    NSMutableOrderedSet<NSString *> *unique = [NSMutableOrderedSet orderedSetWithObject:compose(-1, 0)];
    for (NSUInteger g = 0; g < groups.count; g++) {
        for (NSUInteger a = 1; a < groups[g].count; a++) {
            [unique addObject:compose((NSInteger)g, a)];
        }
    }
    for (NSString *phrase in unique) {
        if (phrase.length > 0) {
            [output addObject:phrase];
        }
    }
}

@implementation BrowserCommand

+ (BrowserCommand *)commandWithName:(NSString *)name
                              title:(NSString *)title
                             symbol:(NSString *)symbol
                           argument:(BrowserCommandArgument)argument
                              video:(BOOL)video
                           patterns:(NSDictionary<NSString *, NSArray<NSString *> *> *)patterns
                           prefixes:(NSArray<NSString *> *)prefixes {
    BrowserCommand *command = [BrowserCommand new];
    command.name = name;
    command.title = title;
    command.symbolName = symbol;
    command.argumentKind = argument;
    command.requiresVideo = video;
    NSMutableDictionary<NSString *, NSString *> *phrases = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *examples = [NSMutableDictionary dictionary];
    [patterns enumerateKeysAndObjectsUsingBlock:^(NSString *arg, NSArray<NSString *> *list, __unused BOOL *stop) {
        NSMutableArray<NSString *> *linear = [NSMutableArray array];
        for (NSString *pattern in list) {
            NSMutableArray<NSString *> *expanded = [NSMutableArray array];
            BrowserCommandExpandPattern(pattern, expanded);
            for (NSString *phrase in expanded) {
                phrases[phrase] = arg;
            }
            BrowserCommandExpandPatternLinear(pattern, linear);
        }
        examples[arg] = [[NSOrderedSet orderedSetWithArray:linear] array];
    }];
    command.phrases = phrases;
    command.examplePhrases = examples;
    command.prefixes = [prefixes sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return a.length > b.length ? NSOrderedAscending : (a.length < b.length ? NSOrderedDescending : NSOrderedSame);
    }];
    return command;
}

+ (NSArray<BrowserCommand *> *)allCommands {
    static NSArray<BrowserCommand *> *commands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *readerNoun = @"(reader|lesemodus|lese modus|leseansicht|lese ansicht|reader modus|reader ansicht|reader mode|reader view|reading mode)";
        NSString *article = @"(den |die |das |the |)";
        NSString *adNoun = @"(werbeblocker|werbe blocker|adblocker|ad blocker|adblock|werbefilter)";
        NSString *adPlace = @"( hier| für diese seite| auf dieser seite| für die seite| for this site| on this site| here|)";
        NSArray<BrowserCommand *> *list = @[
            [self commandWithName:@"reader" title:@"Reader" symbol:@"doc.plaintext" argument:BrowserCommandArgumentToggle video:NO
                         patterns:@{
                @"": @[readerNoun, [readerNoun stringByAppendingString:@" umschalten"], @"(toggle|switch) (the |)(reader|reader mode|reader view)"],
                @"on": @[[readerNoun stringByAppendingString:@" (an|ein|einschalten|anschalten|starten|öffnen|aktivieren|zeigen|on|start)"],
                         [NSString stringWithFormat:@"(starte|start|öffne|open|zeige|zeig|show|aktiviere|schalte|mach) %@%@( ein| an|)", article, readerNoun],
                         [NSString stringWithFormat:@"(turn on|switch on|enable) %@%@", article, readerNoun],
                         @"(in den|zum|zur) (reader|lesemodus|leseansicht)"],
                @"off": @[[readerNoun stringByAppendingString:@" (aus|ausschalten|abschalten|beenden|schließen|verlassen|deaktivieren|off|close|exit)"],
                          [NSString stringWithFormat:@"(beende|schließe|schließ|verlasse|close|exit|quit|deaktiviere) %@%@", article, readerNoun],
                          [NSString stringWithFormat:@"(schalte|mach) %@%@ aus", article, readerNoun],
                          [NSString stringWithFormat:@"(turn off|switch off|disable) %@%@", article, readerNoun],
                          @"(originalseite|original seite|zurück zur originalseite|original page)"],
            } prefixes:@[]],
            [self commandWithName:@"address" title:@"Adresse" symbol:@"mic.fill" argument:BrowserCommandArgumentText video:NO
                         patterns:@{@"": @[@"(adresse|adressleiste|adresszeile|adresse eingeben|address|address bar|suche|suchen|search)",
                                           @"(öffne|zeige|zeig) (die |)(adresse|adressleiste|favoriten)",
                                           @"(favoriten|favoriten anzeigen|show favorites|open address bar)"]}
                         prefixes:@[]],
            [self commandWithName:@"search" title:@"Suche" symbol:@"magnifyingglass" argument:BrowserCommandArgumentText video:NO
                         patterns:@{}
                         prefixes:@[@"suche nach", @"such nach", @"suchen nach", @"suche", @"such", @"google nach", @"google", @"googel", @"search for"]],
            [self commandWithName:@"open" title:@"Öffnen" symbol:@"globe" argument:BrowserCommandArgumentText video:NO
                         patterns:@{}
                         prefixes:@[@"öffne die seite", @"öffne seite", @"öffne", @"öffnen", @"oeffne", @"gehe zu", @"geh zu", @"gehe auf", @"geh auf",
                                    @"navigiere zu", @"open", @"go to", @"navigate to"]],
            [self commandWithName:@"back" title:@"Zurück" symbol:@"chevron.left" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(zurück|geh zurück|gehe zurück|zurückgehen|eine seite zurück|seite zurück|vorige seite|vorherige seite|letzte seite|back|go back|previous page)"]}
                         prefixes:@[]],
            [self commandWithName:@"forward" title:@"Vor" symbol:@"chevron.right" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(vor|vorwärts|weiter|geh vor|gehe vor|geh vorwärts|gehe vorwärts|geh weiter|eine seite vor|seite vor|nächste seite|forward|go forward|next page)"]}
                         prefixes:@[]],
            [self commandWithName:@"reload" title:@"Neu laden" symbol:@"arrow.clockwise" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(neu laden|seite neu laden|neuladen|aktualisieren|seite aktualisieren|lade neu|lade die seite neu|reload|refresh|reload page|refresh page)"]}
                         prefixes:@[]],
            [self commandWithName:@"home" title:@"Startseite" symbol:@"house" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(startseite|zur startseite|startseite öffnen|home|go home|home page|homepage)",
                                           @"(öffne|geh zur|gehe zur|zeige) (die |)startseite"]}
                         prefixes:@[]],
            [self commandWithName:@"newtab" title:@"Neuer Tab" symbol:@"plus.square.on.square" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(neuer|neuen|neues) tab( öffnen|)", @"(öffne|mach) (einen |ein |)(neuen|neues) tab( auf|)",
                                           @"tab öffnen", @"(new tab|open new tab|open a new tab)"]}
                         prefixes:@[]],
            [self commandWithName:@"closetab" title:@"Tab schließen" symbol:@"xmark.square" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(tab|diesen tab|den tab|aktuellen tab) (schließen|zumachen|zu)", @"(schließe|schließ) (den |diesen |)tab",
                                           @"(close tab|close this tab|close the tab)"]}
                         prefixes:@[]],
            [self commandWithName:@"tabs" title:@"Tab-Übersicht" symbol:@"square.on.square" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(tabs|tab übersicht|tabübersicht|alle tabs|offene tabs|tabs anzeigen|tab overview|show tabs|all tabs)",
                                           @"(zeige|zeig|öffne) (die |alle |)(tabs|tab übersicht|tabübersicht)"]}
                         prefixes:@[]],
            [self commandWithName:@"favorite" title:@"Favorit" symbol:@"star.fill" argument:BrowserCommandArgumentToggle video:NO
                         patterns:@{
                @"": @[@"(favorit|merken|seite merken|merke die seite|merk dir die seite|lesezeichen|favorite|favourite|bookmark)"],
                @"on": @[@"(als favorit|als favorit speichern|zu favoriten|zu den favoriten|favorit hinzufügen|favorit an)",
                         @"(zu favoriten|zu den favoriten) hinzufügen", @"lesezeichen (setzen|hinzufügen)", @"(add bookmark|add to favorites|bookmark this)"],
                @"off": @[@"(favorit|lesezeichen) (entfernen|aus|löschen)", @"aus (den |)favoriten (entfernen|löschen)",
                          @"(remove bookmark|remove favorite|remove from favorites)"],
            } prefixes:@[]],
            [self commandWithName:@"adblock-site" title:@"Werbeblocker hier" symbol:@"shield.lefthalf.filled" argument:BrowserCommandArgumentToggle video:NO
                         patterns:@{
                @"": @[[NSString stringWithFormat:@"%@%@ umschalten", adNoun, adPlace], @"(toggle ad blocker|toggle adblock)"],
                @"off": @[[NSString stringWithFormat:@"%@%@ (aus|ausschalten|abschalten|deaktivieren|pausieren|off)", adNoun, adPlace],
                          [NSString stringWithFormat:@"(schalte|mach) (den |)%@%@ aus", adNoun, adPlace],
                          [NSString stringWithFormat:@"(deaktiviere|pausiere) (den |)%@%@", adNoun, adPlace],
                          [NSString stringWithFormat:@"(disable|turn off) (the |)%@%@", adNoun, adPlace],
                          @"werbung (zulassen|erlauben)( hier|)", @"(allow ads|allow ads here)"],
                @"on": @[[NSString stringWithFormat:@"%@%@ (an|ein|einschalten|anschalten|aktivieren|on)", adNoun, adPlace],
                         [NSString stringWithFormat:@"(schalte|mach) (den |)%@%@ (an|ein)", adNoun, adPlace],
                         [NSString stringWithFormat:@"aktiviere (den |)%@%@", adNoun, adPlace],
                         [NSString stringWithFormat:@"(enable|turn on) (the |)%@%@", adNoun, adPlace],
                         @"werbung (blockieren|ausblenden)( hier|)", @"(block ads|block ads here)"],
            } prefixes:@[]],
            [self commandWithName:@"top" title:@"Nach oben" symbol:@"arrow.up.to.line" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(nach oben|ganz nach oben|nach ganz oben|ganz oben|zum anfang|zum seitenanfang|seitenanfang|an den anfang|top|to the top|scroll to top|go to top|back to top)"]}
                         prefixes:@[]],
            [self commandWithName:@"down" title:@"Seite runter" symbol:@"arrow.down" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(runter|nach unten|weiter runter|seite runter|runterscrollen|nach unten scrollen|scroll runter|scrollen|weiter scrollen|scroll down|down|page down)"]}
                         prefixes:@[]],
            [self commandWithName:@"up" title:@"Seite hoch" symbol:@"arrow.up" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(hoch|rauf|seite hoch|hochscrollen|nach oben scrollen|scroll hoch|scroll rauf|scroll up|up|page up)"]}
                         prefixes:@[]],
            [self commandWithName:@"menu" title:@"Menü" symbol:@"ellipsis.circle" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(menü|menu|einstellungen|optionen|mehr|settings|options|show menu|open menu|open settings)",
                                           @"(öffne|zeige|zeig) (das |die |)(menü|einstellungen|optionen)"]}
                         prefixes:@[]],
            [self commandWithName:@"help" title:@"Bedienung" symbol:@"questionmark.circle" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(hilfe|bedienung|anleitung|bedienungshilfe|hilfe anzeigen|sprachbefehle|befehle|was kann ich sagen|help|show help|what can i say|commands)",
                                           @"(öffne|zeige|zeig) (die |)(hilfe|bedienung|anleitung)"]}
                         prefixes:@[]],
            [self commandWithName:@"player" title:@"Im Player abspielen" symbol:@"play.rectangle" argument:BrowserCommandArgumentNone video:YES
                         patterns:@{@"": @[@"(im player abspielen|im player öffnen|im player|video im player|video im player abspielen|video im player öffnen|player|nativer player|video groß|video vollbild|play in player|open in player|video fullscreen)"]}
                         prefixes:@[]],
            [self commandWithName:@"playpause" title:@"Wiedergabe" symbol:@"playpause" argument:BrowserCommandArgumentToggle video:YES
                         patterns:@{
                @"": @[@"(wiedergabe|play pause)"],
                @"on": @[@"(play|abspielen|weiter abspielen|video abspielen|video starten|wiedergabe starten|fortsetzen|resume|play video)"],
                @"off": @[@"(pause|pausieren|anhalten|stopp|stop|video anhalten|video stoppen|video pausieren|pause video)"],
            } prefixes:@[]],
            [self commandWithName:@"seek" title:@"Spulen" symbol:@"gobackward" argument:BrowserCommandArgumentSeconds video:YES
                         patterns:@{
                @"10": @[@"(vorspulen|spul vor|spule vor|skip forward|fast forward)"],
                @"-10": @[@"(zurückspulen|spul zurück|spule zurück|skip back|rewind)"],
            } prefixes:@[]],
            // Intelligente Funktionen (BrowserIntelligence, PLAN.md Phase 6).
            [self commandWithName:@"summarize" title:@"Zusammenfassen" symbol:@"text.line.3.summary" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(fasse|fass) (die seite |diese seite |den artikel |den text |das |)zusammen",
                                           @"(seite|artikel|text|) zusammenfassen", @"zusammenfassung( zeigen| anzeigen|)",
                                           @"(worum geht es|worum gehts|was steht hier)",
                                           @"(summarize|summarise) (this page|the page|this article|the article|this|)",
                                           @"(summary|tldr|tl dr|give me a summary)"]}
                         prefixes:@[]],
            [self commandWithName:@"translate" title:@"Übersetzen" symbol:@"translate" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(übersetze|übersetz|übersetzen) (die seite |diese seite |die webseite |den artikel |das |)(ins deutsche|auf deutsch|)",
                                           @"(seite|webseite|artikel) übersetzen", @"(auf deutsch|ins deutsche) übersetzen", @"übersetzung",
                                           @"(translate|translate this page|translate the page|translate page|translate to german)"]}
                         prefixes:@[]],
            [self commandWithName:@"original" title:@"Übersetzung beenden" symbol:@"character.book.closed" argument:BrowserCommandArgumentNone video:NO
                         patterns:@{@"": @[@"(übersetzung beenden|übersetzung aus|übersetzung ausschalten|übersetzung stoppen|ohne übersetzung)",
                                           @"(original|original anzeigen|originalseite|zum original|zurück zum original|originalsprache)",
                                           @"(show original|stop translating|stop translation)"]}
                         prefixes:@[]],
            // „Frag die Seite“: Frage im Diktat, Antwort ist die passendste Stelle der Seite (hervorgehoben).
            // „frage“ und „ask“ nur mit Fragewort danach (BrowserCommandParser), sonst bleibt es eine Suche.
            [self commandWithName:@"ask" title:@"Frag die Seite" symbol:@"text.magnifyingglass" argument:BrowserCommandArgumentText video:NO
                         patterns:@{}
                         prefixes:@[@"frag die seite", @"frage die seite", @"frag", @"frage", @"ask the page", @"ask this page", @"ask"]],
        ];
#if DEBUG
        // Doppelte Phrasen wären mehrdeutig: im Debug-Build melden.
        NSMutableDictionary<NSString *, NSString *> *owner = [NSMutableDictionary dictionary];
        for (BrowserCommand *command in list) {
            for (NSString *phrase in command.phrases) {
                if (owner[phrase] != nil) {
                    NSLog(@"[Command] Phrase doppelt: \"%@\" (%@ und %@)", phrase, owner[phrase], command.name);
                }
                owner[phrase] = command.name;
            }
        }
#endif
        commands = list;
    });
    return commands;
}

+ (BrowserCommand *)commandNamed:(NSString *)name {
    for (BrowserCommand *command in [self allCommands]) {
        if ([command.name isEqualToString:name]) {
            return command;
        }
    }
    return nil;
}

+ (NSString *)nameForSource:(BrowserCommandSource)source {
    switch (source) {
        case BrowserCommandSourceDictation: return @"diktat";
        case BrowserCommandSourceSiri: return @"siri";
        case BrowserCommandSourceSelfTest: return @"selbsttest";
        case BrowserCommandSourceRemote: return @"remote";
    }
    return @"?";
}

@end
