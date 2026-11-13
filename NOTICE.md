# Licences de ce dépôt

Le code de l'app (`Champis/`, `ChampisTests/`, `Packages/`, `scripts/`) est sous licence MIT :
voir `LICENSE`.

Ce qui suit n'est pas du code de ce dépôt et garde sa propre licence.

| Fichiers | Origine | Licence |
| --- | --- | --- |
| `Champis/Resources/Texts/`, `Packages/ChampisScoring/Tests/ChampisScoringTests/Resources/` (espèces, palette, vecteurs) | Copies du référentiel `adhumi/champis`, mises à jour par `scripts/sync-*.sh` | CC BY 4.0 (« Champis, champis.app ») : `LICENSE-DATA.md` du référentiel |
| `Champis/Assets.xcassets/Icon-*`, `IconPreview-*` | Dérivées des aquarelles du référentiel (`shared/illustrations/`), images générées avec Gemini par Adrien Humilière ; écrites par `scripts/sync-icons.py` | CC BY 4.0, dans la mesure où un droit existe sur une image générée |
| `.claude/skills/swiftui-pro`, `swift-concurrency-pro`, `swift-testing-pro`, `ios-accessibility`, `background-execution` | Skills communautaires copiés ; auteurs, sources et commits dans `.claude/skills/SOURCES.md` | MIT, fichier `LICENSE` de chaque dossier |
| `.claude/skills/champis-model`, `scoring-parity`, `spec-sync` | Copies du référentiel `adhumi/champis` | MIT |

Les photos des fiches d'espèces viennent de Wikimedia Commons ; chacune garde la licence de son
auteur, affichée sous la photo. Les données dont le modèle est tiré (IGN, Copernicus, SoilGrids,
Open-Meteo, GBIF) sont décrites dans l'article « Les données et leurs sources » de l'app.

Le nom « Champis » et l'icône de l'app (`Champis/AppIcon.icon`) identifient l'app publiée par
Adrien Humilière : une version modifiée et redistribuée doit porter un autre nom et une autre icône.
