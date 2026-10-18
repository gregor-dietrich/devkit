#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/select_modules.sh
. "$DEVKIT/scripts/lib/select_modules.sh"
# shellcheck source=SCRIPTDIR/../lib/get_uv.sh
UV_BOOTSTRAP=false . "$DEVKIT/scripts/lib/get_uv.sh"
# shellcheck source=SCRIPTDIR/../lib/get_venv.sh
. "$DEVKIT/scripts/lib/get_venv.sh"
# A .venv that drifted from uv.lock would run the tests against other code than the lock names.
venv_synced
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
# --cache-clear: a stale .pytest_cache (--lf, --sw) steers no session; COVERAGE_FILE: the data
# file is the session's own, so no stale .coverage (--cov-append) reaches the floor and a data_file
# in the configuration loses to it.
# Numbered reports: names may repeat without JUNIT_DIR, and a session that writes none must
# not be judged by an earlier one's.
n=0
for member in $SELECTED; do
    json=$tmp/$((++n)).json label=$member
    [[ $member != . ]] || label=$(name .)
    echo "Testing $label..."
    (cd "$member" && COVERAGE_FILE="$tmp/$n.coverage" "$pytest" --cache-clear --cov-branch \
        --cov-report="json:$json" ${JUNIT_DIR:+--junitxml="$JUNIT_DIR/$(name "$member").xml"})
    python3 -I "$DEVKIT/scripts/python/coverage_floor.py" "$json" "$floor" "$label"
done

echo "Tests completed."
