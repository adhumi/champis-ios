---
name: swiftui-mapkit
description: Carte Champis dans l'app (MKMapView dans SwiftUI + MKTileOverlay maison) - tuiles PMTiles T et A, colorisation par la palette, score du jour S = T × M_eff × Φ par pixel, groupes, curseur de jour, bandeau des jours, fiche au toucher. À lire avant tout code dans Champis/Map ou qui touche un overlay, une tuile ou l'affichage d'un score.
---

# Carte SwiftUI + MapKit

La carte est la raison d'être de l'app. Elle affiche le potentiel terrain `T` ou le score du jour `S` à 25 m sur un fond Apple, à tout zoom : la vue France par département est retirée (spec › Points ouverts › Vue France et indice par département, décision du 4 nov. 2026). Les règles du modèle sont dans le skill `champis-model` ; la parité du calcul dans `scoring-parity` ; ce skill dit comment les mettre à l'écran.

## Ce que la carte reçoit

| Donnée | Source | Format |
| --- | --- | --- |
| `T` par espèce | PMTiles `T-<espèce>-<hash>-…pmtiles` (manifeste `GET /tiles`) | PNG 256 px, niveaux 6–15, Web Mercator XYZ ; gris = `T × 254`, alpha 0 = hors forêt, 255 = nodata (`palette.json › tile_encoding`) |
| Classe d'altitude `A` | PMTiles `A-300m-…pmtiles`, un seul pour toutes les espèces | gris = indice `k` de la classe `[300k, 300k+300[` m, alpha 0 = inconnu (`palette.json › alt_encoding`) |
| `M_eff`, `Φ` | `GET /weather/bbox` sur l'emprise visible (+ 0,1° de marge), 11 jours J−3 → J+7, par cellule 5 km et par classe d'altitude, **au zoom 9 et au-delà** | servi depuis la météo précalculée à chaque pré-chauffe (décision du 2 nov. 2026) : une emprise d'écran entière à tout zoom, `computed_at` affiché dans le statut ; 422 « zoomez » seulement au-delà de 5 000 cellules ; cellules `unavailable` listées à part ; `stale` si cache périmé. Une emprise contenue dans la dernière réponse complète (zoom avant, petit déplacement, moins de 30 min) ne redemande rien (`MapModel.weatherAlreadyCovers`) |
| `M_eff × Φ` du jour | `GET /weather/field?species=&day=&min_lon=…` sur l'emprise visible (+ 0,1°), **sous le zoom 9** (`MapModel.fieldZoom`) : un seul jour, sans plafond de cellules (France entière ≈ 20 000), `f[espèce][classe]` par cellule, `stale` seulement si vrai, `unavailable` compté | spec › Points ouverts › Carte visible dès l'ouverture (4 nov. 2026) : fusionné dans le même `WeatherField` que bbox (`WeatherFactor`, `row` nil : `M_eff` et `Φ` séparés viennent de `GET /weather?cell=` pour la fiche) ; changer de jour sous le seuil redemande le champ de ce jour, gardé par (jour, couche) ; même règle de couverture ; statut : cellules, `computed_at`, périmées et manquantes en clair |
| Espèces, groupes, palette, seuils | `GET /species` | JSON tel quel ; rien n'est embarqué dans l'app |
| Indice par département | `GET /departements?species=` | 11 jours par département, pour le seul bandeau des jours (pastille = indice du département sous le centre, trouvé dans le GeoJSON `/web/departements.geojson` chargé une fois) ; les notifications des coins le lisent côté backend |

## Règles d'affichage (ne pas en inventer d'autres)

1. **Décodage des PNG octet par octet** (`ChampisPMTiles`), jamais via `UIImage`/`CGImage` : la gestion des couleurs décale les gris d'un niveau et change la classe d'un pixel près des seuils. Même leçon que `web/png.js` dans le monorepo.
2. **Score du pixel** : `S = T × M_eff × Φ`, avec `M_eff` et `Φ` de la cellule qui contient le pixel **et** de la classe d'altitude lue dans `A`. Sans `A` chargée, repli sur la classe la plus proche de `elevation_m` de la cellule, et la fiche l'indique « (médiane cellule) ».
3. **Groupe** (cèpes, girolles) : score = max sur les espèces du groupe de `T_e × M_eff_e × Φ_e` ; la fiche nomme l'espèce qui porte le score (règle 9).
4. **Pixel sans météo** (cellule `unavailable`, hors grille, ou à plus de 7,5 km de la cellule la plus proche, `CellIndex.maxDistanceKm`) : transparent. Jamais un 0,5 inventé, jamais la météo de la cellule voisine (une cellule sans ligne pour l'espèce, le jour ou la classe laisse ses pixels transparents). `stale` s'affiche en texte.
5. **Palette et seuils** viennent de `/species` (`palette`). Une couleur n'est jamais écrite en dur.
6. **Changer de jour ne recharge aucune tuile** : les 11 jours sont déjà là, seule la colorisation change.
7. **Mode T** (potentiel terrain seul) et **mode S** (score du jour) : même overlay, deux fonctions de couleur.
8. **Avertissement cadre légal** (forêt privée, arrêtés préfectoraux) visible depuis la carte, décision du 30 oct. 2026.

## Architecture

- **`MKMapView` dans un `UIViewRepresentable` / `NSViewRepresentable`** (`MapContainer`), pas la `Map` SwiftUI : celle-ci n'accepte pas d'`MKTileOverlay` (constat du 30 oct. 2026, noté dans la spec › App iOS). Le toucher passe par un gesture recognizer → `convert(_:toCoordinateFrom:)`.
- `MapModel` (`@Observable`, MainActor) : espèce ou groupe courant, jour courant, mode T/S, cellules météo chargées (`WeatherField`), état `stale`/indisponible, position sélectionnée, `renderGeneration` incrémenté à chaque réglage poussé au rendu. Les vues ne calculent rien.
- Client `ChampisAPI` (`Champis/API`) : `/species`, `/tiles`, `/weather/bbox`, `/weather/field`, décodage hors MainActor (`@concurrent`). L'adresse de l'API est un réglage de l'app (`@AppStorage("apiBaseURL")`, défaut `https://champis.adhumi.fr`).
- Chargement et décodage des tuiles **hors du MainActor** : un acteur `TileStore` qui lit les PMTiles (requêtes Range, cache disque, voir skill `offline`) et renvoie des matrices `UInt8`. L'isolation `MainActor` par défaut du projet impose de marquer ce code `nonisolated` ou de le mettre dans un acteur.
- `ScoreTileOverlay: MKTileOverlay` (support : emprise, `minimumZ = 6`, `maximumZ = 15`, 256 px, `canReplaceMapContent = false`) dessiné par `ScoreOverlayRenderer: MKOverlayRenderer`, **pas** par `MKTileOverlayRenderer` (décision du 1er nov. 2026) : son `reloadData()` vidait la carte à chaque réglage (tuiles réapparaissant carré par carré, tuiles en échec restées vides) et ses tuiles lissées à zoom non entier laissaient des coutures. Le renderer maison garde l'image périmée à l'écran jusqu'à la nouvelle, montre une tuile parente agrandie en attendant, redemande une tuile en échec après 3 s, pose chaque image sur des bords alignés au pixel sans interpolation ni anticrénelage. Il demande les images à `TileRenderer` (classe `Sendable`, `Mutex`) qui lit `T` de chaque espèce et `A` **en parallèle** depuis `TileStore` (lectures dédupliquées, disque, réseau et décodage hors de l'acteur), applique les réglages (`RenderSettings` : couche, mode, jour, `WeatherField`, palette) poussés par `MapModel` et renvoie une `CGImage` (plus d'aller-retour PNG) avec la génération des réglages. Un réglage appelle `settingsChanged()` (redessin), jamais `reloadData()`. XYZ natif des deux côtés, pas de conversion TMS.
- La colorisation est une fonction pure testable, `TileColorizer` : `values(Request) -> [Double]` (nan = transparent) puis `render` → RGBA. Cellule météo par bloc de 16 × 16 px (comme la carte web), trouvée par l'index spatial `CellIndex` (casiers de 0,05°, recherche dans les casiers qui couvrent 7,5 km : quelques dizaines de candidats par bloc, jamais un parcours des 20 000 cellules du champ France), classe d'altitude par pixel. Ses tests (`ChampisTests/TileColorizerTests`, `CellIndexTests`) sont indépendants de MapKit.
- Fond Apple standard ou satellite, opacité de l'overlay réglable.
- Toucher → coordonnée (`MapSelection` dans le modèle) → pixel (T, classe, cellule) → fiche (PR suivante).

## Fiche au toucher (v1 réduite, décision du 30 oct. 2026)

T, classe d'altitude du pixel, cellule météo, `M_eff`, `Φ`, facteurs météo via `GET /weather?cell=&species=` (`temp`, `rain`, `trigger`, `soil_moisture`, `frost`, `water_balance`, `heat`, `memory`), et l'espèce qui porte le score du groupe. Les facteurs terrain (essence, pH, exposition) ne sont pas dans les tuiles : pas de fiche terrain détaillée tant que la spec ne décide pas de couches supplémentaires.

Implémentation : `PointInspector.inspect` (fonction pure async, testée avec un PMTiles en mémoire) lit `T` de chaque espèce de la couche et la classe `A` au zoom 15, prend la cellule la plus proche et garde la meilleure espèce ; trois issues : `noData` (hors forêt), `noWeather` (du terrain mais pas de ligne météo), `scored`. `PointSheet` affiche ; les facteurs arrivent ensuite par `MapModel.loadFactors`. Jamais de valeur inventée : sans ligne météo, la fiche le dit.

## Menu de calque (lots 2 à 4)

Groupes puis espèces, le potentiel toute saison en bascule, et depuis le lot 4 le fond de carte (standard ou satellite) : il n'y a plus de réglage d'opacité ni de fond ailleurs, `overlayOpacity` est fixe.

## Appui long et disposition iPad / Mac (lot 3)

Un appui long (0,5 s) sur la carte donne `MapModel.longPress` ; `MapScreen` ouvre le menu de terrain au point pressé (skill `field-feedback`). « Ajouter à mes coins » passe par la fiche (`requestCoin` → `select` ; `PointSheet` ouvre directement le nom). Sur iPad en largeur régulière et sur Mac, `SplitContentView` remplace les onglets : barre latérale, carte en détail, fiches (`PointSheet`, `CoinDetailView`) dans `.inspector`. `MapScreen(layout: .split)` ne présente aucune feuille de fiche : c'est la sélection du modèle qui commande, et le bouton OK de la fiche appelle `clearSelection`, jamais `dismiss`.

## Bandeau des jours et plus de vue France (4 nov. 2026)

La vue France (départements colorés par l'indice `I = Σ T × M_eff × Φ / Σ T` sous le zoom 9) est retirée, de l'app comme du site : l'indice n'était pas à l'échelle de `S` et la couche de tuiles reste visible à tout zoom. `GET /departements` ne sert plus qu'au bandeau des onze jours : `MapModel.dayDots` colore chaque pastille par l'indice du département sous le centre de la carte (`centerDeptCode`, point dans polygone sur le GeoJSON `/web/departements.geojson` décodé par `MKGeoJSONDecoder`, chargé une fois, sans appel réseau par déplacement). Département ou jour sans indice : pastille vide, jamais une valeur inventée. Le GeoJSON donne aussi les noms des départements (écran hors ligne, proposition d'embarquer).

## Accessibilité et performance

- La couleur ne porte jamais seule l'information : la fiche donne le libellé (`excellent`, `bon`…) et une légende est accessible.
- Colorisation en mémoire sans allocation par pixel ; une image par tuile et par (espèce, jour, mode), mise en cache et invalidée au changement de jour.
- Pas de `#available` : iOS 26 minimum.

## Tests

Swift Testing. La fonction de couleur est testée contre les seuils exacts de `shared/vectors/palette.json` (0,15 / 0,35 / 0,55 / 0,75) et sur les cas limites : nodata, alpha 0, cellule absente, classe d'altitude inconnue, groupe avec espèce dominante. Les tuiles de test sont des PNG générés par le pipeline (`tiles._png`) copiés en ressources, jamais dessinés à la main.
