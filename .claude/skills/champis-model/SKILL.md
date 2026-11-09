---
name: champis-model
description: Contrat du modèle Champis (potentiel terrain T, indice météo M, fenêtre Φ, score S). À lire avant tout code qui calcule, affiche ou teste un score, dans le pipeline, l'API, le site ou l'app.
---

# Le modèle Champis

Champis prédit où et quand cueillir des champignons en France. Le score d'un pixel de 25 m, pour une espèce et un jour J :

```
S(p, e, J) = T(p, e) × M_eff(c(p), e, J, alt(p)) × Φ(e, J, alt(p))
```

- `T` : potentiel terrain, statique, précalculé par le pipeline (raster uint8 0–255 → 0–1).
- `M_eff` : indice météo, dynamique, calculé par l'API sur la cellule météo `c(p)`.
- `Φ` : fenêtre phénologique, calculée par l'API.

**La seule source de vérité des règles est `species/*.json` et `species/SCHEMA.md`.** Aucun seuil, poids, hôte ou date ne vit dans le code. Si tu te surprends à écrire `if species == "boletus_edulis"`, arrête-toi : c'est un paramètre à ajouter au schéma.

## Règles à respecter dans tout code

1. **Une seule fonction trapèze**, `trapezoid(x, min, opt_low, opt_high, max)` : 0 hors `[min, max]`, 1 dans `[opt_low, opt_high]`, linéaire entre. Elle sert partout (terrain, météo). Ne pas en réimplémenter une variante.
2. **`T = host × Σ(w_i × f_i)`** : l'hôte est multiplicatif ; `cover`, `ph`, `altitude`, `aspect`, `slope` sont pondérés (somme des poids = 1). Règles dures : altitude hors `[min, max]` → 0 ; hors forêt → 0 ; `ph` a un plancher de 0,15 ; donnée manquante → facteur 0,5 (sauf hôte : hors forêt = 0).
3. **`M = (Σ w × f) × frost × water_balance × heat × memory`** (la somme porte temp, rain, trigger, soil_moisture et le facteur optionnel soil_temp, température du sol 0–7 cm corrigée à l'altitude comme l'air ; absent = poids 0), puis persistance `M_eff(J) = max(M(J), max_k M(J−k) × (1 − k/days))`, puis frost et water_balance **réappliqués** sur `M_eff` (les sporophores existants gèlent ou sèchent).
4. **Trigger = meilleur événement de pluie de la fenêtre**, pas le dernier. Un événement = `≥ event_mm` sur `event_days` jours consécutifs, hors jours de neige.
5. **Correction altitudinale des températures** : −0,6 °C/100 m × (alt pixel − alt cellule), par classes de 300 m. Toujours, pour temp_mean, frost, heat.
6. **`rain_sum`, jamais `precipitation_sum`** (la neige n'est pas une pluie déclenchante).
7. **Humidité du sol en percentile** de la climatologie de la cellule sur **l'année entière** (10 ans, toutes dates confondues ; décision du 7 nov. 2026), jamais en valeur absolue ni par mois civil : le percentile du mois faisait une marche au 1er du mois et mettait tout l'hiver en « sol sec ».
8. **`Φ`** : 0 hors saison, 0,25 dès `season.start`, 1 au pic, rampes linéaires de `ramp_days` ; `secondary_peak` fusionné par max ; `altitude_shift` décale début et fin séparément (positif = plus tard).
9. **Groupe d'affichage** : l'UI montre `group` (cèpes, girolles) ; score du groupe = **max** des espèces du groupe, et la fiche indique quelle espèce porte le score.
10. **Seuils d'affichage** (ne pas en inventer d'autres) : ≥ 0,75 excellent · ≥ 0,55 bon · ≥ 0,35 moyen · ≥ 0,15 faible · sinon très faible. Ils ne donnent que les **mots** (fiche, coins, notifications, graduations de la légende). La **couleur d'un pixel** est une échelle linéaire (6 nov. 2026) : un seul violet `scale.hex` dont l'alpha est le score, `alpha = floor(255 × (alpha_min + (alpha_max − alpha_min) × S) + 0,5)`, `S` borné à [0, 1] ; l'overlay est dessiné à l'opacité 1. Le `hex` d'un seuil est la couleur de pastille de sa classe (violet au milieu de la classe sur blanc), jamais celle d'un pixel. Tout vient de `shared/palette.json`.

## Où vit quoi

Depuis le découpage des dépôts (6 nov. 2026), le code de référence est dans `adhumi/champis-api` ; ce référentiel (`adhumi/champis`, sous-module `champis/` de champis-api et champis-web) garde les espèces, la table BD Forêt, la palette, les vecteurs et les textes.

| Calcul | Module de référence | Portages |
| --- | --- | --- |
| trapèze, `T` | champis-api : `pipeline/champis_pipeline/scoring.py` | — (jamais ailleurs) |
| `M`, `Φ`, `M_eff`, groupes | champis-api : `api/champis_api/scoring.py` (importe le trapèze du pipeline) | `champis-ios/Packages/ChampisScoring` — validé par les vecteurs de test (skill `scoring-parity`) ; le site prend les valeurs de l'API, sans portage |
| seuils, palette | `shared/palette.json` | chargé tel quel par tous les clients |

## Vocabulaire

- **hôte** : clé du vocabulaire `mapping/bdforet_to_hosts.json` → `hosts` (`hetre`, `sapin_epicea`, `chenes_decidus`…). Jamais un code TFV brut ni un nom d'arbre libre.
- **cellule météo** : point de la grille `weather_grid.json` (~5 km) ; l'API ne connaît pas les pixels, seulement les cellules et leur altitude.
- **espèce** vs **groupe** : une espèce = un JSON ; un groupe = ce que l'utilisateur voit.

## Pièges connus

- SoilGrids surestime le pH des humus forestiers sur calcaire : d'où le plancher. Ne pas « corriger » en resserrant les plages.
- Une petite pluie récente ne doit jamais annuler l'effet d'une grosse pluie plus ancienne (d'où le max sur les événements).
- Le délai pluie → pousse est de 10–20 j pour les cèpes, 14–28 j pour les girolles : la période de beau temps après la pluie est **la** période de récolte, elle ne doit pas être pénalisée comme « sèche » (d'où le bilan P − ET0 et non un compteur de jours secs).
- `season.end` dépasse souvent le pic de plusieurs semaines : c'est voulu (pousses tardives).

## Quand tu modifies le modèle

Modifier une formule = modifier `SCHEMA.md` et les vecteurs de test (ce référentiel), `scoring.py` (champis-api) et la spec (skill `spec-sync`), en PR liées, fusionnées ensemble. Un changement de paramètre d'espèce = skill `species-file`.
