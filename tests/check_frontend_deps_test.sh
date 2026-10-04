#!/usr/bin/env bash
# Tests for scripts/java/check_frontend_deps.py: per case, a fresh temp HOME
# whose ~/.m2 holds fake Vaadin jars, optionally with a stand-in mvn
# (MVN_CMD) that "resolves" the dev bundle by writing it; one temp project
# whose files (package.json, package-lock.json, devkit.toml) project()
# rewrites before a case. No Maven, no network. Prints PASS/FAIL per case.
set -euo pipefail

check=$(cd "$(dirname "$0")/.." && pwd)/scripts/java/check_frontend_deps.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
proj=$work/proj
mkdir "$proj"
echo '<project><properties><vaadin.version>9.9.9</vaadin.version></properties></project>' > "$proj/pom.xml"
fails=0 case_no=0

# jar ARTIFACT [MEMBER CONTENT]...: write com/vaadin/ARTIFACT/9.9.9/ARTIFACT-9.9.9.jar into the case's ~/.m2
jar() {
  python3 - "$HOME/.m2/repository/com/vaadin/$1/9.9.9/$1-9.9.9.jar" "${@:2}" << 'EOF'
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
prod_jar() { jar vaadin-prod-bundle vaadin-prod-bundle/config/stats.json '{}'; }
dev_jar() {
  jar vaadin-dev-bundle vaadin-dev-bundle/config/stats.json '{}' vaadin-dev-bundle/package-lock.json \
    '{"packages": {"node_modules/@vaadin/common-frontend": {"version": "0.0.24"}}}'
}
dev_jar_without_lock() { jar vaadin-dev-bundle vaadin-dev-bundle/config/stats.json '{}'; }

# A stand-in for mvn: asked for the dev bundle, it writes it, as Maven would.
cat > "$work/mvn" << EOF
#!/usr/bin/env bash
set -euo pipefail
$(declare -f jar dev_jar)
[[ \$* == *dependency:get*-Dartifact=com.vaadin:vaadin-dev-bundle:9.9.9* ]] && dev_jar
EOF
chmod +x "$work/mvn"

# project SOMEPKG-JSON SOMEPKG-LOCK TOML: the project's files; package.json
# lacks somepkg when SOMEPKG-JSON is empty, and TOML follows the [devkit] table.
project() {
  local somepkg=${1:+", \"somepkg\": \"$1\""}
  printf '{"dependencies": {"@vaadin/common-frontend": "0.0.24"%s}}\n' "$somepkg" > "$proj/package.json"
  printf '{"packages": {"node_modules/@vaadin/common-frontend": {"version": "0.0.24"}, %s}}\n' \
    "\"node_modules/somepkg\": {\"version\": \"$2\"}" > "$proj/package-lock.json"
  printf '[devkit]\nversion = "v0.0.0"\n\n%s\n' "$3" > "$proj/devkit.toml"
}

# expect LABEL WANT-STATUS WANT-TEXT MVN SETUP...: run the check on a fresh ~/.m2
# prepared by the SETUP functions, with MVN_CMD=MVN; the output must contain WANT-TEXT.
expect() {
  local label=$1 want=$2 text=$3 mvn=$4 out rc=0 setup
  shift 4
  export HOME=$work/home-$((++case_no))
  for setup in "$@"; do "$setup"; done
  out=$(MVN_CMD=$mvn PROJECT_ROOT=$proj python3 "$check" . 2>&1) || rc=$?
  if [[ $rc == "$want" && $out == *"$text"* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and '$text' in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}
passed="Frontend dependency check passed."
dev_bundle_path=.m2/repository/com/vaadin/vaadin-dev-bundle/9.9.9/vaadin-dev-bundle-9.9.9.jar
pins=$'[frontend.min-pins]\nsomepkg = "1.2.3"'

# The project's minimums, [frontend.min-pins].
project 1.2.3 1.2.3 '[frontend.min-pins]'
expect "an empty [frontend.min-pins] passes" 0 "$passed" "" core_jar dev_jar
project 1.2.3 1.2.3 "$pins"
expect "a met minimum passes" 0 "$passed" "" core_jar dev_jar
project 1.2.2 1.2.3 "$pins"
expect "package.json below the minimum fails" 1 "somepkg is 1.2.2 in package.json" "" core_jar dev_jar
project 1.2.3 1.2.2 "$pins"
expect "package-lock.json below the minimum fails" 1 "somepkg is 1.2.2 in package-lock.json" "" \
  core_jar dev_jar
project "" 1.2.3 "$pins"
expect "a pinned package missing from package.json fails" 1 "somepkg missing version in package.json" "" \
  core_jar dev_jar
project 1.2.3 1.2.3 ''
expect "a missing table fails" 1 "[frontend.min-pins]" "" core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend.min-pins]\nsomepkg = "1.2.3-rc.1"'
expect "a minimum that is not x.y.z fails" 1 "is not a stable x.y.z" "" core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend.min-pins]\nchart.js = "1.2.3"'
expect "an unquoted dotted package name fails" 1 'quote package names that contain "."' "" \
  core_jar dev_jar
project 1.2.3 1.2.3 $'[frontend]\nother = 1\n\n[frontend.min-pins]'
expect "a stray key under [frontend] fails" 1 "under [frontend] in" "" core_jar dev_jar
project 1.2.2 1.2.3 "$pins"
expect "a minimum's error still shows when the bundle step fails" 1 "somepkg is 1.2.2 in package.json" "" \
  core_jar

# Vaadin's manifests: the core jar, gaps filled from the dev bundle.
project 1.2.3 1.2.3 '[frontend.min-pins]'
expect "the core manifest wins over the dev bundle" 1 "expected 0.0.25 per the Vaadin manifest" "" \
  core_jar_with_common_frontend dev_jar
expect "a present prod bundle does not stop the dev bundle being resolved" 0 \
  "Resolving vaadin-dev-bundle 9.9.9" "$work/mvn" core_jar prod_jar
expect "without MVN_CMD the missing dev bundle is named" 1 "$dev_bundle_path" "" core_jar prod_jar
expect "a failed resolution still names the dev bundle" 1 "$dev_bundle_path" false core_jar
expect "a dev bundle without package-lock.json fails loudly" 1 "No package-lock.json found in" "" \
  core_jar dev_jar_without_lock

[[ $fails == 0 ]]
