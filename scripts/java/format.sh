#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

REVISION=${REVISION:-1.0.0-SNAPSHOT}

echo "Formatting Java sources${ONLY:+ in $ONLY}..."

# Run Maven from the root using the reactor; ONLY narrows it with -pl
"${MVN_CMD}" -q spotless:apply ${ONLY:+-pl "$ONLY"} -Drevision="${REVISION}"

echo "Java source formatting completed."
