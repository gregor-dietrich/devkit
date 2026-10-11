#!/bin/bash

# devkit's own `make audit`: audit the npm closures devkit pins (markdown/, jscpd/) against
# the advisory database, which no consumer target does: closure_audit.sh DIR..., each DIR
# holding a package.json and a package-lock.json. Runs `npm audit` on a copy of those two
# files, installing nothing, then scripts/closure_audit.py judges the report against
# DIR/audit-ignore, if there is one. Every DIR is audited; the exit status is 1 if any
# failed, 2 for no DIR. Needs npm on PATH, python3 3.11 or later and the npm registry.
set -euo pipefail

(($#)) || {
    echo "usage: closure_audit.sh DIR..." >&2
    exit 2
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=SCRIPTDIR/lib/python.sh
. "$root/scripts/lib/python.sh"
python3_floor
command -v npm >/dev/null || {
    echo "ERROR: npm not found; the closure audit needs npm on PATH." >&2
    exit 1
}
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
trap 'exit 1' HUP INT TERM

failed=0 n=0
for dir; do
    # A report file per DIR: one npm never wrote, say when the copy failed, is empty and fails
    # closed rather than being judged as the previous DIR's.
    report=$tmp/$((n += 1)).json
    : >"$report"
    # npm runs in a copy of the two files, named as DIR is, so a .npmrc beside the lockfile is
    # never read; --offline=false and --registry beat the rest of npm's config (user, env), so
    # none of it chooses whether or where the advisories are looked up. npm's exit status says
    # "vulnerable", "failed" or both; closure_audit.py judges the report. --include=optional
    # beats an omit=optional in the user's npm config: jscpd's binary is an optional,
    # per-platform dependency (lib/node_closure.sh). --include=peer likewise for peer ones.
    stage=$tmp/$n/$(basename "$dir")
    (mkdir -p "$stage" && cp "$dir/package.json" "$dir/package-lock.json" "$stage/" &&
        cd "$stage" && NPM_CONFIG_UPDATE_NOTIFIER=false npm audit --json --package-lock-only \
        --offline=false --registry=https://registry.npmjs.org/ --include=optional --include=peer \
        --loglevel=error >"$report") || :
    python3 -I "$root/scripts/closure_audit.py" "$(basename "$dir")" "$report" "$dir/audit-ignore" || failed=1
done
exit "$failed"
