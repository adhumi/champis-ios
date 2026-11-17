# Provenance des skills

Deux familles, comme le veut la spec (« Décisions prises › Skills ») : des skills maison, et des skills communautaires **copiés en dossier, jamais installés en plugin**, pour que chaque session lise exactement ce qui a été relu.

## Copies synchronisées depuis le monorepo `adhumi/champis`

`champis-model`, `scoring-parity`, `spec-sync`, `roadmap` : la source de vérité est `adhumi/champis/.claude/skills/`. Ne pas les modifier ici ; relancer `scripts/sync-skills.sh ../champis` après un changement là-bas. `SKILLS_VERSION` note le commit du monorepo synchronisé.

## Skills maison de ce dépôt (phase 4)

`swiftui-mapkit`, `offline`, `field-feedback` : écrits pour Champis à partir des décisions de la spec. Toute évolution structurante passe par la spec avant le skill.

## Skills communautaires (copies, licence MIT)

| Dossier | Source | Auteur | Commit copié | Date |
| --- | --- | --- | --- | --- |
| `swiftui-pro` | https://github.com/twostraws/SwiftUI-Agent-Skill | Paul Hudson | f2920b6 | 2026-10-26 |
| `swift-concurrency-pro` | https://github.com/twostraws/Swift-Concurrency-Agent-Skill | Paul Hudson | bee3f69 | 2026-05-17 |
| `swift-testing-pro` | https://github.com/twostraws/Swift-Testing-Agent-Skill | Paul Hudson | 2d6bba1 | 2026-05-17 |
| `ios-accessibility` | https://github.com/dadederk/iOS-Accessibility-Agent-Skill | Daniel Devesa Derksen-Staats | dcc3a36 | 2026-03-09 |
| `background-execution` | https://github.com/n0an/Background-Execution-Agent-Skill | Anton Novoselov | a29ddf8 | 2026-09-08 |

Copiés le 30 oct. 2026 et relus : aucune instruction hors sujet (réseau, exécution, secrets). Les dossiers `.claude-plugin/` et les doublons `skills/` des dépôts d'origine ne sont pas repris. Écartés (audit du 17 oct. 2026) : pytest-skill LambdaTest, fastapi-router-py Microsoft, App Store Connect CLI, skills van der Lee et Ricouard.

Note d'usage : `background-execution` sert aux téléchargements hors ligne (URLSession en arrière-plan), pas aux notifications « mes coins », qui sont calculées et envoyées par le backend (décision du 30 oct. 2026).
