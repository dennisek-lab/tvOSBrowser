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

/// Muster mehrerer Sprachen zusammenführen (Argument → Musterliste). Die erste Tabelle ist die deutsch-englische,
/// die weiteren hängen Spanisch und Französisch an; erkannt wird immer in allen Sprachen, unabhängig von der Oberfläche.
static NSDictionary<NSString *, NSArray<NSString *> *> *BrowserCommandPatterns(NSArray<NSDictionary<NSString *, NSArray<NSString *> *> *> *tables) {
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *merged = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, NSArray<NSString *> *> *table in tables) {
        [table enumerateKeysAndObjectsUsingBlock:^(NSString *arg, NSArray<NSString *> *list, __unused BOOL *stop) {
            merged[arg] = merged[arg] != nil ? [merged[arg] arrayByAddingObjectsFromArray:list] : list;
        }];
    }
    return merged;
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
        // Spanisch und Französisch: eigene Listen statt Alternativen in den deutschen Nomen (sonst Kreuzprodukte wie
        // „starte el modo lectura“). Normalisierte Form: klein, ohne Satzzeichen, Elision getrennt („l'onglet“ → „l onglet“).
        NSString *esReader = @"(modo lectura|modo de lectura|vista de lectura|modo lector|lector)";
        NSString *frReader = @"(mode lecture|mode de lecture|vue lecture|vue de lecture|mode lecteur)";
        NSString *esAd = @"(bloqueador de anuncios|bloqueador de publicidad|bloqueador|bloqueo de anuncios|adblock)";
        NSString *esAdPlace = @"( aquí| aqui| en esta página| en esta pagina| para esta página| para esta pagina| en este sitio| para este sitio|)";
        NSString *frAd = @"(bloqueur de pub|bloqueur de pubs|bloqueur de publicité|bloqueur de publicités|bloqueur|adblock)";
        NSString *frAdPlace = @"( ici| sur ce site| pour ce site| sur cette page| pour cette page|)";
        NSString *esPage = @"(la página|la pagina|esta página|esta pagina|el artículo|el articulo|el texto|esto)";
        NSString *frPage = @"(la page|cette page|l article|cet article|le texte|ça|ca)";
        NSArray<BrowserCommand *> *list = @[
            [self commandWithName:@"reader" title:@"Reader" symbol:@"doc.plaintext" argument:BrowserCommandArgumentToggle video:NO
                         patterns:BrowserCommandPatterns(@[@{
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
            }, @{
                @"": @[esReader, frReader],
                @"on": @[[NSString stringWithFormat:@"(activa|activar|abre|abrir|muestra|mostrar|inicia|iniciar|enciende|pon) (el |la |)%@", esReader],
                         [NSString stringWithFormat:@"(ir al|ve al|cambia al|pasar al) %@", esReader],
                         [NSString stringWithFormat:@"(active|activer|ouvre|ouvrir|affiche|afficher|lance|lancer|mets|mettre) (le |la |)%@", frReader],
                         [NSString stringWithFormat:@"(passe|passer|bascule|basculer) en %@", frReader]],
                @"off": @[[NSString stringWithFormat:@"(desactiva|desactivar|cierra|cerrar|quita|quitar|apaga|apagar) (el |la |)%@", esReader],
                          [NSString stringWithFormat:@"(sal|salir|salte) del %@", esReader],
                          [NSString stringWithFormat:@"(désactive|désactiver|ferme|fermer|quitte|quitter|enlève|enlever) (le |la |)%@", frReader],
                          [NSString stringWithFormat:@"(sors|sortir) du %@", frReader]],
            }]) prefixes:@[]],
            [self commandWithName:@"address" title:@"Adresse" symbol:@"mic.fill" argument:BrowserCommandArgumentText video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(adresse|adressleiste|adresszeile|adresse eingeben|address|address bar|suche|suchen|search)",
                                           @"(öffne|zeige|zeig) (die |)(adresse|adressleiste|favoriten)",
                                           @"(favoriten|favoriten anzeigen|show favorites|open address bar)"]}, @{@"": @[@"(barra de direcciones|dirección|direccion|buscar|busca|búsqueda|busqueda|favoritos|mostrar favoritos|ver favoritos)",
                                           @"(abre|muestra) (la |los |)(barra de direcciones|favoritos)",
                                           @"(barre d adresse|barre d adresses|rechercher|recherche|chercher|favoris|afficher les favoris|voir les favoris)",
                                           @"(ouvre|affiche) (la |les |)(barre d adresse|favoris)"]}])
                         prefixes:@[]],
            [self commandWithName:@"search" title:@"Suche" symbol:@"magnifyingglass" argument:BrowserCommandArgumentText video:NO
                         patterns:@{}
                         prefixes:@[@"suche nach", @"such nach", @"suchen nach", @"suche", @"such", @"google nach", @"google", @"googel", @"search for",
                                    @"busca en google", @"busca", @"buscar", @"búscame",
                                    @"cherche sur google", @"recherche sur google", @"cherche", @"chercher", @"recherche", @"rechercher"]],
            [self commandWithName:@"open" title:@"Öffnen" symbol:@"globe" argument:BrowserCommandArgumentText video:NO
                         patterns:@{}
                         prefixes:@[@"öffne die seite", @"öffne seite", @"öffne", @"öffnen", @"oeffne", @"gehe zu", @"geh zu", @"gehe auf", @"geh auf",
                                    @"navigiere zu", @"open", @"go to", @"navigate to",
                                    @"abre la página", @"abre la pagina", @"abre", @"abrir", @"ve a", @"ir a", @"navega a",
                                    @"ouvre la page", @"ouvre le site", @"ouvre", @"ouvrir", @"va sur", @"aller sur", @"va à", @"aller à", @"navigue vers"]],
            [self commandWithName:@"back" title:@"Zurück" symbol:@"chevron.left" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(zurück|geh zurück|gehe zurück|zurückgehen|eine seite zurück|seite zurück|vorige seite|vorherige seite|letzte seite|back|go back|previous page)"]}, @{@"": @[@"(atrás|atras|volver|vuelve|vuelve atrás|vuelve atras|ve atrás|ve atras|regresa|regresar|volver atrás|página anterior|pagina anterior)",
                                           @"(retour|retourne|revenir|reviens|retour arrière|page précédente|page precedente|précédent|precedent)"]}])
                         prefixes:@[]],
            [self commandWithName:@"forward" title:@"Vor" symbol:@"chevron.right" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(vor|vorwärts|weiter|geh vor|gehe vor|geh vorwärts|gehe vorwärts|geh weiter|eine seite vor|seite vor|nächste seite|forward|go forward|next page)"]}, @{@"": @[@"(adelante|ve adelante|ir adelante|avanzar|avanza|página siguiente|pagina siguiente|siguiente)",
                                           @"(suivant|page suivante|avancer|avance|en avant|va en avant)"]}])
                         prefixes:@[]],
            [self commandWithName:@"reload" title:@"Neu laden" symbol:@"arrow.clockwise" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(neu laden|seite neu laden|neuladen|aktualisieren|seite aktualisieren|lade neu|lade die seite neu|reload|refresh|reload page|refresh page)"]}, @{@"": @[@"(recargar|recarga|actualizar|actualiza) (la página|la pagina|esta página|esta pagina|)",
                                           @"(recharger|recharge|actualiser|actualise|rafraîchir|rafraichir|rafraîchis|rafraichis) (la page|cette page|)"]}])
                         prefixes:@[]],
            [self commandWithName:@"home" title:@"Startseite" symbol:@"house" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(startseite|zur startseite|startseite öffnen|home|go home|home page|homepage)",
                                           @"(öffne|geh zur|gehe zur|zeige) (die |)startseite"]}, @{@"": @[@"(inicio|página de inicio|pagina de inicio|ir al inicio|ve al inicio|ir a la página de inicio|abre la página de inicio)",
                                           @"(accueil|page d accueil|va à l accueil|retour à l accueil|ouvre la page d accueil)"]}])
                         prefixes:@[]],
            [self commandWithName:@"newtab" title:@"Neuer Tab" symbol:@"plus.square.on.square" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(neuer|neuen|neues) tab( öffnen|)", @"(öffne|mach) (einen |ein |)(neuen|neues) tab( auf|)",
                                           @"tab öffnen", @"(new tab|open new tab|open a new tab)"]}, @{@"": @[@"(nueva pestaña|pestaña nueva)", @"(abre|abrir) (una |)(nueva pestaña|pestaña nueva)",
                                           @"(nouvel onglet|nouveau onglet)", @"(ouvre|ouvrir) (un |)(nouvel onglet|onglet)"]}])
                         prefixes:@[]],
            [self commandWithName:@"closetab" title:@"Tab schließen" symbol:@"xmark.square" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(tab|diesen tab|den tab|aktuellen tab) (schließen|zumachen|zu)", @"(schließe|schließ) (den |diesen |)tab",
                                           @"(close tab|close this tab|close the tab)"]}, @{@"": @[@"(cierra|cerrar) (la |esta |)pestaña", @"(ferme|fermer) (l |cet |)onglet"]}])
                         prefixes:@[]],
            [self commandWithName:@"tabs" title:@"Tab-Übersicht" symbol:@"square.on.square" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(tabs|tab übersicht|tabübersicht|alle tabs|offene tabs|tabs anzeigen|tab overview|show tabs|all tabs)",
                                           @"(zeige|zeig|öffne) (die |alle |)(tabs|tab übersicht|tabübersicht)"]}, @{@"": @[@"(pestañas|todas las pestañas|pestañas abiertas|vista de pestañas)", @"(muestra|mostrar|ver|abre) (las |todas las |)pestañas",
                                           @"(onglets|tous les onglets|onglets ouverts|vue des onglets)", @"(affiche|afficher|montre|voir) (les |tous les |)onglets"]}])
                         prefixes:@[]],
            [self commandWithName:@"favorite" title:@"Favorit" symbol:@"star.fill" argument:BrowserCommandArgumentToggle video:NO
                         patterns:BrowserCommandPatterns(@[@{
                @"": @[@"(favorit|merken|seite merken|merke die seite|merk dir die seite|lesezeichen|favorite|favourite|bookmark)"],
                @"on": @[@"(als favorit|als favorit speichern|zu favoriten|zu den favoriten|favorit hinzufügen|favorit an)",
                         @"(zu favoriten|zu den favoriten) hinzufügen", @"lesezeichen (setzen|hinzufügen)", @"(add bookmark|add to favorites|bookmark this)"],
                @"off": @[@"(favorit|lesezeichen) (entfernen|aus|löschen)", @"aus (den |)favoriten (entfernen|löschen)",
                          @"(remove bookmark|remove favorite|remove from favorites)"],
            }, @{
                @"": @[@"(favorito|marcador|guardar página|guardar la página)", @"(favori|signet|marque page)"],
                @"on": @[@"(añadir|añade|agregar|agrega|guardar|guarda) (a |en |)(favoritos|marcadores)", @"(añadir|añade|agregar|agrega) (un |)marcador",
                         @"(ajouter|ajoute|mettre|mets) (aux |dans les |en |)(favoris|signets|favori)", @"(ajouter|ajoute) un signet"],
                @"off": @[@"(quitar|quita|eliminar|elimina|borrar|borra) de (favoritos|marcadores)", @"(quitar|quita|eliminar|elimina) (el |)marcador",
                          @"(retirer|retire|supprimer|supprime|enlever|enlève) (des favoris|des signets|le signet|le favori)"],
            }]) prefixes:@[]],
            [self commandWithName:@"adblock-site" title:@"Werbeblocker hier" symbol:@"shield.lefthalf.filled" argument:BrowserCommandArgumentToggle video:NO
                         patterns:BrowserCommandPatterns(@[@{
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
            }, @{
                @"off": @[[NSString stringWithFormat:@"(desactiva|desactivar|apaga|apagar|pausa|pausar) (el |)%@%@", esAd, esAdPlace],
                          @"(permitir|permite) (los |)anuncios( aquí| aqui|)",
                          [NSString stringWithFormat:@"(désactive|désactiver|coupe|couper) (le |)%@%@", frAd, frAdPlace],
                          @"(autoriser|autorise) (les |)(pubs|publicités|publicites)( ici|)"],
                @"on": @[[NSString stringWithFormat:@"(activa|activar|enciende|encender|reactiva|reactivar) (el |)%@%@", esAd, esAdPlace],
                         @"(bloquear|bloquea) (los |)anuncios( aquí| aqui|)",
                         [NSString stringWithFormat:@"(active|activer|réactive|réactiver) (le |)%@%@", frAd, frAdPlace],
                         @"(bloquer|bloque) (les |)(pubs|publicités|publicites)( ici|)"],
            }]) prefixes:@[]],
            [self commandWithName:@"top" title:@"Nach oben" symbol:@"arrow.up.to.line" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(nach oben|ganz nach oben|nach ganz oben|ganz oben|zum anfang|zum seitenanfang|seitenanfang|an den anfang|top|to the top|scroll to top|go to top|back to top)"]}, @{@"": @[@"(arriba del todo|al principio|al principio de la página|al inicio de la página|ir arriba del todo|subir del todo|sube del todo)",
                                           @"(tout en haut|en haut de la page|haut de la page|début de la page|au début|retour en haut|remonte tout en haut)"]}])
                         prefixes:@[]],
            [self commandWithName:@"down" title:@"Seite runter" symbol:@"arrow.down" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(runter|nach unten|weiter runter|seite runter|runterscrollen|nach unten scrollen|scroll runter|scrollen|weiter scrollen|scroll down|down|page down)"]}, @{@"": @[@"(abajo|baja|bajar|hacia abajo|más abajo|desplaza hacia abajo|desplázate hacia abajo|página abajo|pagina abajo)",
                                           @"(en bas|vers le bas|descends|descendre|plus bas|défile vers le bas|fais défiler vers le bas)"]}])
                         prefixes:@[]],
            [self commandWithName:@"up" title:@"Seite hoch" symbol:@"arrow.up" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(hoch|rauf|seite hoch|hochscrollen|nach oben scrollen|scroll hoch|scroll rauf|scroll up|up|page up)"]}, @{@"": @[@"(arriba|sube|subir|hacia arriba|más arriba|desplaza hacia arriba|desplázate hacia arriba|página arriba|pagina arriba)",
                                           @"(en haut|vers le haut|monte|monter|remonte|remonter|plus haut|défile vers le haut|fais défiler vers le haut)"]}])
                         prefixes:@[]],
            [self commandWithName:@"menu" title:@"Menü" symbol:@"ellipsis.circle" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(menü|menu|einstellungen|optionen|mehr|settings|options|show menu|open menu|open settings)",
                                           @"(öffne|zeige|zeig) (das |die |)(menü|einstellungen|optionen)"]}, @{@"": @[@"(menú|ajustes|configuración|configuracion|opciones|más opciones)", @"(abre|muestra) (el |los |las |)(menú|menu|ajustes|opciones)",
                                           @"(réglages|reglages|paramètres|parametres|plus d options)", @"(ouvre|affiche) (le |les |)(menu|réglages|paramètres|options)"]}])
                         prefixes:@[]],
            [self commandWithName:@"help" title:@"Bedienung" symbol:@"questionmark.circle" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(hilfe|bedienung|anleitung|bedienungshilfe|hilfe anzeigen|sprachbefehle|befehle|was kann ich sagen|help|show help|what can i say|commands)",
                                           @"(öffne|zeige|zeig) (die |)(hilfe|bedienung|anleitung)"]}, @{@"": @[@"(ayuda|comandos|comandos de voz|qué puedo decir|que puedo decir)", @"(muestra|mostrar|abre) (la |)ayuda",
                                           @"(aide|commandes|commandes vocales|que puis je dire|qu est ce que je peux dire)", @"(affiche|afficher|ouvre) (l |)aide"]}])
                         prefixes:@[]],
            [self commandWithName:@"player" title:@"Im Player abspielen" symbol:@"play.rectangle" argument:BrowserCommandArgumentNone video:YES
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(im player abspielen|im player öffnen|im player|video im player|video im player abspielen|video im player öffnen|player|nativer player|video groß|video vollbild|play in player|open in player|video fullscreen)"]}, @{@"": @[@"(reproducir en el reproductor|abrir en el reproductor|en el reproductor|reproductor|pantalla completa|vídeo en pantalla completa|video en pantalla completa)",
                                           @"(lire dans le lecteur|ouvrir dans le lecteur|dans le lecteur|lecteur vidéo|plein écran|vidéo en plein écran|mettre en plein écran|mets en plein écran)"]}])
                         prefixes:@[]],
            [self commandWithName:@"playpause" title:@"Wiedergabe" symbol:@"playpause" argument:BrowserCommandArgumentToggle video:YES
                         patterns:BrowserCommandPatterns(@[@{
                @"": @[@"(wiedergabe|play pause)"],
                @"on": @[@"(play|abspielen|weiter abspielen|video abspielen|video starten|wiedergabe starten|fortsetzen|resume|play video)"],
                @"off": @[@"(pause|pausieren|anhalten|stopp|stop|video anhalten|video stoppen|video pausieren|pause video)"],
            }, @{
                @"": @[@"(reproducción|reproduccion)"],
                @"on": @[@"(reproducir|reproduce|reanudar|reanuda|continuar|continúa|continua|dale al play)", @"(reproducir|reproduce) el (vídeo|video)",
                         @"(lecture|lire|reprendre|reprends|joue|jouer)", @"(lire|lance|relance|reprends) la vidéo"],
                @"off": @[@"(pausa|pausar|detener|detén|para|parar)", @"(pausa|pausar|detén|para) el (vídeo|video)",
                          @"(mets en pause|mettre en pause|arrête|arrêter|stoppe)", @"(mets en pause|arrête) la vidéo"],
            }]) prefixes:@[]],
            [self commandWithName:@"seek" title:@"Spulen" symbol:@"gobackward" argument:BrowserCommandArgumentSeconds video:YES
                         patterns:BrowserCommandPatterns(@[@{
                @"10": @[@"(vorspulen|spul vor|spule vor|skip forward|fast forward)"],
                @"-10": @[@"(zurückspulen|spul zurück|spule zurück|skip back|rewind)"],
            }, @{
                @"10": @[@"(adelanta|adelantar|avance rápido|avance rapido)", @"(avance rapide|avance un peu|avancer un peu)"],
                @"-10": @[@"(retrocede|retroceder|rebobina|rebobinar)", @"(recule|reculer|rembobine|rembobiner|retour rapide)"],
            }]) prefixes:@[]],
            // Intelligente Funktionen (BrowserIntelligence).
            [self commandWithName:@"summarize" title:@"Zusammenfassen" symbol:@"text.line.3.summary" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(fasse|fass) (die seite |diese seite |den artikel |den text |das |)zusammen",
                                           @"(seite|artikel|text|) zusammenfassen", @"zusammenfassung( zeigen| anzeigen|)",
                                           @"(worum geht es|worum gehts|was steht hier)",
                                           @"(summarize|summarise) (this page|the page|this article|the article|this|)",
                                           @"(summary|tldr|tl dr|give me a summary)"]}, @{@"": @[[NSString stringWithFormat:@"(resume|resumir|resúmeme) %@", esPage], @"(resumir|resúmeme|resúmelo|resúmela|haz un resumen)",
                                           @"(resumen|un resumen|dame un resumen|muestra un resumen|de qué trata|de que trata|de qué va|de que va)",
                                           [NSString stringWithFormat:@"(résume|résumer|resume moi|résume moi|fais un résumé de) %@", frPage],
                                           @"(résumé|un résumé|fais un résumé|fais moi un résumé|donne moi un résumé|de quoi ça parle|de quoi ca parle|de quoi parle cette page)"]}])
                         prefixes:@[]],
            [self commandWithName:@"translate" title:@"Übersetzen" symbol:@"translate" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(übersetze|übersetz|übersetzen) (die seite |diese seite |die webseite |den artikel |das |)(ins deutsche|auf deutsch|)",
                                           @"(seite|webseite|artikel) übersetzen", @"(auf deutsch|ins deutsche) übersetzen", @"übersetzung",
                                           @"(translate|translate this page|translate the page|translate page|translate to german)"]}, @{@"": @[@"(traduce|traducir|tradúcela|tradúcelo) (la página |la pagina |esta página |esta pagina |el artículo |el articulo |esto |)(al español|al castellano|)",
                                           @"(traducción|traduccion)",
                                           @"(traduis|traduire|traduit) (la page |cette page |ça |)(en français|)", @"traduction"]}])
                         prefixes:@[]],
            [self commandWithName:@"original" title:@"Übersetzung beenden" symbol:@"character.book.closed" argument:BrowserCommandArgumentNone video:NO
                         patterns:BrowserCommandPatterns(@[@{@"": @[@"(übersetzung beenden|übersetzung aus|übersetzung ausschalten|übersetzung stoppen|ohne übersetzung)",
                                           @"(original|original anzeigen|originalseite|zum original|zurück zum original|originalsprache)",
                                           @"(show original|stop translating|stop translation)"]}, @{@"": @[@"(ver original|ver el original|mostrar original|mostrar el original|muestra el original|página original|pagina original|versión original)",
                                           @"(quitar|quita|desactivar|desactiva|detener|detén) (la |)traducción", @"sin traducción",
                                           @"(voir l original|afficher l original|affiche l original|page originale|version originale|sans traduction)",
                                           @"(arrêter|arrête|désactiver|désactive|enlever|enlève) la traduction"]}])
                         prefixes:@[]],
            // „Frag die Seite“: Frage im Diktat, Antwort ist die passendste Stelle der Seite (hervorgehoben).
            // „frage“, „ask“, „pregunta“ und „demande“ nur mit Fragewort danach (BrowserCommandParser), sonst bleibt es eine Suche.
            [self commandWithName:@"ask" title:@"Frag die Seite" symbol:@"text.magnifyingglass" argument:BrowserCommandArgumentText video:NO
                         patterns:@{}
                         prefixes:@[@"frag die seite", @"frage die seite", @"frag", @"frage", @"ask the page", @"ask this page", @"ask",
                                    @"pregúntale a la página", @"pregunta a la página", @"pregunta a la pagina", @"pregunta",
                                    @"demande à la page", @"demande a la page", @"demande"]],
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
