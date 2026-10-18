#!/usr/bin/env bash
# Tests for scripts/python/audit.sh: a stand-in devkit (get_uv.sh names a stub uv that writes a
# requirements file; audit.py and its helpers are the real ones) and a temp project whose .venv
# holds a stub pip-audit. The stub logs its arguments, writes $PYPI_JSON or $OSV_JSON to its -o
# path and exits per service. Asserts both runs happen, in order, with their flags, that either
# failing fails the target while the other still runs, that devkit.toml's accepted advisories
# are judged (and validated before pip-audit runs). No network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
proj=$work/proj fake=$work/devkit log=$work/log fails=0
mkdir -p "$proj/.venv/bin" "$fake/scripts/lib" "$fake/scripts/python"
cp "$root/scripts/lib/get_venv.sh" "$fake/scripts/lib/"
cp "$root/scripts/python/audit.py" "$root/scripts/python/project_files.py" "$fake/scripts/python/"
# shellcheck disable=SC2016 # expands when the stub runs
{
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --output-file ] && echo "${UV_REQ-six==1.16.0}" >"$2"; shift; done\n' >"$work/uv"
  printf 'UV_CMD=%q\n' "$work/uv" >"$fake/scripts/lib/get_uv.sh"
  cat >"$proj/.venv/bin/pip-audit" <<STUB
#!/bin/sh
echo "\$*" | sed "s|-o [^ ]*|-o OUT|; s|-r .*|-r REQ|" >>"$log"
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; [ "\$1" = -s ] && service=\$2; shift; done
[ "\$service" = pypi ] && { printf '%s' "\$PYPI_JSON" >"\$out"; exit "\${PYPI_RC:-0}"; }
[ "\$service" = osv ] && { printf '%s' "\$OSV_JSON" >"\$out"; exit "\${OSV_RC:-0}"; }
exit 99
STUB
}
printf '#!/bin/sh\nexit 0\n' >"$proj/.venv/bin/python"
chmod +x "$work/uv" "$proj/.venv/bin/pip-audit" "$proj/.venv/bin/python"

CLEAN='{"dependencies": [{"name": "six", "version": "1.16.0", "vulns": []}]}'
# One finding, as pip-audit 2.10.1 writes it with --aliases on.
FOUND='{"dependencies": [{"name": "jinja2", "version": "3.1.4", "vulns": [{"id": "PYSEC-2026-1472", "fix_versions": ["3.1.5"], "aliases": ["CVE-2024-56201", "GHSA-gmj6-6f8f-6699"]}]}]}'
export PYPI_JSON=$CLEAN OSV_JSON=$CLEAN
ENTRY='[[python.audit.accepted]]
package = "jinja2"
id = "GHSA-gmj6-6f8f-6699"
reason = "not reachable here"'
printf '[python.duplication]\npaths = ["src"]\n' >"$proj/devkit.toml"

# expect LABEL WANT-RC WANT-LOG PYPI-RC OSV-RC [WANT-TEXT...]: the log holds exactly WANT-LOG, lines
# split by "|", and the output every WANT-TEXT
expect() {
  local rc=0 want out text ok=true
  : >"$log"
  out=$(PROJECT_ROOT=$proj DEVKIT=$fake PYPI_RC=$4 OSV_RC=$5 "$root/scripts/python/audit.sh" 2>&1) || rc=$?
  want=$(printf '%s' "$3" | tr '|' '\n')
  for text in "${@:6}"; do [[ $out == *"$text"* ]] || ok=false; done
  if [[ $rc == "$2" && $(<"$log") == "$want" && $ok == true ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: exit $rc, want $2; log:"
    cat "$log"
    echo "output:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

flags='--strict --no-deps --disable-pip -f json --aliases on --desc off -o OUT -r REQ'
both="-s pypi $flags|-s osv $flags"
expect "both services pass: the target passes, pypi then osv, with their flags" 0 "$both" 0 0
expect "the PyPI run alone fails: the target fails and osv still runs" 1 "$both" 1 0
expect "the OSV run alone fails: the target fails" 1 "$both" 0 1
expect "both fail: the target fails" 1 "$both" 1 1
expect "a clean run says it completed" 0 "$both" 0 0 "Audit completed."

PYPI_JSON=$FOUND OSV_JSON=$FOUND
expect "findings no entry accepts fail the target, both services still run" 1 "$both" 1 1 "reported by osv and pypi, not accepted in devkit.toml"
printf '%s\n' "$ENTRY" >>"$proj/devkit.toml"
expect "an entry by an alias accepts the findings, printing its reason" 0 "$both" 1 1 "not reachable here"
PYPI_JSON=$CLEAN OSV_JSON=$CLEAN
expect "an entry nothing reports is stale" 1 "$both" 0 0 "stale [[python.audit.accepted]] entry"
PYPI_JSON=$FOUND OSV_JSON=$CLEAN
expect "an entry one service reports is not stale" 0 "$both" 1 0 "Audit completed."
PYPI_JSON='{"dependencies": [{"name": "mako", "version": "1.4.1", "vulns": [{"id": "PYSEC-2026-4243", "fix_versions": [], "aliases": []}]}]}' OSV_JSON='' \
  expect "an empty OSV report fails the target, and the PyPI finding no entry accepts still prints" 1 "$both" 1 1 \
  "pip-audit against osv (exit 1) left no readable report" "mako 1.4.1: PYSEC-2026-4243 (no fixed version) reported by pypi, not accepted"
UV_REQ='# nothing' expect "no runtime dependencies: pip-audit never runs and the entry is stale" 1 "" 0 0 "stale [[python.audit.accepted]] entry"
printf '[python.duplication]\npaths = ["src"]\n[[python.audit.accepted]]\npackage = "jinja2"\nid = "GHSA-x-y"\nreason = " "\n' >"$proj/devkit.toml"
expect "an invalid entry fails before pip-audit runs" 1 "" 0 0 "needs a reason"
printf '[python.duplication]\npaths = ["src"]\n' >"$proj/devkit.toml"
UV_REQ='# nothing' expect "no runtime dependencies and no entry: the target passes without pip-audit" 0 "" 0 0 "nothing to audit"

[[ $fails == 0 ]]
