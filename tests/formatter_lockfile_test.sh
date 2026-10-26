#!/usr/bin/env bash
# Tests for scripts/java/formatter_lockfile.py: per case, a stub parent POM, a synthetic
# spotless-lib-extra jar in a temp local repository, and a checksums file listing it and the
# formatter's jars; one case runs against the real parent POM, the committed checksums and
# ~/.m2/repository, when the jar is there. No Maven, no network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/java/formatter_lockfile.py
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
fails=0 repo=$work/repo
lib=com/diffplug/spotless/spotless-lib-extra/9.9/spotless-lib-extra-9.9.jar
lockfile_entry=com/diffplug/spotless/extra/eclipse_jdt_formatter/v1.2.lockfile
hash=$(printf '%064d' 0)

# pom PROPERTY-LINE ECLIPSE-VERSION: the stub parent POM, $work/pom.xml
pom() {
  cat >"$work/pom.xml" <<XML
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <properties>$1</properties>
  <build><pluginManagement><plugins><plugin>
    <artifactId>spotless-maven-plugin</artifactId>
    <configuration><java><eclipse><version>$2</version></eclipse></java></configuration>
  </plugin></plugins></pluginManagement>
  <plugins><plugin><artifactId>spotless-maven-plugin</artifactId></plugin></plugins></build>
</project>
XML
}
# jar ENTRY: the repository's spotless-lib-extra jar, holding that member (none if empty) and a lockfile body
jar() {
  python3 -I - "$work/repo/$lib" "$1" <<'PY'
import sys, zipfile
from pathlib import Path
path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(path, "w") as jar:
    if sys.argv[2]:
        jar.writestr(sys.argv[2], "# Spotless formatter based on Eclipse-JDT 1.2\norg.eclipse.jdt:core:3.0\nnet.x.y:lib:5.1\n\n")
PY
}
# sums LINE...: the checksums file, one "hash  path" line per path
sums() {
  : >"$work/sums"
  local path
  for path; do printf '%s  %s\n' "$hash" "$path" >>"$work/sums"; done
}
good_sums() { sums "$lib" org/eclipse/jdt/core/3.0/core-3.0.jar net/x/y/lib/5.1/lib-5.1.jar; }
# expect LABEL WANT-STATUS WANT-TEXT: run the check on the case's files
expect() {
  local out rc=0
  out=$(python3 -I "$check" "$work/pom.xml" "$repo" "$work/sums" 2>&1) || rc=$?
  if [[ $rc == "$2" && $out == *"$3"* && $out != *Traceback* && ( $2 != 0 || -z $out ) ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1 (exit $rc): $out"
    fails=$((fails + 1))
  fi
}

prop='<eclipse-formatter.version>1.2</eclipse-formatter.version>'
# shellcheck disable=SC2016 # a Maven property, not a shell expansion
ref='${eclipse-formatter.version}'
pom "$prop" "$ref"
jar "$lockfile_entry"
good_sums
expect "a lockfile whose coordinates are all listed passes, silently" 0 ""

jar ""
expect "a jar without the version's lockfile fails naming P2" 1 "embeds no lockfile for eclipse-formatter.version 1.2"
jar "$lockfile_entry"

sums "$lib" org/eclipse/jdt/core/3.0/core-3.0.jar
expect "a coordinate the checksums do not list fails naming it and make maven-checksums" 1 \
  "does not list net/x/y/lib/5.1/lib-5.1.jar: make maven-checksums"

good_sums
pom "" "$ref"
expect "a POM without the property fails" 1 "sets no eclipse-formatter.version property"

pom "$prop" "1.2"
expect "an <eclipse><version> that is not the property fails" 1 "not exactly \${eclipse-formatter.version}"
pom "$prop" "$ref"

sums org/eclipse/jdt/core/3.0/core-3.0.jar net/x/y/lib/5.1/lib-5.1.jar
expect "checksums without a spotless-lib-extra jar fail" 1 "lists 0 spotless-lib-extra jars"

sums "$lib" "${lib//9.9/9.8}" org/eclipse/jdt/core/3.0/core-3.0.jar net/x/y/lib/5.1/lib-5.1.jar
expect "checksums with two spotless-lib-extra jars fail" 1 "lists 2 spotless-lib-extra jars"

good_sums
rm -r "${work:?}/repo"
expect "a missing jar fails naming it" 1 "spotless-lib-extra-9.9.jar does not exist"

if [[ -f $HOME/.m2/repository/$(grep -o 'com/diffplug/spotless/spotless-lib-extra/[^ ]*\.jar' "$root/java/checksums/checksums.sha256") ]]; then
  repo=$HOME/.m2/repository
  cp "$root/java/parent/pom.xml" "$work/pom.xml"
  cp "$root/java/checksums/checksums.sha256" "$work/sums"
  expect "the real parent POM, committed checksums and ~/.m2 pass, silently" 0 ""
else
  echo "SKIP the real parent POM: no spotless-lib-extra jar in ~/.m2/repository"
fi

[[ $fails == 0 ]]
