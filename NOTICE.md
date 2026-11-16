# Licences de ce dépôt

Le code de l'app (`Champis/`, `ChampisTests/`, `Packages/`, `scripts/`) est sous licence MIT :
voir `LICENSE`.

Ce qui suit n'est pas du code de ce dépôt et garde sa propre licence.

| Fichiers | Origine | Licence |
| --- | --- | --- |
| `Champis/Resources/Texts/`, `Packages/ChampisScoring/Tests/ChampisScoringTests/Resources/` (espèces, palette, vecteurs) | Copies du référentiel `adhumi/champis`, mises à jour par `scripts/sync-*.sh` | CC BY 4.0 (« Champis, champis.app ») : `LICENSE-DATA.md` du référentiel |
| `Champis/Assets.xcassets/Icon-*`, `IconPreview-*` | Dérivées des aquarelles du référentiel (`shared/illustrations/`), images générées avec Gemini par Adrien Humilière ; écrites par `scripts/sync-icons.py` | CC BY 4.0 comme images, dans la mesure où un droit existe sur une image générée ; leur emploi comme icône d'app : voir « Nom et icônes » |
| `.claude/skills/swiftui-pro`, `swift-concurrency-pro`, `swift-testing-pro`, `ios-accessibility`, `background-execution` | Skills communautaires copiés ; auteurs, sources et commits dans `.claude/skills/SOURCES.md` | MIT, fichier `LICENSE` de chaque dossier |
| `.claude/skills/champis-model`, `scoring-parity`, `spec-sync` | Copies du référentiel `adhumi/champis` | MIT |

Les photos des fiches d'espèces ne sont pas dans ce dépôt : l'app les charge depuis le site
(`https://champis.app/shared/photos/<espèce>.jpg`), qui sert les copies du référentiel
(`shared/photos/`). Elles viennent à l'origine de Wikimedia Commons ; chacune garde la licence de
son auteur, affichée avec son crédit sous la photo. Les données dont le modèle est tiré (IGN, Copernicus, SoilGrids,
Open-Meteo, GBIF) sont décrites dans l'article « Les données et leurs sources » de l'app.

## Nom et icônes

Le nom « Champis » et les icônes de l'app, c'est-à-dire l'icône principale
(`Champis/Assets.xcassets/AppIcon.appiconset`) et les icônes alternatives
(`Champis/Assets.xcassets/Icon-*`), identifient l'app publiée par Adrien Humilière.

Une version modifiée de l'app qui est redistribuée doit porter un autre nom et une autre icône, qui
ne soit ni l'icône principale ni l'une des icônes alternatives.

Cette clause ne change rien aux licences. Le code reste sous licence MIT. Les aquarelles dont
dérivent les icônes alternatives restent sous CC BY 4.0 : elles se réutilisent comme images, en
citant Champis. La clause ne porte que sur leur emploi comme icône ou signe distinctif d'une app
redistribuée, qui relève de l'identité de l'app et non du droit d'auteur. « Champis » n'est pas une
marque déposée : il s'agit d'éviter qu'une autre app soit prise pour celle-ci.
