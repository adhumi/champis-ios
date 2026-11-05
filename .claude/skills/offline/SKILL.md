---
name: offline
description: Hors ligne dans l'app Champis - téléchargement par département des tuiles PMTiles (niveaux 10-15) et de la dernière météo, lecteur PMTiles maison avec cache disque, fraîcheur affichée, aucun hors ligne sur le web. À lire avant tout code qui télécharge, met en cache ou lit des tuiles ou des réponses météo sur disque.
---

# Hors ligne

Indispensable en forêt : pas de réseau, et c'est là qu'on consulte la carte. Décisions de la spec : hors ligne **dans l'app seulement** (le site ne fait que consulter en ligne), téléchargement **par département**, tuiles niveaux 10–15 plus la dernière réponse météo, position GPS sur la carte.

## Ce qu'on embarque pour un département

| Contenu | Taille approx. | Source |
| --- | --- | --- |
| Tuiles `T` des espèces choisies, niveaux 10–15 | de quelques dizaines à quelques centaines de Mo selon la forêt | PMTiles du bucket via `GET /tiles` |
| Depuis le 5 nov. 2026 : le `G` de chaque groupe touché par les espèces choisies (`kind: "G"` avec `dept`, un canal par espèce, `species` conservé dans `OfflineFile.channels`), et le `T` des seules espèces sans `G` (`DownloadableDepartment.files`) ; taille annoncée = somme des fichiers retenus | un `G` pèse moins que la somme de ses `T` | idem ; `TileStore.setLocalFiles` lit les `G` locaux avant les `T` locaux puis la source distante, un département téléchargé en `T` reste lisible |
| Couche `A` (classes d'altitude), niveaux 10–15 | idem, une fois | PMTiles `A-300m-…` |
| Météo : `GET /weather/bbox` sur l'emprise du département, 11 jours, toutes classes d'altitude | quelques centaines de Ko | API, à l'heure du téléchargement |
| `GET /species` (espèces, palette, seuils) | négligeable | API |
| Limites du département | négligeable | pour l'emprise et le département sous le centre (bandeau des jours) |

Point ouvert de la spec, **ne pas trancher seul** : les PMTiles publiés sont un seul fichier France par espèce, alors que l'app télécharge par département. Deux options : des fichiers par département publiés en plus par le pipeline, ou une extraction côté app de la sous-emprise depuis le fichier France (répertoire PMTiles + requêtes Range par plages de tuiles). Le code du lecteur doit fonctionner dans les deux cas : il lit un PMTiles local **ou** distant par la même interface.

## Lecteur PMTiles maison (`ChampisPMTiles`)

Décidé : écrit maison, sans dépendance, ~300 lignes. Il implémente la spec PMTiles v3 : en-tête 127 octets, répertoires racine et feuilles (compressés gzip), identifiant de tuile par courbe de Hilbert, données par plages `[offset, length)`.

- Une seule interface `TileSource` : `tile(z, x, y) async throws -> Data?`. Deux implémentations : `RemotePMTiles` (requêtes `Range` HTTP, cache disque des répertoires et des tuiles lues) et `LocalPMTiles` (fichier téléchargé, lecture par `FileHandle`).
- Les requêtes `Range` passent par l'API en mode proxy (`GET /tiles/{name}`, décision du 19 oct. 2026) ou par URL présignée selon le manifeste `/tiles` (`mode`). Le client ne choisit pas : il suit le manifeste. En ligne, `TileStore.chooseEntries` lit le jeu complet (entrée sans `dept`) de la version de scoring de l'app, jamais un jeu par département, qui ne contient que les tuiles de son département (bug du 4 nov. 2026 : « le dernier par nom » tombait sur le département 70, carte vide ailleurs).
- Cache disque : `Application Support/Champis/tiles/<nom du fichier>/<z>/<x>_<y>.png`, exclu de la sauvegarde iCloud (`isExcludedFromBackup`), clé = nom du fichier PMTiles (il contient déjà le hash des départements et la version du scoring). Changement de hash dans le manifeste = nouveau dossier, l'ancien est purgé. Écrit le 31 oct. 2026 : `DiskTileCache`, branché dans `TileStore` (lecture disque avant la source, écriture après ; une tuile absente est un fichier vide), taille et vidage dans les réglages. Les répertoires PMTiles (en-tête, racine, feuilles) restent en mémoire : deux requêtes au lancement.
- Les PNG sont décodés octet par octet, jamais via `UIImage` (skill `swiftui-mapkit`).

## Téléchargement

- `URLSession` en configuration **background** pour les gros fichiers (skill `background-execution`, référence `background-url-session.md`) : reprise après fermeture, progression visible, annulation. Pas d'autre travail en arrière-plan dans l'app.
- Un téléchargement est **atomique par département** : rien n'est marqué disponible tant que tuiles, couche `A`, météo et espèces ne sont pas tous écrits. Un manifeste local `offline.json` liste les départements, les espèces, les hashes et les dates.
- Déclenché par l'utilisateur, jamais automatiquement. Proposer le Wi-Fi pour les gros volumes.

## En forêt

- Sans réseau, la carte lit `LocalPMTiles` et la météo embarquée. La date de la météo embarquée est affichée en permanence (« météo du 12 oct. 7 h »), et le curseur de jour reste borné aux 11 jours qu'elle couvre.
- Le score se recalcule localement avec `ChampisScoring` ? Non : la météo embarquée contient déjà `M_eff` et `Φ` par jour et par classe d'altitude. Le portage Swift n'est nécessaire que si l'on veut changer de jour au-delà de J+7 ou recalculer avec des espèces modifiées ; ce n'est pas le cas en v1.
- Position GPS : `CoreLocation` en « pendant l'utilisation », affichée sur la carte, sans enregistrement de trajet. Les chemins viennent du fond Apple, qui garde un cache limité : prévenir que le fond peut manquer hors couverture.
- Jamais de valeur inventée : pixel sans météo embarquée = transparent, comme en ligne.

## Stockage et nettoyage

- Un écran « Hors ligne » liste les départements téléchargés avec taille, date de la météo, date des tuiles, et permet de rafraîchir la météo seule (petit) ou de supprimer.
- Quota : prévenir au-delà d'un seuil raisonnable ; ne jamais supprimer sans demander.

## Implémentation (31 oct. 2026)

- Tranché par Adrien le 31 oct. : fichiers par département publiés par le pipeline (`tiles --per-dept`, `publish --per-dept`, champ `dept` du manifeste), pas d'extraction côté app.
- `Champis/Offline` : `OfflineManifest` (`OfflineDepartment`, `OfflineFile`, `BBox.split`), `OfflineStore` (acteur : `offline.json`, dossier par département, `weather.json`, caches `/species` et `/tiles`), `DownloadManager` (`URLSessionDownloadDelegate` hors MainActor, `AsyncStream` d'événements ; configuration de fond `fr.adhumi.champis.offline`, éphémère en test), `OfflineModel` (`@Observable` : départements téléchargeables d'après le manifeste, téléchargement, météo par sous-emprises de 0,3° lue sur l'en-tête du PMTiles, rafraîchir la météo, supprimer), `OfflineView`. `TileStore.setLocalFiles` lit les fichiers embarqués avant la source distante ; `MapModel` bascule sur la météo embarquée quand l'API ne répond pas et démarre sur les caches sans réseau.
- Pas encore : reprise des téléchargements après relance de l'app (`handleEventsForBackgroundURLSession`) et quota d'alerte.

## Tests

Swift Testing, sans réseau : un PMTiles synthétique de quelques tuiles généré en fixture (en-tête, répertoire, données), lu par `LocalPMTiles` et par `RemotePMTiles` via un `URLProtocol` de test qui sert les `Range`. Vérifier l'identifiant de Hilbert sur des valeurs connues de la spec PMTiles, la lecture des répertoires feuilles, la purge au changement de hash, l'atomicité d'un téléchargement interrompu.
