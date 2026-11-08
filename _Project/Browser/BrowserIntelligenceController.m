//
//  BrowserIntelligenceController.m
//  Browser
//

#import "BrowserIntelligenceController.h"
#import "BrowserIntelligence.h"
#import "BrowserMotion.h"
#import "BrowserWebView.h"

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#endif

static const CGFloat kCardCornerRadius = 56.0;
static const CGFloat kCardPadding = 64.0;
static const NSTimeInterval kHintDuration = 10.0;

static UIVisualEffect *BrowserIntelligenceGlassEffect(void) {
#if __has_include(<UIKit/UIGlassEffect.h>)
    if (@available(tvOS 26.0, *)) {
        return [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    }
#endif
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

static UIFont *BrowserIntelligenceSerifFont(CGFloat size, UIFontWeight weight) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *serif = [base.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif];
    return serif != nil ? [UIFont fontWithDescriptor:serif size:size] : base;
}

#pragma mark - Karte „Zusammenfassung“

/// Abgedunkelter Hintergrund mit Glas-Karte in der Mitte: Kopf (Symbol, „Zusammenfassung“, Seitentitel),
/// Sätze als Liste in Reader-Schrift (New York), Fußzeile mit Quelle („lokal“), Dauer und Bedienhinweis.
@interface BrowserSummaryCardView : UIView
@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIVisualEffectView *cardView;
@property (nonatomic, strong) UIView *tintView;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *headingLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *separatorView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray<UILabel *> *bulletLabels;
@property (nonatomic, strong) NSMutableArray<UILabel *> *sentenceLabels;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, copy) NSArray<NSString *> *sentences;
@property (nonatomic) CGFloat sentenceFontSize;
@property (nonatomic) BOOL dismissing;
@end

@implementation BrowserSummaryCardView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _bulletLabels = [NSMutableArray array];
        _sentenceLabels = [NSMutableArray array];
        _sentenceFontSize = 32.0;

        _dimView = [[UIView alloc] initWithFrame:self.bounds];
        _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        _dimView.alpha = 0.0;
        [self addSubview:_dimView];

        _cardView = [[UIVisualEffectView alloc] initWithEffect:nil];
        _cardView.clipsToBounds = YES;
        _cardView.layer.cornerRadius = kCardCornerRadius;
        _cardView.layer.cornerCurve = kCACornerCurveContinuous;
        _cardView.layer.borderWidth = 1.0;
        _cardView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
        _cardView.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [self addSubview:_cardView];

        // Wie Leiste und Aufklapp-Karte: Glas mit leichter Abdunkelung, damit Schrift auf jeder Seite lesbar bleibt.
        _tintView = [UIView new];
        _tintView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.42];
        _tintView.alpha = 0.0;
        [_cardView.contentView addSubview:_tintView];

        _contentView = [UIView new];
        _contentView.alpha = 0.0;
        [_cardView.contentView addSubview:_contentView];

        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:34.0 weight:UIImageSymbolWeightSemibold];
        UIImage *icon = [UIImage systemImageNamed:@"text.line.3.summary" withConfiguration:config] ?:
            [UIImage systemImageNamed:@"list.bullet.rectangle" withConfiguration:config];
        _iconView = [[UIImageView alloc] initWithImage:icon];
        _iconView.tintColor = UIColor.whiteColor;
        _iconView.contentMode = UIViewContentModeCenter;
        [_contentView addSubview:_iconView];

        _headingLabel = [UILabel new];
        _headingLabel.text = @"Zusammenfassung";
        _headingLabel.font = [UIFont systemFontOfSize:38.0 weight:UIFontWeightBold];
        _headingLabel.textColor = UIColor.whiteColor;
        [_contentView addSubview:_headingLabel];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_contentView addSubview:_titleLabel];

        _separatorView = [UIView new];
        _separatorView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        [_contentView addSubview:_separatorView];

        _spinner = [[UIActivityIndicatorView alloc] initWithFrame:CGRectZero];
        _spinner.activityIndicatorViewStyle = UIActivityIndicatorViewStyleLarge;
        _spinner.color = UIColor.whiteColor;
        [_contentView addSubview:_spinner];

        _statusLabel = [UILabel new];
        _statusLabel.text = @"Wird zusammengefasst …";
        _statusLabel.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightMedium];
        _statusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
        [_contentView addSubview:_statusLabel];

        _footerLabel = [UILabel new];
        _footerLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightRegular];
        _footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
        _footerLabel.numberOfLines = 1;
        _footerLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_contentView addSubview:_footerLabel];
        _footerLabel.text = @"Zurück-Taste bricht ab";
    }
    return self;
}

- (CGFloat)cardWidth {
    return MIN(1320.0, CGRectGetWidth(self.bounds) - 240.0);
}

- (CGFloat)textWidth {
    return [self cardWidth] - 2 * kCardPadding - 44.0;
}

/// Höhe des Inhalts bei der aktuellen Schriftgröße.
- (CGFloat)contentHeight {
    CGFloat height = kCardPadding + 48.0 + 8.0 + 34.0 + 28.0 + 1.0 + 32.0; // Kopf, Titel, Trennlinie
    if (self.sentences.count == 0) {
        height += 80.0;
    } else {
        for (UILabel *label in self.sentenceLabels) {
            height += ceil([label sizeThatFits:CGSizeMake([self textWidth], CGFLOAT_MAX)].height) + 22.0;
        }
    }
    height += 18.0 + 28.0 + kCardPadding; // Fußzeile
    return height;
}

- (void)setTitleText:(NSString *)title {
    self.titleLabel.text = title;
}

- (void)showSentences:(NSArray<NSString *> *)sentences footer:(NSString *)footer {
    self.sentences = sentences;
    for (UILabel *label in self.sentenceLabels) { [label removeFromSuperview]; }
    for (UILabel *label in self.bulletLabels) { [label removeFromSuperview]; }
    [self.sentenceLabels removeAllObjects];
    [self.bulletLabels removeAllObjects];
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    self.statusLabel.hidden = YES;
    for (NSString *sentence in sentences) {
        UILabel *bullet = [UILabel new];
        bullet.text = @"•";
        bullet.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        [self.contentView addSubview:bullet];
        [self.bulletLabels addObject:bullet];
        UILabel *label = [UILabel new];
        label.text = sentence;
        label.numberOfLines = 0;
        label.textColor = [UIColor colorWithWhite:1.0 alpha:0.94];
        [self.contentView addSubview:label];
        [self.sentenceLabels addObject:label];
    }
    self.footerLabel.text = footer;
    // Schrift verkleinern, bis alles auf den Bildschirm passt (32 → 24 pt).
    CGFloat maxHeight = CGRectGetHeight(self.bounds) - 160.0;
    for (CGFloat size = 32.0; size >= 24.0; size -= 2.0) {
        self.sentenceFontSize = size;
        [self applySentenceFont];
        if ([self contentHeight] <= maxHeight) {
            break;
        }
    }
}

- (void)applySentenceFont {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineSpacing = self.sentenceFontSize * 0.22;
    for (UILabel *label in self.sentenceLabels) {
        label.attributedText = [[NSAttributedString alloc] initWithString:label.text ?: @""
                                                               attributes:@{NSFontAttributeName: BrowserIntelligenceSerifFont(self.sentenceFontSize, UIFontWeightRegular),
                                                                            NSParagraphStyleAttributeName: style}];
    }
    for (UILabel *bullet in self.bulletLabels) {
        bullet.font = [UIFont systemFontOfSize:self.sentenceFontSize weight:UIFontWeightBold];
    }
}

- (CGRect)cardFrame {
    CGFloat width = [self cardWidth];
    CGFloat height = MIN([self contentHeight], CGRectGetHeight(self.bounds) - 120.0);
    return CGRectMake(floor((CGRectGetWidth(self.bounds) - width) / 2.0), floor((CGRectGetHeight(self.bounds) - height) / 2.0), width, height);
}

- (void)layoutCard {
    // Nur Mittelpunkt und Größe setzen: eine laufende Skalierung (transform) bleibt so erhalten.
    CGRect frame = [self cardFrame];
    self.cardView.bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    self.cardView.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    CGRect bounds = self.cardView.bounds;
    self.tintView.frame = bounds;
    self.contentView.frame = bounds;
    CGFloat x = kCardPadding;
    CGFloat width = CGRectGetWidth(bounds) - 2 * kCardPadding;
    CGFloat y = kCardPadding;
    self.iconView.frame = CGRectMake(x, y, 48.0, 48.0);
    self.headingLabel.frame = CGRectMake(x + 64.0, y, width - 64.0, 48.0);
    y += 48.0 + 8.0;
    self.titleLabel.frame = CGRectMake(x + 64.0, y, width - 64.0, 34.0);
    y += 34.0 + 28.0;
    self.separatorView.frame = CGRectMake(x, y, width, 1.0);
    y += 1.0 + 32.0;
    if (self.sentences.count == 0) {
        self.spinner.center = CGPointMake(x + 28.0, y + 40.0);
        self.statusLabel.frame = CGRectMake(x + 72.0, y + 10.0, width - 72.0, 60.0);
    } else {
        CGFloat textX = x + 44.0;
        for (NSUInteger i = 0; i < self.sentenceLabels.count; i++) {
            UILabel *label = self.sentenceLabels[i];
            CGFloat height = ceil([label sizeThatFits:CGSizeMake([self textWidth], CGFLOAT_MAX)].height);
            label.frame = CGRectMake(textX, y, [self textWidth], height);
            self.bulletLabels[i].frame = CGRectMake(x + 4.0, y, 30.0, self.sentenceFontSize * 1.25);
            y += height + 22.0;
        }
    }
    self.footerLabel.frame = CGRectMake(x, CGRectGetHeight(bounds) - kCardPadding - 28.0, width, 28.0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.dismissing) {
        [self layoutCard];
    }
}

- (void)present {
    [self.spinner startAnimating];
    [self layoutCard];
    BOOL liquid = BrowserMotion.liquidGlassEnabled;
    if (liquid) {
        self.cardView.transform = CGAffineTransformMakeScale(0.94, 0.94);
    }
    [BrowserMotion glassAppear:self.cardView effect:BrowserIntelligenceGlassEffect() kind:BrowserMotionKindAppear alongside:^{
        self.dimView.alpha = 1.0;
        self.tintView.alpha = 1.0;
        self.cardView.transform = CGAffineTransformIdentity;
    } completion:nil];
    [BrowserMotion animateKind:BrowserMotionKindFade delay:0.1 options:0 animations:^{
        self.contentView.alpha = 1.0;
    } completion:nil];
}

/// Ladezustand → Ergebnis: Karte federt auf die neue Höhe, Inhalt blendet über.
- (void)transitionToSentences:(NSArray<NSString *> *)sentences footer:(NSString *)footer {
    self.contentView.alpha = 0.0;
    CGRect oldBounds = self.cardView.bounds;
    CGPoint oldCenter = self.cardView.center;
    [self showSentences:sentences footer:footer];
    // Inhalt sofort an die Endposition (sonst wachsen die Zeilen sichtbar aus der Ecke), nur die Glasfläche federt.
    [UIView performWithoutAnimation:^{
        [self layoutCard];
    }];
    CGRect newBounds = self.cardView.bounds;
    CGPoint newCenter = self.cardView.center;
    self.cardView.bounds = oldBounds;
    self.cardView.center = oldCenter;
    self.tintView.frame = oldBounds;
    [BrowserMotion animateKind:BrowserMotionKindStandard delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.cardView.bounds = newBounds;
        self.cardView.center = newCenter;
        self.tintView.frame = newBounds;
    } completion:nil];
    [BrowserMotion animateKind:BrowserMotionKindFade delay:0.08 options:0 animations:^{
        self.contentView.alpha = 1.0;
    } completion:nil];
}

- (void)dismissWithCompletion:(void (^)(void))completion {
    if (self.dismissing) {
        return;
    }
    self.dismissing = YES;
    BOOL liquid = BrowserMotion.liquidGlassEnabled;
    [BrowserMotion animateKind:BrowserMotionKindSnap delay:0.0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.contentView.alpha = 0.0;
    } completion:nil];
    [BrowserMotion glassDisappear:self.cardView kind:BrowserMotionKindDisappear alongside:^{
        self.dimView.alpha = 0.0;
        self.tintView.alpha = 0.0;
        if (liquid) {
            self.cardView.transform = CGAffineTransformMakeScale(0.96, 0.96);
        }
    } completion:^(__unused BOOL finished) {
        [self removeFromSuperview];
        if (completion != nil) {
            completion();
        }
    }];
}

@end

#pragma mark - Kapsel „Übersetzen?“

@interface BrowserTranslateHintView : UIVisualEffectView
@property (nonatomic, strong) UIView *tintView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic) BOOL dismissing;
@end

@implementation BrowserTranslateHintView

- (instancetype)initWithTitle:(NSString *)title detail:(NSString *)detail {
    self = [super initWithEffect:nil];
    if (self) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        _tintView = [UIView new];
        _tintView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
        _tintView.alpha = 0.0;
        [self.contentView addSubview:_tintView];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:34.0 weight:UIImageSymbolWeightSemibold];
        _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"translate" withConfiguration:config] ?:
                     [UIImage systemImageNamed:@"globe" withConfiguration:config]];
        _iconView.tintColor = UIColor.whiteColor;
        _iconView.contentMode = UIViewContentModeCenter;
        [self.contentView addSubview:_iconView];
        _titleLabel = [UILabel new];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        [self.contentView addSubview:_titleLabel];
        _detailLabel = [UILabel new];
        _detailLabel.text = detail;
        _detailLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightRegular];
        _detailLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.66];
        [self.contentView addSubview:_detailLabel];
    }
    return self;
}

- (CGSize)preferredSizeWithMaxWidth:(CGFloat)maxWidth {
    CGFloat text = MAX([self.titleLabel sizeThatFits:CGSizeMake(maxWidth, 40.0)].width,
                       [self.detailLabel sizeThatFits:CGSizeMake(maxWidth, 30.0)].width);
    return CGSizeMake(MIN(maxWidth, ceil(text) + 40.0 + 48.0 + 20.0 + 2 * 44.0), 110.0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = CGRectGetHeight(self.bounds);
    self.layer.cornerRadius = height / 2.0;
    self.tintView.frame = self.bounds;
    self.iconView.frame = CGRectMake(44.0, 0.0, 48.0, height);
    CGFloat x = 44.0 + 48.0 + 20.0;
    CGFloat width = CGRectGetWidth(self.bounds) - x - 44.0;
    self.titleLabel.frame = CGRectMake(x, 18.0, width, 40.0);
    self.detailLabel.frame = CGRectMake(x, 60.0, width, 30.0);
}

- (void)presentInView:(UIView *)container {
    CGRect bounds = container.bounds;
    CGSize size = [self preferredSizeWithMaxWidth:MIN(1300.0, CGRectGetWidth(bounds) - 200.0)];
    self.frame = CGRectMake(floor((CGRectGetWidth(bounds) - size.width) / 2.0), CGRectGetHeight(bounds) - size.height - 80.0, size.width, size.height);
    [container addSubview:self];
    [self layoutIfNeeded];
    BOOL liquid = BrowserMotion.liquidGlassEnabled;
    if (liquid) {
        self.transform = CGAffineTransformMakeScale(0.9, 0.9);
    }
    [BrowserMotion glassAppear:self effect:BrowserIntelligenceGlassEffect() kind:BrowserMotionKindAppear alongside:^{
        self.tintView.alpha = 1.0;
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)dismissWithCompletion:(void (^)(void))completion {
    if (self.dismissing) {
        return;
    }
    self.dismissing = YES;
    BOOL liquid = BrowserMotion.liquidGlassEnabled;
    [BrowserMotion glassDisappear:self kind:BrowserMotionKindDisappear alongside:^{
        self.tintView.alpha = 0.0;
        self.iconView.alpha = 0.0;
        self.titleLabel.alpha = 0.0;
        self.detailLabel.alpha = 0.0;
        if (liquid) {
            self.transform = CGAffineTransformMakeScale(0.92, 0.92);
        }
    } completion:^(__unused BOOL finished) {
        [self removeFromSuperview];
        if (completion != nil) {
            completion();
        }
    }];
}

@end

#pragma mark - Controller

@interface BrowserIntelligenceController ()
@property (nonatomic, copy) UIView * (^containerProvider)(void);
@property (nonatomic, copy) BrowserWebView * (^webViewProvider)(void);
@property (nonatomic, copy) void (^feedbackHandler)(NSString *, NSString *, BOOL);
@property (nonatomic, weak) BrowserSummaryCardView *cardView;
@property (nonatomic, weak) BrowserTranslateHintView *hintView;
@property (nonatomic, copy, nullable) NSString *hintHost;
@property (nonatomic) NSUInteger summaryGeneration;
@property (nonatomic) NSUInteger hintGeneration;
/// Hosts, denen der Hinweis in dieser Sitzung schon angeboten wurde (nicht bei jeder Unterseite erneut).
@property (nonatomic, strong) NSMutableSet<NSString *> *offeredHosts;
@end

@implementation BrowserIntelligenceController

- (instancetype)initWithContainerProvider:(UIView * (^)(void))containerProvider
                          webViewProvider:(BrowserWebView * (^)(void))webViewProvider
                          feedbackHandler:(void (^)(NSString *, NSString *, BOOL))feedbackHandler {
    self = [super init];
    if (self) {
        _containerProvider = [containerProvider copy];
        _webViewProvider = [webViewProvider copy];
        _feedbackHandler = [feedbackHandler copy];
        _offeredHosts = [NSMutableSet set];
    }
    return self;
}

- (BOOL)summaryVisible {
    return self.cardView != nil && !self.cardView.dismissing;
}

- (BOOL)translationHintVisible {
    return self.hintView != nil && !self.hintView.dismissing;
}

- (void)feedback:(NSString *)text symbol:(NSString *)symbol success:(BOOL)success {
    if (self.feedbackHandler != nil) {
        self.feedbackHandler(text, symbol, success);
    }
}

#pragma mark Zusammenfassen

- (void)summarizeCurrentPage {
    BrowserWebView *webView = self.webViewProvider ? self.webViewProvider() : nil;
    UIView *container = self.containerProvider ? self.containerProvider() : nil;
    if (webView == nil || container == nil || webView.request.URL == nil) {
        [self feedback:@"Keine Seite geladen" symbol:@"text.line.3.summary" success:NO];
        return;
    }
    [self dismissTranslationHint];
    [self.cardView dismissWithCompletion:nil];
    BrowserSummaryCardView *card = [[BrowserSummaryCardView alloc] initWithFrame:container.bounds];
    NSString *host = [BrowserIntelligence normalizedHostForURL:webView.request.URL] ?: @"";
    [card setTitleText:host];
    [container addSubview:card];
    self.cardView = card;
    [card present];

    NSUInteger generation = ++self.summaryGeneration;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    __weak typeof(self) weakSelf = self;
    [BrowserIntelligence.sharedIntelligence summarizeWebView:webView completion:^(BrowserAISummary *summary, NSDictionary *info, NSError *error) {
        typeof(self) self_ = weakSelf;
        if (self_ == nil || self_.summaryGeneration != generation || self_.cardView != card || card.dismissing) {
            return; // abgebrochen (Menütaste, neue Seite)
        }
        if (summary == nil || summary.sentences.count == 0) {
            [card dismissWithCompletion:nil];
            NSString *message = error.code == BrowserIntelligenceErrorTooShort || error.code == BrowserIntelligenceErrorNoText
                ? @"Zu wenig Text zum Zusammenfassen" : (error.localizedDescription ?: @"Zusammenfassen nicht möglich");
            [self_ feedback:message symbol:@"text.line.3.summary" success:NO];
            return;
        }
        NSString *title = [info[@"title"] isKindOfClass:NSString.class] && [info[@"title"] length] > 0 ? info[@"title"] : host;
        [card setTitleText:[title isEqualToString:host] ? host : [NSString stringWithFormat:@"%@  ·  %@", title, host]];
        NSTimeInterval total = CFAbsoluteTimeGetCurrent() - start;
        NSString *language = summary.language.length > 0 ? [BrowserIntelligence displayNameForLanguage:summary.language] : nil;
        NSMutableArray<NSString *> *footer = [NSMutableArray arrayWithObject:@"Lokal auf dem Apple TV"];
        [footer addObject:[NSString stringWithFormat:@"%lu von %lu Sätzen", (unsigned long)summary.sentences.count,
                           (unsigned long)summary.candidateCount]];
        if (language != nil) { [footer addObject:language]; }
        [footer addObject:total < 0.1 ? @"unter 0,1 s"
                                      : [[NSString stringWithFormat:@"%.1f s", total] stringByReplacingOccurrencesOfString:@"." withString:@","]];
        [footer addObject:@"Zurück-Taste schließt"];
        [card transitionToSentences:summary.sentences footer:[footer componentsJoinedByString:@"  ·  "]];
        NSLog(@"[AI] Karte: %lu Sätze, Schrift %.0f pt, gesamt %.0f ms", (unsigned long)summary.sentences.count, card.sentenceFontSize, total * 1000.0);
    }];
}

- (void)dismissSummary {
    self.summaryGeneration++;
    [self.cardView dismissWithCompletion:nil];
}

#pragma mark Übersetzen

- (BOOL)translateCurrentPageFromHint:(BOOL)fromHint {
    BrowserWebView *webView = self.webViewProvider ? self.webViewProvider() : nil;
    NSURL *url = webView.request.URL;
    [self dismissTranslationHint];
    if (url == nil) {
        [self feedback:@"Keine Seite geladen" symbol:@"translate" success:NO];
        return NO;
    }
    if ([BrowserIntelligence isTranslationProxyURL:url]) {
        [self feedback:@"Seite ist schon übersetzt" symbol:@"translate" success:YES];
        return NO;
    }
    NSString *target = BrowserIntelligence.systemLanguageCode;
    NSURL *proxy = [BrowserIntelligence translationProxyURLForURL:url targetLanguage:target];
    NSLog(@"[AI] übersetzen %@ -> %@", url.absoluteString, proxy.absoluteString ?: @"(nicht möglich)");
    if (proxy == nil) {
        [self feedback:@"Diese Seite lässt sich nicht übersetzen" symbol:@"translate" success:NO];
        return NO;
    }
    if (fromHint) {
        [self loadTranslation:proxy inWebView:webView target:target];
        return YES;
    }
    // Befehl oder Menü: Seiten, die schon in der Systemsprache sind, nicht über Google schicken.
    [BrowserIntelligence.sharedIntelligence languageInfoForWebView:webView completion:^(BrowserPageLanguageInfo *info) {
        if (![webView.request.URL isEqual:url]) {
            return;
        }
        if (info.confidence >= 0.65 && [info.language.lowercaseString hasPrefix:target]) {
            NSLog(@"[AI] übersetzen: Seite ist schon %@", info.language);
            [self feedback:[NSString stringWithFormat:@"Seite ist schon auf %@", [BrowserIntelligence displayNameForLanguage:target]]
                    symbol:@"translate" success:YES];
            return;
        }
        [self loadTranslation:proxy inWebView:webView target:target];
    }];
    return YES;
}

- (BOOL)translateCurrentPage {
    return [self translateCurrentPageFromHint:NO];
}

- (void)loadTranslation:(NSURL *)proxy inWebView:(BrowserWebView *)webView target:(NSString *)target {
    // Logins und Cookies der Originalseite gelten auf translate.goog nicht; Google sieht die Seite.
    [webView loadRequest:[NSURLRequest requestWithURL:proxy]];
    [self feedback:[NSString stringWithFormat:@"Übersetze auf %@ (Google)", [BrowserIntelligence displayNameForLanguage:target]]
            symbol:@"translate" success:YES];
}

- (void)showTranslationHintForHost:(NSString *)host language:(NSString *)language {
    UIView *container = self.containerProvider ? self.containerProvider() : nil;
    if (container == nil || self.summaryVisible) {
        return;
    }
    [self.hintView dismissWithCompletion:nil];
    NSString *name = [BrowserIntelligence displayNameForLanguage:language];
    NSString *title = [NSString stringWithFormat:@"Seite auf %@ – übersetzen?", name];
    NSString *detail = [NSString stringWithFormat:@"Play/Pause übersetzt  ·  Zurück-Taste: für %@ nicht mehr fragen", host];
    BrowserTranslateHintView *hint = [[BrowserTranslateHintView alloc] initWithTitle:title detail:detail];
    [hint presentInView:container];
    self.hintView = hint;
    self.hintHost = host;
    NSUInteger generation = ++self.hintGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHintDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.hintGeneration == generation) {
            [self dismissTranslationHint];
        }
    });
}

- (void)dismissTranslationHint {
    self.hintGeneration++;
    [self.hintView dismissWithCompletion:nil];
    self.hintHost = nil;
}

#pragma mark Seitenereignisse

- (void)pageDidStartLoadInWebView:(__unused BrowserWebView *)webView {
    [self dismissSummary];
    [self dismissTranslationHint];
}

- (void)activeWebViewDidChange {
    [self dismissSummary];
    [self dismissTranslationHint];
}

- (void)pageDidFinishLoadInWebView:(BrowserWebView *)webView {
    NSURL *url = webView.request.URL;
    // Kurz warten: Seiten bauen Text oft per Skript nach, Cookie-Dialoge verschwinden.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BrowserWebView *current = self.webViewProvider ? self.webViewProvider() : nil;
        if (current != webView || webView.isLoading || ![webView.request.URL isEqual:url]) {
            return;
        }
        NSString *host = [BrowserIntelligence normalizedHostForURL:url];
        if (host == nil || [self.offeredHosts containsObject:host]) {
            return;
        }
        [BrowserIntelligence.sharedIntelligence languageInfoForWebView:webView completion:^(BrowserPageLanguageInfo *info) {
            NSLog(@"[AI] Übersetzen-Hinweis %@: %@ (Sprache=%@ %.2f, lang=%@, Text=%lu, Login=%d)", host, info.reason,
                  info.language ?: @"?", info.confidence, info.declaredLanguage ?: @"-", (unsigned long)info.sampleLength, info.hasLogin);
            BrowserWebView *now = self.webViewProvider ? self.webViewProvider() : nil;
            if (!info.shouldOfferTranslation || now != webView || ![webView.request.URL isEqual:url]) {
                return;
            }
            [self.offeredHosts addObject:host];
            [self showTranslationHintForHost:host language:info.language];
        }];
    });
}

#pragma mark Tasten

- (BOOL)handleMenuPress {
    if (self.summaryVisible) {
        [self dismissSummary];
        return YES;
    }
    if (self.translationHintVisible) {
        NSString *host = self.hintHost;
        if (host != nil) {
            [BrowserIntelligence.sharedIntelligence declineTranslationForHost:host];
            NSLog(@"[AI] Übersetzen abgelehnt für %@", host);
        }
        [self dismissTranslationHint];
        [self feedback:[NSString stringWithFormat:@"Für %@ nicht mehr fragen", host ?: @"diese Seite"] symbol:@"translate" success:YES];
        return YES;
    }
    return NO;
}

- (BOOL)handlePlayPausePress {
    if (!self.translationHintVisible) {
        return NO;
    }
    [self translateCurrentPageFromHint:YES];
    return YES;
}

#pragma mark Selbsttest

#if DEBUG
- (BOOL)runSelfTestStep:(NSString *)step {
    BrowserIntelligence *intelligence = BrowserIntelligence.sharedIntelligence;
    BrowserWebView *webView = self.webViewProvider ? self.webViewProvider() : nil;
    if ([step isEqualToString:@"ai"]) {
        NSLog(@"[SelfTest] ai %@", [intelligence diagnosticsDescription]);
        if (webView != nil) {
            [intelligence languageInfoForWebView:webView completion:^(BrowserPageLanguageInfo *info) {
                NSLog(@"[SelfTest] ai Seite %@: Sprache=%@ (%.2f) lang=%@ Login=%d Text=%lu -> %@ (Hinweis=%d)",
                      webView.request.URL.host ?: @"-", info.language ?: @"?", info.confidence, info.declaredLanguage ?: @"-",
                      info.hasLogin, (unsigned long)info.sampleLength, info.reason, info.shouldOfferTranslation);
            }];
        }
        return YES;
    }
    if ([step isEqualToString:@"summarize"]) {
        NSLog(@"[SelfTest] summarize %@", webView.request.URL.absoluteString ?: @"-");
        [self summarizeCurrentPage];
        return YES;
    }
    if ([step isEqualToString:@"translate"]) {
        NSURL *url = webView.request.URL;
        NSLog(@"[SelfTest] translate %@ -> %@", url.absoluteString ?: @"-",
              [BrowserIntelligence translationProxyURLForURL:url targetLanguage:BrowserIntelligence.systemLanguageCode] ?: @"-");
        [self translateCurrentPage];
        return YES;
    }
    if ([step isEqualToString:@"translate:hint"]) {
        NSString *host = [BrowserIntelligence normalizedHostForURL:webView.request.URL] ?: @"example.com";
        NSLog(@"[SelfTest] translate:hint %@", host);
        [self showTranslationHintForHost:host language:@"en"];
        return YES;
    }
    if ([step isEqualToString:@"translate:reset"]) {
        [intelligence resetDeclinedTranslations];
        [self.offeredHosts removeAllObjects];
        NSLog(@"[SelfTest] translate:reset");
        return YES;
    }
    return NO;
}
#endif

@end
