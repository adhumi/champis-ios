---
name: field-feedback
description: Retour terrain et « mes coins » dans l'app Champis - observations trouvé/rien trouvé (espèce, position, date, quantité, sans photo), identité par identifiant d'appareil, synchronisation vers POST/DELETE /observations, favoris synchronisés par PUT /coins pour les notifications calculées par le backend, vie privée stricte. À lire avant tout code qui enregistre, affiche ou envoie une observation ou un favori.
---

# Retour terrain et mes coins

Les observations servent à **calibrer le modèle** (phase 5) ; les coins servent à **savoir quand y aller** sans ouvrir la carte. Les deux sont saisis dans l'app seulement, jamais sur le web, et restent privés. Décisions du 30 oct. 2026 dans la spec (sections App iOS, Backend, Retour terrain).

## Observation

Un signalement technique, rien de plus :

| Champ | Valeur | Note |
| --- | --- | --- |
| `id` | UUID généré par l'app | idempotence de la synchronisation |
| `species` | identifiant d'espèce de `/species` | pas un nom libre ; si l'utilisateur voit un groupe, il choisit l'espèce dans le groupe ou « ne sait pas » (à poser dans la spec si on l'accepte) |
| `lat`, `lon` | position au moment de l'enregistrement, ou épingle déplacée à la main | garder la précision GPS en mètres |
| `date` | date civile locale, par défaut aujourd'hui, modifiable vers le passé | la sortie a pu être le matin |
| `found` | trouvé / rien trouvé | les **négatives** valent autant que les positives : le bouton « rien trouvé » est aussi accessible que « trouvé » |
| `quantity` | 1 à 3, seulement si trouvé | « quelques-uns », « un bon panier », « beaucoup » |
| `shared` | réservé, toujours faux | champ gardé par la décision du 16 oct., inactif |

Pas de photo, pas de commentaire libre, pas de nom de lieu : moins il y a de données personnelles, mieux c'est.

## Identité

Un identifiant aléatoire généré au premier lancement, stocké dans le trousseau avec synchronisation iCloud (`kSecAttrSynchronizable`) pour survivre à un changement d'appareil, envoyé en en-tête de chaque appel à l'API (obligatoire pour les observations et les coins ; sur les autres, le serveur n'en garde qu'une empreinte hachée par jour pour compter les appareils actifs, spec › Backoffice › Usage, 8 nov. 2026). Le nom de l'en-tête est un contrat d'API : il se fixe dans la spec › Backend avec `POST /observations`, pas dans le code. Aucun compte, aucun mail, pas de Sign in with Apple.

Limite assumée : qui perd son trousseau perd ses épingles et ses coins ; le serveur garde des lignes anonymes pour la calibration.

Règles du 13 nov. 2026 (`Identity.resolve`) : un identifiant n'est créé que si le trousseau dit qu'il n'en a pas (`errSecItemNotFound`) ; toute autre erreur remonte en clair avec « Réessayer », sans identifiant de rechange ; `SecItemAdd` seul, un identifiant présent n'est jamais écrasé. `UserDefaults` retient le dernier identifiant connu (il sert si le trousseau est en erreur, et y est remis s'il en a disparu) et ceux qu'un conflit iCloud a remplacés, que « tout supprimer » efface aussi du serveur. L'identifiant, les observations et les coins ne partent que vers l'API officielle `api.champis.app` en https : avec une autre adresse réglée, l'app est en lecture seule et rien de privé n'est envoyé (`ChampisAPI.isOfficial`, `Failure.readOnly`).

## Synchronisation

- File locale persistante : toute observation est d'abord écrite sur l'appareil (la sortie se passe sans réseau), puis envoyée par lots à `POST /observations` dès que le réseau revient. Réessai avec recul exponentiel, envoi idempotent par `id`.
- Le choix du stockage local (SwiftData ou autre) est une décision structurante : à poser dans la spec avant de coder.
- `DELETE /observations` efface toutes les lignes de l'identifiant : bouton « supprimer toutes mes observations » dans les réglages, avec confirmation, puis purge locale. C'est l'exercice du droit RGPD ; la politique de confidentialité le mentionne.
- Les observations de la personne s'affichent en épingles sur sa carte (positives et négatives distinguées). Celles des autres n'existent pas côté client.

## Mes coins

- Un coin = nom, position, espèce ou groupe. Privé, stocké localement et synchronisé **en liste complète** par `PUT /coins` avec le jeton APNs de l'appareil : le serveur remplace tout, pas de fusion.
- La fusion est donc dans l'app (décision du 13 nov. 2026, deux appareils s'effaçaient l'un l'autre) : au démarrage, dès qu'un identifiant existe, lire `GET /coins` et `GET /observations` et fusionner avec l'appareil **avant tout `PUT`** ; aucun `PUT` tant que cette première lecture n'a pas réussi (hors ligne, les changements restent sur l'appareil). `CoinMerge` (fonction pure, testée) : union par `id` à trois listes, l'appareil, le serveur et la base (la liste du serveur au dernier échange réussi, gardée dans `coins.json` avec l'identifiant pour lequel elle vaut). Sans horodatage dans le modèle : pour un même `id`, la version de l'appareil si elle a changé depuis la base, sinon celle du serveur ; un coin de la base absent de l'appareil y a été supprimé et n'est pas repris du serveur ; un coin de la base, inchangé ici et absent du serveur, a été supprimé ailleurs et part. Un `PUT` ne part que si la liste diffère de la base.
- Les notifications sont **calculées et envoyées par le backend** après la pré-chauffe du matin : une seule notification par appareil, récapitulative, envoyée seulement si au moins un coin est bon ou excellent (score ≥ 0,55, seuils de la palette). L'app ne fait **aucun rafraîchissement en arrière-plan** et ne pose aucune notification locale.
- Côté app : demander l'autorisation de notification au moment où l'utilisateur crée son premier coin (pas au lancement), renvoyer `PUT /coins` à chaque changement de liste ou de jeton, afficher pour chaque coin le score du jour et des jours à venir à partir de `/weather`.
- Toucher la notification ouvre la liste des coins, chacun avec son score du jour, puis la carte centrée sur le coin choisi.

## Vie privée

Position et date d'une personne sont des données personnelles. Rappels : jamais de partage entre utilisateurs, jamais d'affichage agrégé sur la carte, suppression complète depuis l'app, pas de collecte en arrière-plan, pas de trajets. L'avertissement sur le cadre légal de la cueillette (forêt privée, arrêtés préfectoraux) accompagne la carte, pas le retour terrain.

## Implémentation (31 oct. 2026)

- `Champis/Field` : `FieldModels` (formes exactes de l'API, clés `snake_case`), `Identity` (`KeychainIdentityStore` synchronisé iCloud, `DefaultsIdentityMemory` pour le dernier identifiant connu et ceux mis de côté, `MemoryIdentityStore` et `VolatileIdentityMemory` pour les tests), `LocalStore` (acteur, `observations.json` avec la file `pending` et `coins.json` avec la base de la fusion, écriture atomique en protection complète), `FieldModel` (`@Observable` : enregistrer, envoyer par lots de 200, reprendre du serveur, tout effacer, coins en liste complète, scores de `GET /coins`), `QuickFoundSheet` (« Trouvé ici »), `CoinsScreen`. `ChampisAPI+Field` porte l'en-tête `X-Champis-User` explicitement ; depuis le lot BO2 du backoffice (8 nov. 2026), `ChampisAPI.userID` l'ajoute aussi à toutes les autres requêtes à l'API (jamais au site), le serveur n'en gardant qu'une empreinte hachée par jour pour compter les appareils actifs.
- Entrées (9 nov. 2026) : seulement depuis la carte, au point touché : boutons de la fiche du point (« Trouvé ici », « Rien trouvé ici », l'étoile de la barre de la fiche, qui remplace la ligne « Ajouter à mes coins » depuis le 18 nov. 2026, avec la cible de la couche, la classe d'altitude et le T de chaque espèce du pixel), et le menu de l'appui long (les mêmes trois). Plus de menu « Retour terrain », de formulaire complet ni de « Noter » à ma position. Épingles : vertes trouvé, grises rien trouvé, orange coins.
- La permission de notification est demandée au premier coin ; l'enregistrement APNs (jeton dans `PUT /coins`) attend la capacité Push sur l'App ID.

## Tests

Swift Testing. File locale : enregistrement hors ligne, envoi par lots au retour du réseau (via `URLProtocol` de test), idempotence sur renvoi, purge après `DELETE`. Coins : `PUT` en liste complète à chaque changement, jeton APNs mis à jour, aucune tâche d'arrière-plan planifiée (vérifiable : aucun identifiant `BGTaskScheduler` dans l'app). Interface : « rien trouvé » accessible en un geste, libellés VoiceOver (skill `ios-accessibility`).

## Écran Mes coins (refonte UX, lot 1, 1er nov. 2026)

Onglet à part entière, première réponse de l'app (« j'y vais ce week-end ou pas ? »). Règles : des mots avant des chiffres (libellé de la palette via `MapModel.classify`, jamais un nombre hors de « Détails ») ; classement du meilleur au moins bon, sans météo en dernier (`CoinTrend.order`) ; tendance calculée sur les onze jours de `GET /coins` › `days` avec le seuil « bon » de la palette (`MapModel.goodThreshold`), jamais un seuil écrit dans le code ; dates en français sans dépendre de la locale (`CoinTrend.weekdayName`). Une notification porte `coin_id` : `AppDelegate` le lit, `AppRouter.open(coinID:)` bascule l'onglet et `CoinsScreen` pousse la fiche. L'état vide est le seul endroit où la promesse de confidentialité est écrite en entier.

## Deux tapes en forêt (refonte UX, lot 3, 1er nov. 2026)

Marc, gants boueux, doit noter en deux gestes. Appui long sur la carte → menu au point pressé. « Rien trouvé ici » : `FieldModel.recordNotFound(species:latitude:longitude:)` écrit une observation négative par espèce du calque (`MapModel.layerSpecies` ; un groupe = toutes ses espèces), la garde dans `undoable` pendant `undoWindow` (5 s) sans l'envoyer, puis `sync()` ; `undoNotFound()` la retire (`LocalStore.remove`). Le message « Noté : rien trouvé » avec Annuler est affiché par `MapScreen` tant que `undoable` n'est pas vide, et annoncé à VoiceOver. « Trouvé ici » : `QuickFoundSheet`, espèce du calque préremplie et modifiable, position du point, date du jour, trois boutons de quantité ; toucher enregistre et ferme. Après `MapModel.addCoin`, si le département du coin n'est pas embarqué et que le manifeste publie son jeu, une alerte propose de l'embarquer (toutes les espèces) ; le refus est mémorisé par département (`offlineDeclinedDepartments`) et jamais redemandé. Règle inchangée : rien n'est envoyé qui n'ait d'abord été écrit sur l'appareil.

Étape B4 (6 nov. 2026) : un bouton flottant « Noter » ouvrait `NoteSheet` à ma position ; il est retiré le 9 nov. 2026 avec `MapModel.currentFix` et `LocationProvider` (`recordNotFound(…, accuracyM:)` garde son paramètre, `nil` pour un point touché). Les échecs d'envoi se disent en clair (`FieldModel.problem`, `Problem`) avec « Réessayer » (`FieldModel.retry`) ; `status` ne porte plus que les confirmations.

## Un coin est générique (18 nov. 2026)

Un coin est générique (18 nov. 2026, spec › App iOS) : un nouveau coin garde le terrain de toutes les espèces de l'endroit (`MapModel.coinParameters`, `PointInfo.terrains`), et `MapModel.completeCoins` complète une fois les coins plus anciens à l'ouverture de Mes coins (tuiles relues, `FieldModel.setCoinTerrains`, `PUT /coins` ; identifiants faits dans `UserDefaults` › `coinsWithAllTerrains.v2` ; dans une tâche du modèle, `completeCoinsInBackground`, et seulement après une lecture complète, `PointInfo.terrainsComplete`). La liste n'a plus d'en-tête de date ni de tendance : chaque ligne (`CoinRowView`) montre une miniature de carte (`CoinThumbnail`, `MKMapSnapshotter`, fond Plans standard) et une ligne par espèce notée au moins « moyen » (`GET /coins` › `species`, `CoinTrend.worthSpecies`), sinon la pastille et le libellé du coin sans nom d'espèce.
