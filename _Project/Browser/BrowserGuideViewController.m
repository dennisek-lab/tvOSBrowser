#import "BrowserGuideViewController.h"
#import "BrowserMotion.h"
#import "BrowserShape.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

@interface BrowserGuideViewController ()
@property (nonatomic, strong) UIButton *primaryButton;
@property (nonatomic, strong) UIVisualEffectView *motionCardView;
@end

@implementation BrowserGuideViewController

+ (NSString *)whatsNewVersion {
    return @"2.0-fork-1";
}

/// Neuerungen gegenüber dem ursprünglichen tvOS Browser (Symbol, Titel, Text). Zwei Spalten, höchstens 14.
+ (NSArray<NSArray<NSString *> *> *)whatsNewItems {
    return @[
        @[@"sparkles", @"Magnetic Buttons", @"Der Zeiger zieht sich auf Links und Knöpfe, sie heben sich als Glas ab und leuchten."],
        @[@"drop", @"Liquid Glass", @"Leiste, Menüs und Dialoge aus Glas, federnde Animationen."],
        @[@"cursorarrow.motionlines", @"Neuer Zeiger", @"Gleitet flüssig ohne Ruckeln, Lupe über kleinem Text."],
        @[@"square.on.square", @"Tabs", @"Übersicht mit Vorschau, bleiben nach Neustart erhalten."],
        @[@"text.page", @"Reader", @"Artikel ohne Werbung und Ablenkung lesen."],
        @[@"hand.raised.fill", @"Werbeblocker", @"Filterlisten von uBlock Origin Lite, Ausnahme bei Sperrseiten."],
        @[@"checkmark.shield.fill", @"Cookie-Banner", @"Werden automatisch abgelehnt."],
        @[@"play.rectangle", @"Nativer Player", @"Videos im Apple-Player, mit Bild-in-Bild und iPhone-Steuerung."],
        @[@"captions.bubble", @"Automatische Untertitel", @"Auf dem Gerät erzeugt, im Player und in der Webseite."],
        @[@"list.bullet.rectangle", @"Zusammenfassen und fragen", @"Seite in wenigen Sätzen, passende Stelle anspringen."],
        @[@"translate", @"Übersetzen", @"Hinweis bei fremdsprachigen Seiten, ein Druck genügt."],
        @[@"mic", @"Sprachbefehle", @"„Reader“, „zurück“ oder „suche Wetter“ per Siri-Taste."],
        @[@"star", @"Favoriten im Adressfeld", @"Favoriten, oft und zuletzt besuchte Seiten auf einen Blick."],
        @[@"network", @"Cloudflare-DNS", @"Verschlüsselte Namensauflösung, abschaltbar."],
    ];
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.alpha = 0.9;
    [self.view addSubview:backdrop];

    UIVisualEffect *cardEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        if (BrowserMotion.glassMaterialAvailable) { // im alten Design dunkler Blur
            cardEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        }
    }
#endif
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:cardEffect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.clipsToBounds = YES;
    BrowserShapeApply(card.layer, BrowserShapeCardRadius);
    [self.view addSubview:card];
    self.motionCardView = card;
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    if (self.whatsNew) {
        [self buildWhatsNewInCard:card];
        return;
    }

    UILabel *title = [[UILabel alloc] init];
    title.text = @"So bedienst du den Browser";
    title.font = [UIFont systemFontOfSize:48.0 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;

    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 12.0;
    // Höchstens ca. 7 Zeilen, damit die Karte auf den Bildschirm passt. Belegung siehe docs/ERWEITERUNGEN.md, Abschnitt 8.2.
    // Weitere Zeilen (z. B. „Sprachbefehle“) einfach unten anhängen; es ist Platz für eine mehr.
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"hand.point.up.left", @"Zeigen und klicken", @"Über das Clickpad wischen, zum Klicken drücken."],
        @[@"arrow.up.arrow.down", @"Scrollen und Adresse", @"Oben oder unten drücken scrollt. Zweimal oben: Adressleiste. Zweimal unten: Leiste klein."],
        @[@"arrow.left.arrow.right", @"Von Knopf zu Knopf", @"Links/rechts drücken, halten: weiter. Zweimal rechts: Menü. Im Video: 10 s spulen."],
        @[@"playpause", @"Play/Pause", @"Video starten oder stoppen, sonst Eingabe. Halten: suchen und sprechen. Zweimal: Menü."],
        @[@"chevron.backward", @"Zurück", @"Menü-Taste: Adressleiste schließen, Reader beenden, dann eine Seite zurück."],
        @[@"text.page", @"Reader und mehr", @"Reader-Knopf links von •••. Werbeblocker und Einstellungen findest du unter •••."],
        @[@"mic", @"Sprachbefehle", @"Im Adressfeld Siri-Taste halten und z. B. „Reader“, „zurück“ oder „suche Wetter“ sagen."],
    ];
    for (NSArray<NSString *> *item in items) {
        [rows addArrangedSubview:[self rowWithSymbol:item[0] title:item[1] text:item[2]]];
    }

    UILabel *tips = [[UILabel alloc] init];
    tips.text = @"Kreisbewegung am Rand des Clickpads: von Element zu Element. Geht auch mit iPhone/iPad.";
    tips.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightRegular];
    tips.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    tips.textAlignment = NSTextAlignmentCenter;
    tips.numberOfLines = 0;

    self.primaryButton = [self buttonWithTitle:@"Los geht's" prominent:YES action:@selector(closeTapped)];
    NSString *secondTitle = self.dontShowOnLaunch ? @"Beim Start anzeigen" : @"Nicht mehr anzeigen";
    UIButton *secondary = [self buttonWithTitle:secondTitle prominent:NO action:@selector(toggleTapped)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.primaryButton, secondary]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 32.0;
    buttons.distribution = UIStackViewDistributionFillEqually;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[title, rows, tips, buttons]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 26.0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content setCustomSpacing:28.0 afterView:rows];
    [content setCustomSpacing:32.0 afterView:tips];
    [card.contentView addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [card.widthAnchor constraintEqualToConstant:1280.0],
        [content.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:BrowserShapeCardInset],
        [content.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-BrowserShapeCardInset],
        [content.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:BrowserShapeCardInset],
        [content.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-BrowserShapeCardInset],
    ]];
    rows.layoutMarginsRelativeArrangement = YES;
    rows.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0.0, 20.0, 0.0, 20.0);
}

- (void)buildWhatsNewInCard:(UIVisualEffectView *)card {
    UILabel *title = [[UILabel alloc] init];
    title.text = @"Was ist neu";
    title.font = [UIFont systemFontOfSize:52.0 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"Diese Fassung des tvOS Browser bringt gegenüber dem Original mit:";
    subtitle.font = [UIFont systemFontOfSize:27.0 weight:UIFontWeightRegular];
    subtitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    subtitle.textAlignment = NSTextAlignmentCenter;

    NSArray<NSArray<NSString *> *> *items = [self.class whatsNewItems];
    NSUInteger half = (items.count + 1) / 2;
    UIStackView *left = [[UIStackView alloc] init];
    UIStackView *right = [[UIStackView alloc] init];
    for (UIStackView *column in @[left, right]) {
        column.axis = UILayoutConstraintAxisVertical;
        column.spacing = 18.0;
        column.alignment = UIStackViewAlignmentFill;
    }
    for (NSUInteger i = 0; i < items.count; i++) {
        NSArray<NSString *> *item = items[i];
        UIView *row = [self compactRowWithSymbol:item[0] title:item[1] text:item[2] featured:(i == 0)];
        [(i < half ? left : right) addArrangedSubview:row];
    }
    UIStackView *columns = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
    columns.axis = UILayoutConstraintAxisHorizontal;
    columns.spacing = 56.0;
    columns.distribution = UIStackViewDistributionFillEqually;
    columns.alignment = UIStackViewAlignmentTop;
    columns.layoutMarginsRelativeArrangement = YES;
    columns.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0.0, 20.0, 0.0, 20.0);

    self.primaryButton = [self buttonWithTitle:@"Weiter" prominent:YES action:@selector(closeTapped)];
    UIButton *secondary = [self buttonWithTitle:@"Bedienung ansehen" prominent:NO action:@selector(showGuideTapped)];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.primaryButton, secondary]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 32.0;
    buttons.distribution = UIStackViewDistributionFillEqually;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle, columns, buttons]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 10.0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content setCustomSpacing:40.0 afterView:subtitle];
    [content setCustomSpacing:44.0 afterView:columns];
    [card.contentView addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [card.widthAnchor constraintEqualToConstant:1660.0],
        [content.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:BrowserShapeCardInset],
        [content.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-BrowserShapeCardInset],
        [content.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:BrowserShapeCardInset],
        [content.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-BrowserShapeCardInset],
    ]];
}

- (UIView *)compactRowWithSymbol:(NSString *)symbol title:(NSString *)title text:(NSString *)text featured:(BOOL)featured {
    CGFloat side = 60.0;
    UIView *circle = [[UIView alloc] init];
    circle.translatesAutoresizingMaskIntoConstraints = NO;
    circle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    BrowserShapeApply(circle.layer, side / 2.0);
    if (featured) {
        // Hauptfunktion (Magnetic Buttons): Kreis im Regenbogen-Leuchten, wie der Glow um gewählte Elemente.
        CAGradientLayer *rainbow = [CAGradientLayer layer];
        rainbow.type = kCAGradientLayerConic;
        rainbow.startPoint = CGPointMake(0.5, 0.5);
        rainbow.endPoint = CGPointMake(0.5, 0.0);
        rainbow.frame = CGRectMake(0.0, 0.0, side, side);
        rainbow.cornerRadius = side / 2.0;
        rainbow.colors = @[(id)UIColor.systemPinkColor.CGColor, (id)UIColor.systemOrangeColor.CGColor,
                           (id)UIColor.systemYellowColor.CGColor, (id)UIColor.systemGreenColor.CGColor,
                           (id)UIColor.systemTealColor.CGColor, (id)UIColor.systemBlueColor.CGColor,
                           (id)UIColor.systemPurpleColor.CGColor, (id)UIColor.systemPinkColor.CGColor];
        [circle.layer addSublayer:rainbow];
        circle.layer.shadowColor = UIColor.systemPinkColor.CGColor;
        circle.layer.shadowOpacity = 0.5;
        circle.layer.shadowRadius = 12.0;
        circle.layer.shadowOffset = CGSizeZero;
    }
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:27.0 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:config] ?: [UIImage systemImageNamed:@"sparkles" withConfiguration:config];
    UIImageView *icon = [[UIImageView alloc] initWithImage:image];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [circle addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [circle.widthAnchor constraintEqualToConstant:side],
        [circle.heightAnchor constraintEqualToConstant:side],
        [icon.centerXAnchor constraintEqualToAnchor:circle.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:circle.centerYAnchor],
    ]];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:29.0 weight:UIFontWeightBold];
    titleLabel.textColor = UIColor.whiteColor;
    UILabel *textLabel = [[UILabel alloc] init];
    textLabel.text = text;
    textLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightRegular];
    textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    textLabel.numberOfLines = 2;
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, textLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[circle, texts]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 24.0;
    return row;
}

- (void)showGuideTapped {
    void (^handler)(void) = self.showGuideHandler;
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler != nil) {
            handler();
        }
    }];
}

- (UIView *)rowWithSymbol:(NSString *)symbol title:(NSString *)title text:(NSString *)text {
    UIView *circle = [[UIView alloc] init];
    circle.translatesAutoresizingMaskIntoConstraints = NO;
    circle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    circle.layer.cornerRadius = 36.0;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:34.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:config]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [circle addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [circle.widthAnchor constraintEqualToConstant:72.0],
        [circle.heightAnchor constraintEqualToConstant:72.0],
        [icon.centerXAnchor constraintEqualToAnchor:circle.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:circle.centerYAnchor],
    ]];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:32.0 weight:UIFontWeightBold];
    titleLabel.textColor = UIColor.whiteColor;
    UILabel *textLabel = [[UILabel alloc] init];
    textLabel.text = text;
    textLabel.font = [UIFont systemFontOfSize:27.0 weight:UIFontWeightRegular];
    textLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    textLabel.numberOfLines = 0;
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, textLabel]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 4.0;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[circle, texts]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 28.0;
    return row;
}

- (UIButton *)buttonWithTitle:(NSString *)title prominent:(BOOL)prominent action:(SEL)action {
    // Beide Knöpfe gleich: Unter tvOS zeigt nur der Fokus (hell, angehoben), welcher Knopf gewählt ist.
    // Die hervorgehobene Variante (prominent) ist schon ohne Fokus hell und war vom gewählten Knopf kaum
    // zu unterscheiden. Der Hauptknopf bekommt stattdessen den ersten Fokus (preferredFocusEnvironments).
    (void)prominent;
    UIButtonConfiguration *config = nil;
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        if (BrowserMotion.glassMaterialAvailable) { // im alten Design graue Knöpfe
            config = [UIButtonConfiguration glassButtonConfiguration];
        }
    }
#endif
    if (config == nil) {
        config = [UIButtonConfiguration grayButtonConfiguration];
    }
    config.title = title;
    config.contentInsets = NSDirectionalEdgeInsetsMake(20.0, 36.0, 20.0, 36.0);
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    // Kapsel mit 80 pt Höhe: liegt mit BrowserShapeCardInset Abstand konzentrisch in der Kartenecke.
    [button.heightAnchor constraintEqualToConstant:2.0 * (BrowserShapeCardRadius - BrowserShapeCardInset)].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    return button;
}

// Glas-Karte: Liquid Glass materialisiert und federt beim Erscheinen, schlicht bleibt es bei der Überblendung.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (animated) {
        [BrowserMotion presentCard:self.motionCardView glassEffect:self.motionCardView.effect];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (animated) {
        [BrowserMotion dismissCard:self.motionCardView];
    }
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return self.primaryButton != nil ? @[self.primaryButton] : @[];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleTapped {
    BOOL newValue = !self.dontShowOnLaunch;
    self.dontShowOnLaunch = newValue;
    void (^handler)(BOOL) = self.toggleHandler;
    if (handler != nil) {
        handler(newValue);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeMenu) {
            [self closeTapped];
            return;
        }
    }
    [super pressesBegan:presses withEvent:event];
}

/// Das Ende des Menü-Drucks gehört zum Schließen oben; weitergereicht käme es nach der Ausblendung
/// beim ViewController an und blätterte zurück bzw. verließe die App.
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeMenu) {
            return;
        }
    }
    [super pressesEnded:presses withEvent:event];
}

@end
