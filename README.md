# ShortLimiter

Tweak iOS (bibliothèque `.dylib` en Objective-C) qui limite le temps passé sur les **Shorts** dans l'app YouTube,
chargé par la fonction **Tweaks** de LiveContainer. Il ne fait que gérer le temps des Shorts : pas de blocage de
publicités, pas de fonction payante débloquée.

Ce dépôt ne contient que le code original du tweak et ses versions compilées. **Aucune app YouTube (IPA) n'y est
téléchargée, embarquée ni publiée** : tu fournis toi-même ton app.

## Fonctions

- **Détection des Shorts** à l'exécution : chaque seconde, le tweak parcourt les contrôleurs de vue affichés et
  reconnaît un écran Shorts quand le nom de sa classe contient un des « noms recherchés » (par défaut `Reel`, `Shorts`),
  sans contenir un « nom exclu » (`Shelf`, `Thumbnail`, `Cell`…), et qu'il occupe au moins la moitié de l'écran.
- **Compteur** : seulement quand YouTube est au premier plan et qu'un Short est affiché. Petit compteur en haut de
  l'écran (désactivable).
- **Deux règles au choix**, activables séparément ou ensemble :
  - **Pause après une limite** (activée par défaut) : après 5 min de Shorts (réglable), pause de 30 min (réglable),
    puis le compteur repart de zéro ;
  - **Limite quotidienne** (désactivée par défaut) : après 30 min de Shorts dans la journée (réglable), plus de
    Shorts jusqu'à minuit.
- **Réglages selon le jour** (option) : chaque jour de la semaine a ses propres règles. « Jour à régler » choisit
  le jour modifié, « Copier vers un autre jour » recopie ses réglages (par exemple lundi → mardi et jeudi).
- **Blocage** : un écran
  par-dessus affiche le temps restant et le tweak tente de quitter les Shorts tout seul (fermer l'écran, revenir en
  arrière, toucher le premier onglet de la barre du bas). La barre d'onglets du bas reste accessible : le reste de
  YouTube (vidéos, recherche, abonnements) reste utilisable.
- **Mode focus NoteFlow** : pendant un focus NoteFlow (créneau du jour, rappel avec focus ou puce NFC), l'app
  entière est bloquée, sans raccourci ni automatisation : un écran opaque sans bouton, le son coupé, puis le retour
  à l'écran d'accueil, jusqu'à la fin du focus. Liaison (une fois) : dans l'app NoteFlow de l'iPhone, **Ma routine ›
  Régler › Copier le code de liaison**, puis ouvre l'app : le code est lu dans le presse-papiers (ou réglages du
  tweak › **Mode focus NoteFlow** › Coller le code de liaison). Le code est partagé avec `shared/NFFocus.m`.
- **Réglages et statistiques du jour** : rubrique **Shorts Limiter** (logo Shorts) dans les **Paramètres de YouTube**,
  avec les cellules et sélecteurs de YouTube (limite, durée de pause, compteur). Historique et détection avancée :
  dernière ligne de la rubrique, appui long à trois doigts n'importe où, ou toucher le compteur. Tout est enregistré (NSUserDefaults) et survit à la fermeture de l'app.
- **Reprise des vidéos** : dès que tu quittes une vidéo classique (pas un Short), sa position est gardée sur
  l'iPhone, même si l'historique YouTube est en pause. Quand tu y reviens, elle repart à cet endroit et le message
  « Retour là où vous vous êtes arrêté » s'affiche 3 secondes. Une vidéo regardée jusqu'au bout repart du début.
  Option « Reprendre les vidéos » dans la rubrique Shorts Limiter.
- **Journal** : `Documents/ShortLimiter-journal.txt` de l'app, aussi visible et partageable depuis les réglages
  (« Voir le journal »). Il liste les écrans vus (nom de classe et part de l'écran) pour ajuster la détection.

## Installation

1. Sur l'iPhone, télécharge la dernière version :
   https://github.com/eliaskinzigeri-blip/short-limiter/releases/download/latest/ShortLimiter.dylib
   (enregistre-la dans Fichiers).
2. Ouvre SideStore, onglet **My Apps**, puis le bouton en haut qui ouvre l'interface **LiveContainer**.
3. Onglet **Tweaks** : ajoute `ShortLimiter.dylib` (bouton +, depuis Fichiers). Si tu le ranges dans un dossier,
   crée un dossier dédié.
4. Onglet des apps : appui long sur ton app YouTube → réglages de l'app → **Dossier de tweaks** : choisis le dossier
   qui contient `ShortLimiter.dylib`.
5. Toujours dans l'onglet **Tweaks**, touche le bouton **signature** (à gauche du +) : il signe le tweak avec le
   certificat de LiveContainer. Sans ça, YouTube affiche « Failed to load tweaks … code signature invalid ».
   Si la signature échoue, importe d'abord le certificat de SideStore dans les **Paramètres** de LiveContainer.
6. Lance YouTube **depuis LiveContainer** : la rubrique **Shorts Limiter** apparaît dans les Paramètres de YouTube (sa première ligne donne la version du tweak), et un appui
   long à trois doigts ouvre les réglages.

Pour mettre à jour : remplace le fichier par la nouvelle version (même lien), retouche le bouton **signature**,
puis relance YouTube.

## Ajuster la détection après un premier essai

La détection est faite sans le code de YouTube : elle peut ne pas marcher du premier coup, et une mise à jour de
YouTube peut la casser.

1. Ouvre un Short, reste quelques secondes, puis reviens à l'accueil.
2. Appui long à trois doigts → **Voir le journal**. Repère les lignes `Écran vu : …` apparues quand le Short
   était affiché, et la ligne `Shorts : OUI (…)` si la détection a marché.
3. Si rien ne correspond, ajoute un morceau du nom de classe de l'écran Shorts dans **Noms recherchés** ; si un autre
   écran est pris pour un Short, ajoute un morceau de son nom dans **Noms exclus**.
4. **Barre d'onglets** : morceau du nom des vues des onglets du bas (par défaut `PivotBarItem`), utilisé pour
   revenir à l'accueil pendant le blocage.

## Compilation

GitHub Actions (`.github/workflows/build.yml`) compile `src/*.m` avec clang et le SDK iOS sur un runner macOS (arm64,
iOS 15 minimum), signe le `.dylib` en ad hoc et le publie dans la version `latest` et une version `v1.0.N`.
