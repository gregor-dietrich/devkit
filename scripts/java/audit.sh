#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"

# NVD API key: environment first, else the gitignored .env.build (kept out of .env, which docker-compose
# hands to the app container). Sourced, so `export`, quotes and comments behave as in any shell file.
if [[ -z "${NVD_API_KEY:-}" && -f .env.build ]]; then
    # shellcheck source=/dev/null
    . ./.env.build
fi
NVD_API_KEY=${NVD_API_KEY:-}
NVD_API_KEY=${NVD_API_KEY%$'\r'}
export NVD_API_KEY
# dependency-check rejects an empty key ("Invalid API Key, length of 0"), so fail before Maven starts.
[[ -n "$NVD_API_KEY" ]] || {
    echo "ERROR: NVD_API_KEY not set (environment or .env.build); request one at https://nvd.nist.gov/developers/request-an-api-key" >&2
    exit 1
}

# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

echo "Running OWASP dependency-check..."

"${MVN_CMD}" org.owasp:dependency-check-maven:check

echo "Dependency-check completed. Report: target/dependency-check-report.html"
