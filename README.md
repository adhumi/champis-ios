# Champis — app Apple

App SwiftUI de [Champis](https://github.com/adhumi/champis) pour iOS, iPadOS et macOS 26 : carte des spots à la parcelle, score du jour, hors ligne en forêt, retour terrain et « mes coins ». Phase 4 du plan de réalisation (spec « Spec — Champis »).

## Prérequis

- Xcode 26.3 ou plus récent. Le projet est un `project.pbxproj` créé par Xcode (dossiers synchronisés) : le `.xcproj` JSON généré hors d'Xcode le 30 oct. 2026 ne s'ouvrait pas et a été remplacé.
- Cibles : iOS, iPadOS et macOS 26, mode de langage Swift 6. L'équipe de signature est renseignée dans le projet.

## Structure

```
Champis.xcodeproj/          projet (project.pbxproj), schéma partagé Champis
Champis/                    cible app : SwiftUI, MVVM @Observable, Assets, entitlements
ChampisTests/               tests de l'app (Swift Testing)
Packages/ChampisScoring/    paquet local : portage du scoring, vecteurs de parité en ressources de test
Packages/ChampisPMTiles/    paquet local : lecteur PMTiles (fichier ou Range HTTP) et décodeur PNG de données
scripts/sync-vectors.sh     copie shared/vectors/ du monorepo dans le paquet, note VECTORS_VERSION
```

Les dossiers `Champis/` et `ChampisTests/` sont des dossiers synchronisés : ajouter un fichier sur disque suffit, le projet ne change pas.

## Scoring et parité

Le scoring de référence est en Python dans le monorepo. `ChampisScoring` le porte en Swift (trapèze, Φ, M, M_eff, groupes, palette ; dates civiles sans fuseau, même ordre d'opérations) et le valide contre les mêmes vecteurs (`shared/vectors/`), avec les fichiers espèces et la palette du même commit en ressources de test, copiés ici par :

```sh
scripts/sync-vectors.sh ../champis      # puis relancer les tests
```

`Packages/ChampisScoring/VECTORS_VERSION` note la génération synchronisée (`scoring_version`, `species_hash`). L'app refuse une `scoring_version` renvoyée par `/species` qu'elle ne connaît pas. Règles d'écriture : skill `scoring-parity` du monorepo.

## Tuiles

`ChampisPMTiles` lit les PMTiles v3 publiés par le pipeline, en local (fichier téléchargé) ou à distance par requêtes `Range`, et décode les PNG de données octet par octet (jamais via `UIImage`, dont la gestion des couleurs décale les gris). Ses tests rejouent un fichier produit par la bibliothèque `pmtiles` du pipeline et des PNG de chaque filtre (`Tests/ChampisPMTilesTests/Resources`).

## Tests

Schéma `Champis` → ⌘U : exécute `ChampisTests`, `ChampisScoringTests` et `ChampisPMTilesTests`. En ligne de commande, pour le paquet seul :

```sh
cd Packages/ChampisScoring && swift test
```

## Icône

`Champis/AppIcon.icon` est un document Icon Composer (Xcode 26+) : fond dégradé ciel, deux calques de forêt stylisée (bande claire avec sapins, bande sombre au premier plan), puis un groupe Liquid Glass avec deux calques séparés, `pied` et `chapeau`, teintés cèpe de Bordeaux. Les couleurs et les réglages de verre (reflet, translucidité, ombre) se modifient dans Icon Composer ; les formes sont les SVG de `Assets/`, canevas 1024 points. `Assets.xcassets/AppIcon.appiconset` garde un PNG 1024 plat en repli pour les emplacements qui n'utilisent pas le document.
