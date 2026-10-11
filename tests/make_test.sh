#!/usr/bin/env bash
# Tests for what make/*.mk promise a consumer's Makefile (docs/contract.md,
# "Make"), offline: the real make/ files run in a temp project whose DEVKIT is
# a stub tree, with scripts/python/test.sh a stub that prints "devkit test
# ran". The project Makefile is the uv skeleton's shape plus extra lines each
# case supplies. Covered: an added prerequisite runs first and, failing, stops
# the target and no help entry appears; recipes and $(shell) run under bash
# outside POSIX mode despite SHELL in the environment or set before the
# includes (replaced); a SHELL on the command line, after the includes or
# set with override before them wins. A probe target prints "probe ran", then
# fails unless its recipe runs under bash outside POSIX mode; the failing
# cases require that marker, so only the probe's own test can fail them.
# Prints PASS/FAIL per check.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
stub=$work/devkit
proj=$work/proj
fails=0

mkdir -p "$stub/scripts/python" "$proj"
ln -s "$root/make" "$stub/make"
printf '#!/usr/bin/env bash\necho "devkit test ran"\n' >"$stub/scripts/python/test.sh"
chmod +x "$stub/scripts/python/test.sh"
ln -s "$stub" "$proj/.devkit"

# [before=LINE] write_makefile [LINE...]: the skeleton with the optional before
# line ahead of the includes, then LINEs (one per argument) after them.
write_makefile() {
  {
    printf '%s\n' "PROJECT := demo" "MODULES :=" "COVERAGE_FLOOR := 90" "DEVKIT := $stub"
    [[ -z ${before:-} ]] || printf '%s\n' "$before"
    printf '%s\n' "include .devkit/make/common.mk" "include .devkit/make/python-uv.mk" \
      "probe:" $'\t@echo "probe ran"; [[ -n $${BASH_VERSION:-} ]] && ! shopt -oq posix'
    (($# == 0)) || printf '%s\n' "$@"
  } >"$proj/Makefile"
}

# run_make ARGS...: make in the project with an outer make's state cleared (as devkit's own `test` does);
# sets out and rc.
run_make() {
  rc=0
  out=$(env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEFILES \
    -u SHELLOPTS -u POSIXLY_CORRECT -u BASH_ENV make -C "$proj" "$@" 2>&1) || rc=$?
}

expect() { # expect DESCRIPTION COMMAND...: PASS when COMMAND succeeds
  local desc=$1
  shift
  if "$@"; then echo "PASS $desc"; else echo "FAIL $desc" && fails=$((fails + 1)); fi
}
ran_before() { # ran_before A B: both lines are in $out, A first
  local a b
  a=$(grep -nxF "$1" <<<"$out" | head -n1 | cut -d: -f1)
  b=$(grep -nxF "$2" <<<"$out" | head -n1 | cut -d: -f1)
  [[ -n $a && -n $b ]] && ((a < b))
}
made_ok() { ((rc == 0)); }
made_fail() { ((rc != 0)); }
has() { grep -qxF "$1" <<<"$out"; }
lacks() { ! has "$1"; }
probe_failed() { made_fail && has "probe ran"; } # failed in the probe's test, not elsewhere
lists_once() { (($(grep -cE "^  make $1 +-" <<<"$out") == 1)); }

# An added prerequisite runs before devkit's recipe.
write_makefile "test: extra" "extra:" $'\t@echo "extra ran"'
run_make test
expect "make test passes with an added prerequisite" made_ok
expect "the added prerequisite runs before devkit's recipe" ran_before "extra ran" "devkit test ran"

# A failing one fails the target before devkit's recipe runs.
write_makefile "test: extra" "extra:" $'\t@echo "extra failed"; exit 1'
run_make test
expect "make test fails when an added prerequisite fails" made_fail
expect "it failed in that prerequisite" has "extra failed"
expect "devkit's recipe does not run after it" lacks "devkit test ran"

# A prerequisite-only rule line adds no help entry.
write_makefile "test: extra" "extra:" $'\t@echo "extra ran"'
run_make help
expect "make help lists test exactly once" lists_once test

# Recipes run under bash, even with SHELL in the environment.
write_makefile
run_make probe
expect "make probe passes (recipes run under bash)" made_ok
SHELL=/bin/sh run_make probe
expect "make probe passes with SHELL=/bin/sh in the environment" made_ok

# The probe discriminates, and the project's own SHELL wins.
run_make probe SHELL=/bin/sh
expect "make probe fails with SHELL=/bin/sh on the command line" probe_failed
write_makefile "SHELL := /bin/sh"
run_make probe
expect "make probe fails when the project sets SHELL after the includes" probe_failed

# A SHELL set before the includes is replaced; override keeps it.
before="SHELL := /bin/sh" write_makefile
run_make probe
expect "make probe passes when the project sets SHELL before the includes" made_ok
before="override SHELL := /bin/sh" write_makefile
run_make probe
expect "make probe fails when the project overrides SHELL before the includes" probe_failed

# A $(shell) expanded after the includes runs under bash outside POSIX mode too.
# shellcheck disable=SC2016 # make's $$, not the shell's
write_makefile 'X := $(shell [[ -n $${BASH_VERSION:-} ]] && ! shopt -oq posix && echo bash)' 'show:' $'\t@echo "bash=$(X)"'
run_make show
expect "\$(shell) after the includes runs under bash" has "bash=bash"

((fails == 0))
