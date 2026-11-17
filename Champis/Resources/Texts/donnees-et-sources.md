# Les données et leurs sources

Toutes les données de Champis sont publiques et sous licence ouverte. Rien n'est acheté, rien n'est deviné.

## Forêts

**BD Forêt V2** de l'IGN : la nature du peuplement (essences dominantes, couvert) pour chaque parcelle boisée de France, en Licence Ouverte Etalab 2.0. Hors forêt, la **BD TOPO** de l'IGN (même licence) donne les peupleraies, les bosquets, les vergers et les haies ; le modèle sait la lire, mais aucune des espèces publiées ne s'en sert encore.

## Relief

**Copernicus DEM** (GLO-30), ramené à 25 mètres : altitude, pente et exposition de chaque carré. © DLR e.V. 2010-2014 et © Airbus Defence and Space GmbH 2014-2018, fourni sous licence COPERNICUS par l'Union européenne et l'ESA ; tous droits réservés.

## Sols

**SoilGrids** de l'ISRIC (licence CC BY 4.0) : acidité du sol (pH) à 250 mètres, lissée. Elle surestime souvent le pH des humus forestiers ; le modèle en tient compte.

## Météo

**Open-Meteo** (données météo d'Open-Meteo.com, licence CC BY 4.0) : températures, pluie, neige, évapotranspiration et humidité du sol des trois derniers mois et des sept prochains jours, pour chaque cellule de cinq kilomètres de forêt, actualisés chaque matin. La climatologie du sol vient d'**ERA5-Land** (service Copernicus sur le changement climatique, Climate Data Store) ; ce produit contient des informations Copernicus modifiées.

## Contrôle

**GBIF** : les observations publiques d'espèces servent à vérifier que les cartes de terrain sont crédibles (altitudes, mois de récolte, acidité). Elles ne sont ni affichées ni redistribuées : c'est un contrôle interne, sans usage commercial, certains jeux de GBIF étant sous licence CC BY-NC.

## Fraîcheur

La météo est recalculée chaque matin. Les cartes de terrain sont régénérées quand un fichier d'espèce change. La date de la météo s'affiche sur la carte ; hors ligne, c'est celle du dernier téléchargement.

## Le modèle lui-même

Les règles de chaque espèce (arbres hôtes, sol, altitude, saison, seuils de pluie et de température) sont écrites dans des fichiers lisibles, chaque valeur appuyée sur une publication citée. Ils seront publiés avec le code de Champis, ouvert avant la sortie des apps.
