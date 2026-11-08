#!/bin/sh
# Copie les illustrations des espèces du monorepo (shared/illustrations/<id>.svg) dans le
# catalogue d'images de l'app, un imageset par espèce (Assets.xcassets/Illustrations/<id>.imageset),
# et note le commit synchronisé dans ILLUSTRATIONS_VERSION. Xcode rend le SVG en vecteur
# (« Preserve Vector Data ») : `Image(speciesID)` dans SwiftUI, toutes tailles.
#
#   scripts/sync-illustrations.sh [chemin/vers/champis]
#
# Par défaut, le monorepo est attendu à côté de ce dépôt (../champis). Les SVG ne se retouchent
# jamais ici : ils viennent de scripts/draw_illustrations.py du référentiel.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
monorepo=${1:-"$here/../champis"}
src="$monorepo/shared/illustrations"
dst="$here/Champis/Assets.xcassets/Illustrations"

if [ ! -f "$src/index.json" ]; then
    echo "illustrations introuvables dans $src (passer le chemin du monorepo en argument)" >&2
    exit 1
fi

rm -rf "$dst"
mkdir -p "$dst"
cat > "$dst/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "provides-namespace" : false
  }
}
JSON

n=0
for svg in "$src"/*.svg; do
    id=$(basename "$svg" .svg)
    set_dir="$dst/$id.imageset"
    mkdir -p "$set_dir"
    cp "$svg" "$set_dir/$id.svg"
    cat > "$set_dir/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$id.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}
JSON
    n=$((n + 1))
done

commit=$(git -C "$monorepo" rev-parse --short HEAD 2>/dev/null || echo inconnu)
printf 'monorepo=adhumi/champis\ncommit=%s\nsource=shared/illustrations\n' "$commit" > "$dst/ILLUSTRATIONS_VERSION"
echo "$n illustrations synchronisées :"
cat "$dst/ILLUSTRATIONS_VERSION"
