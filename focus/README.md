# NoteFlowFocus (tweak pour n'importe quelle app)

Tweak `.dylib` chargé par LiveContainer dans les apps que tu choisis. Pendant un focus NoteFlow (créneau du jour,
rappel avec focus ou puce NFC), l'app entière est bloquée : écran noir sans bouton avec le temps restant, son coupé,
puis retour à l'écran d'accueil, jusqu'à la fin du focus. Hors focus, il ne fait rien.

Le code est celui de `shared/NFFocus.m`, le même que dans ShortLimiter (YouTube) et StreamBoost (Twitch) : inutile de
l'ajouter à ces deux apps.

## Liaison (une seule fois)

Au lancement d'une app pas encore liée, une fenêtre demande le code de liaison :

1. Dans NoteFlow : Mode focus › **Copier le code de liaison**.
2. Reviens dans l'app et touche **Coller** (ou tape le code dans le champ).

Le code est rangé dans le groupe d'apps de LiveContainer (et dans le trousseau en secours) : les autres apps qui ont
ce tweak le reprennent toutes seules, sans rien demander. Une fois lié, la fenêtre ne revient plus.

## Installation

Dans SideStore : My Apps › appui long sur l'app › **Tweaks** › **+** › **From a Link (auto-update)**, puis colle

https://github.com/eliaskinzigeri-blip/short-limiter/releases/download/focus-latest/NoteFlowFocus.dylib

Ferme complètement l'app et relance-la depuis son icône.
