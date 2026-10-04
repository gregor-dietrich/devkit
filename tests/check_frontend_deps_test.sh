#!/usr/bin/env bash
# Tests for scripts/java/check_frontend_deps.py: per case, a fresh temp HOME
# whose ~/.m2 holds fake Vaadin jars, and a stand-in mvn (MVN_CMD) that
# answers the script's exact help:evaluate calls (local repository,
# vaadin.version) and "resolves" the dev bundle by writing it; one temp
# project whose files (package.json, package-lock.json, devkit.toml)
# project() rewrites before a case. No Maven, no network. Prints PASS/FAIL
# per case. Knobs, set per case: vaadin_version, local_repo, resolve,
# frontend (the frontend directory, default ".").
set -euo pipefail
unset vaadin_version local_repo resolve frontend

check=$(cd "$(dirname "$0")/.." && pwd)/scripts/java/check_frontend_deps.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
proj=$work/proj
mkdir "$proj"
# Real Maven would read it; the stand-in reports vaadin.version on its own.
echo '<project><properties><vaadin.version>9.9.9</vaadin.version></properties></project>' > "$proj/pom.xml"
fails=0 case_no=0

# jar_path ARTIFACT: com/vaadin/ARTIFACT/V/ARTIFACT-V.jar in the case's ~/.m2, V being
# $vaadin_version (default 9.9.9), the version the stand-in reports
jar_path() {
  local v=${vaadin_version:-9.9.9}
  printf '%s' "$HOME/.m2/repository/com/vaadin/$1/$v/$1-$v.jar"
}
# jar ARTIFACT [MEMBER CONTENT]...: write that jar with these members
jar() {
  python3 - "$(jar_path "$1")" "${@:2}" << 'EOF'
import sys, zipfile
from pathlib import Path
path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(path, "w") as jar:
    for member, content in zip(sys.argv[2::2], sys.argv[3::2]):
        jar.writestr(member, content)
EOF
}
# @vaadin/common-frontend is absent from the core manifest, as in Vaadin itself:
# only the dev bundle's package-lock.json supplies its version.
core_jar() { jar vaadin-core-internal META-INF/VAADIN/versions/vaadin-core-versions.json '{}'; }
core_jar_with_common_frontend() {
  jar vaadin-core-internal META-INF/VAADIN/versions/vaadin-core-versions.json \
    '{"core": {"common": {"npmName": "@vaadin/common-frontend", "jsVersion": "0.0.25"}}}'
}
core_jar_garbage() {
  local path
  path=$(jar_path vaadin-core-internal)
  mkdir -p "${path%/*}"
  printf 'not a zip' > "$path"
}
prod_jar() { jar vaadin-prod-bundle vaadin-prod-bundle/config/stats.json '{}'; }
dev_jar() {
  jar vaadin-dev-bundle vaadin-dev-bundle/config/stats.json '{}' vaadin-dev-bundle/package-lock.json \
    '{"packages": {"node_modules/@vaadin/common-frontend": {"version": "0.0.24"}}}'
}
dev_jar_without_lock() { jar vaadin-dev-bundle vaadin-dev-bundle/config/stats.json '{}'; }
dev_jar_without_vaadin() {
  jar vaadin-dev-bundle vaadin-dev-bundle/package-lock.json \
    '{"packages": {"node_modules/lit": {"version": "3.0.0"}}}'
}
no_toml() { rm "$proj/devkit.toml"; }
bad_package_json() { echo '{' > "$proj/${frontend:-.}/package.json"; }
array_package_lock() { echo '[]' > "$proj/${frontend:-.}/package-lock.json"; }

# A stand-in for mvn, run as the script runs Maven: from PROJECT_ROOT, with
# exactly these argument lists. help:evaluate answers settings.localRepository
# with $local_repo (default the case's ~/.m2/repository) and vaadin.version,
# asked of the frontend pom, with $vaadin_version (default 9.9.9);
# dependency:get writes the dev bundle, as Maven would, unless $resolve is
# "fail". Anything else exits 1.
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  declare -f jar_path jar dev_jar
  cat << 'EOF'
[[ $(pwd -P) == "$(cd "$PROJECT_ROOT" && pwd -P)" ]] || exit 1
help=org.apache.maven.plugins:maven-help-plugin:3.5.2:evaluate
pom=$(cd "$PROJECT_ROOT/${frontend:-.}" && pwd -P)/pom.xml
case "$*" in
  "-B -q -N $help -Dexpression=settings.localRepository -DforceStdout")
    printf '%s' "${local_repo-$HOME/.m2/repository}" ;;
  "-B -q -N $help -Dexpression=vaadin.version -DforceStdout -f $pom")
    printf '%s' "${vaadin_version:-9.9.9}" ;;
  "-q -N org.apache.maven.plugins:maven-dependency-plugin:3.11.0:get -Dartifact=com.vaadin:vaadin-dev-bundle:${vaadin_version:-9.9.9} -Dtransitive=false")
    [[ ${resolve:-} != fail ]] && dev_jar ;;
  *) exit 1 ;;
esac
EOF
} > "$work/mvn"
chmod +x "$work/mvn"
export MVN_CMD=$work/mvn

# project PKG-JSON PKG-LOCK TOML [PKG]: the project's files; package.json and
# package-lock.json, in $frontend, lack PKG (default somepkg) when PKG-JSON or
# PKG-LOCK is empty, and TOML follows the [devkit] table in devkit.toml.
project() {
  local pkg=${4:-somepkg} dir=$proj/${frontend:-.}
  local json=${1:+", \"$pkg\": \"$1\""} lock=${2:+", \"node_modules/$pkg\": {\"version\": \"$2\"}"}
  mkdir -p "$dir"
  printf '{"dependencies": {"@vaadin/common-frontend": "0.0.24"%s}}\n' "$json" > "$dir/package.json"
  printf '{"packages": {"node_modules/@vaadin/common-frontend": {"version": "0.0.24"}%s}}\n' \
    "$lock" > "$dir/package-lock.json"
  printf '[devkit]\nversion = "v0.0.0"\n\n%s\n' "$3" > "$proj/devkit.toml"
}

# expect LABEL WANT-STATUS WANT-TEXT SETUP...: run the check on $frontend with a
# fresh ~/.m2 prepared by the SETUP functions; the output must contain
# WANT-TEXT and no Python traceback.
expect() {
  local label=$1 want=$2 text=$3 out rc=0 setup
  shift 3
  export HOME=$work/home-$((++case_no))
  for setup in "$@"; do "$setup"; done
  out=$(PROJECT_ROOT=$proj python3 "$check" "${frontend:-.}" 2>&1) || rc=$?
  if [[ $rc == "$want" && $out == *"$text"* && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and '$text' (no traceback) in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}
passed="Frontend dependency check passed."
dev_bundle_path=.m2/repository/com/vaadin/vaadin-dev-bundle/9.9.9/vaadin-dev-bundle-9.9.9.jar
pins=$'[frontend.min-pins]\nsomepkg = "1.2.3"'

# The project's minimums, [frontend.min-pins].
project 1.2.3 1.2.3 '[frontend.min-pins]'
expect "an empty [frontend.min-pins] passes" 0 "$passed" core_jar dev_jar
project 1.2.3 1.2.3 "$pins"
expect "a met minimum passes" 0 "$passed" core_jar dev_jar
project 1.2.2 1.2.3 "$pins"
expect "package.json below the minimum fails" 1 "somepkg is 1.2.2 in package.json" core_jar dev_jar
project 1.2.3 1.2.2 "$pins"
expect "package-lock.json below the minimum fails" 1 "somepkg is 1.2.2 in package-lock.json" \
  core_jar dev_jar
project "" 1.2.3 "$pins"
expect "a pinned package missing from package.json fails" 1 "somepkg missing version in package.json" \
  core_jar dev_jar
project 1.2.3 "" "$pins"
expect "a pinned package missing from package-lock.json fails" 1 \
  "somepkg missing version in package-lock.json" core_jar dev_jar
project 1.2.9 1.2.9 $'[frontend.min-pins]\nsomepkg = "1.2.10"'
expect "versions compare numerically: 1.2.9 is below 1.2.10" 1 "somepkg is 1.2.9 in package.json" \
  core_jar dev_jar
project 1.2.10 1.2.10 $'[frontend.min-pins]\nsomepkg = "1.2.9"'
expect "versions compare numerically: 1.2.10 meets 1.2.9" 0 "$passed" core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend.min-pins]\n"@scope/name" = "1.2.3"' @scope/name
expect "a met minimum on a quoted scoped name passes" 0 "$passed" core_jar dev_jar
project 1.2.3 1.2.3 ''
expect "a missing table fails" 1 "[frontend.min-pins]" core_jar dev_jar
project 1.2.3 1.2.3 "$pins"
expect "a missing devkit.toml fails" 1 "devkit.toml: no such file" no_toml core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend.min-pins]\nsomepkg = '
expect "invalid TOML fails" 1 "is not valid TOML" core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend.min-pins]\nsomepkg = "1.2.3-rc.1"'
expect "a minimum that is not x.y.z fails" 1 "is not a stable x.y.z" core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend.min-pins]\nsomepkg = 1'
expect "a minimum that is not a string fails" 1 "somepkg = 1 in [frontend.min-pins]" \
  core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend.min-pins]\nchart.js = "1.2.3"'
expect "an unquoted dotted package name fails" 1 'quote package names that contain "."' \
  core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend]\nmin-pins = "x"'
expect "a min-pins that is not a table fails" 1 "[frontend.min-pins] in $proj/devkit.toml must be a table" \
  core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend]\nother = 1\n\n[frontend.min-pins]'
expect "a stray key under [frontend] fails" 1 "under [frontend] in" core_jar dev_jar
project 1.2.2 1.2.3 "$pins"
resolve=fail expect "a minimum's error still shows when the bundle step fails" 1 \
  "somepkg is 1.2.2 in package.json" core_jar

# Unreadable project files.
project 1.2.3 1.2.3 "$pins"
expect "an invalid package.json fails naming it" 1 "package.json is not valid JSON" bad_package_json
project 1.2.3 1.2.3 "$pins"
expect "a package-lock.json that is not an object fails naming it" 1 "package-lock.json is not a JSON object" \
  array_package_lock

# What Maven reports: the local repository and the frontend module's vaadin.version.
project 1.2.3 1.2.3 '[frontend.min-pins]'
vaadin_version=9.9.8 expect "the vaadin.version Maven reports is the one used, not the pom's text" 0 \
  "against Vaadin 9.9.8 manifest" core_jar dev_jar
vaadin_version=25.3 expect "a vaadin.version that is not x.y.z fails naming it" 1 'vaadin.version as "25.3"'
# What Maven prints for vaadin.version when the pom does not define it.
vaadin_version="null object or invalid expression" expect "an undefined vaadin.version fails" 1 \
  'vaadin.version as "null object or invalid expression"'
local_repo=$work/none expect "a local repository that is not a directory fails naming it" 1 \
  "local repository as \"$work/none\""
local_repo='' expect "an empty local repository answer fails" 1 'local repository as ""'
MVN_CMD='' expect "without MVN_CMD the check fails naming it" 1 "ERROR: MVN_CMD is not set" core_jar dev_jar
MVN_CMD=false expect "a failing Maven call fails naming it" 1 "Maven failed to evaluate vaadin.version"
MVN_CMD=$work/none expect "a missing MVN_CMD binary fails naming it" 1 "No such file"
frontend=gui project 1.2.3 1.2.3 "$pins"
frontend=gui expect "a frontend in a module directory passes" 0 "$passed" core_jar dev_jar

# Vaadin's manifests: the core jar, gaps filled from the dev bundle.
project 1.2.3 1.2.3 '[frontend.min-pins]'
expect "the core manifest wins over the dev bundle" 1 "expected 0.0.25 per the Vaadin manifest" \
  core_jar_with_common_frontend dev_jar
expect "a drifted @vaadin/ version prints the remedy" 1 "Regenerate the committed frontend files" \
  core_jar_with_common_frontend dev_jar
expect "a present prod bundle does not stop the dev bundle being resolved" 0 \
  "Resolving vaadin-dev-bundle 9.9.9" core_jar prod_jar
resolve=fail expect "a failed resolution names the dev bundle" 1 "$dev_bundle_path" core_jar prod_jar
expect "a dev bundle without package-lock.json fails loudly" 1 "ERROR: No package-lock.json found in" \
  core_jar dev_jar_without_lock
expect "a dev bundle lock without @vaadin/ entries fails naming the jar" 1 \
  "vaadin-dev-bundle-9.9.9.jar lists no @vaadin/ package" core_jar dev_jar_without_vaadin
project 1.2.2 1.2.3 "$pins"
expect "a core jar that is not a zip fails naming the error" 1 "File is not a zip file" core_jar_garbage
expect "a core jar that is not a zip keeps the minimum's error" 1 "somepkg is 1.2.2 in package.json" \
  core_jar_garbage

[[ $fails == 0 ]]
