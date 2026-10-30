# Champis — app Apple

App SwiftUI de [Champis](https://github.com/adhumi/champis) pour iOS, iPadOS et macOS 26 : carte des spots à la parcelle, score du jour, hors ligne en forêt, retour terrain et « mes coins ». Phase 4 du plan de réalisation (spec « Spec — Champis »).

## Prérequis

- Xcode 27.2 ou plus récent (Swift 6.4). Le projet utilise le format `project.xcproj` (JSON) ; il ne s'ouvre pas dans Xcode 26.
- Un compte développeur pour la signature automatique : renseigner l'équipe dans *Signing & Capabilities* au premier lancement (`DEVELOPMENT_TEAM` n'est pas versionné).

## Structure

```
Champis.xcodeproj/          projet (project.xcproj), schéma partagé Champis
Champis/                    cible app : SwiftUI, MVVM @Observable, Assets, entitlements
ChampisTests/               tests de l'app (Swift Testing)
Packages/ChampisScoring/    paquet local : portage du scoring, vecteurs de parité en ressources de test
scripts/sync-vectors.sh     copie shared/vectors/ du monorepo dans le paquet, note VECTORS_VERSION
```

Les dossiers `Champis/` et `ChampisTests/` sont des dossiers synchronisés : ajouter un fichier sur disque suffit, le projet ne change pas.

## Scoring et parité

Le scoring de référence est en Python dans le monorepo. `ChampisScoring` le recalcule en Swift à partir des mêmes vecteurs (`shared/vectors/`), copiés ici par :

```sh
scripts/sync-vectors.sh ../champis      # puis relancer les tests
```

`Packages/ChampisScoring/VECTORS_VERSION` note la génération synchronisée (`scoring_version`, `species_hash`). L'app refuse une `scoring_version` renvoyée par `/species` qu'elle ne connaît pas. Règles d'écriture : skill `scoring-parity` du monorepo.

## Tests

Schéma `Champis` → ⌘U : exécute `ChampisTests` et `ChampisScoringTests`. En ligne de commande, pour le paquet seul :

```sh
cd Packages/ChampisScoring && swift test
```

## Icône

`Champis/Assets.xcassets/AppIcon.appiconset` est vide : y déposer le PNG 1024 du cèpe stylisé (iOS, image unique) et les tailles macOS, ou remplacer par un document Icon Composer.

## Reformater le projet

Le fichier `project.xcproj` a été généré hors d'Xcode, en JSON strict. Xcode le réécrit dans son style canonique à la première modification ; pour le faire sans Xcode :

```sh
swift run --package-path /chemin/vers/xcode-project-format xcprojformatter --update Champis.xcodeproj
```
