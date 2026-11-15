// StreamBoost : tweak (.dylib) pour l'app Twitch, chargé par LiveContainer dans l'app que l'utilisateur installe lui-même.
// - Appui long sur une vidéo à la demande (VOD, clip) : lecture accélérée (×2 par défaut) tant que le doigt reste posé.
// - En direct, si on a du retard sur le direct (10 s par défaut) : bouton « Revenir au direct ».
// Aucun code de Twitch ici : le tweak repère les lecteurs vidéo à l'exécution (AVPlayer d'Apple, IVSPlayer d'Amazon IVS)
// uniquement par le runtime Objective-C, et vérifie chaque méthode avant de l'appeler.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#ifndef SB_VERSION
#define SB_VERSION "dev"
#endif

#define SBKey(x) (@"StreamBoost." x)

#pragma mark Journal

static NSString *SBLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"StreamBoost-journal.txt"];
}

static void SBLog(NSString *line) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd HH:mm:ss"; });
    NSString *text = [NSString stringWithFormat:@"%@  %@\n", [f stringFromDate:NSDate.date], line];
    NSString *path = SBLogPath();
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([[fm attributesOfItemAtPath:path error:nil] fileSize] > 300 * 1024) [fm removeItemAtPath:path error:nil];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    [h seekToEndOfFile];
    [h writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static NSMutableSet *SBSeen;
static void SBLogOnce(NSString *key, NSString *line) {
    if (!SBSeen) SBSeen = [NSMutableSet set];
    if ([SBSeen containsObject:key]) return;
    [SBSeen addObject:key];
    SBLog(line);
}

#pragma mark Réglages

static float SBSpeed(void) {
    float v = [NSUserDefaults.standardUserDefaults floatForKey:SBKey("speed")];
    return v > 0 ? v : 2.0f;
}
static double SBThreshold(void) {
    double v = [NSUserDefaults.standardUserDefaults doubleForKey:SBKey("threshold")];
    return v > 0 ? v : 10.0;
}

#pragma mark Lecteurs (AVPlayer et IVSPlayer)

static Class SBIVS(void) { return NSClassFromString(@"IVSPlayer"); }

static BOOL SBIsPlayer(id p) {
    if (!p) return NO;
    if ([p isKindOfClass:AVPlayer.class]) return YES;
    Class ivs = SBIVS();
    return ivs && [p isKindOfClass:ivs];
}

static CMTime SBTime(id p, SEL sel) {
    if (![p respondsToSelector:sel]) return kCMTimeInvalid;
    return ((CMTime (*)(id, SEL))objc_msgSend)(p, sel);
}

static CMTime SBDuration(id p) {
    if ([p isKindOfClass:AVPlayer.class]) {
        AVPlayerItem *item = ((AVPlayer *)p).currentItem;
        return item ? item.duration : kCMTimeInvalid;
    }
    return SBTime(p, @selector(duration));
}

/// Direct : durée indéfinie. VOD / clip : durée finie.
static BOOL SBIsLive(id p) {
    CMTime d = SBDuration(p);
    return CMTIME_IS_INDEFINITE(d);
}
static BOOL SBIsVOD(id p) {
    CMTime d = SBDuration(p);
    return CMTIME_IS_NUMERIC(d) && CMTimeGetSeconds(d) > 1;
}

static float SBRate(id p) {
    if ([p isKindOfClass:AVPlayer.class]) return ((AVPlayer *)p).rate;
    if ([p respondsToSelector:@selector(playbackRate)]) return ((float (*)(id, SEL))objc_msgSend)(p, @selector(playbackRate));
    return 0;
}

static BOOL SBIsPlaying(id p) {
    if ([p isKindOfClass:AVPlayer.class]) return ((AVPlayer *)p).rate > 0 || ((AVPlayer *)p).timeControlStatus == AVPlayerTimeControlStatusPlaying;
    if ([p respondsToSelector:@selector(state)]) {
        NSInteger st = ((NSInteger (*)(id, SEL))objc_msgSend)(p, @selector(state));
        return st == 2 || st == 3; // IVSPlayerStateBuffering, IVSPlayerStatePlaying
    }
    return NO;
}

static void SBSetRate(id p, float rate) {
    if ([p isKindOfClass:AVPlayer.class]) {
        AVPlayer *av = p;
        if (av.currentItem && !av.currentItem.canPlayFastForward && rate > 1) SBLogOnce(@"noff", @"AVPlayer : l'élément n'annonce pas l'avance rapide (essai quand même)");
        av.rate = rate;
    } else if ([p respondsToSelector:@selector(setPlaybackRate:)]) {
        ((void (*)(id, SEL, float))objc_msgSend)(p, @selector(setPlaybackRate:), rate);
    }
}

/// Retard sur le direct, en secondes (-1 si inconnu).
static double SBLatency(id p) {
    if ([p isKindOfClass:AVPlayer.class]) {
        AVPlayerItem *item = ((AVPlayer *)p).currentItem;
        NSValue *range = item.seekableTimeRanges.lastObject;
        if (!range) return -1;
        CMTime end = CMTimeRangeGetEnd(range.CMTimeRangeValue);
        CMTime now = item.currentTime;
        if (!CMTIME_IS_NUMERIC(end) || !CMTIME_IS_NUMERIC(now)) return -1;
        return CMTimeGetSeconds(CMTimeSubtract(end, now));
    }
    CMTime lat = SBTime(p, @selector(liveLatency));
    return CMTIME_IS_NUMERIC(lat) ? CMTimeGetSeconds(lat) : -1;
}

static void SBJumpToLive(id p) {
    if ([p isKindOfClass:AVPlayer.class]) {
        AVPlayer *av = p;
        NSValue *range = av.currentItem.seekableTimeRanges.lastObject;
        if (!range) return;
        CMTime end = CMTimeSubtract(CMTimeRangeGetEnd(range.CMTimeRangeValue), CMTimeMakeWithSeconds(1, 600));
        SBLog(@"Direct : saut au bord du direct (AVPlayer)");
        [av seekToTime:end toleranceBefore:CMTimeMakeWithSeconds(1, 600) toleranceAfter:kCMTimeZero completionHandler:^(BOOL done) {
            [av play];
        }];
        return;
    }
    // IVS : pas de retour en arrière sur un direct ; recharger le flux repart du direct
    if ([p respondsToSelector:@selector(path)] && [p respondsToSelector:@selector(load:)]) {
        NSURL *url = ((NSURL * (*)(id, SEL))objc_msgSend)(p, @selector(path));
        if (url) {
            SBLog(@"Direct : rechargement du flux (IVSPlayer)");
            ((void (*)(id, SEL, id))objc_msgSend)(p, @selector(load:), url);
            if ([p respondsToSelector:@selector(play)]) ((void (*)(id, SEL))objc_msgSend)(p, @selector(play));
        }
    }
}

#pragma mark Suivi des lecteurs (méthode play)

static NSHashTable *SBPlayers;
static __weak id SBLastPlayer;

static void SBTrack(id p) {
    if (!SBIsPlayer(p)) return;
    if (!SBPlayers) SBPlayers = [NSHashTable weakObjectsHashTable];
    [SBPlayers addObject:p];
    SBLastPlayer = p;
    SBLogOnce([@"player-" stringByAppendingString:NSStringFromClass([p class])],
              [NSString stringWithFormat:@"Lecteur repéré : %@", NSStringFromClass([p class])]);
}

static void SBHookPlay(Class c) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, @selector(play));
    if (!m) return;
    void (*orig)(id, SEL) = (void *)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self) {
        orig(self, @selector(play));
        dispatch_async(dispatch_get_main_queue(), ^{ SBTrack(self); });
    }));
}

/// Lecteur affiché sous un point de l'écran : vue / calque qui expose `player` (AVPlayerLayer, IVSPlayerView, …).
static id SBPlayerInLayer(CALayer *layer, int depth) {
    if (!layer || depth > 4) return nil;
    if ([layer respondsToSelector:@selector(player)]) {
        id p = ((id (*)(id, SEL))objc_msgSend)(layer, @selector(player));
        if (SBIsPlayer(p)) return p;
    }
    for (CALayer *sub in layer.sublayers) {
        id p = SBPlayerInLayer(sub, depth + 1);
        if (p) return p;
    }
    return nil;
}

static id SBPlayerInView(UIView *v, int depth) {
    if (!v || depth > 6) return nil;
    if ([v respondsToSelector:@selector(player)]) {
        id p = ((id (*)(id, SEL))objc_msgSend)(v, @selector(player));
        if (SBIsPlayer(p)) return p;
    }
    id p = SBPlayerInLayer(v.layer, 0);
    if (p) return p;
    for (UIView *sub in v.subviews) {
        p = SBPlayerInView(sub, depth + 1);
        if (p) return p;
    }
    return nil;
}

/// Lecteur sous le doigt : on remonte depuis la vue touchée tant qu'elle reste à peu près de la taille de la vidéo.
static id SBPlayerAtPoint(UIWindow *w, CGPoint pt, NSString **chain) {
    UIView *hit = [w hitTest:pt withEvent:nil];
    NSMutableArray *names = [NSMutableArray array];
    for (UIView *v = hit; v && v != w; v = v.superview) {
        [names addObject:NSStringFromClass(v.class)];
        NSString *low = NSStringFromClass(v.class).lowercaseString;
        if ([low containsString:@"chat"] || [low containsString:@"comment"]) break; // jamais dans le chat
        id p = SBPlayerInView(v, 0);
        if (p) {
            if (chain) *chain = [names componentsJoinedByString:@" < "];
            return p;
        }
        if (v.bounds.size.height > w.bounds.size.height * 0.95 && v.bounds.size.width > w.bounds.size.width * 0.95) break;
    }
    if (chain) *chain = [names componentsJoinedByString:@" < "];
    return nil;
}

#pragma mark Fenêtre par-dessus l'app

@interface SBWindow : UIWindow
@end

@implementation SBWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface SBRoot : UIViewController
@end

@implementation SBRoot
- (void)loadView { self.view = [UIView new]; self.view.backgroundColor = UIColor.clearColor; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

@interface SBCore : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SBCore {
    SBWindow *_window;
    UILabel *_speedPill;
    UIButton *_liveButton;
    __weak id _boosted;   // lecteur accéléré par l'appui long en cours
    float _savedRate;
    __weak id _livePlayer;
    NSTimer *_timer;
}

+ (instancetype)shared {
    static SBCore *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [SBCore new]; });
    return c;
}

static UIWindowScene *SBScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!fallback) fallback = (UIWindowScene *)s;
    }
    return fallback;
}

- (NSArray<UIWindow *> *)appWindows {
    NSMutableArray *out = [NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (!w.hidden && ![w isKindOfClass:SBWindow.class]) [out addObject:w];
        }
    }
    return out;
}

- (BOOL)ensureWindow {
    UIWindowScene *scene = SBScene();
    if (!scene) return NO;
    if (_window && _window.windowScene == scene) return YES;
    _window = [[SBWindow alloc] initWithWindowScene:scene];
    _window.windowLevel = UIWindowLevelAlert + 1;
    _window.backgroundColor = UIColor.clearColor;
    _window.rootViewController = [SBRoot new];
    UIView *root = _window.rootViewController.view;

    _speedPill = [UILabel new];
    _speedPill.translatesAutoresizingMaskIntoConstraints = NO;
    _speedPill.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _speedPill.textColor = UIColor.whiteColor;
    _speedPill.textAlignment = NSTextAlignmentCenter;
    _speedPill.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    _speedPill.layer.cornerRadius = 16;
    _speedPill.clipsToBounds = YES;
    _speedPill.hidden = YES;
    [root addSubview:_speedPill];

    _liveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _liveButton.translatesAutoresizingMaskIntoConstraints = NO;
    _liveButton.backgroundColor = [UIColor colorWithRed:0.57 green:0.27 blue:1.0 alpha:0.95]; // violet
    _liveButton.tintColor = UIColor.whiteColor;
    _liveButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    _liveButton.layer.cornerRadius = 17;
    _liveButton.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    _liveButton.hidden = YES;
    [_liveButton addTarget:self action:@selector(goLive) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_liveButton];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_speedPill.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [_speedPill.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_speedPill.widthAnchor constraintEqualToConstant:96],
        [_speedPill.heightAnchor constraintEqualToConstant:32],
        [_liveButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:52],
        [_liveButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_liveButton.heightAnchor constraintEqualToConstant:34],
    ]];
    return YES;
}

- (void)start {
    if (_timer) return;
    SBLog([NSString stringWithFormat:@"StreamBoost %s chargé dans %@ (%@)", SB_VERSION, NSBundle.mainBundle.bundleIdentifier,
           [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]]);
    _timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)installGestures {
    for (UIWindow *w in [self appWindows]) {
        BOOL has = NO;
        for (UIGestureRecognizer *g in w.gestureRecognizers) if (g.delegate == self) { has = YES; break; }
        if (has) continue;
        UILongPressGestureRecognizer *boost = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(boost:)];
        boost.minimumPressDuration = 0.45;
        boost.allowableMovement = 30;
        boost.cancelsTouchesInView = NO;
        boost.delaysTouchesBegan = NO;
        boost.delegate = self;
        [w addGestureRecognizer:boost];
        UILongPressGestureRecognizer *settings = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(settings:)];
        settings.numberOfTouchesRequired = 3;
        settings.minimumPressDuration = 0.8;
        settings.cancelsTouchesInView = NO;
        settings.delegate = self;
        [w addGestureRecognizer:settings];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

#pragma mark Appui long : accélération des VOD

- (void)boost:(UILongPressGestureRecognizer *)g {
    UIWindow *w = (UIWindow *)g.view;
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            NSString *chain = nil;
            id p = SBPlayerAtPoint(w, [g locationInView:w], &chain);
            SBLogOnce([@"chain-" stringByAppendingString:chain ?: @""], [NSString stringWithFormat:@"Appui long sur : %@ → %@", chain,
                                                                        p ? NSStringFromClass([p class]) : @"aucun lecteur"]);
            if (!p || !SBIsVOD(p) || !SBIsPlaying(p)) return;
            _savedRate = SBRate(p) > 0 ? SBRate(p) : 1;
            _boosted = p;
            SBSetRate(p, SBSpeed());
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
            [self refresh];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            id p = _boosted;
            if (p) SBSetRate(p, _savedRate);
            _boosted = nil;
            [self refresh];
            break;
        }
        default: break;
    }
}

#pragma mark Bouton « Revenir au direct »

- (void)goLive {
    id p = _livePlayer;
    if (p) SBJumpToLive(p);
    _liveButton.hidden = YES;
}

- (void)tick {
    BOOL active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    [self installGestures];

    // L'app peut remettre la vitesse normale pendant l'appui : on la réimpose
    id b = _boosted;
    if (b && SBIsPlaying(b) && fabsf(SBRate(b) - SBSpeed()) > 0.01) SBSetRate(b, SBSpeed());

    // Lecteur en direct qui joue, avec le plus de retard
    id best = nil;
    double bestLatency = -1;
    if (active) {
        for (id p in SBPlayers.allObjects) {
            if (!SBIsLive(p) || !SBIsPlaying(p)) continue;
            double lat = SBLatency(p);
            if (lat > bestLatency) { best = p; bestLatency = lat; }
        }
    }
    _livePlayer = best;
    if (best && bestLatency >= SBThreshold())
        SBLogOnce(@"late", [NSString stringWithFormat:@"Retard sur le direct détecté : %.0f s (%@)", bestLatency, NSStringFromClass([best class])]);
    [self refreshWithLatency:best ? bestLatency : -1];
}

- (void)refresh { [self refreshWithLatency:-1]; }

- (void)refreshWithLatency:(double)latency {
    BOOL speed = _boosted != nil;
    BOOL live = latency >= SBThreshold();
    if (!speed && !live) {
        if (_window) {
            _speedPill.hidden = YES;
            _liveButton.hidden = YES;
            _window.hidden = YES;
        }
        return;
    }
    if (![self ensureWindow]) return;
    _speedPill.hidden = !speed;
    if (speed) _speedPill.text = [NSString stringWithFormat:@"%g× ▶▶", SBSpeed()];
    _liveButton.hidden = !live;
    if (live) {
        [UIView performWithoutAnimation:^{
            [self->_liveButton setTitle:[NSString stringWithFormat:@"⏩ Revenir au direct (−%.0f s)", latency] forState:UIControlStateNormal];
            [self->_liveButton layoutIfNeeded];
        }];
    }
    _window.hidden = NO;
}

#pragma mark Réglages (appui long à trois doigts)

- (UIViewController *)topController {
    for (UIWindow *w in [self appWindows]) {
        if (!w.isKeyWindow) continue;
        UIViewController *vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        return vc;
    }
    return [self appWindows].firstObject.rootViewController;
}

- (void)settings:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIViewController *top = [self topController];
    if (!top || [top isKindOfClass:UIAlertController.class]) return;
    NSString *msg = [NSString stringWithFormat:@"Appui long sur une vidéo : ×%g\nBouton direct à partir de %.0f s de retard\nVersion %s",
                     SBSpeed(), SBThreshold(), SB_VERSION];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"StreamBoost" message:msg preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *s in @[@1.5, @2, @3]) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Vitesse de l'appui long : ×%g%@", s.floatValue, fabsf(s.floatValue - SBSpeed()) < 0.01 ? @" ✓" : @""]
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [NSUserDefaults.standardUserDefaults setFloat:s.floatValue forKey:SBKey("speed")];
        }]];
    }
    for (NSNumber *t in @[@5, @10, @20, @30]) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Bouton direct dès %@ s de retard%@", t, fabs(t.doubleValue - SBThreshold()) < 0.5 ? @" ✓" : @""]
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [NSUserDefaults.standardUserDefaults setDouble:t.doubleValue forKey:SBKey("threshold")];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Partager le journal" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSURL *url = [NSURL fileURLWithPath:SBLogPath()];
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView = top.view;
        share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        [top presentViewController:share animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Fermer" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = top.view;
    a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
    [top presentViewController:a animated:YES completion:nil];
}

@end

__attribute__((constructor)) static void SBInit(void) {
    SBHookPlay(AVPlayer.class);
    SBHookPlay(SBIVS());
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!SBIVS()) SBLog(@"IVSPlayer absent au chargement");
        [[SBCore shared] start];
    });
}
