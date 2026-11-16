# Signaler une faille de sécurité

Champis est un projet personnel, tenu par une seule personne sur son temps libre. Un signalement est toujours le bienvenu.

## Comment signaler

Par courriel à **hello@champis.app**. Pas d'issue publique ni de pull request pour une faille : elles la rendraient visible avant sa correction.

À joindre, autant que possible :

- ce qui est touché : un écran, un fichier du dépôt, un des deux paquets (`ChampisPMTiles`, `ChampisScoring`), avec le commit ou la version de l'app ;
- l'appareil et la version du système ;
- les étapes pour reproduire, ou le fichier qui déclenche le problème (une tuile, un PMTiles, une réponse d'API) ;
- ce qu'un attaquant obtiendrait : lecture ou envoi de données privées, arrêt de l'app, écriture hors de son dossier ;
- le nom à citer dans le correctif, si vous souhaitez être crédité.

## À quoi s'attendre

- Un accusé de réception sous quelques jours.
- Un correctif dès que possible, selon la gravité et le temps disponible. Aucun délai n'est garanti, et une version de l'app passe par la revue d'Apple.
- Pas de prime.
- Merci d'attendre le correctif avant d'en parler publiquement.

## Périmètre

- Le code de ce dépôt : l'app (`Champis/`), ses paquets (`Packages/`) et ses scripts.
- L'app Champis construite à partir de ce dépôt, sur iOS, iPadOS et macOS.

L'API `api.champis.app` relève de `adhumi/champis-api`, le site `champis.app` de `adhumi/champis-web`, les fichiers d'espèces et les textes de `adhumi/champis`. La même adresse reçoit les signalements pour les quatre dépôts.

Seule la branche `main` reçoit des correctifs.

## Ce qui n'est pas une faille

Ces points sont des choix du modèle, décrits dans `CLAUDE.md` et `docs/conception.md` :

- **L'identifiant d'appareil vaut mot de passe.** Il n'y a pas de compte : l'app tire un identifiant au hasard, le garde dans le trousseau iCloud et l'envoie à l'API dans l'en-tête `X-Champis-User`. Qui a accès au trousseau de l'utilisateur a accès à ses observations et à ses coins. Que l'app envoie cet identifiant ailleurs qu'à `api.champis.app` en https serait en revanche une faille.
- **L'adresse de l'API se règle dans l'app.** Avec une adresse qui n'est pas l'API officielle, l'app passe en lecture seule et le dit ; elle affiche alors ce que ce serveur lui répond.
- **L'app lit des services publics nommés** : l'API, le site (photos des fiches, limites des départements) et la Géoplateforme de l'IGN (statut de la forêt). L'article « Confidentialité » de l'app le dit.
- Un fichier PMTiles ou PNG malformé lève une erreur affichée : c'est le comportement voulu. Qu'il arrête l'app serait un bug à signaler.

## Ce qu'il ne faut pas faire

- Ne testez pas la production en charge : pas d'outil de balayage à haut débit contre `api.champis.app` ou `champis.app`, pas d'essai de déni de service. Le service tourne sur une petite infrastructure financée par des dons. L'app peut être pointée vers une API locale (`README.md` › Installer et lancer en local).
- Ne touchez pas aux données d'autrui : n'utilisez que l'identifiant de votre propre installation. Si vous tombez sur des données qui ne sont pas les vôtres, arrêtez-vous et écrivez.
