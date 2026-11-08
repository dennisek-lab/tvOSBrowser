#import "BrowserGuideViewController.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

@interface BrowserGuideViewController ()
@property (nonatomic, strong) UIButton *primaryButton;
@end

@implementation BrowserGuideViewController

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
        cardEffect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    }
#endif
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:cardEffect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.clipsToBounds = YES;
    card.layer.cornerRadius = 56.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:card];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"So bedienst du den Browser";
    title.font = [UIFont systemFontOfSize:48.0 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;

    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 22.0;
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"hand.point.up.left", @"Zeigen und klicken", @"Über das Clickpad wischen, drücken zum Klicken. Der Zeiger rastet an Links ein."],
        @[@"arrow.up.arrow.down", @"Scrollen", @"Clickpad oben oder unten drücken. Zweimal oben öffnet die Adresse."],
        @[@"arrow.left.arrow.right", @"Zurück und vor", @"Clickpad links oder rechts drücken. Über einem Video: 10 Sekunden spulen."],
        @[@"playpause", @"Play/Pause", @"Startet und stoppt Videos. Gedrückt halten: suchen und sprechen."],
        @[@"ellipsis.circle", @"Mehr", @"Werbeblocker, Cookie-Ablehner und Einstellungen findest du oben rechts unter •••."],
    ];
    for (NSArray<NSString *> *item in items) {
        [rows addArrangedSubview:[self rowWithSymbol:item[0] title:item[1] text:item[2]]];
    }

    UILabel *tips = [[UILabel alloc] init];
    tips.text = @"Tipps: Am Clickpad-Ring kreisen springt von Link zu Link. Zweimal unten verkleinert die Leiste.";
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
    content.spacing = 34.0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content setCustomSpacing:40.0 afterView:rows];
    [content setCustomSpacing:44.0 afterView:tips];
    [card.contentView addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:1280.0],
        [content.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:52.0],
        [content.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-52.0],
        [content.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:64.0],
        [content.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-64.0],
    ]];
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
    UIButtonConfiguration *config = nil;
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        config = prominent ? [UIButtonConfiguration prominentGlassButtonConfiguration] : [UIButtonConfiguration glassButtonConfiguration];
    }
#endif
    if (config == nil) {
        config = prominent ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration grayButtonConfiguration];
    }
    config.title = title;
    config.contentInsets = NSDirectionalEdgeInsetsMake(20.0, 36.0, 20.0, 36.0);
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventPrimaryActionTriggered];
    return button;
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

@end
