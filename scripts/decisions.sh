#!/bin/bash

set -euo pipefail

# Check docs/decisions.md's entry format, when the project keeps one (docs/contract.md).
cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/lib/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor
exec python3 "$DEVKIT/scripts/check_decisions.py"
