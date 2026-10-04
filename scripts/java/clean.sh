#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/select_modules.sh
. "$DEVKIT/scripts/lib/select_modules.sh"
# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

REVISION=${REVISION:-1.0.0-SNAPSHOT}

echo "Starting clean${ONLY:+ for $ONLY}..."

"${MVN_CMD}" -q clean ${ONLY:+-pl "$ONLY"} -Drevision="${REVISION}"

# What mvn clean leaves behind: Quarkus file logs and the Vaadin frontend build output.
for module in $SELECTED; do
    rm -rf "$module/logs"
done
if [[ $FRONTEND_SELECTED == true ]]; then
    rm -rf "$FRONTEND_DIR/node_modules" "$FRONTEND_DIR/src/main/frontend/generated"
fi

echo "Clean completed."
