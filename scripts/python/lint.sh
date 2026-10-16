#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor || exit 1
# shellcheck source=SCRIPTDIR/../lib/select_modules.sh
. "$DEVKIT/scripts/lib/select_modules.sh"
# shellcheck source=SCRIPTDIR/../lib/get_venv.sh
. "$DEVKIT/scripts/lib/get_venv.sh"
ruff=$(venv_tool ruff)
vulture=$(venv_tool vulture)
# ONLY narrows the ruff passes to the selected members; vulture, the anchored-match gate and jscpd always scan the whole project.
read -ra targets <<< "${ONLY:+$SELECTED}"
[[ ${#targets[@]} -gt 0 ]] || targets=(.)

echo "Starting lint checks${ONLY:+ for $ONLY}..."

"$ruff" check "${targets[@]}"
"$ruff" format --check "${targets[@]}"
# vulture reads its paths from [tool.vulture]; without them it would fail on its usage.
python3 -I "$DEVKIT/scripts/python/uv_project.py" vulture-paths > /dev/null
"$vulture"
# The anchored-match gate: no $-anchored re.match or re.search beyond devkit.toml's [python.anchored-match] entries.
# It runs under .venv's Python, so it parses with the project's grammar; -I -S: no PYTHON* variable and no
# site-packages, so nothing of the project's environment runs in it.
"$VENV/bin/python" -I -S "$DEVKIT/scripts/python/anchored_match.py" run
# The copy-paste gate: jscpd over devkit.toml's [python.duplication] paths.
# shellcheck source=SCRIPTDIR/../lib/node_closure.sh
. "$DEVKIT/scripts/lib/node_closure.sh"
node_closure "$DEVKIT/jscpd" jscpd lint
python3 -I "$DEVKIT/scripts/python/duplication.py" run "$NODE_TOOL"

echo "Lint checks completed."
