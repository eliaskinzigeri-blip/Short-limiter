// PiP à l'écran noir (son mais pas d'image) : YouTube rend la vidéo par un calque à images (« sample buffer »),
// qui peut rester noir en PiP dans certains environnements comme LiveContainer. Le mode compatibilité demande à
// YouTube le rendu vidéo classique d'Apple (renderViewType = 2), qui s'affiche en PiP. Même principe que l'option
// « compatibilité » du tweak open source YouPiP. Rien n'est débloqué : le PiP doit déjà démarrer.
#import "SL.h"
#import <objc/runtime.h>

static NSString *const SLPiPKey = @"ShortLimiter.pipCompat";

BOOL SLPiPCompatEnabled(void) {
    NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:SLPiPKey];
    return v ? v.boolValue : YES;
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
