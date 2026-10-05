#!/bin/bash

set -euo pipefail

# Check docs/decisions.md's entry format, when the project keeps one (docs/contract.md).
cd "$PROJECT_ROOT"
exec python3 "$DEVKIT/scripts/check_decisions.py"
