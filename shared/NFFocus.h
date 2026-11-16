// Mode focus NoteFlow, commun aux tweaks YouTube (ShortLimiter) et Twitch (StreamBoost) :
// pendant un focus NoteFlow, l'app entière est bloquée. Voir NFFocus.m.
#import <UIKit/UIKit.h>

/// État en une ligne pour les réglages (« Non lié », « Lié · pas de focus en cours », « Bloqué jusqu'à 18h30 »).
NSString *NFFocusStatus(void);
/// Fiche de liaison avec NoteFlow (coller le code, délier), présentée depuis `from`.
void NFFocusPresentSettings(UIViewController *from);
