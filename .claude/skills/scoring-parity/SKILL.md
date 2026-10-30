---
name: scoring-parity
description: Garantir que le scoring (trapèze, M, Φ, M_eff, groupes, palette) donne le même résultat en Python (API) et en Swift (app) via des vecteurs de test partagés. À lire avant de porter ou modifier le scoring dans un client.
---

# Parité du scoring entre Python et Swift

Le scoring de référence est en Python (`api/champis_api/scoring.py`, trapèze dans `pipeline/champis_pipeline/scoring.py`). L'app recalcule `M × Φ` localement (hors ligne, changement de jour sans réseau). Ce portage n'a pas le droit de diverger.

Le site **ne porte pas** le scoring (décision du 30 oct. 2026) : sans hors ligne web, il affiche `M_eff` et `Φ` tels que l'API les renvoie pour les 11 jours, et ne lit de `shared/` que la palette. La parité ne concerne donc que Python et Swift.

## Le contrat : `shared/vectors/`

Fichiers JSON générés **uniquement par Python** (`uv run python -m champis_api.vectors --out shared/vectors/`), jamais écrits à la main ni par un autre langage :

```
shared/vectors/trapezoid.json       [{ "x": 4.2, "t": {min,opt_low,opt_high,max}, "expected": 0.4 }, …]
shared/vectors/phi.json             [{ "species": "…", "date": "2026-10-16", "alt_m": 1200, "expected": 0.8333 }, …]
shared/vectors/m.json               [{ "species": "…", "series": { daily arrays J−118 → J+7 }, "cell_elevation": 700, "alt_class": 1350, "expected": { "M": …, "M_eff": …, "factors": {…} } }, …]
shared/vectors/group.json           [{ "group": "cepes", "scores": {…}, "expected": { "score": …, "leading": "boletus_aereus" } }, …]
shared/vectors/palette.json         [{ "score": 0.55, "expected": { "label": "bon", "hex": "…" } }, …]
```

Chaque fichier contient un champ `"generated_by": { "scoring_version": …, "species_hash": … }`. Les vecteurs couvrent au minimum : les bornes exactes du trapèze (x = min, opt_low, opt_high, max, et ±ε), les seuils de palette exacts (0,15 / 0,35 / 0,55 / 0,75), chaque facteur multiplicatif à 0 et à 1, la persistance avec un M passé dominant, le décalage altitudinal aux bornes `max_days`, `secondary_peak`, un 29 février.

## Tolérance

`|actual − expected| ≤ 1e-6` sur les scores ; égalité stricte sur `label`, `hex`, `leading`. Flottants en double précision partout (`Double` en Swift, pas `Float`). Les tuiles uint8 arrondissent à l'affichage seulement.

## Dans chaque langage

- **Python** : `tests/test_vectors.py` rejoue les vecteurs contre le code qui les a produits (détecte une régénération incohérente).
- **Swift** (`champis-ios/Packages/ChampisScoring`, paquet local sans dépendance) : `ChampisScoringTests` avec Swift Testing, les vecteurs sont copiés dans les ressources du paquet de test par `scripts/sync-vectors.sh` (le dépôt iOS est séparé ; le script note `scoring_version` et `species_hash` dans `Packages/ChampisScoring/VECTORS_VERSION`).

Les deux suites tournent en CI ; une PR qui change le scoring Python sans régénérer les vecteurs échoue (le test Python détecte le hash), et une PR client qui échoue sur les vecteurs ne se merge pas.

## Règles d'écriture des portages

- Même ordre d'opérations que Python (somme pondérée, puis facteurs multiplicatifs dans l'ordre frost, water_balance, heat, memory, puis persistance, puis frost et water_balance à nouveau). Réordonner change les arrondis.
- Dates : jour de l'année calculé sur la date civile locale (`Europe/Paris`), `MM-DD` comparés comme chaînes ou comme (mois, jour), jamais via des timestamps.
- Les paramètres d'espèce sont chargés depuis `/species` (JSON identique aux fichiers du dépôt) : aucun client n'embarque de valeur en dur.
- Un client qui ne sait pas calculer un facteur (série manquante) l'affiche comme « indisponible » et n'invente pas 0,5 : c'est l'API qui applique la règle de la donnée manquante.

## Quand le modèle change

1. Modifier `SCHEMA.md` et `scoring.py` (skill `champis-model`).
2. Régénérer les vecteurs, relancer les trois suites.
3. Porter la modification en Swift dans une PR liée ; tant qu'elle échoue, l'API n'est pas déployée (le contrat `/species` inclut `scoring_version` et les clients refusent une version qu'ils ne connaissent pas).
