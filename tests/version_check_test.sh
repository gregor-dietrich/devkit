#!/usr/bin/env bash
# Tests for scripts/java/version_check.py, run as scripts/java/check.sh runs it
# (python3 -I, PROJECT_ROOT the project): per case, a fresh temp project and
# the pom parse's output. No network: a pom with an artifact to look up makes
# the helper query Maven Central, so every case either holds none (no
# property, an unresolved one, a managed artifact, the project's own modules)
# or sends the query to a proxy that refuses connections (https_proxy points at
# a closed port of this host, which urllib honours before it resolves the
# host, so no packet leaves it). What a Central answer is made into (outdated,
# current, ahead) is not tested: it needs Central. Prints PASS/FAIL per case.
set -euo pipefail

script=$(cd "$(dirname "$0")/.." && pwd)/scripts/java/version_check.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
proj=$work/proj
fails=0
ns='xmlns="http://maven.apache.org/POM/4.0.0"'
# Never reach a real proxy, or Central: whatever the caller exports, queries go to a refused port.
unset http_proxy HTTP_PROXY ALL_PROXY all_proxy
export https_proxy=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1 no_proxy='' NO_PROXY=''

# project BODY: a fresh project whose root pom is BODY, in the POM namespace
project() {
  rm -rf "$proj"
  mkdir -p "$proj"
  printf '<project %s>%s</project>\n' "$ns" "$1" >"$proj/pom.xml"
}

# module NAME BODY: the module NAME of the project, whose pom is BODY (declared in the root pom)
module() {
  sed "s|</project>|<modules><module>$1</module></modules></project>|" "$proj/pom.xml" >"$proj/pom.xml.new"
  mv "$proj/pom.xml.new" "$proj/pom.xml"
  mkdir -p "$proj/$1"
  printf '<project %s>%s</project>\n' "$ns" "$2" >"$proj/$1/pom.xml"
}

# ref NAME: the Maven property reference ${NAME}
ref() { echo "\${$1}"; }

# dep GROUP ARTIFACT [VERSION]: a <dependency>
dep() {
  printf '<dependency><groupId>%s</groupId><artifactId>%s</artifactId>' "$1" "$2"
  [[ -z ${3:-} ]] || printf '<version>%s</version>' "$3"
  printf '</dependency>'
}

own='<groupId>my.app</groupId><artifactId>my-app</artifactId>'

# expect LABEL WANT-STATUS WANT-TEXT...: the helper over $proj must exit WANT-STATUS and print each
# WANT-TEXT, in stdout and stderr together and without a traceback; a WANT-TEXT of the form !TEXT
# must be absent
expect() {
  local label=$1 status=$2 out rc=0 text bad=''
  shift 2
  out=$(PROJECT_ROOT=$proj python3 -I "$script" 2>&1) || rc=$?
  [[ $rc == "$status" && $out != *Traceback* ]] || bad="exit $rc"
  for text in "$@"; do
    if [[ $text == '!'* ]]; then [[ $out != *"${text:1}"* ]] || bad+=" with '${text:1}'"
    else [[ $out == *"$text"* ]] || bad+=" without '$text'"; fi
  done
  if [[ -z $bad ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: $bad in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

project "$own"
expect "a pom with no dependencies has nothing to check and no notes" 0 \
  "Checking 0 version properties (0 artifacts) against Maven Central..." "Up to date: 0" "!Notes:"

rm "$proj/pom.xml"
expect "a missing pom.xml fails, naming it" 1 "ERROR: $proj/pom.xml not found."

project "$own<dependencies>$(dep org.example lib "$(ref lib.version)")</dependencies>"
expect "a version property the pom does not define is a note, not a lookup" 0 \
  'Checking 0 version properties (0 artifacts)' 'Notes:' "org.example:lib:$(ref lib.version): unresolved property, skipped" "!Could not check"

project "$own<dependencies>$(dep "$(ref missing.group)" lib 1.0)</dependencies>"
expect "a groupId the pom does not define is a note too" 0 \
  "$(ref missing.group):lib:1.0: unresolved property, skipped"

project "$own<dependencyManagement><dependencies>$(dep org.example bom)$(dep org.example other)</dependencies></dependencyManagement>"
expect "artifacts without a version are counted as managed, not looked up" 0 \
  "Checking 0 version properties" "2 artifact(s) without an explicit version (managed by a BOM or the parent), skipped"

project "$own<properties><orphan.version>1.0</orphan.version><java.release>25</java.release></properties>"
expect "a *.version property no artifact uses is listed, a property of another name is not" 0 \
  "property orphan.version pins no Maven artifact, not checked" "!java.release"

project "$own<properties><lib.version>1.0</lib.version></properties><dependencies>$(dep org.example lib "$(ref lib.version)")</dependencies>"
expect "an artifact to look up is sent to Central, which the refused proxy fails: unchecked, with the cause" 0 \
  "Checking 1 version properties (1 artifacts)" "Error: org.example:lib" "Could not check (1):" "  lib.version (1.0)" \
  "could not check org.example:lib" "!Up to date: 1"

project "$own<properties><lib.version>1.0</lib.version></properties><dependencies>$(dep org.example lib $'\n  ${lib.version}\n')</dependencies>"
expect "a placeholder between line breaks is still the property's pin, not a hardcoded version" 0 \
  "  lib.version (1.0)" "!org.example:lib (1.0)"

project "$own<dependencies>$(dep org.example lib 1.0)</dependencies>"
expect "a hardcoded version is its own edit site, named by its coordinate" 0 \
  "Could not check (1):" "  org.example:lib (1.0)"

project "$own<properties><vaadin.version>1.0</vaadin.version></properties><dependencies>$(dep org.example a "$(ref vaadin.version)")$(dep org.example b "$(ref vaadin.version)")</dependencies>"
expect "one property pinning two artifacts is one pin" 0 "Checking 1 version properties (2 artifacts)" "  vaadin.version (1.0)"

project "$own<properties><x.version>1</x.version></properties><profiles><profile><id>p</id><properties><x.version>2</x.version></properties></profile></profiles><dependencies>$(dep org.example a "$(ref x.version)")</dependencies>"
expect "a property a profile redefines resolves to the first definition" 0 "  x.version (1)"

project "<groupId>my.app</groupId><artifactId>my-app</artifactId><packaging>pom</packaging><properties><root.group>my.app</root.group></properties>"
module core '<parent><groupId>my.app</groupId><artifactId>my-app</artifactId><version>1</version></parent><artifactId>core</artifactId>'
module api "<parent><groupId>my.app</groupId><artifactId>my-app</artifactId><version>1</version></parent><artifactId>api</artifactId><dependencies>$(dep "$(ref root.group)" core 1.0)$(dep my.app missing-module "$(ref nowhere.version)")</dependencies>"
expect "a multi-module build: a module inherits the root's properties, and a dependency on a sibling module (groupId inherited from the parent) is skipped, not looked up" 0 \
  "Checking 0 version properties (0 artifacts)" "1 dependency declaration(s) on the project's own modules, skipped" \
  "my.app:missing-module:$(ref nowhere.version): unresolved property, skipped" "!Could not check"

project "$own<modules><module>gone</module></modules>"
expect "a module whose directory holds no pom is ignored" 0 "Checking 0 version properties"

project "$own<dependencies>$(dep org.example lib 1.0)</dependencies>"
rc=0
out=$(cd "$proj" && env -u PROJECT_ROOT python3 -I "$script" 2>&1) || rc=$?
if [[ $rc == 0 && $out == *"  org.example:lib (1.0)"* ]]; then
  echo "PASS without PROJECT_ROOT the current directory is the project"
else
  echo "FAIL without PROJECT_ROOT the current directory is the project: exit $rc, got:"
  printf '%s\n' "$out"
  fails=$((fails + 1))
fi

[[ $fails == 0 ]]
