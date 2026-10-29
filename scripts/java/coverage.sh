#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/select_modules.sh
. "$DEVKIT/scripts/lib/select_modules.sh"
# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

OPEN_REPORT=false
while getopts "o" opt; do
    case "$opt" in
        o) OPEN_REPORT=true ;;
        *) exit 2 ;;
    esac
done

REVISION=${REVISION:-1.0.0-SNAPSHOT}
REPORT=".coverage.md"
maven_status=0

# Everything this run wrote is newer than the marker; backdated a second because find -newer is
# strict and mtimes are coarse (python3, as touch -d is not portable).
marker=$(mktemp)
trap 'rm -f "$marker"' EXIT
python3 -I -c 'import os, sys, time; t = time.time() - 1; os.utime(sys.argv[1], (t, t))' "$marker"
# A run that writes no report leaves none of an earlier run behind.
rm -f "$REPORT"

echo "Running tests (including ITs) with JaCoCo${ONLY:+ for $ONLY}..."

# Run Maven from the root using the reactor; ONLY narrows it with -pl. A failing module stops only its
# dependents, and failing tests do not stop Maven, so their reports are read below.
"${MVN_CMD}" -q verify --fail-at-end ${ONLY:+-pl "$ONLY"} -DskipITs=false -Dquarkus.log.console.enabled=false -Dquarkus.log.file.enabled=false -Drevision="${REVISION}" -Dmaven.test.failure.ignore=true || maven_status=$?

echo "Generating coverage report..."

# Test classes whose report from this run, in any module below the root (MODULES need not list it),
# records a failure or an error, or cannot be read.
failing=$({ find . \( -name node_modules -o -name .git \) -prune -o -path '*/target/*-reports/TEST-*.xml' -newer "$marker" -print || true; } |
    python3 -I "$DEVKIT/scripts/java/failed_tests.py")

# One JaCoCo CSV per selected module (the project root for a monolith) that this run wrote.
set --
for module in $SELECTED; do
    csv="$module/target/site/jacoco/jacoco.csv"
    if [ -n "$(find "$csv" -newer "$marker" 2>/dev/null)" ]; then
        set -- "$@" "$csv"
    else
        echo "WARNING: module $module wrote no coverage report this run; it is left out." >&2
    fi
done

coverage_status=0
if [ $# -eq 0 ]; then
    echo "ERROR: no module wrote a coverage report this run." >&2
    coverage_status=1
else
    [ "$maven_status" -eq 0 ] || echo "WARNING: Maven failed (status $maven_status); the report covers only the modules the build reached." >&2
    python3 -I "$DEVKIT/scripts/java/coverage.py" "$REPORT" "$@" || coverage_status=$?
    if [ "$coverage_status" -eq 0 ]; then
        if [ "$OPEN_REPORT" = true ]; then
            xdg-open "$REPORT" 2>/dev/null || open "$REPORT" 2>/dev/null || echo "Cannot open $REPORT" >&2
        fi
        echo "Coverage report generated at $REPORT."
    fi
fi

[ -z "$failing" ] || echo "ERROR: failing tests: $failing" >&2

[ "$maven_status" -eq 0 ] || exit "$maven_status"
[ -z "$failing" ] || exit 1
exit "$coverage_status"
