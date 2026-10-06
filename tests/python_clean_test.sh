#!/usr/bin/env bash
# Tests for scripts/python/clean.sh: a temp project holding every cache and
# build output it removes, next to what it must leave alone (a .venv or
# node_modules at any depth, the .devkit link's target, a nested checkout,
# sources), with an ONLY that names no module, which clean ignores. Prints
# PASS/FAIL per path.
set -euo pipefail

clean_sh=$(cd "$(dirname "$0")/.." && pwd)/scripts/python/clean.sh
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
proj=$work/proj
fails=0

gone=(
  src/pkg/__pycache__ packages/core/tests/__pycache__ .pytest_cache packages/core/.pytest_cache
  .ruff_cache src/pkg.egg-info dist packages/core/dist .coverage packages/core/.coverage.host.1234
)
kept=(
  src/pkg/__init__.py .venv/lib/__pycache__ .venv/dist node_modules/x/__pycache__
  web/node_modules/x/dist pkg/.venv/x/__pycache__
  wt/.git wt/__pycache__ wt/.coverage clone/.git/HEAD clone/src/__pycache__ ../devkit/__pycache__
)
for path in "${gone[@]}" "${kept[@]}"; do
  case $path in
    *.coverage* | *.py | */.git | */HEAD) mkdir -p "$(dirname "$proj/$path")" && touch "$proj/$path" ;;
    *) mkdir -p "$proj/$path" && touch "$proj/$path/f" ;;
  esac
done
ln -s "$work/devkit" "$proj/.devkit"

out=$(PROJECT_ROOT=$proj ONLY=nosuchmodule "$clean_sh" 2>&1) || {
  echo "FAIL clean.sh exited non-zero:"
  printf '%s\n' "$out"
  exit 1
}
for path in "${gone[@]}"; do
  if [[ ! -e $proj/$path ]]; then echo "PASS removes $path"; else echo "FAIL removes $path" && fails=$((fails + 1)); fi
done
for path in "${kept[@]}" .devkit; do
  if [[ -e $proj/$path ]]; then echo "PASS keeps $path"; else echo "FAIL keeps $path" && fails=$((fails + 1)); fi
done

[[ $fails == 0 ]]
