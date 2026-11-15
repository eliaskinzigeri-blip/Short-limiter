# StreamBoost (tweak pour l'app Twitch)

Tweak `.dylib` chargé par la fonction **Tweaks** de LiveContainer dans l'app Twitch que tu installes toi-même.
Aucune app Twitch n'est contenue ni publiée ici. Pas de blocage de publicités ni de fonction payante débloquée.

## Fonctions

- **Appui long sur une vidéo à la demande** (VOD, clip) : lecture accélérée (×2 par défaut) tant que le doigt reste
  posé, avec une pastille « 2× ▶▶ » ; la vitesse normale revient quand tu relâches.
- **Double appui sur les côtés de la vidéo** : à gauche −10 s, à droite +10 s (réglable : 5 à 30 s) ; les doubles
  appuis rapprochés s'additionnent (⏪ 20 s, 30 s…). **En direct** : le lecteur de Twitch (Amazon IVS) ne
  garde rien en arrière, donc le tweak garde lui-même la **dernière minute** : il note les morceaux du direct
  publiés par Twitch (juste leurs adresses) et, au double appui à gauche, les rejoue avec le lecteur d'Apple
  par-dessus la vidéo, le direct continuant en sourdine. « Revenir au direct », un double appui à droite jusqu'au
  bout, ou la fin de la minute gardée ramènent au direct.
- **Chat par-dessus la vidéo** : le double appui de Twitch est désactivé (il ne sert plus qu'à reculer / avancer).
  Le chat s'ouvre et se ferme avec le bouton **« 💬 Chat »** en haut à gauche, en plein écran (paysage).
- **Retard sur un direct** : si tu as au moins 10 s de retard (réglable), un bouton **« ⏩ Revenir au direct »**
  apparaît en haut à droite ; il saute au direct (lecteur Apple) ou recharge le flux (lecteur Amazon IVS).
- **Réglages** : appui long à trois doigts → vitesse (×1,5 / ×2 / ×3), pas du double appui, seuil du bouton direct (5 à 30 s),
  partage du journal.

## Installation

1. Télécharge https://github.com/eliaskinzigeri-blip/short-limiter/releases/download/twitch-latest/StreamBoost.dylib
2. LiveContainer → onglet **Tweaks** → **+** → ajoute `StreamBoost.dylib`, puis touche le bouton **signature**.
3. Lance Twitch **depuis LiveContainer**.

## Si ça ne marche pas du premier coup

Le tweak repère le lecteur vidéo pendant que l'app tourne, sans le code de Twitch. Appui long à trois doigts →
**Partager le journal** : il indique le lecteur repéré (`Lecteur repéré : …`), ce qu'il y avait sous ton doigt
(`Appui long sur : …`) et le retard mesuré, pour ajuster.
