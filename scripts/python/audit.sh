#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/get_uv.sh
UV_BOOTSTRAP=false . "$DEVKIT/scripts/lib/get_uv.sh"
# shellcheck source=SCRIPTDIR/../lib/get_venv.sh
. "$DEVKIT/scripts/lib/get_venv.sh"
pip_audit=$(venv_tool pip-audit)
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT

echo "Exporting the runtime dependencies uv.lock pins..."
# Third-party runtime dependencies only: no dependency group, none of the project's own
# packages, no local path dependency (pip-audit refuses a path it cannot hash; what it depends
# on stays).
"$UV_CMD" export --frozen --no-default-groups --all-packages --all-extras --no-emit-project \
    --no-emit-workspace --no-emit-local --format requirements.txt --quiet --output-file "$tmp/requirements.txt"
if ! grep -q '^[A-Za-z0-9]' "$tmp/requirements.txt"; then
    echo "No third-party runtime dependencies in uv.lock; nothing to audit."
    exit 0
fi

echo "Running pip-audit (needs the network)..."
# --strict: a dependency pip-audit could not audit fails the run instead of passing with a warning.
"$pip_audit" --strict --no-deps --disable-pip -r "$tmp/requirements.txt" || {
    echo "ERROR: pip-audit reported vulnerable or unauditable dependencies; see its output above." >&2
    exit 1
}

echo "Audit completed."
