#!/bin/bash

set -euo pipefail

# Check that workflow actions and container images are pinned (docs/contract.md).
cd "$PROJECT_ROOT"
exec python3 "$DEVKIT/scripts/check_pins.py"
