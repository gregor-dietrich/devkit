#!/usr/bin/env bash
# Tests for scripts/java/check_frontend_deps.py: a temp project and a temp HOME
# whose ~/.m2 holds fake Vaadin jars, and a fake mvn (MVN_CMD) that "resolves"
# the dev bundle by writing it. No Maven, no network. Prints PASS/FAIL per case.
set -euo pipefail

check=$(cd "$(dirname "$0")/.." && pwd)/scripts/java/check_frontend_deps.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

# @vaadin/common-frontend is absent from the core manifest, as in Vaadin itself:
# only the dev bundle's package-lock.json supplies its version.
mkdir "$work/proj"
cat > "$work/proj/pom.xml" << 'EOF'
<project><properties><vaadin.version>9.9.9</vaadin.version></properties></project>
EOF
cat > "$work/proj/package.json" << 'EOF'
{"dependencies": {"@vaadin/common-frontend": "0.0.24", "react-router": "7.15.0", "dompurify": "3.4.16"}}
EOF
cat > "$work/proj/package-lock.json" << 'EOF'
{"packages": {"node_modules/@vaadin/common-frontend": {"version": "0.0.24"},
  "node_modules/react-router": {"version": "7.15.0"}, "node_modules/dompurify": {"version": "3.4.16"}}}
EOF

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
core_jar() { jar vaadin-core-internal META-INF/VAADIN/versions/vaadin-core-versions.json '{}'; }
prod_jar() { jar vaadin-prod-bundle vaadin-prod-bundle/config/stats.json '{}'; }
dev_jar() {
  jar vaadin-dev-bundle vaadin-dev-bundle/config/stats.json '{}' vaadin-dev-bundle/package-lock.json \
    '{"packages": {"node_modules/@vaadin/common-frontend": {"version": "0.0.24"}}}'
}
dev_jar_without_lock() { jar vaadin-dev-bundle vaadin-dev-bundle/config/stats.json '{}'; }

# A stand-in for mvn: on dependency:get it writes the dev bundle, as Maven would.
cat > "$work/mvn" << EOF
#!/usr/bin/env bash
set -euo pipefail
$(declare -f jar dev_jar)
[[ \$* == *dependency:get* ]] && dev_jar
EOF
chmod +x "$work/mvn"

# expect LABEL WANT-STATUS WANT-TEXT MVN SETUP...: run the check on a fresh ~/.m2
# prepared by the SETUP functions, with MVN_CMD=MVN; the output must contain WANT-TEXT.
expect() {
  local label=$1 want=$2 text=$3 mvn=$4 out rc=0 setup
  shift 4
  export HOME=$work/home-$((++case_no))
  for setup in "$@"; do "$setup"; done
  out=$(MVN_CMD=$mvn PROJECT_ROOT=$work/proj python3 "$check" . 2>&1) || rc=$?
  if [[ $rc == "$want" && $out == *"$text"* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and '$text' in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}
case_no=0

expect "the dev bundle fills the core manifest's gaps" 0 "check passed" "" core_jar dev_jar
expect "a present prod bundle does not stop the dev bundle being resolved" 0 \
  "Resolving vaadin-dev-bundle 9.9.9" "$work/mvn" core_jar prod_jar
expect "without MVN_CMD the missing dev bundle is named" 1 \
  "Vaadin bundle jar not found: $work/home-3/.m2/repository/com/vaadin/vaadin-dev-bundle" "" \
  core_jar prod_jar
expect "a dev bundle without package-lock.json fails loudly" 1 "No package-lock.json found in" "" \
  core_jar dev_jar_without_lock

[[ $fails == 0 ]]
