#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/select_modules.sh
. "$DEVKIT/scripts/lib/select_modules.sh"
# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

REVISION=${REVISION:-1.0.0-SNAPSHOT}

echo "Starting install${ONLY:+ for $ONLY}..."

"${MVN_CMD}" -q clean install ${ONLY:+-pl "$ONLY"} -DskipTests -Drevision="${REVISION}"

# The build above resolves vaadin-core-internal, which the gate reads; the gate resolves the bundle jar.
if [[ $FRONTEND_SELECTED == true ]]; then
    python3 "$DEVKIT/scripts/java/check_frontend_deps.py" "$FRONTEND_DIR"
fi

echo "Install completed."
