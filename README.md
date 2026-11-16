# Champis — app Apple

Champis estime où et quand cueillir des champignons en France, à l'échelle de la parcelle forestière : [champis.app](https://champis.app). Ce dépôt est l'app SwiftUI pour iOS, iPadOS et macOS 26 : carte à 25 m, score du jour, hors ligne en forêt, retour terrain et « mes coins ».

Il fait partie de quatre dépôts :

| Dépôt | Contenu |
| --- | --- |
| `adhumi/champis` | le référentiel (espèces, palette, vecteurs de parité, textes du Guide), copié ici par les scripts `scripts/sync-*` |
| `adhumi/champis-api` | pipeline terrain et API météo, sur `api.champis.app` |
| `adhumi/champis-web` | le site `champis.app` |
| `adhumi/champis-ios` (ce dépôt) | l'app iOS, iPadOS et macOS |

## Prérequis

- Un Mac avec Xcode 26.3 ou plus récent.
- Cibles : iOS, iPadOS et macOS 26, mode de langage Swift 6.
- Aucune dépendance à télécharger : les deux paquets Swift sont locaux (`Packages/`), sans dépendance distante.
- Pour les scripts de synchronisation seulement : un clone du référentiel `adhumi/champis` à côté de ce dépôt (`../champis`), et [uv](https://docs.astral.sh/uv/) pour `scripts/sync-icons.py`.

## Installer et lancer en local

```sh
git clone https://github.com/adhumi/champis-ios
open champis-ios/Champis.xcodeproj
```

Dans Xcode : schéma `Champis`, un simulateur iOS 26, puis ⌘R. Le simulateur suffit pour lancer l'app et la parcourir.

L'app compilée appelle par défaut l'API officielle, `https://api.champis.app`, et le site `https://champis.app` pour les photos des fiches et les limites des départements. Les observations et les coins que vous y saisissez sont donc réellement enregistrés, sous un identifiant propre à votre build ; « Supprimer mes observations et mes coins », dans les réglages, les efface.

Pour une autre API : cinq tapes sur la version, dans Réglages › À propos, révèlent l'adresse de l'API. Une adresse `https` quelconque est acceptée ; en build de développement (`DEBUG`), `http://localhost:8000` aussi, pour l'API lancée par `make serve` dans `adhumi/champis-api`. Avec une adresse qui n'est pas l'API officielle, l'app est en lecture seule : ni identifiant, ni observation, ni coin n'y sont envoyés, et un bandeau le dit.

### Compiler sans le compte de l'auteur

L'équipe de signature (`DEVELOPMENT_TEAM`) et les identifiants de bundle (`fr.adhumi.champis`, et `fr.adhumi.champis.tests` pour les tests) sont écrits en dur dans `Champis.xcodeproj/project.pbxproj`, avec une signature automatique. Ce sont ceux de l'auteur ; un tiers ne peut pas signer avec.

- **Simulateur.** Un build pour le simulateur ne demande pas de profil de signature : en principe, rien à changer. Si Xcode réclame tout de même une équipe, faites le changement ci-dessous.
- **Appareil.** Dans Xcode, cible `Champis` puis `ChampisTests`, onglet Signing & Capabilities : choisissez votre équipe et remplacez l'identifiant de bundle par un identifiant à vous. Ne proposez pas ce changement dans une pull request.
- **Identifiant et trousseau iCloud.** L'app garde son identifiant dans le trousseau, comme élément synchronisé par iCloud. Une app signée par votre équipe a son propre trousseau : son identifiant est distinct de celui de l'app de l'auteur, et sa synchronisation entre vos appareils passe par votre compte développeur et votre compte iCloud. Le projet ne contient aucun fichier d'entitlements.
- **Notifications « mes coins ».** Elles sont envoyées par le serveur, par APNs, à l'identifiant de bundle de l'auteur. L'app ne transmet pas encore de jeton d'appareil, et le projet ne déclare pas la capacité Push Notifications. Un build à votre identifiant de bundle ne recevra donc pas de notification de `api.champis.app` ; pour en envoyer il faudrait votre propre compte développeur, votre clé APNs et votre propre API.

Le reste de l'app (carte, fiches, hors ligne, Guide, observations, coins) fonctionne sans rien de tout cela.

## Tester

Dans Xcode, schéma `Champis` puis ⌘U : exécute `ChampisTests`, `ChampisScoringTests` et `ChampisPMTilesTests`. Les tests sont écrits avec Swift Testing et tournent sans réseau.

En ligne de commande, pour le paquet du scoring seul :

```sh
cd Packages/ChampisScoring && swift test
```

La CI est Xcode Cloud, sur le schéma partagé `Champis`. Il n'y a pas de workflow GitHub.

## Structure du dépôt

```
Champis.xcodeproj/          projet (project.pbxproj créé par Xcode), schéma partagé Champis
Champis/                    cible app : SwiftUI, MVVM @Observable, Assets, PrivacyInfo.xcprivacy
Champis/API/                client de l'API (/species, /tiles, /weather…, observations, coins) et ses modèles
Champis/Map/                carte : MapModel, overlay MKTileOverlay, TileStore, colorisation, fiche d'un point
Champis/Field/              retour terrain et mes coins : modèles, identité (trousseau), LocalStore JSON, fusion des coins
Champis/Offline/            hors ligne par département : manifeste offline.json, OfflineStore, DownloadManager, écran
Champis/Understand/         Guide (articles, fiches d'espèces), première ouverture, réglages
Champis/Navigation/         onglets, barre latérale iPad et Mac, routage d'une notification
Champis/Support/            icônes de l'app : une par aquarelle d'espèce, sélecteur des réglages (iOS, iPadOS)
Champis/Shared/             erreurs en clair (Problem), contrôle des chemins (SafePath)
Champis/Resources/Texts/    copie des articles du Guide du référentiel
ChampisTests/               tests de l'app (Swift Testing)
Packages/ChampisScoring/    paquet local : portage du scoring, vecteurs de parité en ressources de test
Packages/ChampisPMTiles/    paquet local : lecteur PMTiles (fichier ou Range HTTP) et décodeur PNG de données
scripts/sync-vectors.sh     copie shared/vectors/, les espèces et la palette du référentiel dans le paquet, note VECTORS_VERSION
scripts/sync-texts.sh       copie shared/texts/ du référentiel dans Champis/Resources/Texts/, note TEXTS_VERSION
scripts/sync-icons.py       icônes et aperçus tirés de shared/illustrations/ du référentiel, note ICONS_VERSION
scripts/sync-skills.sh      copie les skills partagés du référentiel dans .claude/skills/
docs/                       conception.md (conception et décisions datées), app-store.md (fiche App Store, confidentialité)
```

`Champis/` et `ChampisTests/` sont des dossiers synchronisés : ajouter un fichier sur disque suffit, le projet ne change pas.

Ce que fait chaque partie (scoring et parité, tuiles, carte, hors ligne, retour terrain, Guide, icônes) et les décisions datées qui l'expliquent : [`docs/conception.md`](docs/conception.md).

## Déployer

L'app se construit et se teste dans Xcode Cloud (`Champis.xcodeproj/xcshareddata/xcodecloud/manifest.json`), avec le compte développeur de l'auteur. La fiche App Store, les captures à produire et les étiquettes de confidentialité sont préparées dans [`docs/app-store.md`](docs/app-store.md) ; elles doivent rester alignées sur `Champis/PrivacyInfo.xcprivacy`.

Le dépôt ne contient aucun secret : ni clé, ni profil de signature.

Après un changement du référentiel, les copies se mettent à jour par les scripts, jamais à la main :

```sh
scripts/sync-vectors.sh ../champis      # vecteurs, espèces et palette des tests de parité
scripts/sync-texts.sh ../champis        # articles du Guide
uv run scripts/sync-icons.py ../champis # icônes alternatives et aperçus
```

## Contribuer, signaler une faille

- Contribuer : [`CONTRIBUTING.md`](CONTRIBUTING.md). Projet personnel : les pull requests sont bienvenues, relues quand l'auteur le peut.
- Signaler une faille : [`SECURITY.md`](SECURITY.md), par courriel à hello@champis.app, pas par une issue.

## Licences

- Code de ce dépôt : MIT ([`LICENSE`](LICENSE)).
- Copies du référentiel (textes, espèces, palette, vecteurs), icônes tirées des aquarelles et skills de tiers : chacun garde sa licence, voir [`NOTICE.md`](NOTICE.md).
- Nom et icônes : le nom « Champis », l'icône principale et les icônes alternatives identifient l'app publiée par l'auteur. Une version modifiée et redistribuée porte un autre nom et une autre icône, qui ne soit ni l'icône principale ni l'une des icônes alternatives ([`NOTICE.md`](NOTICE.md) › Nom et icônes).
- Données dont le modèle est tiré (IGN, Copernicus, SoilGrids, Open-Meteo, GBIF) : article « Les données et leurs sources » du Guide, dans le référentiel `adhumi/champis`.
