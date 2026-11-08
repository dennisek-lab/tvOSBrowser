#import "BrowserWebSubtitleOverlay.h"
#import "BrowserShape.h"

#import <MediaAccessibility/MediaAccessibility.h>
#import <QuartzCore/QuartzCore.h>

/// Höchstens so weit wird ohne neue Meldung der Seite weitergezählt.
static NSTimeInterval const kBrowserWebSubtitleMaxExtrapolation = 1.5;
static NSUInteger const kBrowserWebSubtitleMaxCues = 400;

/// CADisplayLink hält sein Ziel fest; der Vermittler hält die Ebene nur schwach.
@interface BrowserWebSubtitleDisplayLinkTarget : NSObject
@property (nonatomic, weak) BrowserWebSubtitleOverlay *overlay;
@end

@interface BrowserWebSubtitleOverlay ()
@property (nonatomic, strong) UIView *bubble;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) NSMutableArray<BrowserWebSubtitleCue *> *cues;
@property (nonatomic) BrowserWebAudioPlaybackState state;
@property (nonatomic, readwrite, nullable) BrowserWebSubtitleCue *displayedCue;
@property (nonatomic, copy, nullable) NSString *hintText;
@property (nonatomic) CFTimeInterval hintUntil;
@property (nonatomic, copy, nullable) NSString *shownText;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, weak, nullable) UIView *hostWebView;
@property (nonatomic) BOOL hostedInWindow;
- (void)tick;
@end

@implementation BrowserWebSubtitleDisplayLinkTarget
- (void)tick:(CADisplayLink *)link {
    (void)link;
    [self.overlay tick];
}
@end

@implementation BrowserWebSubtitleOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cues = [NSMutableArray array];
        _holdDuration = 3.0;
        _state.videoRect = CGRectNull;
        _state.paused = YES;
        _state.rate = 1.0;
        _bubble = [[UIView alloc] initWithFrame:CGRectZero];
        BrowserShapeApply(_bubble.layer, BrowserShapeSmallRadius);
        _bubble.hidden = YES;
        [self addSubview:_bubble];
        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.numberOfLines = 3;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.lineBreakMode = NSLineBreakByWordWrapping;
        [_bubble addSubview:_label];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(captionAppearanceDidChange:)
                                                   name:(__bridge NSString *)kMACaptionAppearanceSettingsChangedNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)captionAppearanceDidChange:(NSNotification *)notification {
    (void)notification;
    self.shownText = nil;
    [self tick];
}

#pragma mark - Einhängen

- (void)attachToWebView:(UIView *)webView {
    self.hostWebView = webView;
    self.hostedInWindow = NO;
    if (webView == nil) {
        [self removeFromSuperview];
        [self.displayLink invalidate];
        self.displayLink = nil;
        return;
    }
    self.frame = webView.bounds;
    [webView addSubview:self];
    if (self.displayLink == nil) {
        BrowserWebSubtitleDisplayLinkTarget *target = [BrowserWebSubtitleDisplayLinkTarget new];
        target.overlay = self;
        self.displayLink = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(10, 15, 15);
        [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

/// Im Element-Vollbild kann WebKit ein eigenes Fenster zeigen; dann über das oberste Fenster der Szene legen.
- (void)updateHostForFullscreen:(BOOL)fullscreen {
    UIView *webView = self.hostWebView;
    if (webView == nil) {
        return;
    }
    if (fullscreen) {
        UIWindow *top = webView.window;
        for (UIWindow *window in webView.window.windowScene.windows) {
            if (!window.hidden && window.windowLevel >= top.windowLevel) {
                top = window;
            }
        }
        if (top != nil && (self.superview != top)) {
            self.frame = top.bounds;
            [top addSubview:self];
            self.hostedInWindow = YES;
        }
    } else if (self.hostedInWindow || self.superview != webView) {
        self.frame = webView.bounds;
        [webView addSubview:self];
        self.hostedInWindow = NO;
    } else if (self.superview.subviews.lastObject != self) {
        // Neue Unteransichten der WebView (Überblend-Schnappschuss) liegen sonst darüber.
        [self.superview bringSubviewToFront:self];
    }
}

#pragma mark - Daten

- (void)updatePlaybackState:(BrowserWebAudioPlaybackState)state {
    self.state = state;
    [self updateHostForFullscreen:state.fullscreen];
    [self tick];
}

- (NSTimeInterval)currentMediaTime {
    BrowserWebAudioPlaybackState state = self.state;
    if (state.paused || state.seeking || state.hostTime <= 0.0) {
        return state.mediaTime;
    }
    NSTimeInterval elapsed = MIN(kBrowserWebSubtitleMaxExtrapolation, MAX(0.0, CACurrentMediaTime() - state.hostTime));
    return state.mediaTime + elapsed * (state.rate > 0.0 ? state.rate : 1.0);
}

- (BOOL)currentPlaybackPaused {
    return self.state.paused;
}

- (NSString *)layoutSummary {
    NSUInteger index = [self.superview.subviews indexOfObject:self];
    return [NSString stringWithFormat:@"in=%@ (%lu/%lu) frame=%@ bubble=%@ hidden=%d text=%@",
            NSStringFromClass(self.superview.class), (unsigned long)index, (unsigned long)self.superview.subviews.count,
            NSStringFromCGRect(self.frame), NSStringFromCGRect(self.bubble.frame), self.bubble.hidden, self.label.text];
}

- (NSUInteger)cueCount {
    return self.cues.count;
}

- (void)addCues:(NSArray<BrowserWebSubtitleCue *> *)cues replacingFrom:(NSTimeInterval)start {
    NSIndexSet *stale = [self.cues indexesOfObjectsPassingTest:^BOOL(BrowserWebSubtitleCue *cue, __unused NSUInteger index, __unused BOOL *stop) {
        return cue.start >= start - 0.001;
    }];
    [self.cues removeObjectsAtIndexes:stale];
    for (BrowserWebSubtitleCue *cue in cues) {
        if (cue.text.length > 0) {
            [self.cues addObject:cue];
        }
    }
    [self.cues sortUsingComparator:^NSComparisonResult(BrowserWebSubtitleCue *a, BrowserWebSubtitleCue *b) {
        return a.start < b.start ? NSOrderedAscending : (a.start > b.start ? NSOrderedDescending : NSOrderedSame);
    }];
    if (self.cues.count > kBrowserWebSubtitleMaxCues) {
        [self.cues removeObjectsInRange:NSMakeRange(0, self.cues.count - kBrowserWebSubtitleMaxCues)];
    }
    [self tick];
}

- (void)removeAllCues {
    [self.cues removeAllObjects];
    self.displayedCue = nil;
    [self tick];
}

- (void)showHint:(NSString *)text duration:(NSTimeInterval)duration {
    self.hintText = text;
    self.hintUntil = CACurrentMediaTime() + MAX(0.5, duration);
    [self tick];
}

- (BrowserWebSubtitleCue *)cueAtTime:(NSTimeInterval)time {
    BrowserWebSubtitleCue *covering = nil;
    BrowserWebSubtitleCue *recent = nil;
    for (BrowserWebSubtitleCue *cue in self.cues) {
        if (cue.start > time + 0.05) {
            break;
        }
        if (time < cue.end) {
            covering = cue; // bei Überlappung gewinnt der spätere Beginn
        } else if (time - cue.end < self.holdDuration) {
            recent = cue;
        }
    }
    return covering ?: recent;
}

#pragma mark - Anzeige

- (void)tick {
    if (self.superview == nil) {
        return;
    }
    NSTimeInterval now = self.currentMediaTime;
    BrowserWebSubtitleCue *cue = CGRectIsNull(self.state.videoRect) && !self.state.fullscreen ? nil : [self cueAtTime:now];
    // Bei Pause bleibt der zuletzt gezeigte Untertitel stehen (wie beim Fernsehen), solange er zur Stelle passt.
    if (cue == nil && self.state.paused && self.displayedCue != nil && [self.cues containsObject:self.displayedCue] &&
        now >= self.displayedCue.start - 0.05 && now - self.displayedCue.end < 3.0) {
        cue = self.displayedCue;
    }
    if (cue != self.displayedCue) {
        self.displayedCue = cue;
        if (cue != nil && self.cueDidAppear != nil) {
            self.cueDidAppear(cue, now);
        }
    }
    NSString *text = cue.text;
    BOOL hint = NO;
    if (text.length == 0 && self.hintText.length > 0 && CACurrentMediaTime() < self.hintUntil) {
        text = self.hintText;
        hint = YES;
    }
    if (text.length == 0) {
        self.bubble.hidden = YES;
        self.shownText = nil;
        return;
    }
    [self layoutBubbleWithText:text hint:hint];
}

- (CGRect)targetArea {
    CGRect bounds = self.bounds;
    if (self.state.fullscreen) {
        return bounds;
    }
    CGRect video = self.state.videoRect;
    if (CGRectIsNull(video)) {
        return bounds;
    }
    if (self.hostedInWindow && self.hostWebView != nil) {
        video = [self.hostWebView convertRect:video toView:self];
    }
    CGRect visible = CGRectIntersection(video, bounds);
    return CGRectIsNull(visible) || CGRectGetHeight(visible) < 40.0 ? CGRectNull : visible;
}

- (void)layoutBubbleWithText:(NSString *)text hint:(BOOL)hint {
    CGRect area = [self targetArea];
    if (CGRectIsNull(area)) {
        self.bubble.hidden = YES;
        return;
    }
    MACaptionAppearanceDomain domain = kMACaptionAppearanceDomainUser;
    CGFloat relative = MACaptionAppearanceGetRelativeCharacterSize(domain, NULL);
    if (relative <= 0.0) {
        relative = 1.0;
    }
    // Sofaabstand: etwa 1/16 der Videohöhe, mindestens 34 pt (1080p-Raster), höchstens 72 pt.
    // Bezug ist die ganze Videohöhe (nicht nur der sichtbare Teil), höchstens die Bildschirmhöhe.
    CGFloat videoHeight = CGRectGetHeight(area);
    if (!self.state.fullscreen && !CGRectIsNull(self.state.videoRect)) {
        videoHeight = MIN(CGRectGetHeight(self.bounds), MAX(videoHeight, CGRectGetHeight(self.state.videoRect)));
    }
    CGFloat size = MIN(72.0, MAX(34.0, videoHeight * 0.062)) * relative;
    if (hint) {
        size *= 0.8;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%.1f|%@", text, size, NSStringFromCGRect(area)];
    if ([key isEqualToString:self.shownText] && !self.bubble.hidden) {
        return;
    }
    self.shownText = key;

    UIFont *font = nil;
    // Nur eine ausdrücklich in den Untertitel-Einstellungen gewählte Schrift übernehmen; der Standard ist eine
    // Serifenschrift – sonst SF Pro halbfett wie im nativen Player.
    MACaptionAppearanceBehavior fontBehavior = kMACaptionAppearanceBehaviorUseContentIfAvailable;
    CTFontDescriptorRef descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, &fontBehavior, kMACaptionAppearanceFontStyleDefault);
    if (descriptor != NULL && fontBehavior != kMACaptionAppearanceBehaviorUseValue) {
        CFRelease(descriptor);
        descriptor = NULL;
    }
    if (descriptor != NULL) {
        font = [UIFont fontWithDescriptor:(__bridge UIFontDescriptor *)descriptor size:size];
        CFRelease(descriptor);
    }
    if (font == nil) {
        font = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
    }

    UIColor *foreground = UIColor.whiteColor;
    CGColorRef foregroundRef = MACaptionAppearanceCopyForegroundColor(domain, NULL);
    if (foregroundRef != NULL) {
        foreground = [UIColor colorWithCGColor:foregroundRef];
        CFRelease(foregroundRef);
    }
    CGFloat foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(domain, NULL);
    foreground = [foreground colorWithAlphaComponent:foregroundOpacity > 0.0 ? foregroundOpacity : 1.0];

    UIColor *background = UIColor.blackColor;
    CGColorRef backgroundRef = MACaptionAppearanceCopyBackgroundColor(domain, NULL);
    if (backgroundRef != NULL) {
        background = [UIColor colorWithCGColor:backgroundRef];
        CFRelease(backgroundRef);
    }
    // Halbtransparent, außer die Nutzerin hat in den Einstellungen ausdrücklich etwas anderes gewählt.
    MACaptionAppearanceBehavior behavior = kMACaptionAppearanceBehaviorUseContentIfAvailable;
    CGFloat backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(domain, &behavior);
    if (behavior != kMACaptionAppearanceBehaviorUseValue || backgroundOpacity <= 0.0) {
        backgroundOpacity = 0.6;
    }
    self.bubble.backgroundColor = [background colorWithAlphaComponent:backgroundOpacity];

    NSShadow *shadow = nil;
    MACaptionAppearanceTextEdgeStyle edge = MACaptionAppearanceGetTextEdgeStyle(domain, NULL);
    if (edge == kMACaptionAppearanceTextEdgeStyleDropShadow || edge == kMACaptionAppearanceTextEdgeStyleUniform ||
        edge == kMACaptionAppearanceTextEdgeStyleUndefined || edge == kMACaptionAppearanceTextEdgeStyleNone) {
        shadow = [NSShadow new];
        shadow.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.8];
        shadow.shadowOffset = edge == kMACaptionAppearanceTextEdgeStyleUniform ? CGSizeZero : CGSizeMake(0.0, 2.0);
        shadow.shadowBlurRadius = 3.0;
    }
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    NSMutableDictionary *attributes = [@{NSFontAttributeName: font, NSForegroundColorAttributeName: foreground,
                                         NSParagraphStyleAttributeName: paragraph} mutableCopy];
    if (shadow != nil) {
        attributes[NSShadowAttributeName] = shadow;
    }
    self.label.attributedText = [[NSAttributedString alloc] initWithString:text attributes:attributes];

    CGFloat paddingX = round(size * 0.45), paddingY = round(size * 0.18);
    CGFloat maxWidth = MAX(200.0, CGRectGetWidth(area) * 0.9) - 2.0 * paddingX;
    CGSize textSize = [self.label sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    textSize.width = MIN(ceil(textSize.width), maxWidth);
    textSize.height = MIN(ceil(textSize.height), ceil(font.lineHeight * 3.0 + 2.0));
    CGSize bubbleSize = CGSizeMake(textSize.width + 2.0 * paddingX, textSize.height + 2.0 * paddingY);
    CGFloat bottom = CGRectGetMaxY(area) - MAX(16.0, CGRectGetHeight(area) * 0.06);
    CGRect frame = CGRectMake(round(CGRectGetMidX(area) - bubbleSize.width / 2.0), round(bottom - bubbleSize.height), bubbleSize.width, bubbleSize.height);
    // Im sichtbaren Bereich halten.
    frame.origin.x = MIN(MAX(frame.origin.x, CGRectGetMinX(self.bounds) + 8.0), CGRectGetMaxX(self.bounds) - frame.size.width - 8.0);
    frame.origin.y = MIN(MAX(frame.origin.y, CGRectGetMinY(self.bounds) + 8.0), CGRectGetMaxY(self.bounds) - frame.size.height - 8.0);
    self.bubble.frame = frame;
    self.label.frame = CGRectMake(paddingX, paddingY, textSize.width, textSize.height);
    self.bubble.hidden = NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.shownText = nil;
    [self tick];
}

@end
