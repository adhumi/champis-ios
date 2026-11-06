# Fiche App Store et confidentialité de l'app

Étape C, lot C5 (spec › Produit › Étape C, 6 nov. 2026). Ce fichier est la source des champs à
recopier dans App Store Connect ; le manifeste `Champis/PrivacyInfo.xcprivacy` et l'article
« Confidentialité » du Guide disent la même chose que les étiquettes plus bas. Un changement de
collecte se fait aux trois endroits à la fois.

## Fiche (français, France)

| Champ | Valeur | Limite |
| --- | --- | --- |
| Nom | Champis | 30 |
| Sous-titre | La météo des champignons | 30 (24 utilisés) |
| Texte promotionnel | Où et quand poussent cèpes et girolles, forêt par forêt, jour par jour. Gratuit, sans compte, sans publicité. | 170 (109 utilisés) |
| Mots-clés | `champignons,cèpes,girolles,cueillette,forêt,mycologie,météo,lactaires,trompettes,pied de mouton` | 100 (95 utilisés) |
| URL d'assistance | https://champis.app/web/comprendre.html?article=mentions-legales (en attendant l'adresse de contact) | |
| URL marketing | https://champis.app | |
| URL de la politique de confidentialité | https://champis.app/web/comprendre.html?article=confidentialite | |
| Catégorie principale | Météo | |
| Catégorie secondaire | Style de vie (comme `LSApplicationCategoryType`) | |
| Prix | Gratuit ; le soutien facultatif viendra par achat intégré (lot C6) | |
| Disponibilité | France seulement : les données ne couvrent que la France | |
| Classification | 4+ (aucun contenu à signaler) | |
| Chiffrement | HTTPS seulement : `ITSAppUsesNonExemptEncryption = NO` déjà dans le projet | |

### Description

> La météo des champignons, forêt par forêt.
>
> Champis estime, pour chaque carré de forêt de 25 mètres et chaque jour, si les conditions sont réunies pour que poussent cèpes, girolles et les autres espèces de la carte : le terrain (essences, sol, altitude, exposition), la météo des dernières semaines et la saison de l'espèce. Le résultat se lit en cinq mots, d'excellent à très faible.
>
> OÙ — La carte colore la forêt selon les conditions du jour. Touchez un endroit : sa fiche dit pourquoi, en phrases (« grosse pluie il y a 8 jours : en plein dans le délai de pousse »), montre ses onze jours, la tendance et le meilleur jour à venir, et si la forêt est publique ou privée.
>
> QUAND — Ajoutez vos coins : ils sont classés du meilleur au moins bon, avec leur tendance et leurs phrases du jour, et un itinéraire vers Plans.
>
> EN FORÊT — Hors ligne, embarquez un département entier, carte et météo comprises. Notez ce que vous trouvez, ou ne trouvez pas, en deux gestes, à l'endroit où vous êtes.
>
> POURQUOI — Le Guide explique le modèle, ses sources publiques (IGN, Open-Meteo, SoilGrids, Copernicus) et les règles de chaque espèce, chacune appuyée sur une publication citée.
>
> Gratuit, sans compte, sans publicité. Vos coins et vos observations restent privés, liés à un identifiant tiré au hasard, effaçables d'un geste.
>
> Champis indique un potentiel, pas une autorisation : en forêt privée, il faut l'accord du propriétaire. Ne consommez jamais un champignon sans identification certaine.

Avant de publier : vérifier que chaque phrase est vraie dans la version envoyée (notifications « mes coins » actives, espèces publiées sur la carte, hors ligne).

## Captures à produire

iPhone 6,9 pouces et iPad 13 pouces, mode clair, un secteur du Jura en pleine saison :

1. La carte avec la légende, un secteur bon ou excellent à l'écran.
2. La fiche d'un point : libellé, phrases, onze jours, tendance, statut de la forêt.
3. Mes coins : trois coins classés, tendances en mots.
4. La fiche d'un coin : phrases du jour, onze jours, Itinéraire.
5. « Noter » : la feuille trouvé / rien trouvé à ma position.
6. Le Guide : une fiche d'espèce avec ses sources.

## Confidentialité de l'app (étiquettes App Store)

Réponses du questionnaire « Confidentialité de l'app », alignées sur `PrivacyInfo.xcprivacy` :

| Donnée | Collectée | Liée à l'utilisateur | Suivi | Finalités |
| --- | --- | --- | --- | --- |
| Localisation précise (position d'un coin ou d'une observation) | oui | oui (identifiant pseudonyme) | non | Fonctionnalités de l'app ; Analyse (les observations vérifient le modèle) |
| Identifiant utilisateur (code tiré au hasard par l'app, trousseau iCloud) | oui | oui | non | Fonctionnalités de l'app |
| Autre contenu de l'utilisateur (nom d'un coin, observation : espèce, date, quantité) | oui | oui | non | Fonctionnalités de l'app ; Analyse |

Non collectés : coordonnées, contacts, santé, finances, historique de navigation ou de recherche, achats (jusqu'au lot C6), données d'usage ou de diagnostic, identifiant publicitaire. Aucun SDK tiers. La position n'est lue que quand l'utilisateur le demande ; aucun trajet.

API à raison déclarée (`NSPrivacyAccessedAPITypes`) : `UserDefaults` (`CA92.1`, préférences et identifiant de repli de l'app) ; métadonnées de fichiers (`C617.1`, taille des fichiers téléchargés pour le hors ligne, dans le conteneur de l'app).

## Notes pour la revue

- Pas de compte, pas de connexion : tout est accessible dès l'ouverture.
- La carte couvre la France seulement ; pour une vue parlante, ouvrir la carte sur le Jura (Mouthe, Doubs).
- La localisation est demandée quand l'utilisateur veut se centrer sur sa position ou noter une observation à l'endroit où il est, jamais au lancement.
- Les notifications « mes coins » sont calculées et envoyées par le serveur ; l'app ne fait aucun travail en arrière-plan.
- Le statut public ou privé d'une forêt vient du service public de l'IGN (data.geopf.fr).
