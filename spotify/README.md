# SoundMatch (tweak pour l'app Spotify)

Tweak `.dylib` chargé par la fonction **Tweaks** de LiveContainer dans l'app Spotify que tu installes toi-même.
Il t'aide à trouver ton égaliseur par comparaisons à l'oreille et affiche tes stats d'écoute. Aucune app Spotify
n'est contenue ni publiée ici ; pas de blocage de publicités ni de fonction payante débloquée ; aucun fichier audio
n'est copié.

## Couleur de l'app

Paramètres de Spotify → **Couleur de l'app** : choisis n'importe quelle couleur dans le sélecteur d'iOS, elle remplace
le vert de Spotify (boutons, lecture en cours, barres, icônes teintées…) au prochain lancement. « Remettre le vert de
Spotify » annule. Les images déjà vertes dans les fichiers de l'app ne changent pas.

## Stats d'écoute

Touche ta **photo de profil** (en haut à gauche) → **Stats d'écoute** : la ligne de Spotify ouvre celles de SoundMatch :

- filtres **Jour / Semaine / Mois / Année**, avec les flèches ‹ › pour remonter aux périodes précédentes ;
- **minutes écoutées** sur la période, nombre de titres, d'artistes et d'écoutes, et un graphique (par heure, par
  jour ou par mois) ;
- **Top artistes** et **Top titres** avec les minutes et le nombre d'écoutes de chacun (« Afficher plus » : 50).

Les écoutes sont relevées sur l'appareil à partir des infos « À l'écoute » de Spotify (titre, artiste, pochette),
seulement quand du son sort vraiment de Spotify. Une écoute compte à partir de 30 s. Tout reste dans
`Documents/SoundMatch-stats.json` de l'app.

**Données du compte Spotify, récupérées par le tweak** : avec la connexion de l'app (le jeton que Spotify envoie
avec ses propres requêtes, gardé en mémoire seulement, jamais écrit ni envoyé ailleurs qu'à Spotify) :

- onglet **Classement** : top artistes et top titres calculés par Spotify sur 4 semaines, 6 mois et environ 1 an
  (Spotify ne donne pas de minutes pour ce classement) ;
- **dernières écoutes du compte** (tous appareils, les 50 dernières, relues toutes les 10 min quand l'app tourne) :
  ajoutées aux minutes, avec une durée estimée jusqu'au titre suivant.

**Tout l'historique de Spotify** (avec les minutes) : Spotify ne le donne que sur demande. Sur spotify.com :
Compte › Confidentialité du compte › « Historique de streaming étendu » (depuis la création du compte) et/ou
« Données du compte » (dernière année) › Demander les données. Le mail contient un .zip : décompresse-le dans
Fichiers, puis dans Stats d'écoute touche ⬇︎ › Choisir les fichiers et sélectionne tous les
`Streaming_History_Audio_….json` (ou `StreamingHistory_music_….json`). Les jours importés remplacent le relevé de
l'iPhone ; après la date de l'export, c'est le relevé de l'iPhone qui continue.

## Comment ça marche

1. Dans **Paramètres › Lecture › Égaliseur** de Spotify, touche la ligne **Calibrer avec SoundMatch** (ou ligne
   **SoundMatch** en haut des Paramètres, ou appui long à trois doigts n'importe où → **Trouver mon égaliseur**).
2. Coupe l'égaliseur de Spotify et lance un morceau que tu connais bien.
3. 9 étapes : à chaque fois, trois versions du même son (**A**, **B**, **C**, dans un ordre mélangé : l'actuelle,
   plus et moins sur une zone — basses, aigus, médiums, présence, voix…). Tu passes de l'une à l'autre sans couper
   la musique et tu gardes ta préférée. Les écarts sont grands au début (±6 dB) puis plus fins (±2 dB). Si tu choisis
   la version qui monte (ou qui baisse), l'étape recommence (deux fois au plus) pour aller plus loin. Les trois
   versions ont le même volume ressenti : on compare le timbre, pas le volume. À la fin, si une bande dépasse
   +4 dB, toute la courbe est abaissée d'un bloc (même forme, sans saturation).
4. Résultat sur les 6 bandes de l'égaliseur de Spotify (60 Hz, 150 Hz, 400 Hz, 1 kHz, 2,4 kHz, 15 kHz) :
   **Mettre dans l'égaliseur de Spotify** écrit le réglage dans l'égaliseur de Spotify et l'allume (l'égaliseur
   du tweak s'efface alors). Pendant le test, l'égaliseur de Spotify est coupé, puis rétabli si tu fermes le test.

Menu (ligne **SoundMatch** dans les Paramètres de Spotify, ou appui long à trois doigts) : stats d'écoute, : activer / désactiver ton égaliseur, voir les réglages, remettre à plat, journal.

## Technique

Le tweak pose une notification de rendu sur l'unité de sortie audio d'iOS (RemoteIO) que Spotify crée, et y
applique 6 filtres (plateau grave, 4 cloches, plateau aigu), avec une baisse de volume pour ne pas saturer. Les
fonctions audio sont interceptées en réécrivant les tables d'import (principe de fishhook), ce qui marche sans JIT.

## Installation

1. Télécharge https://github.com/eliaskinzigeri-blip/short-limiter/releases/download/spotify-latest/SoundMatch.dylib
2. LiveContainer → onglet **Tweaks** → **+** → ajoute `SoundMatch.dylib`, puis touche le bouton **signature**.
3. Lance Spotify **depuis LiveContainer** : la ligne « SoundMatch » apparaît en haut des Paramètres, et « Stats d'écoute » du menu du profil ouvre les stats SoundMatch.

Si « Son de Spotify détecté » n'apparaît pas pendant le test alors que la musique joue, envoie le journal
(menu → Partager le journal) : il indique si la sortie audio de Spotify a été trouvée et son format.
