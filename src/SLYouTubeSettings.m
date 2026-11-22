// Rubrique « Shorts Limiter » dans les Paramètres de YouTube, avec les cellules et sélecteurs de YouTube.
// Même principe que les tweaks open source (YouPiP, en-têtes PoomSmart/YouTubeHeader) : on ajoute une catégorie
// à la liste des paramètres et on fournit ses lignes quand YouTube la demande. Tout passe par le runtime
// Objective-C et chaque classe / méthode est vérifiée : si YouTube change, la rubrique n'apparaît simplement pas
// (les réglages restent accessibles par l'appui long à trois doigts).
#import "SL.h"
#import "NFFocus.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger SLSection = 7781;   // numéro de catégorie propre au tweak
static const int SLIconShortsCairo = 1157; // YT_TAB_SHORTS_CAIRO (logo Shorts, nouveau style)
static const int SLIconShorts = 776;       // YT_TAB_SHORTS (logo Shorts)
static NSString *const SLTitle = @"Shorts Limiter";

typedef BOOL (^SLSelectBlock)(id cell, NSUInteger arg);
typedef BOOL (^SLSwitchBlock)(id cell, BOOL on);

#pragma mark Fabrication des lignes YouTube

static id SLItem(NSString *title, NSString *desc, NSString *(^detail)(void), SLSelectBlock select) {
    Class C = objc_getClass("YTSettingsSectionItem");
    SEL s4 = @selector(itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:);
    if ([C respondsToSelector:s4])
        return ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(C, s4, title, desc, nil, detail, select);
    SEL s3 = @selector(itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:);
    if ([C respondsToSelector:s3])
        return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(C, s3, title, nil, detail, select);
    return nil;
}

static id SLSwitch(NSString *title, NSString *desc, BOOL on, SLSwitchBlock block) {
    Class C = objc_getClass("YTSettingsSectionItem");
    SEL s = @selector(switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:);
    if ([C respondsToSelector:s])
        return ((id (*)(id, SEL, id, id, id, BOOL, id, int))objc_msgSend)(C, s, title, desc, nil, on, block, 0);
    SEL s2 = @selector(switchItemWithTitle:switchOn:switchBlock:);
    if ([C respondsToSelector:s2])
        return ((id (*)(id, SEL, id, BOOL, id))objc_msgSend)(C, s2, title, on, block);
    return nil;
}

static id SLCheckmark(NSString *title, NSString *desc, SLSelectBlock block) {
    Class C = objc_getClass("YTSettingsSectionItem");
    SEL s2 = @selector(checkmarkItemWithTitle:titleDescription:selectBlock:);
    if (desc && [C respondsToSelector:s2]) return ((id (*)(id, SEL, id, id, id))objc_msgSend)(C, s2, title, desc, block);
    SEL s = @selector(checkmarkItemWithTitle:selectBlock:);
    if (![C respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL, id, id))objc_msgSend)(C, s, title, block);
}

static id SLSettingsVC(id manager) {
    for (NSString *key in @[@"_dataDelegate", @"_settingsViewControllerDelegate"]) {
        @try {
            id v = [manager valueForKey:key];
            if (v) return v;
        } @catch (NSException *e) {}
    }
    if ([manager respondsToSelector:@selector(parentResponder)]) {
        id p = ((id (*)(id, SEL))objc_msgSend)(manager, @selector(parentResponder));
        if ([p respondsToSelector:@selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)]) return p;
    }
    return nil;
}

static void SLReload(id settingsVC) {
    if ([settingsVC respondsToSelector:@selector(reloadData)]) ((void (*)(id, SEL))objc_msgSend)(settingsVC, @selector(reloadData));
}

static NSString *SLMinutes(NSInteger m) {
    if (m >= 60 && m % 60 == 0) return [NSString stringWithFormat:@"%ld h", (long)(m / 60)];
    if (m >= 60) return [NSString stringWithFormat:@"%ld h %02ld", (long)(m / 60), (long)(m % 60)];
    return [NSString stringWithFormat:@"%ld min", (long)m];
}

/// Sélecteur de YouTube (même écran que « Qualité vidéo »), poussé dans la navigation des paramètres.
/// titles / descs : textes des lignes (nil : durées en minutes).
static void SLPushPicker(id manager, id settingsVC, NSString *title, NSArray<NSNumber *> *values, NSArray<NSString *> *titles,
                         NSArray<NSString *> *descs, NSInteger current, void (^apply)(NSInteger)) {
    Class P = objc_getClass("YTSettingsPickerViewController");
    SEL init = @selector(initWithNavTitle:pickerSectionTitle:rows:selectedItemIndex:parentResponder:);
    if (!P || ![P instancesRespondToSelector:init] || ![settingsVC respondsToSelector:@selector(pushViewController:)]) return;
    NSMutableArray *rows = [NSMutableArray array];
    NSUInteger selected = 0;
    for (NSUInteger i = 0; i < values.count; i++) {
        NSInteger v = values[i].integerValue;
        if (v == current) selected = i;
        id row = SLCheckmark(titles ? titles[i] : SLMinutes(v), descs ? descs[i] : nil, ^BOOL(id cell, NSUInteger arg) {
            apply(v);
            SLReload(settingsVC);
            return YES;
        });
        if (row) [rows addObject:row];
    }
    id parent = [manager respondsToSelector:@selector(parentResponder)]
        ? ((id (*)(id, SEL))objc_msgSend)(manager, @selector(parentResponder)) : settingsVC;
    id picker = ((id (*)(id, SEL, id, id, id, NSUInteger, id))objc_msgSend)([P alloc], init, title, nil, rows, selected, parent);
    if (picker) ((void (*)(id, SEL, id))objc_msgSend)(settingsVC, @selector(pushViewController:), picker);
}

static void SLSetOn(id item, BOOL on) {
    if ([item respondsToSelector:@selector(setOn:)]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, @selector(setOn:), on);
}

static NSString *SLDayLabel(NSInteger day) {
    NSString *name = SLDayName(day);
    return day == SLCore.shared.todayWeekday ? [name stringByAppendingString:@" (aujourd'hui)"] : name;
}

static void SLBuildSection(id manager) {
    id vc = SLSettingsVC(manager);
    if (!vc) return;
    SLCore *c = SLCore.shared;
    NSMutableArray *items = [NSMutableArray array];
    void (^add)(id) = ^(id item) { if (item) [items addObject:item]; };

    // Blocage de toute l'app pendant un focus NoteFlow (shared/NFFocus.m) : liaison avec le code copié dans NoteFlow
    add(SLItem(@"Mode focus NoteFlow", [NSString stringWithFormat:@"YouTube entier est bloqué pendant tes focus. Touche pour coller le code de liaison copié dans NoteFlow. Version %s", SL_VERSION], ^NSString *{
        return NFFocusStatus();
    }, ^BOOL(id cell, NSUInteger arg) {
        UIViewController *from = [vc isKindOfClass:UIViewController.class] ? vc : nil;
        while (from.presentedViewController) from = from.presentedViewController;
        if (from) NFFocusPresentSettings(from);
        return YES;
    }));

    add(SLItem(@"Temps sur les Shorts aujourd'hui", nil, ^NSString *{
        return SLFormat([SLCore.shared.today[@"seconds"] doubleValue]);
    }, ^BOOL(id cell, NSUInteger arg) { return YES; }));

    add(SLItem(@"Statut", nil, ^NSString *{
        SLCore *k = SLCore.shared;
        if (k.dailyBlocked) return @"Bloqués jusqu'à minuit";
        if (k.isBlocked) return [NSString stringWithFormat:@"En pause encore %@", SLFormat(k.remainingBlock)];
        if (k.remainingBeforeBlock < 0) return @"Aucune limite active";
        return [NSString stringWithFormat:@"%@ restantes", SLFormat(k.remainingBeforeBlock)];
    }, ^BOOL(id cell, NSUInteger arg) { SLReload(vc); return YES; }));

    add(SLItem(@"Ouvertures et pauses aujourd'hui", nil, ^NSString *{
        NSDictionary *t = SLCore.shared.today;
        return [NSString stringWithFormat:@"%@ · %@", t[@"entries"], t[@"blocks"]];
    }, ^BOOL(id cell, NSUInteger arg) { return YES; }));

    // Sélecteur de jours (toujours affiché) : « Tous les jours » = mêmes réglages chaque jour ; un jour précis
    // active les réglages par jour et les lignes de règles ci-dessous modifient ce jour-là.
    __block id cooldownSwitch = nil, dailySwitch = nil;
    NSInteger (^day)(void) = ^NSInteger { SLCore *k = SLCore.shared; return k.perDayEnabled ? MAX(1, k.editDay) : 0; };
    void (^refreshSwitches)(void) = ^{
        NSInteger dd = day();
        SLSetOn(cooldownSwitch, [SLCore.shared rule:@"cooldown" day:dd] != 0);
        SLSetOn(dailySwitch, [SLCore.shared rule:@"daily" day:dd] != 0);
        SLReload(vc);
    };
    add(SLItem(@"Jours", @"Choisis « Tous les jours » ou un jour précis à régler", ^NSString *{
        SLCore *k = SLCore.shared;
        return k.perDayEnabled ? SLDayLabel(MAX(1, k.editDay)) : @"Tous les jours";
    }, ^BOOL(id cell, NSUInteger arg) {
        SLCore *k = SLCore.shared;
        NSMutableArray *values = [NSMutableArray arrayWithObject:@0];
        NSMutableArray *titles = [NSMutableArray arrayWithObject:@"Tous les jours"];
        NSMutableArray *descs = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"Mêmes réglages chaque jour : %@", [k summaryForDay:0]]];
        for (NSInteger i = 1; i <= 7; i++) {
            [values addObject:@(i)];
            [titles addObject:SLDayLabel(i)];
            [descs addObject:[k summaryForDay:i]];
        }
        SLPushPicker(manager, vc, @"Jours", values, titles, descs, k.perDayEnabled ? MAX(1, k.editDay) : 0, ^(NSInteger v) {
            SLCore *kk = SLCore.shared;
            if (v == 0) {
                kk.perDayEnabled = NO;
            } else {
                if (!kk.perDayEnabled) kk.perDayEnabled = YES;
                kk.editDay = v;
            }
            [kk log:[NSString stringWithFormat:@"Jours : %@", SLDayName(v)]];
            refreshSwitches();
        });
        return YES;
    }));

    // Règle 1 : pause après un temps de Shorts, puis ça recommence
    cooldownSwitch = SLSwitch(@"Pause après une limite", @"Après la limite de temps, les Shorts sont bloqués pendant la durée de pause, puis le compteur repart de zéro",
                 [c rule:@"cooldown" day:day()] != 0, ^BOOL(id cell, BOOL on) { [SLCore.shared setRule:@"cooldown" day:day() value:on]; SLReload(vc); return YES; });
    add(cooldownSwitch);

    add(SLItem(@"Limite avant la pause", @"Temps de Shorts autorisé avant chaque pause", ^NSString *{
        return SLMinutes([SLCore.shared rule:@"limit" day:day()]);
    }, ^BOOL(id cell, NSUInteger arg) {
        SLPushPicker(manager, vc, @"Limite avant la pause", @[@1, @2, @3, @5, @10, @15, @20, @30, @45, @60, @90, @120, @180],
                     nil, nil, [SLCore.shared rule:@"limit" day:day()], ^(NSInteger v) { [SLCore.shared setRule:@"limit" day:day() value:v]; });
        return YES;
    }));

    add(SLItem(@"Durée de la pause", @"Pendant combien de temps les Shorts restent bloqués", ^NSString *{
        return SLMinutes([SLCore.shared rule:@"block" day:day()]);
    }, ^BOOL(id cell, NSUInteger arg) {
        SLPushPicker(manager, vc, @"Durée de la pause", @[@5, @10, @15, @20, @30, @45, @60, @90, @120, @180, @240],
                     nil, nil, [SLCore.shared rule:@"block" day:day()], ^(NSInteger v) { [SLCore.shared setRule:@"block" day:day() value:v]; });
        return YES;
    }));

    // Règle 2 : maximum par jour, puis plus de Shorts jusqu'à minuit
    dailySwitch = SLSwitch(@"Limite quotidienne", @"Une fois le maximum du jour atteint, plus de Shorts jusqu'à minuit",
                 [c rule:@"daily" day:day()] != 0, ^BOOL(id cell, BOOL on) { [SLCore.shared setRule:@"daily" day:day() value:on]; SLReload(vc); return YES; });
    add(dailySwitch);

    add(SLItem(@"Maximum par jour", @"Temps total de Shorts autorisé dans la journée", ^NSString *{
        return SLMinutes([SLCore.shared rule:@"dailyMin" day:day()]);
    }, ^BOOL(id cell, NSUInteger arg) {
        SLPushPicker(manager, vc, @"Maximum par jour", @[@5, @10, @15, @20, @30, @45, @60, @90, @120, @150, @180, @240],
                     nil, nil, [SLCore.shared rule:@"dailyMin" day:day()], ^(NSInteger v) { [SLCore.shared setRule:@"dailyMin" day:day() value:v]; });
        return YES;
    }));

    add(SLItem(@"Copier vers un autre jour", @"Recopie les réglages du jour choisi dans « Jours »", nil, ^BOOL(id cell, NSUInteger arg) {
        NSInteger from = day();
        NSMutableArray *values = [NSMutableArray array], *titles = [NSMutableArray array];
        if (from != 0) { [values addObject:@0]; [titles addObject:@"Tous les autres jours"]; }
        for (NSInteger i = 1; i <= 7; i++) {
            if (i == from) continue;
            [values addObject:@(i)];
            [titles addObject:SLDayLabel(i)];
        }
        SLPushPicker(manager, vc, [NSString stringWithFormat:@"Copier %@ vers", SLDayName(from).lowercaseString], values, titles, nil, -1,
                     ^(NSInteger v) { [SLCore.shared copyRulesFromDay:from toDay:v]; });
        return YES;
    }));

    add(SLSwitch(@"Compteur pendant les Shorts", @"Affiche le temps utilisé en haut de l'écran", c.showCounter,
                 ^BOOL(id cell, BOOL on) { SLCore.shared.showCounter = on; return YES; }));

    add(SLSwitch(@"Reprendre les vidéos", @"Une vidéo repart là où tu t'étais arrêté (pas les Shorts, même sans l'historique YouTube)",
                 SLResumeEnabled(), ^BOOL(id cell, BOOL on) { SLResumeSetEnabled(on); return YES; }));

    add(SLItem(@"Historique et détection", @"Jours précédents, noms d'écrans, journal", nil, ^BOOL(id cell, NSUInteger arg) {
        [[SLOverlay shared] presentSettings];
        return YES;
    }));

    NSString *title = SLTitle;
    SEL withIcon = @selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:);
    SEL noIcon = @selector(setSectionItems:forCategory:title:titleDescription:headerHidden:);
    Class Icon = objc_getClass("YTIIcon");
    if ([vc respondsToSelector:withIcon] && Icon) {
        // Première icône Shorts que cette version de YouTube sait dessiner (la barre est ajoutée par SLDecorateSettings)
        id icon = nil;
        for (NSNumber *type in @[@(SLIconShortsCairo), @(SLIconShorts)]) {
            id candidate = [Icon new];
            if (![candidate respondsToSelector:@selector(setIconType:)]) break;
            ((void (*)(id, SEL, int))objc_msgSend)(candidate, @selector(setIconType:), type.intValue);
            UIImage *img = [candidate respondsToSelector:@selector(iconImageWithColor:)]
                ? ((UIImage *(*)(id, SEL, id))objc_msgSend)(candidate, @selector(iconImageWithColor:), UIColor.whiteColor) : nil;
            if (!icon) icon = candidate;
            if (img) { icon = candidate; break; }
        }
        ((void (*)(id, SEL, id, NSInteger, id, id, id, BOOL))objc_msgSend)(vc, withIcon, items, SLSection, title, icon, nil, NO);
    } else if ([vc respondsToSelector:noIcon]) {
        ((void (*)(id, SEL, id, NSInteger, id, id, BOOL))objc_msgSend)(vc, noIcon, items, SLSection, title, nil, NO);
    }
}

#pragma mark Branchements

static NSArray *SLInsert(NSArray *order, NSInteger after) {
    if (![order isKindOfClass:NSArray.class] || [order containsObject:@(SLSection)]) return order;
    NSMutableArray *m = [order mutableCopy];
    NSUInteger i = after >= 0 ? [order indexOfObject:@(after)] : NSNotFound;
    [m insertObject:@(SLSection) atIndex:i == NSNotFound ? 0 : i + 1];
    return m;
}

static BOOL SLHooked;

void SLInstallYouTubeSettings(void) {
    if (SLHooked) return;
    Class presentation = objc_getClass("YTAppSettingsPresentationData");
    Class manager = objc_getClass("YTSettingsSectionItemManager");
    if (!manager) return;
    SLHooked = YES;

    // Ordre des catégories (ancienne présentation : une seule liste)
    Method m1 = presentation ? class_getClassMethod(presentation, @selector(settingsCategoryOrder)) : NULL;
    if (m1) {
        NSArray *(*orig)(id, SEL) = (void *)method_getImplementation(m1);
        method_setImplementation(m1, imp_implementationWithBlock(^NSArray *(id self) {
            return SLInsert(orig(self, @selector(settingsCategoryOrder)), 1);
        }));
    }

    // Groupes de la nouvelle présentation (« Compte », …) : en tête du premier groupe
    Class group = objc_getClass("YTSettingsGroupData");
    Method m2 = group ? class_getInstanceMethod(group, @selector(orderedCategories)) : NULL;
    if (m2) {
        NSArray *(*orig)(id, SEL) = (void *)method_getImplementation(m2);
        method_setImplementation(m2, imp_implementationWithBlock(^NSArray *(id self) {
            NSArray *cats = orig(self, @selector(orderedCategories));
            NSUInteger type = [self respondsToSelector:@selector(type)] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(self, @selector(type)) : 0;
            if (type != 1) return cats;
            return SLInsert(cats, -1);
        }));
    }

    // Contenu de la rubrique quand YouTube la demande
    Method m3 = class_getInstanceMethod(manager, @selector(updateSectionForCategory:withEntry:));
    if (m3) {
        void (*orig)(id, SEL, NSUInteger, id) = (void *)method_getImplementation(m3);
        method_setImplementation(m3, imp_implementationWithBlock(^(id self, NSUInteger category, id entry) {
            if (category == (NSUInteger)SLSection) {
                @try { SLBuildSection(self); } @catch (NSException *e) {
                    [SLCore.shared log:[NSString stringWithFormat:@"Paramètres YouTube : erreur %@", e.reason]];
                }
                return;
            }
            orig(self, @selector(updateSectionForCategory:withEntry:), category, entry);
        }));
    }
    [SLCore.shared log:[NSString stringWithFormat:@"Paramètres YouTube : ordre %@, groupes %@, contenu %@",
                        m1 ? @"oui" : @"non", m2 ? @"oui" : @"non", m3 ? @"oui" : @"non"]];
}

#pragma mark Icône barrée dans la liste des paramètres

/// Logo Shorts barré, dessiné (utilisé si YouTube n'affiche pas d'icône pour la rubrique).
static UIImage *SLShortsSlashImage(UIColor *color, UIColor *bg) {
    CGSize size = CGSizeMake(26, 26);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef g = ctx.CGContext;
        CGContextSaveGState(g);
        CGContextTranslateCTM(g, 13, 13);
        CGContextRotateCTM(g, -0.45);
        UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(-6.5, -10.5, 13, 21) cornerRadius:6.5];
        body.lineWidth = 2;
        [color setStroke];
        [body stroke];
        CGContextRotateCTM(g, 0.45);
        UIBezierPath *play = [UIBezierPath bezierPath];
        [play moveToPoint:CGPointMake(-2.5, -4)];
        [play addLineToPoint:CGPointMake(4, 0)];
        [play addLineToPoint:CGPointMake(-2.5, 4)];
        [play closePath];
        [color setFill];
        [play fill];
        CGContextRestoreGState(g);
        UIBezierPath *gap = [UIBezierPath bezierPath];
        [gap moveToPoint:CGPointMake(3, 3)];
        [gap addLineToPoint:CGPointMake(23, 23)];
        gap.lineWidth = 5;
        gap.lineCapStyle = kCGLineCapRound;
        [bg setStroke];
        [gap stroke];
        gap.lineWidth = 2;
        [color setStroke];
        [gap stroke];
    }];
}

/// Barre diagonale posée sur l'icône Shorts de YouTube.
@interface SLSlashView : UIView
@property (nonatomic, strong) UIColor *color, *bg;
@end

@implementation SLSlashView
- (void)drawRect:(CGRect)rect {
    CGRect b = CGRectInset(self.bounds, 2, 2);
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:b.origin];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(b), CGRectGetMaxY(b))];
    p.lineCapStyle = kCGLineCapRound;
    p.lineWidth = 5;
    [self.bg setStroke];
    [p stroke];
    p.lineWidth = 2;
    [self.color setStroke];
    [p stroke];
}
@end

static const NSInteger SLDecorTag = 0x51D3;

static void SLFindLabels(UIView *v, NSMutableArray *out, int depth) {
    if (depth > 60 || v.hidden) return;
    if ([v isKindOfClass:UILabel.class] && [((UILabel *)v).text isEqualToString:SLTitle]) [out addObject:v];
    for (UIView *sub in v.subviews) SLFindLabels(sub, out, depth + 1);
}

static UIView *SLIconNear(UIView *cell, UILabel *label) {
    CGRect lr = [label convertRect:label.bounds toView:cell];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v != cell && !v.hidden && v.tag != SLDecorTag) {
            CGRect r = [v convertRect:v.bounds toView:cell];
            BOOL iconSize = r.size.width >= 14 && r.size.width <= 40 && r.size.height >= 14 && r.size.height <= 40;
            BOOL leftOfLabel = CGRectGetMaxX(r) <= CGRectGetMinX(lr) + 2 && fabs(CGRectGetMidY(r) - CGRectGetMidY(lr)) < 14;
            NSString *n = NSStringFromClass(v.class).lowercaseString;
            if (iconSize && leftOfLabel && ([v isKindOfClass:UIImageView.class] || [n containsString:@"icon"] || [n containsString:@"image"]))
                return v;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

/// Contrôleur des Paramètres de YouTube affiché à l'écran (sinon nil : rien à faire).
static UIViewController *SLVisibleSettings(UIViewController *vc, int depth) {
    if (!vc || depth > 40) return nil;
    if (vc.isViewLoaded && vc.view.window && [NSStringFromClass(vc.class) containsString:@"Settings"]) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *f = SLVisibleSettings(child, depth + 1);
        if (f) return f;
    }
    if (vc.presentedViewController.presentingViewController == vc) return SLVisibleSettings(vc.presentedViewController, depth + 1);
    return nil;
}

/// Ajoute la barre sur l'icône de la rubrique « Shorts Limiter » (ou dessine l'icône si YouTube n'en a pas mis).
void SLDecorateSettings(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden || [NSStringFromClass(w.class) hasPrefix:@"SL"]) continue;
            UIViewController *settings = SLVisibleSettings(w.rootViewController, 0);
            if (!settings) continue;
            NSMutableArray<UILabel *> *labels = [NSMutableArray array];
            SLFindLabels(settings.view, labels, 0);
            for (UILabel *label in labels) {
                UIView *cell = label.superview;
                for (int i = 0; i < 6 && cell.superview; i++) {
                    if ([cell isKindOfClass:UICollectionViewCell.class] || [cell isKindOfClass:UITableViewCell.class]) break;
                    cell = cell.superview;
                }
                if ([cell viewWithTag:SLDecorTag]) continue;
                UIColor *color = label.textColor ?: UIColor.whiteColor;
                UIColor *bg = UIColor.blackColor;
                for (UIView *p = cell; p; p = p.superview) {
                    CGFloat a = 0;
                    if (p.backgroundColor && [p.backgroundColor getWhite:NULL alpha:&a] && a > 0.9) { bg = p.backgroundColor; break; }
                }
                UIView *icon = SLIconNear(cell, label);
                if (icon) {
                    SLSlashView *slash = [[SLSlashView alloc] initWithFrame:icon.bounds];
                    slash.tag = SLDecorTag;
                    slash.color = color;
                    slash.bg = bg;
                    slash.backgroundColor = UIColor.clearColor;
                    slash.userInteractionEnabled = NO;
                    slash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                    [icon addSubview:slash];
                } else {
                    CGRect lr = [label convertRect:label.bounds toView:cell];
                    UIImageView *img = [[UIImageView alloc] initWithImage:SLShortsSlashImage(color, bg)];
                    img.tag = SLDecorTag;
                    img.frame = CGRectMake(MAX(4, CGRectGetMinX(lr) - 47), CGRectGetMidY(lr) - 13, 26, 26);
                    img.userInteractionEnabled = NO;
                    [cell addSubview:img];
                }
            }
        }
    }
}
