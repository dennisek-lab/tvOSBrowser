#import "BrowserCursorRenderer.h"
#import "BrowserPreferencesStore.h"

/// Rand um die Zeichnung (Punkte) für Kontur und Schatten; zugleich Lage der Klickspitze.
static const CGFloat kMargin = 14.0;
/// Linker Rand größer: Daumen der Hand ragt links von der Fingerspitze heraus.
static const CGFloat kMarginX = 30.0;
/// Zeichenfaktor: Zeigerhöhe etwa 44 pt für den Sofaabstand.
static const CGFloat kScale = 2.1;
static const CGFloat kBorder = 1.5;

@implementation BrowserCursorRenderer

+ (CGPoint)hotspot {
    return CGPointMake(kMarginX, kMargin);
}

+ (UIImage *)imageForKind:(BrowserCursorKind)kind {
    BrowserPreferencesStore *preferences = [[BrowserPreferencesStore alloc] init];
    BrowserCursorStyle style = (BrowserCursorStyle)preferences.cursorStyle;
    if (style == BrowserCursorStyleMacDark && preferences.classicDesignEnabled) {
        // Altes Design mit Standardstil: die Bitmaps des Originals (Assets „Cursor“ und „Pointer“).
        UIImage *classic = [self classicImageForKind:kind];
        if (classic != nil) {
            return classic;
        }
    }
    return [self imageForKind:kind style:style];
}

/// Zeiger der ursprünglichen Fassung: 64-pt-Bitmaps (Pfeil „Cursor“, Hand „Pointer“), in ein Bild mit demselben Rand wie
/// die Vektorzeiger gesetzt, damit die Klickspitze bei `+hotspot` liegt. Für die Texteinfügemarke gab es kein Bild (nil).
+ (nullable UIImage *)classicImageForKind:(BrowserCursorKind)kind {
    if (kind == BrowserCursorKindIBeam) {
        return nil;
    }
    static NSMutableDictionary<NSNumber *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    @synchronized (cache) {
        UIImage *image = cache[@(kind)];
        if (image != nil) {
            return image;
        }
        UIImage *bitmap = [UIImage imageNamed:kind == BrowserCursorKindArrow ? @"Cursor" : @"Pointer"];
        if (bitmap == nil) {
            return nil;
        }
        // Klickspitze im Originalbild: Pfeilspitze oben links, bei der Hand die Fingerspitze.
        CGPoint tip = kind == BrowserCursorKindArrow ? CGPointMake(1.0, 1.0) : CGPointMake(10.0, 2.0);
        CGSize size = CGSizeMake(kMarginX + bitmap.size.width + kMargin, kMargin + bitmap.size.height + kMargin);
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.opaque = NO;
        image = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
            [bitmap drawAtPoint:CGPointMake(kMarginX - tip.x, kMargin - tip.y)];
        }];
        cache[@(kind)] = image;
        return image;
    }
}

+ (UIImage *)imageForKind:(BrowserCursorKind)kind style:(BrowserCursorStyle)style {
    static NSMutableDictionary<NSNumber *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    NSNumber *key = @(style * 10 + kind);
    @synchronized (cache) {
        UIImage *image = cache[key];
        if (!image) {
            image = [self renderKind:kind style:style];
            cache[key] = image;
        }
        return image;
    }
}

#pragma mark Zeichnung

+ (UIImage *)renderKind:(BrowserCursorKind)kind style:(BrowserCursorStyle)style {
    BOOL light = style == BrowserCursorStyleMacLight;
    UIColor *black = [UIColor colorWithWhite:0.06 alpha:1];
    UIColor *white = UIColor.whiteColor;
    // Pfeil: Füllung dunkel (Mac) bzw. hell; Hand umgekehrt wie bei macOS.
    UIColor *arrowFill = light ? white : black, *arrowLine = light ? black : white;
    UIColor *handFill = light ? black : white, *handLine = light ? white : black;

    CGSize content = kind == BrowserCursorKindArrow ? CGSizeMake(14, 21.5) :
                     kind == BrowserCursorKindHand ? CGSizeMake(25, 38) : CGSizeMake(10, 22);
    CGSize size = CGSizeMake(content.width * kScale + kMarginX + kMargin + 6, content.height * kScale + 2 * kMargin);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 3.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

    if (style == BrowserCursorStyleSymbol) {
        return [self renderSymbolKind:kind size:size renderer:renderer];
    }
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextTranslateCTM(c, kMarginX, kMargin);
        CGContextScaleCTM(c, kScale, kScale);
        NSArray<UIBezierPath *> *shapes;
        UIColor *fill = arrowFill, *line = arrowLine;
        if (kind == BrowserCursorKindArrow) {
            shapes = @[[self arrowPath]];
        } else if (kind == BrowserCursorKindHand) {
            shapes = [self handShapes];
            fill = handFill; line = handLine;
        } else {
            shapes = [self ibeamShapes];
        }
        // Weicher Schatten einmal für die ganze Figur.
        CGContextSetShadowWithColor(c, CGSizeMake(0, 1.2 * kScale), 2.6 * kScale, [UIColor colorWithWhite:0 alpha:0.38].CGColor);
        CGContextBeginTransparencyLayer(c, NULL);
        [line setStroke];
        for (UIBezierPath *p in shapes) {
            p.lineWidth = kBorder * 2;
            p.lineJoinStyle = kCGLineJoinRound;
            p.lineCapStyle = kCGLineCapRound;
            [p stroke];
        }
        [fill setFill];
        for (UIBezierPath *p in shapes) { [p fill]; }
        CGContextEndTransparencyLayer(c);
        if (kind == BrowserCursorKindHand) {
            // Trennlinien der eingeklappten Finger.
            CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
            [line setStroke];
            UIBezierPath *lines = [UIBezierPath bezierPath];
            for (NSNumber *x in @[@9.2, @14.6, @20.0]) {
                [lines moveToPoint:CGPointMake(x.doubleValue, 24.0)];
                [lines addLineToPoint:CGPointMake(x.doubleValue, 31.0)];
            }
            lines.lineWidth = 0.8;
            lines.lineCapStyle = kCGLineCapRound;
            [lines stroke];
        }
    }];
}

/// Klassischer Pfeil, Spitze bei (0, 0).
+ (UIBezierPath *)arrowPath {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(0, 0)];
    [p addLineToPoint:CGPointMake(0, 17.2)];
    [p addLineToPoint:CGPointMake(4.1, 13.4)];
    [p addLineToPoint:CGPointMake(6.9, 20.0)];
    [p addLineToPoint:CGPointMake(9.7, 18.8)];
    [p addLineToPoint:CGPointMake(6.9, 12.4)];
    [p addLineToPoint:CGPointMake(12.4, 12.4)];
    [p closePath];
    return p;
}

/// Zeigefinger-Hand: Fingerspitze bei (0, 0).
+ (NSArray<UIBezierPath *> *)handShapes {
    CGRect rects[] = {
        {0, 0, 8.4, 25},         // Zeigefinger
        {-4.8, 19, 31, 18},      // Handrücken
        {8.2, 14.5, 7.6, 13},    // Finger 2
        {13.6, 15.8, 7.6, 13},   // Finger 3
        {19.0, 17.4, 7.6, 13},   // Finger 4
        {-7.4, 21, 8.6, 12},     // Daumen
    };
    NSMutableArray *out = [NSMutableArray new];
    for (size_t i = 0; i < sizeof(rects) / sizeof(rects[0]); i++) {
        CGRect r = rects[i];
        r.origin.x -= 4.2; // Fingerspitze (Mitte des Zeigefingers) liegt bei x = 0
        CGFloat radius = i == 1 ? 7 : MIN(r.size.width, r.size.height) / 2;
        [out addObject:[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius]];
    }
    return out;
}

/// Texteinfügemarke, Mitte oben bei (0, 0).
+ (NSArray<UIBezierPath *> *)ibeamShapes {
    return @[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(-0.9, 0, 1.8, 20) cornerRadius:0.9],
             [UIBezierPath bezierPathWithRoundedRect:CGRectMake(-3.6, 0, 7.2, 1.8) cornerRadius:0.9],
             [UIBezierPath bezierPathWithRoundedRect:CGRectMake(-3.6, 18.2, 7.2, 1.8) cornerRadius:0.9]];
}

#pragma mark SF Symbols

+ (UIImage *)renderSymbolKind:(BrowserCursorKind)kind size:(CGSize)size renderer:(UIGraphicsImageRenderer *)renderer {
    NSString *name = kind == BrowserCursorKindArrow ? @"cursorarrow" :
                     kind == BrowserCursorKindHand ? @"hand.point.up.left.fill" : @"character.cursor.ibeam";
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightSemibold];
    UIImage *symbol = [UIImage systemImageNamed:name withConfiguration:config];
    if (!symbol) { return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {}]; }
    UIImage *white = [symbol imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *black = [symbol imageWithTintColor:[UIColor colorWithWhite:0.06 alpha:1] renderingMode:UIImageRenderingModeAlwaysOriginal];
    // Spitze (oben links, kleinste Summe x + y der sichtbaren Bildpunkte) bestimmen.
    CGPoint tip = [self tipOfImage:symbol];
    CGPoint origin = CGPointMake(kMarginX - tip.x, kMargin - tip.y);
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetShadowWithColor(c, CGSizeMake(0, 2.4), 5, [UIColor colorWithWhite:0 alpha:0.38].CGColor);
        CGContextBeginTransparencyLayer(c, NULL);
        const int steps = 16;
        for (int i = 0; i < steps; i++) {
            CGFloat a = 2 * M_PI * i / steps;
            [black drawAtPoint:CGPointMake(origin.x + 1.8 * cos(a), origin.y + 1.8 * sin(a))];
        }
        [white drawAtPoint:origin];
        CGContextEndTransparencyLayer(c);
    }];
}

+ (CGPoint)tipOfImage:(UIImage *)image {
    CGSize size = image.size;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2.0;
    UIImage *flat = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[image imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawAtPoint:CGPointZero];
    }];
    CGImageRef cg = flat.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    NSMutableData *data = [NSMutableData dataWithLength:w * h];
    CGContextRef ctx = CGBitmapContextCreate(data.mutableBytes, w, h, 8, w, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    const uint8_t *bytes = data.bytes;
    size_t best = SIZE_MAX; CGPoint tip = CGPointZero;
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            // Bitmap-Kontext hat Ursprung unten links; y von oben zählen.
            if (bytes[(h - 1 - y) * w + x] > 128 && x + y < best) { best = x + y; tip = CGPointMake(x / 2.0, y / 2.0); }
        }
    }
    return tip;
}

@end

#pragma mark - Ansicht

@interface BrowserCursorImageView ()
@property (nonatomic, strong) UIImageView *innerView;
@property (nonatomic, strong, nullable) UIImage *shownImage;
@end

@implementation BrowserCursorImageView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = NO;
        _innerView = [[UIImageView alloc] init];
        _innerView.userInteractionEnabled = NO;
        [self addSubview:_innerView];
    }
    return self;
}

/// Das Bild wird nur im inneren Bild gezeichnet; die eigene Zeichnung der Ansicht bliebe sonst doppelt sichtbar
/// (`image` der Oberklasse bleibt absichtlich leer).
- (void)setImage:(UIImage *)image {
    self.shownImage = image;
    CGPoint hotspot = BrowserCursorRenderer.hotspot;
    self.innerView.image = image;
    self.innerView.frame = CGRectMake(-hotspot.x, -hotspot.y, image.size.width, image.size.height);
}

@end
