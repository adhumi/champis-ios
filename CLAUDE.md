# Champis — app Apple (SwiftUI)

Client iOS / iPadOS / macOS 26 de Champis. Le modèle, les règles d'espèces et la spec vivent dans le monorepo `adhumi/champis` (doc « Spec — Champis »). Les skills sont dans `.claude/skills/` (provenance dans `SOURCES.md`) :

- `champis-model`, `scoring-parity`, `spec-sync` : copies du monorepo, synchronisées par `scripts/sync-skills.sh`, à ne pas modifier ici. Lis `champis-model` et `scoring-parity` avant tout code qui calcule ou affiche un score. Toute décision structurante passe par la spec avant le code (`spec-sync`).
- `swiftui-mapkit`, `offline`, `field-feedback` : skills maison de la phase 4, à lire avant de toucher la carte, le hors ligne, les observations ou les coins.
- `swiftui-pro`, `swift-concurrency-pro`, `swift-testing-pro`, `ios-accessibility`, `background-execution` : skills communautaires copiés en dossier (MIT), à appliquer à toute revue ou écriture de code Swift.

## Décisions qui s'appliquent ici

- iOS, iPadOS et macOS 26 minimum, mode de langage Swift 6, isolation `MainActor` par défaut dans l'app. Pas de `#available`.
- MVVM avec `@Observable`. Un modèle par écran, les vues ne calculent rien.
- Projet `project.pbxproj` créé par Xcode (le `.xcproj` généré hors d'Xcode ne s'ouvrait pas). Dossiers synchronisés pour `Champis/` et `ChampisTests/` : ne pas éditer le projet pour ajouter un fichier ; le paquet local est `Packages/ChampisScoring`.
- Aucune valeur d'espèce dans le code : tout vient de `/species`. Palette et seuils viennent de `shared/palette.json` via l'API.
- Scoring recalculé localement par le paquet `ChampisScoring`, validé par les vecteurs `shared/vectors/` (tolérance 1e-6, `Double` partout). `scripts/sync-vectors.sh` est la seule façon de les mettre à jour.
- Tuiles PMTiles lues par un lecteur maison (requêtes Range, cache disque pour le hors ligne). Les PNG de données se décodent octet par octet, jamais via `UIImage` ou `CGImage` : la gestion des couleurs décale les gris et change la classe d'un pixel.
- Observations et favoris : saisis dans l'app seulement, privés, identifiant généré par l'app dans le trousseau iCloud, envoyé en en-tête. Pas de photo, pas de rafraîchissement en arrière-plan : les notifications « mes coins » sont calculées et envoyées par le backend.

## Outillage

- Jamais de commit poussé sur `main` sans PR : branche, PR, Xcode Cloud vert, fusion (règle du 30 oct. 2026).
- Tests : Swift Testing (`@Test`, `#expect`), jamais XCTest. Schéma `Champis` partagé, utilisé par Xcode Cloud.
- `cd Packages/ChampisScoring && swift test` pour le paquet seul.
- Ne pas versionner `xcuserdata/`, `DerivedData/`, `.build/`.
