#!/usr/bin/env bash
# Tests for scripts/python/audit.sh: a stand-in devkit whose get_uv.sh names a
# stub uv (it writes a requirements file) and a temp project whose .venv holds
# a stub pip-audit, which logs its arguments and exits per service. Asserts
# both runs happen, in order, with their flags, and that either failing fails
# the target while the other still runs. No network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
proj=$work/proj fake=$work/devkit log=$work/log fails=0
mkdir -p "$proj/.venv/bin" "$fake/scripts/lib"
cp "$root/scripts/lib/get_venv.sh" "$fake/scripts/lib/"
# shellcheck disable=SC2016 # expands when the stub runs
{
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --output-file ] && echo "six==1.16.0" >"$2"; shift; done\n' >"$work/uv"
  printf 'UV_CMD=%q\n' "$work/uv" >"$fake/scripts/lib/get_uv.sh"
  printf '#!/bin/sh\necho "$*" | sed "s|-r .*|-r REQ|" >>"%s"\n' "$log" >"$proj/.venv/bin/pip-audit"
  printf '[ "$2" = pypi ] && exit "${PYPI_RC:-0}"\n[ "$2" = osv ] && exit "${OSV_RC:-0}"\nexit 99\n' >>"$proj/.venv/bin/pip-audit"
}
printf '#!/bin/sh\nexit 0\n' >"$proj/.venv/bin/python"
chmod +x "$work/uv" "$proj/.venv/bin/pip-audit" "$proj/.venv/bin/python"

# expect LABEL WANT-RC WANT-LOG PYPI-RC OSV-RC: the log holds exactly WANT-LOG, lines split by "|"
expect() {
  local rc=0 want out
  : >"$log"
  out=$(PROJECT_ROOT=$proj DEVKIT=$fake PYPI_RC=$4 OSV_RC=$5 "$root/scripts/python/audit.sh" 2>&1) || rc=$?
  want=$(printf '%s' "$3" | tr '|' '\n')
  if [[ $rc == "$2" && $(<"$log") == "$want" ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: exit $rc, want $2; log:"
    cat "$log"
    echo "output:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

flags='--strict --no-deps --disable-pip -r REQ'
both="-s pypi $flags|-s osv $flags"
expect "both services pass: the target passes, pypi then osv, with their flags" 0 "$both" 0 0
expect "the PyPI run alone fails: the target fails and osv still runs" 1 "$both" 1 0
expect "the OSV run alone fails: the target fails" 1 "$both" 0 1
expect "both fail: the target fails" 1 "$both" 1 1

[[ $fails == 0 ]]
