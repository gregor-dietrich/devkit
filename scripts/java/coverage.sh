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

echo "Running tests (including ITs) with JaCoCo${ONLY:+ for $ONLY}..."

# Run Maven from the root using the reactor; ONLY narrows it with -pl
"${MVN_CMD}" -q verify ${ONLY:+-pl "$ONLY"} -DskipITs=false -Dquarkus.log.console.enabled=false -Dquarkus.log.file.enabled=false -Drevision="${REVISION}" -Dmaven.test.failure.ignore=true || maven_status=$?

echo "Generating coverage report..."

# One JaCoCo CSV per selected module (the project root for a monolith); coverage.py
# warns about missing ones and fails when none exists.
set --
for module in $SELECTED; do
    set -- "$@" "$module/target/site/jacoco/jacoco.csv"
done
python3 "$DEVKIT/scripts/java/coverage.py" "$REPORT" "$@"

if [ "$OPEN_REPORT" = true ]; then
    xdg-open "$REPORT" 2>/dev/null || open "$REPORT" 2>/dev/null || echo "Cannot open $REPORT" >&2
fi

echo "Coverage report generated at $REPORT."

exit $maven_status
