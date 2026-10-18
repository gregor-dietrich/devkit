#!/usr/bin/env bash
# Tests for what make/*.mk promise a consumer's Makefile (docs/contract.md,
# "Make"), offline: the real make/ files run in a temp project whose DEVKIT is
# a stub tree, with scripts/python/test.sh a stub that prints "devkit test
# ran". The project Makefile is the uv skeleton's shape plus extra lines each
# case supplies (lang=java-maven swaps in the Java file, which only includes).
# Covered: a profile variable inherited from the environment never counts
# (JAVA_VERSION and FRONTEND_DIR only in a Java project), a command-line one
# does (under make gate only the Makefile's value counts, even a command-line
# or make -e one), and a profile line that reads the earlier value takes the
# environment's; an added prerequisite runs first and, failing, stops the
# target and no help entry appears; recipes and $(shell) run under bash
# outside POSIX mode despite SHELL in the environment or set before the
# includes (replaced); a SHELL on the command line, after the includes or
# set with override before them wins. A probe target prints "probe ran", then
# fails unless its recipe runs under bash outside POSIX mode; the failing
# cases require that marker, so only the probe's own test can fail them.
# Prints PASS/FAIL per check.
set -euo pipefail
# What common.mk exports, so an outer make's (devkit's own make gate) values
# reach no case: under make -e its DEVKIT and profile values would win over the
# project Makefile's.
unset PROJECT_ROOT PROJECT JAVA_VERSION MODULES FRONTEND_DIR COVERAGE_FLOOR ONLY DEVKIT

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
stub=$work/devkit
proj=$work/proj
fails=0

mkdir -p "$stub/scripts/python" "$proj"
ln -s "$root/make" "$stub/make"
# shellcheck disable=SC2016 # the stub expands MODULES, not this shell
printf '#!/usr/bin/env bash\necho "devkit test ran"\necho "modules=${MODULES-unset}"\n' >"$stub/scripts/python/test.sh"
chmod +x "$stub/scripts/python/test.sh"
# make gate runs the real gate.sh, whose lint-repo stages are no-ops here.
ln -s "$root/scripts/gate.sh" "$stub/scripts/gate.sh"
for s in devkitw pins decisions secrets markdown; do
  printf '#!/usr/bin/env bash\n' >"$stub/scripts/$s.sh"
  chmod +x "$stub/scripts/$s.sh"
done
ln -s "$stub" "$proj/.devkit"

# [lang=java-maven] [bare=1] [before=LINE] write_makefile [LINE...]: the skeleton (bare=1 omits the
# MODULES and COVERAGE_FLOOR lines) with the optional before
# line ahead of the includes, then LINEs (one per argument) after them.
write_makefile() {
  {
    printf '%s\n' "PROJECT := demo" "DEVKIT := $stub"
    [[ -n ${bare:-} ]] || printf '%s\n' "MODULES :=" "COVERAGE_FLOOR := 90"
    [[ -z ${before:-} ]] || printf '%s\n' "$before"
    printf '%s\n' "include .devkit/make/common.mk" "include .devkit/make/${lang:-python-uv}.mk" \
      "probe:" $'\t@echo "probe ran"; [[ -n $${BASH_VERSION:-} ]] && ! shopt -oq posix' \
      "prof:" $'\t@echo "prof=$(MODULES)|$(FRONTEND_DIR)|$(JAVA_VERSION)|$(COVERAGE_FLOOR)"'
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

# An inherited profile value never counts; a command-line one does. MODULES and
# COVERAGE_FLOOR in a uv project, MODULES, FRONTEND_DIR and JAVA_VERSION in a
# Java one; a uv project's recipes still see an inherited JAVA_VERSION and
# FRONTEND_DIR, which only the Java scripts read.
bare=1 write_makefile
MODULES=m FRONTEND_DIR=f JAVA_VERSION=21 COVERAGE_FLOOR=80 run_make prof
expect "inherited MODULES and COVERAGE_FLOOR are empty for a bare uv Makefile" has "prof=|f|21|"
run_make prof MODULES=m FRONTEND_DIR=f JAVA_VERSION=21 COVERAGE_FLOOR=80
expect "command-line profile values are kept" has "prof=m|f|21|80"
MODULES=m FRONTEND_DIR=f JAVA_VERSION=21 COVERAGE_FLOOR=80 run_make -e prof
expect "make -e keeps inherited profile values" has "prof=m|f|21|80"
bare=1 before=$'MODULES := a\nCOVERAGE_FLOOR := 90' write_makefile
MODULES=m COVERAGE_FLOOR=80 run_make prof
expect "the Makefile's profile values win over inherited ones" has "prof=a|||90"

lang=java-maven bare=1 write_makefile
MODULES=m FRONTEND_DIR=f JAVA_VERSION=21 run_make prof
expect "inherited profile values are empty for a bare Java Makefile" has "prof=|||"
FRONTEND_DIR=f run_make prof
expect "an inherited FRONTEND_DIR is empty for a Java Makefile" has "prof=|||"
JAVA_VERSION=21 run_make prof
expect "an inherited JAVA_VERSION is empty for a Java Makefile" has "prof=|||"
run_make prof MODULES=m FRONTEND_DIR=f JAVA_VERSION=21
expect "command-line Java profile values are kept" has "prof=m|f|21|"
MODULES=m FRONTEND_DIR=f JAVA_VERSION=21 run_make -e prof
expect "make -e keeps inherited Java profile values" has "prof=m|f|21|"
lang=java-maven bare=1 before=$'MODULES := a\nFRONTEND_DIR := b\nJAVA_VERSION := 25' write_makefile
MODULES=m FRONTEND_DIR=f JAVA_VERSION=21 run_make prof
expect "the Makefile's Java profile values win over inherited ones" has "prof=a|b|25|"

# Under make gate the inner make sees the outer command-line value as an
# inherited one, so only the Makefile's counts. MODULES is exported, so a
# bare Makefile's stage sees it set but empty.
bare=1 before='MODULES := a' write_makefile
run_make test MODULES=x
expect "a command-line MODULES counts for make test" has "modules=x"
run_make gate MODULES=x
expect "make gate ignores a command-line MODULES for the Makefile's" has "modules=a"
MODULES=x run_make -e gate
expect "make gate ignores make -e's MODULES for the Makefile's" has "modules=a"
bare=1 write_makefile
run_make gate MODULES=x
expect "make gate empties a command-line MODULES the Makefile does not set" has "modules="

# An inherited PROJECT_ROOT never counts, not even under make -e; a
# command-line one and a project's line after the include do.
write_makefile "root:" $'\t@echo "root=$(PROJECT_ROOT)"'
here=$(cd "$proj" && pwd -P)
PROJECT_ROOT=/elsewhere run_make -e root
expect "make -e ignores an inherited PROJECT_ROOT" has "root=$here"
run_make root PROJECT_ROOT=/elsewhere
expect "a command-line PROJECT_ROOT counts" has "root=/elsewhere"
write_makefile "PROJECT_ROOT := /mine" "root:" $'\t@echo "root=$(PROJECT_ROOT)"'
run_make root
expect "a project's PROJECT_ROOT line after the include counts" has "root=/mine"
PROJECT_ROOT=/elsewhere run_make -e root
expect "make -e with an inherited PROJECT_ROOT gives the project directory, not the inherited value" has "root=$here"

# A line that reads the earlier value takes the environment's, so the docs say
# to assign with := alone.
bare=1 before='MODULES += a' write_makefile
MODULES=b run_make prof
expect "MODULES += a over an inherited MODULES=b yields b a" has "prof=b a|||"

((fails == 0))
