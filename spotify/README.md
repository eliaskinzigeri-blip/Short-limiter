# SoundMatch (tweak pour l'app Spotify)

Tweak `.dylib` chargé par la fonction **Tweaks** de LiveContainer dans l'app Spotify que tu installes toi-même.
Il t'aide à trouver ton égaliseur par comparaisons à l'oreille. Aucune app Spotify n'est contenue ni publiée ici ;
pas de blocage de publicités ni de fonction payante débloquée ; rien n'est enregistré ni copié.

## Comment ça marche

1. Dans les **Paramètres de Spotify**, touche le bouton vert **« 🎚 SoundMatch : calibrer mon égaliseur »** (ou appui
   long à trois doigts n'importe où) → **Trouver mon égaliseur**.
2. Coupe l'égaliseur de Spotify et lance un morceau que tu connais bien.
3. 9 étapes : à chaque fois, trois versions du même son (**A**, **B**, **C**, dans un ordre mélangé : l'actuelle,
   plus et moins sur une zone — basses, aigus, médiums, présence, voix…). Tu passes de l'une à l'autre sans couper
   la musique et tu gardes ta préférée. Les écarts sont grands au début (±6 dB) puis plus fins (±2 dB).
4. Résultat sur les 6 bandes de l'égaliseur de Spotify (60 Hz, 150 Hz, 400 Hz, 1 kHz, 2,4 kHz, 15 kHz) :
   **Mettre dans l'égaliseur de Spotify** écrit le réglage dans l'égaliseur de Spotify et l'allume (l'égaliseur
   du tweak s'efface alors). Pendant le test, l'égaliseur de Spotify est coupé, puis rétabli si tu fermes le test.

Menu (bouton dans les Paramètres de Spotify, ou appui long à trois doigts) : activer / désactiver ton égaliseur, voir les réglages, remettre à plat, journal.

## Technique

Le tweak pose une notification de rendu sur l'unité de sortie audio d'iOS (RemoteIO) que Spotify crée, et y
applique 6 filtres (plateau grave, 4 cloches, plateau aigu), avec une baisse de volume pour ne pas saturer. Les
fonctions audio sont interceptées en réécrivant les tables d'import (principe de fishhook), ce qui marche sans JIT.

## Installation

1. Télécharge https://github.com/eliaskinzigeri-blip/short-limiter/releases/download/spotify-latest/SoundMatch.dylib
2. LiveContainer → onglet **Tweaks** → **+** → ajoute `SoundMatch.dylib`, puis touche le bouton **signature**.
3. Lance Spotify **depuis LiveContainer** : le bandeau vert « SoundMatch actif » apparaît.

Si « Son de Spotify détecté » n'apparaît pas pendant le test alors que la musique joue, envoie le journal
(menu → Partager le journal) : il indique si la sortie audio de Spotify a été trouvée et son format.
