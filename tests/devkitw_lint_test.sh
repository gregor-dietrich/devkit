#!/usr/bin/env bash
# Tests for scripts/devkitw.sh: per case, fresh temp directories for the project
# and the pinned devkit, each holding a devkitw. No network. Prints PASS/FAIL
# per case.
set -euo pipefail
unset PROJECT_ROOT DEVKIT # make test exports devkit's own; each case sets its pair

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
proj=$work/proj
pinned=$work/devkit
fails=0

# wrappers PROJECT-REVISION PINNED-REVISION: a devkitw in each directory, whose
# revision line is the given number, or absent for "none"; the bodies differ.
wrappers() {
  rm -rf "$proj" "$pinned"
  mkdir "$proj" "$pinned"
  local dir rev
  for dir in "$proj" "$pinned"; do
    rev=$1
    [[ $dir == "$proj" ]] || rev=$2
    {
      echo '#!/bin/sh'
      [[ $rev == none ]] || echo "# devkitw revision $rev"
      echo "echo ${dir##*/}"
    } >"$dir/devkitw"
  done
}

# expect LABEL WANT-STATUS WANT-TEXT...: run the check on $proj and $pinned (or
# the directories in $PROJECT_ROOT and $DEVKIT); the output must contain every
# WANT-TEXT, and be empty when there is none
expect() {
  local label=$1 want=$2 out rc=0 ok=true text
  shift 2
  out=$(PROJECT_ROOT=${PROJECT_ROOT:-$proj} DEVKIT=${DEVKIT:-$pinned} "$root/scripts/devkitw.sh" 2>&1) || rc=$?
  for text in "$@"; do [[ $out == *"$text"* ]] || ok=false; done
  [[ $# -gt 0 || -z $out ]] || ok=false
  if [[ $rc == "$want" && $ok == true ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and each of [$*] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

# one_line LABEL: the same check fails with exactly one line, starting ERROR:
one_line() {
  local out
  out=$(PROJECT_ROOT=${PROJECT_ROOT:-$proj} DEVKIT=${DEVKIT:-$pinned} "$root/scripts/devkitw.sh" 2>&1 || :)
  if [[ $out == ERROR:* && $out != *$'\n'* ]]; then echo "PASS $1"; else
    echo "FAIL $1: $out"
    fails=$((fails + 1))
  fi
}

wrappers 1 1
cp "$pinned/devkitw" "$proj/devkitw"
expect "identical files pass silently" 0

wrappers none 1
expect "a copy without the line is older than revision 1" 1 "ERROR: ./devkitw (revision 0) is older than the pinned devkit's (revision 1)" "cp .devkit/devkitw devkitw"
one_line "the failure is one line"

wrappers 2 1
expect "a higher project revision passes" 0

wrappers 1 1
expect "the same revision with different bytes fails" 1 "ERROR: ./devkitw differs from the pinned devkit's at the same revision 1" "raise its revision"
one_line "the same-revision failure is one line"

wrappers 1 2
expect "a lower project revision fails" 1 "(revision 1) is older than the pinned devkit's (revision 2)"

wrappers none none
expect "no line on either side, different bytes, fails" 1 "at the same revision 0"

wrappers 10 9
expect "revisions compare as numbers, not text" 0

wrappers 010 9
expect "a leading zero reads as decimal" 0

wrappers 1 2
printf '# devkitw revision 3\n' >>"$proj/devkitw"
expect "the first revision line counts" 1 "(revision 1) is older than"

wrappers none 1
printf '#!/bin/sh\n# devkitw revision 2\r\n' >"$proj/devkitw"
expect "a malformed revision line reads as 0" 1 "(revision 0) is older than"

wrappers 1 1
PROJECT_ROOT=$pinned expect "the same directory twice passes" 0

wrappers 1 1
rm "$pinned/devkitw"
expect "a missing pinned devkitw fails" 1 "ERROR: no readable devkitw at $pinned/devkitw"
one_line "a missing pinned devkitw fails with one line"

wrappers 1 1
rm "$proj/devkitw"
expect "a missing project devkitw fails" 1 "ERROR: no readable devkitw at $proj/devkitw"

if ((EUID == 0)); then
  echo "SKIP an unreadable pinned devkitw fails: root reads any file"
else
  wrappers 2 1
  chmod a-r "$pinned/devkitw"
  expect "an unreadable pinned devkitw fails" 1 "ERROR: no readable devkitw at $pinned/devkitw"
  one_line "an unreadable pinned devkitw fails with one line"
fi

wrappers none 1
echo "0123456789abcdef0123456789abcdef01234567 v9.9.9" >"$pinned/.devkit-commit"
expect "the version comes from .devkit-commit" 1 "is older than the pinned devkit v9.9.9's (revision 1)"

[[ $fails == 0 ]]
