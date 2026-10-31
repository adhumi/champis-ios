# Champis — app Apple

App SwiftUI de [Champis](https://github.com/adhumi/champis) pour iOS, iPadOS et macOS 26 : carte des spots à la parcelle, score du jour, hors ligne en forêt, retour terrain et « mes coins ». Phase 4 du plan de réalisation (spec « Spec — Champis »).

## Prérequis

- Xcode 26.3 ou plus récent. Le projet est un `project.pbxproj` créé par Xcode (dossiers synchronisés) : le `.xcproj` JSON généré hors d'Xcode le 30 oct. 2026 ne s'ouvrait pas et a été remplacé.
- Cibles : iOS, iPadOS et macOS 26, mode de langage Swift 6. L'équipe de signature est renseignée dans le projet.

## Structure

```
Champis.xcodeproj/          projet (project.pbxproj), schéma partagé Champis
Champis/                    cible app : SwiftUI, MVVM @Observable, Assets, entitlements
Champis/API/                client champis-api (/species, /tiles, /weather/bbox) et ses modèles
Champis/Map/                carte : MapModel, overlay MKTileOverlay, TileStore, colorisation, écran
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

## Carte

`MapScreen` affiche un `MKMapView` (via `UIViewRepresentable` / `NSViewRepresentable` : la `Map` SwiftUI n'accepte pas d'`MKTileOverlay`) sous un overlay de tuiles colorisées. `TileStore` (acteur) lit les PMTiles du manifeste `GET /tiles` par requêtes Range et décode les PNG ; `TileColorizer` (fonction pure, testée) calcule par pixel `T` ou `S = T × M_eff × Φ` avec la météo de `GET /weather/bbox` (cellule la plus proche par bloc de 16 px, classe d'altitude lue dans la couche A, repli sur la médiane de la cellule) et la palette de `GET /species` ; `TileRenderer` encode et met en cache les PNG rendus. Changer de jour ne recharge aucune tuile. Pixel sans météo : transparent. Toucher la carte ouvre la fiche du point (`PointInspector` lit `T` et la classe d'altitude au zoom 15, `PointSheet` montre l'espèce qui porte le score, `M_eff`, `Φ`, la cellule et les facteurs météo de `GET /weather`). Sous le zoom 9 en mode score, la carte passe aux départements colorés par l'indice de `GET /departements` (vue France ; limites du GeoJSON servi par l'API sous `/web/departements.geojson`, décodé par `MKGeoJSONDecoder`). Les tuiles lues sont gardées sur disque (`DiskTileCache`, Application Support, exclu de la sauvegarde, purgé au changement de manifeste) : ce qui a été vu reste lisible sans réseau, premier étage du hors ligne ; la position GPS « pendant l'utilisation » s'affiche sur la carte à la demande. L'adresse de l'API se règle dans l'app (`https://champis.adhumi.fr` par défaut) ; l'avertissement sur le cadre légal de la cueillette s'affiche au premier lancement et reste accessible dans les réglages.

## Tests

Schéma `Champis` → ⌘U : exécute `ChampisTests`, `ChampisScoringTests` et `ChampisPMTilesTests`. En ligne de commande, pour le paquet seul :

```sh
cd Packages/ChampisScoring && swift test
```

## Icône

`Champis/AppIcon.icon` est un document Icon Composer (Xcode 26+) : fond dégradé ciel, deux calques de forêt stylisée (bande claire avec sapins, bande sombre au premier plan), puis un groupe Liquid Glass avec deux calques séparés, `pied` et `chapeau`, teintés cèpe de Bordeaux. Les couleurs et les réglages de verre (reflet, translucidité, ombre) se modifient dans Icon Composer ; les formes sont les SVG de `Assets/`, canevas 1024 points. `Assets.xcassets/AppIcon.appiconset` garde un PNG 1024 plat en repli pour les emplacements qui n'utilisent pas le document.
