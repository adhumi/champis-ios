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
Champis/Field/              retour terrain et mes coins : modèles, identité (trousseau), LocalStore JSON, formulaire, liste
Champis/Offline/            hors ligne par département : manifeste offline.json, OfflineStore, DownloadManager (URLSession de fond), écran
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

## Navigation

Refonte UX, lot 1 (décision du 1er nov. 2026 ; analyse et wireframes dans le doc « Champis — Analyse UX/UI et proposition de refonte ») : trois onglets, une question chacun. **Mes coins** (quand ?) : liste classée par score du jour, libellé de la palette et espèce porteuse, tendance en mots (« mieux dimanche », « stable toute la semaine », « en baisse », `CoinTrend`), fiche d'un coin avec ses onze jours (`GET /coins` › `days`), Voir sur la carte, Renommer, Supprimer, chiffres derrière Détails ; l'état vide porte la promesse de confidentialité. **Carte** (où ?) : l'écran existant. **Comprendre** (pourquoi ?) : textes légal et confidentialité, résumé du modèle, en attendant les articles du lot 4. L'app s'ouvre toujours sur la carte ; une notification « mes coins » (`coin_id` dans la charge utile) bascule sur Mes coins et ouvre la fiche (`AppRouter`, `AppDelegate`). Les réglages restent accessibles depuis chaque onglet. Un seul `MapModel`, créé par `ContentView`, est partagé par les trois onglets.

## Carte

`MapScreen` affiche un `MKMapView` (via `UIViewRepresentable` / `NSViewRepresentable` : la `Map` SwiftUI n'accepte pas d'`MKTileOverlay`) sous un overlay de tuiles colorisées. `TileStore` (acteur) lit les PMTiles du manifeste `GET /tiles` par requêtes Range et décode les PNG ; `TileColorizer` (fonction pure, testée) calcule par pixel `T` ou `S = T × M_eff × Φ` avec la météo de `GET /weather/bbox` (cellule la plus proche par bloc de 16 px, classe d'altitude lue dans la couche A, repli sur la médiane de la cellule) et la palette de `GET /species` ; `TileRenderer` encode et met en cache les PNG rendus. Changer de jour ne recharge aucune tuile. Pixel sans météo : transparent. Toucher la carte ouvre la fiche du point (`PointInspector` lit `T` et la classe d'altitude au zoom 15, `PointSheet` montre l'espèce qui porte le score, `M_eff`, `Φ`, la cellule et les facteurs météo de `GET /weather`). Sous le zoom 9 en mode score, la carte passe aux départements colorés par l'indice de `GET /departements` (vue France ; limites du GeoJSON servi par l'API sous `/web/departements.geojson`, décodé par `MKGeoJSONDecoder`). Les tuiles lues sont gardées sur disque (`DiskTileCache`, Application Support, exclu de la sauvegarde, purgé au changement de manifeste) : ce qui a été vu reste lisible sans réseau, premier étage du hors ligne ; la position GPS « pendant l'utilisation » s'affiche sur la carte à la demande. L'adresse de l'API se règle dans l'app (`https://champis.adhumi.fr` par défaut) ; l'avertissement sur le cadre légal de la cueillette s'affiche au premier lancement et reste accessible dans les réglages.

## Hors ligne par département

Le pipeline publie un jeu de PMTiles par département (décision du 31 oct. 2026) : le manifeste `GET /tiles` marque ces entrées d'un champ `dept`. Depuis les réglages, « Départements embarqués » liste ce qui est sur l'appareil et permet d'en ajouter : choix du département et des espèces, poids estimé, puis téléchargement des fichiers entiers par `URLSession` de fond (`DownloadManager`), météo des 11 jours récupérée sur l'emprise du fichier par sous-emprises de 0,3° (`GET /weather/bbox` refuse plus de 40 cellules), le tout noté dans `offline.json` (`OfflineStore`). Un département n'est disponible qu'une fois tuiles, couche A et météo écrits ; on peut rafraîchir la météo seule ou supprimer. Le lecteur de tuiles lit ces fichiers avant la source distante ; sans réseau, la météo embarquée sert la carte avec sa date affichée, et les réponses `/species` et `/tiles` du dernier démarrage permettent de lancer l'app. Rien n'est inventé : un pixel hors des départements embarqués reste transparent.

## Retour terrain et mes coins

Observations (trouvé / rien trouvé, espèce, position, date, quantité, sans photo) et coins (favoris nommés) sont saisis dans l'app seulement et restent privés. Identité : un UUID généré au premier lancement dans le trousseau synchronisé iCloud (`KeychainIdentityStore`, repli `UserDefaults` quand le trousseau refuse), envoyé en en-tête `X-Champis-User`. Stockage local : fichiers JSON dans Application Support (`LocalStore`, écriture atomique) ; les observations partent par lots idempotents vers `POST /observations` dès que le réseau répond, les coins par `PUT /coins` en liste complète. Les scores des coins viennent de `GET /coins` (calculés par le backend) ; la notification est calculée et envoyée par le backend, l'app ne fait aucun travail en arrière-plan. Le jeton APNs n'est pas encore envoyé : cela demande la capacité Push Notifications sur l'App ID, à venir avec les clés. « Supprimer mes observations et mes coins » dans les réglages exerce le droit à l'effacement (`DELETE /observations`, puis purge locale).

## Tests

Schéma `Champis` → ⌘U : exécute `ChampisTests`, `ChampisScoringTests` et `ChampisPMTilesTests`. En ligne de commande, pour le paquet seul :

```sh
cd Packages/ChampisScoring && swift test
```

## Icône

`Champis/AppIcon.icon` est un document Icon Composer (Xcode 26+) : fond dégradé ciel, deux calques de forêt stylisée (bande claire avec sapins, bande sombre au premier plan), puis un groupe Liquid Glass avec deux calques séparés, `pied` et `chapeau`, teintés cèpe de Bordeaux. Les couleurs et les réglages de verre (reflet, translucidité, ombre) se modifient dans Icon Composer ; les formes sont les SVG de `Assets/`, canevas 1024 points. `Assets.xcassets/AppIcon.appiconset` garde un PNG 1024 plat en repli pour les emplacements qui n'utilisent pas le document.
