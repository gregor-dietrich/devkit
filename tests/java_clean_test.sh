#!/usr/bin/env bash
# Tests for scripts/java/clean.sh, with a fake Maven in devkit's tools cache (a
# seeded XDG_CACHE_HOME), and decoys, an mvn on PATH and a wrapper-jar ./mvnw in
# the project, that must stay unused: per case, a temp project (pom.xml
# inheriting devkit's parent, devkit.toml pinned to its version) holding the
# frontend build output and logs clean removes, next to the manifests and
# sources it must keep: for a monolith whose frontend is the project root, for
# MODULES whose frontend is gui, and for the same MODULES with ONLY=api, which
# must remove api's logs only, keep gui's logs and frontend output, and pass
# -pl api to mvn (the whole-reactor cases pass no -pl). A curl stub that fails
# sits first on PATH, so a drift of the cache layout from the pin cannot reach
# the network (the case would fail). Prints PASS/FAIL per path. No Maven, no
# network.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=SCRIPTDIR/../scripts/lib/tree.sh
. "$root/scripts/lib/tree.sh"
work=$(mktemp -d)
# No -- for chmod: macOS's rejects it; || : keeps set -e from ending the trap before rm.
trap 'chmod -R u+w "${work:?}" 2>/dev/null || :; rm -rf -- "${work:?}"' EXIT # the pinned Maven's cache is read-only
version=$(parent_version "$root")
fails=0

export XDG_CACHE_HOME=$work/cache
maven=$(maven_version "$root")
mvn_bin=$XDG_CACHE_HOME/devkit/tools/maven-$maven/apache-maven-$maven/bin
mkdir -p "$work/bin" "$mvn_bin"
cat >"$mvn_bin/mvn" <<'MVN'
#!/bin/bash
echo "$*" >>"$MVN_LOG"
MVN
cat >"$work/bin/mvn" <<'MVN'
#!/bin/bash
echo decoy >>"$MVN_LOG"
exit 1
MVN
printf '#!/bin/sh\nexit 22\n' >"$work/bin/curl"
chmod +x "$mvn_bin/mvn" "$work/bin/mvn" "$work/bin/curl"

# run_case LABEL FRONTEND_DIR MODULES ONLY: a fresh project, clean.sh run on it,
# then the paths under FRONTEND_DIR (or the logs of MODULES) checked; with ONLY
# set, only its module's logs are removed, and the frontend output only if it
# is the frontend
run_case() {
  local label=$1 frontend=$2 modules=$3 only=$4 module path
  local proj=$work/$label
  local gone=("$frontend/node_modules" "$frontend/src/main/frontend/generated")
  local kept=("$frontend/package.json" "$frontend/package-lock.json" "$frontend/src/main/frontend/index.html" pom.xml)
  for module in ${modules:-.}; do
    if [[ -z $only || $module == "$only" ]]; then gone+=("$module/logs"); else kept+=("$module/logs"); fi
  done
  if [[ -n $only && $only != "$frontend" ]]; then kept+=("${gone[@]:0:2}") gone=("${gone[@]:2}"); fi
  gone=("${gone[@]#./}") kept=("${kept[@]#./}")
  mkdir -p "$proj"
  {
    printf '<project xmlns="http://maven.apache.org/POM/4.0.0"><parent><groupId>de.vptr.devkit</groupId>'
    printf '<artifactId>devkit-parent</artifactId><version>%s</version>' "$version"
    printf '<relativePath>.devkit/java/parent/pom.xml</relativePath></parent>'
    printf '<groupId>my.app</groupId><artifactId>my-app</artifactId></project>\n'
  } >"$proj/pom.xml"
  # shellcheck disable=SC2016 # $MVN_LOG is for the decoy to expand
  printf '#!/bin/sh\n# MavenWrapperMain\necho decoy >>"$MVN_LOG"\nexit 1\n' >"$proj/mvnw"
  chmod +x "$proj/mvnw"
  printf '[devkit]\nversion = "v%s"\n' "$version" >"$proj/devkit.toml"
  for path in "${gone[@]}" "${kept[@]}"; do
    mkdir -p "$proj/$(dirname "$path")"
    case $path in
      *logs | *node_modules | *generated) mkdir -p "$proj/$path" && touch "$proj/$path/f" ;;
      *) [[ -e $proj/$path ]] || touch "$proj/$path" ;;
    esac
  done

  local out
  out=$(cd "$proj" && env -u ONLY -u REVISION ${only:+ONLY="$only"} PATH="$work/bin:$PATH" JAVA_VERSION=25 MVN_LOG="$work/$label.mvn.log" \
    DEVKIT="$root" PROJECT_ROOT="$proj" MODULES="$modules" FRONTEND_DIR="$frontend" \
    "$root/scripts/java/clean.sh" 2>&1) || {
    echo "FAIL $label: clean.sh exited non-zero:"
    printf '%s\n' "$out"
    exit 1
  }
  if grep -qw clean "$work/$label.mvn.log"; then echo "PASS $label runs mvn clean"; else echo "FAIL $label runs mvn clean" && fails=$((fails + 1)); fi
  if ! grep -qw decoy "$work/$label.mvn.log"; then echo "PASS $label runs no decoy mvn or ./mvnw"; else echo "FAIL $label runs no decoy mvn or ./mvnw" && fails=$((fails + 1)); fi
  if [[ -z $only ]]; then
    if ! grep -qw -- -pl "$work/$label.mvn.log"; then echo "PASS $label passes no -pl"; else echo "FAIL $label passes no -pl" && fails=$((fails + 1)); fi
  else
    if grep -qw -- "-pl $only" "$work/$label.mvn.log"; then echo "PASS $label passes -pl $only"; else echo "FAIL $label passes -pl $only" && fails=$((fails + 1)); fi
  fi
  for path in "${gone[@]}"; do
    if [[ ! -e $proj/$path ]]; then echo "PASS $label removes $path"; else echo "FAIL $label removes $path" && fails=$((fails + 1)); fi
  done
  for path in "${kept[@]}"; do
    if [[ -e $proj/$path ]]; then echo "PASS $label keeps $path"; else echo "FAIL $label keeps $path" && fails=$((fails + 1)); fi
  done
}

run_case monolith . "" ""
run_case modules gui "api gui" ""
run_case only-api gui "api gui" api

[[ $fails == 0 ]]
