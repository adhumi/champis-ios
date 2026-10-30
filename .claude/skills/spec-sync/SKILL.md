---
name: spec-sync
description: Toute décision de conception du projet Champis vit dans la spec (doc Claude « Spec — Champis ») avant d'exister dans le code. Dit quoi y reporter, où, et ce qu'on ne décide pas seul.
---

# Synchronisation avec la spec

La spec est le doc « Spec — Champis (carte de cueillette) ». Le code l'implémente ; il ne la précède jamais sur un choix structurant.

## Ce qui doit être dans la spec avant d'être codé

- Une formule ou un facteur du modèle (section « Scoring »), avec sa justification et sa source.
- Un endpoint de l'API, son contrat de réponse (section « Backend »).
- Un format de fichier échangé entre composants (PMTiles, `weather_grid.json`, vecteurs, `species/*.json`).
- Une dépendance externe nouvelle (source de données, bibliothèque non triviale, service).
- Un choix d'hébergement, de stockage ou de coût.
- Tout ce qui touche la vie privée des observations terrain.

## Ce qui n'a pas besoin d'y être

Structure interne d'un module, nommage, refactoring, choix d'une fonction GDAL plutôt qu'une autre pour le même résultat, tests.

## Comment reporter

- Décision prise → ligne dans le tableau « Décisions prises » (sujet, décision, pourquoi) ou mise à jour de la section concernée. Pas de doublon : on modifie la ligne existante.
- Décision à prendre → case à cocher dans « Points ouverts à trancher », avec les options et une recommandation, **puis on demande à Adrien** ; on ne tranche pas seul ce qui est dans cette liste.
- Règle d'espèce → onglet « Références » de la phase courante (skill `species-file`).
- Fin de phase → la ligne du « Plan de réalisation » reçoit le livrable réel et le résultat du critère de passage.

Préférence explicite d'Adrien : passer les points importants en revue ensemble, challenger ce qui doit l'être, pas d'hypothèse silencieuse sur un sujet structurant. En cas de doute sur « est-ce structurant ? », c'est structurant.

## En commit

Le message de commit d'une PR qui implémente une décision cite la section de la spec (« Scoring › trigger = meilleur événement »). Une PR qui contredit la spec est refusée, même si le code est meilleur : on change la spec d'abord.

**Jamais de commit poussé sur `main` sans PR** (règle d'Adrien, 30 oct. 2026), dans le monorepo comme dans `champis-ios` : une branche, une PR, la CI verte, puis la fusion. Même pour une ligne de documentation.
