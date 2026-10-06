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
pytest=$(venv_tool pytest)
floor=${COVERAGE_FLOOR:-}
[[ -n $floor ]] || {
    echo "ERROR: COVERAGE_FLOOR is not set; set it in the project Makefile, e.g. COVERAGE_FLOOR := 90." >&2
    exit 1
}
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT

# A session's name: its member's last path component, the project directory's for ".".
name() { [[ $1 == . ]] && basename "$PWD" || echo "${1##*/}"; }

if [[ -n ${JUNIT_DIR:-} ]]; then
    names=$(for member in $SELECTED; do name "$member"; done | sort | uniq -d)
    [[ -z $names ]] || {
        echo "ERROR: members share the name ${names//$'\n'/, }, so their reports would collide in JUNIT_DIR." >&2
        exit 1
    }
    mkdir -p "$JUNIT_DIR"
    JUNIT_DIR=$(cd "$JUNIT_DIR" && pwd)
fi

echo "Starting tests${ONLY:+ for $ONLY}..."

# One session per member, in its directory, so its own pytest configuration applies; each
# member's coverage is held to the floor on its own, never combined.
# Numbered reports: names may repeat without JUNIT_DIR, and a session that writes none must
# not be judged by an earlier one's.
n=0
for member in $SELECTED; do
    json=$tmp/$((++n)).json label=$member
    [[ $member != . ]] || label=$(name .)
    echo "Testing $label..."
    (cd "$member" && "$pytest" --cov-branch --cov-report="json:$json" \
        ${JUNIT_DIR:+--junitxml="$JUNIT_DIR/$(name "$member").xml"})
    python3 "$DEVKIT/scripts/python/coverage_floor.py" "$json" "$floor" "$label"
done

echo "Tests completed."
