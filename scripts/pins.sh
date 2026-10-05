#!/bin/bash

set -euo pipefail

# Check that workflow actions and container images are pinned (docs/contract.md).
cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/lib/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor
exec python3 "$DEVKIT/scripts/check_pins.py"
