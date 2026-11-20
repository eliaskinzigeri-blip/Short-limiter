// SoundMatch : statistiques d'écoute (minutes, titres, artistes) et lignes dans les paramètres de Spotify.
//
// Les écoutes sont relevées sur l'appareil, chaque seconde, à partir des informations « À l'écoute » que Spotify
// donne à iOS (écran verrouillé) : titre, artiste, album, pochette, lecture ou pause. Rien n'est envoyé nulle part :
// tout reste dans Documents/SoundMatch-stats.json de l'app. Les stats commencent donc à l'installation du tweak.
#import "SMStats.h"
#import <MediaPlayer/MediaPlayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Couleurs et polices

static UIColor *SMC(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}
#define SM_BG      SMC(0x121212)
#define SM_CARD    SMC(0x1F1F1F)
#define SM_PILL    SMC(0x2A2A2A)
#define SM_GRAY    SMC(0xB3B3B3)
#define SM_GREEN   SMC(0x1ED760)

static NSString *gFontRegular, *gFontBold; // polices de Spotify, relevées dans l'écran des paramètres

static UIFont *SMFont(CGFloat size, BOOL bold) {
    NSString *name = bold ? gFontBold : gFontRegular;
    UIFont *f = name ? [UIFont fontWithName:name size:size] : nil;
    return f ?: [UIFont systemFontOfSize:size weight:bold ? UIFontWeightBold : UIFontWeightRegular];
}

#pragma mark - Enregistrement des écoutes

static NSMutableDictionary *gDays;   // "aaaa-mm-jj" → { tot: s, h: [24 × s], tr: { clé: [s, écoutes] } }
static NSMutableDictionary *gTracks; // clé → { t: titre, a: artiste(s), al: album }
static BOOL gDirty;
static CFAbsoluteTime gLastTick, gLastSave;
static NSString *gCurKey;
static double gCurSec;
static BOOL gCurCounted, gCurFull, gCurArtSaved;
static NSDictionary *gLastInfo, *gHookedInfo;
static CFAbsoluteTime gKeyAt;     // changement de titre
static __weak id gPrevArt; // pochette du titre précédent (à ne pas attribuer au nouveau)
static void SMResolveTrack(NSString *key);
static void SMArtUpdated(void);
static NSString *SMBaseTitle(NSString *t);
// Historique importé depuis les données que Spotify envoie sur demande (fichiers JSON) : mêmes jours que gDays
static NSMutableDictionary *gImportDays, *gImportTracks;
static NSString *gImportUntil; // dernier jour couvert par l'import

/// « Vacra, La Rvfleuze • Lossless » → « Vacra, La Rvfleuze » (Spotify ajoute la qualité à l'artiste)
static NSString *SMCleanArtist(NSString *a) {
    NSRange r = [a rangeOfString:@" • "];
    return r.location == NSNotFound ? a : [a substringToIndex:r.location];
}

static NSString *SMImportPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"SoundMatch-import.json"];
}

static NSString *SMStatsPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"SoundMatch-stats.json"];
}

static NSString *SMArtDir(void) {
    static NSString *dir;
    if (!dir) {
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        dir = [caches stringByAppendingPathComponent:@"SoundMatchArt"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return dir;
}

static NSString *SMArtPath(NSString *key) {
    uint64_t h = 1469598103934665603ULL; // FNV-1a : nom de fichier stable d'un lancement à l'autre
    for (const unsigned char *p = (const unsigned char *)key.UTF8String; *p; p++) { h ^= *p; h *= 1099511628211ULL; }
    return [SMArtDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx.jpg", h]];
}

static NSDateFormatter *SMDayFormatter(void) {
    static NSDateFormatter *f;
    if (!f) {
        f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyy-MM-dd";
    }
    return f;
}

static void SMStatsLoad(void) {
    NSData *d = [NSData dataWithContentsOfFile:SMStatsPath()];
    NSDictionary *root = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    gDays = [root[@"days"] isKindOfClass:NSMutableDictionary.class] ? root[@"days"] : [NSMutableDictionary dictionary];
    gTracks = [root[@"tracks"] isKindOfClass:NSMutableDictionary.class] ? root[@"tracks"] : [NSMutableDictionary dictionary];
    NSData *i = [NSData dataWithContentsOfFile:SMImportPath()];
    NSDictionary *imp = i ? [NSJSONSerialization JSONObjectWithData:i options:0 error:nil] : nil;
    gImportDays = [imp[@"days"] isKindOfClass:NSDictionary.class] ? [imp[@"days"] mutableCopy] : nil;
    gImportTracks = [imp[@"tracks"] isKindOfClass:NSDictionary.class] ? [imp[@"tracks"] mutableCopy] : nil;
    gImportUntil = [imp[@"until"] isKindOfClass:NSString.class] ? imp[@"until"] : nil;
}

static void SMStatsSave(void) {
    if (!gDirty || !gDays) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"days": gDays, @"tracks": gTracks} options:0 error:nil];
    if ([d writeToFile:SMStatsPath() atomically:YES]) gDirty = NO;
    gLastSave = CFAbsoluteTimeGetCurrent();
}

static NSMutableDictionary *SMDayEntry(NSDate *date) {
    NSString *k = [SMDayFormatter() stringFromDate:date];
    NSMutableDictionary *day = gDays[k];
    if (![day isKindOfClass:NSMutableDictionary.class]) {
        NSMutableArray *hours = [NSMutableArray array];
        for (int i = 0; i < 24; i++) [hours addObject:@0];
        day = [@{@"tot": @0, @"h": hours, @"tr": [NSMutableDictionary dictionary]} mutableCopy];
        gDays[k] = day;
    }
    return day;
}

static void SMSaveArtwork(NSString *key, NSDictionary *info) {
    if (gCurArtSaved) return;
    NSString *path = SMArtPath(key);
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) { gCurArtSaved = YES; return; }
    id art = info[MPMediaItemPropertyArtwork];
    if (![art isKindOfClass:MPMediaItemArtwork.class]) return;
    UIImage *img = [(MPMediaItemArtwork *)art imageWithSize:CGSizeMake(160, 160)];
    if (!img) return;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(160, 160)];
    UIImage *small = [r imageWithActions:^(UIGraphicsImageRendererContext *c) { [img drawInRect:CGRectMake(0, 0, 160, 160)]; }];
    gCurArtSaved = [UIImageJPEGRepresentation(small, 0.8) writeToFile:path atomically:YES];
}

static void SMStatsTick(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double dt = gLastTick ? now - gLastTick : 0;
    gLastTick = now;
    if (dt < 0 || dt > 5) dt = 0; // retour après une mise en veille de l'app : rien à compter

    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo ?: gHookedInfo;
    NSString *title = info[MPMediaItemPropertyTitle];
    if (![title isKindOfClass:NSString.class] || !title.length) {
        if (gDirty && now - gLastSave > 20) SMStatsSave();
        return;
    }
    NSString *artist = SMCleanArtist([info[MPMediaItemPropertyArtist] isKindOfClass:NSString.class] ? info[MPMediaItemPropertyArtist] : @"");
    static BOOL loggedKeys;
    if (!loggedKeys) {
        loggedKeys = YES;
        SMLogPublic([NSString stringWithFormat:@"Stats : infos « À l'écoute » de Spotify : %@ (vitesse %@)",
                     [[info.allKeys valueForKey:@"description"] componentsJoinedByString:@", "], info[MPNowPlayingInfoPropertyPlaybackRate]]);
    }
    NSString *album = [info[MPMediaItemPropertyAlbumTitle] isKindOfClass:NSString.class] ? info[MPMediaItemPropertyAlbumTitle] : @"";
    double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
    NSNumber *elapsedN = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    NSString *key = [NSString stringWithFormat:@"%@—%@", title, artist];

    BOOL changedInfo = gLastInfo && ![gLastInfo isEqual:info];
    gLastInfo = info;
    if (![key isEqualToString:gCurKey]) {
        gPrevArt = info[MPMediaItemPropertyArtwork]; // encore celle du titre précédent à cet instant
        gCurKey = key;
        gCurSec = 0;
        gCurCounted = NO;
        gCurFull = NO;
        gCurArtSaved = NO;
        gKeyAt = now;
        if (!gTracks[key]) {
            gTracks[key] = [@{@"t": title, @"a": artist, @"al": album} mutableCopy];
            gDirty = YES;
        }
    } else if (changedInfo && gCurSec >= 30 && elapsedN && elapsedN.doubleValue < 3) {
        gCurSec = 0; // même titre relancé depuis le début : nouvelle écoute
        gCurCounted = NO;
        gCurFull = NO;
    }
    // Identifiant Spotify du titre (« spotify:track:… ») : sert à trouver la vraie pochette et les photos d'artistes
    NSString *ext = [info[MPNowPlayingInfoPropertyExternalContentIdentifier] isKindOfClass:NSString.class] ? info[MPNowPlayingInfoPropertyExternalContentIdentifier] : nil;
    NSMutableDictionary *meta = gTracks[key];
    if (ext.length && [meta isKindOfClass:NSMutableDictionary.class] && ![meta[@"uri"] isEqualToString:ext]) {
        meta[@"uri"] = ext;
        gDirty = YES;
        static BOOL loggedUri;
        if (!loggedUri) { loggedUri = YES; SMLogPublic([@"Stats : identifiant du titre : " stringByAppendingString:ext]); }
    }
    double duration = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
    if (duration > 0 && [meta isKindOfClass:NSMutableDictionary.class] && fabs([meta[@"d"] doubleValue] - duration) > 1) meta[@"d"] = @(duration);
    // Pochette d'iOS seulement une fois le titre installé (juste après un changement, c'est encore l'ancienne)
    id art = info[MPMediaItemPropertyArtwork];
    if (now - gKeyAt > 3 && art != gPrevArt) SMSaveArtwork(key, info);
    if (now - gKeyAt > 3 && now - gKeyAt < 5) SMResolveTrack(key);

    // En lecture : du son sort vraiment de Spotify sur l'iPhone (casque, voiture, haut-parleur) ;
    // sans mesure du son (AirPlay, Connect…), on se fie à la vitesse de lecture annoncée par Spotify.
    int sound = SMAudioSound();
    BOOL playing = sound == 1 || (sound < 0 && rate > 0);
    if (playing && dt > 0) {
        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:now];
        NSMutableDictionary *day = SMDayEntry(date);
        day[@"tot"] = @([day[@"tot"] doubleValue] + dt);
        NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:date];
        NSMutableArray *hours = day[@"h"];
        if ([hours isKindOfClass:NSMutableArray.class] && hour < (NSInteger)hours.count) hours[hour] = @([hours[hour] doubleValue] + dt);
        NSMutableDictionary *tr = day[@"tr"];
        NSMutableArray *e = tr[key];
        if (![e isKindOfClass:NSMutableArray.class] || e.count < 2) { e = [@[@0, @0, @0] mutableCopy]; tr[key] = e; }
        while (e.count < 3) [e addObject:@0];
        e[0] = @([e[0] doubleValue] + dt);
        gCurSec += dt;
        if (!gCurCounted && gCurSec >= 30) { // une écoute compte à partir de 30 s, comme chez Spotify
            gCurCounted = YES;
            e[1] = @([e[1] integerValue] + 1);
        }
        if (!gCurFull && duration > 30 && gCurSec >= duration * 0.9) { // écoute complète : 90 % du titre
            gCurFull = YES;
            e[2] = @([e[2] integerValue] + 1);
        }
        gDirty = YES;
    }
    if (gDirty && now - gLastSave > 20) SMStatsSave();
}

static void SMHookNowPlaying(void) {
    Method m = class_getInstanceMethod(MPNowPlayingInfoCenter.class, @selector(setNowPlayingInfo:));
    if (!m) return;
    void (*orig)(id, SEL, NSDictionary *) = (void *)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self, NSDictionary *info) {
        gHookedInfo = [info copy];
        orig(self, @selector(setNowPlayingInfo:), info);
    }));
}

static void SMLoadSpotifyCache(void);
static void SMHookAuth(void);
static void SMHookSessions(void);
static void SMLoadArtists(void);
static void SMFetchRecent(void (^done)(void));

void SMStatsStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SMStatsLoad();
        SMLoadSpotifyCache();
        SMLoadArtists();
        SMHookNowPlaying();
        SMHookAuth();
        SMHookSessions();
        NSTimer *recent = [NSTimer timerWithTimeInterval:600 repeats:YES block:^(NSTimer *x) { SMFetchRecent(nil); }];
        [NSRunLoop.mainRunLoop addTimer:recent forMode:NSRunLoopCommonModes];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ SMFetchRecent(nil); });
        NSTimer *t = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *x) { SMStatsTick(); }];
        [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
        for (NSNotificationName n in @[UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification,
                                       UIApplicationWillTerminateNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *x) {
                SMStatsSave();
            }];
        }
        SMLogPublic([NSString stringWithFormat:@"Stats d'écoute : %lu jour(s), %lu titre(s) enregistrés", (unsigned long)gDays.count, (unsigned long)gTracks.count]);
    });
}

#pragma mark - Données du compte Spotify (connexion de l'app)

// L'app Spotify envoie son jeton de connexion avec ses requêtes : on le relève pour lire, avec le même compte,
// le classement Spotify (top artistes / titres) et les dernières écoutes (tous appareils). Il reste en mémoire.
static NSString *gToken;
static NSMutableDictionary *gSpotifyTop;          // short_term / medium_term / long_term → { artists, tracks }
static NSDate *gSpotifyTopAt;
static NSString *gSpotifyStatus;
static BOOL gFetchingTop;
static NSMutableDictionary *gRecentDays, *gRecentTracks; // dernières écoutes données par Spotify, par jour
static NSMutableArray *gRecentSeen;               // played_at déjà comptés
static CFAbsoluteTime gRecentAt;
static CFAbsoluteTime gTopFailAt; // dernier échec : pas de nouvel essai avant 10 min (évite de bombarder Spotify)

static NSString *SMHex(NSString *str) {
    uint64_t h = 1469598103934665603ULL;
    for (const unsigned char *c = (const unsigned char *)str.UTF8String; *c; c++) { h ^= *c; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", h];
}

static NSString *SMDocPath(NSString *name) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:name];
}

static void SMSeeAuth(NSURLRequest *r, NSString *field, NSString *value) {
    if (![field.lowercaseString isEqualToString:@"authorization"] || ![value hasPrefix:@"Bearer "] || value.length < 40) return;
    NSString *host = r.URL.host.lowercaseString ?: @"";
    if (host.length && ![host containsString:@"spotify"] && ![host containsString:@"scdn"]) return;
    NSString *tok = [value substringFromIndex:7];
    if ([tok isEqualToString:gToken]) return;
    BOOL first = gToken == nil;
    gToken = tok;
    if (first) SMLogPublic([NSString stringWithFormat:@"Stats : connexion Spotify trouvée (requête vers %@)", host.length ? host : @"?"]);
}

static void SMHookAuth(void) {
    Class c = NSMutableURLRequest.class;
    SEL sels[] = {@selector(setValue:forHTTPHeaderField:), @selector(addValue:forHTTPHeaderField:)};
    for (int i = 0; i < 2; i++) {
        SEL sel = sels[i];
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        void (*orig)(id, SEL, NSString *, NSString *) = (void *)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(NSMutableURLRequest *self, NSString *value, NSString *field) {
            orig(self, sel, value, field);
            if ([value isKindOfClass:NSString.class] && [field isKindOfClass:NSString.class]) SMSeeAuth(self, field, value);
        }));
    }
    Method m = class_getInstanceMethod(c, @selector(setAllHTTPHeaderFields:));
    if (m) {
        void (*orig)(id, SEL, NSDictionary *) = (void *)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(NSMutableURLRequest *self, NSDictionary *all) {
            orig(self, @selector(setAllHTTPHeaderFields:), all);
            for (NSString *k in all) if ([all[k] isKindOfClass:NSString.class]) SMSeeAuth(self, k, all[k]);
        }));
    }
    // Sessions avec en-têtes communs
    Method cm = class_getInstanceMethod(NSURLSessionConfiguration.class, @selector(setHTTPAdditionalHeaders:));
    if (cm) {
        void (*orig)(id, SEL, NSDictionary *) = (void *)method_getImplementation(cm);
        method_setImplementation(cm, imp_implementationWithBlock(^(id self, NSDictionary *all) {
            orig(self, @selector(setHTTPAdditionalHeaders:), all);
            for (id k in all) if ([k isKindOfClass:NSString.class] && [all[k] isKindOfClass:NSString.class]) SMSeeAuth(nil, k, all[k]);
        }));
    }
}

#pragma mark Relevé des requêtes de l'app (pour trouver où Spotify range les stats)

static NSString *SMCaptureDir(void) {
    NSString *dir = SMDocPath(@"SoundMatch-captures");
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

NSArray<NSURL *> *SMStatsCaptureFiles(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:SMCaptureDir() error:nil])
        [out addObject:[NSURL fileURLWithPath:[SMCaptureDir() stringByAppendingPathComponent:f]]];
    return out;
}

/// Chemin sans les identifiants (suites de chiffres ou de lettres longues) : un même type de requête = une ligne.
static NSString *SMPathPattern(NSURL *u) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *seg in [u.path componentsSeparatedByString:@"/"]) {
        BOOL isId = seg.length >= 16 || ([seg rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound && seg.length >= 6);
        [parts addObject:isId ? @"*" : seg];
    }
    return [NSString stringWithFormat:@"%@%@", u.host, [parts componentsJoinedByString:@"/"]];
}

static void SMSeeResponse(NSURLRequest *req, NSData *data, NSURLResponse *resp) {
    NSURL *u = req.URL;
    NSString *host = u.host.lowercaseString;
    if (![host containsString:@"spotify"] || [host hasPrefix:@"api.spotify"]) return;
    NSString *pattern = SMPathPattern(u);
    static NSMutableSet *seen;
    static int saved;
    if (!seen) seen = [NSMutableSet set];
    NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : -1;
    @synchronized (SMCaptureDir()) {
        if (![seen containsObject:pattern]) {
            [seen addObject:pattern];
            SMLogPublic([NSString stringWithFormat:@"Requête Spotify : %@ %@ → %ld, %lu octets", req.HTTPMethod ?: @"GET", pattern, (long)st, (unsigned long)data.length]);
        }
        NSString *low = pattern.lowercaseString;
        NSArray *keys = @[@"stat", @"highlight", @"listening", @"recent", @"history", @"top", @"wrapped", @"timeline", @"insight", @"played"];
        BOOL interesting = NO;
        for (NSString *k in keys) if ([low containsString:k]) interesting = YES;
        if (interesting && data.length && data.length < 400000 && saved < 40) {
            saved++;
            NSString *name = [NSString stringWithFormat:@"%02d-%@.bin", saved,
                [[pattern stringByReplacingOccurrencesOfString:@"/" withString:@"_"] substringToIndex:MIN(80, pattern.length)]];
            NSMutableData *out = [NSMutableData dataWithData:[[NSString stringWithFormat:@"%@ %@\nstatus %ld\n\n", req.HTTPMethod ?: @"GET", u.absoluteString, (long)st] dataUsingEncoding:NSUTF8StringEncoding]];
            [out appendData:data];
            [out writeToFile:[SMCaptureDir() stringByAppendingPathComponent:name] atomically:YES];
            SMLogPublic([NSString stringWithFormat:@"Requête Spotify enregistrée : %@", name]);
        }
    }
}

static void SMHookSessionClass(Class cls) {
    SEL sel = @selector(dataTaskWithRequest:completionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    static NSMutableSet *done;
    if (!done) done = [NSMutableSet set];
    NSValue *key = [NSValue valueWithPointer:method_getImplementation(m)];
    if ([done containsObject:key]) return;
    [done addObject:key];
    id (*orig)(id, SEL, NSURLRequest *, id) = (void *)method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^id(id self, NSURLRequest *req, void (^handler)(NSData *, NSURLResponse *, NSError *)) {
        if (!handler || ![req.URL.host.lowercaseString containsString:@"spotify"]) return orig(self, sel, req, handler);
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
            SMSeeResponse(req, d, r);
            handler(d, r, e);
        };
        return orig(self, sel, req, wrapped);
    });
    [done addObject:[NSValue valueWithPointer:imp]]; // jamais deux fois le même relevé
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m)))
        method_setImplementation(m, imp);
}

static void SMHookSessions(void) {
    SMHookSessionClass(NSURLSession.class);
    SMHookSessionClass(NSURLSession.sharedSession.class);
    Class local = NSClassFromString(@"__NSURLSessionLocal");
    if (local) SMHookSessionClass(local);
}

static void SMApiGet(NSString *path, void (^done)(id json, NSInteger status)) {
    if (!gToken) { done(nil, 0); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://api.spotify.com/v1/" stringByAppendingString:path]]];
    [r setValue:[@"Bearer " stringByAppendingString:gToken] forHTTPHeaderField:@"Authorization"];
    r.timeoutInterval = 20;
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : -1;
        id json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(st == 200 ? json : nil, st); });
    }] resume];
}

static NSString *SMImageURL(NSArray *images) {
    if (![images isKindOfClass:NSArray.class] || !images.count) return nil;
    NSDictionary *best = images.firstObject; // les images vont de la plus grande à la plus petite
    for (NSDictionary *im in images) if ([im[@"width"] integerValue] >= 160) best = im;
    return [best[@"url"] isKindOfClass:NSString.class] ? best[@"url"] : nil;
}

static void SMSaveSpotifyCache(void) {
    if (gSpotifyTop) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"top": gSpotifyTop, @"at": @(gSpotifyTopAt.timeIntervalSince1970)} options:0 error:nil];
        [d writeToFile:SMDocPath(@"SoundMatch-top.json") atomically:YES];
    }
    if (gRecentDays) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"days": gRecentDays, @"tracks": gRecentTracks ?: @{}, @"seen": gRecentSeen ?: @[]} options:0 error:nil];
        [d writeToFile:SMDocPath(@"SoundMatch-recent.json") atomically:YES];
    }
}

static void SMLoadSpotifyCache(void) {
    NSData *d = [NSData dataWithContentsOfFile:SMDocPath(@"SoundMatch-top.json")];
    NSDictionary *root = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    if ([root[@"top"] isKindOfClass:NSMutableDictionary.class]) {
        gSpotifyTop = root[@"top"];
        gSpotifyTopAt = [NSDate dateWithTimeIntervalSince1970:[root[@"at"] doubleValue]];
    }
    d = [NSData dataWithContentsOfFile:SMDocPath(@"SoundMatch-recent.json")];
    root = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    gRecentDays = [root[@"days"] isKindOfClass:NSMutableDictionary.class] ? root[@"days"] : [NSMutableDictionary dictionary];
    gRecentTracks = [root[@"tracks"] isKindOfClass:NSMutableDictionary.class] ? root[@"tracks"] : [NSMutableDictionary dictionary];
    gRecentSeen = [root[@"seen"] isKindOfClass:NSMutableArray.class] ? root[@"seen"] : [NSMutableArray array];
}

/// Classement Spotify : top artistes et titres sur 4 semaines, 6 mois et environ 1 an.
static void SMFetchTop(void (^done)(void)) {
    if (gFetchingTop || (gTopFailAt && CFAbsoluteTimeGetCurrent() - gTopFailAt < 600)) return;
    if (!gToken) {
        gSpotifyStatus = @"Connexion Spotify pas encore trouvée : ouvre l'accueil ou une playlist de Spotify, puis reviens ici.";
        if (done) done();
        return;
    }
    gFetchingTop = YES;
    NSArray *terms = @[@"short_term", @"medium_term", @"long_term"];
    NSMutableDictionary *res = [NSMutableDictionary dictionary];
    __block int pending = 6;
    __block NSInteger lastError = 0;
    void (^finish)(void) = ^{
        if (--pending > 0) return;
        gFetchingTop = NO;
        if (res.count) {
            if (!gSpotifyTop) gSpotifyTop = [NSMutableDictionary dictionary];
            for (NSString *k in res) gSpotifyTop[k] = res[k];
            gSpotifyTopAt = NSDate.date;
            gSpotifyStatus = nil;
            SMSaveSpotifyCache();
            SMLogPublic(@"Stats : classement Spotify mis à jour");
        } else {
            gTopFailAt = CFAbsoluteTimeGetCurrent();
            gSpotifyStatus = [NSString stringWithFormat:@"Spotify refuse la lecture du classement (code %ld).", (long)lastError];
            SMLogPublic([@"Stats : " stringByAppendingString:gSpotifyStatus]);
        }
        if (done) done();
    };
    for (NSString *term in terms) {
        SMApiGet([NSString stringWithFormat:@"me/top/artists?limit=50&time_range=%@", term], ^(NSDictionary *json, NSInteger st) {
            if (json) {
                NSMutableArray *list = [NSMutableArray array];
                for (NSDictionary *a in json[@"items"]) {
                    if (![a isKindOfClass:NSDictionary.class] || ![a[@"name"] isKindOfClass:NSString.class]) continue;
                    NSArray *genres = [a[@"genres"] isKindOfClass:NSArray.class] ? a[@"genres"] : @[];
                    [list addObject:@{@"name": a[@"name"], @"img": SMImageURL(a[@"images"]) ?: @"",
                                      @"sub": [[genres subarrayWithRange:NSMakeRange(0, MIN(2, genres.count))] componentsJoinedByString:@", "]}];
                }
                NSMutableDictionary *e = [res[term] mutableCopy] ?: [NSMutableDictionary dictionary];
                e[@"artists"] = list;
                res[term] = e;
            } else lastError = st;
            finish();
        });
        SMApiGet([NSString stringWithFormat:@"me/top/tracks?limit=50&time_range=%@", term], ^(NSDictionary *json, NSInteger st) {
            if (json) {
                NSMutableArray *list = [NSMutableArray array];
                for (NSDictionary *t in json[@"items"]) {
                    if (![t isKindOfClass:NSDictionary.class] || ![t[@"name"] isKindOfClass:NSString.class]) continue;
                    NSArray *names = [t[@"artists"] isKindOfClass:NSArray.class] ? [t[@"artists"] valueForKey:@"name"] : @[];
                    [list addObject:@{@"t": t[@"name"], @"a": [names componentsJoinedByString:@", "],
                                      @"img": SMImageURL(t[@"album"][@"images"]) ?: @""}];
                }
                NSMutableDictionary *e = [res[term] mutableCopy] ?: [NSMutableDictionary dictionary];
                e[@"tracks"] = list;
                res[term] = e;
            } else lastError = st;
            finish();
        });
    }
}

/// Dernières écoutes du compte (50, tous appareils) ajoutées aux stats ; durée estimée jusqu'au titre suivant.
static void SMFetchRecent(void (^done)(void)) {
    if (!gToken || CFAbsoluteTimeGetCurrent() - gRecentAt < 60) { if (done) done(); return; }
    gRecentAt = CFAbsoluteTimeGetCurrent();
    SMApiGet(@"me/player/recently-played?limit=50", ^(NSDictionary *json, NSInteger st) {
        if (!json) {
            gRecentAt = CFAbsoluteTimeGetCurrent() + 540; // nouvel essai dans 10 min
            SMLogPublic([NSString stringWithFormat:@"Stats : dernières écoutes refusées par Spotify (code %ld)", (long)st]);
            if (done) done();
            return;
        }
        NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
        iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        NSISO8601DateFormatter *iso2 = [NSISO8601DateFormatter new];
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *it in json[@"items"]) {
            if (![it isKindOfClass:NSDictionary.class] || ![it[@"played_at"] isKindOfClass:NSString.class]) continue;
            NSDate *at = [iso dateFromString:it[@"played_at"]] ?: [iso2 dateFromString:it[@"played_at"]];
            NSDictionary *t = it[@"track"];
            if (!at || ![t isKindOfClass:NSDictionary.class] || ![t[@"name"] isKindOfClass:NSString.class]) continue;
            [items addObject:@{@"at": at, @"id": it[@"played_at"], @"t": t}];
        }
        [items sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"at" ascending:YES]]];
        NSCalendar *cal = NSCalendar.currentCalendar;
        int added = 0;
        for (NSUInteger i = 0; i < items.count; i++) {
            NSDictionary *it = items[i];
            if ([gRecentSeen containsObject:it[@"id"]]) continue;
            NSDictionary *t = it[@"t"];
            NSDate *at = it[@"at"];
            double dur = [t[@"duration_ms"] doubleValue] / 1000.0;
            double sec = dur;
            if (i + 1 < items.count) {
                double gap = [items[i + 1][@"at"] timeIntervalSinceDate:at];
                if (gap > 0 && gap < dur) sec = gap;
            }
            if (sec < 1) continue;
            NSArray *names = [t[@"artists"] isKindOfClass:NSArray.class] ? [t[@"artists"] valueForKey:@"name"] : @[];
            NSString *artist = [names componentsJoinedByString:@", "];
            NSString *key = [NSString stringWithFormat:@"%@\u2014%@", t[@"name"], artist];
            NSString *dk = [SMDayFormatter() stringFromDate:at];
            NSMutableDictionary *day = gRecentDays[dk];
            if (![day isKindOfClass:NSMutableDictionary.class]) {
                NSMutableArray *hours = [NSMutableArray array];
                for (int h = 0; h < 24; h++) [hours addObject:@0];
                day = [@{@"tot": @0, @"h": hours, @"tr": [NSMutableDictionary dictionary]} mutableCopy];
                gRecentDays[dk] = day;
            }
            day[@"tot"] = @([day[@"tot"] doubleValue] + sec);
            NSMutableArray *hours = day[@"h"];
            NSInteger hour = [cal component:NSCalendarUnitHour fromDate:at];
            hours[hour] = @([hours[hour] doubleValue] + sec);
            NSMutableDictionary *tr = day[@"tr"];
            NSMutableArray *e = tr[key];
            if (![e isKindOfClass:NSMutableArray.class]) { e = [@[@0, @0, @0] mutableCopy]; tr[key] = e; }
            while (e.count < 3) [e addObject:@0];
            e[0] = @([e[0] doubleValue] + sec);
            e[1] = @([e[1] integerValue] + 1);
            if (dur > 0 && sec >= dur * 0.9) e[2] = @([e[2] integerValue] + 1);
            if (!gRecentTracks[key])
                gRecentTracks[key] = @{@"t": t[@"name"], @"a": artist, @"img": SMImageURL(t[@"album"][@"images"]) ?: @""};
            [gRecentSeen addObject:it[@"id"]];
            added++;
        }
        while (gRecentSeen.count > 600) [gRecentSeen removeObjectAtIndex:0];
        if (added) {
            SMSaveSpotifyCache();
            SMLogPublic([NSString stringWithFormat:@"Stats : %d écoute(s) récupérée(s) depuis le compte Spotify", added]);
        }
        if (done) done();
    });
}

/// Image en ligne (pochette, photo d'artiste), gardée en cache.
static void SMLoadRemote(NSString *url, UIImageView *iv) {
    iv.accessibilityIdentifier = url;
    if (!url.length) return;
    NSString *path = [SMArtDir() stringByAppendingPathComponent:[SMHex(url) stringByAppendingString:@".img"]];
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (img) { iv.image = img; return; }
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        UIImage *im = d ? [UIImage imageWithData:d] : nil;
        if (!im) return;
        [d writeToFile:path atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ if ([iv.accessibilityIdentifier isEqualToString:url]) iv.image = im; });
    }] resume];
}

#pragma mark Vraies pochettes et photos d'artistes (pages publiques open.spotify.com)

static NSMutableDictionary *gArtistImg; // nom d'artiste (minuscules) → photo
static NSMutableSet *gResolving;

static void SMLoadArtists(void) {
    NSData *d = [NSData dataWithContentsOfFile:SMDocPath(@"SoundMatch-artists.json")];
    NSDictionary *a = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    gArtistImg = [a isKindOfClass:NSDictionary.class] ? [a mutableCopy] : [NSMutableDictionary dictionary];
    // Les photos trouvées par le nom seul pouvaient être celles d'un homonyme : on les recherche à nouveau
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"SoundMatch.artistsV2"]) {
        for (NSString *k in gArtistImg.allKeys) if ([gArtistImg[k] containsString:@"dzcdn"]) [gArtistImg removeObjectForKey:k];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"SoundMatch.artistsV2"];
    }
}

static void SMSaveArtists(void) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:gArtistImg options:0 error:nil];
    [d writeToFile:SMDocPath(@"SoundMatch-artists.json") atomically:YES];
}

static NSString *SMMeta(NSString *html, NSString *attr, NSString *name) {
    NSString *pat = [NSString stringWithFormat:@"<meta[^>]*%@=\"%@\"[^>]*content=\"([^\"]+)\"", attr, [NSRegularExpression escapedPatternForString:name]];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    return m ? [[html substringWithRange:[m rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"] : nil;
}

static NSArray<NSString *> *SMMetaAll(NSString *html, NSString *name) {
    NSString *pat = [NSString stringWithFormat:@"<meta[^>]*name=\"%@\"[^>]*content=\"([^\"]+)\"", name];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:NSRegularExpressionCaseInsensitive error:nil];
    NSMutableArray *out = [NSMutableArray array];
    for (NSTextCheckingResult *m in [re matchesInString:html options:0 range:NSMakeRange(0, html.length)])
        [out addObject:[html substringWithRange:[m rangeAtIndex:1]]];
    return out;
}

static void SMGetPage(NSString *url, void (^done)(NSString *html)) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [r setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    r.timeoutInterval = 20;
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSString *html = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(html); });
    }] resume];
}

static NSString *SMSpotifyId(NSString *uri, NSString *kind) {
    if (!uri.length) return nil;
    NSString *pat = [NSString stringWithFormat:@"%@[:/]([A-Za-z0-9]{22})", kind];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:uri options:0 range:NSMakeRange(0, uri.length)];
    return m ? [uri substringWithRange:[m rangeAtIndex:1]] : nil;
}

/// Page publique du titre : vraie pochette (og:image) et liens des artistes, puis la photo de chaque artiste.
static void SMResolveTrack(NSString *key) {
    NSMutableDictionary *meta = gTracks[key];
    NSString *tid = SMSpotifyId(meta[@"uri"], @"track");
    if (!tid || [meta[@"img"] length] || [gResolving containsObject:key]) return;
    if (!gResolving) gResolving = [NSMutableSet set];
    [gResolving addObject:key];
    SMGetPage([@"https://open.spotify.com/track/" stringByAppendingString:tid], ^(NSString *html) {
        [gResolving removeObject:key];
        if (!html) return;
        NSString *img = SMMeta(html, @"property", @"og:image");
        if (img.length) { meta[@"img"] = img; gDirty = YES; SMArtUpdated(); }
        for (NSString *link in SMMetaAll(html, @"music:musician")) {
            NSString *aid = SMSpotifyId(link, @"artist");
            if (!aid || [gResolving containsObject:aid]) continue;
            [gResolving addObject:aid];
            SMGetPage([@"https://open.spotify.com/artist/" stringByAppendingString:aid], ^(NSString *page) {
                [gResolving removeObject:aid];
                NSString *name = page ? SMMeta(page, @"property", @"og:title") : nil;
                NSString *photo = page ? SMMeta(page, @"property", @"og:image") : nil;
                if (!name.length || !photo.length) return;
                gArtistImg[name.lowercaseString] = photo;
                SMSaveArtists();
                SMArtUpdated();
            });
        }
        static BOOL logged;
        if (!logged) {
            logged = YES;
            SMLogPublic([NSString stringWithFormat:@"Stats : pochette %@, %lu artiste(s) trouvé(s) pour « %@ »", img.length ? @"trouvée" : @"introuvable",
                         (unsigned long)SMMetaAll(html, @"music:musician").count, meta[@"t"]]);
        }
    });
}

static NSMutableSet *gTried; // recherches déjà faites (pas deux fois la même)

static NSArray<NSString *> *SMSplitArtistsAll(NSString *a) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in [a componentsSeparatedByString:@", "]) if (p.length) [out addObject:p];
    return out;
}


static NSString *SMFold(NSString *x) {
    return [[x stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static void SMArtUpdated(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:@"SMArtUpdated" object:nil];
}

static void SMGetJSON(NSString *url, void (^done)(id json)) {
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(json); });
    }] resume];
}

/// Photo d'un artiste : d'abord via un de tes titres où il apparaît (le bon artiste, pas un homonyme),
/// sinon par son nom exact, en prenant celui qui a le plus de fans.
static void SMFindArtistPhoto(NSString *name) {
    if (!name.length || gArtistImg[name.lowercaseString]) return;
    if (!gTried) gTried = [NSMutableSet set];
    NSString *tag = [@"a:" stringByAppendingString:name.lowercaseString];
    if ([gTried containsObject:tag]) return;
    [gTried addObject:tag];
    NSString *fold = SMFold(name);
    NSMutableArray *queries = [NSMutableArray array];
    for (NSString *k in gTracks) {
        NSDictionary *m = gTracks[k];
        BOOL his = NO;
        for (NSString *n in SMSplitArtistsAll(SMCleanArtist(m[@"a"] ?: @""))) if ([SMFold(n) isEqualToString:fold]) his = YES;
        NSString *t = m[@"t"] ?: @"";
        if ([SMFold(t) containsString:fold]) his = YES; // « LEVEL UP - Nouvelle École »
        if (!his || !t.length) continue;
        [queries addObject:[NSString stringWithFormat:@"artist:\"%@\" track:\"%@\"", name, SMBaseTitle(t)]];
        if (queries.count >= 3) break;
    }
    __block void (^next)(NSUInteger) = nil; // gardé jusqu'à la fin des recherches
    void (^found)(NSString *) = ^(NSString *pic) {
        gArtistImg[name.lowercaseString] = pic;
        SMSaveArtists();
        SMArtUpdated();
    };
    next = ^(NSUInteger i) {
        if (i < queries.count) {
            NSString *q = [queries[i] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
            SMGetJSON([@"https://api.deezer.com/search?limit=10&q=" stringByAppendingString:q], ^(NSDictionary *json) {
                for (NSDictionary *t in json[@"data"]) {
                    NSDictionary *ar = [t isKindOfClass:NSDictionary.class] ? t[@"artist"] : nil;
                    if (![ar isKindOfClass:NSDictionary.class] || ![ar[@"name"] isKindOfClass:NSString.class]) continue;
                    if (![SMFold(ar[@"name"]) isEqualToString:fold]) continue;
                    NSString *pic = ar[@"picture_big"];
                    if (![pic isKindOfClass:NSString.class] || [pic containsString:@"/artist//"]) continue;
                    found(pic);
                    next = nil;
                    return;
                }
                if (next) next(i + 1);
            });
            return;
        }
        // Dernier recours : le nom exact avec le plus de fans
        NSString *q = [name stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet] ?: @"";
        SMGetJSON([@"https://api.deezer.com/search/artist?limit=15&q=" stringByAppendingString:q], ^(NSDictionary *json) {
            NSDictionary *best = nil;
            for (NSDictionary *a in json[@"data"]) {
                if (![a isKindOfClass:NSDictionary.class] || ![a[@"name"] isKindOfClass:NSString.class]) continue;
                if (![SMFold(a[@"name"]) isEqualToString:fold]) continue;
                if (![a[@"picture_big"] isKindOfClass:NSString.class] || [a[@"picture_big"] containsString:@"/artist//"]) continue;
                if (!best || [a[@"nb_fan"] longLongValue] > [best[@"nb_fan"] longLongValue]) best = a;
            }
            if (best) found(best[@"picture_big"]);
            next = nil;
        });
    };
    next(0);
}

/// « LEVEL UP - Nouvelle École », « Titre (feat. X) » → « LEVEL UP », « Titre »
static NSString *SMBaseTitle(NSString *t) {
    NSString *x = t;
    for (NSString *sep in @[@" - ", @" (", @" [", @" feat", @" ft."]) {
        NSRange r = [x rangeOfString:sep options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound && r.location > 0) x = [x substringToIndex:r.location];
    }
    return [x stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

/// Pochette d'un titre sans identifiant Spotify : plusieurs recherches (titre exact, titre court, texte libre),
/// en n'acceptant qu'un résultat dont l'artiste fait partie des artistes du titre.
static void SMFindCover(NSString *key) {
    NSMutableDictionary *meta = gTracks[key];
    if (![meta isKindOfClass:NSMutableDictionary.class] || [meta[@"img"] length] || [meta[@"img2"] length]) return;
    if (!gTried) gTried = [NSMutableSet set];
    NSString *tag = [@"t:" stringByAppendingString:key];
    if ([gTried containsObject:tag]) return;
    [gTried addObject:tag];
    NSString *title = meta[@"t"] ?: @"";
    NSArray *names = SMSplitArtistsAll(SMCleanArtist(meta[@"a"] ?: @""));
    NSString *first = names.firstObject ?: @"";
    NSString *base = SMBaseTitle(title);
    NSMutableArray *queries = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"artist:\"%@\" track:\"%@\"", first, title]];
    if (![base isEqualToString:title]) [queries addObject:[NSString stringWithFormat:@"artist:\"%@\" track:\"%@\"", first, base]];
    [queries addObject:[NSString stringWithFormat:@"%@ %@", first, base]];
    NSMutableSet *folded = [NSMutableSet set];
    for (NSString *n in names) [folded addObject:SMFold(n)];
    // les artistes cités dans le titre (« - Nouvelle École ») comptent aussi
    NSRange dash = [title rangeOfString:@" - "];
    if (dash.location != NSNotFound) [folded addObject:SMFold([title substringFromIndex:NSMaxRange(dash)])];
    __block void (^next)(NSUInteger) = nil; // gardé jusqu'à la fin des recherches, puis libéré
    next = ^(NSUInteger i) {
        if (i >= queries.count) {
            SMLogPublic([NSString stringWithFormat:@"Stats : pochette introuvable pour « %@ »", title]);
            next = nil;
            return;
        }
        NSString *q = [queries[i] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
        SMGetJSON([@"https://api.deezer.com/search?limit=10&q=" stringByAppendingString:q], ^(NSDictionary *json) {
            for (NSDictionary *t in json[@"data"]) {
                if (![t isKindOfClass:NSDictionary.class]) continue;
                NSString *an = [t[@"artist"] isKindOfClass:NSDictionary.class] ? t[@"artist"][@"name"] : nil;
                NSString *tt = [t[@"title"] isKindOfClass:NSString.class] ? t[@"title"] : @"";
                NSString *cover = [t[@"album"] isKindOfClass:NSDictionary.class] ? t[@"album"][@"cover_big"] : nil;
                if (![an isKindOfClass:NSString.class] || ![cover isKindOfClass:NSString.class]) continue;
                if (![folded containsObject:SMFold(an)]) continue;
                if (![SMFold(SMBaseTitle(tt)) isEqualToString:SMFold(base)]) continue;
                meta[@"img2"] = cover;
                gDirty = YES;
                SMArtUpdated();
                next = nil;
                return;
            }
            if (next) next(i + 1);
        });
    };
    next(0);
}

#pragma mark - Périodes et calculs

typedef NS_ENUM(NSInteger, SMRange) { SMRangeDay, SMRangeWeek, SMRangeMonth, SMRangeYear, SMRangeSpotify };

static NSCalendar *SMCal(void) {
    static NSCalendar *c;
    if (!c) {
        c = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        c.locale = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
        c.firstWeekday = 2; // semaine du lundi au dimanche
        c.minimumDaysInFirstWeek = 4;
    }
    return c;
}

static NSCalendarUnit SMUnit(SMRange r) {
    switch (r) {
        case SMRangeDay: return NSCalendarUnitDay;
        case SMRangeWeek: return NSCalendarUnitWeekOfYear;
        case SMRangeMonth: return NSCalendarUnitMonth;
        default: return NSCalendarUnitYear;
    }
}

static void SMPeriod(SMRange r, NSInteger offset, NSDate **start, NSDate **end) {
    NSCalendar *cal = SMCal();
    NSDate *ref = [cal dateByAddingUnit:SMUnit(r) value:offset toDate:NSDate.date options:0];
    NSDate *s = nil;
    NSTimeInterval iv = 0;
    [cal rangeOfUnit:SMUnit(r) startDate:&s interval:&iv forDate:ref];
    *start = s;
    *end = [cal dateByAddingUnit:SMUnit(r) value:1 toDate:s options:0];
}

static NSString *SMFr(NSString *format, NSDate *d) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
    f.dateFormat = format;
    return [f stringFromDate:d];
}

static NSString *SMCap(NSString *s) {
    return s.length ? [[s substringToIndex:1].uppercaseString stringByAppendingString:[s substringFromIndex:1]] : s;
}

static NSString *SMPeriodLabel(SMRange r, NSInteger offset, NSDate *start, NSDate *end) {
    NSDate *last = [end dateByAddingTimeInterval:-1];
    switch (r) {
        case SMRangeDay:
            if (offset == 0) return @"Aujourd'hui";
            if (offset == -1) return @"Hier";
            return SMCap(SMFr(@"EEEE d MMMM", start));
        case SMRangeWeek:
            if ([SMCal() component:NSCalendarUnitMonth fromDate:start] == [SMCal() component:NSCalendarUnitMonth fromDate:last])
                return [NSString stringWithFormat:@"%@–%@", SMFr(@"d", start), SMFr(@"d MMM", last)];
            return [NSString stringWithFormat:@"%@ – %@", SMFr(@"d MMM", start), SMFr(@"d MMM", last)];
        case SMRangeMonth: return SMCap(SMFr(@"MMMM yyyy", start));
        default: return SMFr(@"yyyy", start);
    }
}

static NSString *SMRangeWord(SMRange r, NSInteger offset) {
    switch (r) {
        case SMRangeDay: return offset == 0 ? @"aujourd'hui" : offset == -1 ? @"hier" : @"ce jour-là";
        case SMRangeWeek: return offset == 0 ? @"cette semaine" : offset == -1 ? @"la semaine dernière" : @"cette semaine-là";
        case SMRangeMonth: return offset == 0 ? @"ce mois-ci" : offset == -1 ? @"le mois dernier" : @"ce mois-là";
        default: return offset == 0 ? @"cette année" : offset == -1 ? @"l'année dernière" : @"cette année-là";
    }
}

static NSString *SMMinutes(double sec) {
    long m = lround(sec / 60.0);
    if (m < 60) return [NSString stringWithFormat:@"%ld min", m];
    return [NSString stringWithFormat:@"%ld h %02ld", m / 60, m % 60];
}

static NSString *SMGroup(long n) {
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    f.locale = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
    return [f stringFromNumber:@(n)];
}

@interface SMAgg : NSObject
@property (nonatomic) double total;
@property (nonatomic) long plays;
@property (nonatomic, strong) NSArray<NSDictionary *> *tracks;  // t, a, key, sec, plays
@property (nonatomic, strong) NSArray<NSDictionary *> *artists; // name, sec, plays, key (titre pour la pochette)
@property (nonatomic, strong) NSArray<NSNumber *> *buckets;
@property (nonatomic, strong) NSArray<NSString *> *bucketLabels;
@end
@implementation SMAgg
@end

static NSArray<NSString *> *SMSplitArtists(NSString *a) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *part in [a componentsSeparatedByString:@", "]) {
        NSString *p = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (p.length && ![out containsObject:p]) [out addObject:p];
    }
    if (!out.count) [out addObject:a.length ? a : @"Artiste inconnu"];
    return out;
}

static SMAgg *SMAggregate(SMRange r, NSDate *start, NSDate *end) {
    NSCalendar *cal = SMCal();
    NSInteger nb = r == SMRangeDay ? 24 : r == SMRangeWeek ? 7 : r == SMRangeYear ? 12 :
        [cal rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:start].length;
    double buckets[31] = {0};
    NSMutableDictionary<NSString *, NSMutableArray *> *tracks = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *keyAlias = [NSMutableDictionary dictionary]; // clé regroupée → clé d'origine
    double total = 0;
    for (NSDate *d = start; [d compare:end] == NSOrderedAscending; d = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:d options:0]) {
        NSString *dk = [SMDayFormatter() stringFromDate:d];
        // Jour importé en priorité, sinon le plus complet entre le relevé de l'iPhone et les dernières écoutes du compte
        NSDictionary *loc = gDays[dk], *rec = gRecentDays[dk];
        NSDictionary *day = gImportDays[dk] ?: ([rec[@"tot"] doubleValue] > [loc[@"tot"] doubleValue] ? rec : loc);
        if (![day isKindOfClass:NSDictionary.class]) continue;
        double tot = [day[@"tot"] doubleValue];
        total += tot;
        if (r == SMRangeDay) {
            NSArray *h = day[@"h"];
            for (NSInteger i = 0; i < 24 && i < (NSInteger)h.count; i++) buckets[i] += [h[i] doubleValue];
        } else {
            NSInteger idx;
            if (r == SMRangeWeek) idx = ([cal component:NSCalendarUnitWeekday fromDate:d] + 5) % 7; // lundi = 0
            else if (r == SMRangeMonth) idx = [cal component:NSCalendarUnitDay fromDate:d] - 1;
            else idx = [cal component:NSCalendarUnitMonth fromDate:d] - 1;
            if (idx >= 0 && idx < nb) buckets[idx] += tot;
        }
        NSDictionary *tr = day[@"tr"];
        for (NSString *rawKey in tr) {
            NSArray *e = tr[rawKey];
            if (![e isKindOfClass:NSArray.class] || e.count < 2) continue;
            // Même titre enregistré avec « • Lossless » dans l'artiste : regroupé
            NSArray *kp = [rawKey componentsSeparatedByString:@"—"];
            NSString *k = kp.count == 2 ? [NSString stringWithFormat:@"%@—%@", kp[0], SMCleanArtist(kp[1])] : rawKey;
            if (!keyAlias[k]) keyAlias[k] = rawKey;
            NSMutableArray *acc = tracks[k];
            if (!acc) { acc = [@[@0.0, @0, @0] mutableCopy]; tracks[k] = acc; }
            acc[0] = @([acc[0] doubleValue] + [e[0] doubleValue]);
            acc[1] = @([acc[1] integerValue] + [e[1] integerValue]);
            // Anciennes données sans écoutes complètes : on reprend les écoutes de 30 s
            acc[2] = @([acc[2] integerValue] + (e.count >= 3 ? [e[2] integerValue] : [e[1] integerValue]));
        }
    }
    NSMutableArray *trackList = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *artists = [NSMutableDictionary dictionary];
    long plays = 0;
    for (NSString *k in tracks) {
        double sec = [tracks[k][0] doubleValue];
        long p = [tracks[k][1] integerValue];
        long full = [tracks[k][2] integerValue];
        if (sec < 1) continue;
        plays += p;
        NSString *orig = keyAlias[k] ?: k;
        NSDictionary *meta = gTracks[k] ?: gTracks[orig] ?: gRecentTracks[k] ?: gImportTracks[k];
        NSString *t = meta[@"t"] ?: [k componentsSeparatedByString:@"—"].firstObject;
        NSString *a = SMCleanArtist(meta[@"a"] ?: @"");
        NSString *img = [meta[@"img"] length] ? meta[@"img"] : [meta[@"img2"] length] ? meta[@"img2"] :
                        ([gRecentTracks[k][@"img"] isKindOfClass:NSString.class] ? gRecentTracks[k][@"img"] : @"");
        [trackList addObject:@{@"t": t, @"a": a, @"key": gTracks[k] ? k : orig, @"sec": @(sec), @"plays": @(p), @"full": @(full), @"url": img}];
        for (NSString *name in SMSplitArtists(a)) {
            NSMutableDictionary *ar = artists[name];
            if (!ar) { ar = [@{@"name": name, @"sec": @0.0, @"plays": @0, @"key": k, @"best": @0.0, @"url": img} mutableCopy]; artists[name] = ar; }
            ar[@"sec"] = @([ar[@"sec"] doubleValue] + sec);
            ar[@"plays"] = @([ar[@"plays"] integerValue] + p);
            if (sec > [ar[@"best"] doubleValue]) { ar[@"best"] = @(sec); ar[@"key"] = k; ar[@"url"] = img; } // pochette de son titre le plus écouté
        }
    }
    NSSortDescriptor *bySec = [NSSortDescriptor sortDescriptorWithKey:@"sec" ascending:NO];
    SMAgg *agg = [SMAgg new];
    agg.total = total;
    agg.plays = plays;
    agg.tracks = [trackList sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"full" ascending:NO], bySec]];
    agg.artists = [artists.allValues sortedArrayUsingDescriptors:@[bySec]];
    NSMutableArray *b = [NSMutableArray array], *labels = [NSMutableArray array];
    NSArray *week = @[@"L", @"M", @"M", @"J", @"V", @"S", @"D"];
    NSArray *year = @[@"J", @"F", @"M", @"A", @"M", @"J", @"J", @"A", @"S", @"O", @"N", @"D"];
    for (NSInteger i = 0; i < nb; i++) {
        [b addObject:@(buckets[i])];
        if (r == SMRangeDay) [labels addObject:i % 6 == 0 ? [NSString stringWithFormat:@"%ld h", (long)i] : @""];
        else if (r == SMRangeWeek) [labels addObject:week[i]];
        else if (r == SMRangeMonth) [labels addObject:(i % 7 == 0) ? [NSString stringWithFormat:@"%ld", (long)i + 1] : @""];
        else [labels addObject:year[i]];
    }
    agg.buckets = b;
    agg.bucketLabels = labels;
    return agg;
}

#pragma mark - Historique envoyé par Spotify

static NSDate *SMParseStreamDate(NSString *s) {
    static NSISO8601DateFormatter *iso;
    static NSDateFormatter *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iso = [NSISO8601DateFormatter new];
        plain = [NSDateFormatter new];
        plain.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        plain.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        plain.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    @synchronized (iso) {
        return [iso dateFromString:s] ?: [plain dateFromString:s];
    }
}

/// Fichiers JSON de Spotify : historique étendu (ts, ms_played, master_metadata_…) ou données du compte
/// (endTime, msPlayed, artistName, trackName). Chaque écoute est rangée au jour et à l'heure où elle s'est terminée.
static NSDictionary *SMReadSpotifyHistory(NSArray<NSURL *> *urls) {
    NSMutableDictionary *days = [NSMutableDictionary dictionary], *tracks = [NSMutableDictionary dictionary];
    NSDateFormatter *dayF = [NSDateFormatter new];
    dayF.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dayF.dateFormat = @"yyyy-MM-dd";
    NSCalendar *cal = NSCalendar.currentCalendar;
    long streams = 0;
    int files = 0;
    NSDate *first = nil, *last = nil;
    for (NSURL *url in urls) {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (scoped) [url stopAccessingSecurityScopedResource];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSArray.class]) continue;
        BOOL any = NO;
        for (NSDictionary *it in json) {
            if (![it isKindOfClass:NSDictionary.class]) continue;
            id t = it[@"master_metadata_track_name"] ?: it[@"trackName"];
            id a = it[@"master_metadata_album_artist_name"] ?: it[@"artistName"];
            id al = it[@"master_metadata_album_album_name"];
            id ms = it[@"ms_played"] ?: it[@"msPlayed"];
            id ts = it[@"ts"] ?: it[@"endTime"];
            if (![t isKindOfClass:NSString.class] || ![ts isKindOfClass:NSString.class] || ![ms isKindOfClass:NSNumber.class]) continue;
            double sec = [ms doubleValue] / 1000.0;
            if (sec < 1) continue;
            NSDate *end = SMParseStreamDate(ts);
            if (!end) continue;
            NSString *artist = [a isKindOfClass:NSString.class] ? a : @"";
            NSString *key = [NSString stringWithFormat:@"%@\u2014%@", t, artist];
            NSString *dk = [dayF stringFromDate:end];
            NSMutableDictionary *day = days[dk];
            if (!day) {
                NSMutableArray *hours = [NSMutableArray array];
                for (int i = 0; i < 24; i++) [hours addObject:@0];
                day = [@{@"tot": @0, @"h": hours, @"tr": [NSMutableDictionary dictionary]} mutableCopy];
                days[dk] = day;
            }
            day[@"tot"] = @([day[@"tot"] doubleValue] + sec);
            NSInteger hour = [cal component:NSCalendarUnitHour fromDate:end];
            NSMutableArray *hours = day[@"h"];
            hours[hour] = @([hours[hour] doubleValue] + sec);
            NSMutableDictionary *tr = day[@"tr"];
            NSMutableArray *e = tr[key];
            if (!e) { e = [@[@0, @0, @0] mutableCopy]; tr[key] = e; }
            e[0] = @([e[0] doubleValue] + sec);
            if (sec >= 30) e[1] = @([e[1] integerValue] + 1);
            // Historique étendu : « trackdone » = titre écouté jusqu'au bout ; données du compte : écoute de 30 s et plus
            id reason = it[@"reason_end"];
            BOOL full = [reason isKindOfClass:NSString.class] ? [reason isEqualToString:@"trackdone"] : sec >= 30;
            if (full) e[2] = @([e[2] integerValue] + 1);
            if (!tracks[key]) tracks[key] = @{@"t": t, @"a": artist, @"al": [al isKindOfClass:NSString.class] ? al : @""};
            if (!first || [end compare:first] == NSOrderedAscending) first = end;
            if (!last || [end compare:last] == NSOrderedDescending) last = end;
            streams++;
            any = YES;
        }
        if (any) files++;
    }
    return @{@"days": days, @"tracks": tracks, @"streams": @(streams), @"files": @(files),
             @"from": first ? [dayF stringFromDate:first] : @"", @"until": last ? [dayF stringFromDate:last] : @""};
}

/// Pochette d'un titre ; pour un titre importé (sans pochette), celle du même titre écouté sur l'iPhone.
/// Pochette relevée sur l'iPhone mais identique à celle d'un autre album : c'était celle du titre précédent.
static BOOL SMArtLooksWrong(NSString *key, NSString *path) {
    static NSMutableDictionary *verdict;
    if (!verdict) verdict = [NSMutableDictionary dictionary];
    if (verdict[key]) return [verdict[key] boolValue];
    NSData *mine = [NSData dataWithContentsOfFile:path];
    NSString *album = gTracks[key][@"al"] ?: @"";
    BOOL wrong = NO;
    for (NSString *k in gTracks) {
        if ([k isEqualToString:key]) continue;
        NSString *otherAlbum = gTracks[k][@"al"] ?: @"";
        if (!album.length || [otherAlbum isEqualToString:album]) continue;
        NSString *q = SMArtPath(k);
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:q error:nil];
        if (!attrs || [attrs fileSize] != mine.length) continue;
        if ([[NSData dataWithContentsOfFile:q] isEqualToData:mine]) { wrong = YES; break; }
    }
    verdict[key] = @(wrong);
    return wrong;
}

static NSString *SMArtFor(NSString *key, NSString *title) {
    NSString *p = SMArtPath(key);
    if ([NSFileManager.defaultManager fileExistsAtPath:p]) return SMArtLooksWrong(key, p) ? nil : p;
    NSString *low = title.lowercaseString;
    NSString *artistPart = [key componentsSeparatedByString:@"\u2014"].lastObject.lowercaseString;
    for (NSString *k in gTracks) {
        NSDictionary *m = gTracks[k];
        BOOL sameTitle = low && [[m[@"t"] lowercaseString] isEqualToString:low];
        BOOL sameArtist = !low && artistPart.length && [[m[@"a"] lowercaseString] hasPrefix:artistPart];
        if (!sameTitle && !sameArtist) continue;
        NSString *q = SMArtPath(k);
        if ([NSFileManager.defaultManager fileExistsAtPath:q]) return q;
    }
    return nil;
}

#pragma mark - Graphique

@interface SMBarChart : UIView
@property (nonatomic, strong) NSArray<NSNumber *> *values;
@property (nonatomic, strong) NSArray<NSString *> *labels;
@end

@implementation SMBarChart
- (void)drawRect:(CGRect)rect {
    NSUInteger n = self.values.count;
    if (!n) return;
    double max = 0;
    NSUInteger best = 0;
    for (NSUInteger i = 0; i < n; i++) if (self.values[i].doubleValue > max) { max = self.values[i].doubleValue; best = i; }
    CGFloat labelH = 18, h = self.bounds.size.height - labelH, w = self.bounds.size.width;
    CGFloat slot = w / n, bar = MAX(2, MIN(22, slot * 0.6));
    NSDictionary *attrs = @{NSFontAttributeName: SMFont(11, NO), NSForegroundColorAttributeName: SM_GRAY};
    for (NSUInteger i = 0; i < n; i++) {
        double v = self.values[i].doubleValue;
        CGFloat bh = max > 0 ? MAX(v > 0 ? 3 : 2, h * v / max) : 2;
        CGRect r = CGRectMake(slot * i + (slot - bar) / 2, h - bh, bar, bh);
        [(v > 0 && i == best ? SM_GREEN : (v > 0 ? SMC(0x535353) : SMC(0x2A2A2A))) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:MIN(3, bar / 2)] fill];
        NSString *l = i < self.labels.count ? self.labels[i] : @"";
        if (l.length) {
            CGSize s = [l sizeWithAttributes:attrs];
            [l drawAtPoint:CGPointMake(slot * i + (slot - s.width) / 2, h + 3) withAttributes:attrs];
        }
    }
}
@end

#pragma mark - Cellule

@interface SMStatCell : UITableViewCell
@property (nonatomic, strong) UILabel *rank, *title, *sub, *value;
@property (nonatomic, strong) UIImageView *art;
@end

@implementation SMStatCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.backgroundColor = SM_BG;
        UIView *sel = [UIView new];
        sel.backgroundColor = SM_CARD;
        self.selectedBackgroundView = sel;
        _rank = [UILabel new];
        _rank.font = SMFont(16, YES);
        _rank.textColor = UIColor.whiteColor;
        _rank.textAlignment = NSTextAlignmentCenter;
        _art = [UIImageView new];
        _art.contentMode = UIViewContentModeScaleAspectFill;
        _art.clipsToBounds = YES;
        _art.backgroundColor = SM_PILL;
        _title = [UILabel new];
        _title.font = SMFont(16, YES);
        _title.textColor = UIColor.whiteColor;
        _sub = [UILabel new];
        _sub.font = SMFont(13, NO);
        _sub.textColor = SM_GRAY;
        _value = [UILabel new];
        _value.font = SMFont(14, YES);
        _value.textColor = UIColor.whiteColor;
        _value.textAlignment = NSTextAlignmentRight;
        for (UIView *v in @[_rank, _art, _title, _sub, _value]) [self.contentView addSubview:v];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width, h = self.contentView.bounds.size.height;
    _rank.frame = CGRectMake(8, 0, 30, h);
    _art.frame = CGRectMake(44, (h - 52) / 2, 52, 52);
    [_value sizeToFit];
    CGFloat vw = MAX(54, _value.bounds.size.width);
    _value.frame = CGRectMake(w - vw - 16, 0, vw, h);
    CGFloat x = 108, tw = w - x - vw - 24;
    _title.frame = CGRectMake(x, h / 2 - 21, tw, 21);
    _sub.frame = CGRectMake(x, h / 2 + 1, tw, 18);
}
@end

#pragma mark - Écran « Stats d'écoute »

@interface SMStatsController : UIViewController <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@end

@implementation SMStatsController {
    UITableView *_table;
    UIView *_bar;
    SMRange _range;
    NSInteger _offset;
    SMAgg *_agg;
    BOOL _moreArtists, _moreTracks;
    BOOL _navWasHidden;
    NSArray<UIButton *> *_pills;
    UILabel *_period, *_headline, *_summary;
    UIButton *_prev, *_next;
    SMBarChart *_chart;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = SM_BG;
    _range = [NSUserDefaults.standardUserDefaults integerForKey:@"SoundMatch.statsRange"];
    if (_range < SMRangeDay || _range > SMRangeSpotify) _range = SMRangeWeek;

    // Barre du haut comme les écrans de Spotify : retour à gauche, titre au centre
    _bar = [UIView new];
    _bar.translatesAutoresizingMaskIntoConstraints = NO;
    _bar.backgroundColor = SM_BG;
    [self.view addSubview:_bar];
    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    back.tintColor = UIColor.whiteColor;
    [back addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:back];
    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Stats d'écoute";
    title.font = SMFont(17, YES);
    title.textColor = UIColor.whiteColor;
    [_bar addSubview:title];
    UIButton *imp = [UIButton buttonWithType:UIButtonTypeSystem];
    imp.translatesAutoresizingMaskIntoConstraints = NO;
    [imp setImage:[UIImage systemImageNamed:@"square.and.arrow.down" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    imp.tintColor = UIColor.whiteColor;
    [imp addTarget:self action:@selector(importTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:imp];
    UIButton *shr = [UIButton buttonWithType:UIButtonTypeSystem];
    shr.translatesAutoresizingMaskIntoConstraints = NO;
    [shr setImage:[UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    shr.tintColor = UIColor.whiteColor;
    [shr addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:shr];
    [NSLayoutConstraint activateConstraints:@[
        [shr.trailingAnchor constraintEqualToAnchor:imp.leadingAnchor constant:-2],
        [shr.centerYAnchor constraintEqualToAnchor:_bar.centerYAnchor],
        [shr.widthAnchor constraintEqualToConstant:44],
        [shr.heightAnchor constraintEqualToConstant:44],
        [imp.trailingAnchor constraintEqualToAnchor:_bar.trailingAnchor constant:-8],
        [imp.centerYAnchor constraintEqualToAnchor:_bar.centerYAnchor],
        [imp.widthAnchor constraintEqualToConstant:44],
        [imp.heightAnchor constraintEqualToConstant:44],
    ]];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.backgroundColor = SM_BG;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 72;
    if (@available(iOS 15.0, *)) _table.sectionHeaderTopPadding = 0;
    [_table registerClass:SMStatCell.class forCellReuseIdentifier:@"c"];
    [self.view addSubview:_table];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_bar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_bar.heightAnchor constraintEqualToConstant:48],
        [back.leadingAnchor constraintEqualToAnchor:_bar.leadingAnchor constant:8],
        [back.centerYAnchor constraintEqualToAnchor:_bar.centerYAnchor],
        [back.widthAnchor constraintEqualToConstant:44],
        [back.heightAnchor constraintEqualToConstant:44],
        [title.centerXAnchor constraintEqualToAnchor:_bar.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:_bar.centerYAnchor],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self buildHeader];
    [self reload];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artUpdated) name:@"SMArtUpdated" object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _navWasHidden = self.navigationController.navigationBarHidden;
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    SMStatsSave(); // les dernières secondes écoutées sont prises en compte
    [self reload];
    __weak SMStatsController *weakSelf = self;
    SMFetchRecent(^{ [weakSelf reload]; });
}

- (void)artUpdated {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadRowsSoon) object:nil];
    [self performSelector:@selector(reloadRowsSoon) withObject:nil afterDelay:0.4];
}

- (void)reloadRowsSoon {
    if (_range == SMRangeSpotify) return;
    BOOL ma = _moreArtists, mt = _moreTracks;
    CGPoint off = _table.contentOffset;
    [self reload];
    _moreArtists = ma;
    _moreTracks = mt;
    [_table reloadData];
    _table.contentOffset = off; // l'image arrive sans faire sauter la liste
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (!_navWasHidden) [self.navigationController setNavigationBarHidden:NO animated:animated];
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)close {
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)buildHeader {
    UIView *header = [UIView new];
    header.backgroundColor = SM_BG;

    // Filtres : Jour, Semaine, Mois, Année (pastilles comme « Tout / Musique / Podcasts »)
    NSMutableArray *pills = [NSMutableArray array];
    NSArray *names = @[@"Jour", @"Semaine", @"Mois", @"Année", @"Classement"];
    for (NSUInteger i = 0; i < names.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        [b setTitle:names[i] forState:UIControlStateNormal];
        b.titleLabel.font = SMFont(14, NO);
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 16);
        b.layer.cornerRadius = 16;
        b.tag = i;
        [b addTarget:self action:@selector(pill:) forControlEvents:UIControlEventTouchUpInside];
        [pills addObject:b];
    }
    _pills = pills;
    UIStackView *pillRow = [[UIStackView alloc] initWithArrangedSubviews:pills];
    pillRow.spacing = 8;
    for (UIButton *b in pills) [b.heightAnchor constraintEqualToConstant:32].active = YES;

    // Période : ‹ 16–22 nov. ›
    _prev = [self arrow:@"chevron.left" action:@selector(prevPeriod)];
    _next = [self arrow:@"chevron.right" action:@selector(nextPeriod)];
    _period = [UILabel new];
    _period.font = SMFont(15, YES);
    _period.textColor = SM_GRAY;
    _period.textAlignment = NSTextAlignmentCenter;
    UIStackView *nav = [[UIStackView alloc] initWithArrangedSubviews:@[_prev, _period, _next]];
    nav.alignment = UIStackViewAlignmentCenter;

    _headline = [UILabel new];
    _headline.numberOfLines = 0;
    _summary = [UILabel new];
    _summary.numberOfLines = 0;
    _summary.font = SMFont(14, NO);
    _summary.textColor = SM_GRAY;

    _chart = [SMBarChart new];
    _chart.backgroundColor = SM_BG;
    [_chart.heightAnchor constraintEqualToConstant:110].active = YES;

    // Filtres et période fixes sous la barre du haut (ils ne défilent pas avec la liste)
    UIView *filters = [UIView new];
    filters.translatesAutoresizingMaskIntoConstraints = NO;
    filters.backgroundColor = SM_BG;
    pillRow.translatesAutoresizingMaskIntoConstraints = NO;
    nav.translatesAutoresizingMaskIntoConstraints = NO;
    [filters addSubview:pillRow];
    [filters addSubview:nav];
    [self.view addSubview:filters];
    [NSLayoutConstraint activateConstraints:@[
        [filters.topAnchor constraintEqualToAnchor:_bar.bottomAnchor],
        [filters.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [filters.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [pillRow.topAnchor constraintEqualToAnchor:filters.topAnchor constant:4],
        [pillRow.leadingAnchor constraintEqualToAnchor:filters.leadingAnchor constant:16],
        [pillRow.trailingAnchor constraintLessThanOrEqualToAnchor:filters.trailingAnchor constant:-16],
        [nav.topAnchor constraintEqualToAnchor:pillRow.bottomAnchor constant:8],
        [nav.leadingAnchor constraintEqualToAnchor:filters.leadingAnchor constant:8],
        [nav.trailingAnchor constraintEqualToAnchor:filters.trailingAnchor constant:-8],
        [nav.bottomAnchor constraintEqualToAnchor:filters.bottomAnchor constant:-2],
        [_table.topAnchor constraintEqualToAnchor:filters.bottomAnchor],
    ]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_headline, _summary, _chart]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 6;
    [stack setCustomSpacing:22 afterView:_summary];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12],
    ]];
    _table.tableHeaderView = header;
}

- (UIButton *)arrow:(NSString *)symbol action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [b.widthAnchor constraintEqualToConstant:40].active = YES;
    [b.heightAnchor constraintEqualToConstant:36].active = YES;
    return b;
}

- (void)pill:(UIButton *)b {
    _range = b.tag;
    _offset = 0;
    [NSUserDefaults.standardUserDefaults setInteger:_range forKey:@"SoundMatch.statsRange"];
    [self reload];
}

- (void)prevPeriod { if (_range == SMRangeSpotify && _offset <= -2) return; _offset--; [self reload]; }
- (void)nextPeriod { if (_offset < 0) { _offset++; [self reload]; } }

- (void)resizeHeader {
    UIView *header = _table.tableHeaderView;
    CGFloat w = _table.bounds.size.width > 0 ? _table.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    header.frame = CGRectMake(0, 0, w, 10);
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGSize fit = [header systemLayoutSizeFittingSize:CGSizeMake(w, 0) withHorizontalFittingPriority:UILayoutPriorityRequired
                               verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    header.frame = CGRectMake(0, 0, w, fit.height);
    _table.tableHeaderView = header;
    [_table reloadData];
}

/// Classement calculé par Spotify pour ton compte (4 semaines, 6 mois, environ 1 an).
- (void)reloadSpotify {
    NSArray *terms = @[@"short_term", @"medium_term", @"long_term"];
    NSInteger idx = MIN(2, MAX(0, -_offset));
    _period.text = @[@"4 dernières semaines", @"6 derniers mois", @"Environ 1 an"][idx];
    _next.enabled = _offset < 0;
    _next.alpha = _offset < 0 ? 1 : 0.3;
    _prev.enabled = idx < 2;
    _prev.alpha = idx < 2 ? 1 : 0.3;
    NSDictionary *top = gSpotifyTop[terms[idx]];
    SMAgg *agg = [SMAgg new];
    agg.artists = [top[@"artists"] isKindOfClass:NSArray.class] ? top[@"artists"] : @[];
    agg.tracks = [top[@"tracks"] isKindOfClass:NSArray.class] ? top[@"tracks"] : @[];
    agg.total = (agg.artists.count || agg.tracks.count) ? 1 : 0;
    _agg = agg;
    NSMutableAttributedString *h = [[NSMutableAttributedString alloc] initWithString:@"Ton classement "
        attributes:@{NSFontAttributeName: SMFont(28, YES), NSForegroundColorAttributeName: UIColor.whiteColor}];
    [h appendAttributedString:[[NSAttributedString alloc] initWithString:@"Spotify"
        attributes:@{NSFontAttributeName: SMFont(28, YES), NSForegroundColorAttributeName: SM_GREEN}]];
    _headline.attributedText = h;
    NSString *when = gSpotifyTopAt ? [NSString stringWithFormat:@" · mis à jour %@", SMFr(@"d MMM 'à' HH:mm", gSpotifyTopAt)] : @"";
    _summary.text = gSpotifyStatus ?: (gFetchingTop ? @"Récupération du classement…" :
        [NSString stringWithFormat:@"Calculé par Spotify pour ton compte (Spotify ne donne pas les minutes de ce classement)%@", when]);
    _chart.hidden = YES;
    [self resizeHeader];
    BOOL canRetry = !gTopFailAt || CFAbsoluteTimeGetCurrent() - gTopFailAt > 600;
    if (!gFetchingTop && canRetry && (!gSpotifyTopAt || -gSpotifyTopAt.timeIntervalSinceNow > 1800)) {
        __weak SMStatsController *weakSelf = self;
        SMFetchTop(^{ SMStatsController *me = weakSelf; if (me && me->_range == SMRangeSpotify) [me reload]; });
        if (gFetchingTop) _summary.text = @"Récupération du classement…";
    }
}

- (void)reload {
    if (!_table) return;
    for (UIButton *p in _pills) {
        BOOL on = p.tag == _range;
        p.backgroundColor = on ? SM_GREEN : SM_PILL;
        [p setTitleColor:on ? UIColor.blackColor : UIColor.whiteColor forState:UIControlStateNormal];
    }
    _moreArtists = _moreTracks = NO;
    _prev.enabled = YES;
    _prev.alpha = 1;
    if (_range == SMRangeSpotify) { [self reloadSpotify]; return; }
    NSDate *start, *end;
    SMPeriod(_range, _offset, &start, &end);
    _agg = SMAggregate(_range, start, end);
    _period.text = SMPeriodLabel(_range, _offset, start, end);
    _next.enabled = _offset < 0;
    _next.alpha = _offset < 0 ? 1 : 0.3;

    long minutes = lround(_agg.total / 60.0);
    NSMutableAttributedString *h = [[NSMutableAttributedString alloc] initWithString:@"Vous avez écouté\n"
        attributes:@{NSFontAttributeName: SMFont(28, YES), NSForegroundColorAttributeName: UIColor.whiteColor}];
    [h appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ minute%@", SMGroup(minutes), minutes > 1 ? @"s" : @""]
        attributes:@{NSFontAttributeName: SMFont(28, YES), NSForegroundColorAttributeName: SM_GREEN}]];
    [h appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:SMRangeWord(_range, _offset)]
        attributes:@{NSFontAttributeName: SMFont(28, YES), NSForegroundColorAttributeName: UIColor.whiteColor}]];
    _headline.attributedText = h;

    NSMutableArray *parts = [NSMutableArray array];
    if (minutes >= 60) [parts addObject:[NSString stringWithFormat:@"soit %@", SMMinutes(_agg.total)]];
    [parts addObject:[NSString stringWithFormat:@"%lu titre%@", (unsigned long)_agg.tracks.count, _agg.tracks.count > 1 ? @"s" : @""]];
    [parts addObject:[NSString stringWithFormat:@"%lu artiste%@", (unsigned long)_agg.artists.count, _agg.artists.count > 1 ? @"s" : @""]];
    [parts addObject:[NSString stringWithFormat:@"%ld écoute%@", _agg.plays, _agg.plays > 1 ? @"s" : @""]];
    NSString *summary = [parts componentsJoinedByString:@" · "];
    if (gImportUntil) {
        NSDate *u = [SMDayFormatter() dateFromString:gImportUntil];
        summary = [summary stringByAppendingFormat:@"\nHistorique Spotify importé jusqu'au %@, puis relevé sur l'iPhone", u ? SMFr(@"d MMMM yyyy", u) : gImportUntil];
    }
    if (gRecentDays.count) summary = [summary stringByAppendingString:@"\nAvec les dernières écoutes de ton compte Spotify (tous appareils)"];
    _summary.text = summary;

    _chart.values = _agg.buckets;
    _chart.labels = _agg.bucketLabels;
    _chart.hidden = _agg.total < 1;
    [_chart setNeedsDisplay];
    [self resizeHeader];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = _table.tableHeaderView;
    if (header && fabs(header.bounds.size.width - _table.bounds.size.width) > 1) [self reload];
}

#pragma mark Affiche à partager

- (void)shareTapped {
    if (_agg.total < 1) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Rien à partager" message:@"Aucune écoute sur cette période."
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    BOOL top = _range == SMRangeSpotify;
    NSMutableArray *artists = [NSMutableArray array], *tracks = [NSMutableArray array];
    for (NSDictionary *a in _agg.artists) { if (artists.count == 5) break; [artists addObject:a[@"name"] ?: @""]; }
    for (NSDictionary *t in _agg.tracks) { if (tracks.count == 5) break; [tracks addObject:t[@"t"] ?: @""]; }
    NSDictionary *a0 = _agg.artists.firstObject, *t0 = _agg.tracks.firstObject;
    NSString *artistImg = top ? a0[@"img"] : gArtistImg[[a0[@"name"] lowercaseString]];
    NSString *trackImg = top ? t0[@"img"] : ([t0[@"url"] length] ? t0[@"url"] : SMArtFor(t0[@"key"], t0[@"t"]));
    long minutes = lround(_agg.total / 60.0);
    NSString *min = top ? nil : [NSString stringWithFormat:@"%@ minute%@", SMGroup(minutes), minutes > 1 ? @"s" : @""];
    SMPosterPresent(self, _period.text, min, artists, tracks, artistImg, trackImg);
}

#pragma mark Import de l'historique Spotify

- (void)importTapped {
    NSString *msg = @"Spotify garde tout ton historique d'écoute avec les minutes, mais ne le donne que sur demande :\n\n"
        "1. Sur spotify.com (navigateur) : Profil › Compte › Confidentialité du compte, coche « Historique de streaming étendu » "
        "(tout depuis la création du compte) et/ou « Données du compte » (la dernière année), puis Demander les données.\n"
        "2. Spotify t'envoie un mail avec un fichier .zip (quelques jours ; jusqu'à 30 jours pour l'historique étendu).\n"
        "3. Enregistre-le dans Fichiers et touche-le pour le décompresser.\n"
        "4. Ici : Choisir les fichiers, puis sélectionne TOUS les fichiers Streaming_History_Audio_….json "
        "(ou StreamingHistory_music_….json).";
    if (gImportUntil) msg = [msg stringByAppendingFormat:@"\n\nHistorique actuel importé jusqu'au %@.", gImportUntil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Importer mon historique Spotify" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Choisir les fichiers" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSArray *types = @[UTTypeJSON, UTTypePlainText, UTTypeData];
        UIDocumentPickerViewController *pk = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        pk.allowsMultipleSelection = YES;
        pk.delegate = self;
        [self presentViewController:pk animated:YES completion:nil];
    }]];
    if (gImportDays) {
        [a addAction:[UIAlertAction actionWithTitle:@"Supprimer l'historique importé" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            gImportDays = nil;
            gImportTracks = nil;
            gImportUntil = nil;
            [NSFileManager.defaultManager removeItemAtPath:SMImportPath() error:nil];
            SMLogPublic(@"Stats : historique importé supprimé");
            [self reload];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    _summary.text = @"Import en cours…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *res = SMReadSpotifyHistory(urls);
        dispatch_async(dispatch_get_main_queue(), ^{
            long streams = [res[@"streams"] longValue];
            NSString *text;
            if (streams > 0) {
                gImportDays = [res[@"days"] mutableCopy];
                gImportTracks = [res[@"tracks"] mutableCopy];
                gImportUntil = res[@"until"];
                NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"days": gImportDays, @"tracks": gImportTracks, @"until": gImportUntil} options:0 error:nil];
                [d writeToFile:SMImportPath() atomically:YES];
                text = [NSString stringWithFormat:@"%@ écoutes importées (%@ fichier%@), du %@ au %@.", SMGroup(streams), res[@"files"],
                        [res[@"files"] intValue] > 1 ? @"s" : @"", res[@"from"], res[@"until"]];
            } else {
                text = [NSString stringWithFormat:@"Aucune écoute trouvée dans ces %lu fichier(s). Choisis les fichiers Streaming_History_Audio_….json ou StreamingHistory_music_….json (décompresse d'abord le .zip).", (unsigned long)urls.count];
            }
            SMLogPublic([@"Stats : import — " stringByAppendingString:text]);
            [self reload];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:streams > 0 ? @"Historique importé" : @"Import impossible"
                                                                       message:text preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return _agg.total < 1 ? 1 : 2; }

- (NSArray *)itemsFor:(NSInteger)section {
    if (_agg.total < 1) return @[];
    NSArray *all = section == 0 ? _agg.artists : _agg.tracks;
    NSUInteger limit = (section == 0 ? _moreArtists : _moreTracks) ? 50 : 5;
    return all.count > limit ? [all subarrayWithRange:NSMakeRange(0, limit)] : all;
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (_agg.total < 1) return 1;
    return [self itemsFor:s].count;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    SMStatCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    if (_agg.total < 1) {
        c.rank.text = @"";
        c.art.hidden = YES;
        c.value.text = @"";
        BOOL top = _range == SMRangeSpotify;
        c.title.text = top ? @"Classement pas encore disponible" : @"Aucune écoute sur cette période";
        c.sub.text = top ? (gSpotifyStatus ?: @"Récupération en cours…") : @"Les stats sont relevées depuis l'installation de SoundMatch.";
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    c.art.hidden = NO;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    NSDictionary *it = [self itemsFor:ip.section][ip.row];
    c.rank.text = [NSString stringWithFormat:@"%ld", (long)ip.row + 1];
    double sec = [it[@"sec"] doubleValue];
    long plays = [it[@"plays"] integerValue];
    c.value.text = SMMinutes(sec);
    c.art.image = nil;
    c.art.contentMode = UIViewContentModeScaleAspectFill;
    if (_range == SMRangeSpotify) {
        c.value.text = @"";
        c.title.text = ip.section == 0 ? it[@"name"] : it[@"t"];
        c.sub.text = ip.section == 0 ? it[@"sub"] : it[@"a"];
        c.art.layer.cornerRadius = ip.section == 0 ? 26 : 4;
        SMLoadRemote(it[@"img"], c.art);
        [c setNeedsLayout];
        return c;
    }
    if (ip.section == 0) {
        c.title.text = it[@"name"];
        c.sub.text = [NSString stringWithFormat:@"%ld écoute%@", plays, plays > 1 ? @"s" : @""];
        c.art.layer.cornerRadius = 26; // artistes en rond, comme dans Spotify
    } else {
        // Titres : classés et affichés en écoutes complètes, les minutes en dessous
        long full = [it[@"full"] integerValue];
        c.title.text = it[@"t"];
        c.value.text = [NSString stringWithFormat:@"%ld écoute%@", full, full > 1 ? @"s" : @""];
        c.sub.text = [NSString stringWithFormat:@"%@ · %@", it[@"a"], SMMinutes(sec)];
        c.art.layer.cornerRadius = 4;
    }
    c.art.accessibilityIdentifier = nil;
    if (ip.section == 0) {
        // Artiste : sa vraie photo seulement (jamais une pochette) ; en attendant, une silhouette
        NSString *photo = gArtistImg[[it[@"name"] lowercaseString]];
        if (photo.length) SMLoadRemote(photo, c.art);
        else {
            c.art.image = [UIImage systemImageNamed:@"person.fill"];
            c.art.tintColor = SM_GRAY;
            c.art.contentMode = UIViewContentModeCenter;
            SMResolveTrack(it[@"key"]);
            SMFindArtistPhoto(it[@"name"]);
        }
    } else {
        // Titre : pochette officielle (Spotify, sinon recherche), puis celle relevée sur l'iPhone
        NSString *remote = it[@"url"];
        if (remote.length) SMLoadRemote(remote, c.art);
        else {
            NSString *local = SMArtFor(it[@"key"], it[@"t"]);
            if (local) c.art.image = [UIImage imageWithContentsOfFile:local];
            SMResolveTrack(it[@"key"]);
            SMFindCover(it[@"key"]);
        }
    }
    [c setNeedsLayout];
    return c;
}

- (UIView *)tableView:(UITableView *)t viewForHeaderInSection:(NSInteger)s {
    if (_agg.total < 1) return nil;
    UIView *v = [UIView new];
    v.backgroundColor = SM_BG;
    UILabel *l = [UILabel new];
    l.text = s == 0 ? @"Top artistes" : @"Top titres";
    l.font = SMFont(22, YES);
    l.textColor = UIColor.whiteColor;
    l.frame = CGRectMake(16, 14, t.bounds.size.width - 32, 30);
    [v addSubview:l];
    return v;
}

- (CGFloat)tableView:(UITableView *)t heightForHeaderInSection:(NSInteger)s { return _agg.total < 1 ? 0 : 52; }

- (UIView *)tableView:(UITableView *)t viewForFooterInSection:(NSInteger)s {
    if (_agg.total < 1) return nil;
    NSArray *all = s == 0 ? _agg.artists : _agg.tracks;
    BOOL more = s == 0 ? _moreArtists : _moreTracks;
    if (all.count <= 5) return [UIView new];
    UIView *v = [UIView new];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:more ? @"Afficher moins" : @"Afficher plus" forState:UIControlStateNormal];
    b.titleLabel.font = SMFont(14, YES);
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.borderColor = SMC(0x7C7C7C).CGColor;
    b.layer.borderWidth = 1;
    b.layer.cornerRadius = 16;
    b.tag = s;
    [b addTarget:self action:@selector(toggleMore:) forControlEvents:UIControlEventTouchUpInside];
    CGSize sz = [b sizeThatFits:CGSizeZero];
    b.frame = CGRectMake((t.bounds.size.width - sz.width - 32) / 2, 10, sz.width + 32, 32);
    [v addSubview:b];
    return v;
}

- (CGFloat)tableView:(UITableView *)t heightForFooterInSection:(NSInteger)s {
    if (_agg.total < 1) return 24;
    NSArray *all = s == 0 ? _agg.artists : _agg.tracks;
    return all.count > 5 ? 56 : 12;
}

- (void)toggleMore:(UIButton *)b {
    if (b.tag == 0) _moreArtists = !_moreArtists; else _moreTracks = !_moreTracks;
    [_table reloadSections:[NSIndexSet indexSetWithIndex:b.tag] withRowAnimation:UITableViewRowAnimationAutomatic];
}
@end

UIViewController *SMStatsMakeController(void) {
    return [SMStatsController new];
}

#pragma mark - Lignes dans les paramètres de Spotify

static const NSInteger SMRowsTag = 0x5D5707;
static char SMInsetKey;

@interface SMRowControl : UIControl
@property (nonatomic, copy) void (^action)(void);
@end

@implementation SMRowControl
- (void)setHighlighted:(BOOL)h {
    [super setHighlighted:h];
    self.backgroundColor = h ? [UIColor colorWithWhite:1 alpha:0.08] : UIColor.clearColor;
}
- (void)fire { if (self.action) self.action(); }
@end

/// Polices des lignes de Spotify (titre en gras, description plus petite) relevées dans l'écran.
static void SMLearnFonts(UIView *root) {
    if (gFontBold && gFontRegular) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    int seen = 0;
    while (stack.count && seen < 1500) {
        UIView *v = stack.lastObject; [stack removeLastObject]; seen++;
        if ([v isKindOfClass:UILabel.class] && [(UILabel *)v text].length) {
            UIFont *f = [(UILabel *)v font];
            if ([f.fontName hasPrefix:@"."]) continue; // police système
            BOOL bold = (f.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) || [f.fontName.lowercaseString containsString:@"bold"];
            if (bold && !gFontBold) gFontBold = f.fontName;
            if (!bold && !gFontRegular) gFontRegular = f.fontName;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    if (gFontBold || gFontRegular) SMLogPublic([NSString stringWithFormat:@"Paramètres : polices de Spotify %@ / %@", gFontBold, gFontRegular]);
}

static UIView *SMMakeRows(NSArray<NSArray *> *rows, CGFloat width) {
    CGFloat rowH = 68, top = 8;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, top + rowH * rows.count + 8)];
    box.tag = SMRowsTag;
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSArray *r = rows[i];
        SMRowControl *row = [[SMRowControl alloc] initWithFrame:CGRectMake(0, top + rowH * i, width, rowH)];
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        row.action = r[3];
        [row addTarget:row action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:r[2] withConfiguration:
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular]]];
        icon.tintColor = UIColor.whiteColor;
        icon.contentMode = UIViewContentModeCenter;
        icon.frame = CGRectMake(16, 0, 28, rowH);
        icon.userInteractionEnabled = NO;
        [row addSubview:icon];
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(60, 13, width - 76, 22)];
        t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        t.text = r[0];
        t.font = SMFont(16, YES);
        t.textColor = UIColor.whiteColor;
        [row addSubview:t];
        UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(60, 36, width - 76, 18)];
        s.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        s.text = r[1];
        s.font = SMFont(13, NO);
        s.textColor = SM_GRAY;
        [row addSubview:s];
        UIImageView *chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:
            [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
        chev.tintColor = SM_GRAY;
        chev.contentMode = UIViewContentModeCenter;
        chev.frame = CGRectMake(width - 32, 0, 16, rowH);
        chev.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [row addSubview:chev];
        [box addSubview:row];
    }
    return box;
}

/// Liste qui défile sous le point touché : là où vont les lignes.
static UIScrollView *SMListAt(UIWindow *w, UIViewController *vc) {
    UIView *hit = [w hitTest:CGPointMake(CGRectGetMidX(w.bounds), w.bounds.size.height * 0.55) withEvent:nil];
    for (UIView *v = hit; v && v != vc.view.superview; v = v.superview) {
        if ([v isKindOfClass:UIScrollView.class] && v.bounds.size.height > w.bounds.size.height * 0.4 &&
            ![v isKindOfClass:UITextView.class] && v.bounds.size.width > w.bounds.size.width * 0.8)
            return (UIScrollView *)v;
    }
    return nil;
}

static void SMInstallRows(UIScrollView *sv, NSArray<NSArray *> *rows) {
    CGFloat width = sv.bounds.size.width;
    UIView *mine = [sv viewWithTag:SMRowsTag];
    if ([sv isKindOfClass:UITableView.class]) {
        UITableView *tv = (UITableView *)sv;
        if (mine) return;
        UIView *box = SMMakeRows(rows, width);
        UIView *old = tv.tableHeaderView;
        if (old) {
            UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, box.bounds.size.height + old.bounds.size.height)];
            [wrap addSubview:box];
            old.frame = CGRectMake(0, box.bounds.size.height, width, old.bounds.size.height);
            [wrap addSubview:old];
            tv.tableHeaderView = wrap;
        } else {
            tv.tableHeaderView = box;
        }
        return;
    }
    // Liste en grille (UICollectionView ou autre) : les lignes vont au-dessus du contenu, dans la marge du haut
    CGFloat h = 8 + 68 * rows.count + 8;
    if (!mine) {
        mine = SMMakeRows(rows, width);
        [sv addSubview:mine];
    }
    mine.frame = CGRectMake(0, -h, width, h);
    NSNumber *applied = objc_getAssociatedObject(sv, &SMInsetKey);
    if (!applied || fabs(sv.contentInset.top - applied.doubleValue) > 0.5) {
        BOOL atTop = sv.contentOffset.y <= -sv.adjustedContentInset.top + 2;
        UIEdgeInsets in = sv.contentInset;
        in.top += h;
        sv.contentInset = in;
        objc_setAssociatedObject(sv, &SMInsetKey, @(in.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (atTop) sv.contentOffset = CGPointMake(sv.contentOffset.x, -sv.adjustedContentInset.top);
    }
}

static void SMOpenStats(UIViewController *from) {
    // Plein écran : la barre et le lecteur de Spotify ne se superposent pas à l'écran des stats
    UIViewController *stats = SMStatsMakeController();
    stats.modalPresentationStyle = UIModalPresentationFullScreen;
    [from presentViewController:stats animated:YES completion:nil];
}

BOOL SMSettingsInject(NSArray<UIWindow *> *windows, void (^calibrate)(void), void (^menu)(void)) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    static NSMutableSet *logged;
    if (!logged) logged = [NSMutableSet set];
    for (UIWindow *w in windows) {
        if (!w.isKeyWindow) continue;
        UIView *hit = [w hitTest:CGPointMake(CGRectGetMidX(w.bounds), w.bounds.size.height * 0.55) withEvent:nil];
        UIViewController *target = nil;
        BOOL isEq = NO;
        for (UIResponder *r = hit; r; r = r.nextResponder) {
            if (![r isKindOfClass:UIViewController.class]) continue;
            NSString *low = NSStringFromClass(r.class).lowercaseString;
            if ([low containsString:@"nowplaying"] || [low containsString:@"player"]) return NO;
            if ([low containsString:@"equaliz"]) { target = (UIViewController *)r; isEq = YES; break; }
            if ([low containsString:@"rootsettings"]) { target = (UIViewController *)r; break; }
        }
        if (!target) return NO;
        UIScrollView *sv = SMListAt(w, target);
        NSString *name = NSStringFromClass(target.class);
        if (!sv) {
            if (![logged containsObject:name]) {
                [logged addObject:name];
                SMLogPublic([NSString stringWithFormat:@"Paramètres : aucune liste trouvée dans %@ (vue touchée %@)", name, NSStringFromClass(hit.class)]);
            }
            return NO;
        }
        SMLearnFonts(sv);
        __weak UIViewController *weakTarget = target;
        NSArray *rows = isEq
            ? @[@[@"Calibrer avec SoundMatch", @"Trouver mon égaliseur en comparant des versions d'un morceau", @"slider.vertical.3", calibrate],
                @[@"Options SoundMatch", @"Saisir des valeurs, remettre l'ancien égaliseur…", @"ellipsis.circle", menu]]
            : @[@[@"SoundMatch", @"Calibrer l'égaliseur et options", @"slider.vertical.3", menu],
                @[@"Couleur de l'app", @"Remplacer le vert de Spotify par la couleur de ton choix", @"paintpalette.fill",
                  ^{ UIViewController *t = weakTarget; if (t) SMAccentPick(t); }]];
        SMInstallRows(sv, rows);
        if (![logged containsObject:name]) {
            [logged addObject:name];
            SMLogPublic([NSString stringWithFormat:@"Paramètres : lignes ajoutées dans %@ (%@)", name, NSStringFromClass(sv.class)]);
        }
        return YES;
    }
    return NO;
}

void SMStatsOpenFrom(UIViewController *from) { SMOpenStats(from); }

#pragma mark - « Stats d'écoute » dans le menu du profil

static void SMCollectVCs(UIViewController *vc, NSMutableArray *out, int depth) {
    if (!vc || depth > 30) return;
    [out addObject:vc];
    for (UIViewController *c in vc.childViewControllers) SMCollectVCs(c, out, depth + 1);
    if (vc.presentedViewController.presentingViewController == vc) SMCollectVCs(vc.presentedViewController, out, depth + 1);
}

/// Dans le menu ouvert en touchant la photo de profil, la ligne « Stats d'écoute » de Spotify ouvre celles de SoundMatch.
void SMDrawerInject(NSArray<UIWindow *> *windows) {
    static const NSInteger tag = 0x5D5708;
    static NSMutableSet *logged;
    if (!logged) logged = [NSMutableSet set];
    for (UIWindow *w in windows) {
        NSMutableArray *vcs = [NSMutableArray array];
        SMCollectVCs(w.rootViewController, vcs, 0);
        for (UIViewController *vc in vcs) {
            if (![NSStringFromClass(vc.class).lowercaseString containsString:@"sidedrawer"]) continue;
            if (!vc.isViewLoaded || !vc.view.window) continue;
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:vc.view];
            NSMutableArray *texts = [NSMutableArray array];
            BOOL done = NO;
            int seen = 0;
            while (stack.count && seen < 3000) {
                UIView *v = stack.lastObject; [stack removeLastObject]; seen++;
                [stack addObjectsFromArray:v.subviews];
                if (![v isKindOfClass:UILabel.class]) continue;
                NSString *text = [(UILabel *)v text];
                if (!text.length) continue;
                if (texts.count < 25) [texts addObject:text];
                NSString *f = [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
                if (![f isEqualToString:@"stats d'ecoute"] && ![f isEqualToString:@"stats d’ecoute"] && ![f isEqualToString:@"listening stats"]) continue;
                // Ligne entière : on remonte jusqu'à la cellule (ou une vue large et pas trop haute)
                UIView *row = v;
                for (UIView *u = v.superview; u && u != vc.view; u = u.superview) {
                    row = u;
                    if ([u isKindOfClass:UITableViewCell.class] || [u isKindOfClass:UICollectionViewCell.class]) break;
                    if (u.bounds.size.width >= vc.view.bounds.size.width * 0.5 && u.bounds.size.height >= 36 && u.bounds.size.height <= 120) break;
                }
                done = YES;
                if ([row viewWithTag:tag]) continue;
                SMRowControl *ctl = [[SMRowControl alloc] initWithFrame:row.bounds];
                ctl.tag = tag;
                ctl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                __weak UIViewController *weakVC = vc;
                ctl.action = ^{
                    UIViewController *top = weakVC.view.window.rootViewController;
                    while (top.presentedViewController) top = top.presentedViewController;
                    if (top) SMOpenStats(top);
                };
                [ctl addTarget:ctl action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
                [row addSubview:ctl];
                [row bringSubviewToFront:ctl];
                if (![logged containsObject:@"drawer"]) {
                    [logged addObject:@"drawer"];
                    SMLogPublic([NSString stringWithFormat:@"Menu du profil : « %@ » ouvre les stats SoundMatch (%@)", text, NSStringFromClass(row.class)]);
                }
            }
            if (!done && ![logged containsObject:@"drawer-miss"]) {
                [logged addObject:@"drawer-miss"];
                SMLogPublic([@"Menu du profil : ligne Stats d'écoute introuvable, textes vus : " stringByAppendingString:[texts componentsJoinedByString:@" | "]]);
            }
        }
    }
}
