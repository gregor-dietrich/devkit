#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# The one script that may install the pinned uv into devkit's cache.
# shellcheck source=SCRIPTDIR/../lib/get_uv.sh
UV_BOOTSTRAP=true . "$DEVKIT/scripts/lib/get_uv.sh"

echo "Syncing .venv from uv.lock with uv $UV_PIN..."
# --locked: a uv.lock stale against pyproject.toml fails instead of being rewritten.
"$UV_CMD" sync --locked --all-packages --all-extras || {
    echo "ERROR: uv sync failed; if uv.lock is stale against pyproject.toml, run uv lock and commit uv.lock." >&2
    exit 1
}

echo "Install completed."
