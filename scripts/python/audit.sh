#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/get_uv.sh
UV_BOOTSTRAP=false . "$DEVKIT/scripts/lib/get_uv.sh"
# shellcheck source=SCRIPTDIR/../lib/get_venv.sh
. "$DEVKIT/scripts/lib/get_venv.sh"
pip_audit=$(venv_tool pip-audit)
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT

audit=$DEVKIT/scripts/python/audit.py
# The accepted advisories are validated before any network call.
python3 -I "$audit" check-config

echo "Exporting the runtime dependencies uv.lock pins..."
# Third-party runtime dependencies only: no dependency group, none of the project's own
# packages, no local path dependency (pip-audit refuses a path it cannot hash; what it depends
# on stays).
"$UV_CMD" export --frozen --no-default-groups --all-packages --all-extras --no-emit-project \
    --no-emit-workspace --no-emit-local --format requirements.txt --quiet --output-file "$tmp/requirements.txt"
if ! grep -q '^[A-Za-z0-9]' "$tmp/requirements.txt"; then
    echo "No third-party runtime dependencies in uv.lock; nothing to audit."
    # Every accepted entry is stale now.
    python3 -I "$audit" judge
    echo "Audit completed."
    exit 0
fi

echo "Running pip-audit (needs the network)..."
# Both services, always both so that each report is read: PyPI's advisory data omits advisories
# OSV carries, and OSV cannot tell an unknown package from a clean one, so only PyPI's --strict
# fails closed on a dependency that cannot be audited. Each writes a JSON report (its exit status
# 1 means findings, which audit.py judges against devkit.toml's accepted advisories; its own
# output is then only progress and a count), and audit.py prints the findings.
# --strict: a dependency pip-audit could not audit fails the run instead of passing with a warning.
reports=()
for service in pypi osv; do
    echo "Auditing against $service..."
    rc=0
    "$pip_audit" -s "$service" --strict --no-deps --disable-pip -f json --aliases on --desc off \
        -o "$tmp/$service.json" -r "$tmp/requirements.txt" || rc=$?
    reports+=("$service" "$rc" "$tmp/$service.json")
done
python3 -I "$audit" judge "${reports[@]}"

echo "Audit completed."
