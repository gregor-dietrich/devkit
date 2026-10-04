#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/select_modules.sh
. "$DEVKIT/scripts/lib/select_modules.sh"
# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

REVISION=${REVISION:-1.0.0-SNAPSHOT}

echo "Starting lint checks${ONLY:+ for $ONLY}..."

# Run Maven from the root using the reactor; ONLY narrows it with -pl
"${MVN_CMD}" -q compile test-compile spotless:check checkstyle:check spotbugs:check pmd:check pmd:cpd-check ${ONLY:+-pl "$ONLY"} -Drevision="${REVISION}"

# Skip when the selection leaves the frontend out: the gate is about its committed manifest.
if [[ $FRONTEND_SELECTED == true ]]; then
    echo "Checking pinned frontend dependencies..."
    python3 "$DEVKIT/scripts/java/check_frontend_deps.py" "$FRONTEND_DIR"
fi

echo "Lint checks completed."
