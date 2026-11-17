# Champis — app Apple (SwiftUI)

Client iOS / iPadOS / macOS 26 de Champis. Le modèle, les règles d'espèces et la spec vivent dans le monorepo `adhumi/champis` (doc « Spec — Champis »). Les skills sont dans `.claude/skills/` (provenance dans `SOURCES.md`) :

- `champis-model`, `scoring-parity`, `spec-sync`, `roadmap` : copies du référentiel, synchronisées par `scripts/sync-skills.sh`, à ne pas modifier ici. Lis `champis-model` et `scoring-parity` avant tout code qui calcule ou affiche un score. Toute décision structurante passe par la spec avant le code (`spec-sync`).
- `swiftui-mapkit`, `offline`, `field-feedback` : skills maison de la phase 4, à lire avant de toucher la carte, le hors ligne, les observations ou les coins.
- `swiftui-pro`, `swift-concurrency-pro`, `swift-testing-pro`, `ios-accessibility`, `background-execution` : skills communautaires copiés en dossier (MIT), à appliquer à toute revue ou écriture de code Swift.

## Décisions qui s'appliquent ici

- iOS, iPadOS et macOS 26 minimum, mode de langage Swift 6, isolation `MainActor` par défaut dans l'app. Pas de `#available`.
- MVVM avec `@Observable`. Un modèle par écran, les vues ne calculent rien.
- Projet `project.pbxproj` créé par Xcode (le `.xcproj` généré hors d'Xcode ne s'ouvrait pas). Dossiers synchronisés pour `Champis/` et `ChampisTests/` : ne pas éditer le projet pour ajouter un fichier ; le paquet local est `Packages/ChampisScoring`.
- Aucune valeur d'espèce dans le code : tout vient de `/species`. Palette et seuils viennent de `shared/palette.json` via l'API.
- Météo interpolée entre les centres des cellules voisines pour la carte et la fiche (spec › Scoring, 13 nov. 2026) : `CellInterpolation` du paquet `ChampisScoring`, portage de `champis_api/interp.py` validé par `interp.json` ; une cellule sans météo laisse ses pixels transparents. Entre deux classes d'altitude, même module (`betweenClasses`, vecteur `alt.json`) : l'altitude du pixel vient de la couche `E` (pas de 20 m) quand le jeu la publie et que la palette porte `elev_encoding`, sinon de la couche `A`, que `TileStore` convertit en tranches (`fineIndices`).
- Scoring recalculé localement par le paquet `ChampisScoring`, validé par les vecteurs `shared/vectors/` (tolérance 1e-6, `Double` partout). `scripts/sync-vectors.sh` est la seule façon de les mettre à jour.
- Icônes alternatives : une par aquarelle d'espèce du référentiel, écrites par `uv run scripts/sync-icons.py ../champis` (jamais à la main) ; la liste vit dans `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` et l'Info.plist compilé, pas dans le code. Leurs aperçus `IconPreview-<espèce>` servent aussi de vignette au sélecteur d'espèce de la carte.
- Symboles des familles du sélecteur d'espèce : un SF Symbol maison par groupe du référentiel (`Group-<groupe>.symbolset`), écrit par `uv run scripts/group-symbols.py ../champis` (jamais à la main) ; `GroupSymbol` ne nomme aucun groupe, un groupe sans symbole s'affiche sans icône.
- Tuiles PMTiles lues par un lecteur maison (requêtes Range, cache disque pour le hors ligne). Les PNG de données se décodent octet par octet, jamais via `UIImage` ou `CGImage` : la gestion des couleurs décale les gris et change la classe d'un pixel.
- Observations et favoris : saisis dans l'app seulement, privés, identifiant généré par l'app dans le trousseau iCloud, envoyé en en-tête. Pas de photo, pas de rafraîchissement en arrière-plan : les notifications « mes coins » sont calculées et envoyées par le backend.
- Décisions du 13 nov. 2026 (audit avant ouverture du code) : l'identifiant, les observations et les coins ne partent que vers `api.champis.app` en https (`ChampisAPI.isOfficial`), toute autre adresse réglée met l'app en lecture seule ; `PUT /coins` ne part qu'après lecture de `GET /coins` et fusion (`CoinMerge`) ; un identifiant n'est créé que si le trousseau dit qu'il manque, jamais écrasé ; `coins.json` et `observations.json` en protection complète ; `dept` et `name` du manifeste contrôlés avant de servir de chemin (`SafePath`) ; un fichier PMTiles ou PNG malformé lève une erreur, jamais un arrêt (pas de `Int(…)` sur une taille lue dans un fichier) ; les photos des fiches viennent du site, jamais d'un tiers.

## Outillage

- Jamais de commit poussé sur `main` sans PR : branche, PR, Xcode Cloud vert, fusion (règle du 30 oct. 2026).
- Les issues GitHub sont la source de vérité de ce qui reste à faire (décision du 17 nov. 2026, skill `roadmap`) : lire les issues ouvertes de ce dépôt, et celles de `adhumi/champis` pour les sujets transverses, avant de commencer une tâche ; tout ce qui est remis à plus tard, découvert en chemin ou laissé hors périmètre devient une issue, jamais un « reste à faire » dans un message, un README ou un commentaire ; une PR cite son issue (`Closes #N`). Jamais de faille non corrigée, de secret ni de coût dans une issue : elles seront publiques.
- Tests : Swift Testing (`@Test`, `#expect`), jamais XCTest. Schéma `Champis` partagé, utilisé par Xcode Cloud.
- `cd Packages/ChampisScoring && swift test` pour le paquet seul.
- Documentation : `README.md` (installer, lancer, compiler sans le compte de l'auteur, tester), `docs/conception.md` (ce que fait chaque partie de l'app et les décisions datées, déplacé du README le 15 nov. 2026), `docs/app-store.md` ; `SECURITY.md` et `CONTRIBUTING.md` pour les tiers.
- Ne pas versionner `xcuserdata/`, `DerivedData/`, `.build/`.
