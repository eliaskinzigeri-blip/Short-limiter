// Mode focus NoteFlow : pendant un focus (créneau du jour, rappel avec focus ou puce NFC), l'app entière est
// bloquée, sans raccourci ni automatisation. Le tweak demande l'état du focus à NoteFlow (fonction
// « noteflow-focus », q=state) avec la clé secrète du compte, à chaque retour dans l'app puis toutes les 30 secondes.
// Pendant un focus : un écran opaque couvre toute l'app (aucun bouton), le son est coupé, puis l'app est renvoyée
// à l'écran d'accueil. La fin du focus est gardée en mémoire : le blocage tient aussi sans réseau.
// Liaison : dans NoteFlow (app iPhone › Ma routine › Régler), « Copier le code de liaison » ; le tweak le lit dans
// le presse-papiers au retour dans l'app (tant qu'il n'est pas lié) ou depuis ses réglages.
#import "NFFocus.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static NSString *const NFEndpoint = @"https://ieagkscoaoutrvsgihat.supabase.co/functions/v1/noteflow-focus";
static NSString *const NFPrefix = @"noteflow-focus:";
#define NFKey(k) @"nffocus." k

@interface NFRoot : UIViewController
@end

@implementation NFRoot
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return NO; }
@end

@interface NFFocus : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSString *key;
@property (nonatomic, readonly) BOOL blocked;
@property (nonatomic, readonly) NSString *note;   // dernier message de la vérification (erreur de liaison…)
- (void)start;
- (BOOL)linkFromPasteboard:(BOOL)manual;
- (void)unlink;
- (void)poll;
- (NSString *)untilText;
@end

@implementation NFFocus {
    NSUserDefaults *_d;
    NSTimer *_timer;
    UIWindow *_window;
    UILabel *_title;
    UILabel *_detail;
    UILabel *_countdown;
    double _endsAt;        // fin du focus en cours (secondes depuis 1970), 0 hors focus
    NSDate *_lastPoll;
    BOOL _polling;
    NSDate *_shownSince;   // début de l'affichage du blocage depuis le dernier retour dans l'app
    BOOL _kicked;          // déjà renvoyé à l'écran d'accueil depuis le dernier retour dans l'app
}

+ (instancetype)shared {
    static NFFocus *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NFFocus new]; });
    return f;
}

- (instancetype)init {
    if ((self = [super init])) {
        _d = NSUserDefaults.standardUserDefaults;
        _endsAt = [_d doubleForKey:NFKey("endsAt")];
    }
    return self;
}

- (NSString *)key { return [_d stringForKey:NFKey("key")] ?: @""; }
- (BOOL)blocked { return self.key.length > 0 && _endsAt > NSDate.date.timeIntervalSince1970; }

- (NSString *)appName {
    NSBundle *b = NSBundle.mainBundle;
    return [b objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [b objectForInfoDictionaryKey:@"CFBundleName"] ?: @"Cette app";
}

- (NSString *)untilText {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
    f.dateFormat = @"H'h'mm";
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:_endsAt]];
}

- (void)start {
    if (_timer) return;
    _timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    _timer.tolerance = 0.1;
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(activated)
                                               name:UIApplicationDidBecomeActiveNotification object:nil];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self activated];
}

- (void)activated {
    _kicked = NO;
    _shownSince = nil;
    if (!self.key.length) [self linkFromPasteboard:NO];
    [self poll];
    [self refresh];
}

- (void)tick {
    BOOL active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (active && self.key.length && (!_lastPoll || -_lastPoll.timeIntervalSinceNow >= (self.blocked ? 20 : 30))) [self poll];
    [self refresh];
    if (!self.blocked) return;
    [self silence];
    // Le message reste trois secondes, puis l'app est renvoyée à l'écran d'accueil (une fois par ouverture)
    if (active && !_kicked && _shownSince && -_shownSince.timeIntervalSinceNow >= 3) {
        _kicked = YES;
        UIApplication *app = UIApplication.sharedApplication;
        SEL suspend = NSSelectorFromString(@"suspend");
        if ([app respondsToSelector:suspend]) ((void (*)(id, SEL))objc_msgSend)(app, suspend);
    }
}

/// Coupe le son de l'app : désactiver la session audio arrête les lecteurs en cours.
- (void)silence {
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

#pragma mark État du focus (NoteFlow)

- (void)poll {
    NSString *key = self.key;
    if (!key.length || _polling) return;
    NSString *k = [key stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?q=state&k=%@", NFEndpoint, k]];
    if (!url) return;
    _polling = YES;
    _lastPoll = NSDate.date;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        NSInteger status = [res isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)res).statusCode : 0;
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *json = [obj isKindOfClass:NSDictionary.class] ? obj : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_polling = NO;
            if (![key isEqualToString:self.key]) return;  // délié ou relié entre-temps
            if (status == 200 && json) {
                BOOL on = [json[@"active"] respondsToSelector:@selector(boolValue)] && [json[@"active"] boolValue];
                double end = [json[@"endsAt"] respondsToSelector:@selector(doubleValue)] ? [json[@"endsAt"] doubleValue] / 1000.0 : 0;
                [self setEndsAt:on ? end : 0];
                self->_note = nil;
            } else if (status == 404 || status == 400) {
                // Clé inconnue de NoteFlow : pas de blocage, à relier
                [self setEndsAt:0];
                self->_note = @"Code de liaison refusé par NoteFlow : copie-le à nouveau.";
            }
            // Pas de réseau ou serveur en panne : la fin de focus gardée en mémoire continue de s'appliquer
            [self refresh];
        });
    }] resume];
}

- (void)setEndsAt:(double)end {
    if (end == _endsAt) return;
    _endsAt = end;
    [_d setDouble:end forKey:NFKey("endsAt")];
}

#pragma mark Liaison

- (BOOL)linkFromPasteboard:(BOOL)manual {
    UIPasteboard *pb = UIPasteboard.generalPasteboard;
    if (!manual) {
        // Lecture automatique : une seule fois par contenu du presse-papiers (iOS affiche un avis à chaque lecture)
        if (!pb.hasStrings) return NO;
        NSInteger count = pb.changeCount;
        if ([_d objectForKey:NFKey("pbCount")] && count == [_d integerForKey:NFKey("pbCount")]) return NO;
        [_d setInteger:count forKey:NFKey("pbCount")];
    }
    NSString *text = [pb.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![text hasPrefix:NFPrefix]) return NO;
    NSString *key = [text substringFromIndex:NFPrefix.length];
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet];
    if (key.length < 20 || key.length > 120 || [key rangeOfCharacterFromSet:bad].location != NSNotFound) return NO;
    [_d setObject:key forKey:NFKey("key")];
    pb.string = @"";  // la clé ne reste pas dans le presse-papiers
    [_d setInteger:pb.changeCount forKey:NFKey("pbCount")];
    _note = nil;
    _lastPoll = nil;
    [self poll];
    if (!manual) [self announce:[NSString stringWithFormat:@"%@ est lié à NoteFlow : il sera bloqué pendant tes focus.", self.appName]];
    return YES;
}

- (void)unlink {
    [_d removeObjectForKey:NFKey("key")];
    [self setEndsAt:0];
    _note = nil;
    [self refresh];
}

- (UIWindowScene *)scene {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!fallback) fallback = (UIWindowScene *)s;
    }
    return fallback;
}

- (void)announce:(NSString *)text {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *top = nil;
        for (UIWindow *w in [self scene].windows) {
            if (w == self->_window || !w.isKeyWindow) continue;
            top = w.rootViewController;
        }
        while (top.presentedViewController) top = top.presentedViewController;
        if (!top || [top isKindOfClass:UIAlertController.class]) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Mode focus NoteFlow" message:text preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

#pragma mark Écran de blocage

- (UILabel *)label:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (BOOL)ensureWindow {
    UIWindowScene *scene = [self scene];
    if (!scene) return NO;
    if (_window && _window.windowScene == scene) return YES;
    _window.hidden = YES;
    _window = [[UIWindow alloc] initWithWindowScene:scene];
    _window.windowLevel = UIWindowLevelAlert + 1000;  // au-dessus de tout, y compris des fenêtres des tweaks
    _window.backgroundColor = UIColor.blackColor;
    NFRoot *root = [NFRoot new];
    _window.rootViewController = root;
    UIView *v = root.view;
    v.backgroundColor = UIColor.blackColor;

    UILabel *kick = [self label:13 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:1 alpha:0.55]];
    kick.text = @"NOTEFLOW";
    _title = [self label:30 weight:UIFontWeightBold color:UIColor.whiteColor];
    _title.text = @"Mode focus";
    _countdown = [self label:64 weight:UIFontWeightBold color:UIColor.whiteColor];
    _countdown.font = [UIFont monospacedDigitSystemFontOfSize:64 weight:UIFontWeightBold];
    _countdown.adjustsFontSizeToFitWidth = YES;
    _countdown.minimumScaleFactor = 0.5;
    _countdown.numberOfLines = 1;
    _detail = [self label:17 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.75]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[kick, _title, _countdown, _detail]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-28],
    ]];
    return YES;
}

- (void)refresh {
    BOOL blocked = self.blocked;
    if (!blocked) {
        if (_window && !_window.hidden) _window.hidden = YES;
        _shownSince = nil;
        if (_endsAt > 0) { [self setEndsAt:0]; _lastPoll = nil; }  // focus fini : l'état est redemandé tout de suite
        return;
    }
    if (![self ensureWindow]) return;
    if (_window.hidden) {
        _window.hidden = NO;
        // Clavier et saisie en cours fermés : plus rien n'est utilisable derrière l'écran
        [UIApplication.sharedApplication sendAction:@selector(resignFirstResponder) to:nil from:nil forEvent:nil];
    }
    if (!_shownSince) _shownSince = NSDate.date;
    long left = (long)MAX(0, ceil(_endsAt - NSDate.date.timeIntervalSince1970));
    _countdown.text = left >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", left / 3600, (left % 3600) / 60, left % 60]
                                   : [NSString stringWithFormat:@"%ld:%02ld", left / 60, left % 60];
    _detail.text = [NSString stringWithFormat:@"%@ est bloqué jusqu’à %@.\nReviens après ton focus.", self.appName, self.untilText];
}

@end

NSString *NFFocusStatus(void) {
    NFFocus *f = NFFocus.shared;
    if (!f.key.length) return @"Non lié";
    if (f.blocked) return [NSString stringWithFormat:@"Bloqué jusqu’à %@", f.untilText];
    return f.note ? @"À relier" : @"Lié";
}

void NFFocusPresentSettings(UIViewController *from) {
    NFFocus *f = NFFocus.shared;
    BOOL linked = f.key.length > 0;
    NSString *msg = linked
        ? [NSString stringWithFormat:@"%@\n\nPendant un focus NoteFlow (créneau, rappel avec focus ou puce NFC), l’app entière est bloquée jusqu’à la fin.",
           f.note ?: @"Lié à ton compte NoteFlow."]
        : @"Dans NoteFlow sur ton iPhone : Ma routine › Régler › « Copier le code de liaison ». Reviens ensuite ici et touche « Coller le code de liaison ».";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Mode focus NoteFlow" message:msg preferredStyle:UIAlertControllerStyleAlert];
    __weak UIViewController *weakFrom = from;
    [a addAction:[UIAlertAction actionWithTitle:@"Coller le code de liaison" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        BOOL ok = [f linkFromPasteboard:YES];
        UIAlertController *r = [UIAlertController alertControllerWithTitle:ok ? @"Lié à NoteFlow" : @"Code introuvable"
            message:ok ? @"L’app sera bloquée pendant tes focus." : @"Le presse-papiers ne contient pas de code de liaison NoteFlow. Copie-le d’abord dans NoteFlow."
            preferredStyle:UIAlertControllerStyleAlert];
        [r addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [weakFrom presentViewController:r animated:YES completion:nil];
    }]];
    if (linked) {
        [a addAction:[UIAlertAction actionWithTitle:@"Délier de NoteFlow" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [f unlink]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Fermer" style:UIAlertActionStyleCancel handler:nil]];
    [from presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor)) static void NFFocusInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[NFFocus shared] start]; });
}
