# StreamBoost (tweak pour l'app Twitch)

Tweak `.dylib` chargé par la fonction **Tweaks** de LiveContainer dans l'app Twitch que tu installes toi-même.
Aucune app Twitch n'est contenue ni publiée ici. Pas de blocage de publicités ni de fonction payante débloquée.

## Fonctions

- **Appui long sur une vidéo à la demande** (VOD, clip) : lecture accélérée (×2 par défaut) tant que le doigt reste
  posé, avec une pastille « 2× ▶▶ » ; la vitesse normale revient quand tu relâches.
- **Retard sur un direct** : si tu as au moins 10 s de retard (réglable), un bouton **« ⏩ Revenir au direct »**
  apparaît en haut à droite ; il saute au direct (lecteur Apple) ou recharge le flux (lecteur Amazon IVS).
- **Réglages** : appui long à trois doigts → vitesse (×1,5 / ×2 / ×3), seuil du bouton direct (5 à 30 s),
  partage du journal.

## Installation

1. Télécharge https://github.com/eliaskinzigeri-blip/short-limiter/releases/download/twitch-latest/StreamBoost.dylib
2. LiveContainer → onglet **Tweaks** → **+** → ajoute `StreamBoost.dylib`, puis touche le bouton **signature**.
3. Lance Twitch **depuis LiveContainer**.

## Si ça ne marche pas du premier coup

Le tweak repère le lecteur vidéo pendant que l'app tourne, sans le code de Twitch. Appui long à trois doigts →
**Partager le journal** : il indique le lecteur repéré (`Lecteur repéré : …`), ce qu'il y avait sous ton doigt
(`Appui long sur : …`) et le retard mesuré, pour ajuster.
