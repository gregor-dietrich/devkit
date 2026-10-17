#!/usr/bin/env bash
# Tests for the rule of docs/contract.md ("every helper runs with python3 -I"):
# every command that runs python3 or a venv's python in scripts/, make/ and
# devkitw (python3 SCRIPT, python3 -m, python3 -c, "$VENV/bin/python" ...) has -I
# as its first argument, so that no PYTHON* variable, user site or working
# directory reaches it. A call without it must fail, naming file:line; the check
# is shown to see each shape on scratch copies of the tree. Prints PASS/FAIL per
# case. No network.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

# calls DIR: every python invocation under DIR (scripts, make, devkitw), as file:line:text. A
# command is python3 or a path ending /bin/python, quoted or not, at the start of a line or after
# | ; & ( ! exec then do else, so that a word in an echoed message is not one.
calls() {
  (cd "$1" && grep -rnE --exclude-dir=__pycache__ --exclude='*.py' \
    "(^[[:space:]]*|[|;&(!][[:space:]]*|(exec|then|do|else)[[:space:]]+)(python3|\"?[^[:space:]\"]*/bin/python\"?)([[:space:]]|\$)" \
    scripts make devkitw)
}

# unisolated DIR: the invocations under DIR whose first argument is not -I, one per line; fails
# when there are none to check (the pattern stopped matching) or any lacks -I
unisolated() {
  local all bad
  all=$(calls "$1") || { echo "no python invocation found under $1: update this check"; return 1; }
  [[ $(wc -l <<<"$all") -ge 15 ]] || { echo "only $(wc -l <<<"$all") python invocations found: update this check"; return 1; }
  bad=$(grep -vE '(python3|/bin/python"?) -I([[:space:]]|$)' <<<"$all") || return 0
  printf '%s\n' "$bad"
  return 1
}

# result LABEL WANT-STATUS WANT-TEXT DIR: unisolated DIR exits WANT-STATUS, printing WANT-TEXT
result() {
  local out rc=0
  out=$(unisolated "$4") || rc=$?
  if [[ $rc == "$2" && $out == *"$3"* ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: exit $rc, want $2 and '$3' in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

# broken LABEL FILE SED TEXT: a scratch copy of the tree with FILE run through SED (which must
# change it) fails, naming FILE:line and TEXT; the copy is never the repository
broken() {
  local copy=$work/copy-${1//[^a-z]/-} line
  mkdir -p "$copy"
  cp -R "$root/scripts" "$root/make" "$root/devkitw" "$copy/"
  sed "$3" "$copy/$2" >"$copy/$2.new"
  if cmp -s "$copy/$2" "$copy/$2.new"; then
    echo "FAIL $1: the sed changed nothing in $2"
    fails=$((fails + 1))
    return
  fi
  cat "$copy/$2.new" >"$copy/$2"
  rm "$copy/$2.new"
  line=$(grep -nF "$4" "$copy/$2" | head -n 1 | cut -d: -f1)
  result "$1" 1 "$2:$line:" "$copy"
}

result "every python invocation of scripts/, make/ and devkitw has -I" 0 "" "$root"
broken "a python3 SCRIPT call without -I fails" scripts/pins.sh 's/python3 -I /python3 /' 'python3 '
broken "a python3 -c call without -I fails" scripts/lib/node_closure.sh 's/python3 -I -c/python3 -c/' 'python3 -c'
broken "a python3 -m call without -I fails" scripts/lib/get_uv.sh 's/python3 -I -m venv/python3 -m venv/' 'python3 -m venv'
broken "a venv python call without -I fails" scripts/python/lint.sh 's|bin/python" -I -S|bin/python" -S|' 'bin/python" -S'
broken "a venv python -m call without -I fails" scripts/lib/get_uv.sh 's|venv/bin/python" -I -m|venv/bin/python" -m|' 'venv/bin/python" -m'
broken "a call after a pipe without -I fails" scripts/markdown.sh 's/| python3 -I /| python3 /' '| python3 '
# shellcheck disable=SC2016 # the $( is literal
broken "a call in a command substitution without -I fails" scripts/python/check.sh 's/members=[$](python3 -I /members=$(python3 /' 'members=$(python3'

[[ $fails == 0 ]]
