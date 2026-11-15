#import "SL.h"

#define SLKey(x) (@"ShortLimiter." x)

static NSString *const SLDefaultInclude = @"Reel,Shorts";
static NSString *const SLDefaultExclude = @"Shelf,Thumbnail,Cell,Lockup,Overlay,Button";
static NSString *const SLDefaultExit = @"PivotBarItem";
static const double SLMinScreenRatio = 0.5; // un écran Shorts occupe au moins la moitié de la fenêtre

NSString *SLFormat(double seconds) {
    long s = (long)MAX(0, floor(seconds));
    if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, (s / 60) % 60, s % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

UIWindowScene *SLActiveScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        if (!fallback) fallback = (UIWindowScene *)scene;
    }
    return fallback;
}

static NSString *SLDayKey(NSDate *date) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyy-MM-dd";
    });
    f.timeZone = NSTimeZone.localTimeZone;
    return [f stringFromDate:date];
}

static NSArray<NSString *> *SLParse(NSString *list) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [list componentsSeparatedByString:@","]) {
        NSString *t = [[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if (t.length) [out addObject:t];
    }
    return out;
}

/// Appui long à trois doigts : ouvre les réglages.
@interface SLGesture : UILongPressGestureRecognizer <UIGestureRecognizerDelegate>
@end

@implementation SLGesture
- (instancetype)init {
    if ((self = [super initWithTarget:self action:@selector(fire:)])) {
        self.numberOfTouchesRequired = 3;
        self.minimumPressDuration = 0.8;
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
        self.delegate = self;
    }
    return self;
}
- (void)fire:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [[SLOverlay shared] presentSettings];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}
@end

@implementation SLCore {
    NSUserDefaults *_d;
    NSTimer *_timer;
    NSDate *_lastTick;
    NSMutableDictionary *_today;
    NSMutableArray *_history;
    NSMutableSet<NSString *> *_seen;
    __weak UIViewController *_shortsVC;
    NSString *_hitName;
    NSDate *_lastExit;
    BOOL _exiting;
    int _ticksSinceSave;
}

+ (instancetype)shared {
    static SLCore *core;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ core = [SLCore new]; });
    return core;
}

- (instancetype)init {
    if ((self = [super init])) {
        _d = NSUserDefaults.standardUserDefaults;
        [_d registerDefaults:@{
            SLKey("limit"): @5, SLKey("block"): @30, SLKey("cooldown"): @YES, SLKey("daily"): @NO, SLKey("dailyMin"): @30, SLKey("counter"): @YES, SLKey("log"): @YES,
            SLKey("include"): SLDefaultInclude, SLKey("exclude"): SLDefaultExclude, SLKey("exit"): SLDefaultExit,
        }];
        _showCounter = [_d boolForKey:SLKey("counter")];
        _perDayEnabled = [_d boolForKey:SLKey("perDay")];
        _editDay = self.todayWeekday;
        _logEnabled = [_d boolForKey:SLKey("log")];
        _includeNames = [_d stringForKey:SLKey("include")] ?: SLDefaultInclude;
        _excludeNames = [_d stringForKey:SLKey("exclude")] ?: SLDefaultExclude;
        _exitNames = [_d stringForKey:SLKey("exit")] ?: SLDefaultExit;
        _usedSeconds = [_d doubleForKey:SLKey("used")];
        double until = [_d doubleForKey:SLKey("blockedUntil")];
        _blockedUntil = until > 0 ? [NSDate dateWithTimeIntervalSince1970:until] : nil;
        NSDictionary *today = [_d dictionaryForKey:SLKey("today")];
        _today = today ? [today mutableCopy] : [self emptyDay:NSDate.date];
        _history = [([_d arrayForKey:SLKey("history")] ?: @[]) mutableCopy];
        _seen = [NSMutableSet set];
    }
    return self;
}

- (NSMutableDictionary *)emptyDay:(NSDate *)date {
    return [@{@"day": SLDayKey(date), @"seconds": @0, @"entries": @0, @"blocks": @0} mutableCopy];
}

#pragma mark Réglages

// Règles : valeurs communes (clés ShortLimiter.limit, …) ou propres à un jour (ShortLimiter.profiles["1".."7"]).
// Jour 0 = réglages communs ; 1 = lundi … 7 = dimanche.

NSString *SLDayName(NSInteger day) {
    NSArray *names = @[@"Tous les jours", @"Lundi", @"Mardi", @"Mercredi", @"Jeudi", @"Vendredi", @"Samedi", @"Dimanche"];
    return day >= 0 && day < (NSInteger)names.count ? names[day] : @"?";
}

- (NSInteger)todayWeekday {
    NSInteger w = [NSCalendar.currentCalendar component:NSCalendarUnitWeekday fromDate:NSDate.date]; // 1 = dimanche
    return w == 1 ? 7 : w - 1;
}

- (NSInteger)activeDay { return _perDayEnabled ? self.todayWeekday : 0; }

- (NSInteger)rule:(NSString *)key day:(NSInteger)day {
    if (day > 0) {
        NSDictionary *p = [_d dictionaryForKey:SLKey("profiles")][@(day).stringValue];
        if (p[key]) return [p[key] integerValue];
    }
    return [_d integerForKey:[@"ShortLimiter." stringByAppendingString:key]];
}

- (void)setRule:(NSString *)key day:(NSInteger)day value:(NSInteger)v {
    BOOL liftPause = [key isEqual:@"cooldown"] && !v && day == self.activeDay;
    if (day <= 0) {
        [_d setInteger:v forKey:[@"ShortLimiter." stringByAppendingString:key]];
    } else {
        NSMutableDictionary *all = [([_d dictionaryForKey:SLKey("profiles")] ?: @{}) mutableCopy];
        NSMutableDictionary *p = [(all[@(day).stringValue] ?: @{}) mutableCopy];
        for (NSString *k in @[@"cooldown", @"limit", @"block", @"daily", @"dailyMin"]) {
            if (!p[k]) p[k] = @([self rule:k day:0]); // un jour part des réglages communs
        }
        p[key] = @(v);
        all[@(day).stringValue] = p;
        [_d setObject:all forKey:SLKey("profiles")];
    }
    if (liftPause) { _blockedUntil = nil; _usedSeconds = 0; [self save]; } // désactiver la pause lève celle en cours
}

- (void)copyRulesFromDay:(NSInteger)from toDay:(NSInteger)to {
    if (from == to) return;
    NSArray *days = to == 0 ? @[@1, @2, @3, @4, @5, @6, @7] : @[@(to)];
    for (NSNumber *d in days) {
        if (d.integerValue == from) continue;
        for (NSString *k in @[@"cooldown", @"limit", @"block", @"daily", @"dailyMin"])
            [self setRule:k day:d.integerValue value:[self rule:k day:from]];
    }
    [self log:[NSString stringWithFormat:@"Réglages de %@ copiés vers %@", SLDayName(from), SLDayName(to)]];
}

- (NSString *)summaryForDay:(NSInteger)day {
    NSMutableArray *parts = [NSMutableArray array];
    if ([self rule:@"cooldown" day:day])
        [parts addObject:[NSString stringWithFormat:@"pause %ld/%ld min", (long)[self rule:@"limit" day:day], (long)[self rule:@"block" day:day]]];
    if ([self rule:@"daily" day:day])
        [parts addObject:[NSString stringWithFormat:@"max %ld min", (long)[self rule:@"dailyMin" day:day]]];
    return parts.count ? [parts componentsJoinedByString:@" · "] : @"aucune limite";
}

- (void)setPerDayEnabled:(BOOL)v {
    _perDayEnabled = v;
    [_d setBool:v forKey:SLKey("perDay")];
    _editDay = v ? self.todayWeekday : 0;
}

// Règles en vigueur aujourd'hui (moteur) ; les modifier change le jour en cours
- (NSInteger)limitMinutes { return MAX(1, [self rule:@"limit" day:self.activeDay]); }
- (NSInteger)blockMinutes { return MAX(1, [self rule:@"block" day:self.activeDay]); }
- (BOOL)cooldownEnabled { return [self rule:@"cooldown" day:self.activeDay] != 0; }
- (BOOL)dailyEnabled { return [self rule:@"daily" day:self.activeDay] != 0; }
- (NSInteger)dailyMinutes { return MAX(1, [self rule:@"dailyMin" day:self.activeDay]); }
- (void)setLimitMinutes:(NSInteger)v { [self setRule:@"limit" day:self.activeDay value:MAX(1, v)]; }
- (void)setBlockMinutes:(NSInteger)v { [self setRule:@"block" day:self.activeDay value:MAX(1, v)]; }
- (void)setCooldownEnabled:(BOOL)v { [self setRule:@"cooldown" day:self.activeDay value:v]; }
- (void)setDailyEnabled:(BOOL)v { [self setRule:@"daily" day:self.activeDay value:v]; }
- (void)setDailyMinutes:(NSInteger)v { [self setRule:@"dailyMin" day:self.activeDay value:MAX(1, v)]; }
- (void)setShowCounter:(BOOL)v { _showCounter = v; [_d setBool:v forKey:SLKey("counter")]; }
- (void)setLogEnabled:(BOOL)v { _logEnabled = v; [_d setBool:v forKey:SLKey("log")]; [_seen removeAllObjects]; }
- (void)setIncludeNames:(NSString *)v { _includeNames = [v copy]; [_d setObject:_includeNames forKey:SLKey("include")]; }
- (void)setExcludeNames:(NSString *)v { _excludeNames = [v copy]; [_d setObject:_excludeNames forKey:SLKey("exclude")]; }
- (void)setExitNames:(NSString *)v { _exitNames = [v copy]; [_d setObject:_exitNames forKey:SLKey("exit")]; }

- (void)resetDetectionNames {
    self.includeNames = SLDefaultInclude;
    self.excludeNames = SLDefaultExclude;
    self.exitNames = SLDefaultExit;
}

#pragma mark État

static NSDate *SLNextMidnight(void) {
    NSCalendar *cal = NSCalendar.currentCalendar;
    return [cal startOfDayForDate:[cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:NSDate.date options:0]];
}

- (BOOL)cooldownBlocked { return self.cooldownEnabled && _blockedUntil && _blockedUntil.timeIntervalSinceNow > 0; }
- (BOOL)dailyBlocked { return self.dailyEnabled && [_today[@"seconds"] doubleValue] >= self.dailyMinutes * 60.0; }
- (BOOL)isBlocked { return self.cooldownBlocked || self.dailyBlocked; }

- (double)remainingBlock {
    double r = self.cooldownBlocked ? _blockedUntil.timeIntervalSinceNow : 0;
    if (self.dailyBlocked) r = MAX(r, SLNextMidnight().timeIntervalSinceNow);
    return r;
}

- (double)blockDuration {
    if (self.dailyBlocked) {
        double hit = [_today[@"dailyHit"] doubleValue];
        double end = SLNextMidnight().timeIntervalSince1970;
        return hit > 0 ? MAX(1, end - hit) : 86400;
    }
    double start = [_d doubleForKey:SLKey("blockStart")];
    if (!_blockedUntil || start <= 0) return self.blockMinutes * 60.0;
    return MAX(1, _blockedUntil.timeIntervalSince1970 - start);
}

- (CGFloat)tabBarInset {
    for (UIWindow *w in [self appWindows]) {
        NSMutableArray<UIView *> *bars = [NSMutableArray array];
        [self collect:w names:@[@"pivotbar"] into:bars depth:0];
        CGFloat best = 0;
        for (UIView *v in bars) {
            if ([NSStringFromClass(v.class).lowercaseString containsString:@"item"] || ![self isVisible:v inWindow:w]) continue;
            CGRect r = [v convertRect:v.bounds toView:nil];
            if (r.size.width < w.bounds.size.width * 0.8 || CGRectGetMinY(r) < w.bounds.size.height * 0.6) continue;
            best = MAX(best, w.bounds.size.height - CGRectGetMinY(r));
        }
        if (best > 0) return best;
        return w.safeAreaInsets.bottom + 56;
    }
    return 90;
}

- (double)remainingBeforeBlock {
    double r = -1;
    if (self.cooldownEnabled) r = MAX(0, self.limitMinutes * 60.0 - _usedSeconds);
    if (self.dailyEnabled) {
        double d = MAX(0, self.dailyMinutes * 60.0 - [_today[@"seconds"] doubleValue]);
        r = r < 0 ? d : MIN(r, d);
    }
    return r;
}
- (NSDictionary *)today { return [_today copy]; }
- (NSArray<NSDictionary *> *)history { return [_history copy]; }

- (void)save {
    [_d setDouble:_usedSeconds forKey:SLKey("used")];
    [_d setDouble:_blockedUntil ? _blockedUntil.timeIntervalSince1970 : 0 forKey:SLKey("blockedUntil")];
    [_d setObject:_today forKey:SLKey("today")];
    [_d setObject:_history forKey:SLKey("history")];
    _ticksSinceSave = 0;
}

- (void)bump:(NSString *)key by:(double)amount {
    _today[key] = @([_today[key] doubleValue] + amount);
}

/// Nouveau jour : la journée finie part dans l'historique, le compteur vers la limite repart de zéro.
- (void)rollDay:(NSDate *)now {
    NSString *key = SLDayKey(now);
    if ([_today[@"day"] isEqualToString:key]) return;
    [_history insertObject:[_today copy] atIndex:0];
    while (_history.count > 7) [_history removeLastObject];
    _today = [self emptyDay:now];
    _usedSeconds = 0;
    [self save];
}

#pragma mark Boucle

- (void)start {
    if (_timer) return;
    SLInstallYouTubeSettings(); // au cas où les classes n'étaient pas encore là au chargement
    [self log:[NSString stringWithFormat:@"ShortLimiter %s chargé dans %@ (%@)", SL_VERSION,
               NSBundle.mainBundle.bundleIdentifier,
               [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]]];
    _timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    _timer.tolerance = 0.1;
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification,
                                      UIApplicationWillTerminateNotification]) {
        [nc addObserver:self selector:@selector(save) name:name object:nil];
    }
    [nc addObserver:self selector:@selector(tick) name:UIApplicationDidBecomeActiveNotification object:nil];
    // Preuve que le tweak est chargé
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SLOverlay shared] toast:@"ShortLimiter actif · appui long à 3 doigts : réglages"];
    });
}

- (void)tick {
    NSDate *now = NSDate.date;
    [self rollDay:now];
    if (_blockedUntil && _blockedUntil.timeIntervalSinceNow <= 0) {
        _blockedUntil = nil;
        _usedSeconds = 0;
        [self log:@"Fin du blocage"];
        [self save];
    }

    // Compté uniquement au premier plan, quand un écran Shorts est affiché
    BOOL active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    UIViewController *vc = active ? [self findShorts] : nil;
    BOOL on = vc != nil;
    if (on != _onShorts) {
        _onShorts = on;
        _matchedName = on ? _hitName : nil;
        if (on) [self bump:@"entries" by:1];
        [self log:on ? [NSString stringWithFormat:@"Shorts : OUI (%@)", _matchedName] : @"Shorts : non"];
    }
    _shortsVC = vc;

    if (on && !self.isBlocked && _lastTick) {
        double dt = MIN(MAX([now timeIntervalSinceDate:_lastTick], 0), 2);
        _usedSeconds += dt;
        [self bump:@"seconds" by:dt];
        if (self.dailyEnabled && !_today[@"dailyHit"] && [_today[@"seconds"] doubleValue] >= self.dailyMinutes * 60.0) {
            _today[@"dailyHit"] = @(now.timeIntervalSince1970);
            [self bump:@"blocks" by:1];
            [self log:[NSString stringWithFormat:@"Limite du jour atteinte (%ld min) : Shorts bloqués jusqu'à minuit", (long)self.dailyMinutes]];
            [self save];
        } else if (self.cooldownEnabled && _usedSeconds >= self.limitMinutes * 60.0) {
            _blockedUntil = [now dateByAddingTimeInterval:self.blockMinutes * 60.0];
            [_d setDouble:now.timeIntervalSince1970 forKey:SLKey("blockStart")];
            _usedSeconds = 0;
            [self bump:@"blocks" by:1];
            [self log:[NSString stringWithFormat:@"Limite atteinte : Shorts bloqués %ld min", (long)self.blockMinutes]];
            [self save];
        } else if (++_ticksSinceSave >= 5) {
            [self save];
        }
    }
    _lastTick = now;

    if (on && self.isBlocked) [self tryExit:NO];
    [[SLOverlay shared] refresh];
    [self installGestures];
    if (active && !on) SLDecorateSettings();
}

#pragma mark Détection

- (NSArray<UIWindow *> *)appWindows {
    NSMutableArray *out = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden || [NSStringFromClass(w.class) hasPrefix:@"SL"]) continue;
            [out addObject:w];
        }
    }
    return out;
}

- (BOOL)isVisible:(UIView *)v inWindow:(UIWindow *)w {
    if (v.window != w) return NO;
    for (UIView *p = v; p; p = p.superview) {
        if (p.hidden || p.alpha < 0.01) return NO;
    }
    return YES;
}

- (double)ratio:(UIView *)v inWindow:(UIWindow *)w {
    CGRect r = CGRectIntersection([v convertRect:v.bounds toView:nil], w.bounds);
    double total = w.bounds.size.width * w.bounds.size.height;
    if (CGRectIsNull(r) || total <= 0) return 0;
    return (r.size.width * r.size.height) / total;
}

- (BOOL)name:(NSString *)name matches:(NSArray *)inc excluding:(NSArray *)exc {
    NSString *low = name.lowercaseString;
    BOOL hit = NO;
    for (NSString *p in inc) if ([low containsString:p]) { hit = YES; break; }
    if (!hit) return NO;
    for (NSString *p in exc) if ([low containsString:p]) return NO;
    return YES;
}

- (UIViewController *)findShorts {
    NSArray *inc = SLParse(_includeNames), *exc = SLParse(_excludeNames);
    _hitName = nil;
    if (!inc.count) return nil;
    NSArray<UIWindow *> *windows = [self appWindows];
    // 1. Contrôleurs de vue affichés
    NSHashTable *visited = [NSHashTable weakObjectsHashTable];
    for (UIWindow *w in windows) {
        UIViewController *found = [self scan:w.rootViewController window:w inc:inc exc:exc visited:visited depth:0];
        if (found) {
            _hitName = [self describe:found];
            return found;
        }
    }
    // 2. Grandes vues affichées (certains écrans sont des vues dans un contrôleur générique)
    for (UIWindow *w in windows) {
        double total = w.bounds.size.width * w.bounds.size.height;
        UIView *v = [self scanView:w window:w total:total inc:inc exc:exc depth:0];
        if (v) {
            _hitName = [self describe:v];
            UIResponder *r = v;
            while (r && ![r isKindOfClass:UIViewController.class]) r = r.nextResponder;
            return (UIViewController *)r ?: w.rootViewController;
        }
    }
    return nil;
}

/// Nom de classe, plus l'identifiant d'accessibilité s'il y en a un (aussi pris en compte par la détection).
- (NSString *)describe:(id)obj {
    NSString *name = NSStringFromClass([obj class]);
    UIView *v = [obj isKindOfClass:UIViewController.class] ? ([(UIViewController *)obj isViewLoaded] ? [(UIViewController *)obj view] : nil) : obj;
    NSString *ident = v.accessibilityIdentifier;
    return ident.length ? [NSString stringWithFormat:@"%@ #%@", name, ident] : name;
}

- (UIView *)scanView:(UIView *)v window:(UIWindow *)w total:(double)total inc:(NSArray *)inc exc:(NSArray *)exc depth:(int)depth {
    if (depth > 80 || v.hidden || v.alpha < 0.01 || total <= 0) return nil;
    CGSize sz = v.bounds.size;
    if (sz.width * sz.height >= total * SLMinScreenRatio && v != w) {
        double ratio = [self ratio:v inWindow:w];
        if (ratio >= SLMinScreenRatio) {
            NSString *name = [self describe:v];
            BOOL match = [self name:name matches:inc excluding:exc];
            if (_logEnabled && ![_seen containsObject:name]) {
                [_seen addObject:name];
                [self log:[NSString stringWithFormat:@"Vue affichée : %@ (%.0f %% de l'écran)%@", name, ratio * 100, match ? @" ← correspond" : @""]];
            }
            if (match) return v;
        }
    }
    for (UIView *sub in v.subviews) {
        // Seules les vues assez grandes peuvent contenir un écran Shorts plein écran
        CGSize s2 = sub.bounds.size;
        if (s2.width * s2.height < total * SLMinScreenRatio && !CGSizeEqualToSize(s2, CGSizeZero)) continue;
        UIView *found = [self scanView:sub window:w total:total inc:inc exc:exc depth:depth + 1];
        if (found) return found;
    }
    return nil;
}

- (UIViewController *)scan:(UIViewController *)vc window:(UIWindow *)w inc:(NSArray *)inc exc:(NSArray *)exc
                   visited:(NSHashTable *)visited depth:(int)depth {
    if (!vc || depth > 60 || [visited containsObject:vc]) return nil;
    [visited addObject:vc];
    if (vc.isViewLoaded && [self isVisible:vc.view inWindow:w]) {
        NSString *name = [self describe:vc];
        double ratio = [self ratio:vc.view inWindow:w];
        if (_logEnabled && ratio >= 0.2 && ![_seen containsObject:name]) {
            [_seen addObject:name];
            [self log:[NSString stringWithFormat:@"Écran vu : %@ (%.0f %% de l'écran)%@", name, ratio * 100,
                       [self name:name matches:inc excluding:exc] ? @" ← correspond" : @""]];
        }
        if (ratio >= SLMinScreenRatio && [self name:name matches:inc excluding:exc]) return vc;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = [self scan:child window:w inc:inc exc:exc visited:visited depth:depth + 1];
        if (found) return found;
    }
    return [self scan:vc.presentedViewController window:w inc:inc exc:exc visited:visited depth:depth + 1];
}

#pragma mark Sortie des Shorts pendant le blocage

- (void)leaveShorts {
    [self tryExit:YES];
}

/// Essaie les méthodes de sortie une par une ; après chacune, vérifie ~1 s plus tard qu'on a quitté les Shorts,
/// sinon passe à la suivante. Le journal note ce qui a été tenté.
- (void)tryExit:(BOOL)force {
    if (_exiting) return;
    if (!force && _lastExit && -_lastExit.timeIntervalSinceNow < 4) return;
    _exiting = YES;
    [self exitFromStep:0];
}

- (void)exitFromStep:(NSUInteger)step {
    _lastExit = NSDate.date;
    UIViewController *vc = _shortsVC;
    while (step < 6 && ![self exitStep:step from:vc]) step++;
    if (step >= 6) {
        [self log:@"Sortie : aucune méthode n'a marché"];
        _exiting = NO;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self findShorts]) {
            [self log:[NSString stringWithFormat:@"Sortie réussie (méthode %lu)", (unsigned long)step]];
            self->_exiting = NO;
            [self tick];
            return;
        }
        [self exitFromStep:step + 1];
    });
}

- (BOOL)exitStep:(NSUInteger)step from:(UIViewController *)vc {
    @try {
        switch (step) {
            case 0: { // Short ouvert par-dessus (depuis le fil, une chaîne…) : on le ferme
                UIViewController *top = vc;
                while (top.parentViewController && ![top.parentViewController isKindOfClass:UITabBarController.class]) top = top.parentViewController;
                if (vc && top.presentingViewController) {
                    [self log:[NSString stringWithFormat:@"Sortie 0 : fermeture de %@", NSStringFromClass(top.class)]];
                    [top.presentingViewController dismissViewControllerAnimated:YES completion:nil];
                    return YES;
                }
                return NO;
            }
            case 1: return [self tapPivot:@"FEwhat_to_watch"];   // onglet Accueil de YouTube
            case 2: return [self tapLabelled:@[@"accueil", @"home"]];
            case 3: return [self tapFirstTabByPosition];
            case 4: { // pile de navigation
                UINavigationController *nav = vc.navigationController;
                if (nav && nav.viewControllers.count > 1) {
                    [self log:@"Sortie 4 : retour à la racine de la navigation"];
                    [nav popToRootViewControllerAnimated:YES];
                    return YES;
                }
                return NO;
            }
            default: { // onglets standard
                UITabBarController *tab = vc.tabBarController;
                if (tab && tab.selectedIndex != 0) {
                    [self log:@"Sortie 5 : premier onglet"];
                    tab.selectedIndex = 0;
                    return YES;
                }
                return NO;
            }
        }
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"Sortie %lu : erreur %@", (unsigned long)step, e.reason]];
        return NO;
    }
}

/// Touche le bouton d'un onglet du bas d'après son identifiant YouTube (YTPivotBarItemView.renderer.pivotIdentifier).
- (BOOL)tapPivot:(NSString *)identifier {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    for (UIWindow *w in [self appWindows]) [self collect:w names:SLParse(_exitNames) into:items depth:0];
    NSMutableArray *seen = [NSMutableArray array];
    for (UIView *item in items) {
        NSString *ident = nil;
        @try { ident = [[item valueForKey:@"renderer"] valueForKey:@"pivotIdentifier"]; } @catch (NSException *e) {}
        [seen addObject:ident ?: NSStringFromClass(item.class)];
        if (![ident isEqual:identifier]) continue;
        UIControl *button = nil;
        @try { button = [item valueForKey:@"navigationButton"]; } @catch (NSException *e) {}
        if (![button isKindOfClass:UIControl.class]) button = [self controlIn:item depth:0];
        [self log:[NSString stringWithFormat:@"Sortie 1 : onglet %@ (%@)", identifier, button ? NSStringFromClass(button.class) : @"sans bouton"]];
        if (!button) return NO;
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    [self log:[NSString stringWithFormat:@"Sortie 1 : onglet %@ introuvable (vus : %@)", identifier, [seen componentsJoinedByString:@", "]]];
    return NO;
}

- (void)collectLabelled:(UIView *)v labels:(NSArray *)labels minY:(CGFloat)minY into:(NSMutableArray *)out depth:(int)depth {
    if (depth > 80 || v.hidden || v.alpha < 0.01) return;
    NSString *label = v.accessibilityLabel.lowercaseString;
    if (label.length) {
        CGRect r = [v convertRect:v.bounds toView:nil];
        for (NSString *l in labels) {
            if ([label hasPrefix:l] && CGRectGetMinY(r) >= minY) { [out addObject:v]; return; }
        }
    }
    for (UIView *sub in v.subviews) [self collectLabelled:sub labels:labels minY:minY into:out depth:depth + 1];
}

/// Active une vue ou un ancêtre : bouton (UIControl) ou action d'accessibilité (comme VoiceOver).
- (BOOL)activate:(UIView *)v {
    for (UIView *p = v; p; p = p.superview) {
        if ([p isKindOfClass:UIControl.class] && ((UIControl *)p).enabled) {
            [(UIControl *)p sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        if ([p accessibilityActivate]) return YES;
        if ([p isKindOfClass:UIWindow.class]) break;
    }
    return NO;
}

/// Élément de la barre du bas dont l'étiquette d'accessibilité commence par « Accueil » / « Home ».
- (BOOL)tapLabelled:(NSArray *)labels {
    for (UIWindow *w in [self appWindows]) {
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        [self collectLabelled:w labels:labels minY:w.bounds.size.height - [self tabBarInset] - 10 into:found depth:0];
        for (UIView *v in found) {
            if ([self activate:v]) {
                [self log:[NSString stringWithFormat:@"Sortie 2 : « %@ » (%@)", v.accessibilityLabel, NSStringFromClass(v.class)]];
                return YES;
            }
        }
    }
    return NO;
}

/// Premier onglet à gauche de la barre du bas, trouvé par sa position à l'écran.
- (BOOL)tapFirstTabByPosition {
    CGFloat inset = [self tabBarInset];
    for (UIWindow *w in [self appWindows]) {
        CGFloat h = w.bounds.size.height, safe = w.safeAreaInsets.bottom;
        CGPoint p = CGPointMake(w.bounds.size.width * 0.1, h - inset + (inset - safe) / 2);
        UIView *hit = [w hitTest:p withEvent:nil];
        if (hit && [self activate:hit]) {
            [self log:[NSString stringWithFormat:@"Sortie 3 : toucher en (%.0f, %.0f) sur %@", p.x, p.y, NSStringFromClass(hit.class)]];
            return YES;
        }
    }
    return NO;
}

- (void)collect:(UIView *)v names:(NSArray *)names into:(NSMutableArray *)out depth:(int)depth {
    if (depth > 80 || v.hidden) return;
    NSString *low = NSStringFromClass(v.class).lowercaseString;
    for (NSString *n in names) {
        if ([low containsString:n]) { [out addObject:v]; return; }
    }
    for (UIView *sub in v.subviews) [self collect:sub names:names into:out depth:depth + 1];
}

- (UIControl *)controlIn:(UIView *)v depth:(int)depth {
    if ([v isKindOfClass:UIControl.class]) return (UIControl *)v;
    if (depth > 10) return nil;
    for (UIView *sub in v.subviews) {
        UIControl *c = [self controlIn:sub depth:depth + 1];
        if (c) return c;
    }
    return nil;
}

#pragma mark Geste des réglages

- (void)installGestures {
    for (UIWindow *w in [self appWindows]) {
        BOOL has = NO;
        for (UIGestureRecognizer *g in w.gestureRecognizers) if ([g isKindOfClass:SLGesture.class]) { has = YES; break; }
        if (!has) [w addGestureRecognizer:[SLGesture new]];
    }
}

#pragma mark Journal

- (NSString *)logPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"ShortLimiter-journal.txt"];
}

- (void)log:(NSString *)line {
    if (!_logEnabled) return;
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd HH:mm:ss"; });
    NSString *text = [NSString stringWithFormat:@"%@  %@\n", [f stringFromDate:NSDate.date], line];
    NSString *path = self.logPath;
    NSFileManager *fm = NSFileManager.defaultManager;
    unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize];
    if (size > 300 * 1024) [fm removeItemAtPath:path error:nil];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    [h seekToEndOfFile];
    [h writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

- (NSString *)logText {
    return [NSString stringWithContentsOfFile:self.logPath encoding:NSUTF8StringEncoding error:nil] ?: @"(journal vide)";
}

- (void)clearLog {
    [NSFileManager.defaultManager removeItemAtPath:self.logPath error:nil];
    [_seen removeAllObjects];
}

@end

__attribute__((constructor)) static void SLInit(void) {
    SLInstallYouTubeSettings();
    dispatch_async(dispatch_get_main_queue(), ^{ [[SLCore shared] start]; });
}
