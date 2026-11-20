// SoundMatch : affiche « Mes stats d'écoute » à partager, dans le style des affiches de Spotify
// (photo de l'artiste en rond, période en grand, minutes, top 5, pochette penchée, logo en bas).
#import "SMStats.h"

#pragma mark - Polices et couleurs

static UIFont *SMPosterTitleFont(CGFloat size) {
    static NSString *name;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Police « titre » de Spotify si l'app l'a (étroite et grasse, comme sur ses affiches)
        NSMutableArray *found = [NSMutableArray array];
        for (NSString *fam in UIFont.familyNames) {
            if (![fam.lowercaseString containsString:@"spotify"] && ![fam.lowercaseString containsString:@"circular"]) continue;
            [found addObjectsFromArray:[UIFont fontNamesForFamilyName:fam]];
        }
        if (found.count) SMLogPublic([@"Affiche : polices de Spotify " stringByAppendingString:[found componentsJoinedByString:@", "]]);
        for (NSString *weight in @[@"black", @"extrabold", @"heavy", @"bold"]) {
            for (NSString *f in found) {
                NSString *low = f.lowercaseString;
                if (([low containsString:@"title"] || [low containsString:@"condensed"] || [low containsString:@"display"]) && [low containsString:weight]) { name = f; return; }
            }
        }
    });
    UIFont *f = name ? [UIFont fontWithName:name size:size] : nil;
    if (f) return f;
    if (@available(iOS 16.0, *)) return [UIFont systemFontOfSize:size weight:UIFontWeightHeavy width:UIFontWidthCondensed];
    return [UIFont systemFontOfSize:size weight:UIFontWeightHeavy];
}

static UIFont *SMPosterBodyFont(CGFloat size, BOOL bold) {
    UIFont *f = [UIFont fontWithName:bold ? @"SpotifyMixUI-Bold" : @"SpotifyMixUI-Regular" size:size];
    return f ?: [UIFont systemFontOfSize:size weight:bold ? UIFontWeightBold : UIFontWeightMedium];
}

/// Couleur principale d'une image (les pixels colorés comptent plus que les gris).
static BOOL SMDominant(UIImage *img, CGFloat *r, CGFloat *g, CGFloat *b) {
    CGImageRef cg = img.CGImage;
    if (!cg) return NO;
    const int n = 16;
    unsigned char px[16 * 16 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, n, n, 8, n * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NO;
    CGContextDrawImage(ctx, CGRectMake(0, 0, n, n), cg);
    CGContextRelease(ctx);
    double sr = 0, sg = 0, sb = 0, sw = 0;
    for (int i = 0; i < n * n; i++) {
        double R = px[i * 4] / 255.0, G = px[i * 4 + 1] / 255.0, B = px[i * 4 + 2] / 255.0;
        double mx = fmax(R, fmax(G, B)), mn = fmin(R, fmin(G, B));
        double sat = mx > 0 ? (mx - mn) / mx : 0;
        double w = 0.15 + sat * sat * 3 * (mx > 0.12 ? 1 : 0.2);
        sr += R * w; sg += G * w; sb += B * w; sw += w;
    }
    if (sw <= 0) return NO;
    *r = sr / sw; *g = sg / sw; *b = sb / sw;
    return YES;
}

#pragma mark - Dessin

static void SMDrawFill(UIImage *img, CGRect target) {
    if (!img) return;
    CGSize s = img.size;
    CGFloat scale = MAX(target.size.width / MAX(1, s.width), target.size.height / MAX(1, s.height));
    CGSize d = CGSizeMake(s.width * scale, s.height * scale);
    [img drawInRect:CGRectMake(CGRectGetMidX(target) - d.width / 2, CGRectGetMidY(target) - d.height / 2, d.width, d.height)];
}

static void SMDrawLine(NSString *text, CGRect rect, UIFont *font, UIColor *color) {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    [text drawWithRect:rect options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: ps} context:nil];
}

static CGPoint SMPt(CGPoint o, CGFloat k, double px, double py) { return CGPointMake(o.x + px * k, o.y + py * k); }

/// Petit lecteur de tracés SVG (commandes M, C, c, z) : assez pour le logo.
static UIBezierPath *SMSVGPath(NSString *d, CGFloat scale, CGPoint origin) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    NSScanner *sc = [NSScanner scannerWithString:d];
    sc.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@" ,\n"];
    NSCharacterSet *cmds = [NSCharacterSet characterSetWithCharactersInString:@"MmCcLlZz"];
    unichar cmd = 'M';
    CGPoint cur = CGPointZero;
    while (!sc.isAtEnd) {
        NSString *c = nil;
        if ([sc scanCharactersFromSet:cmds intoString:&c] && c.length) cmd = [c characterAtIndex:c.length - 1];
        if (cmd == 'z' || cmd == 'Z') { [p closePath]; cmd = 'M'; continue; }
        int need = (cmd == 'C' || cmd == 'c') ? 6 : 2;
        double v[6];
        BOOL ok = YES;
        for (int i = 0; i < need && ok; i++) ok = [sc scanDouble:&v[i]];
        if (!ok) break;
        BOOL rel = cmd == 'c' || cmd == 'm' || cmd == 'l';
        if (rel) for (int i = 0; i < need; i++) v[i] += (i % 2 == 0) ? cur.x : cur.y;
        if (cmd == 'M' || cmd == 'm') {
            cur = CGPointMake(v[0], v[1]);
            [p moveToPoint:SMPt(origin, scale, cur.x, cur.y)];
            cmd = rel ? 'l' : 'L';
        } else if (cmd == 'L' || cmd == 'l') {
            cur = CGPointMake(v[0], v[1]);
            [p addLineToPoint:SMPt(origin, scale, cur.x, cur.y)];
        } else {
            [p addCurveToPoint:SMPt(origin, scale, v[4], v[5]) controlPoint1:SMPt(origin, scale, v[0], v[1]) controlPoint2:SMPt(origin, scale, v[2], v[3])];
            cur = CGPointMake(v[4], v[5]);
        }
    }
    return p;
}

/// Logo Spotify : rond plein et trois ondes, d'après le tracé de l'icône (carré de 168).
static void SMDrawLogo(CGPoint c, CGFloat R, UIColor *fg, UIColor *bg) {
    [fg setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - R, c.y - R, 2 * R, 2 * R)] fill];
    NSArray *waves = @[
        @"M133.7,74.4C106.8,58.4,62.3,56.9,36.6,64.7c-4.1,1.3-8.5-1.1-9.7-5.2c-1.3-4.1,1.1-8.5,5.2-9.7c29.6-9,78.7-7.2,109.7,11.2c3.7,2.2,4.9,7,2.7,10.7C142.3,75.4,137.4,76.6,133.7,74.4z",
        @"M132.9,98c-1.9,3.1-5.9,4-8.9,2.2c-22.5-13.8-56.8-17.8-83.4-9.8c-3.4,1-7.1-0.9-8.1-4.3c-1-3.4,0.9-7,4.3-8.1c30.4-9.2,68.2-4.8,94.1,11.1C133.8,90.9,134.8,94.9,132.9,98z",
        @"M122.8,120.8c-1.5,2.5-4.7,3.3-7.2,1.8c-19.7-12-44.4-14.7-73.6-8.1c-2.8,0.6-5.6-1.1-6.3-3.9c-0.6-2.8,1.1-5.6,3.9-6.3c31.9-7.3,59.3-4.2,81.3,9.3C123.5,115.2,124.3,118.4,122.8,120.8z",
    ];
    CGFloat scale = 2 * R / 168.0;
    [bg setFill];
    for (NSString *w in waves) [SMSVGPath(w, scale, CGPointMake(c.x - R, c.y - R)) fill];
}

static UIImage *SMRenderPoster(NSString *period, NSString *minutes, NSArray<NSString *> *artists, NSArray<NSString *> *tracks,
                               UIImage *artistImg, UIImage *trackImg) {
    const CGFloat W = 1080, H = 1920;
    // Fond : entre la couleur principale de la photo de l'artiste et celle de la pochette, assombrie
    CGFloat r1 = 0.35, g1 = 0.25, b1 = 0.25, r2, g2, b2;
    BOOL has1 = SMDominant(artistImg, &r1, &g1, &b1);
    BOOL has2 = SMDominant(trackImg, &r2, &g2, &b2);
    if (has2 && has1) { r1 = (r1 + r2) / 2; g1 = (g1 + g2) / 2; b1 = (b1 + b2) / 2; }
    else if (has2) { r1 = r2; g1 = g2; b1 = b2; }
    CGFloat h, s, v, a;
    [[UIColor colorWithRed:r1 green:g1 blue:b1 alpha:1] getHue:&h saturation:&s brightness:&v alpha:&a];
    UIColor *bg = [UIColor colorWithHue:h saturation:MIN(0.5, MAX(0.12, s * 0.7)) brightness:0.27 alpha:1];
    UIColor *fg = [UIColor colorWithHue:h saturation:0.07 brightness:0.97 alpha:1];

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(W, H) format:fmt];
    return [rd imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef ctx = rc.CGContext;
        [bg setFill];
        UIRectFill(CGRectMake(0, 0, W, H));

        // Photo de l'artiste en rond, qui dépasse à gauche
        CGRect circle = CGRectMake(-70, 150, 500, 500);
        CGContextSaveGState(ctx);
        [[UIBezierPath bezierPathWithOvalInRect:circle] addClip];
        if (artistImg) SMDrawFill(artistImg, circle);
        else { [[fg colorWithAlphaComponent:0.15] setFill]; UIRectFill(circle); }
        CGContextRestoreGState(ctx);

        // Top artistes à droite de la photo
        CGFloat x = 480, y = 175;
        SMDrawLine(@"Top Artistes", CGRectMake(x, y, W - x - 40, 90), SMPosterTitleFont(74), fg);
        y += 100;
        for (NSUInteger i = 0; i < MIN(5, artists.count); i++) {
            SMDrawLine([NSString stringWithFormat:@"%lu  %@", (unsigned long)i + 1, artists[i]], CGRectMake(x, y, W - x - 40, 70),
                       SMPosterBodyFont(50, i == 0), fg);
            y += 72;
        }

        // Période en très grand, puis les minutes
        SMDrawLine(period.uppercaseString, CGRectMake(56, 760, W - 100, 200), SMPosterTitleFont(170), fg);
        if (minutes.length) SMDrawLine(minutes, CGRectMake(56, 975, W - 100, 100), SMPosterTitleFont(80), fg);

        // Pochette du titre, penchée, qui dépasse à droite
        if (trackImg) {
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, 900, 1365);
            CGContextRotateCTM(ctx, 7 * M_PI / 180);
            CGContextSetShadowWithColor(ctx, CGSizeMake(0, 14), 30, [UIColor colorWithWhite:0 alpha:0.45].CGColor);
            CGRect cover = CGRectMake(-250, -250, 500, 500);
            [[UIColor blackColor] setFill];
            UIRectFill(cover);
            CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
            CGContextClipToRect(ctx, cover);
            SMDrawFill(trackImg, cover);
            CGContextRestoreGState(ctx);
        }

        // Top titres
        x = 56; y = 1140;
        SMDrawLine(@"Top Titres", CGRectMake(x, y, 560, 90), SMPosterTitleFont(74), fg);
        y += 100;
        for (NSUInteger i = 0; i < MIN(5, tracks.count); i++) {
            SMDrawLine([NSString stringWithFormat:@"%lu  %@", (unsigned long)i + 1, tracks[i]], CGRectMake(x, y, trackImg ? 560 : W - 110, 70),
                       SMPosterBodyFont(50, i == 0), fg);
            y += 72;
        }

        // Logo en bas à gauche, signature en bas à droite
        SMDrawLogo(CGPointMake(100, 1820), 42, fg, bg);
        NSString *sig = @"MES STATS D'ÉCOUTE";
        UIFont *sf = SMPosterTitleFont(50);
        CGSize ss = [sig sizeWithAttributes:@{NSFontAttributeName: sf}];
        SMDrawLine(sig, CGRectMake(W - 56 - ss.width, 1820 - ss.height / 2, ss.width + 4, ss.height + 4), sf, fg);
    }];
}

#pragma mark - Aperçu et partage

@interface SMPosterController : UIViewController
@property (nonatomic, strong) UIImage *poster;
@end

@implementation SMPosterController {
    UIImageView *_iv;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.12 alpha:1];
    _iv = [[UIImageView alloc] initWithImage:self.poster];
    _iv.translatesAutoresizingMaskIntoConstraints = NO;
    _iv.contentMode = UIViewContentModeScaleAspectFit;
    _iv.layer.cornerRadius = 22;
    _iv.clipsToBounds = YES;
    [self.view addSubview:_iv];

    UIButton *share = [UIButton buttonWithType:UIButtonTypeCustom];
    share.translatesAutoresizingMaskIntoConstraints = NO;
    [share setTitle:@"Partager" forState:UIControlStateNormal];
    [share setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    share.titleLabel.font = SMPosterBodyFont(17, YES);
    share.backgroundColor = [UIColor colorWithRed:0.118 green:0.843 blue:0.376 alpha:1];
    share.layer.cornerRadius = 25;
    [share addTarget:self action:@selector(share:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:share];

    UIView *grabber = [UIView new];
    grabber.translatesAutoresizingMaskIntoConstraints = NO;
    grabber.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
    grabber.layer.cornerRadius = 2.5;
    [self.view addSubview:grabber];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    CGFloat ratio = 1920.0 / 1080.0;
    NSLayoutConstraint *h = [_iv.heightAnchor constraintEqualToAnchor:_iv.widthAnchor multiplier:ratio];
    [NSLayoutConstraint activateConstraints:@[
        [grabber.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [grabber.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:40],
        [grabber.heightAnchor constraintEqualToConstant:5],
        [_iv.topAnchor constraintEqualToAnchor:safe.topAnchor constant:28],
        [_iv.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_iv.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor multiplier:0.62],
        [_iv.bottomAnchor constraintLessThanOrEqualToAnchor:share.topAnchor constant:-24],
        h,
        [share.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [share.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-20],
        [share.widthAnchor constraintEqualToConstant:200],
        [share.heightAnchor constraintEqualToConstant:50],
    ]];
}

- (void)share:(UIButton *)b {
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[self.poster] applicationActivities:nil];
    a.popoverPresentationController.sourceView = b;
    a.popoverPresentationController.sourceRect = b.bounds;
    [self presentViewController:a animated:YES completion:nil];
}
@end

static UIImage *SMLoadPosterImage(id src) {
    if (![src isKindOfClass:NSString.class] || ![src length]) return nil;
    NSString *s = src;
    if ([s hasPrefix:@"http"]) {
        NSData *d = [NSData dataWithContentsOfURL:[NSURL URLWithString:s]];
        return d ? [UIImage imageWithData:d] : nil;
    }
    return [UIImage imageWithContentsOfFile:s];
}

void SMPosterPresent(UIViewController *from, NSString *period, NSString *minutes, NSArray<NSString *> *artists,
                     NSArray<NSString *> *tracks, NSString *artistImage, NSString *trackImage) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *ai = SMLoadPosterImage(artistImage);
        UIImage *ti = SMLoadPosterImage(trackImage);
        dispatch_async(dispatch_get_main_queue(), ^{
            SMPosterController *vc = [SMPosterController new];
            vc.poster = SMRenderPoster(period ?: @"", minutes, artists ?: @[], tracks ?: @[], ai, ti);
            vc.modalPresentationStyle = UIModalPresentationPageSheet;
            [from presentViewController:vc animated:YES completion:nil];
        });
    });
}
