// SoundMatch : couleur de l'app au choix à la place du vert de Spotify.
// Les couleurs créées par l'app (boutons, lecture en cours, barres, icônes teintées…) qui sont le vert de Spotify
// sont remplacées au moment où elles sont créées par la couleur choisie, en gardant leurs nuances (plus clair,
// plus foncé, transparence). Les images déjà vertes (fichiers de l'app) ne changent pas.
#import "SMStats.h"
#import <objc/runtime.h>

static BOOL gAccentOn;
static CGFloat gAH, gAS, gAB; // couleur choisie (teinte, saturation, luminosité)

static NSString *const SMAccentKey = @"SoundMatch.accent";

/// Vert de Spotify (#1ED760, #1DB954 et leurs variantes) ?
static BOOL SMIsSpotifyGreen(CGFloat r, CGFloat g, CGFloat b, CGFloat *outB) {
    CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
    if (mx < 0.35 || g < mx - 0.0001) return NO; // le vert doit dominer
    CGFloat sat = mx > 0 ? (mx - mn) / mx : 0;
    if (sat < 0.55) return NO;
    // teinte en degrés
    CGFloat d = mx - mn, h;
    if (d <= 0) return NO;
    h = 60 * ((b - r) / d + 2);
    if (h < 125 || h > 155) return NO;
    *outB = mx;
    return YES;
}

static void SMReplace(CGFloat *r, CGFloat *g, CGFloat *b) {
    CGFloat bright;
    if (!gAccentOn || !SMIsSpotifyGreen(*r, *g, *b, &bright)) return;
    // Même nuance relative : un vert plus foncé donne une couleur choisie plus foncée
    CGFloat v = MIN(1, gAB * (bright / 0.843));
    // Teinte / saturation / luminosité → rouge, vert, bleu, calculé à la main (aucun appel à UIColor ici,
    // sinon la création de couleur repasserait par ce remplacement)
    CGFloat h6 = gAH * 6, f = h6 - floor(h6), p = v * (1 - gAS), q = v * (1 - gAS * f), t = v * (1 - gAS * (1 - f));
    switch (((int)floor(h6)) % 6) {
        case 0: *r = v; *g = t; *b = p; break;
        case 1: *r = q; *g = v; *b = p; break;
        case 2: *r = p; *g = v; *b = t; break;
        case 3: *r = p; *g = q; *b = v; break;
        case 4: *r = t; *g = p; *b = v; break;
        default: *r = v; *g = p; *b = q; break;
    }
}

static void SMHookColors(void) {
    // +colorWithRed:green:blue:alpha:
    Method cm = class_getClassMethod(UIColor.class, @selector(colorWithRed:green:blue:alpha:));
    if (cm) {
        UIColor *(*orig)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat) = (void *)method_getImplementation(cm);
        method_setImplementation(cm, imp_implementationWithBlock(^UIColor *(id cls, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
            SMReplace(&r, &g, &b);
            return orig(cls, @selector(colorWithRed:green:blue:alpha:), r, g, b, a);
        }));
    }
    // -initWithRed:green:blue:alpha: (UIColor(red:green:blue:alpha:) en Swift)
    Method im = class_getInstanceMethod(UIColor.class, @selector(initWithRed:green:blue:alpha:));
    if (im) {
        UIColor *(*orig)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat) = (void *)method_getImplementation(im);
        method_setImplementation(im, imp_implementationWithBlock(^UIColor *(id me, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
            SMReplace(&r, &g, &b);
            return orig(me, @selector(initWithRed:green:blue:alpha:), r, g, b, a);
        }));
    }
    // Display P3
    Method pm = class_getInstanceMethod(UIColor.class, @selector(initWithDisplayP3Red:green:blue:alpha:));
    if (pm) {
        UIColor *(*orig)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat) = (void *)method_getImplementation(pm);
        method_setImplementation(pm, imp_implementationWithBlock(^UIColor *(id me, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
            SMReplace(&r, &g, &b);
            return orig(me, @selector(initWithDisplayP3Red:green:blue:alpha:), r, g, b, a);
        }));
    }
}

void SMAccentInstall(void) {
    NSArray *c = [NSUserDefaults.standardUserDefaults arrayForKey:SMAccentKey];
    if (c.count == 3) {
        // Conversion en teinte / saturation / luminosité faite ici à la main (avant tout remplacement)
        CGFloat r = [c[0] doubleValue], g = [c[1] doubleValue], b = [c[2] doubleValue];
        CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b)), d = mx - mn, h = 0;
        if (d > 0) {
            if (mx == r) h = fmod((g - b) / d, 6);
            else if (mx == g) h = (b - r) / d + 2;
            else h = (r - g) / d + 4;
            h /= 6;
            if (h < 0) h += 1;
        }
        gAH = h;
        gAS = mx > 0 ? d / mx : 0;
        gAB = mx;
        gAccentOn = YES;
    }
    SMHookColors(); // toujours posé : une couleur choisie plus tard s'applique au prochain lancement
}

#pragma mark - Choix de la couleur

@interface SMAccentPicker : NSObject <UIColorPickerViewControllerDelegate>
@property (nonatomic, weak) UIViewController *from;
@property (nonatomic, strong) UIColor *picked;
@end

static SMAccentPicker *gPicker;

@implementation SMAccentPicker
- (void)colorPickerViewController:(UIColorPickerViewController *)vc didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    self.picked = color;
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc {
    UIColor *c = self.picked;
    if (!c) { gPicker = nil; return; }
    CGFloat r, g, b, a;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { gPicker = nil; return; }
    r = MIN(1, MAX(0, r)); g = MIN(1, MAX(0, g)); b = MIN(1, MAX(0, b));
    [NSUserDefaults.standardUserDefaults setObject:@[@(r), @(g), @(b)] forKey:SMAccentKey];
    SMLogPublic([NSString stringWithFormat:@"Couleur de l'app : %.2f %.2f %.2f", r, g, b]);
    [self askRestartFrom:vc.presentingViewController ?: self.from];
}

- (void)askRestartFrom:(UIViewController *)from {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Couleur enregistrée"
        message:@"Elle s'applique au prochain lancement de Spotify." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Fermer Spotify maintenant" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        [NSUserDefaults.standardUserDefaults synchronize];
        exit(0);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Plus tard" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { gPicker = nil; }]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *top = from;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:a animated:YES completion:nil];
    });
}
@end

void SMAccentPick(UIViewController *from) {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Couleur de l'app"
        message:@"Remplace le vert de Spotify (boutons, lecture en cours, barres…) par la couleur de ton choix."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"Choisir une couleur" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        gPicker = [SMAccentPicker new];
        gPicker.from = from;
        UIColorPickerViewController *vc = [UIColorPickerViewController new];
        vc.delegate = gPicker;
        vc.supportsAlpha = NO;
        vc.title = @"Couleur de l'app";
        NSArray *c = [NSUserDefaults.standardUserDefaults arrayForKey:SMAccentKey];
        if (c.count == 3) vc.selectedColor = [UIColor colorWithRed:[c[0] doubleValue] green:[c[1] doubleValue] blue:[c[2] doubleValue] alpha:1];
        [from presentViewController:vc animated:YES completion:nil];
    }]];
    if ([NSUserDefaults.standardUserDefaults arrayForKey:SMAccentKey]) {
        [menu addAction:[UIAlertAction actionWithTitle:@"Remettre le vert de Spotify" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:SMAccentKey];
            SMLogPublic(@"Couleur de l'app : vert de Spotify");
            gPicker = [SMAccentPicker new];
            [gPicker askRestartFrom:from];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = from.view;
    menu.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(from.view.bounds), CGRectGetMidY(from.view.bounds), 1, 1);
    [from presentViewController:menu animated:YES completion:nil];
}
