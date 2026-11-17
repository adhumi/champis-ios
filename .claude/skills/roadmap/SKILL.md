---
name: roadmap
description: Les issues GitHub sont la source de vérité de ce qui reste à faire sur Champis (roadmap, tâches en cours, tâches gardées pour plus tard). Dit quand les lire, quand en ouvrir une, dans quel dépôt, avec quel gabarit, et ce qui ne doit jamais y figurer. À lire avant de commencer une tâche et avant de la déclarer finie.
---

# Roadmap : les issues GitHub

Depuis le 17 nov. 2026 (décision d'Adrien), ce qui reste à faire sur Champis vit dans les issues GitHub des quatre dépôts, et nulle part ailleurs. La spec dit ce qui est **décidé** (skill `spec-sync`) ; les issues disent ce qui **reste à faire**. Un « reste à faire » écrit dans un message, un README, une description de PR ou un commentaire de code n'existe pas : il se perd à la fin de la session.

## En lecture : avant de commencer

- Lire les issues ouvertes du dépôt concerné, et celles de `adhumi/champis` pour les sujets transverses. Chercher celle qui couvre la tâche demandée avant d'en ouvrir une.
- Si la tâche a son issue : la lire en entier (critère de fin, dépendances, décisions déjà prises en commentaire) et travailler dessus.
- Si la demande contredit une issue ou en dépend, le dire à Adrien avant de coder.
- Une issue marquée `waiting-for-decision` attend une décision : ne pas trancher à la place d'Adrien.

## En écriture : pendant et à la fin

Ouvrir une issue dès qu'une chose est remise à plus tard :

- un travail laissé hors du périmètre de la tâche en cours ;
- un défaut ou une dette découverts en chemin et non corrigés ;
- une décision qui attend Adrien et bloque une suite ;
- une vérification qui n'a pas pu être faite (essai sur appareil, contrôle en production) ;
- une suite annoncée (« PR suivante », « à faire après le déploiement »).

Chercher d'abord un doublon ; s'il existe, le compléter par un commentaire plutôt que d'en ouvrir une seconde.

À la fin d'une tâche :

- la PR cite son issue (`Closes #N` pour la fermer à la fusion, `Refs #N` si elle n'en fait qu'une partie ; d'un dépôt à l'autre, `adhumi/champis-api#N` ne ferme rien : fermer à la main après fusion) ;
- les issues touchées sont à jour : ce qui est fait est coché ou fermé, ce qui reste est écrit ;
- le compte rendu à Adrien cite les numéros des issues ouvertes, mises à jour ou fermées.

Ne pas fermer une issue dont le critère de fin n'est pas rempli, même si la PR est fusionnée.

## Dans quel dépôt

| Sujet | Dépôt |
| --- | --- |
| Pipeline, API, backoffice, crons, déploiement de l'API | `adhumi/champis-api` |
| Site | `adhumi/champis-web` |
| App iOS, iPadOS, macOS | `adhumi/champis-ios` |
| Espèces, palette, textes du Guide, vecteurs, spec | `adhumi/champis` |
| Sujet qui touche plusieurs dépôts, roadmap produit, ouverture du code | `adhumi/champis`, avec une issue par dépôt pour le travail lui-même, liée depuis l'issue transverse |

## Gabarit

Titre : ce qui sera vrai quand ce sera fait, pas l'outil (« L'app envoie son jeton APNs » plutôt que « Notifications »).

```
## Contexte
Pourquoi, et d'où vient la demande (décision de la spec et sa date, PR, audit).

## À faire
- [ ] …

## Fini quand
Le critère vérifiable.

## Dépend de
Issues, décisions d'Adrien, accès ou essais nécessaires (appareil, compte développeur, Railway).
```

Une issue par résultat : pas de liste fourre-tout. Écrire en français, comme le reste du projet.

## Étiquettes

Peu, et les mêmes dans les quatre dépôts :

- `later` : gardé au chaud, pas prévu maintenant ;
- `waiting-for-decision` : une décision est nécessaire avant d'avancer ;
- `open-source` : à faire avant ou le jour de l'ouverture du code ;
- `on-device` : demande un essai sur un vrai appareil.

Une issue sans `later` est à faire. Pas d'étiquette de priorité : l'ordre se lit dans la spec (plan de réalisation) et dans les jalons si Adrien en crée.

## Ce qui ne va jamais dans une issue

Les dépôts seront publics, avec leurs issues.

- **Une faille de sécurité non corrigée**, ou assez de détail pour en retrouver une : la dire à Adrien directement (`SECURITY.md` donne l'adresse pour les tiers). Une fois corrigée et déployée, une issue peut en garder la trace sans la recette.
- Secrets, clés, jetons, adresses internes, identifiants de projet.
- Coûts, facturation, statut fiscal, informations personnelles d'Adrien ou de ses proches.
- Jugements sur des tiers nommés.

En cas de doute, demander à Adrien avant de publier.

## Ce qui n'a pas besoin d'une issue

Une correction faite dans la PR en cours, un détail d'implémentation, une question posée et tranchée dans la conversation.
