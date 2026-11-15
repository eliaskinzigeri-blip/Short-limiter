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
@property (nonatomic) BOOL cooldownEnabled;     // règle 1 : pause de blockMinutes après limitMinutes (oui par défaut)
@property (nonatomic) BOOL dailyEnabled;        // règle 2 : plus de Shorts jusqu'à minuit après dailyMinutes (non par défaut)
@property (nonatomic) NSInteger dailyMinutes;   // 30 par défaut
@property (nonatomic) BOOL perDayEnabled;       // règles différentes selon le jour de la semaine
@property (nonatomic) NSInteger editDay;        // jour modifié dans les réglages (0 = tous, 1 = lundi … 7 = dimanche)
@property (nonatomic, readonly) NSInteger todayWeekday;
- (NSInteger)rule:(NSString *)key day:(NSInteger)day;   // clés : cooldown, limit, block, daily, dailyMin
- (void)setRule:(NSString *)key day:(NSInteger)day value:(NSInteger)value;
- (void)copyRulesFromDay:(NSInteger)from toDay:(NSInteger)to; // to = 0 : tous les jours
- (NSString *)summaryForDay:(NSInteger)day;
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
@property (nonatomic, readonly) BOOL dailyBlocked;       // limite du jour atteinte (bloqué jusqu'à minuit)
@property (nonatomic, readonly) double remainingBlock;   // secondes
@property (nonatomic, readonly) double remainingBeforeBlock; // -1 si aucune règle active
@property (nonatomic, readonly) double blockDuration;    // durée totale du blocage en cours
- (CGFloat)tabBarInset;    // hauteur de la barre d'onglets du bas de l'app (bord inférieur compris)
@property (nonatomic, readonly) NSString *matchedName;   // classe reconnue comme écran Shorts
@property (nonatomic, readonly) NSDictionary *today;     // day, seconds, entries, blocks
@property (nonatomic, readonly) NSArray<NSDictionary *> *history; // 7 jours précédents

- (void)start;
- (void)save;
- (void)leaveShorts;          // bouton « Retour à l'accueil »
- (void)resetDetectionNames;  // remet les listes de noms par défaut

// Journal
- (void)log:(NSString *)line;
- (void)logOnce:(NSString *)key text:(NSString *)line;
- (NSString *)logPath;
- (NSString *)logText;
- (void)clearLog;
@end

/// Fenêtre par-dessus l'app : compteur discret et écran de blocage.
@interface SLOverlay : NSObject
+ (instancetype)shared;
- (void)refresh;
- (void)presentSettings;
- (void)toast:(NSString *)text;
@end

/// Écran des réglages et des statistiques.
@interface SLSettingsController : UITableViewController <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) void (^onClose)(void);
@end

NSString *SLFormat(double seconds);
NSString *SLDayName(NSInteger day); // 0 = tous les jours, 1 = lundi … 7 = dimanche
void SLInstallYouTubeSettings(void);
void SLInstallPiPCompat(void);       // PiP noir : rendu vidéo classique
BOOL SLPiPCompatEnabled(void);
void SLSetPiPCompatEnabled(BOOL on);
UIViewController *SLVisiblePlayerVC(void); // lecteur vidéo de YouTube affiché
BOOL SLPiPAllowed(UIViewController *playerVC);  // YouTube autorise le PiP sur ce compte
void SLStartPiP(UIViewController *playerVC);
void SLPiPWatchdog(void);     // PiP noir : remet à zéro le calque vidéo en échec
void SLInstallPiPFixes(void);
void SLDecorateSettings(void);     // icône barrée de la rubrique dans les Paramètres de YouTube
UIWindowScene *SLActiveScene(void);
