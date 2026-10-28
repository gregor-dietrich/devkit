#!/usr/bin/env bash
# Tests for scripts/python/uv_project.py: a temp project whose uv.lock and
# pyproject.toml are synthetic, shaped as uv writes them (a single project
# has no [manifest] and its own package at "."; a workspace lists its members
# by name in [manifest] members, each a package whose source is its
# directory). Cases cover every command, certifi-versions included. The last
# cases check that each committed fixture's uv.lock pins uv at UV_FLOOR and its
# uv_build ranges run from UV_FLOOR up to the next minor, and that it locks
# certifi at CERTIFI_FLOOR or later. No uv, no network. Prints PASS/FAIL per
# case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/scripts/python/uv_project.py
# Physical: the scripts report resolved paths, and macOS's TMPDIR is under the
# /var -> /private/var symlink. Two steps, so set -e catches a failed mktemp.
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
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
# certifi VERSION: a certifi entry at VERSION
certifi() { printf '[[package]]\nname = "certifi"\nversion = "%s"\nsource = { registry = "https://pypi.org/simple" }\n' "$1"; }
# uv HASH...: the uv entry, one wheel per HASH; "none" is a wheel without one
uv() {
  local hash field
  printf '[[package]]\nname = "uv"\nversion = "0.13.6"\nsource = { registry = "https://pypi.org/simple" }\nwheels = [\n'
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
expect "uv-version prints the locked uv's version" 0 "0.13.6" uv-version
lock "$single" $'[[package]]\nversion = "0.13.6"\nname = "uv"\nsource = { registry = "https://pypi.org/simple" }' \
  "$(package zzz 'registry = "https://pypi.org/simple"')"
expect "uv-version reads a uv entry whose version precedes its name" 0 "0.13.6" uv-version
lock "$single" "$(package uvicorn 'registry = "https://pypi.org/simple"')"
expect "a lock without a uv entry fails" 1 "uv.lock pins no uv package" uv-version
lock "$single" "$(uv "$h1")" "$(uv "$h2" | sed 's/0\.13\.6/0.14.1/')"
expect "two uv entries fail" 1 "uv.lock pins uv more than once (0.13.6, 0.14.1)" uv-version
lock "$single" "$(uv "$h1" | sed 's|^version = .*|version = "../0.1"|')"
expect "a uv version unfit for a path fails" 1 "no usable version" uv-version
for below in 0!0.13.5 0.13.5 0.13.6rc1 0.13.6.dev1 0.13.6a1 0.13.6b1 0.13.6c1 0.13.6pre1 0.13.6-alpha1 0.13.5.post1 0.13.5+local 0.12.99 0.9; do
  lock "$single" "$(uv "$h1" | sed "s|^version = .*|version = \"$below\"|")"
  expect "uv $below is below the minimum" 1 "uv.lock pins uv $below, below devkit's minimum 0.13.6; require uv>=0.13.6" uv-version
done
for ok in 0.13.6+local 0.13.6.post1 0.13.6.post1.dev1 0.13.7rc1 0.13.10 0.14.0 1.0 0!0.14.0 0!1.0 1!0.1; do
  lock "$single" "$(uv "$h1" | sed "s|^version = .*|version = \"$ok\"|")"
  expect "uv $ok meets the minimum" 0 "$ok" uv-version
done
for long in "0.13.$(printf '9%.0s' {1..4301})" "0.14.0+$(printf 'a%.0s' {1..60})"; do
  lock "$single" "$(uv "$h1" | sed "s|^version = .*|version = \"$long\"|")"
  expect "a uv version over 64 characters fails" 1 "no usable version" uv-version
done
rm "$proj/uv.lock"
expect "a missing uv.lock fails" 1 "no uv.lock in $proj" uv-version
echo '[[package]' >"$proj/uv.lock"
expect "a malformed uv.lock fails" 1 "cannot read uv.lock" uv-version

# certifi-versions
lock "$single" "$(certifi 2026.10.23)"
expect "certifi-versions prints the locked certifi's version" 0 "2026.10.23" certifi-versions
for ok in 2026.10.18 2026.10.18.post1 2026.10.18+local 1!2020.1.1; do
  lock "$single" "$(certifi "$ok")"
  expect "certifi $ok meets the minimum" 0 "$ok" certifi-versions
done
for below in 2026.7.22 2026.10.18rc1 2026.10.18.dev1; do
  lock "$single" "$(certifi "$below")"
  expect "certifi $below is below the minimum" 1 "uv.lock pins certifi ($below) below devkit's minimum 2026.10.18" certifi-versions
done
lock "$single" "$(certifi 2026.10.23)" "$(certifi 2026.7.22)"
expect "a certifi fork judges every entry, naming the old one" 1 "uv.lock pins certifi (2026.7.22) below devkit's minimum" certifi-versions
lock "$single" "$(certifi 2026.7.22)" "$(certifi 2026.6.17)"
expect "several entries below the minimum are all named, in lock order" 1 "uv.lock pins certifi (2026.7.22, 2026.6.17) below devkit's minimum 2026.10.18" certifi-versions
lock "$single" "$(certifi 2026.7.22 | sed 's/"certifi"/"Certifi"/')"
expect "an entry named Certifi is judged as certifi" 1 "uv.lock pins certifi (2026.7.22) below" certifi-versions
lock "$single" "$(certifi 2026.10.19)" "$(certifi 2026.10.23)"
expect "a certifi fork prints every version in lock order" 0 $'2026.10.19\n2026.10.23' certifi-versions
lock "$single" "$(uv "$h1")"
expect "a lock without certifi passes, printing nothing" 0 "" certifi-versions
lock "$single" "$(certifi ../x)"
expect "an unusable certifi version fails" 1 "no usable version" certifi-versions

# uv-requirements
lock "$single" "$(uv "$h1" "$h2")"
expect "uv-requirements pins uv by every wheel hash" 0 \
  "uv==0.13.6 \\"$'\n'"    --hash=sha256:$h1 \\"$'\n'"    --hash=sha256:$h2" uv-requirements
lock "$single" "$(uv "$h1" none)"
expect "a wheel without a hash fails" 1 "no sha256 hash for every uv 0.13.6 wheel" uv-requirements
lock "$single" "$(uv)"
expect "a uv without wheels fails" 1 "no sha256 hash for every uv 0.13.6 wheel" uv-requirements

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

# uv-platform
rm -f "$proj/uv.lock"
out=$(PROJECT_ROOT=$proj python3 "$script" uv-platform 2>&1) || out=failed
if [[ $out =~ ^(glibc|musl|other)(32|64)$ ]]; then
  echo "PASS uv-platform prints libc and pointer width, reading no lock"
else
  echo "FAIL uv-platform prints libc and pointer width, reading no lock: got: $out"
  fails=$((fails + 1))
fi

rc=0
out=$(python3 "$script" frobnicate 2>&1) || rc=$?
if [[ $rc == 2 && $out == "usage: "* ]]; then
  echo "PASS an unknown command exits 2"
else
  echo "FAIL an unknown command exits 2: exit $rc, got: $out"
  fails=$((fails + 1))
fi

# The fixtures pin uv exactly at UV_FLOOR and allow uv_build from UV_FLOOR up
# to the next minor (README, "Gating devkit itself"): one off it fails here.
read -r floor below certifi_floor <<<"$(python3 -I -c 'import runpy, sys
major, minor, *_ = floor = (module := runpy.run_path(sys.argv[1]))["UV_FLOOR"]
print(".".join(map(str, floor)), f"{major}.{minor + 1}", ".".join(map(str, module["CERTIFI_FLOOR"])))' "$script")"
# ... and lock certifi, at CERTIFI_FLOOR or later (make audit's pip-audit trusts it): the exit 0
# proves the version, the output proves an entry
for fixture in "$root"/tests/fixtures/python-*/; do
  proj=${fixture%/} expect "$(basename "$fixture") pins uv at UV_FLOOR ($floor)" 0 "$floor" uv-version
  rc=0
  out=$(PROJECT_ROOT=${fixture%/} python3 "$script" certifi-versions 2>&1) || rc=$?
  if [[ $rc == 0 && -n $out ]]; then
    echo "PASS $(basename "$fixture") locks certifi at CERTIFI_FLOOR ($certifi_floor) or later"
  else
    echo "FAIL $(basename "$fixture") locks certifi at CERTIFI_FLOOR ($certifi_floor) or later: exit $rc, got '$out'"
    fails=$((fails + 1))
  fi
done
# uv_build_check LABEL TEXT: every uv_build requirement in TEXT is the
# floor's, and there is at least one
uv_build_check() {
  local want="uv_build>=$floor,<$below" found
  found=$(grep -oE 'requires = \[[^]]*\]' <<<"$2" | grep -oE 'uv[_-]build[^"]*' || :)
  if [[ -n $found && -z $(grep -vxF "$want" <<<"$found" || :) ]]; then
    echo "PASS $1 requires $want"
  else
    echo "FAIL $1 requires $want: got '${found//$'\n'/ }'"
    fails=$((fails + 1))
  fi
}
checked=0
for pyproject in "$root"/tests/fixtures/python-*/packages/*/pyproject.toml "$root"/tests/fixtures/python-*/pyproject.toml; do
  [[ ! -e $pyproject ]] || ! grep -qE 'uv[_-]build' "$pyproject" ||
    { uv_build_check "${pyproject#"$root"/tests/fixtures/}" "$(<"$pyproject")" && checked=$((checked + 1)); }
done
if [[ $checked == 0 ]]; then
  echo "FAIL a fixture's pyproject.toml requires uv_build"
  fails=$((fails + 1))
fi
uv_build_check "tests/run.sh's packaged-root rewrite" "$(grep 'requires = \["uv_build' "$root/tests/run.sh")"

[[ $fails == 0 ]]
