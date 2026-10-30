# Champis — app Apple (SwiftUI)

Client iOS / iPadOS / macOS 26 de Champis. Le modèle, les règles d'espèces, la spec et les skills vivent dans le monorepo `adhumi/champis` (doc « Spec — Champis », skills `.claude/skills/*`) : lis `champis-model` et `scoring-parity` là-bas avant tout code qui calcule ou affiche un score. Toute décision structurante passe par la spec avant le code (`spec-sync`).

## Décisions qui s'appliquent ici

- iOS, iPadOS et macOS 26 minimum, Xcode 27.2, Swift 6.4, mode de langage Swift 6, isolation `MainActor` par défaut dans l'app. Pas de `#available`.
- MVVM avec `@Observable`. Un modèle par écran, les vues ne calculent rien.
- Projet au format `project.xcproj` (JSON). Dossiers synchronisés pour `Champis/` et `ChampisTests/` : ne pas éditer le projet pour ajouter un fichier.
- Aucune valeur d'espèce dans le code : tout vient de `/species`. Palette et seuils viennent de `shared/palette.json` via l'API.
- Scoring recalculé localement par le paquet `ChampisScoring`, validé par les vecteurs `shared/vectors/` (tolérance 1e-6, `Double` partout). `scripts/sync-vectors.sh` est la seule façon de les mettre à jour.
- Tuiles PMTiles lues par un lecteur maison (requêtes Range, cache disque pour le hors ligne). Les PNG de données se décodent octet par octet, jamais via `UIImage` ou `CGImage` : la gestion des couleurs décale les gris et change la classe d'un pixel.
- Observations et favoris : saisis dans l'app seulement, privés, identifiant généré par l'app dans le trousseau iCloud, envoyé en en-tête. Pas de photo, pas de rafraîchissement en arrière-plan : les notifications « mes coins » sont calculées et envoyées par le backend.

## Outillage

- Tests : Swift Testing (`@Test`, `#expect`), jamais XCTest. Schéma `Champis` partagé, utilisé par Xcode Cloud.
- `cd Packages/ChampisScoring && swift test` pour le paquet seul.
- Ne pas versionner `xcuserdata/`, `DerivedData/`, `.build/`.
