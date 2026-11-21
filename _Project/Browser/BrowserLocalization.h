//
//  BrowserLocalization.h
//  Browser
//
//  Oberflächentexte übersetzen. Schlüssel ist der deutsche Text; fehlt eine Übersetzung, erscheint er unverändert.
//  Übersetzungen: en.lproj, es.lproj, fr.lproj (Localizable.strings). de.lproj bleibt leer und meldet nur die Sprache an.
//  Nicht für Logzeilen, Schlüssel in UserDefaults oder Texte, die als Kennung verglichen werden.
//

#import <Foundation/Foundation.h>

static inline NSString *BLS(NSString *german) {
    if (german.length == 0) {
        return german;
    }
    return [NSBundle.mainBundle localizedStringForKey:german value:german table:@"Localizable"];
}

/// Sprache der Oberfläche („de“, „en“, „es“, „fr“), wie tvOS sie für die App gewählt hat.
static inline NSString *BLSLanguage(void) {
    NSString *lang = NSBundle.mainBundle.preferredLocalizations.firstObject;
    return lang.length > 0 ? lang : @"de";
}
