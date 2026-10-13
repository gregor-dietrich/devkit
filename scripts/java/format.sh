#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/select_modules.sh
. "$DEVKIT/scripts/lib/select_modules.sh"
# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

REVISION=${REVISION:-1.0.0-SNAPSHOT}

echo "Formatting Java sources${ONLY:+ in $ONLY}..."

# Run Maven from the root using the reactor; ONLY narrows it with -pl
# Named groupId:artifactId, not by prefix, as lint.sh explains.
"${MVN_CMD}" -q com.diffplug.spotless:spotless-maven-plugin:apply ${ONLY:+-pl "$ONLY"} -Drevision="${REVISION}"

echo "Java source formatting completed."
