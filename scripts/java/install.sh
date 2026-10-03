#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

REVISION=${REVISION:-1.0.0-SNAPSHOT}

echo "Starting install${ONLY:+ for $ONLY}..."

"${MVN_CMD}" -q clean install ${ONLY:+-pl "$ONLY"} -DskipTests -Drevision="${REVISION}"

# The Vaadin jars are resolved by the build above, which is what the gate reads.
if [[ -n "${FRONTEND_DIR:-}" && ( -z "${ONLY:-}" || ",$ONLY," == *",$FRONTEND_DIR,"* ) ]]; then
    python3 "$DEVKIT/scripts/java/check_frontend_deps.py" "$FRONTEND_DIR"
fi

echo "Install completed."
