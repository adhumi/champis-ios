#!/bin/sh
# Copie les vecteurs de parité du monorepo (shared/vectors/) dans les ressources de test
# du paquet ChampisScoring et note la génération synchronisée dans VECTORS_VERSION.
#
#   scripts/sync-vectors.sh [chemin/vers/champis]
#
# Par défaut, le monorepo est attendu à côté de ce dépôt (../champis). Skill scoring-parity.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
monorepo=${1:-"$here/../champis"}
src="$monorepo/shared/vectors"
pkg="$here/Packages/ChampisScoring"
dst="$pkg/Tests/ChampisScoringTests/Resources/vectors"

if [ ! -f "$src/m.json" ]; then
    echo "vecteurs introuvables dans $src (passer le chemin du monorepo en argument)" >&2
    exit 1
fi

mkdir -p "$dst"
rm -f "$dst"/*.json
cp "$src"/*.json "$dst/"

python3 - "$src/m.json" > "$pkg/VECTORS_VERSION" <<'PYTHON'
import json, sys
g = json.load(open(sys.argv[1]))["generated_by"]
print("scoring_version=" + g["scoring_version"])
print("species_hash=" + g["species_hash"])
PYTHON

echo "vecteurs synchronisés :"
cat "$pkg/VECTORS_VERSION"
