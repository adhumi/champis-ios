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

Un identifiant aléatoire généré au premier lancement, stocké dans le trousseau avec synchronisation iCloud (`kSecAttrSynchronizable`) pour survivre à un changement d'appareil, envoyé en en-tête de chaque appel qui touche les observations ou les coins. Le nom de l'en-tête est un contrat d'API : il se fixe dans la spec › Backend avec `POST /observations`, pas dans le code. Aucun compte, aucun mail, pas de Sign in with Apple.

Limite assumée : qui perd son trousseau perd ses épingles et ses coins ; le serveur garde des lignes anonymes pour la calibration.

## Synchronisation

- File locale persistante : toute observation est d'abord écrite sur l'appareil (la sortie se passe sans réseau), puis envoyée par lots à `POST /observations` dès que le réseau revient. Réessai avec recul exponentiel, envoi idempotent par `id`.
- Le choix du stockage local (SwiftData ou autre) est une décision structurante : à poser dans la spec avant de coder.
- `DELETE /observations` efface toutes les lignes de l'identifiant : bouton « supprimer toutes mes observations » dans les réglages, avec confirmation, puis purge locale. C'est l'exercice du droit RGPD ; la politique de confidentialité le mentionne.
- Les observations de la personne s'affichent en épingles sur sa carte (positives et négatives distinguées). Celles des autres n'existent pas côté client.

## Mes coins

- Un coin = nom, position, espèce ou groupe. Privé, stocké localement et synchronisé **en liste complète** par `PUT /coins` avec le jeton APNs de l'appareil : le serveur remplace tout, pas de fusion.
- Les notifications sont **calculées et envoyées par le backend** après la pré-chauffe du matin : une seule notification par appareil, récapitulative, envoyée seulement si au moins un coin est bon ou excellent (score ≥ 0,55, seuils de la palette). L'app ne fait **aucun rafraîchissement en arrière-plan** et ne pose aucune notification locale.
- Côté app : demander l'autorisation de notification au moment où l'utilisateur crée son premier coin (pas au lancement), renvoyer `PUT /coins` à chaque changement de liste ou de jeton, afficher pour chaque coin le score du jour et des jours à venir à partir de `/weather`.
- Toucher la notification ouvre la liste des coins, chacun avec son score du jour, puis la carte centrée sur le coin choisi.

## Vie privée

Position et date d'une personne sont des données personnelles. Rappels : jamais de partage entre utilisateurs, jamais d'affichage agrégé sur la carte, suppression complète depuis l'app, pas de collecte en arrière-plan, pas de trajets. L'avertissement sur le cadre légal de la cueillette (forêt privée, arrêtés préfectoraux) accompagne la carte, pas le retour terrain.

## Tests

Swift Testing. File locale : enregistrement hors ligne, envoi par lots au retour du réseau (via `URLProtocol` de test), idempotence sur renvoi, purge après `DELETE`. Coins : `PUT` en liste complète à chaque changement, jeton APNs mis à jour, aucune tâche d'arrière-plan planifiée (vérifiable : aucun identifiant `BGTaskScheduler` dans l'app). Interface : « rien trouvé » accessible en un geste, libellés VoiceOver (skill `ios-accessibility`).
