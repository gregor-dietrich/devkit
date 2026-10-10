#!/bin/bash

set -euo pipefail

# Check that the project's devkitw is not older than the pinned devkit's (docs/contract.md).
# Both files are read as data and never run.
cd "$PROJECT_ROOT"

# revision FILE: the number on FILE's first '# devkitw revision N' line, else 0.
revision() {
  local n
  n=$(awk '/^# devkitw revision [0-9]+$/ { print $4; exit }' "$1")
  echo "$((10#${n:-0}))"
}

for f in "$PROJECT_ROOT/devkitw" "$DEVKIT/devkitw"; do
  [[ -f $f && -r $f ]] || { echo "ERROR: no readable devkitw at $f" >&2; exit 1; }
done
cmp -s "$PROJECT_ROOT/devkitw" "$DEVKIT/devkitw" && exit 0

mine=$(revision "$PROJECT_ROOT/devkitw")
pinned=$(revision "$DEVKIT/devkitw")
((mine > pinned)) && exit 0

version=$(awk '{ print $2 }' "$DEVKIT/.devkit-commit" 2>/dev/null || :)
pin="the pinned devkit${version:+ $version}'s"
if ((mine == pinned)); then
  echo "ERROR: ./devkitw differs from $pin at the same revision $mine; run: cp .devkit/devkitw devkitw, or, editing devkitw in devkit itself, raise its revision" >&2
else
  echo "ERROR: ./devkitw (revision $mine) is older than $pin (revision $pinned); run: cp .devkit/devkitw devkitw" >&2
fi
exit 1
