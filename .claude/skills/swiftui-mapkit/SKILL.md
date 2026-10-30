---
name: swiftui-mapkit
description: Carte Champis dans l'app (SwiftUI Map + MKTileOverlay maison) - tuiles PMTiles T et A, colorisation par la palette, score du jour S = T × M_eff × Φ par pixel, groupes, curseur de jour, fiche au toucher, vue France. À lire avant tout code dans Champis/Map ou qui touche un overlay, une tuile ou l'affichage d'un score.
---

# Carte SwiftUI + MapKit

La carte est la raison d'être de l'app. Elle affiche le potentiel terrain `T` ou le score du jour `S` à 25 m sur un fond Apple, et une vue France par département en dézoomant. Les règles du modèle sont dans le skill `champis-model` ; la parité du calcul dans `scoring-parity` ; ce skill dit comment les mettre à l'écran.

## Ce que la carte reçoit

| Donnée | Source | Format |
| --- | --- | --- |
| `T` par espèce | PMTiles `T-<espèce>-<hash>-…pmtiles` (manifeste `GET /tiles`) | PNG 256 px, niveaux 6–15, Web Mercator XYZ ; gris = `T × 254`, alpha 0 = hors forêt, 255 = nodata (`palette.json › tile_encoding`) |
| Classe d'altitude `A` | PMTiles `A-300m-…pmtiles`, un seul pour toutes les espèces | gris = indice `k` de la classe `[300k, 300k+300[` m, alpha 0 = inconnu (`palette.json › alt_encoding`) |
| `M_eff`, `Φ` | `GET /weather/bbox` sur l'emprise visible, 11 jours J−3 → J+7, par cellule 5 km et par classe d'altitude | plafonné à 40 cellules (422 « zoomez ») ; cellules `unavailable` listées à part ; `stale` si cache périmé |
| Espèces, groupes, palette, seuils | `GET /species` | JSON tel quel ; rien n'est embarqué dans l'app |
| Indice par département | `GET /departements?species=&day=` | pour la vue France |

## Règles d'affichage (ne pas en inventer d'autres)

1. **Décodage des PNG octet par octet** (`ChampisPMTiles`), jamais via `UIImage`/`CGImage` : la gestion des couleurs décale les gris d'un niveau et change la classe d'un pixel près des seuils. Même leçon que `web/png.js` dans le monorepo.
2. **Score du pixel** : `S = T × M_eff × Φ`, avec `M_eff` et `Φ` de la cellule qui contient le pixel **et** de la classe d'altitude lue dans `A`. Sans `A` chargée, repli sur la classe la plus proche de `elevation_m` de la cellule, et la fiche l'indique « (médiane cellule) ».
3. **Groupe** (cèpes, girolles) : score = max sur les espèces du groupe de `T_e × M_eff_e × Φ_e` ; la fiche nomme l'espèce qui porte le score (règle 9).
4. **Pixel sans météo** (cellule `unavailable`, hors grille) : transparent. Jamais un 0,5 inventé. `stale` s'affiche en texte.
5. **Palette et seuils** viennent de `/species` (`palette`). Une couleur n'est jamais écrite en dur.
6. **Changer de jour ne recharge aucune tuile** : les 11 jours sont déjà là, seule la colorisation change.
7. **Mode T** (potentiel terrain seul) et **mode S** (score du jour) : même overlay, deux fonctions de couleur.
8. **Avertissement cadre légal** (forêt privée, arrêtés préfectoraux) visible depuis la carte, décision du 30 oct. 2026.

## Architecture

- `MapModel` (`@Observable`, MainActor) : espèce ou groupe courant, jour courant, mode T/S, cellules météo chargées, état `stale`/indisponible, position sélectionnée. Les vues ne calculent rien.
- Chargement et décodage des tuiles **hors du MainActor** : un acteur `TileStore` qui lit les PMTiles (requêtes Range, cache disque, voir skill `offline`) et renvoie des matrices `UInt8`. L'isolation `MainActor` par défaut du projet impose de marquer ce code `nonisolated` ou de le mettre dans un acteur.
- `ScoreTileOverlay: MKTileOverlay` + `MKTileOverlayRenderer` : pour une tuile z/x/y, prend `T` (et `A`) depuis `TileStore`, les cellules météo depuis `MapModel`, produit une image RGBA colorisée. XYZ natif des deux côtés, pas de conversion TMS. `canReplaceMapContent = false`, `minimumZ = 6`, `maximumZ = 15`, 256 px.
- La colorisation est une fonction pure testable : `(t: UInt8, altClass: UInt8?, cell: WeatherCell?, day) -> RGBA`. Elle a ses tests, indépendants de MapKit.
- Fond Apple standard ou satellite, opacité de l'overlay réglable.
- `Map` SwiftUI avec `MapReader` pour le toucher → coordonnée → pixel (T, classe, cellule) → fiche.

## Fiche au toucher (v1 réduite, décision du 30 oct. 2026)

T, classe d'altitude du pixel, cellule météo, `M_eff`, `Φ`, facteurs météo via `GET /weather?cell=&species=` (`temp`, `rain`, `trigger`, `soil_moisture`, `frost`, `water_balance`, `heat`, `memory`), et l'espèce qui porte le score du groupe. Les facteurs terrain (essence, pH, exposition) ne sont pas dans les tuiles : pas de fiche terrain détaillée tant que la spec ne décide pas de couches supplémentaires.

## Vue France

En dessous d'un zoom seuil, la carte passe aux départements colorés par l'indice `I = Σ T × M_eff × Φ / Σ T` (section Scoring de la spec), servi par `/departements`, avec la même palette. Groupe = max des indices d'espèces. Les limites départementales viennent d'un GeoJSON embarqué ou servi par l'API : à poser dans la spec avant de coder.

## Accessibilité et performance

- La couleur ne porte jamais seule l'information : la fiche donne le libellé (`excellent`, `bon`…) et une légende est accessible.
- Colorisation en mémoire sans allocation par pixel ; une image par tuile et par (espèce, jour, mode), mise en cache et invalidée au changement de jour.
- Pas de `#available` : iOS 26 minimum.

## Tests

Swift Testing. La fonction de couleur est testée contre les seuils exacts de `shared/vectors/palette.json` (0,15 / 0,35 / 0,55 / 0,75) et sur les cas limites : nodata, alpha 0, cellule absente, classe d'altitude inconnue, groupe avec espèce dominante. Les tuiles de test sont des PNG générés par le pipeline (`tiles._png`) copiés en ressources, jamais dessinés à la main.
