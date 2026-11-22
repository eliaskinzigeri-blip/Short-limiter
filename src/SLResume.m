// ShortLimiter : reprise des vidéos là où on s'était arrêté (vidéos classiques uniquement, pas les Shorts).
// La position est gardée sur l'iPhone, par vidéo, indépendamment de l'historique YouTube (qui peut être en pause).
// Quand on revient sur une vidéo, elle repart à cet endroit et un message s'affiche 3 secondes.
#import "SL.h"
#import <objc/message.h>

static NSString *const SLResumeKey = @"ShortLimiter.resume";        // id → { t, d, at }
static NSString *const SLResumeOnKey = @"ShortLimiter.resumeEnabled";

static NSMutableDictionary *gStore;
static BOOL gDirty;
static NSString *gVid;          // vidéo affichée
static double gPending = -1;    // position à rétablir pour gVid
static NSDate *gPendingUntil;
static NSDate *gLastSave;
static __weak UILabel *gToast;

BOOL SLResumeEnabled(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:SLResumeOnKey] ? [d boolForKey:SLResumeOnKey] : YES;
}

void SLResumeSetEnabled(BOOL on) {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:SLResumeOnKey];
}

static void SLResumeLoad(void) {
    if (gStore) return;
    NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:SLResumeKey];
    gStore = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

void SLResumeFlush(void) {
    if (!gDirty || !gStore) return;
    // 300 vidéos au plus : les plus anciennes partent
    if (gStore.count > 300) {
        NSArray *keys = [gStore keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"at"] compare:b[@"at"]];
        }];
        for (NSUInteger i = 0; i < keys.count - 300; i++) [gStore removeObjectForKey:keys[i]];
    }
    [NSUserDefaults.standardUserDefaults setObject:gStore forKey:SLResumeKey];
    gDirty = NO;
    gLastSave = NSDate.date;
}

static NSString *SLClock(double t) {
    long s = lround(t);
    return s >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, (s / 60) % 60, s % 60]
                     : [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

static void SLCollect(UIViewController *vc, NSMutableArray *out, int depth) {
    if (!vc || depth > 40) return;
    [out addObject:vc];
    for (UIViewController *c in vc.childViewControllers) SLCollect(c, out, depth + 1);
    if (vc.presentedViewController.presentingViewController == vc) SLCollect(vc.presentedViewController, out, depth + 1);
}

/// Lecteur des vidéos classiques affiché (le plus grand à l'écran).
static UIViewController *SLFindPlayer(void) {
    Class cls = NSClassFromString(@"YTPlayerViewController");
    if (!cls) return nil;
    UIViewController *best = nil;
    CGFloat bestArea = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden || [NSStringFromClass(w.class) hasPrefix:@"SL"]) continue;
            NSMutableArray *vcs = [NSMutableArray array];
            SLCollect(w.rootViewController, vcs, 0);
            for (UIViewController *vc in vcs) {
                if (![vc isKindOfClass:cls] || !vc.isViewLoaded || !vc.view.window) continue;
                CGRect r = [vc.view convertRect:vc.view.bounds toView:nil];
                CGFloat area = r.size.width * r.size.height;
                if (area > bestArea) { bestArea = area; best = vc; }
            }
        }
    }
    return best;
}

static double SLDouble(id o, SEL s) {
    if (![o respondsToSelector:s]) return -1;
    return ((double (*)(id, SEL))objc_msgSend)(o, s);
}

static BOOL SLPlayingAd(UIViewController *p) {
    for (NSString *name in @[@"isPlayingAd", @"playingAd", @"isAdPlaying"]) {
        SEL s = NSSelectorFromString(name);
        if ([p respondsToSelector:s] && ((BOOL (*)(id, SEL))objc_msgSend)(p, s)) return YES;
    }
    return NO;
}

/// Message en bas de la vidéo pendant 3 secondes, dans le style des messages de YouTube.
static void SLShowResumeToast(UIViewController *player, double t) {
    [gToast removeFromSuperview];
    UILabel *l = [UILabel new];
    l.text = [NSString stringWithFormat:@"  ↺  Retour là où vous vous êtes arrêté (%@)  ", SLClock(t)];
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
    l.layer.cornerRadius = 8;
    l.clipsToBounds = YES;
    l.textAlignment = NSTextAlignmentCenter;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.userInteractionEnabled = NO;
    UIView *host = player.view;
    [host addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:12],
        [l.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-36],
        [l.trailingAnchor constraintLessThanOrEqualToAnchor:host.trailingAnchor constant:-12],
        [l.heightAnchor constraintEqualToConstant:32],
    ]];
    gToast = l;
    l.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; } completion:^(BOOL f) { [l removeFromSuperview]; }];
    });
}

static BOOL SLSeek(UIViewController *p, double t) {
    for (NSString *name in @[@"seekToTime:", @"scrubToTime:"]) {
        SEL s = NSSelectorFromString(name);
        if (![p respondsToSelector:s]) continue;
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(p, s, (CGFloat)t);
        return YES;
    }
    return NO;
}

void SLResumeTick(BOOL onShorts) {
    if (!SLResumeEnabled()) return;
    SLResumeLoad();
    UIViewController *p = onShorts ? nil : SLFindPlayer();
    NSString *vid = nil;
    if (p && [p respondsToSelector:@selector(currentVideoID)]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(p, @selector(currentVideoID));
        if ([v isKindOfClass:NSString.class] && [v length]) vid = v;
    }
    if (!vid) {
        // Plus de vidéo à l'écran : la prochaine ouverture (même de la même vidéo) repartira de la position gardée
        if (gVid) { gVid = nil; gPending = -1; SLResumeFlush(); }
        return;
    }
    double t = SLDouble(p, NSSelectorFromString(@"currentVideoMediaTime"));
    double total = SLDouble(p, NSSelectorFromString(@"currentVideoTotalMediaTime"));
    BOOL ad = SLPlayingAd(p);

    if (![vid isEqualToString:gVid]) {
        gVid = vid;
        gPending = -1;
        NSDictionary *e = gStore[vid];
        double saved = [e[@"t"] doubleValue];
        if (saved >= 15) {
            gPending = saved;
            gPendingUntil = [NSDate dateWithTimeIntervalSinceNow:20]; // laisse le temps aux pubs et au chargement
        }
    }

    // Reprise : une fois la vidéo chargée (durée connue) et hors pub
    if (gPending >= 0) {
        if (gPendingUntil.timeIntervalSinceNow < 0) { gPending = -1; return; }
        if (ad || total <= 0) return;
        double target = gPending;
        gPending = -1;
        if (target >= total - 20) return;                 // déjà quasiment fini
        if (t >= target - 10) return;                     // YouTube a déjà repris au bon endroit
        if (SLSeek(p, target)) {
            [SLCore.shared log:[NSString stringWithFormat:@"Reprise : %@ à %@", vid, SLClock(target)]];
            SLShowResumeToast(p, target);
        } else {
            [SLCore.shared logOnce:@"noseek" text:@"Reprise : le lecteur ne permet pas d'aller à une position"];
        }
        return;
    }

    // Position actuelle mémorisée (sauf pendant une pub ou un direct)
    if (ad || t < 0 || total <= 0) return;
    if (t >= total - 20) {
        if (gStore[vid]) { [gStore removeObjectForKey:vid]; gDirty = YES; } // vidéo finie : on repartira du début
    } else if (t >= 15) {
        gStore[vid] = @{@"t": @(floor(t)), @"d": @(total), @"at": @(NSDate.date.timeIntervalSince1970)};
        gDirty = YES;
    }
    if (gDirty && (!gLastSave || -gLastSave.timeIntervalSinceNow > 5)) SLResumeFlush();
}
