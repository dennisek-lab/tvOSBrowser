#import "BrowserSubtitleOverlayView.h"

#import <MediaAccessibility/MediaAccessibility.h>

static const CGFloat kSubtitleBaseFontSize = 54.0;   // bei 1920 × 1080 pt, Relativgröße 1

@interface BrowserSubtitleOverlayView ()
@property (nonatomic, strong) UIView *captionBox;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UIView *statusBox;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, copy, nullable) NSString *currentText;
@property (nonatomic) NSUInteger statusToken;
@property (nonatomic) CGFloat appliedHeight;
@end

@implementation BrowserSubtitleOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _captionBox = [UIView new];
        _captionBox.layer.cornerRadius = 10.0;
        _captionBox.layer.cornerCurve = kCACornerCurveContinuous;
        _captionBox.alpha = 0.0;
        [self addSubview:_captionBox];

        _captionLabel = [UILabel new];
        _captionLabel.numberOfLines = 3;
        _captionLabel.textAlignment = NSTextAlignmentCenter;
        _captionLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [_captionBox addSubview:_captionLabel];

        _statusBox = [UIView new];
        _statusBox.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
        _statusBox.layer.cornerRadius = 12.0;
        _statusBox.alpha = 0.0;
        [self addSubview:_statusBox];

        _statusLabel = [UILabel new];
        _statusLabel.numberOfLines = 2;
        _statusLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightMedium];
        _statusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        [_statusBox addSubview:_statusLabel];

        [self applyCaptionAppearance];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(captionAppearanceDidChange:)
                                                   name:(__bridge NSString *)kMACaptionAppearanceSettingsChangedNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)captionAppearanceDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyCaptionAppearance];
        [self setNeedsLayout];
    });
}

- (void)applyCaptionAppearance {
    MACaptionAppearanceDomain domain = kMACaptionAppearanceDomainUser;
    CGFloat relativeSize = MACaptionAppearanceGetRelativeCharacterSize(domain, NULL);
    if (!(relativeSize > 0.2 && relativeSize < 4.0)) {
        relativeSize = 1.0;
    }
    // Schrift mit der Bildhöhe skalieren (tvOS-Bildschirm 1080 pt hoch); ohne Größe vorerst 1080 annehmen.
    CGFloat height = self.bounds.size.height > 1.0 ? self.bounds.size.height : 1080.0;
    self.appliedHeight = self.bounds.size.height;
    CGFloat fontSize = kSubtitleBaseFontSize * relativeSize * MIN(1.5, MAX(0.4, height / 1080.0));

    // Schrift nur übernehmen, wenn der Nutzer sie in den Einstellungen ausdrücklich gewählt hat
    // (Standard liefert eine Serifenschrift); sonst die Systemschrift, halbfett, gut lesbar aus der Ferne.
    UIFont *font = nil;
    MACaptionAppearanceBehavior fontBehavior = kMACaptionAppearanceBehaviorUseContentIfAvailable;
    CTFontDescriptorRef descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, &fontBehavior, kMACaptionAppearanceFontStyleDefault);
    if (descriptor != NULL && fontBehavior != kMACaptionAppearanceBehaviorUseValue) {
        CFRelease(descriptor);
        descriptor = NULL;
    }
    if (descriptor != NULL) {
        CTFontRef ctFont = CTFontCreateWithFontDescriptor(descriptor, fontSize, NULL);
        if (ctFont != NULL) {
            font = [UIFont fontWithDescriptor:[UIFontDescriptor fontDescriptorWithName:(__bridge_transfer NSString *)CTFontCopyPostScriptName(ctFont) size:fontSize] size:fontSize];
            CFRelease(ctFont);
        }
        CFRelease(descriptor);
    }
    if (font == nil || [font.fontName hasPrefix:@"."]) {
        font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    }
    self.captionLabel.font = font;

    UIColor *foreground = UIColor.whiteColor;
    CGColorRef foregroundRef = MACaptionAppearanceCopyForegroundColor(domain, NULL);
    if (foregroundRef != NULL) {
        foreground = [UIColor colorWithCGColor:foregroundRef];
        CFRelease(foregroundRef);
    }
    CGFloat foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(domain, NULL);
    self.captionLabel.textColor = [foreground colorWithAlphaComponent:foregroundOpacity > 0.3 ? foregroundOpacity : 1.0];

    UIColor *background = UIColor.blackColor;
    CGColorRef backgroundRef = MACaptionAppearanceCopyBackgroundColor(domain, NULL);
    if (backgroundRef != NULL) {
        background = [UIColor colorWithCGColor:backgroundRef];
        CFRelease(backgroundRef);
    }
    // Immer halbtransparent: Systemwert, aber begrenzt, damit Text lesbar und Bild sichtbar bleibt.
    CGFloat backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(domain, NULL);
    backgroundOpacity = MIN(0.8, MAX(0.55, backgroundOpacity));
    self.captionBox.backgroundColor = [background colorWithAlphaComponent:backgroundOpacity];

    MACaptionAppearanceTextEdgeStyle edge = MACaptionAppearanceGetTextEdgeStyle(domain, NULL);
    CALayer *layer = self.captionLabel.layer;
    if (edge == kMACaptionAppearanceTextEdgeStyleDropShadow || edge == kMACaptionAppearanceTextEdgeStyleUniform) {
        layer.shadowColor = UIColor.blackColor.CGColor;
        layer.shadowOpacity = 0.9;
        layer.shadowRadius = edge == kMACaptionAppearanceTextEdgeStyleUniform ? 2.0 : 1.0;
        layer.shadowOffset = edge == kMACaptionAppearanceTextEdgeStyleUniform ? CGSizeZero : CGSizeMake(2.0, 2.0);
    } else {
        layer.shadowOpacity = 0.0;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    if (CGRectIsEmpty(bounds)) {
        return;
    }
    if (fabs(bounds.size.height - self.appliedHeight) > 1.0) {
        [self applyCaptionAppearance];
    }
    CGFloat maxWidth = floor(bounds.size.width * 0.78);
    CGFloat paddingX = 24.0;
    CGFloat paddingY = 12.0;
    CGSize textSize = [self.captionLabel sizeThatFits:CGSizeMake(maxWidth - 2 * paddingX, CGFLOAT_MAX)];
    textSize.width = MIN(ceil(textSize.width), maxWidth - 2 * paddingX);
    textSize.height = ceil(textSize.height);
    CGFloat bottomMargin = floor(bounds.size.height * 0.08);
    CGRect box = CGRectMake(floor((bounds.size.width - textSize.width - 2 * paddingX) / 2.0),
                            bounds.size.height - bottomMargin - textSize.height - 2 * paddingY,
                            textSize.width + 2 * paddingX,
                            textSize.height + 2 * paddingY);
    self.captionBox.frame = box;
    self.captionLabel.frame = CGRectMake(paddingX, paddingY, textSize.width, textSize.height);

    CGSize statusSize = [self.statusLabel sizeThatFits:CGSizeMake(bounds.size.width * 0.5, CGFLOAT_MAX)];
    statusSize = CGSizeMake(ceil(statusSize.width), ceil(statusSize.height));
    self.statusBox.frame = CGRectMake(floor(bounds.size.width * 0.05), floor(bounds.size.height * 0.06),
                                      statusSize.width + 36.0, statusSize.height + 20.0);
    self.statusLabel.frame = CGRectMake(18.0, 10.0, statusSize.width, statusSize.height);
}

- (void)setSubtitleText:(NSString *)text {
    NSString *normalized = text.length > 0 ? text : nil;
    if ((normalized == nil && self.currentText == nil) || [normalized isEqualToString:self.currentText]) {
        return;
    }
    self.currentText = normalized;
    if (normalized != nil) {
        self.captionLabel.text = normalized;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }
    [UIView animateWithDuration:0.15 animations:^{
        self.captionBox.alpha = normalized != nil ? 1.0 : 0.0;
    }];
}

- (void)showStatus:(NSString *)status duration:(NSTimeInterval)duration {
    NSUInteger token = ++self.statusToken;
    self.statusLabel.text = status;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [UIView animateWithDuration:0.2 animations:^{
        self.statusBox.alpha = 1.0;
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self.statusToken) {
            return;
        }
        [UIView animateWithDuration:0.3 animations:^{
            self.statusBox.alpha = 0.0;
        }];
    });
}

@end
