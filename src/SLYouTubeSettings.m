// Rubrique « Shorts Limiter » dans les Paramètres de YouTube, avec les cellules et sélecteurs de YouTube.
// Même principe que les tweaks open source (YouPiP, en-têtes PoomSmart/YouTubeHeader) : on ajoute une catégorie
// à la liste des paramètres et on fournit ses lignes quand YouTube la demande. Tout passe par le runtime
// Objective-C et chaque classe / méthode est vérifiée : si YouTube change, la rubrique n'apparaît simplement pas
// (les réglages restent accessibles par l'appui long à trois doigts).
#import "SL.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger SLSection = 7781;   // numéro de catégorie propre au tweak
static const int SLIconShorts = 776;       // YT_TAB_SHORTS (logo Shorts)

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

/// Reconstruit la rubrique (lignes et interrupteurs) après un changement de jour ou d'option.
static void SLRebuild(id manager, id vc) {
    SEL u = @selector(updateSectionForCategory:withEntry:);
    if ([manager respondsToSelector:u]) ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(manager, u, (NSUInteger)SLSection, nil);
    SLReload(vc);
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

    // Réglages selon le jour : les lignes de règles ci-dessous modifient le jour choisi
    add(SLSwitch(@"Réglages selon le jour", @"Des limites différentes pour chaque jour de la semaine", c.perDayEnabled,
                 ^BOOL(id cell, BOOL on) {
        SLCore.shared.perDayEnabled = on;
        dispatch_async(dispatch_get_main_queue(), ^{ SLRebuild(manager, vc); });
        return YES;
    }));

    NSInteger d = c.perDayEnabled ? MAX(1, c.editDay) : 0;
    if (c.perDayEnabled) {
        NSArray *days = @[@1, @2, @3, @4, @5, @6, @7];
        add(SLItem(@"Jour à régler", @"Les réglages ci-dessous s'appliquent à ce jour", ^NSString *{
            return SLDayLabel(MAX(1, SLCore.shared.editDay));
        }, ^BOOL(id cell, NSUInteger arg) {
            NSMutableArray *titles = [NSMutableArray array], *descs = [NSMutableArray array];
            for (NSNumber *n in days) {
                [titles addObject:SLDayLabel(n.integerValue)];
                [descs addObject:[SLCore.shared summaryForDay:n.integerValue]];
            }
            SLPushPicker(manager, vc, @"Jour à régler", days, titles, descs, SLCore.shared.editDay, ^(NSInteger v) {
                SLCore.shared.editDay = v;
                SLRebuild(manager, vc);
            });
            return YES;
        }));
    }

    // Règle 1 : pause après un temps de Shorts, puis ça recommence
    add(SLSwitch(@"Pause après une limite", @"Après la limite de temps, les Shorts sont bloqués pendant la durée de pause, puis le compteur repart de zéro",
                 [c rule:@"cooldown" day:d] != 0, ^BOOL(id cell, BOOL on) { [SLCore.shared setRule:@"cooldown" day:d value:on]; SLReload(vc); return YES; }));

    add(SLItem(@"Limite avant la pause", @"Temps de Shorts autorisé avant chaque pause", ^NSString *{
        return SLMinutes([SLCore.shared rule:@"limit" day:d]);
    }, ^BOOL(id cell, NSUInteger arg) {
        SLPushPicker(manager, vc, @"Limite avant la pause", @[@1, @2, @3, @5, @10, @15, @20, @30, @45, @60, @90, @120, @180],
                     nil, nil, [SLCore.shared rule:@"limit" day:d], ^(NSInteger v) { [SLCore.shared setRule:@"limit" day:d value:v]; });
        return YES;
    }));

    add(SLItem(@"Durée de la pause", @"Pendant combien de temps les Shorts restent bloqués", ^NSString *{
        return SLMinutes([SLCore.shared rule:@"block" day:d]);
    }, ^BOOL(id cell, NSUInteger arg) {
        SLPushPicker(manager, vc, @"Durée de la pause", @[@5, @10, @15, @20, @30, @45, @60, @90, @120, @180, @240],
                     nil, nil, [SLCore.shared rule:@"block" day:d], ^(NSInteger v) { [SLCore.shared setRule:@"block" day:d value:v]; });
        return YES;
    }));

    // Règle 2 : maximum par jour, puis plus de Shorts jusqu'à minuit
    add(SLSwitch(@"Limite quotidienne", @"Une fois le maximum du jour atteint, plus de Shorts jusqu'à minuit",
                 [c rule:@"daily" day:d] != 0, ^BOOL(id cell, BOOL on) { [SLCore.shared setRule:@"daily" day:d value:on]; SLReload(vc); return YES; }));

    add(SLItem(@"Maximum par jour", @"Temps total de Shorts autorisé dans la journée", ^NSString *{
        return SLMinutes([SLCore.shared rule:@"dailyMin" day:d]);
    }, ^BOOL(id cell, NSUInteger arg) {
        SLPushPicker(manager, vc, @"Maximum par jour", @[@5, @10, @15, @20, @30, @45, @60, @90, @120, @150, @180, @240],
                     nil, nil, [SLCore.shared rule:@"dailyMin" day:d], ^(NSInteger v) { [SLCore.shared setRule:@"dailyMin" day:d value:v]; });
        return YES;
    }));

    if (c.perDayEnabled) {
        add(SLItem(@"Copier vers un autre jour", [NSString stringWithFormat:@"Recopie les réglages de %@ sur le jour choisi", SLDayName(d).lowercaseString], nil,
                   ^BOOL(id cell, NSUInteger arg) {
            NSMutableArray *values = [NSMutableArray arrayWithObject:@0], *titles = [NSMutableArray arrayWithObject:@"Tous les autres jours"];
            for (NSInteger i = 1; i <= 7; i++) {
                if (i == d) continue;
                [values addObject:@(i)];
                [titles addObject:SLDayLabel(i)];
            }
            SLPushPicker(manager, vc, @"Copier vers", values, titles, nil, -1, ^(NSInteger v) {
                [SLCore.shared copyRulesFromDay:d toDay:v];
            });
            return YES;
        }));
    }

    add(SLSwitch(@"Compteur pendant les Shorts", @"Affiche le temps utilisé en haut de l'écran", c.showCounter,
                 ^BOOL(id cell, BOOL on) { SLCore.shared.showCounter = on; return YES; }));

    add(SLItem(@"Historique et détection", @"Jours précédents, noms d'écrans, journal", nil, ^BOOL(id cell, NSUInteger arg) {
        [[SLOverlay shared] presentSettings];
        return YES;
    }));

    NSString *title = @"Shorts Limiter";
    SEL withIcon = @selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:);
    SEL noIcon = @selector(setSectionItems:forCategory:title:titleDescription:headerHidden:);
    Class Icon = objc_getClass("YTIIcon");
    if ([vc respondsToSelector:withIcon] && Icon) {
        id icon = [Icon new];
        if ([icon respondsToSelector:@selector(setIconType:)]) ((void (*)(id, SEL, int))objc_msgSend)(icon, @selector(setIconType:), SLIconShorts);
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
