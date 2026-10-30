#!/bin/sh
# Copie depuis le monorepo les skills partagés (champis-model, scoring-parity, spec-sync)
# et note le commit synchronisé dans .claude/skills/SKILLS_VERSION.
#
#   scripts/sync-skills.sh [chemin/vers/champis]
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
monorepo=${1:-"$here/../champis"}
src="$monorepo/.claude/skills"
dst="$here/.claude/skills"

for s in champis-model scoring-parity spec-sync; do
    [ -f "$src/$s/SKILL.md" ] || { echo "skill $s introuvable dans $src" >&2; exit 1; }
    rm -rf "${dst:?}/${s:?}"
    mkdir -p "$dst/$s"
    cp -R "$src/$s/." "$dst/$s/"
done

commit=$(git -C "$monorepo" rev-parse --short HEAD 2>/dev/null || echo inconnu)
printf 'monorepo=adhumi/champis\ncommit=%s\nskills=champis-model scoring-parity spec-sync\n' "$commit" > "$dst/SKILLS_VERSION"
echo "skills synchronisés :"
cat "$dst/SKILLS_VERSION"
