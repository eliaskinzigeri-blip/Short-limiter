#import "SL.h"

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

    // Écran de blocage : couvre tout sauf la barre d'onglets du bas, pour pouvoir aller ailleurs dans YouTube
    _panel = [UIView new];
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    _panel.backgroundColor = [UIColor colorWithRed:0.08 green:0.06 blue:0.20 alpha:0.97];
    [root addSubview:_panel];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hourglass"]];
    icon.tintColor = [UIColor colorWithRed:1 green:0.69 blue:0.25 alpha:1];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.heightAnchor constraintEqualToConstant:56].active = YES;

    UILabel *title = [UILabel new];
    title.text = @"Temps de Shorts écoulé";
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;

    _countdown = [UILabel new];
    _countdown.font = [UIFont monospacedDigitSystemFontOfSize:56 weight:UIFontWeightHeavy];
    _countdown.textColor = UIColor.whiteColor;
    _countdown.textAlignment = NSTextAlignmentCenter;

    _detail = [UILabel new];
    _detail.font = [UIFont systemFontOfSize:15];
    _detail.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    _detail.textAlignment = NSTextAlignmentCenter;
    _detail.numberOfLines = 0;

    UIButton *home = [UIButton buttonWithType:UIButtonTypeSystem];
    [home setTitle:@"Retour à l'accueil" forState:UIControlStateNormal];
    home.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    home.backgroundColor = UIColor.whiteColor;
    home.tintColor = [UIColor colorWithRed:0.08 green:0.06 blue:0.20 alpha:1];
    home.layer.cornerRadius = 12;
    [home.heightAnchor constraintEqualToConstant:50].active = YES;
    [home addTarget:self action:@selector(goHome) forControlEvents:UIControlEventTouchUpInside];

    UIButton *settings = [UIButton buttonWithType:UIButtonTypeSystem];
    [settings setTitle:@"Réglages et statistiques" forState:UIControlStateNormal];
    settings.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
    [settings addTarget:self action:@selector(presentSettings) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, _countdown, _detail, home, settings]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:28 afterView:_detail];
    [_panel addSubview:stack];

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
        [_panel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-56],

        [stack.centerYAnchor constraintEqualToAnchor:_panel.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor constant:-32],
    ]];
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
        _countdown.text = SLFormat(c.remainingBlock);
        _detail.text = [NSString stringWithFormat:@"Les Shorts sont bloqués encore %@.\nAujourd'hui : %@ de Shorts.\nLe reste de YouTube reste disponible.",
                        SLFormat(c.remainingBlock), SLFormat([c.today[@"seconds"] doubleValue])];
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
    nav.presentationController.delegate = s; // fermeture par glissement
    [_window.rootViewController presentViewController:nav animated:YES completion:nil];
}

- (void)settingsClosed {
    _settingsOpen = NO;
    [_previousKey makeKeyWindow];
    [self refresh];
}

@end
