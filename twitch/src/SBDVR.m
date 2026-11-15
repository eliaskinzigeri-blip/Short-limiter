#import "SBDVR.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static const double SBKeepSeconds = 75;   // durée gardée (un peu plus d'une minute)
static NSString *const SBScheme = @"sbdvr";

@interface SBDVR () <AVAssetResourceLoaderDelegate>
@end

@implementation SBDVR {
    __weak id _ivs;
    NSURL *_source;          // adresse donnée au lecteur IVS (liste principale ou liste du flux)
    NSURL *_media;           // liste de lecture du flux choisi (mise à jour en continu par Twitch)
    NSMutableArray<NSDictionary *> *_segs;  // { url, dur, disc }
    NSMutableSet<NSString *> *_known;
    BOOL _fetching, _resolving;
    NSString *_manifestText; // contenu de la liste principale quand Twitch le donne directement
    NSDate *_lastPoll;
    int _failures;

    AVPlayer *_replay;
    UIView *_replayView;
    NSString *_playlist;
    double _snapDuration;
    NSDate *_snapDate;
    BOOL _wasMuted;
    id _endObserver;
}

+ (instancetype)shared {
    static SBDVR *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [SBDVR new]; });
    return d;
}

- (instancetype)init {
    if ((self = [super init])) {
        _segs = [NSMutableArray array];
        _known = [NSMutableSet set];
    }
    return self;
}

- (void)reset {
    _source = nil;
    _media = nil;
    [_segs removeAllObjects];
    [_known removeAllObjects];
    _bufferedSeconds = 0;
    _failures = 0;
}

#pragma mark Suivi de la liste de lecture

- (void)watchPlayer:(id)player {
    if (_replay && _replay.currentItem.status == AVPlayerItemStatusFailed) {
        SBLog([NSString stringWithFormat:@"Relecture : échec (%@)", _replay.currentItem.error.localizedDescription ?: @"?"]);
        [self stopReplay];
    }
    if (!player) {
        if (_replay && !_ivs) [self stopReplay];
        return;
    }
    _ivs = player;
    NSURL *path = SBPlayerURL(player);
    NSString *manifest = path ? nil : SBPlayerManifest(player);
    if (!path && manifest) {
        // Twitch donne le contenu de la liste au lecteur (loadManifest) : on part de ce contenu
        path = [NSURL URLWithString:[NSString stringWithFormat:@"sbmanifest://liste/%lu", (unsigned long)manifest.hash]];
        _manifestText = manifest;
    }
    if (!path) {
        static BOOL said;
        if (!said) { said = YES; SBLog(@"Mémoire du direct : adresse du flux inconnue (le lecteur ne la donne pas)"); }
        return;
    }
    if (![path isEqual:_source]) {
        if (_replay) [self stopReplay];
        [self reset];
        _source = path;
        SBLog([NSString stringWithFormat:@"Mémoire du direct : flux %@%@ (%@)", path.host ?: @"", path.path.lastPathComponent ?: @"",
               path.scheme ?: @"?"]);
        [self resolve];
    }
    if (_media && !_fetching && (!_lastPoll || -_lastPoll.timeIntervalSinceNow >= 2)) [self poll];
}

- (void)fetch:(NSURL *)url done:(void (^)(NSString *text, NSURL *finalURL))done {
    if (![url.scheme hasPrefix:@"http"]) { done(nil, nil); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!text || code >= 400) {
                SBLog([NSString stringWithFormat:@"Mémoire du direct : téléchargement refusé (HTTP %ld, %@)", (long)code, err.localizedDescription ?: @""]);
                done(nil, nil);
            } else {
                done(text, resp.URL ?: url);
            }
        });
    }] resume];
}

static NSDictionary *SBAttrs(NSString *line) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) return out;
    NSString *rest = [line substringFromIndex:colon.location + 1];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:rest options:0 range:NSMakeRange(0, rest.length)]) {
        NSString *v = [rest substringWithRange:[m rangeAtIndex:2]];
        out[[rest substringWithRange:[m rangeAtIndex:1]]] = [v stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
    }
    return out;
}

/// Liste principale : choisit la meilleure qualité vidéo jusqu'à 1080p ; sinon la liste est déjà celle du flux.
- (void)resolve {
    if (_resolving) return;
    _resolving = YES;
    NSURL *source = _source;
    void (^handle)(NSString *, NSURL *) = ^(NSString *text, NSURL *finalURL) {
        self->_resolving = NO;
        if (!text || ![source isEqual:self->_source]) return;
        if (![text containsString:@"#EXT-X-STREAM-INF"]) {
            self->_media = finalURL;
            SBLog(@"Mémoire du direct : liste du flux trouvée");
            return;
        }
        NSArray *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        NSURL *best = nil;
        double bestBw = -1;
        NSString *bestName = nil;
        for (NSUInteger i = 0; i + 1 < lines.count; i++) {
            NSString *l = lines[i];
            if (![l hasPrefix:@"#EXT-X-STREAM-INF"]) continue;
            NSDictionary *a = SBAttrs(l);
            NSString *uri = nil;
            for (NSUInteger j = i + 1; j < lines.count; j++) {
                NSString *u = [lines[j] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (u.length && ![u hasPrefix:@"#"]) { uri = u; break; }
            }
            if (!uri) continue;
            NSString *res = a[@"RESOLUTION"] ?: @"";
            NSInteger height = [[res componentsSeparatedByString:@"x"].lastObject integerValue];
            if (height == 0 || height > 1080) continue; // audio seul ou trop lourd
            double bw = [a[@"BANDWIDTH"] doubleValue];
            if (bw > bestBw) {
                bestBw = bw;
                best = [NSURL URLWithString:uri relativeToURL:finalURL].absoluteURL;
                bestName = [NSString stringWithFormat:@"%@ %@", res, a[@"VIDEO"] ?: @""];
            }
        }
        self->_media = best;
        SBLog(best ? [NSString stringWithFormat:@"Mémoire du direct : qualité %@ choisie", bestName]
                   : @"Mémoire du direct : aucune qualité vidéo trouvée dans la liste principale");
    };
    if ([source.scheme isEqualToString:@"sbmanifest"]) {
        NSString *text = _manifestText;
        if (![text containsString:@"#EXT-X-STREAM-INF"]) {
            _resolving = NO;
            SBLog(@"Mémoire du direct : le contenu donné au lecteur n'est pas une liste principale (pas d'adresse à suivre)");
            return;
        }
        handle(text, nil);
    } else {
        [self fetch:source done:handle];
    }
}

- (void)poll {
    _fetching = YES;
    _lastPoll = NSDate.date;
    NSURL *media = _media;
    [self fetch:media done:^(NSString *text, NSURL *finalURL) {
        self->_fetching = NO;
        if (![media isEqual:self->_media]) return;
        if (!text) {
            if (++self->_failures >= 5) { SBLog(@"Mémoire du direct : abandon après 5 échecs"); self->_media = nil; }
            return;
        }
        self->_failures = 0;
        [self ingest:text base:finalURL];
    }];
}

- (void)ingest:(NSString *)text base:(NSURL *)base {
    NSArray *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    double dur = -1;
    BOOL disc = NO;
    NSUInteger added = 0;
    for (NSString *raw in lines) {
        NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!l.length) continue;
        if ([l hasPrefix:@"#EXTINF:"]) {
            dur = [[l substringFromIndex:8] doubleValue];
        } else if ([l hasPrefix:@"#EXT-X-DISCONTINUITY"]) {
            disc = YES;
        } else if (![l hasPrefix:@"#"] && dur > 0) {
            NSString *url = [NSURL URLWithString:l relativeToURL:base].absoluteString;
            if (url && ![_known containsObject:url]) {
                [_known addObject:url];
                [_segs addObject:@{@"url": url, @"dur": @(dur), @"disc": @(disc)}];
                added++;
            }
            dur = -1;
            disc = NO;
        }
    }
    double total = 0;
    for (NSDictionary *s in _segs) total += [s[@"dur"] doubleValue];
    while (_segs.count > 1 && total - [_segs.firstObject[@"dur"] doubleValue] >= SBKeepSeconds) {
        total -= [_segs.firstObject[@"dur"] doubleValue];
        [_known removeObject:_segs.firstObject[@"url"]];
        [_segs removeObjectAtIndex:0];
    }
    BOOL first = _bufferedSeconds == 0 && total > 0;
    _bufferedSeconds = total;
    if (first) SBLog([NSString stringWithFormat:@"Mémoire du direct : %lu morceaux reçus (%.0f s)", (unsigned long)_segs.count, total]);
}

#pragma mark Relecture

- (double)behindLive {
    if (!_replay) return 0;
    double cur = CMTimeGetSeconds(_replay.currentTime);
    if (isnan(cur)) cur = 0;
    return MAX(0, _snapDuration - cur) - _snapDate.timeIntervalSinceNow;
}

- (NSString *)buildPlaylist {
    double maxDur = 1;
    double total = 0;
    for (NSDictionary *s in _segs) { maxDur = MAX(maxDur, [s[@"dur"] doubleValue]); total += [s[@"dur"] doubleValue]; }
    NSMutableString *m = [NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n",
                          (int)ceil(maxDur)];
    BOOL firstSeg = YES;
    for (NSDictionary *s in _segs) {
        if ([s[@"disc"] boolValue] && !firstSeg) [m appendString:@"#EXT-X-DISCONTINUITY\n"];
        [m appendFormat:@"#EXTINF:%.3f,\n%@\n", [s[@"dur"] doubleValue], s[@"url"]];
        firstSeg = NO;
    }
    [m appendString:@"#EXT-X-ENDLIST\n"];
    _snapDuration = total;
    return m;
}

- (void)setIVSMuted:(BOOL)muted {
    id p = _ivs;
    if ([p respondsToSelector:@selector(setMuted:)]) ((void (*)(id, SEL, BOOL))objc_msgSend)(p, @selector(setMuted:), muted);
}

- (double)seekBy:(double)delta inView:(UIView *)videoView {
    if (!_replay) {
        if (delta >= 0 || !videoView) return 0;
        if (_bufferedSeconds < 3) {
            SBLog([NSString stringWithFormat:@"Mémoire vide : %.0f s gardées (flux %@, liste %@)", _bufferedSeconds,
                   _source ? @"connu" : @"inconnu", _media ? @"trouvée" : @"non trouvée"]);
            return 0;
        }
        _playlist = [self buildPlaylist];
        _snapDate = NSDate.date;
        double start = MAX(0, _snapDuration + delta);
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:[SBScheme stringByAppendingString:@"://live/replay.m3u8"]] options:nil];
        [asset.resourceLoader setDelegate:self queue:dispatch_get_main_queue()];
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
        _replay = [AVPlayer playerWithPlayerItem:item];
        _replayView = [[UIView alloc] initWithFrame:videoView.bounds];
        _replayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _replayView.backgroundColor = UIColor.blackColor;
        _replayView.userInteractionEnabled = NO;
        AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:_replay];
        layer.frame = _replayView.bounds;
        layer.videoGravity = AVLayerVideoGravityResizeAspect;
        layer.needsDisplayOnBoundsChange = YES;
        [_replayView.layer addSublayer:layer];
        [videoView addSubview:_replayView];
        // Le calque suit la taille de la vue (rotation, plein écran)
        [_replayView addObserver:self forKeyPath:@"bounds" options:0 context:NULL];

        id p = _ivs;
        _wasMuted = [p respondsToSelector:@selector(muted)] && ((BOOL (*)(id, SEL))objc_msgSend)(p, @selector(muted));
        [self setIVSMuted:YES];
        _endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item
                                                                        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            SBLog(@"Relecture : fin de la mémoire, retour au direct");
            [self stopReplay];
        }];
        [_replay seekToTime:CMTimeMakeWithSeconds(start, 600) toleranceBefore:kCMTimeZero toleranceAfter:CMTimeMakeWithSeconds(0.5, 600) completionHandler:nil];
        [_replay play];
        _replaying = YES;
        SBLog([NSString stringWithFormat:@"Relecture : départ à −%.0f s (%lu morceaux, %.0f s gardées)", _snapDuration - start,
               (unsigned long)_segs.count, _snapDuration]);
        return start - _snapDuration;
    }
    double cur = CMTimeGetSeconds(_replay.currentTime);
    if (isnan(cur)) cur = 0;
    double target = cur + delta;
    if (target >= _snapDuration - 1) {
        double gained = self.behindLive;
        SBLog(@"Relecture : avance jusqu'au direct");
        [self stopReplay];
        return gained;
    }
    target = MAX(0, target);
    [_replay seekToTime:CMTimeMakeWithSeconds(target, 600) toleranceBefore:kCMTimeZero toleranceAfter:CMTimeMakeWithSeconds(0.5, 600) completionHandler:nil];
    return target - cur;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == _replayView) {
        for (CALayer *l in _replayView.layer.sublayers) l.frame = _replayView.bounds;
    }
}

- (BOOL)isReplayPlayer:(id)player {
    return player && player == _replay;
}

- (void)stopReplay {
    if (!_replay) return;
    if (_endObserver) [NSNotificationCenter.defaultCenter removeObserver:_endObserver];
    _endObserver = nil;
    [_replay pause];
    [_replayView removeObserver:self forKeyPath:@"bounds"];
    [_replayView removeFromSuperview];
    _replayView = nil;
    _replay = nil;
    _replaying = NO;
    [self setIVSMuted:_wasMuted];
}

#pragma mark Liste de relecture servie au lecteur d'Apple

- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)req {
    if (![req.request.URL.scheme isEqualToString:SBScheme]) return NO;
    NSData *data = [_playlist dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NO;
    [req.dataRequest respondWithData:data];
    [req finishLoading];
    return YES;
}

@end
