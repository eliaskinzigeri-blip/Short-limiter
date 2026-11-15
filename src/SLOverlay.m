#import "SL.h"

static UIColor *SLColor(unsigned rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

/// Bouton arrondi façon YouTube.
static UIButton *SLPillButton(NSString *title, UIColor *bg, UIColor *fg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 22;
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    return b;
}

/// Étiquette avec marges intérieures (pastille des statistiques).
@interface SLInsetLabel : UILabel
@end

@implementation SLInsetLabel
- (void)drawTextInRect:(CGRect)rect { [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(0, 14, 0, 14))]; }
- (CGSize)intrinsicContentSize {
    CGSize s = [super intrinsicContentSize];
    return CGSizeMake(s.width + 28, MAX(28, s.height + 10));
}
@end

/// Anneau du compte à rebours : la part rouge diminue jusqu'à la fin du blocage.
@interface SLRingView : UIView
@property (nonatomic) double progress;
@end

@implementation SLRingView {
    CAShapeLayer *_track, *_bar;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _track = [CAShapeLayer layer];
        _bar = [CAShapeLayer layer];
        for (CAShapeLayer *l in @[_track, _bar]) {
            l.fillColor = UIColor.clearColor.CGColor;
            l.lineWidth = 8;
            l.lineCap = kCALineCapRound;
            [self.layer addSublayer:l];
        }
        _track.strokeColor = SLColor(0x3F3F3F).CGColor;
        _bar.strokeColor = SLColor(0xFF0033).CGColor;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = MIN(self.bounds.size.width, self.bounds.size.height) / 2 - 6;
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:c radius:r startAngle:-M_PI_2 endAngle:3 * M_PI_2 clockwise:YES];
    _track.path = path.CGPath;
    _bar.path = path.CGPath;
}
- (void)setProgress:(double)progress {
    _progress = MAX(0, MIN(1, progress));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _bar.strokeEnd = _progress;
    [CATransaction commit];
}
@end

/// Fenêtre transparente au-dessus de l'app : seuls ses éléments visibles captent les touchers.
@interface SLOverlayWindow : UIWindow
@end

@implementation SLOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface SLRootController : UIViewController
@end

@implementation SLRootController
- (void)loadView {
    UIView *v = [UIView new];
    v.backgroundColor = UIColor.clearColor;
    self.view = v;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)prefersStatusBarHidden { return NO; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
@end

@implementation SLOverlay {
    SLOverlayWindow *_window;
    __weak UIWindow *_previousKey;
    UIButton *_pill;
    UIView *_panel;
    UILabel *_countdown;
    UILabel *_detail;
    UILabel *_stats;
    SLRingView *_ring;
    NSLayoutConstraint *_panelBottom;
    BOOL _settingsOpen;
    UILabel *_toast;
    NSDate *_toastUntil;
}

+ (instancetype)shared {
    static SLOverlay *o;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [SLOverlay new]; });
    return o;
}

- (BOOL)ensureWindow {
    UIWindowScene *scene = SLActiveScene();
    if (!scene) return NO;
    if (_window && _window.windowScene == scene) return YES;
    _window = [[SLOverlayWindow alloc] initWithWindowScene:scene];
    _window.windowLevel = UIWindowLevelAlert + 1;
    _window.backgroundColor = UIColor.clearColor;
    _window.rootViewController = [SLRootController new];
    [self buildViewsIn:_window.rootViewController.view];
    return YES;
}

- (void)buildViewsIn:(UIView *)root {
    // Compteur discret en haut de l'écran pendant les Shorts (toucher : réglages)
    _pill = [UIButton buttonWithType:UIButtonTypeSystem];
    _pill.translatesAutoresizingMaskIntoConstraints = NO;
    _pill.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _pill.layer.cornerRadius = 13;
    _pill.tintColor = UIColor.whiteColor;
    _pill.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    _pill.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    [_pill addTarget:self action:@selector(presentSettings) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_pill];

    // Écran de blocage, style sombre de YouTube : couvre l'écran jusqu'à la barre d'onglets du bas,
    // qui reste utilisable pour aller ailleurs dans YouTube
    _panel = [UIView new];
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    _panel.backgroundColor = SLColor(0x0F0F0F);
    [root addSubview:_panel];

    _ring = [SLRingView new];
    _ring.translatesAutoresizingMaskIntoConstraints = NO;
    [_ring.widthAnchor constraintEqualToConstant:196].active = YES;
    [_ring.heightAnchor constraintEqualToConstant:196].active = YES;

    UIImageView *glass = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hourglass"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]]];
    glass.tintColor = SLColor(0xAAAAAA);
    _countdown = [UILabel new];
    _countdown.font = [UIFont monospacedDigitSystemFontOfSize:42 weight:UIFontWeightBold];
    _countdown.textColor = UIColor.whiteColor;
    UILabel *left = [UILabel new];
    left.text = @"restantes";
    left.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    left.textColor = SLColor(0xAAAAAA);
    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:@[glass, _countdown, left]];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.alignment = UIStackViewAlignmentCenter;
    inner.spacing = 2;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [_ring addSubview:inner];
    [inner.centerXAnchor constraintEqualToAnchor:_ring.centerXAnchor].active = YES;
    [inner.centerYAnchor constraintEqualToAnchor:_ring.centerYAnchor].active = YES;

    UILabel *title = [UILabel new];
    title.text = @"Pause Shorts";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;

    _detail = [UILabel new];
    _detail.font = [UIFont systemFontOfSize:15];
    _detail.textColor = SLColor(0xAAAAAA);
    _detail.textAlignment = NSTextAlignmentCenter;
    _detail.numberOfLines = 0;

    _stats = [SLInsetLabel new];
    _stats.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _stats.textColor = UIColor.whiteColor;
    _stats.backgroundColor = SLColor(0x272727);
    _stats.layer.cornerRadius = 14;
    _stats.clipsToBounds = YES;
    _stats.textAlignment = NSTextAlignmentCenter;

    UIButton *home = SLPillButton(@"Retour à l'accueil", UIColor.whiteColor, SLColor(0x0F0F0F));
    [home addTarget:self action:@selector(goHome) forControlEvents:UIControlEventTouchUpInside];
    UIButton *settings = SLPillButton(@"Paramètres de Shorts Limiter", SLColor(0x272727), UIColor.whiteColor);
    [settings addTarget:self action:@selector(presentSettings) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_ring, title, _detail, _stats, home, settings]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:24 afterView:_ring];
    [stack setCustomSpacing:6 afterView:title];
    [stack setCustomSpacing:28 afterView:_stats];
    [_panel addSubview:stack];
    [home.widthAnchor constraintEqualToConstant:260].active = YES;
    [settings.widthAnchor constraintEqualToConstant:260].active = YES;
    [_detail.widthAnchor constraintLessThanOrEqualToConstant:320].active = YES;

    // Message bref (ex. confirmation au lancement)
    _toast = [UILabel new];
    _toast.translatesAutoresizingMaskIntoConstraints = NO;
    _toast.backgroundColor = [UIColor colorWithRed:0.30 green:0.16 blue:0.70 alpha:0.95];
    _toast.textColor = UIColor.whiteColor;
    _toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _toast.textAlignment = NSTextAlignmentCenter;
    _toast.numberOfLines = 0;
    _toast.layer.cornerRadius = 12;
    _toast.clipsToBounds = YES;
    _toast.hidden = YES;
    [root addSubview:_toast];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_pill.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [_pill.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_pill.heightAnchor constraintEqualToConstant:26],

        [_toast.topAnchor constraintEqualToAnchor:safe.topAnchor constant:40],
        [_toast.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_toast.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-40],
        [_toast.heightAnchor constraintGreaterThanOrEqualToConstant:40],

        [_panel.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_panel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_panel.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:_panel.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor constant:-24],
    ]];
    _panelBottom = [_panel.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-90];
    _panelBottom.active = YES;
}

- (void)goHome {
    [[SLCore shared] leaveShorts];
}

- (void)refresh {
    SLCore *c = SLCore.shared;
    BOOL block = c.onShorts && c.isBlocked && !_settingsOpen;
    BOOL pill = c.onShorts && !c.isBlocked && c.showCounter && !_settingsOpen;
    BOOL toast = _toastUntil && _toastUntil.timeIntervalSinceNow > 0 && !_settingsOpen;
    _toast.hidden = !toast;
    if (!block && !pill && !toast && !_settingsOpen) {
        _window.hidden = YES;
        return;
    }
    if (![self ensureWindow]) return;
    _panel.hidden = !block;
    _pill.hidden = !pill;
    if (pill) {
        NSString *t = [NSString stringWithFormat:@"⏳ %@ / %@", SLFormat(c.usedSeconds), SLFormat(c.limitMinutes * 60.0)];
        [UIView performWithoutAnimation:^{
            [self->_pill setTitle:t forState:UIControlStateNormal];
            [self->_pill layoutIfNeeded];
        }];
    }
    if (block) {
        _panelBottom.constant = -[c tabBarInset];
        _countdown.text = SLFormat(c.remainingBlock);
        _ring.progress = c.blockDuration > 0 ? c.remainingBlock / c.blockDuration : 0;
        _detail.text = [NSString stringWithFormat:@"Tu as atteint ta limite de %ld min de Shorts. Ils reviennent à la fin du compte à rebours ; le reste de YouTube reste disponible.",
                        (long)c.limitMinutes];
        long blocks = [c.today[@"blocks"] longValue];
        _stats.text = [NSString stringWithFormat:@"Aujourd'hui · %@ de Shorts · %ld pause%@",
                       SLFormat([c.today[@"seconds"] doubleValue]), blocks, blocks > 1 ? @"s" : @""];
    }
    _window.hidden = NO;
}

- (void)toast:(NSString *)text {
    if (![self ensureWindow]) return;
    _toast.text = [NSString stringWithFormat:@"   %@   ", text];
    _toastUntil = [NSDate dateWithTimeIntervalSinceNow:4];
    [self refresh];
}

- (void)presentSettings {
    if (_settingsOpen || ![self ensureWindow]) return;
    _settingsOpen = YES;
    for (UIWindow *w in SLActiveScene().windows) if (w.isKeyWindow) _previousKey = w;
    _panel.hidden = YES;
    _pill.hidden = YES;
    _window.hidden = NO;
    [_window makeKeyWindow]; // pour le clavier des champs de texte

    SLSettingsController *s = [[SLSettingsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    __weak typeof(self) weakSelf = self;
    s.onClose = ^{ [weakSelf settingsClosed]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark; // même thème que YouTube
    nav.presentationController.delegate = s; // fermeture par glissement
    [_window.rootViewController presentViewController:nav animated:YES completion:nil];
}

- (void)settingsClosed {
    _settingsOpen = NO;
    [_previousKey makeKeyWindow];
    [self refresh];
}

@end
