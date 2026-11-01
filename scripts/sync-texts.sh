#!/bin/sh
# Copie les textes de Comprendre du monorepo (shared/texts/ : index.json + Markdown) dans les
# ressources de l'app et note le commit synchronisé dans Champis/Resources/Texts/TEXTS_VERSION.
# Les mêmes mots servent le site ; l'app les lit hors ligne (décision du 1er nov. 2026, lot 4).
#
#   scripts/sync-texts.sh [chemin/vers/champis]
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
monorepo=${1:-"$here/../champis"}
src="$monorepo/shared/texts"
dst="$here/Champis/Resources/Texts"

if [ ! -f "$src/index.json" ]; then
    echo "textes introuvables dans $src (passer le chemin du monorepo en argument)" >&2
    exit 1
fi

mkdir -p "$dst"
rm -f "$dst"/*.md "$dst"/index.json
cp "$src"/index.json "$src"/*.md "$dst/"

commit=$(git -C "$monorepo" rev-parse --short HEAD 2>/dev/null || echo inconnu)
printf 'monorepo=adhumi/champis\ncommit=%s\nsource=shared/texts\n' "$commit" > "$dst/TEXTS_VERSION"
echo "textes synchronisés :"
cat "$dst/TEXTS_VERSION"
