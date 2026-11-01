# Les données et leurs sources

Toutes les données de Champis sont publiques et sous licence ouverte. Rien n'est acheté, rien n'est deviné.

## Forêts

**BD Forêt V2** de l'IGN : la nature du peuplement (essences dominantes, couvert) pour chaque parcelle boisée de France, en licence ouverte Etalab. Hors forêt, le repli est **Corine Land Cover 2018** (Agence européenne pour l'environnement).

## Relief

**Copernicus DEM** et **BD ALTI** de l'IGN à 25 mètres : altitude, pente et exposition de chaque carré.

## Sols

**SoilGrids** de l'ISRIC : acidité du sol (pH) à 250 mètres, lissée. Elle surestime souvent le pH des humus forestiers ; le modèle en tient compte.

## Météo

**Open-Meteo** : températures, pluie, neige, évapotranspiration et humidité du sol des trois derniers mois et des sept prochains jours, pour chaque cellule de cinq kilomètres de forêt, actualisés chaque matin. La climatologie du sol vient d'**ERA5-Land** (Copernicus).

## Contrôle

**GBIF** : les observations publiques d'espèces servent à vérifier que les cartes de terrain sont crédibles (altitudes, mois de récolte, acidité). Elles ne sont pas affichées.

## Fraîcheur

La météo est recalculée chaque matin. Les cartes de terrain sont régénérées quand un fichier d'espèce change. La date de la météo s'affiche sur la carte ; hors ligne, c'est celle du dernier téléchargement.

## Le modèle lui-même

Les règles de chaque espèce (arbres hôtes, sol, altitude, saison, seuils de pluie et de température) sont écrites dans des fichiers lisibles, chaque valeur appuyée sur une publication citée. Ils sont publics dans le dépôt du projet.
