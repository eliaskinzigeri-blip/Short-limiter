// ShortLimiter : limite le temps passé sur les Shorts dans l'app YouTube.
// Tweak (.dylib) chargé par LiveContainer dans l'app que l'utilisateur installe lui-même.
// Aucun code de YouTube ici : la détection des Shorts repose uniquement sur les noms de classes
// des contrôleurs de vue affichés à l'écran (liste réglable dans l'app).
#import <UIKit/UIKit.h>

#ifndef SL_VERSION
#define SL_VERSION "dev"
#endif

/// Cœur : réglages, compteurs, détection et blocage. Tout se passe sur le fil principal.
@interface SLCore : NSObject
+ (instancetype)shared;

// Réglages (enregistrés dans NSUserDefaults)
@property (nonatomic) NSInteger limitMinutes;   // 5 par défaut
@property (nonatomic) NSInteger blockMinutes;   // 30 par défaut
@property (nonatomic) BOOL showCounter;         // petit compteur en haut de l'écran sur les Shorts
@property (nonatomic) BOOL logEnabled;          // journal des écrans vus
@property (nonatomic, copy) NSString *includeNames; // morceaux de noms de classes des écrans Shorts
@property (nonatomic, copy) NSString *excludeNames; // morceaux à ignorer (étagères du fil d'accueil…)
@property (nonatomic, copy) NSString *exitNames;    // vues de la barre d'onglets du bas (retour à l'accueil)

// État
@property (nonatomic, readonly) BOOL onShorts;
@property (nonatomic, readonly) double usedSeconds;      // temps compté vers la limite
@property (nonatomic, readonly) NSDate *blockedUntil;
@property (nonatomic, readonly) BOOL isBlocked;
@property (nonatomic, readonly) double remainingBlock;   // secondes
@property (nonatomic, readonly) double remainingBeforeBlock;
@property (nonatomic, readonly) NSString *matchedName;   // classe reconnue comme écran Shorts
@property (nonatomic, readonly) NSDictionary *today;     // day, seconds, entries, blocks
@property (nonatomic, readonly) NSArray<NSDictionary *> *history; // 7 jours précédents

- (void)start;
- (void)save;
- (void)leaveShorts;          // bouton « Retour à l'accueil »
- (void)resetDetectionNames;  // remet les listes de noms par défaut

// Journal
- (void)log:(NSString *)line;
- (NSString *)logPath;
- (NSString *)logText;
- (void)clearLog;
@end

/// Fenêtre par-dessus l'app : compteur discret et écran de blocage.
@interface SLOverlay : NSObject
+ (instancetype)shared;
- (void)refresh;
- (void)presentSettings;
@end

/// Écran des réglages et des statistiques.
@interface SLSettingsController : UITableViewController <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) void (^onClose)(void);
@end

NSString *SLFormat(double seconds);
UIWindowScene *SLActiveScene(void);
