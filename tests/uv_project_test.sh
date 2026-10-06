#!/usr/bin/env bash
# Tests for scripts/python/uv_project.py: per case, a temp project whose
# uv.lock and pyproject.toml are synthetic, shaped as uv writes them (a
# single project has no [manifest] and its own package at "."; a workspace
# lists its members by name in [manifest] members, each a package whose
# source is its directory). No uv, no network. Prints PASS/FAIL per case.
set -euo pipefail

script=$(cd "$(dirname "$0")/.." && pwd)/scripts/python/uv_project.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
proj=$work/proj
mkdir "$proj"
fails=0
h1=$(printf '1%.0s' {1..64}) h2=$(printf '2%.0s' {1..64})

# lock BLOCK...: uv.lock, its header and then each BLOCK
lock() {
  printf 'version = 1\nrevision = 3\nrequires-python = ">=3.13"\n' >"$proj/uv.lock"
  printf '\n%s\n' "$@" >>"$proj/uv.lock"
}
# package NAME SOURCE: a [[package]] entry whose source table holds SOURCE
package() { printf '[[package]]\nname = "%s"\nversion = "0.1.0"\nsource = { %s }\n' "$1" "$2"; }
# uv HASH...: the uv entry, one wheel per HASH; "none" is a wheel without one
uv() {
  local hash field
  printf '[[package]]\nname = "uv"\nversion = "0.12.10"\nsource = { registry = "https://pypi.org/simple" }\nwheels = [\n'
  for hash; do
    field=", hash = \"sha256:$hash\""
    [[ $hash != none ]] || field=
    printf '    { url = "https://files.example.invalid/uv.whl"%s, size = 1 },\n' "$field"
  done
  printf ']\n'
}
# manifest NAME...: the [manifest] members
manifest() { printf '[manifest]\nmembers = [%s]\n' "$(printf '"%s", ' "$@")"; }
# pyproject BODY: pyproject.toml
pyproject() { printf '[project]\nname = "p"\n\n%s\n' "$1" >"$proj/pyproject.toml"; }

# expect LABEL WANT-STATUS WANT-TEXT COMMAND: on success the output equals
# WANT-TEXT; on failure it is one ERROR line containing it
expect() {
  local out rc=0
  out=$(PROJECT_ROOT=$proj python3 "$script" "$4" 2>&1) || rc=$?
  if [[ $rc == "$2" && $out != *Traceback* ]] &&
    if [[ $rc == 0 ]]; then [[ $out == "$3" ]]; else [[ $out == "ERROR: "*"$3"* && $out != *$'\n'* ]]; fi; then
    echo "PASS $1"
  else
    echo "FAIL $1: exit $rc, want $2 and '$3', got:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

single=$(package app 'virtual = "."')

# uv-version
lock "$single" "$(uv "$h1")"
expect "uv-version prints the locked uv's version" 0 "0.12.10" uv-version
lock "$single" $'[[package]]\nversion = "0.12.10"\nname = "uv"\nsource = { registry = "https://pypi.org/simple" }' \
  "$(package zzz 'registry = "https://pypi.org/simple"')"
expect "uv-version reads a uv entry whose version precedes its name" 0 "0.12.10" uv-version
lock "$single" "$(package uvicorn 'registry = "https://pypi.org/simple"')"
expect "a lock without a uv entry fails" 1 "uv.lock pins no uv package" uv-version
lock "$single" "$(uv "$h1")" "$(uv "$h2" | sed 's/0\.12\.10/0.13.0/')"
expect "two uv entries fail" 1 "uv.lock pins uv more than once (0.12.10, 0.13.0)" uv-version
lock "$single" "$(uv "$h1" | sed 's|^version = .*|version = "../0.1"|')"
expect "a uv version unfit for a path fails" 1 "no usable version" uv-version
rm "$proj/uv.lock"
expect "a missing uv.lock fails" 1 "no uv.lock in $proj" uv-version
echo '[[package]' >"$proj/uv.lock"
expect "a malformed uv.lock fails" 1 "cannot read uv.lock" uv-version

# uv-requirements
lock "$single" "$(uv "$h1" "$h2")"
expect "uv-requirements pins uv by every wheel hash" 0 \
  "uv==0.12.10 \\"$'\n'"    --hash=sha256:$h1 \\"$'\n'"    --hash=sha256:$h2" uv-requirements
lock "$single" "$(uv "$h1" none)"
expect "a wheel without a hash fails" 1 "no sha256 hash for every uv 0.12.10 wheel" uv-requirements
lock "$single" "$(uv)"
expect "a uv without wheels fails" 1 "no sha256 hash for every uv 0.12.10 wheel" uv-requirements

# members
lock "$single" "$(uv "$h1")"
expect "a single virtual project is ." 0 "." members
lock "$(package app 'editable = "."')" "$(package helper 'editable = "libs/helper"')"
expect "a single packaged project is ., its path dependency no member" 0 "." members
lock "$(manifest ws-core ws-app)" "$(package helper 'editable = "libs/helper"')" \
  "$(package ws-core 'virtual = "packages/core"')" "$(package ws-app 'editable = "packages/app"')"
expect "workspace members are listed sorted, a path dependency not" 0 $'packages/app\npackages/core' members
lock "$(manifest root ws-core)" "$(package root 'virtual = "."')" "$(package ws-core 'virtual = "packages/core"')"
expect "a root package beside the members fails" 1 "make the root virtual" members
lock "$(manifest ws-core ws-app)" "$(package ws-core 'virtual = "packages/core"')"
expect "a member without a package entry fails" 1 "lists workspace member ws-app but no package entry" members
lock "$(uv "$h1")"
expect "a lock without a project package fails" 1 "records no package of the project" members

# vulture-paths
pyproject $'[tool.vulture]\npaths = ["src", "tests"]'
expect "vulture-paths prints the paths" 0 $'src\ntests' vulture-paths
pyproject $'[tool.vulture]\nmin_confidence = 60'
expect "a [tool.vulture] without paths fails" 1 "sets no [tool.vulture] paths" vulture-paths
pyproject $'[tool.vulture]\npaths = []'
expect "empty vulture paths fail" 1 "sets no [tool.vulture] paths" vulture-paths
pyproject ''
expect "a pyproject.toml without [tool.vulture] fails" 1 "sets no [tool.vulture] paths" vulture-paths
rm "$proj/pyproject.toml"
expect "a missing pyproject.toml fails" 1 "no pyproject.toml in $proj" vulture-paths

rc=0
out=$(python3 "$script" frobnicate 2>&1) || rc=$?
if [[ $rc == 2 && $out == "usage: "* ]]; then
  echo "PASS an unknown command exits 2"
else
  echo "FAIL an unknown command exits 2: exit $rc, got: $out"
  fails=$((fails + 1))
fi

[[ $fails == 0 ]]
