// SoundMatch : statistiques d'écoute et lignes ajoutées dans les paramètres de Spotify.
#import <UIKit/UIKit.h>

// Fournis par SoundMatch.m
void SMLogPublic(NSString *line);
BOOL SMAudioLooksActive(void); // le son de Spotify passe sur cet appareil (ou aucune mesure disponible)
int SMAudioSound(void);        // 1 : du son sort de Spotify, 0 : silence, -1 : pas de mesure (AirPlay, Connect…)

/// Enregistre ce qui est écouté (titre, artiste, secondes) à partir des infos « À l'écoute » de Spotify.
void SMStatsStart(void);
/// Écran « Stats d'écoute ».
UIViewController *SMStatsMakeController(void);
void SMStatsOpenFrom(UIViewController *from);
NSArray<NSURL *> *SMStatsCaptureFiles(void); // réponses de Spotify relevées (diagnostic)

/// Ajoute les lignes SoundMatch dans l'écran des paramètres affiché (racine des paramètres et égaliseur).
/// Renvoie YES si les lignes sont visibles à l'écran (le bouton flottant devient alors inutile).
BOOL SMSettingsInject(NSArray<UIWindow *> *windows, void (^calibrate)(void), void (^menu)(void));
