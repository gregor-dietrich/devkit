#!/bin/bash

set -euo pipefail

# Acts on the whole project and ignores ONLY.
cd "$PROJECT_ROOT"

echo "Removing Python caches and build output..."
# Never enters the root's .git or .devkit, a .venv or node_modules at any depth, or another
# checkout: a directory holding a .git (a worktree's .git file, a nested clone's .git
# directory) is pruned wherever it sits.
find . -mindepth 1 \
    \( -path ./.git -o -path ./.devkit -o -name .venv -o -name node_modules \
    -o \( -type d -exec test -e '{}/.git' \; \) \) -prune \
    -o \( -type d \( -name __pycache__ -o -name .pytest_cache -o -name .ruff_cache \
    -o -name '*.egg-info' -o -name dist \) -o -type f \( -name .coverage -o -name '.coverage.*' \) \) \
    -prune -exec rm -rf -- {} +

echo "Clean completed."
