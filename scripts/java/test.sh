#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

REVISION=${REVISION:-1.0.0-SNAPSHOT}

echo "Starting tests${ONLY:+ for $ONLY}..."

# Run Maven from the root using the reactor; ONLY narrows it with -pl
"${MVN_CMD}" -q verify ${ONLY:+-pl "$ONLY"} -Dquarkus.log.console.enabled=false -Dquarkus.log.file.enabled=false -Drevision="${REVISION}"

echo "Tests completed."
