#!/bin/bash

set -euo pipefail

# Check the uv project at the project root; each failure is one ERROR line with its remedy.
cd "$PROJECT_ROOT"

echo "Running uv project checks..."

# shellcheck source=SCRIPTDIR/../lib/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor || exit 1

if [[ -z ${COVERAGE_FLOOR:-} ]]; then
    echo "ERROR: COVERAGE_FLOOR is not set; set it in the project Makefile to the percent each package's tests must cover, e.g. COVERAGE_FLOOR := 90." >&2
    exit 1
elif [[ ! $COVERAGE_FLOOR =~ ^(100(\.0+)?|[0-9]{1,2}(\.[0-9]+)?)$ ]]; then # as coverage_floor.py's FLOOR
    echo "ERROR: COVERAGE_FLOOR '$COVERAGE_FLOOR' is not a percent from 0 to 100; fix it in the project Makefile." >&2
    exit 1
fi

if [[ ! -f .python-version ]]; then
    echo "ERROR: no .python-version at the project root; add one holding the CPython version, e.g. 3.13." >&2
    exit 1
fi
pin=$(< .python-version)
# Only edge whitespace is trimmed: a pin spanning two lines must fail, not join.
pin=${pin#"${pin%%[![:space:]]*}"} pin=${pin%"${pin##*[![:space:]]}"}
if [[ ! $pin =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$ ]]; then
    printf 'ERROR: .python-version must hold a CPython major.minor or major.minor.patch version, e.g. 3.13, not %q.\n' "$pin" >&2
    exit 1
fi
pin_minor=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}

members=$(python3 "$DEVKIT/scripts/python/uv_project.py" members) || exit 1
if [[ ${MODULES:-} == *[*?[]* ]]; then
    echo "ERROR: MODULES ($MODULES) holds a glob character; MODULES lists member directories, not globs." >&2
    exit 1
fi
read -ra entries <<< "${MODULES:-.}"
modules=$(printf '%s\n' "${entries[@]}" | LC_ALL=C sort -u)
if [[ $(LC_ALL=C sort -u <<< "$members") != "$modules" ]]; then
    echo "ERROR: MODULES (${MODULES:-empty: a single package}) differs from the packages uv.lock records (${members//$'\n'/ }); set MODULES to the workspace member directories, or empty for a single package at the root." >&2
    exit 1
fi

python3 "$DEVKIT/scripts/python/duplication.py" check-config
python3 "$DEVKIT/scripts/python/uv_project.py" vulture-paths > /dev/null

# shellcheck source=SCRIPTDIR/../lib/get_uv.sh
UV_BOOTSTRAP=false . "$DEVKIT/scripts/lib/get_uv.sh"
echo "uv: $UV_CMD ($UV_PIN)"
# shellcheck source=SCRIPTDIR/../lib/get_venv.sh
. "$DEVKIT/scripts/lib/get_venv.sh"

venv_version=$("$VENV/bin/python" -I -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])') || {
    echo "ERROR: .venv/bin/python does not run; run make install." >&2
    exit 1
}
# A patch pin binds too: uv's sync --check below rejects a .venv of another patch.
if [[ ${venv_version%.*} != "$pin_minor" || ($pin == *.*.* && $venv_version != "$pin") ]]; then
    echo "ERROR: .venv runs Python $venv_version, but .python-version pins $pin; run make install." >&2
    exit 1
fi
echo "Python: .venv runs $venv_version (.python-version: $pin)"

if ! sync_out=$("$UV_CMD" sync --check --frozen --offline --all-packages --all-extras 2>&1); then
    echo "ERROR: uv cannot confirm .venv matches uv.lock. It reported:" >&2
    echo "    ${sync_out//$'\n'/$'\n'    }" >&2
    echo "If that is drift, run make install; an unreadable uv.lock or unwritable cache is its own fix." >&2
    exit 1
fi
echo ".venv matches uv.lock."

for tool in ruff pytest vulture pip-audit; do
    venv_tool "$tool" > /dev/null
done
"$VENV/bin/python" -I -c 'import pytest_cov' 2> /dev/null || {
    echo "ERROR: .venv has no pytest_cov; add pytest-cov to the dev dependency group, then uv lock and make install." >&2
    exit 1
}

echo "uv project checks passed."
