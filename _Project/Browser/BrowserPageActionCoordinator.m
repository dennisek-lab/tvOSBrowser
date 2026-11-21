#import "BrowserPageActionCoordinator.h"

#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserWebView.h"
#import "BrowserLocalization.h"

@interface BrowserPageActionCoordinator ()

@property (nonatomic, weak) id<BrowserPageActionCoordinatorHost> host;
@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;

@end

@implementation BrowserPageActionCoordinator

- (instancetype)initWithHost:(id<BrowserPageActionCoordinatorHost>)host
       domInteractionService:(BrowserDOMInteractionService *)domInteractionService
           navigationService:(BrowserNavigationService *)navigationService
    videoPlaybackCoordinator:(BrowserVideoPlaybackCoordinator *)videoPlaybackCoordinator {
    self = [super init];
    if (self) {
        _host = host;
        _domInteractionService = domInteractionService;
        _navigationService = navigationService;
        _videoPlaybackCoordinator = videoPlaybackCoordinator;
    }
    return self;
}

- (NSString *)hoverStateAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    return [self.domInteractionService evaluateHoverStateJavaScriptAtPoint:point webView:webView];
}

- (BOOL)handleTargetBlankLinkAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    NSDictionary *linkInfo = [self.domInteractionService linkInfoAtDOMPoint:point webView:webView];
    NSString *href = [linkInfo[@"href"] isKindOfClass:[NSString class]] ? linkInfo[@"href"] : @"";
    NSString *target = [linkInfo[@"target"] isKindOfClass:[NSString class]] ? linkInfo[@"target"] : @"";

    if (href.length == 0 || ![target isEqualToString:@"_blank"]) {
        return NO;
    }

    NSURLRequest *request = [self.navigationService requestForURLString:href];
    if (request == nil) {
        return NO;
    }

    return [self.host browserPageActionCoordinatorCreateNewTabWithRequest:request];
}

#pragma mark - Eingabedialog für Webformulare

/// JavaScript-Hilfen, die vor jedem Aufruf stehen: Wert über den nativen Setter schreiben (sonst übernehmen
/// React und Co. die Eingabe nicht), Formular regulär abschicken, Login-Felder eines Formulars finden.
static NSString *BrowserFormHelpersScript(void) {
    return @"function __bSet(el, v) {"
               "if (!el) { return; }"
               "if (el.isContentEditable && typeof el.value === 'undefined') { el.textContent = v; }"
               "else {"
                   "var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : (el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype);"
                   "var d = Object.getOwnPropertyDescriptor(proto, 'value');"
                   "if (d && d.set) { d.set.call(el, v); } else { el.value = v; }"
               "}"
               "try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: v })); } catch (e) { el.dispatchEvent(new Event('input', { bubbles: true })); }"
               "el.dispatchEvent(new Event('change', { bubbles: true }));"
           "}"
           "function __bSubmit(el) {"
               "var f = el && el.form;"
               "if (f) {"
                   "var b = f.querySelector('button[type=submit],input[type=submit],button:not([type])');"
                   "if (f.requestSubmit) { try { f.requestSubmit(b || undefined); return 'requestSubmit'; } catch (e) {} }"
                   "if (b) { b.click(); return 'click'; }"
                   "f.submit(); return 'submit';"
               "}"
               "var opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };"
               "el.dispatchEvent(new KeyboardEvent('keydown', opts));"
               "el.dispatchEvent(new KeyboardEvent('keypress', opts));"
               "el.dispatchEvent(new KeyboardEvent('keyup', opts));"
               "return 'enter';"
           "}"
           "function __bVisible(el) { var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'; }"
           "function __bLoginFields(target) {"
               "var scope = target.form || document;"
               "var inputs = Array.prototype.filter.call(scope.querySelectorAll('input'), __bVisible);"
               "var pw = inputs.filter(function (i) { return (i.type || '').toLowerCase() === 'password'; });"
               "if (pw.length !== 1) { return null; }"
               "var pass = pw[0], user = null;"
               "for (var i = inputs.indexOf(pass) - 1; i >= 0; i--) {"
                   "var t = (inputs[i].type || 'text').toLowerCase();"
                   "if (t === 'text' || t === 'email' || t === 'tel') { user = inputs[i]; break; }"
               "}"
               "if (target !== pass && target !== user) { return null; }"
               "return { user: user, pass: pass };"
           "}";
}

/// Passender `textContentType` für das iPhone (Passwörter-App, Einmalcodes, Adressen).
static UITextContentType BrowserTextContentType(NSString *autocomplete, NSString *fieldType, BOOL loginUsername) {
    NSString *token = [[autocomplete.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lastObject] ?: @"";
    NSDictionary<NSString *, UITextContentType> *map = @{
        @"username": UITextContentTypeUsername,
        @"current-password": UITextContentTypePassword,
        @"new-password": UITextContentTypeNewPassword,
        @"one-time-code": UITextContentTypeOneTimeCode,
        @"email": UITextContentTypeEmailAddress,
        @"tel": UITextContentTypeTelephoneNumber,
        @"name": UITextContentTypeName,
        @"given-name": UITextContentTypeGivenName,
        @"family-name": UITextContentTypeFamilyName,
        @"street-address": UITextContentTypeFullStreetAddress,
        @"address-line1": UITextContentTypeStreetAddressLine1,
        @"address-line2": UITextContentTypeStreetAddressLine2,
        @"postal-code": UITextContentTypePostalCode,
        @"address-level2": UITextContentTypeAddressCity,
        @"country-name": UITextContentTypeCountryName,
        @"organization": UITextContentTypeOrganizationName,
        @"url": UITextContentTypeURL,
    };
    if (loginUsername) {
        return UITextContentTypeUsername;
    }
    if (map[token] != nil) {
        return map[token];
    }
    if ([fieldType isEqualToString:@"password"]) {
        return UITextContentTypePassword;
    }
    if ([fieldType isEqualToString:@"email"]) {
        return UITextContentTypeEmailAddress;
    }
    if ([fieldType isEqualToString:@"tel"]) {
        return UITextContentTypeTelephoneNumber;
    }
    if ([fieldType isEqualToString:@"url"]) {
        return UITextContentTypeURL;
    }
    return nil;
}

static void BrowserConfigureKeyboard(UITextField *textField, NSString *fieldType) {
    if ([fieldType isEqualToString:@"url"]) {
        textField.keyboardType = UIKeyboardTypeURL;
    } else if ([fieldType isEqualToString:@"email"]) {
        textField.keyboardType = UIKeyboardTypeEmailAddress;
    } else if ([fieldType isEqualToString:@"tel"] ||
               [fieldType isEqualToString:@"number"] ||
               [fieldType isEqualToString:@"date"] ||
               [fieldType isEqualToString:@"datetime"] ||
               [fieldType isEqualToString:@"datetime-local"]) {
        textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    } else {
        textField.keyboardType = UIKeyboardTypeDefault;
    }
    if (![fieldType isEqualToString:@"text"] && ![fieldType isEqualToString:@"search"] && ![fieldType isEqualToString:@""]) {
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }
    textField.secureTextEntry = [fieldType isEqualToString:@"password"];
}

- (NSDictionary *)editableFieldInfoAtPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    NSString *body = [BrowserFormHelpersScript() stringByAppendingString:
        @"var target = browserEditableTarget();"
         "if (!target) { return '{}'; }"
         "var type = ((target.type || '') + '').toLowerCase();"
         "if (target.tagName === 'TEXTAREA' || target.isContentEditable || (target.tagName === 'INPUT' && !type)) { type = 'text'; }"
         "var login = __bLoginFields(target);"
         "window.__browserLoginFields = login;"
         "var label = '';"
         "try { if (target.labels && target.labels.length) { label = target.labels[0].innerText.trim(); } } catch (e) {}"
         "return JSON.stringify({"
             "type: type,"
             "title: label || target.getAttribute('aria-label') || target.title || target.placeholder || (type === 'search' ? 'Suche' : '') || target.name || '',"
             "placeholder: target.placeholder || target.getAttribute('aria-label') || '',"
             "value: (typeof target.value !== 'undefined') ? target.value : (target.textContent || ''),"
             "autocomplete: target.getAttribute('autocomplete') || '',"
             "hasForm: !!target.form,"
             "login: !!(login && login.user),"
             "userValue: (login && login.user) ? login.user.value : '',"
             "userAutocomplete: (login && login.user) ? (login.user.getAttribute('autocomplete') || '') : '',"
             "userType: (login && login.user) ? (login.user.type || 'text').toLowerCase() : '',"
             "host: location.hostname"
         "});"];
    NSString *json = [self.domInteractionService evaluateEditableElementJavaScriptAtPoint:point webView:webView body:body];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id object = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

- (void)presentEditableFieldPromptForFieldType:(NSString *)fieldType
                                         point:(CGPoint)point
                                       webView:(BrowserWebView *)webView {
    NSDictionary *info = [self editableFieldInfoAtPoint:point webView:webView];
    NSString *type = [info[@"type"] isKindOfClass:NSString.class] && [info[@"type"] length] > 0 ? info[@"type"] : fieldType;
    if ([info[@"login"] boolValue]) {
        [self presentLoginPromptWithInfo:info point:point webView:webView];
        return;
    }

    NSString *title = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : @"";
    NSString *placeholder = [info[@"placeholder"] isKindOfClass:NSString.class] ? info[@"placeholder"] : @"";
    NSString *value = [info[@"value"] isKindOfClass:NSString.class] ? info[@"value"] : @"";
    NSString *autocomplete = [info[@"autocomplete"] isKindOfClass:NSString.class] ? info[@"autocomplete"] : @"";
    NSString *host = [info[@"host"] isKindOfClass:NSString.class] ? info[@"host"] : @"";

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title.length > 0 ? title : BLS(@"Eingabe")
                                                                             message:host
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        BrowserConfigureKeyboard(textField, type);
        textField.textContentType = BrowserTextContentType(autocomplete, type, NO);
        textField.placeholder = placeholder.length > 0 ? placeholder : title;
        textField.text = value;
        textField.returnKeyType = UIReturnKeyDone;
    }];

    __weak typeof(self) weakSelf = self;
    // Schwach: der Dialog hält seine Aktionen, die Aktionen halten diesen Block (sonst Zyklus, Dialog und WebView bleiben im Speicher).
    __weak UIAlertController *weakAlert = alertController;
    void (^apply)(BOOL submit) = ^(BOOL submit) {
        NSString *escaped = [weakSelf.domInteractionService javaScriptEscapedString:weakAlert.textFields.firstObject.text ?: @""];
        NSString *script = [BrowserFormHelpersScript() stringByAppendingFormat:
            @"var target = browserEditableTarget();"
             "if (!target) { return 'false'; }"
             "__bSet(target, '%@');"
             "%@"
             "return 'true';", escaped, submit ? @"__bSubmit(target);" : @""];
        [weakSelf.domInteractionService evaluateEditableElementJavaScriptAtPoint:point webView:webView body:script];
    };
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"Übernehmen") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        apply(NO);
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"Übernehmen und absenden") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        apply(YES);
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"Abbrechen") style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPageActionCoordinatorPresentViewController:alertController];

    UITextField *inputTextField = alertController.textFields.firstObject;
    if ([[inputTextField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] length] == 0) {
        [inputTextField becomeFirstResponder];
    }
}

/// Benutzername und Passwort in einem Dialog. Mit den passenden textContentTypes bietet die
/// iPhone-Tastatur (Tastatur-Mitteilung) Einträge aus der Passwörter-App an.
- (void)presentLoginPromptWithInfo:(NSDictionary *)info point:(CGPoint)point webView:(BrowserWebView *)webView {
    NSString *host = [info[@"host"] isKindOfClass:NSString.class] ? info[@"host"] : @"";
    NSString *userValue = [info[@"userValue"] isKindOfClass:NSString.class] ? info[@"userValue"] : @"";
    NSString *userType = [info[@"userType"] isKindOfClass:NSString.class] ? info[@"userType"] : @"text";
    NSString *userAutocomplete = [info[@"userAutocomplete"] isKindOfClass:NSString.class] ? info[@"userAutocomplete"] : @"";
    NSString *autocomplete = [info[@"autocomplete"] isKindOfClass:NSString.class] ? info[@"autocomplete"] : @"";
    BOOL newPassword = [autocomplete.lowercaseString containsString:@"new-password"];

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:BLS(@"Anmelden")
                                                                             message:host
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        BrowserConfigureKeyboard(textField, [userType isEqualToString:@"text"] ? @"email" : userType);
        textField.keyboardType = [userType isEqualToString:@"tel"] ? UIKeyboardTypePhonePad : UIKeyboardTypeEmailAddress;
        textField.textContentType = BrowserTextContentType(userAutocomplete, userType, YES);
        textField.placeholder = BLS(@"Benutzername oder E-Mail");
        textField.text = userValue;
        textField.returnKeyType = UIReturnKeyNext;
    }];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        BrowserConfigureKeyboard(textField, @"password");
        textField.textContentType = newPassword ? UITextContentTypeNewPassword : UITextContentTypePassword;
        textField.placeholder = BLS(@"Passwort");
        textField.returnKeyType = UIReturnKeyDone;
    }];

    __weak typeof(self) weakSelf = self;
    // Schwach wie oben: sonst bleiben Dialog (mit Passwort im Textfeld) und WebView im Speicher.
    __weak UIAlertController *weakAlert = alertController;
    void (^apply)(BOOL submit) = ^(BOOL submit) {
        UIAlertController *alert = weakAlert;
        if (alert.textFields.count < 2) {
            return;
        }
        NSString *user = [weakSelf.domInteractionService javaScriptEscapedString:alert.textFields[0].text ?: @""];
        NSString *pass = [weakSelf.domInteractionService javaScriptEscapedString:alert.textFields[1].text ?: @""];
        NSString *script = [BrowserFormHelpersScript() stringByAppendingFormat:
            @"var login = window.__browserLoginFields;"
             "if (!login || !login.pass || !login.pass.isConnected) { return 'false'; }"
             "if (login.user) { __bSet(login.user, '%@'); }"
             "__bSet(login.pass, '%@');"
             "%@"
             "return 'true';", user, pass, submit ? @"__bSubmit(login.pass);" : @""];
        [weakSelf.domInteractionService evaluateEditableElementJavaScriptAtPoint:point webView:webView body:script];
    };
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"Anmelden") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        apply(YES);
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"Nur eintragen") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        apply(NO);
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:BLS(@"Abbrechen") style:UIAlertActionStyleCancel handler:nil]];
    [self.host browserPageActionCoordinatorPresentViewController:alertController];

    UITextField *first = alertController.textFields[userValue.length > 0 ? 1 : 0];
    [first becomeFirstResponder];
}

- (BOOL)handlePageSelectionAtDOMPoint:(CGPoint)point webView:(BrowserWebView *)webView {
    if ([self.videoPlaybackCoordinator handleSelectPressForVideoAtCursor]) {
        return YES;
    }
    if ([self handleTargetBlankLinkAtDOMPoint:point webView:webView]) {
        return YES;
    }
    // Ziel in einem fremden iframe (eingebettete Player wie Vimeo, Dailymotion, YouTube) oder im Shadow DOM:
    // Der Klick unten erreicht es nicht (er träfe nur das iframe-Element), die Player-Brücke reicht ihn hinein.
    NSString *bridged = [webView playerBridgeClickAtCSSPoint:point];
    if ([bridged isEqualToString:@"frame"] || [bridged isEqualToString:@"shadow"] || [bridged isEqualToString:@"click"]) {
        return YES;
    }

    NSString *fieldType = [self.domInteractionService evaluateResolvedElementJavaScriptAtPoint:point
                                                                                        webView:webView
                                                                                           body:@"function browserEditableTargetAtPoint() {"
                                                                                                "var candidate = editableElement;"
                                                                                                "if (!candidate && resolvedElement && resolvedElement.matches) {"
                                                                                                    "if (resolvedElement.matches(editableSelector) || resolvedElement.matches('textarea, select')) {"
                                                                                                        "candidate = resolvedElement;"
                                                                                                    "}"
                                                                                                "}"
                                                                                                "if (!candidate) { return null; }"
                                                                                                "window.__browserLastEditableElement = candidate;"
                                                                                                "return candidate;"
                                                                                                "}"
                                                                                                "var target = browserEditableTargetAtPoint();"
                                                                                                "if (!target) { return ''; }"
                                                                                                "var tagName = target.tagName ? target.tagName.toLowerCase() : '';"
                                                                                                "var type = (target.type || '').toLowerCase();"
                                                                                                "if (tagName === 'textarea' || target.isContentEditable) { return 'text'; }"
                                                                                                "if (tagName === 'input' && !type) { return 'text'; }"
                                                                                                "return type;"];
    [self.domInteractionService evaluateResolvedElementJavaScriptAtPoint:point
                                                                 webView:webView
                                                                    body:@"var target = editableElement || interactiveElement || resolvedElement;"
                                                                         "if (!target) { return 'false'; }"
                                                                         "try { if (target.focus) { target.focus(); } } catch (error) {}"
                                                                         "function dispatchPointerLikeEvent(type, constructorName) {"
                                                                             "try {"
                                                                                 "var Constructor = window[constructorName];"
                                                                                 "if (Constructor) {"
                                                                                     "var event = new Constructor(type, { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: 1, pointerType: 'mouse' });"
                                                                                     "return target.dispatchEvent(event);"
                                                                                 "}"
                                                                             "} catch (error) {}"
                                                                             "var mouseEvent = document.createEvent('MouseEvents');"
                                                                             "mouseEvent.initMouseEvent(type, true, true, window, 1, x, y, x, y, false, false, false, false, 0, null);"
                                                                             "return target.dispatchEvent(mouseEvent);"
                                                                         "}"
                                                                         "dispatchPointerLikeEvent('pointerdown', 'PointerEvent');"
                                                                         "dispatchPointerLikeEvent('mousedown', 'MouseEvent');"
                                                                         "dispatchPointerLikeEvent('pointerup', 'PointerEvent');"
                                                                         "dispatchPointerLikeEvent('mouseup', 'MouseEvent');"
                                                                         "if (typeof target.click === 'function') { target.click(); }"
                                                                         "else { dispatchPointerLikeEvent('click', 'MouseEvent'); }"
                                                                         "return 'true';"];
    fieldType = fieldType.lowercaseString;
    if ([fieldType isEqualToString:@"date"] ||
        [fieldType isEqualToString:@"datetime"] ||
        [fieldType isEqualToString:@"datetime-local"] ||
        [fieldType isEqualToString:@"email"] ||
        [fieldType isEqualToString:@"month"] ||
        [fieldType isEqualToString:@"number"] ||
        [fieldType isEqualToString:@"password"] ||
        [fieldType isEqualToString:@"search"] ||
        [fieldType isEqualToString:@"tel"] ||
        [fieldType isEqualToString:@"text"] ||
        [fieldType isEqualToString:@"time"] ||
        [fieldType isEqualToString:@"url"] ||
        [fieldType isEqualToString:@"week"]) {
        [self presentEditableFieldPromptForFieldType:fieldType point:point webView:webView];
    }
    return YES;
}

@end
