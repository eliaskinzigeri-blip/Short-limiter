// Dernière minute du direct : garde la liste des morceaux (segments HLS) que Twitch publie pour le direct,
// et les rejoue avec le lecteur d'Apple par-dessus la vidéo quand on recule. Le direct continue en sourdine.
#import <UIKit/UIKit.h>

void SBLog(NSString *line);
NSURL *SBPlayerURL(id player);
NSString *SBPlayerManifest(id player); // contenu de liste de lecture donné directement au lecteur (loadManifest) // adresse du flux du lecteur (propriété path ou adresse captée au chargement)

@interface SBDVR : NSObject
+ (instancetype)shared;
/// À appeler chaque seconde avec le lecteur IVS du direct affiché (nil s'il n'y en a pas).
- (void)watchPlayer:(id)player;
@property (nonatomic, readonly) double bufferedSeconds; // durée gardée (max ~75 s)
@property (nonatomic, readonly) BOOL replaying;
/// Retard sur le direct pendant la relecture (secondes).
- (double)behindLive;
/// Recule (delta < 0) ou avance pendant la relecture ; démarre la relecture au premier recul.
/// Retourne le décalage appliqué (0 si impossible). Avancer au-delà de la fin ramène au direct.
- (double)seekBy:(double)delta inView:(UIView *)videoView;
/// Arrête la relecture et remet le son du direct.
- (void)stopReplay;
@end
