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
NSArray<NSURL *> *SMStatsCaptureFiles(void);
/// Affiche « Mes stats d'écoute » (style des affiches de Spotify) : aperçu puis partage.
/// Images : adresse http(s) ou chemin de fichier, ou nil.
void SMPosterPresent(UIViewController *from, NSString *period, NSString *minutes, NSArray<NSString *> *artists,
                     NSArray<NSString *> *tracks, NSString *artistImage, NSString *trackImage); // réponses de Spotify relevées (diagnostic)

/// Ajoute les lignes SoundMatch dans l'écran des paramètres affiché (racine des paramètres et égaliseur).
/// Renvoie YES si les lignes sont visibles à l'écran (le bouton flottant devient alors inutile).
/// Menu du profil : la ligne « Stats d'écoute » ouvre les stats SoundMatch.
void SMDrawerInject(NSArray<UIWindow *> *windows);

BOOL SMSettingsInject(NSArray<UIWindow *> *windows, void (^calibrate)(void), void (^menu)(void));
