#!/usr/bin/env bash
# Apply patches/riot/<pkg>-<version>-*.patch to the fetched Riot registry
# sources (~/.riot/registry/pkgs.ml/src/<pkg>/<version>). Riot has no
# dependency-override mechanism, so the fixes live here until upstream
# ships them; see docs/oasis-spec.md §8.0 for what each patch fixes.
#
# Idempotent. Run after the registry has been fetched (`riot plan` is enough)
# and before `riot build`; editing the sources makes riot rebuild them.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="${RIOT_HOME:-$HOME/.riot}/registry/pkgs.ml/src"

shopt -s nullglob
patches=("$root"/patches/riot/*.patch)
if [ "${#patches[@]}" -eq 0 ]; then
  echo "patch-riot: no patches under $root/patches/riot" >&2
  exit 1
fi

for p in "${patches[@]}"; do
  name="$(basename "$p" .patch)"
  pkg="${name%%-*}"
  rest="${name#*-}"
  version="${rest%%-*}"
  dir="$src/$pkg/$version"
  if [ ! -d "$dir" ]; then
    echo "patch-riot: $dir not found (run \`riot plan\` first?)" >&2
    exit 1
  fi
  if patch -d "$dir" -p1 -R --dry-run --silent < "$p" > /dev/null 2>&1; then
    echo "patch-riot: already applied: $name"
  else
    patch -d "$dir" -p1 --forward --silent < "$p"
    echo "patch-riot: applied: $name"
  fi
done
