//
//  BrowserCommandRouter.m
//  Browser
//

#import "BrowserCommandRouter.h"
#import "BrowserMotion.h"
#import "BrowserCommandParser.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

/// Glas-Kapsel unten mittig mit Symbol und kurzem Text; blendet nach 1,8 s aus.
@interface BrowserCommandToastView : UIVisualEffectView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *label;
@end

@implementation BrowserCommandToastView

- (instancetype)initWithText:(NSString *)text symbolName:(NSString *)symbolName success:(BOOL)success {
    UIVisualEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        if (BrowserMotion.glassMaterialAvailable) { // im alten Design bleibt es beim dunklen Blur
            UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
            // Leicht dunkel getönt, damit die weiße Schrift auch über hellen Seiten lesbar bleibt.
            glass.tintColor = [UIColor colorWithWhite:0.0 alpha:0.35];
            effect = glass;
        }
    }
#endif
    self = [super initWithEffect:effect];
    if (self) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:30.0 weight:UIImageSymbolWeightSemibold];
        UIImage *image = [UIImage systemImageNamed:symbolName ?: @"checkmark.circle" withConfiguration:config] ?:
            [UIImage systemImageNamed:@"checkmark.circle" withConfiguration:config];
        _iconView = [[UIImageView alloc] initWithImage:image];
        _iconView.tintColor = success ? UIColor.whiteColor : [UIColor colorWithRed:1.0 green:0.62 blue:0.45 alpha:1.0];
        _iconView.contentMode = UIViewContentModeCenter;
        [self.contentView addSubview:_iconView];
        _label = [[UILabel alloc] init];
        _label.text = text;
        _label.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightSemibold];
        _label.textColor = UIColor.whiteColor;
        [self.contentView addSubview:_label];
    }
    return self;
}

- (CGSize)preferredSizeWithMaxWidth:(CGFloat)maxWidth {
    CGSize text = [self.label sizeThatFits:CGSizeMake(maxWidth, 60.0)];
    CGFloat width = MIN(maxWidth, ceil(text.width) + 44.0 + 16.0 + 2 * 36.0);
    return CGSizeMake(width, 84.0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = CGRectGetHeight(self.bounds);
    self.layer.cornerRadius = height / 2.0;
    self.iconView.frame = CGRectMake(36.0, 0.0, 44.0, height);
    CGFloat labelX = CGRectGetMaxX(self.iconView.frame) + 16.0;
    self.label.frame = CGRectMake(labelX, 0.0, CGRectGetWidth(self.bounds) - labelX - 36.0, height);
}

@end

@interface BrowserCommandRouter ()
@property (nonatomic, weak) id<BrowserCommandHost> host;
@property (nonatomic, weak) BrowserCommandToastView *toastView;
@property (nonatomic) NSUInteger toastGeneration;
@end

@implementation BrowserCommandRouter

- (instancetype)initWithHost:(id<BrowserCommandHost>)host {
    self = [super init];
    if (self) {
        _host = host;
    }
    return self;
}

/// "on"/"off" → @YES/@NO, sonst nil (umschalten).
static NSNumber *BrowserCommandDesiredState(NSString *argument) {
    NSString *value = argument.lowercaseString;
    if ([value isEqualToString:@"on"] || [value isEqualToString:@"an"] || [value isEqualToString:@"1"]) {
        return @YES;
    }
    if ([value isEqualToString:@"off"] || [value isEqualToString:@"aus"] || [value isEqualToString:@"0"]) {
        return @NO;
    }
    return nil;
}

- (BOOL)performCommandNamed:(NSString *)name argument:(NSString *)argument source:(BrowserCommandSource)source {
    return [self performCommandNamed:name argument:argument source:source feedbackNote:nil];
}

- (BOOL)performCommandNamed:(NSString *)name argument:(NSString *)argument source:(BrowserCommandSource)source
               feedbackNote:(NSString *)note {
    BrowserCommand *command = [BrowserCommand commandNamed:name.lowercaseString ?: @""];
    NSString *sourceName = [BrowserCommand nameForSource:source];
    if (command == nil) {
        NSLog(@"[Command] %@ arg=%@ quelle=%@ unbekannt", name, argument ?: @"-", sourceName);
        [self showFeedback:@"Unbekannter Befehl" symbolName:@"questionmark.circle" success:NO];
        return NO;
    }
    id<BrowserCommandHost> host = self.host;
    [host browserCommandPrepare];

    // Rückmeldung: Text und Erfolg; nil-Text = keine Einblendung (Befehl öffnet selbst eine Ansicht).
    NSString *feedback = nil;
    BOOL ok = YES;
    NSString *key = command.name;
    NSNumber *desired = BrowserCommandDesiredState(argument);

    if ([key isEqualToString:@"reader"]) {
        BOOL active = host.browserCommandReaderActive;
        if (desired != nil && desired.boolValue == active) {
            feedback = active ? @"Reader ist schon an" : @"Reader ist schon aus";
        } else if (!active && !host.browserCommandReaderAvailable) {
            ok = NO;
            feedback = @"Reader für diese Seite nicht verfügbar";
        } else {
            [host browserCommandToggleReader];
            feedback = active ? @"Reader ausgeschaltet" : @"Reader eingeschaltet";
        }
    } else if ([key isEqualToString:@"address"]) {
        if (argument.length > 0) {
            [host browserCommandOpenAddressOrSearch:argument];
            feedback = [NSString stringWithFormat:@"Öffne „%@“", argument];
        } else {
            [host browserCommandBeginAddressEditing];
        }
    } else if ([key isEqualToString:@"search"]) {
        if (argument.length == 0) {
            [host browserCommandBeginAddressEditing];
        } else {
            [host browserCommandSearch:argument];
            feedback = [NSString stringWithFormat:@"Suche: %@", argument];
        }
    } else if ([key isEqualToString:@"open"]) {
        NSString *address = argument.length > 0 ? [BrowserCommandParser addressFromSpokenText:argument] : nil;
        if (address != nil && [host browserCommandOpenAddress:address]) {
            feedback = [NSString stringWithFormat:@"Öffne %@", address];
        } else if (argument.length > 0) {
            [host browserCommandSearch:argument];
            feedback = [NSString stringWithFormat:@"Suche: %@", argument];
        } else {
            [host browserCommandBeginAddressEditing];
        }
    } else if ([key isEqualToString:@"back"]) {
        ok = [host browserCommandGoBack];
        feedback = ok ? @"Zurück" : @"Keine vorige Seite";
    } else if ([key isEqualToString:@"forward"]) {
        ok = [host browserCommandGoForward];
        feedback = ok ? @"Vor" : @"Keine nächste Seite";
    } else if ([key isEqualToString:@"reload"]) {
        ok = [host browserCommandReload];
        feedback = ok ? @"Neu laden" : @"Keine Seite geladen";
    } else if ([key isEqualToString:@"home"]) {
        [host browserCommandGoHome];
        feedback = @"Startseite";
    } else if ([key isEqualToString:@"newtab"]) {
        [host browserCommandNewTab];
        feedback = @"Neuer Tab";
    } else if ([key isEqualToString:@"closetab"]) {
        [host browserCommandCloseTab];
        feedback = @"Tab geschlossen";
    } else if ([key isEqualToString:@"tabs"]) {
        [host browserCommandShowTabs];
    } else if ([key isEqualToString:@"favorite"]) {
        NSNumber *state = [host browserCommandSetFavorite:desired];
        ok = state != nil;
        feedback = state == nil ? @"Diese Seite kann kein Favorit werden"
            : (state.boolValue ? @"Zu Favoriten hinzugefügt" : @"Aus Favoriten entfernt");
    } else if ([key isEqualToString:@"adblock-site"]) {
        NSString *site = [host browserCommandAdBlockSiteName];
        if (site == nil) {
            ok = NO;
            feedback = @"Keine Seite geladen";
        } else {
            BOOL active = [host browserCommandAdBlockActiveForSite];
            BOOL target = desired != nil ? desired.boolValue : !active;
            if (target != active) {
                [host browserCommandSetAdBlockActiveForSite:target];
            }
            feedback = [NSString stringWithFormat:@"Werbeblocker für %@ %@", site, target ? @"an" : @"aus"];
        }
    } else if ([key isEqualToString:@"top"]) {
        ok = [host browserCommandScrollToTop];
        feedback = ok ? @"Nach oben" : @"Schon ganz oben";
    } else if ([key isEqualToString:@"down"]) {
        ok = [host browserCommandScrollPageByFraction:0.8];
        feedback = ok ? @"Seite runter" : @"Schon am Seitenende";
    } else if ([key isEqualToString:@"up"]) {
        ok = [host browserCommandScrollPageByFraction:-0.8];
        feedback = ok ? @"Seite hoch" : @"Schon ganz oben";
    } else if ([key isEqualToString:@"menu"]) {
        [host browserCommandShowMenu];
    } else if ([key isEqualToString:@"help"]) {
        [host browserCommandShowHelp];
    } else if ([key isEqualToString:@"summarize"] || [key isEqualToString:@"translate"]) {
        // Rückmeldung (Karte bzw. Toast) kommt vom BrowserIntelligenceController.
        BOOL summarize = [key isEqualToString:@"summarize"];
        if (summarize && [host respondsToSelector:@selector(browserCommandSummarize)]) {
            [host browserCommandSummarize];
        } else if (!summarize && [host respondsToSelector:@selector(browserCommandTranslate)]) {
            ok = [host browserCommandTranslate];
        } else {
            ok = NO;
            feedback = @"Befehl nicht verfügbar";
        }
    } else if ([key isEqualToString:@"ask"]) {
        // Rückmeldung (Antwort-Karte oder „Keine passende Stelle“) kommt vom BrowserIntelligenceController.
        if (argument.length == 0) {
            ok = NO;
            feedback = @"Was soll ich die Seite fragen?";
        } else if ([host respondsToSelector:@selector(browserCommandAskPage:)]) {
            [host browserCommandAskPage:argument];
        } else {
            ok = NO;
            feedback = @"Befehl nicht verfügbar";
        }
    } else if (command.requiresVideo && ![host browserCommandPageHasVideo]) {
        ok = NO;
        feedback = @"Kein Video auf der Seite";
    } else if ([key isEqualToString:@"player"]) {
        [host browserCommandOpenVideoInPlayer];
        feedback = @"Video im Player";
    } else if ([key isEqualToString:@"playpause"]) {
        NSString *videoCommand = desired == nil ? @"toggle" : (desired.boolValue ? @"play" : @"pause");
        [host browserCommandSendVideoCommand:videoCommand];
        feedback = desired == nil ? @"Wiedergabe umgeschaltet" : (desired.boolValue ? @"Wiedergabe" : @"Pause");
    } else if ([key isEqualToString:@"seek"]) {
        NSInteger seconds = argument.length > 0 ? argument.integerValue : 10;
        if (seconds == 0) {
            seconds = 10;
        }
        [host browserCommandSendVideoCommand:[NSString stringWithFormat:@"seek:%ld", (long)seconds]];
        feedback = [NSString stringWithFormat:@"%ld s %@", (long)labs(seconds), seconds < 0 ? @"zurück" : @"vor"];
    } else {
        ok = NO;
        feedback = @"Befehl nicht verfügbar";
    }

    NSLog(@"[Command] %@ arg=%@ quelle=%@ %@%@", command.name, argument ?: @"-", sourceName, ok ? @"ok" : @"nicht möglich",
          feedback != nil ? [NSString stringWithFormat:@" („%@“)", feedback] : @"");
    if (feedback != nil) {
        [self showFeedback:note.length > 0 ? [NSString stringWithFormat:@"%@  ·  %@", feedback, note] : feedback
                symbolName:command.symbolName success:ok];
    }
    return ok;
}

- (void)showFeedback:(NSString *)text symbolName:(NSString *)symbolName success:(BOOL)success {
    UIView *container = [self.host browserCommandFeedbackContainerView];
    if (container == nil || text.length == 0) {
        return;
    }
    [self.toastView removeFromSuperview];
    BrowserCommandToastView *toast = [[BrowserCommandToastView alloc] initWithText:text
                                                                         symbolName:success ? symbolName : @"exclamationmark.circle"
                                                                            success:success];
    CGRect bounds = container.bounds;
    CGSize size = [toast preferredSizeWithMaxWidth:MIN(1200.0, CGRectGetWidth(bounds) - 160.0)];
    toast.frame = CGRectMake(floor((CGRectGetWidth(bounds) - size.width) / 2.0), CGRectGetHeight(bounds) - size.height - 90.0,
                             size.width, size.height);
    toast.alpha = 0.0;
    toast.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [container addSubview:toast];
    self.toastView = toast;
    NSUInteger generation = ++self.toastGeneration;
    [UIView animateWithDuration:0.22 delay:0.0 usingSpringWithDamping:0.8 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        toast.alpha = 1.0;
        toast.transform = CGAffineTransformIdentity;
    } completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.toastGeneration != generation) {
            return;
        }
        [UIView animateWithDuration:0.3 animations:^{
            toast.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

@end
