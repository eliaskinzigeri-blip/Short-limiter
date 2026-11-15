// PiP à l'écran noir (son mais pas d'image) : YouTube rend la vidéo par un calque à images (« sample buffer »),
// qui peut rester noir en PiP dans certains environnements comme LiveContainer. Le mode compatibilité demande à
// YouTube le rendu vidéo classique d'Apple (renderViewType = 2), qui s'affiche en PiP. Même principe que l'option
// « compatibilité » du tweak open source YouPiP. Rien n'est débloqué : le PiP doit déjà démarrer.
#import "SL.h"
#import <objc/runtime.h>

static NSString *const SLPiPKey = @"ShortLimiter.pipCompat";

BOOL SLPiPCompatEnabled(void) {
    // Désactivé : le rendu 2 (Metal) empêche le PiP d'Apple (« possible : non » dans le journal). Code gardé pour essais.
    return NO;
}

void SLSetPiPCompatEnabled(BOOL on) {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:SLPiPKey];
    [SLCore.shared log:[NSString stringWithFormat:@"PiP : mode compatibilité %@ (relancer YouTube)", on ? @"activé" : @"désactivé"]];
}

static void SLHookRenderViewType(NSString *className) {
    Class c = NSClassFromString(className);
    if (!c) { [SLCore.shared log:[NSString stringWithFormat:@"PiP : classe %@ absente", className]]; return; }
    // Les messages protobuf créent leurs accesseurs à la demande : class_getInstanceMethod les fait apparaître
    Method m = class_getInstanceMethod(c, @selector(renderViewType));
    if (!m) { [SLCore.shared log:[NSString stringWithFormat:@"PiP : %@ sans renderViewType", className]]; return; }
    int (*orig)(id, SEL) = (void *)method_getImplementation(m);
    __block BOOL logged = NO;
    method_setImplementation(m, imp_implementationWithBlock(^int(id self) {
        int value = orig(self, @selector(renderViewType));
        if (!SLPiPCompatEnabled()) return value;
        if (!logged) {
            logged = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [SLCore.shared log:[NSString stringWithFormat:@"PiP : rendu %d → 2 (%@)", value, className]];
            });
        }
        return 2;
    }));
}

void SLInstallPiPCompat(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    SLHookRenderViewType(@"YTIHamplayerConfig");
    SLHookRenderViewType(@"YTIHamplayerHotConfig");
}

#pragma mark Bouton PiP (LiveContainer ne déclenche pas le PiP automatique en quittant l'app)

#import <AVKit/AVKit.h>
#import <objc/message.h>

static id SLKVC(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static BOOL SLBool(id obj, SEL sel) {
    return obj && [obj respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

static UIViewController *SLFindPlayerVC(UIViewController *vc, int depth) {
    if (!vc || depth > 50) return nil;
    if (vc.isViewLoaded && vc.view.window && [NSStringFromClass(vc.class) isEqualToString:@"YTPlayerViewController"]) {
        BOOL hidden = NO;
        for (UIView *p = vc.view; p; p = p.superview) if (p.hidden || p.alpha < 0.01) { hidden = YES; break; }
        CGRect r = [vc.view convertRect:vc.view.bounds toView:nil];
        if (!hidden && r.size.width >= vc.view.window.bounds.size.width * 0.5 && r.size.height >= 120) return vc;
    }
    for (UIViewController *c in vc.childViewControllers) {
        UIViewController *f = SLFindPlayerVC(c, depth + 1);
        if (f) return f;
    }
    if (vc.presentedViewController.presentingViewController == vc) return SLFindPlayerVC(vc.presentedViewController, depth + 1);
    return nil;
}

/// Lecteur vidéo de YouTube affiché (page de la vidéo), sinon nil.
UIViewController *SLVisiblePlayerVC(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden || [NSStringFromClass(w.class) hasPrefix:@"SL"]) continue;
            UIViewController *f = SLFindPlayerVC(w.rootViewController, 0);
            if (f) return f;
        }
    }
    return nil;
}

void SLPiPRemember(UIView *renderView, AVPictureInPictureController *av);

static id SLPiPControllerOf(UIViewController *playerVC) {
    return SLKVC(SLKVC(playerVC, @"_playbackController"), @"_playerPIPController");
}

static AVPictureInPictureController *SLAVPiP(id controller) {
    id av = SLKVC(SLKVC(controller, @"_pipController"), @"_pictureInPictureController");
    return [av isKindOfClass:AVPictureInPictureController.class] ? av : nil;
}

/// YouTube autorise-t-il le PiP sur ce compte ? (réponses de YouTube lui-même, rien n'est forcé)
BOOL SLPiPAllowed(UIViewController *playerVC) {
    id controller = SLPiPControllerOf(playerVC);
    if (!controller) { [SLCore.shared logOnce:@"pip-noctl" text:@"PiP : contrôleur PiP de YouTube introuvable"]; return NO; }
    id policy = SLKVC(controller, @"_backgroundabilityPolicy");
    BOOL byPolicy = SLBool(policy, @selector(isPlayableInPictureInPictureByUserSettings));
    BOOL can = SLBool(controller, @selector(canEnablePictureInPicture)) || SLBool(controller, @selector(canInvokePictureInPicture));
    if (!byPolicy || !can) {
        [SLCore.shared logOnce:@"pip-denied" text:[NSString stringWithFormat:@"PiP : refusé par YouTube (politique %@, possible %@) — en France le PiP demande Premium",
                                                   byPolicy ? @"oui" : @"non", can ? @"oui" : @"non"]];
        return NO;
    }
    return !SLAVPiP(controller).pictureInPictureActive;
}

/// Lance le PiP de YouTube (comme le fait l'app en quittant l'écran), seulement s'il est autorisé.
void SLStartPiP(UIViewController *playerVC) {
    if (!SLPiPAllowed(playerVC)) return;
    id controller = SLPiPControllerOf(playerVC);
    if ([controller respondsToSelector:@selector(maybeEnablePictureInPicture)])
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(maybeEnablePictureInPicture));
    else if ([controller respondsToSelector:@selector(maybeInvokePictureInPicture)])
        ((void (*)(id, SEL))objc_msgSend)(controller, @selector(maybeInvokePictureInPicture));
    AVPictureInPictureController *av = SLAVPiP(controller);
    if (av.pictureInPicturePossible && !av.pictureInPictureActive) [av startPictureInPicture];
    UIView *render = SLKVC(SLKVC(controller, @"_pipController"), @"HAMPlayerView");
    SLPiPRemember(render, av);
    [SLCore.shared log:[NSString stringWithFormat:@"PiP : demandé (contrôleur Apple %@, possible %@, rendu %@)", av ? @"trouvé" : @"absent",
                        av.pictureInPicturePossible ? @"oui" : @"non", render ? NSStringFromClass(render.class) : @"?"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [SLCore.shared log:[NSString stringWithFormat:@"PiP : %@", av.pictureInPictureActive ? @"actif" : @"pas démarré"]];
    });
}

#pragma mark PiP noir : calque vidéo en échec en arrière-plan

static __weak UIView *SLPiPRenderView;   // vue de rendu donnée au PiP (MLHAMSBDLSampleBufferRenderingView)
static __weak AVPictureInPictureController *SLPiPAV;

static AVSampleBufferDisplayLayer *SLFindSBDL(CALayer *layer, int depth) {
    if (!layer || depth > 6) return nil;
    if ([layer isKindOfClass:AVSampleBufferDisplayLayer.class]) return (AVSampleBufferDisplayLayer *)layer;
    for (CALayer *sub in layer.sublayers) {
        AVSampleBufferDisplayLayer *f = SLFindSBDL(sub, depth + 1);
        if (f) return f;
    }
    return nil;
}

void SLPiPRemember(UIView *renderView, AVPictureInPictureController *av) {
    SLPiPRenderView = renderView;
    SLPiPAV = av;
}

/// Appelé chaque seconde (même en arrière-plan) : si le calque du PiP est en échec, on le remet à zéro pour que
/// YouTube puisse de nouveau y envoyer des images.
void SLPiPWatchdog(void) {
    AVPictureInPictureController *av = SLPiPAV;
    if (!av.pictureInPictureActive) return;
    AVSampleBufferDisplayLayer *l = SLFindSBDL(SLPiPRenderView.layer, 0);
    if (!l) { [SLCore.shared logOnce:@"pip-nolayer" text:@"PiP : calque vidéo introuvable"]; return; }
    // Relevé détaillé toutes les 5 s pendant le PiP (premier plan comme arrière-plan)
    static NSDate *lastReport;
    if (!lastReport || -lastReport.timeIntervalSinceNow >= 5) {
        lastReport = NSDate.date;
        NSString *same = @"?";
        if (@available(iOS 15.0, *)) {
            AVSampleBufferDisplayLayer *pipLayer = av.contentSource.sampleBufferDisplayLayer;
            same = pipLayer ? (pipLayer == l ? @"oui" : [NSString stringWithFormat:@"non (%@)", NSStringFromClass(pipLayer.superlayer.delegate.class)]) : @"pas de calque (lecteur Apple)";
        }
        UIApplicationState st = UIApplication.sharedApplication.applicationState;
        double rate = l.controlTimebase ? CMTimebaseGetRate(l.controlTimebase) : -1;
        [SLCore.shared log:[NSString stringWithFormat:@"PiP relevé : app %@, calque état %ld%@, prêt %@, vitesse %.1f, calque du PiP = calque vidéo : %@",
                            st == UIApplicationStateActive ? @"active" : (st == UIApplicationStateBackground ? @"arrière-plan" : @"inactive"),
                            (long)l.status, l.error ? [NSString stringWithFormat:@" (erreur %ld)", (long)l.error.code] : @"",
                            l.isReadyForMoreMediaData ? @"oui" : @"non", rate, same]];
    }
    BOOL failed = l.status == AVQueuedSampleBufferRenderingStatusFailed;
    BOOL needsFlush = [l respondsToSelector:@selector(requiresFlushToResumeDecoding)] && l.requiresFlushToResumeDecoding;
    BOOL background = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    [SLCore.shared logOnce:[NSString stringWithFormat:@"pip-layer-%d-%d-%d", failed, needsFlush, background]
                      text:[NSString stringWithFormat:@"PiP : calque %@, état %ld%@%@", background ? @"(arrière-plan)" : @"(premier plan)",
                            (long)l.status, l.error ? [NSString stringWithFormat:@", erreur %ld", (long)l.error.code] : @"",
                            needsFlush ? @", à remettre à zéro" : @""]];
    if (failed || needsFlush) {
        [l flush];
        [SLCore.shared log:@"PiP : calque remis à zéro"];
    }
}

/// Réglages internes de YouTube que YouPiP force aussi (corrections du comportement du PiP, pas d'accès au PiP).
void SLInstallPiPFixes(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    Class c = NSClassFromString(@"YTHotConfig");
    for (NSString *name in @[@"iosPlayerClientSharedConfigSkipPipToggleOnStateChange",
                             @"iosPlayerClientSharedConfigOffsetPipControllerTimeRangeWithSbdlCurrentTime"]) {
        Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(name)) : NULL;
        if (!m) continue;
        method_setImplementation(m, imp_implementationWithBlock(^BOOL(id self) { return NO; }));
    }
}
