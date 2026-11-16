// SoundMatch : trouve ton égaliseur dans Spotify par comparaisons successives.
// Tweak (.dylib) chargé par LiveContainer dans l'app que l'utilisateur installe lui-même. Aucun code de Spotify ici :
// le tweak applique son propre égaliseur (6 bandes, mêmes fréquences que celui de Spotify) au son envoyé à la sortie
// audio d'iOS, via une notification de rendu posée sur l'unité de sortie (RemoteIO). Rien n'est enregistré ni copié.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <objc/message.h>
#import "SMRebind.h"

#ifndef SM_VERSION
#define SM_VERSION "dev"
#endif

#define SMKey(x) (@"SoundMatch." x)
#define SM_BANDS 6
#define SM_MAXCH 8

static const double SMFreqs[SM_BANDS] = {60, 150, 400, 1000, 2400, 15000};
static NSString *SMBandName(int i) {
    return @[@"60 Hz", @"150 Hz", @"400 Hz", @"1 kHz", @"2,4 kHz", @"15 kHz"][i];
}

#pragma mark Journal

static NSString *SMLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"SoundMatch-journal.txt"];
}

static void SMLog(NSString *line) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd HH:mm:ss"; });
    NSString *text = [NSString stringWithFormat:@"%@  %@\n", [f stringFromDate:NSDate.date], line];
    NSString *path = SMLogPath();
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([[fm attributesOfItemAtPath:path error:nil] fileSize] > 300 * 1024) [fm removeItemAtPath:path error:nil];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    [h seekToEndOfFile];
    [h writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static void SMLogMain(NSString *line) {
    dispatch_async(dispatch_get_main_queue(), ^{ SMLog(line); });
}

#pragma mark Égaliseur (fil audio)

typedef struct { float b0, b1, b2, a1, a2; } SMBiquad;

typedef struct {
    AudioUnit unit;
    AudioStreamBasicDescription fmt;
    int haveFmt, needFmt, badFmt, loggedFmt;
    int version;
    SMBiquad bq[SM_BANDS];
    float pre;
    float z[SM_MAXCH][SM_BANDS][2];
} SMUnit;

static float gGains[SM_BANDS];          // gains appliqués (dB)
static volatile int gVersion = 1;       // change à chaque nouveau réglage
static volatile int gActive = 0;        // égaliseur appliqué (test en cours ou réglage activé)
static volatile double gLastRender = 0; // dernier passage du son (CFAbsoluteTime)

static void SMSetGains(const float *g, BOOL active) {
    for (int i = 0; i < SM_BANDS; i++) gGains[i] = g[i];
    gActive = active;
    __sync_fetch_and_add(&gVersion, 1);
}

static void SMDesign(SMUnit *u) {
    double fs = u->fmt.mSampleRate > 0 ? u->fmt.mSampleRate : 44100;
    float maxGain = 0;
    for (int i = 0; i < SM_BANDS; i++) {
        double g = gGains[i];
        if (g > maxGain) maxGain = (float)g;
        double A = pow(10.0, g / 40.0);
        double w0 = 2.0 * M_PI * fmin(SMFreqs[i], fs * 0.45) / fs;
        double c = cos(w0), s = sin(w0);
        double b0, b1, b2, a0, a1, a2;
        if (i == 0 || i == SM_BANDS - 1) {
            double alpha = s / 2.0 * sqrt(2.0), sq = 2.0 * sqrt(A) * alpha;
            if (i == 0) { // plateau grave
                b0 = A * ((A + 1) - (A - 1) * c + sq);
                b1 = 2 * A * ((A - 1) - (A + 1) * c);
                b2 = A * ((A + 1) - (A - 1) * c - sq);
                a0 = (A + 1) + (A - 1) * c + sq;
                a1 = -2 * ((A - 1) + (A + 1) * c);
                a2 = (A + 1) + (A - 1) * c - sq;
            } else { // plateau aigu
                b0 = A * ((A + 1) + (A - 1) * c + sq);
                b1 = -2 * A * ((A - 1) + (A + 1) * c);
                b2 = A * ((A + 1) + (A - 1) * c - sq);
                a0 = (A + 1) - (A - 1) * c + sq;
                a1 = 2 * ((A - 1) - (A + 1) * c);
                a2 = (A + 1) - (A - 1) * c - sq;
            }
        } else { // cloche, Q = 1
            double alpha = s / 2.0;
            b0 = 1 + alpha * A; b1 = -2 * c; b2 = 1 - alpha * A;
            a0 = 1 + alpha / A; a1 = -2 * c; a2 = 1 - alpha / A;
        }
        u->bq[i] = (SMBiquad){(float)(b0 / a0), (float)(b1 / a0), (float)(b2 / a0), (float)(a1 / a0), (float)(a2 / a0)};
    }
    u->pre = (float)pow(10.0, -maxGain / 20.0); // évite la saturation quand on monte une bande
    u->version = gVersion;
}

static inline float SMRun(SMUnit *u, int ch, float x) {
    for (int b = 0; b < SM_BANDS; b++) {
        SMBiquad q = u->bq[b];
        float *z = u->z[ch][b];
        float y = q.b0 * x + z[0];
        z[0] = q.b1 * x - q.a1 * y + z[1];
        z[1] = q.b2 * x - q.a2 * y;
        x = y;
    }
    return x * u->pre;
}

static void SMProcessBuffer(SMUnit *u, void *data, UInt32 frames, int channels, int stride, int firstCh, BOOL isFloat) {
    for (int c = 0; c < channels && firstCh + c < SM_MAXCH; c++) {
        int ch = firstCh + c;
        if (isFloat) {
            float *p = (float *)data + c;
            for (UInt32 i = 0; i < frames; i++, p += stride) *p = SMRun(u, ch, *p);
        } else {
            SInt16 *p = (SInt16 *)data + c;
            for (UInt32 i = 0; i < frames; i++, p += stride) {
                float y = SMRun(u, ch, *p / 32768.0f) * 32767.0f;
                *p = (SInt16)(y > 32767.0f ? 32767.0f : (y < -32768.0f ? -32768.0f : y));
            }
        }
    }
}

static OSStatus SMNotify(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *io) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !io) return noErr;
    gLastRender = CFAbsoluteTimeGetCurrent();
    SMUnit *u = refCon;
    if (u->needFmt || !u->haveFmt) {
        UInt32 size = sizeof(u->fmt);
        u->haveFmt = AudioUnitGetProperty(u->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &u->fmt, &size) == noErr;
        u->needFmt = 0;
        UInt32 fl = u->fmt.mFormatFlags;
        BOOL isFloat = (fl & kAudioFormatFlagIsFloat) && u->fmt.mBitsPerChannel == 32;
        BOOL isInt16 = (fl & kAudioFormatFlagIsSignedInteger) && u->fmt.mBitsPerChannel == 16;
        u->badFmt = !u->haveFmt || u->fmt.mFormatID != kAudioFormatLinearPCM || !(isFloat || isInt16);
        u->version = 0;
        if (!u->loggedFmt) {
            u->loggedFmt = 1;
            AudioStreamBasicDescription f = u->fmt;
            SMLogMain([NSString stringWithFormat:@"Son : %.0f Hz, %u canaux, %u bits %@, %@%@", f.mSampleRate, (unsigned)f.mChannelsPerFrame,
                       (unsigned)f.mBitsPerChannel, (fl & kAudioFormatFlagIsFloat) ? @"flottant" : @"entier",
                       (fl & kAudioFormatFlagIsNonInterleaved) ? @"canaux séparés" : @"canaux entrelacés",
                       u->badFmt ? @" — format non pris en charge" : @""]);
        }
    }
    if (!gActive || u->badFmt) return noErr;
    if (u->version != gVersion) SMDesign(u);
    BOOL isFloat = (u->fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    if (u->fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
        for (UInt32 b = 0; b < io->mNumberBuffers; b++)
            SMProcessBuffer(u, io->mBuffers[b].mData, frames, 1, 1, (int)b, isFloat);
    } else if (io->mNumberBuffers > 0) {
        int ch = (int)io->mBuffers[0].mNumberChannels;
        SMProcessBuffer(u, io->mBuffers[0].mData, frames, ch, ch, 0, isFloat);
    }
    return noErr;
}

#pragma mark Branchement sur la sortie audio

static NSMutableSet<NSValue *> *gAttached;
static NSUInteger gAttachedCount;

static BOOL SMIsOutputUnit(AudioUnit unit) {
    AudioComponentDescription d = {0};
    AudioComponent comp = AudioComponentInstanceGetComponent(unit);
    return comp && AudioComponentGetDescription(comp, &d) == noErr && d.componentType == kAudioUnitType_Output;
}

static void SMAttach(AudioUnit unit, NSString *how) {
    if (!unit || !SMIsOutputUnit(unit)) return;
    @synchronized (NSNull.null) {
        if (!gAttached) gAttached = [NSMutableSet set];
        NSValue *key = [NSValue valueWithPointer:unit];
        if ([gAttached containsObject:key]) {
            return;
        }
        [gAttached addObject:key];
        SMUnit *u = calloc(1, sizeof(SMUnit));
        u->unit = unit;
        u->needFmt = 1;
        OSStatus st = AudioUnitAddRenderNotify(unit, SMNotify, u);
        gAttachedCount++;
        SMLogMain([NSString stringWithFormat:@"Sortie audio trouvée (%@) : notification %@", how, st == noErr ? @"posée" : [NSString stringWithFormat:@"refusée (%d)", (int)st]]);
    }
}

static OSStatus (*origInstanceNew)(AudioComponent, AudioComponentInstance *);
static OSStatus SMInstanceNew(AudioComponent comp, AudioComponentInstance *out) {
    OSStatus st = origInstanceNew(comp, out);
    if (st == noErr && out && *out) SMAttach(*out, @"création");
    return st;
}

static OSStatus (*origOutputStart)(AudioUnit);
static OSStatus SMOutputStart(AudioUnit unit) {
    SMAttach(unit, @"démarrage");
    return origOutputStart(unit);
}

static OSStatus (*origGraphStart)(AUGraph);
static OSStatus SMGraphStart(AUGraph graph) {
    UInt32 n = 0;
    if (AUGraphGetNodeCount(graph, &n) == noErr) {
        for (UInt32 i = 0; i < n; i++) {
            AUNode node;
            AudioUnit unit = NULL;
            if (AUGraphGetIndNode(graph, i, &node) == noErr && AUGraphNodeInfo(graph, node, NULL, &unit) == noErr) SMAttach(unit, @"graphe");
        }
    }
    return origGraphStart(graph);
}

static void SMHookAudio(void) {
    origInstanceNew = dlsym(RTLD_DEFAULT, "AudioComponentInstanceNew");
    origOutputStart = dlsym(RTLD_DEFAULT, "AudioOutputUnitStart");
    origGraphStart = dlsym(RTLD_DEFAULT, "AUGraphStart");
    SMRebinding r[3];
    size_t n = 0;
    if (origInstanceNew) r[n++] = (SMRebinding){"AudioComponentInstanceNew", (void *)SMInstanceNew};
    if (origOutputStart) r[n++] = (SMRebinding){"AudioOutputUnitStart", (void *)SMOutputStart};
    if (origGraphStart) r[n++] = (SMRebinding){"AUGraphStart", (void *)SMGraphStart};
    SMRebindSymbols(r, n);

    // AVAudioEngine : unité de sortie du moteur au démarrage
    Method m = class_getInstanceMethod(AVAudioEngine.class, @selector(startAndReturnError:));
    if (m) {
        BOOL (*orig)(id, SEL, NSError **) = (void *)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^BOOL(AVAudioEngine *self, NSError **err) {
            BOOL ok = orig(self, @selector(startAndReturnError:), err);
            AudioUnit unit = self.outputNode.audioUnit;
            SMAttach(unit, @"AVAudioEngine");
            return ok;
        }));
    }
}

#pragma mark Réglages enregistrés

static void SMLoadSaved(float *g) {
    NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:SMKey("gains")];
    for (int i = 0; i < SM_BANDS; i++) g[i] = i < (int)a.count ? [a[i] floatValue] : 0;
}

static void SMSave(const float *g) {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < SM_BANDS; i++) [a addObject:@(g[i])];
    [NSUserDefaults.standardUserDefaults setObject:a forKey:SMKey("gains")];
}

static BOOL SMEnabled(void) { return [NSUserDefaults.standardUserDefaults boolForKey:SMKey("enabled")]; }

static void SMApplySaved(void) {
    float g[SM_BANDS];
    SMLoadSaved(g);
    SMSetGains(g, SMEnabled());
}

static NSString *SMDescribe(const float *g) {
    NSMutableArray *lines = [NSMutableArray array];
    for (int i = 0; i < SM_BANDS; i++) [lines addObject:[NSString stringWithFormat:@"%@ : %+.0f dB", SMBandName(i), g[i]]];
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *SMShortDesc(id v) {
    NSString *d = [[[v description] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    return d.length > 300 ? [[d substringToIndex:300] stringByAppendingString:@"…"] : d;
}

#pragma mark Égaliseur de Spotify (préférences et modèle SPTEqualizerModel)

static NSString *const SMSpotifyValuesSuffix = @".com.spotify.feature.equalizer.values";
static __weak id SMSpotifyModel;

/// Préfixes des clés de l'égaliseur de Spotify (un par compte : « <id>.com.spotify.feature.equalizer. »).
static NSArray<NSString *> *SMSpotifyPrefixes(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in NSUserDefaults.standardUserDefaults.dictionaryRepresentation.allKeys) {
        if ([key hasSuffix:SMSpotifyValuesSuffix]) [out addObject:[key substringToIndex:key.length - @"values".length]];
    }
    return out;
}

static void SMHookSpotifyModel(void) {
    Class c = NSClassFromString(@"SPTEqualizerModel");
    if (!c) { SMLog(@"Égaliseur Spotify : modèle introuvable"); return; }
    SEL init = @selector(initWithLocalSettings:audioDriverController:connectManager:remoteConfigurationProperties:preferences:);
    Method m = class_getInstanceMethod(c, init);
    if (m) {
        id (*orig)(id, SEL, id, id, id, id, id) = (void *)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^id(id self, id a, id b, id c2, id d, id e) {
            id r = orig(self, init, a, b, c2, d, e);
            SMSpotifyModel = r;
            return r;
        }));
    }
    Method mv = class_getInstanceMethod(c, @selector(setValues:));
    if (mv) {
        void (*orig)(id, SEL, id) = (void *)method_getImplementation(mv);
        method_setImplementation(mv, imp_implementationWithBlock(^(id self, id v) {
            SMSpotifyModel = self;
            orig(self, @selector(setValues:), v);
        }));
    }
}

static void SMSetSpotifyOn(BOOL on) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *prefix in SMSpotifyPrefixes()) [d setBool:on forKey:[prefix stringByAppendingString:@"on"]];
    id model = SMSpotifyModel;
    if ([model respondsToSelector:@selector(setOn:)]) ((void (*)(id, SEL, BOOL))objc_msgSend)(model, @selector(setOn:), on);
}

static BOOL SMSpotifyIsOn(void) {
    for (NSString *prefix in SMSpotifyPrefixes())
        if ([NSUserDefaults.standardUserDefaults boolForKey:[prefix stringByAppendingString:@"on"]]) return YES;
    return NO;
}

/// Écrit le réglage dans l'égaliseur de Spotify (valeurs de −1 à +1 pour −12 à +12 dB) et l'allume.
static BOOL SMApplyToSpotify(const float *g) {
    NSMutableArray *vals = [NSMutableArray array];
    for (int i = 0; i < SM_BANDS; i++) [vals addObject:@(fmax(-1.0, fmin(1.0, g[i] / 12.0)))];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray *prefixes = SMSpotifyPrefixes();
    for (NSString *prefix in prefixes) {
        [d setObject:vals forKey:[prefix stringByAppendingString:@"values"]];
        [d setBool:YES forKey:[prefix stringByAppendingString:@"on"]];
        [d removeObjectForKey:[prefix stringByAppendingString:@"persistedPresetName"]]; // réglage personnalisé
    }
    id model = SMSpotifyModel;
    BOOL live = NO;
    if ([model respondsToSelector:@selector(setValues:)]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(model, @selector(setValues:), vals);
            if ([model respondsToSelector:@selector(setOn:)]) ((void (*)(id, SEL, BOOL))objc_msgSend)(model, @selector(setOn:), YES);
            live = YES;
        } @catch (NSException *e) {
            SMLog([NSString stringWithFormat:@"Égaliseur Spotify : erreur du modèle (%@)", e.reason]);
        }
    }
    SMLog([NSString stringWithFormat:@"Égaliseur Spotify : réglage écrit (%lu compte(s), modèle %@) %@", (unsigned long)prefixes.count,
           live ? @"mis à jour" : @"pas encore chargé", vals]);
    if ([model respondsToSelector:@selector(bands)]) {
        id bands = ((id (*)(id, SEL))objc_msgSend)(model, @selector(bands));
        SMLog([NSString stringWithFormat:@"Égaliseur Spotify : bandes %@", SMShortDesc(bands)]);
    }
    return prefixes.count > 0 || live;
}

#pragma mark Étapes du test

typedef struct { const char *name; int bands[3]; int count; float delta; } SMStep;

static const SMStep SMSteps[] = {
    {"Basses",            {0, 1},    2, 6},
    {"Aigus",             {5},       1, 6},
    {"Médiums",           {2, 3},    2, 5},
    {"Présence",          {4},       1, 5},
    {"Sub-basses",        {0},       1, 3},
    {"Bas-médiums",       {1, 2},    2, 3},
    {"Haut du spectre",   {4, 5},    2, 3},
    {"Voix",              {3},       1, 3},
    {"Basses (affinage)", {0, 1},    2, 2},
};
static const int SMStepCount = sizeof(SMSteps) / sizeof(SMSteps[0]);

static void SMDiscoverSpotifyEqualizer(void);

#pragma mark Interface

@interface SMWindow : UIWindow
@end

@implementation SMWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}
@end

@interface SMRoot : UIViewController
@end

@implementation SMRoot
- (void)loadView { self.view = [UIView new]; self.view.backgroundColor = UIColor.clearColor; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

typedef NS_ENUM(NSInteger, SMMode) { SMModeIntro, SMModeStep, SMModeResult };

@interface SMCore : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SMCore {
    SMWindow *_window;
    UIView *_card;
    UILabel *_title, *_subtitle, *_status, *_toast;
    UIStackView *_choices;
    NSArray<UIButton *> *_choiceButtons;
    UIButton *_primary, *_secondary;
    SMMode _mode;
    BOOL _testing;
    int _step;
    float _base[SM_BANDS];      // réglage retenu jusqu'ici
    float _before[SM_BANDS];    // réglage d'avant le test (rétabli si on ferme)
    BOOL _beforeActive;
    BOOL _spotifyWasOn;
    float _variants[3][SM_BANDS];
    int _selected;
    NSTimer *_timer;
    NSDate *_toastUntil;
    UIButton *_settingsButton;
    BOOL _inSettings;
    NSMutableSet<NSString *> *_seenScreens;
    NSUInteger _loggedAttached;
}

+ (instancetype)shared {
    static SMCore *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [SMCore new]; });
    return c;
}

static UIWindowScene *SMScene(void) {
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
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (!w.hidden && ![w isKindOfClass:SMWindow.class]) [out addObject:w];
    }
    return out;
}

static UIButton *SMButton(NSString *title, UIColor *bg, UIColor *fg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 22;
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    return b;
}

static UIColor *SMGreen(void) { return [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:1]; }

- (BOOL)ensureWindow {
    UIWindowScene *scene = SMScene();
    if (!scene) return NO;
    if (_window && _window.windowScene == scene) return YES;
    _window = [[SMWindow alloc] initWithWindowScene:scene];
    _window.windowLevel = UIWindowLevelAlert + 1;
    _window.backgroundColor = UIColor.clearColor;
    _window.rootViewController = [SMRoot new];
    UIView *root = _window.rootViewController.view;

    _toast = [UILabel new];
    _toast.translatesAutoresizingMaskIntoConstraints = NO;
    _toast.backgroundColor = SMGreen();
    _toast.textColor = UIColor.blackColor;
    _toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _toast.textAlignment = NSTextAlignmentCenter;
    _toast.layer.cornerRadius = 12;
    _toast.clipsToBounds = YES;
    _toast.hidden = YES;
    [root addSubview:_toast];

    // Bouton affiché dans les Paramètres de Spotify : ouvre le menu de SoundMatch
    _settingsButton = SMButton(@"🎚 SoundMatch : calibrer mon égaliseur", SMGreen(), UIColor.blackColor);
    _settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    _settingsButton.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 18);
    _settingsButton.layer.shadowColor = UIColor.blackColor.CGColor;
    _settingsButton.layer.shadowOpacity = 0.4;
    _settingsButton.layer.shadowRadius = 8;
    _settingsButton.hidden = YES;
    [_settingsButton addTarget:self action:@selector(openMenu) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:_settingsButton];

    _card = [UIView new];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.98];
    _card.layer.cornerRadius = 20;
    _card.hidden = YES;
    [root addSubview:_card];

    _title = [UILabel new];
    _title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    _title.textColor = UIColor.whiteColor;
    _title.numberOfLines = 0;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithWhite:0.6 alpha:1];
    [close addTarget:self action:@selector(cancelTest) forControlEvents:UIControlEventTouchUpInside];
    [close setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[_title, close]];
    header.alignment = UIStackViewAlignmentTop;

    _subtitle = [UILabel new];
    _subtitle.font = [UIFont systemFontOfSize:14];
    _subtitle.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    _subtitle.numberOfLines = 0;

    _status = [UILabel new];
    _status.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _status.numberOfLines = 0;

    NSMutableArray *buttons = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        UIButton *b = SMButton(@[@"A", @"B", @"C"][i], [UIColor colorWithWhite:0.2 alpha:1], UIColor.whiteColor);
        b.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        b.tag = i;
        [b addTarget:self action:@selector(choose:) forControlEvents:UIControlEventTouchUpInside];
        [buttons addObject:b];
    }
    _choiceButtons = buttons;
    _choices = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    _choices.distribution = UIStackViewDistributionFillEqually;
    _choices.spacing = 10;

    _primary = SMButton(@"Commencer", SMGreen(), UIColor.blackColor);
    [_primary addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    _secondary = SMButton(@"Recommencer", [UIColor colorWithWhite:0.2 alpha:1], UIColor.whiteColor);
    [_secondary addTarget:self action:@selector(restart) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, _subtitle, _status, _choices, _primary, _secondary]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:18 afterView:_status];
    [_card addSubview:stack];

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_toast.topAnchor constraintEqualToAnchor:safe.topAnchor constant:40],
        [_toast.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_toast.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-40],
        [_toast.heightAnchor constraintGreaterThanOrEqualToConstant:40],
        [_settingsButton.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [_settingsButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-80],
        [_card.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [_card.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [_card.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
        [_card.widthAnchor constraintLessThanOrEqualToConstant:520],
        [stack.topAnchor constraintEqualToAnchor:_card.topAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-18],
    ]];
    return YES;
}

- (void)start {
    if (_timer) return;
    SMLog([NSString stringWithFormat:@"SoundMatch %s chargé dans %@ (%@)", SM_VERSION, NSBundle.mainBundle.bundleIdentifier,
           [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]]);
    SMApplySaved();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SMDiscoverSpotifyEqualizer();
    });
    _timer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self toast:@"   SoundMatch actif · appui long à 3 doigts   "];
    });
}

- (void)toast:(NSString *)text {
    if (![self ensureWindow]) return;
    _toast.text = text;
    _toastUntil = [NSDate dateWithTimeIntervalSinceNow:4];
    [self refresh];
}

/// Écrans de Spotify affichés (noms de classes des contrôleurs visibles).
- (void)collectScreens:(UIViewController *)vc into:(NSMutableArray *)out depth:(int)depth {
    if (!vc || depth > 40) return;
    if (vc.isViewLoaded && vc.view.window && !vc.view.hidden) [out addObject:NSStringFromClass(vc.class)];
    for (UIViewController *c in vc.childViewControllers) [self collectScreens:c into:out depth:depth + 1];
    if (vc.presentedViewController.presentingViewController == vc) [self collectScreens:vc.presentedViewController into:out depth:depth + 1];
}

- (BOOL)settingsVisible {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (UIWindow *w in [self appWindows]) [self collectScreens:w.rootViewController into:names depth:0];
    if (!_seenScreens) _seenScreens = [NSMutableSet set];
    BOOL found = NO;
    for (NSString *n in names) {
        if (![_seenScreens containsObject:n]) {
            [_seenScreens addObject:n];
            SMLog([NSString stringWithFormat:@"Écran vu : %@", n]);
        }
        NSString *low = n.lowercaseString;
        if ([low containsString:@"setting"] || [low containsString:@"playback"] || [low containsString:@"equaliz"] || [low containsString:@"preference"])
            found = YES;
    }
    return found;
}

- (void)openMenu {
    UIViewController *top = [self topController];
    if (top) [self showMenuFrom:top];
}

- (void)tick {
    [self installGestures];
    _inSettings = !_testing && [self settingsVisible];
    if (gAttachedCount == 0 && !_loggedAttached && gLastRender == 0) {
        // rien encore : normal tant qu'aucune musique n'a été lancée
    }
    [self refresh];
}

- (void)refresh {
    BOOL toast = _toastUntil && _toastUntil.timeIntervalSinceNow > 0;
    if (!_testing && !toast && !_inSettings) {
        _window.hidden = YES;
        return;
    }
    if (![self ensureWindow]) return;
    _toast.hidden = !toast;
    _settingsButton.hidden = !_inSettings || _testing;
    _card.hidden = !_testing;
    if (_testing) {
        BOOL sound = CFAbsoluteTimeGetCurrent() - gLastRender < 1.5;
        if (sound) {
            _status.text = @"🔊 Son de Spotify détecté";
            _status.textColor = SMGreen();
        } else {
            _status.text = gAttachedCount ? @"⏸ Lance la lecture dans Spotify" : @"⏸ Lance la lecture dans Spotify (sortie audio pas encore trouvée)";
            _status.textColor = [UIColor colorWithRed:1 green:0.75 blue:0.3 alpha:1];
        }
    }
    _window.hidden = NO;
}

#pragma mark Déroulement du test

- (void)openTest {
    float saved[SM_BANDS];
    SMLoadSaved(saved);
    memcpy(_before, saved, sizeof(_before));
    _beforeActive = SMEnabled();
    _spotifyWasOn = SMSpotifyIsOn();
    if (_spotifyWasOn) SMSetSpotifyOn(NO); // le test s'entend sans l'égaliseur de Spotify
    float flat[SM_BANDS] = {0};
    memcpy(_base, flat, sizeof(_base));
    SMSetGains(_base, YES);
    _testing = YES;
    _mode = SMModeIntro;
    [self ensureWindow];
    [self render];
    SMLog(@"Test : ouverture");
}

- (void)cancelTest {
    _testing = NO;
    SMSetGains(_before, _beforeActive);
    if (_spotifyWasOn) SMSetSpotifyOn(YES);
    SMLog(@"Test : fermé sans enregistrer");
    [self refresh];
}

- (void)restart {
    float flat[SM_BANDS] = {0};
    memcpy(_base, flat, sizeof(_base));
    _step = 0;
    [self prepareStep];
}

- (void)prepareStep {
    _mode = SMModeStep;
    SMStep s = SMSteps[_step];
    // Trois versions : actuelle, plus, moins — dans un ordre mélangé
    float plus[SM_BANDS], minus[SM_BANDS];
    memcpy(plus, _base, sizeof(plus));
    memcpy(minus, _base, sizeof(minus));
    for (int k = 0; k < s.count; k++) {
        int b = s.bands[k];
        plus[b] = fminf(12, _base[b] + s.delta);
        minus[b] = fmaxf(-12, _base[b] - s.delta);
    }
    float *versions[3] = {_base, plus, minus};
    int order[3] = {0, 1, 2};
    for (int i = 2; i > 0; i--) { int j = arc4random_uniform(i + 1); int t = order[i]; order[i] = order[j]; order[j] = t; }
    float tmp[3][SM_BANDS];
    for (int i = 0; i < 3; i++) memcpy(tmp[i], versions[order[i]], sizeof(tmp[i]));
    memcpy(_variants, tmp, sizeof(_variants));
    _selected = 0;
    SMSetGains(_variants[0], YES);
    [self render];
}

- (void)choose:(UIButton *)b {
    _selected = (int)b.tag;
    SMSetGains(_variants[_selected], YES);
    [self render];
}

- (void)primaryTapped {
    switch (_mode) {
        case SMModeIntro:
            _step = 0;
            [self prepareStep];
            break;
        case SMModeStep: {
            memcpy(_base, _variants[_selected], sizeof(_base));
            SMLog([NSString stringWithFormat:@"Test : étape %d (%s) → %@", _step + 1, SMSteps[_step].name, @[@"A", @"B", @"C"][_selected]]);
            if (++_step >= SMStepCount) {
                _mode = SMModeResult;
                SMSetGains(_base, YES);
                SMLog([NSString stringWithFormat:@"Test : résultat\n%@", SMDescribe(_base)]);
                [self render];
            } else {
                [self prepareStep];
            }
            break;
        }
        case SMModeResult: {
            SMSave(_base);
            BOOL inSpotify = SMApplyToSpotify(_base);
            // Dans Spotify : l'égaliseur du tweak s'efface (sinon les deux s'additionnent)
            [NSUserDefaults.standardUserDefaults setBool:!inSpotify forKey:SMKey("enabled")];
            SMApplySaved();
            _testing = NO;
            SMLog(inSpotify ? @"Test : réglage mis dans l'égaliseur de Spotify" : @"Test : égaliseur de Spotify introuvable, égaliseur SoundMatch activé");
            [self refresh];
            [self toast:inSpotify ? @"   Réglage mis dans l'égaliseur de Spotify   " : @"   Égaliseur SoundMatch activé   "];
            break;
        }
    }
}

- (void)render {
    _choices.hidden = _mode != SMModeStep;
    _secondary.hidden = _mode != SMModeResult;
    switch (_mode) {
        case SMModeIntro:
            _title.text = @"Trouver mon égaliseur";
            _subtitle.text = @"1. Coupe l'égaliseur de Spotify (Paramètres › Lecture › Égaliseur).\n2. Lance un morceau que tu connais bien, avec un bon casque si possible.\n3. Appuie sur Commencer : à chaque étape, écoute A, B et C et garde ta préférée.";
            [_primary setTitle:@"Commencer" forState:UIControlStateNormal];
            break;
        case SMModeStep:
            _title.text = [NSString stringWithFormat:@"Étape %d / %d · %s", _step + 1, SMStepCount, SMSteps[_step].name];
            _subtitle.text = @"Écoute chaque version quelques secondes (la musique continue), puis garde celle que tu préfères.";
            for (int i = 0; i < 3; i++) {
                UIButton *b = _choiceButtons[i];
                BOOL on = i == _selected;
                b.backgroundColor = on ? SMGreen() : [UIColor colorWithWhite:0.2 alpha:1];
                [b setTitleColor:on ? UIColor.blackColor : UIColor.whiteColor forState:UIControlStateNormal];
            }
            [_primary setTitle:[NSString stringWithFormat:@"Je préfère %@", @[@"A", @"B", @"C"][_selected]] forState:UIControlStateNormal];
            break;
        case SMModeResult:
            _title.text = @"Ton égaliseur";
            _subtitle.text = [NSString stringWithFormat:@"%@\n\nCe réglage va être mis dans l'égaliseur de Spotify (Paramètres › Lecture › Égaliseur).", SMDescribe(_base)];
            [_primary setTitle:@"Mettre dans l'égaliseur de Spotify" forState:UIControlStateNormal];
            break;
    }
    [self refresh];
}

#pragma mark Menu (appui long à trois doigts)

- (void)installGestures {
    for (UIWindow *w in [self appWindows]) {
        BOOL has = NO;
        for (UIGestureRecognizer *g in w.gestureRecognizers) if (g.delegate == self) { has = YES; break; }
        if (has) continue;
        UILongPressGestureRecognizer *menu = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(menu:)];
        menu.numberOfTouchesRequired = 3;
        menu.minimumPressDuration = 0.8;
        menu.cancelsTouchesInView = NO;
        menu.delegate = self;
        [w addGestureRecognizer:menu];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

- (UIViewController *)topController {
    for (UIWindow *w in [self appWindows]) {
        if (!w.isKeyWindow) continue;
        UIViewController *vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        return vc;
    }
    return [self appWindows].firstObject.rootViewController;
}

- (void)present:(UIAlertController *)a from:(UIViewController *)top {
    a.popoverPresentationController.sourceView = top.view;
    a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
    [top presentViewController:a animated:YES completion:nil];
}

- (void)menu:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || _testing) return;
    UIViewController *top = [self topController];
    if (!top || [top isKindOfClass:UIAlertController.class]) return;
    [self showMenuFrom:top];
}

- (void)showMenuFrom:(UIViewController *)top {
    if (_testing || [top isKindOfClass:UIAlertController.class]) return;
    float saved[SM_BANDS];
    SMLoadSaved(saved);
    NSString *savedText = SMDescribe(saved);
    BOOL enabled = SMEnabled();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"SoundMatch"
        message:[NSString stringWithFormat:@"Égaliseur %@\nVersion %s", enabled ? @"activé" : @"désactivé", SM_VERSION]
        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Trouver mon égaliseur" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        self->_inSettings = NO;
        [self openTest];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:enabled ? @"Désactiver mon égaliseur" : @"Activer mon égaliseur" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [NSUserDefaults.standardUserDefaults setBool:!enabled forKey:SMKey("enabled")];
        SMApplySaved();
        SMLog(enabled ? @"Égaliseur désactivé" : @"Égaliseur activé");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Mettre mon réglage dans l'égaliseur de Spotify" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        float g[SM_BANDS];
        SMLoadSaved(g);
        if (SMApplyToSpotify(g)) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:SMKey("enabled")];
            SMApplySaved();
            [self toast:@"   Réglage mis dans l'égaliseur de Spotify   "];
        }
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Voir mes réglages" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIAlertController *v = [UIAlertController alertControllerWithTitle:@"Mon égaliseur"
            message:[NSString stringWithFormat:@"%@\n\nÀ recopier dans Spotify si tu veux : Paramètres › Lecture › Égaliseur.", savedText]
            preferredStyle:UIAlertControllerStyleAlert];
        [v addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self present:v from:[self topController]];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Remettre à plat" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        float flat[SM_BANDS] = {0};
        SMSave(flat);
        SMApplySaved();
        SMLog(@"Égaliseur remis à plat");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Partager le journal" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIViewController *t = [self topController];
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:SMLogPath()]] applicationActivities:nil];
        share.popoverPresentationController.sourceView = t.view;
        share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(t.view.bounds), CGRectGetMidY(t.view.bounds), 1, 1);
        [t presentViewController:share animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Fermer" style:UIAlertActionStyleCancel handler:nil]];
    [self present:a from:top];
}

@end

#pragma mark Repérage de l'égaliseur de Spotify (pour pouvoir le régler directement)

static NSString *SMShort(id v) {
    NSString *d = [v description];
    d = [[d componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    return d.length > 160 ? [[d substringToIndex:160] stringByAppendingString:@"…"] : d;
}

/// Journal : réglages enregistrés et classes de l'app qui parlent d'égaliseur.
static void SMDiscoverSpotifyEqualizer(void) {
    NSDictionary *all = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    int found = 0;
    for (NSString *key in [all.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *low = key.lowercaseString;
        if ([low hasPrefix:@"soundmatch."]) continue;
        if ([low containsString:@"equaliz"] || [low containsString:@"equalis"] || [low containsString:@"eq_"] || [low hasSuffix:@".eq"] ||
            [low containsString:@"eqband"] || [low containsString:@"eq.band"] || [low containsString:@"eqpreset"]) {
            SMLog([NSString stringWithFormat:@"Réglage Spotify : %@ = %@ (%@)", key, SMShort(all[key]), NSStringFromClass([all[key] class])]);
            found++;
        }
    }
    if (!found) SMLog(@"Réglage Spotify : aucune clé d'égaliseur dans les préférences");

}

__attribute__((constructor)) static void SMInit(void) {
    SMHookAudio();
    SMHookSpotifyModel();
    dispatch_async(dispatch_get_main_queue(), ^{ [[SMCore shared] start]; });
}
