#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

# NVD API key: environment first, else the gitignored .env.build (kept out of .env, which docker-compose
# hands to the app container). Sourced, so `export`, quotes and comments behave as in any shell file.
if [[ -z "${NVD_API_KEY:-}" && -f .env.build ]]; then
    # shellcheck source=/dev/null
    . ./.env.build
fi
NVD_API_KEY=${NVD_API_KEY:-}
NVD_API_KEY=${NVD_API_KEY%$'\r'}
export NVD_API_KEY
[[ -n "$NVD_API_KEY" ]] || echo "WARNING: NVD_API_KEY not set (environment or .env.build); the NVD download will be very slow."

echo "Running OWASP dependency-check..."

"${MVN_CMD}" org.owasp:dependency-check-maven:check

echo "Dependency-check completed. Report: target/dependency-check-report.html"
