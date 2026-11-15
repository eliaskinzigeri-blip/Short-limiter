// StreamBoost : tweak (.dylib) pour l'app Twitch, chargé par LiveContainer dans l'app que l'utilisateur installe lui-même.
// - Appui long sur une vidéo à la demande (VOD, clip) : lecture accélérée (×2 par défaut) tant que le doigt reste posé.
// - Double appui à gauche / à droite de la vidéo : −10 s / +10 s (aussi en direct, dans ce que le flux garde).
// - Le double appui sur la vidéo est intercepté avant Twitch (plus de chat par double appui) : le chat s'ouvre
//   avec le bouton « Chat ».
// - En direct, si on a du retard sur le direct (10 s par défaut) : bouton « Revenir au direct ».
// Aucun code de Twitch ici : le tweak repère les lecteurs vidéo à l'exécution (AVPlayer d'Apple, IVSPlayer d'Amazon IVS)
// uniquement par le runtime Objective-C, et vérifie chaque méthode avant de l'appeler.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "SBDVR.h"

#ifndef SB_VERSION
#define SB_VERSION "dev"
#endif

#define SBKey(x) (@"StreamBoost." x)

#pragma mark Journal

static NSString *SBLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"StreamBoost-journal.txt"];
}

void SBLog(NSString *line) {
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

static double SBStep(void) {
    double v = [NSUserDefaults.standardUserDefaults doubleForKey:SBKey("step")];
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

/// Recule (delta < 0) ou avance dans la vidéo, dans les limites de ce que le lecteur garde.
/// Retourne le décalage réellement appliqué (0 si impossible).
static double SBSeekBy(id p, double delta) {
    if ([p isKindOfClass:AVPlayer.class]) {
        AVPlayer *av = p;
        AVPlayerItem *item = av.currentItem;
        if (!item) return 0;
        double now = CMTimeGetSeconds(item.currentTime);
        double lo = 0, hi = now + fabs(delta);
        NSValue *first = item.seekableTimeRanges.firstObject, *last = item.seekableTimeRanges.lastObject;
        if (first && last) {
            lo = CMTimeGetSeconds(first.CMTimeRangeValue.start);
            hi = CMTimeGetSeconds(CMTimeRangeGetEnd(last.CMTimeRangeValue));
        } else if (SBIsVOD(p)) {
            hi = CMTimeGetSeconds(SBDuration(p));
        } else {
            return 0;
        }
        double target = MAX(lo, MIN(hi - 0.5, now + delta));
        if (fabs(target - now) < 0.5) return 0;
        [av seekToTime:CMTimeMakeWithSeconds(target, 600) toleranceBefore:CMTimeMakeWithSeconds(0.3, 600)
        toleranceAfter:CMTimeMakeWithSeconds(0.3, 600) completionHandler:nil];
        return target - now;
    }
    // IVS : recherche possible sur les vidéos à la demande seulement
    if (!SBIsVOD(p) || ![p respondsToSelector:@selector(seekTo:)]) return 0;
    double now = CMTimeGetSeconds(SBTime(p, @selector(position)));
    double dur = CMTimeGetSeconds(SBDuration(p));
    if (isnan(now)) return 0;
    double target = MAX(0, MIN(dur - 0.5, now + delta));
    ((void (*)(id, SEL, CMTime))objc_msgSend)(p, @selector(seekTo:), CMTimeMakeWithSeconds(target, 600));
    return target - now;
}

/// Recul / avance possibles : VOD, ou direct d'un lecteur Apple qui garde une partie du flux (IVS : jamais en direct).
static BOOL SBCanSeek(id p) {
    if (SBIsVOD(p)) return YES;
    if ([p isKindOfClass:AVPlayer.class]) {
        NSValue *first = ((AVPlayer *)p).currentItem.seekableTimeRanges.firstObject;
        NSValue *last = ((AVPlayer *)p).currentItem.seekableTimeRanges.lastObject;
        if (!first || !last) return NO;
        return CMTimeGetSeconds(CMTimeRangeGetEnd(last.CMTimeRangeValue)) - CMTimeGetSeconds(first.CMTimeRangeValue.start) > 5;
    }
    return NO;
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
static id SBPlayerAtPoint(UIWindow *w, CGPoint pt, NSString **chain, UIView **videoView) {
    UIView *hit = [w hitTest:pt withEvent:nil];
    NSMutableArray *names = [NSMutableArray array];
    for (UIView *v = hit; v && v != w; v = v.superview) {
        [names addObject:NSStringFromClass(v.class)];
        NSString *low = NSStringFromClass(v.class).lowercaseString;
        if ([low containsString:@"chat"] || [low containsString:@"comment"]) break; // jamais dans le chat
        id p = SBPlayerInView(v, 0);
        if (p) {
            if (chain) *chain = [names componentsJoinedByString:@" < "];
            if (videoView) *videoView = v;
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
+ (instancetype)shared;
- (BOOL)shouldSwallow:(UITouch *)t window:(UIWindow *)w;
- (void)swallowedTapEnded:(UITouch *)t window:(UIWindow *)w;
@end

@implementation SBCore {
    SBWindow *_window;
    UILabel *_speedPill;
    UIButton *_liveButton;
    __weak id _boosted;   // lecteur accéléré par l'appui long en cours
    float _savedRate;
    __weak id _livePlayer;
    NSTimer *_timer;
    UILabel *_seekLabel;
    NSLayoutConstraint *_seekX, *_seekY;
    NSDate *_seekUntil;
    double _seekTotal;    // cumul des doubles appuis rapprochés (−10, −20, …)
    NSDate *_lastSeek;
    double _lastLatency;
    NSHashTable *_appDoubleTaps; // doubles appuis de Twitch sur la vidéo (chat par-dessus)
    UIButton *_chatButton;
    NSDate *_lastScan;
    BOOL _probeFired;
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

    _seekLabel = [UILabel new];
    _seekLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _seekLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    _seekLabel.textColor = UIColor.whiteColor;
    _seekLabel.textAlignment = NSTextAlignmentCenter;
    _seekLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    _seekLabel.layer.cornerRadius = 22;
    _seekLabel.clipsToBounds = YES;
    _seekLabel.hidden = YES;
    [root addSubview:_seekLabel];
    _seekX = [_seekLabel.centerXAnchor constraintEqualToAnchor:root.leadingAnchor constant:100];
    _seekY = [_seekLabel.centerYAnchor constraintEqualToAnchor:root.topAnchor constant:200];

    _chatButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _chatButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_chatButton setTitle:@"💬 Chat" forState:UIControlStateNormal];
    _chatButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    _chatButton.tintColor = UIColor.whiteColor;
    _chatButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    _chatButton.layer.cornerRadius = 17;
    _chatButton.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    _chatButton.hidden = YES;
    [_chatButton addTarget:self action:@selector(toggleChat) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_chatButton];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_chatButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:52],
        [_chatButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_chatButton.heightAnchor constraintEqualToConstant:34],
        _seekX, _seekY,
        [_seekLabel.widthAnchor constraintEqualToConstant:120],
        [_seekLabel.heightAnchor constraintEqualToConstant:44],
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

/// Côté de la vidéo touché : -1 gauche, +1 droite, 0 milieu.
static int SBSide(CGPoint pt, UIView *video) {
    CGRect r = [video convertRect:video.bounds toView:nil];
    double x = (pt.x - CGRectGetMinX(r)) / MAX(1, r.size.width);
    if (x <= 0.38) return -1;
    if (x >= 0.62) return 1;
    return 0;
}

#pragma mark Interception du double appui (avant Twitch)

/// Deuxième toucher d'un double appui sur la vidéo : il n'est pas transmis à l'app (aucun geste de Twitch ne se
/// déclenche, donc pas de chat par-dessus) et le tweak le traite lui-même. Les boutons de Twitch restent normaux.
- (BOOL)shouldSwallow:(UITouch *)t window:(UIWindow *)w {
    CGPoint pt = [t locationInView:w];
    UIView *hit = [w hitTest:pt withEvent:nil];
    for (UIView *v = hit; v && v != w; v = v.superview) {
        if ([v isKindOfClass:UIControl.class] && ![NSStringFromClass(v.class).lowercaseString containsString:@"player"]) return NO;
    }
    UIView *video = nil;
    id p = SBPlayerAtPoint(w, pt, NULL, &video);
    if (!p || !video) return NO;
    [self linkAppDoubleTapsFrom:hit]; // gestes de Twitch sous le doigt, pour le bouton Chat
    return YES;
}

- (void)swallowedTapEnded:(UITouch *)t window:(UIWindow *)w {
    CGPoint pt = [t locationInView:w];
    UIView *video = nil;
    id p = SBPlayerAtPoint(w, pt, NULL, &video);
    if (!p || !video) return;
    int side = SBSide(pt, video);
    SBLogOnce(@"swallow", @"Double appui intercepté avant Twitch (le chat ne s'ouvre plus par double appui)");
    if (side != 0) [self seekSide:side player:p video:video];
}

#pragma mark Double appui de Twitch (chat par-dessus la vidéo)

- (BOOL)isOurs:(UIGestureRecognizer *)g {
    return g.delegate == (id)self;
}

/// Geste à plusieurs touchers de Twitch posé sur la vidéo : mémorisé pour le bouton « Chat ».
- (void)linkAppDoubleTap:(UITapGestureRecognizer *)t {
    if (!_appDoubleTaps) _appDoubleTaps = [NSHashTable weakObjectsHashTable];
    if ([_appDoubleTaps containsObject:t]) return;
    [_appDoubleTaps addObject:t];
    SBLogOnce([@"dt-" stringByAppendingString:NSStringFromClass(t.view.class)],
              [NSString stringWithFormat:@"Double appui de l'app repéré sur %@", NSStringFromClass(t.view.class)]);
}

- (void)linkAppDoubleTapsFrom:(UIView *)hit {
    for (UIView *v = hit; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if ([g isKindOfClass:UITapGestureRecognizer.class] && ((UITapGestureRecognizer *)g).numberOfTapsRequired >= 2 && ![self isOurs:g])
                [self linkAppDoubleTap:(UITapGestureRecognizer *)g];
        }
    }
}

/// Recherche régulière des doubles appuis posés sur une vidéo (pour qu'ils soient liés avant le premier appui).
- (void)scanView:(UIView *)v window:(UIWindow *)w depth:(int)depth {
    if (depth > 60 || v.hidden) return;
    for (UIGestureRecognizer *g in v.gestureRecognizers) {
        if (![g isKindOfClass:UITapGestureRecognizer.class] || ((UITapGestureRecognizer *)g).numberOfTapsRequired < 2 || [self isOurs:g]) continue;
        if ([_appDoubleTaps containsObject:g]) continue;
        if (v.bounds.size.width >= w.bounds.size.width * 0.4 && SBPlayerInView(v, 0)) [self linkAppDoubleTap:(UITapGestureRecognizer *)g];
    }
    for (UIView *sub in v.subviews) [self scanView:sub window:w depth:depth + 1];
}

- (UITapGestureRecognizer *)visibleAppDoubleTap {
    UITapGestureRecognizer *best = nil;
    CGFloat bestArea = 0;
    for (UITapGestureRecognizer *t in _appDoubleTaps.allObjects) {
        UIView *v = t.view;
        if (!v.window || v.window.hidden) continue;
        BOOL hidden = NO;
        for (UIView *p = v; p; p = p.superview) if (p.hidden || p.alpha < 0.01) { hidden = YES; break; }
        if (hidden) continue;
        CGFloat area = v.bounds.size.width * v.bounds.size.height;
        if (area > bestArea) { best = t; bestArea = area; }
    }
    return best;
}

- (void)probe:(UIGestureRecognizer *)g { _probeFired = YES; }

/// Bouton « Chat » : déclenche le double appui de Twitch, comme si on avait tapé deux fois au milieu de la vidéo.
- (void)toggleChat {
    UITapGestureRecognizer *t = [self visibleAppDoubleTap];
    if (!t) { SBLog(@"Chat : aucun double appui de l'app trouvé"); return; }
    _probeFired = NO;
    [t addTarget:self action:@selector(probe:)];
    @try { t.state = UIGestureRecognizerStateEnded; } @catch (NSException *e) {}
    [t removeTarget:self action:@selector(probe:)];
    if (_probeFired) {
        SBLog([NSString stringWithFormat:@"Chat : double appui de %@ déclenché", NSStringFromClass(t.view.class)]);
    } else {
        // Appel direct des cibles du geste
        NSArray *targets = nil;
        @try { targets = [t valueForKey:@"_targets"]; } @catch (NSException *e) {}
        int called = 0;
        for (id entry in targets) {
            id target = nil;
            @try { target = [entry valueForKey:@"_target"]; } @catch (NSException *e) {}
            Ivar ai = class_getInstanceVariable([entry class], "_action");
            if (!target || !ai || target == self) continue;
            SEL action = *(SEL *)((uint8_t *)(__bridge void *)entry + ivar_getOffset(ai));
            if (!action || ![target respondsToSelector:action]) continue;
            ((void (*)(id, SEL, id))objc_msgSend)(target, action, t);
            called++;
        }
        SBLog([NSString stringWithFormat:@"Chat : %d cible(s) du double appui appelée(s) directement", called]);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { if (t.state != UIGestureRecognizerStatePossible) [t reset]; } @catch (NSException *e) {}
    });
}

#pragma mark Appui long : accélération des VOD

- (void)boost:(UILongPressGestureRecognizer *)g {
    UIWindow *w = (UIWindow *)g.view;
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            NSString *chain = nil;
            id p = SBPlayerAtPoint(w, [g locationInView:w], &chain, NULL);
            SBLogOnce([@"chain-" stringByAppendingString:chain ?: @""], [NSString stringWithFormat:@"Appui long sur : %@ → %@", chain,
                                                                        p ? NSStringFromClass([p class]) : @"aucun lecteur"]);
            if (!p) return;
            if (!SBIsVOD(p) || !SBIsPlaying(p)) {
                SBLog([NSString stringWithFormat:@"Appui long : pas d'accélération (%@)", !SBIsVOD(p) ? @"direct" : @"vidéo en pause"]);
                return;
            }
            _savedRate = SBRate(p) > 0 ? SBRate(p) : 1;
            _boosted = p;
            SBSetRate(p, SBSpeed());
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SBLog([NSString stringWithFormat:@"Appui long : vitesse demandée ×%g, vitesse du lecteur ×%g (%@)", SBSpeed(), SBRate(p),
                       NSStringFromClass([p class])]);
            });
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

#pragma mark Double appui sur les côtés : reculer / avancer

- (void)seekSide:(int)side player:(id)p video:(UIView *)video {
    CGRect r = [video convertRect:video.bounds toView:nil];
    double sign = side;
    BOOL viaMemory = !SBCanSeek(p) && SBIsLive(p);
    double applied = viaMemory ? [SBDVR.shared seekBy:sign * SBStep() inView:video] : SBSeekBy(p, sign * SBStep());
    BOOL chained = _lastSeek && -_lastSeek.timeIntervalSinceNow < 1.2 && (_seekTotal * sign) > 0;
    _seekTotal = (chained ? _seekTotal : 0) + applied;
    _lastSeek = NSDate.date;
    SBLog([NSString stringWithFormat:@"Double appui %@ : %+.0f s demandé, %+.1f s appliqué (%@, %@)", sign < 0 ? @"gauche" : @"droite",
           sign * SBStep(), applied, SBIsLive(p) ? @"direct" : @"vidéo", NSStringFromClass([p class])]);
    if (![self ensureWindow]) return;
    if (viaMemory && !SBDVR.shared.replaying && sign > 0 && fabs(applied) >= 0.5) {
        _seekLabel.text = @"En direct";
    } else if (fabs(applied) < 0.5) {
        _seekLabel.text = sign < 0 ? @"Début atteint" : @"Déjà au direct";
        if (sign < 0 && SBIsLive(p)) _seekLabel.text = viaMemory ? @"Mémoire vide" : @"Retour impossible";
    } else {
        _seekLabel.text = sign < 0 ? [NSString stringWithFormat:@"⏪ %.0f s", _seekTotal] : [NSString stringWithFormat:@"+%.0f s ⏩", _seekTotal];
    }
    _seekX.constant = CGRectGetMinX(r) + r.size.width * (sign < 0 ? 0.2 : 0.8);
    _seekY.constant = CGRectGetMidY(r);
    _seekUntil = [NSDate dateWithTimeIntervalSinceNow:0.9];
    [self refreshWithLatency:_lastLatency];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshWithLatency:self->_lastLatency];
    });
}

#pragma mark Bouton « Revenir au direct »

- (void)goLive {
    if (SBDVR.shared.replaying) {
        SBLog(@"Relecture : retour au direct (bouton)");
        [SBDVR.shared stopReplay];
    } else {
        id p = _livePlayer;
        if (p) SBJumpToLive(p);
    }
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
    _lastLatency = best ? bestLatency : -1;

    // Mémoire de la dernière minute du direct (lecteur IVS)
    Class ivs = SBIVS();
    [SBDVR.shared watchPlayer:(best && ivs && [best isKindOfClass:ivs]) ? best : nil];
    if (SBDVR.shared.replaying) _lastLatency = SBDVR.shared.behindLive;

    // Doubles appuis de Twitch sur la vidéo : recherche toutes les 2 s pendant une lecture
    BOOL playing = NO;
    for (id p in SBPlayers.allObjects) if (SBIsPlaying(p)) { playing = YES; break; }
    if (active && playing && (!_lastScan || -_lastScan.timeIntervalSinceNow > 2)) {
        _lastScan = NSDate.date;
        for (UIWindow *w in [self appWindows]) [self scanView:w window:w depth:0];
    }
    if (best && bestLatency >= SBThreshold())
        SBLogOnce(@"late", [NSString stringWithFormat:@"Retard sur le direct détecté : %.0f s (%@)", bestLatency, NSStringFromClass([best class])]);
    [self refreshWithLatency:_lastLatency];
}

- (void)refresh { [self refreshWithLatency:_lastLatency]; }

/// Bouton Chat : pendant une lecture en plein écran (paysage), quand le double appui de Twitch est connu.
- (BOOL)chatVisible {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIWindowScene *scene = SBScene();
    if (!scene || !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) return NO;
    BOOL playing = NO;
    for (id p in SBPlayers.allObjects) if (SBIsPlaying(p)) { playing = YES; break; }
    return playing && [self visibleAppDoubleTap] != nil;
}

- (void)refreshWithLatency:(double)latency {
    BOOL speed = _boosted != nil;
    BOOL chat = [self chatVisible];
    BOOL live = latency >= SBThreshold();
    BOOL seek = _seekUntil && _seekUntil.timeIntervalSinceNow > 0;
    _seekLabel.hidden = !seek;
    _chatButton.hidden = !chat;
    if (!speed && !live && !seek && !chat) {
        if (_window) {
            _speedPill.hidden = YES;
            _liveButton.hidden = YES;
            _seekLabel.hidden = YES;
            _chatButton.hidden = YES;
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
    NSString *msg = [NSString stringWithFormat:@"Appui long sur une vidéo : ×%g\nDouble appui à gauche / à droite : −/+%.0f s\nBouton direct à partir de %.0f s de retard\nVersion %s",
                     SBSpeed(), SBStep(), SBThreshold(), SB_VERSION];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"StreamBoost" message:msg preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *s in @[@1.5, @2, @3]) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Vitesse de l'appui long : ×%g%@", s.floatValue, fabsf(s.floatValue - SBSpeed()) < 0.01 ? @" ✓" : @""]
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [NSUserDefaults.standardUserDefaults setFloat:s.floatValue forKey:SBKey("speed")];
        }]];
    }
    for (NSNumber *st in @[@5, @10, @15, @30]) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Double appui : %@ s%@", st, fabs(st.doubleValue - SBStep()) < 0.5 ? @" ✓" : @""]
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [NSUserDefaults.standardUserDefaults setDouble:st.doubleValue forKey:SBKey("step")];
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

static NSHashTable *SBSwallowed;

static void SBHookSendEvent(void) {
    Method m = class_getInstanceMethod(UIWindow.class, @selector(sendEvent:));
    if (!m) return;
    SBSwallowed = [NSHashTable weakObjectsHashTable];
    void (*orig)(id, SEL, UIEvent *) = (void *)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(UIWindow *w, UIEvent *e) {
        if (e.type == UIEventTypeTouches && ![w isKindOfClass:SBWindow.class]) {
            NSSet<UITouch *> *touches = e.allTouches;
            if (touches.count == 1) {
                UITouch *t = touches.anyObject;
                if (t.phase == UITouchPhaseBegan && t.tapCount >= 2 && [SBCore.shared shouldSwallow:t window:w])
                    [SBSwallowed addObject:t];
                if ([SBSwallowed containsObject:t]) {
                    if (t.phase == UITouchPhaseEnded) [SBCore.shared swallowedTapEnded:t window:w];
                    if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) [SBSwallowed removeObject:t];
                    return; // pas transmis à l'app
                }
            }
        }
        orig(w, @selector(sendEvent:), e);
    }));
}

__attribute__((constructor)) static void SBInit(void) {
    SBHookSendEvent();
    SBHookPlay(AVPlayer.class);
    SBHookPlay(SBIVS());
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!SBIVS()) SBLog(@"IVSPlayer absent au chargement");
        [[SBCore shared] start];
    });
}
