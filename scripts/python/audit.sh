#!/bin/bash

set -euo pipefail

cd "$PROJECT_ROOT"
# shellcheck source=SCRIPTDIR/../lib/get_uv.sh
UV_BOOTSTRAP=false . "$DEVKIT/scripts/lib/get_uv.sh"
# pip-audit trusts the lock's certifi, not uv's bundle.
python3 -I "$DEVKIT/scripts/python/uv_project.py" certifi-versions >/dev/null
# shellcheck source=SCRIPTDIR/../lib/get_venv.sh
. "$DEVKIT/scripts/lib/get_venv.sh"
# For its remedy message only: pip-audit runs as python -m pip_audit below.
venv_tool pip-audit >/dev/null
venv_synced
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT

audit=$DEVKIT/scripts/python/audit.py
# The accepted advisories are validated before any network call.
python3 -I "$audit" check-config

echo "Exporting the runtime dependencies uv.lock pins..."
# Third-party runtime dependencies only: no dependency group, none of the project's own
# packages, no local path dependency (the project's own code, which pip-audit cannot audit
# against an index; what it depends on stays). A pylock.toml, which pip-audit --locked reads
# without evaluating environment markers: every package uv.lock pins is audited on every machine,
# one a marker restricts to another platform or Python too (pip-audit's -r source drops a
# requirement whose marker is false here). It goes in its own directory because --locked takes a
# directory and reads every pylock*.toml file in it.
mkdir "$tmp/lock"
"$UV_CMD" export --frozen --no-default-groups --all-packages --all-extras --no-emit-project \
    --no-emit-workspace --no-emit-local --format pylock.toml --quiet --output-file "$tmp/lock/pylock.toml"
# Validated before pip-audit runs (uv's export may already download artifacts whose hashes uv.lock
# lacks); a lock audit.py cannot use fails here.
pins=$(python3 -I "$audit" check-lock "$tmp/lock/pylock.toml")
if [[ $pins == 0 ]]; then
    echo "No third-party runtime dependencies in uv.lock; nothing to audit."
    # Every accepted entry is stale now.
    python3 -I "$audit" judge "$tmp/lock/pylock.toml"
    echo "Audit completed."
    exit 0
fi

echo "Running pip-audit over the $pins pinned package$([[ $pins == 1 ]] || echo s) (needs the network)..."
# Both services, always both so that each report is read: PyPI's advisory data omits advisories
# OSV carries, and OSV cannot tell an unknown package from a clean one, so only PyPI's --strict
# fails closed on a dependency that cannot be audited. Each writes a JSON report (its exit status
# 1 means findings, which audit.py judges against devkit.toml's accepted advisories; its own
# output is then only progress and a count), and audit.py prints the findings.
# --strict: a dependency pip-audit could not audit fails the run instead of passing with a warning.
# audit.py fails a report that leaves out a package of the export, in case a pip-audit evaluated
# markers after all.
# -I: no PYTHON* variable and no working directory reaches pip-audit's imports, so a PYTHONPATH
# certifi cannot shadow the one certifi-versions judged. A fresh --cache-dir: pip-audit's default
# cache is per user, shared across projects, and keeps PyPI responses (permanent redirects too)
# fetched under an older trust store.
reports=()
for service in pypi osv; do
    echo "Auditing against $service..."
    rc=0
    "$VENV/bin/python" -I -m pip_audit -s "$service" --cache-dir "$tmp/cache" --strict --locked -f json --aliases on --desc off \
        -o "$tmp/$service.json" "$tmp/lock" || rc=$?
    reports+=("$service" "$rc" "$tmp/$service.json")
done
python3 -I "$audit" judge "$tmp/lock/pylock.toml" "${reports[@]}"

echo "Audit completed."
