# Contribuer

Champis est un projet personnel, tenu par une seule personne sur son temps libre. Les pull requests sont bienvenues ; elles sont relues quand l'auteur le peut, parfois après plusieurs semaines. Une fonctionnalité qui contredit la spec du projet sera refusée, même bien écrite : mieux vaut en parler avant.

## Avant de contribuer

- Pour un changement de fond (nouvel écran, nouvelle donnée collectée, travail en arrière-plan, dépendance de plus), ouvrez d'abord une issue pour en discuter.
- Pour une correction de bug, une faute ou un test manquant, une pull request directe suffit.
- Pour une faille de sécurité, pas d'issue : voir [`SECURITY.md`](SECURITY.md).

## La spec

Les décisions structurantes du projet (le modèle, les sources de données, le découpage des dépôts, la vie privée) sont consignées dans un document de spécification tenu par l'auteur. Le code et les commentaires y renvoient sous la forme « spec › … ». Une copie de ce document est destinée à être versionnée dans le référentiel `adhumi/champis` : voir le référentiel. Une décision de ce niveau se discute dans une issue et s'inscrit dans la spec avant d'arriver dans le code.

## Ce qui ne se modifie pas ici

- Les fichiers d'espèces, la palette, les vecteurs de parité, les textes du Guide et les aquarelles vivent dans le référentiel `adhumi/champis`. Ils se modifient par une pull request là-bas ; ce dépôt n'en garde que des copies, mises à jour par `scripts/sync-vectors.sh`, `scripts/sync-texts.sh` et `scripts/sync-icons.py`, jamais à la main.
- Les skills `champis-model`, `scoring-parity`, `spec-sync` et `roadmap` de `.claude/skills/` sont aussi des copies du référentiel (`scripts/sync-skills.sh`).
- Le scoring de référence est celui de `adhumi/champis-api`, en Python. `Packages/ChampisScoring` en est le portage : une règle se change d'abord là-bas, avec ses vecteurs, puis ici.

## Règles du dépôt

- Une branche, une pull request, Xcode Cloud vert, puis fusion. Jamais de commit poussé directement sur `main`.
- Tests avec Swift Testing (`@Test`, `#expect`), jamais XCTest. Dans Xcode, schéma `Champis` puis ⌘U ; pour le paquet du scoring seul, `cd Packages/ChampisScoring && swift test`.
- iOS, iPadOS et macOS 26 au minimum, mode de langage Swift 6. Pas de `#available`.
- MVVM avec `@Observable` : un modèle par écran, les vues ne calculent rien.
- Aucune valeur d'espèce dans le code : espèces, palette et seuils viennent de l'API.
- Le scoring local doit rester à la parité des vecteurs du référentiel (tolérance 1e-6, `Double` partout).
- Les PNG de données se décodent octet par octet, jamais par `UIImage` ou `CGImage`. Un fichier malformé lève une erreur, il n'arrête pas l'app.
- Vie privée : l'identifiant, les observations et les coins ne partent que vers `api.champis.app` en https. Pas de photo, pas de rafraîchissement en arrière-plan, aucun SDK tiers. Une donnée collectée de plus se décide dans la spec et se reporte dans `Champis/PrivacyInfo.xcprivacy` et `docs/app-store.md`.
- `Champis/` et `ChampisTests/` sont des dossiers synchronisés : ajouter un fichier sur disque suffit, n'éditez pas le projet pour cela. Ne proposez pas de changement d'équipe de signature ni d'identifiant de bundle (`README.md` › Compiler sans le compte de l'auteur).
- Ne versionnez pas `xcuserdata/`, `DerivedData/` ni `.build/`.
- Le dépôt est écrit en français : commentaires, messages de commit, documentation.

Le détail de ces conventions, avec leurs raisons et leurs dates, est dans `CLAUDE.md` ; ce que fait chaque partie de l'app, dans [`docs/conception.md`](docs/conception.md).

## Licence des contributions

Le dépôt est sous licence MIT (`LICENSE`). En proposant une contribution, vous acceptez qu'elle soit publiée sous la même licence.
