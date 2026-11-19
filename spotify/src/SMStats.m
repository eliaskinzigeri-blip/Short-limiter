// SoundMatch : statistiques d'écoute (minutes, titres, artistes) et lignes dans les paramètres de Spotify.
//
// Les écoutes sont relevées sur l'appareil, chaque seconde, à partir des informations « À l'écoute » que Spotify
// donne à iOS (écran verrouillé) : titre, artiste, album, pochette, lecture ou pause. Rien n'est envoyé nulle part :
// tout reste dans Documents/SoundMatch-stats.json de l'app. Les stats commencent donc à l'installation du tweak.
#import "SMStats.h"
#import <MediaPlayer/MediaPlayer.h>
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
static BOOL gCurCounted, gCurArtSaved;
static NSDictionary *gLastInfo, *gHookedInfo;

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
    NSString *artist = [info[MPMediaItemPropertyArtist] isKindOfClass:NSString.class] ? info[MPMediaItemPropertyArtist] : @"";
    NSString *album = [info[MPMediaItemPropertyAlbumTitle] isKindOfClass:NSString.class] ? info[MPMediaItemPropertyAlbumTitle] : @"";
    double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
    NSNumber *elapsedN = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    NSString *key = [NSString stringWithFormat:@"%@—%@", title, artist];

    BOOL changedInfo = gLastInfo && ![gLastInfo isEqual:info];
    gLastInfo = info;
    if (![key isEqualToString:gCurKey]) {
        gCurKey = key;
        gCurSec = 0;
        gCurCounted = NO;
        gCurArtSaved = NO;
        if (!gTracks[key]) {
            gTracks[key] = [@{@"t": title, @"a": artist, @"al": album} mutableCopy];
            gDirty = YES;
        }
    } else if (changedInfo && gCurSec >= 30 && elapsedN && elapsedN.doubleValue < 3) {
        gCurSec = 0; // même titre relancé depuis le début : nouvelle écoute
        gCurCounted = NO;
    }
    SMSaveArtwork(key, info);

    if (rate > 0 && dt > 0 && SMAudioLooksActive()) {
        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:now];
        NSMutableDictionary *day = SMDayEntry(date);
        day[@"tot"] = @([day[@"tot"] doubleValue] + dt);
        NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:date];
        NSMutableArray *hours = day[@"h"];
        if ([hours isKindOfClass:NSMutableArray.class] && hour < (NSInteger)hours.count) hours[hour] = @([hours[hour] doubleValue] + dt);
        NSMutableDictionary *tr = day[@"tr"];
        NSMutableArray *e = tr[key];
        if (![e isKindOfClass:NSMutableArray.class] || e.count < 2) { e = [@[@0, @0] mutableCopy]; tr[key] = e; }
        e[0] = @([e[0] doubleValue] + dt);
        gCurSec += dt;
        if (!gCurCounted && gCurSec >= 30) { // une écoute compte à partir de 30 s, comme chez Spotify
            gCurCounted = YES;
            e[1] = @([e[1] integerValue] + 1);
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

void SMStatsStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SMStatsLoad();
        SMHookNowPlaying();
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

#pragma mark - Périodes et calculs

typedef NS_ENUM(NSInteger, SMRange) { SMRangeDay, SMRangeWeek, SMRangeMonth, SMRangeYear };

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
    double total = 0;
    for (NSDate *d = start; [d compare:end] == NSOrderedAscending; d = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:d options:0]) {
        NSDictionary *day = gDays[[SMDayFormatter() stringFromDate:d]];
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
        for (NSString *k in tr) {
            NSArray *e = tr[k];
            if (![e isKindOfClass:NSArray.class] || e.count < 2) continue;
            NSMutableArray *acc = tracks[k];
            if (!acc) { acc = [@[@0.0, @0] mutableCopy]; tracks[k] = acc; }
            acc[0] = @([acc[0] doubleValue] + [e[0] doubleValue]);
            acc[1] = @([acc[1] integerValue] + [e[1] integerValue]);
        }
    }
    NSMutableArray *trackList = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *artists = [NSMutableDictionary dictionary];
    long plays = 0;
    for (NSString *k in tracks) {
        double sec = [tracks[k][0] doubleValue];
        long p = [tracks[k][1] integerValue];
        if (sec < 1) continue;
        plays += p;
        NSDictionary *meta = gTracks[k];
        NSString *t = meta[@"t"] ?: [k componentsSeparatedByString:@"—"].firstObject;
        NSString *a = meta[@"a"] ?: @"";
        [trackList addObject:@{@"t": t, @"a": a, @"key": k, @"sec": @(sec), @"plays": @(p)}];
        for (NSString *name in SMSplitArtists(a)) {
            NSMutableDictionary *ar = artists[name];
            if (!ar) { ar = [@{@"name": name, @"sec": @0.0, @"plays": @0, @"key": k, @"best": @0.0} mutableCopy]; artists[name] = ar; }
            ar[@"sec"] = @([ar[@"sec"] doubleValue] + sec);
            ar[@"plays"] = @([ar[@"plays"] integerValue] + p);
            if (sec > [ar[@"best"] doubleValue]) { ar[@"best"] = @(sec); ar[@"key"] = k; } // pochette de son titre le plus écouté
        }
    }
    NSSortDescriptor *bySec = [NSSortDescriptor sortDescriptorWithKey:@"sec" ascending:NO];
    SMAgg *agg = [SMAgg new];
    agg.total = total;
    agg.plays = plays;
    agg.tracks = [trackList sortedArrayUsingDescriptors:@[bySec]];
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

@interface SMStatsController : UIViewController <UITableViewDataSource, UITableViewDelegate>
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
    if (_range < SMRangeDay || _range > SMRangeYear) _range = SMRangeWeek;

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
        [_table.topAnchor constraintEqualToAnchor:_bar.bottomAnchor],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self buildHeader];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _navWasHidden = self.navigationController.navigationBarHidden;
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    SMStatsSave(); // les dernières secondes écoutées sont prises en compte
    [self reload];
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
    NSArray *names = @[@"Jour", @"Semaine", @"Mois", @"Année"];
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

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[pillRow, nav, _headline, _summary, _chart]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 14;
    [stack setCustomSpacing:6 afterView:_headline];
    [stack setCustomSpacing:22 afterView:_summary];
    pillRow.alignment = UIStackViewAlignmentLeading;
    UIView *pillHolder = [UIView new];
    [stack insertArrangedSubview:pillHolder atIndex:0];
    [stack removeArrangedSubview:pillRow];
    [pillHolder addSubview:pillRow];
    pillRow.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [pillRow.leadingAnchor constraintEqualToAnchor:pillHolder.leadingAnchor],
        [pillRow.topAnchor constraintEqualToAnchor:pillHolder.topAnchor],
        [pillRow.bottomAnchor constraintEqualToAnchor:pillHolder.bottomAnchor],
        [pillRow.trailingAnchor constraintLessThanOrEqualToAnchor:pillHolder.trailingAnchor],
    ]];
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

- (void)prevPeriod { _offset--; [self reload]; }
- (void)nextPeriod { if (_offset < 0) { _offset++; [self reload]; } }

- (void)reload {
    if (!_table) return;
    NSDate *start, *end;
    SMPeriod(_range, _offset, &start, &end);
    _agg = SMAggregate(_range, start, end);
    _moreArtists = _moreTracks = NO;

    for (UIButton *p in _pills) {
        BOOL on = p.tag == _range;
        p.backgroundColor = on ? SM_GREEN : SM_PILL;
        [p setTitleColor:on ? UIColor.blackColor : UIColor.whiteColor forState:UIControlStateNormal];
    }
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
    _summary.text = [parts componentsJoinedByString:@" · "];

    _chart.values = _agg.buckets;
    _chart.labels = _agg.bucketLabels;
    _chart.hidden = _agg.total < 1;
    [_chart setNeedsDisplay];

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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = _table.tableHeaderView;
    if (header && fabs(header.bounds.size.width - _table.bounds.size.width) > 1) [self reload];
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
        c.title.text = @"Aucune écoute sur cette période";
        c.sub.text = @"Les stats sont relevées depuis l'installation de SoundMatch.";
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
    if (ip.section == 0) {
        c.title.text = it[@"name"];
        c.sub.text = [NSString stringWithFormat:@"%ld écoute%@", plays, plays > 1 ? @"s" : @""];
        c.art.layer.cornerRadius = 26; // artistes en rond, comme dans Spotify
    } else {
        c.title.text = it[@"t"];
        c.sub.text = [NSString stringWithFormat:@"%@ · %ld écoute%@", it[@"a"], plays, plays > 1 ? @"s" : @""];
        c.art.layer.cornerRadius = 4;
    }
    c.art.image = [UIImage imageWithContentsOfFile:SMArtPath(it[@"key"])];
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
    UIViewController *stats = SMStatsMakeController();
    UINavigationController *nav = from.navigationController;
    if (nav) {
        [nav pushViewController:stats animated:YES];
    } else {
        stats.modalPresentationStyle = UIModalPresentationFullScreen;
        [from presentViewController:stats animated:YES completion:nil];
    }
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
            : @[@[@"Stats d'écoute", @"Minutes, titres et artistes par jour, semaine, mois, année", @"chart.bar.fill",
                  ^{ UIViewController *t = weakTarget; if (t) SMOpenStats(t); }],
                @[@"SoundMatch", @"Calibrer l'égaliseur et options", @"slider.vertical.3", menu]];
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
