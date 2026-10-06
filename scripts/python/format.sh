#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/select_modules.sh
. "$DEVKIT/scripts/lib/select_modules.sh"
# shellcheck source=SCRIPTDIR/../lib/get_venv.sh
. "$DEVKIT/scripts/lib/get_venv.sh"
ruff=$(venv_tool ruff)
read -ra targets <<< "${ONLY:+$SELECTED}"
[[ ${#targets[@]} -gt 0 ]] || targets=(.)

echo "Formatting${ONLY:+ $ONLY}..."

# Rewrites, never judges: what ruff cannot fix is make lint's to report.
"$ruff" check --fix --exit-zero "${targets[@]}"
"$ruff" format "${targets[@]}"

echo "Format completed."
