#!/usr/bin/env bash
# Tests for scripts/java/parent_check.py: per case, a fresh temp project
# (pom.xml, devkit.toml pinned to devkit's parent version, optionally a
# module) checked against this checkout's java/parent/pom.xml, or against a
# copy declaring another version. No Maven, no network. Prints PASS/FAIL per
# case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check=$root/scripts/java/parent_check.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
proj=$work/proj
version=$(sed -n 's|^  <version>\(.*\)</version>$|\1|p' "$root/java/parent/pom.xml")
fails=0

# parent [VERSION [RELATIVE-PATH [GROUP:ARTIFACT]]]: a <parent> block, devkit's by default
parent() {
  local coordinate=${3:-de.vptr.devkit:devkit-parent}
  printf '<parent><groupId>%s</groupId><artifactId>%s</artifactId>' "${coordinate%:*}" "${coordinate#*:}"
  printf '<version>%s</version><relativePath>%s</relativePath></parent>' \
    "${1:-$version}" "${2-.devkit/java/parent/pom.xml}"
}
own='<groupId>my.app</groupId><artifactId>my-app</artifactId>'

# project BODY [XMLNS]: a fresh project whose root pom is BODY in the POM
# namespace (XMLNS, when given, replaces the attribute), pinned to v$version.
project() {
  rm -rf "$proj"
  mkdir -p "$proj"
  printf '<project%s>%s</project>\n' "${2- xmlns=\"http://maven.apache.org/POM/4.0.0\"}" "$1" >"$proj/pom.xml"
  printf '[devkit]\nversion = "v%s"\n' "$version" >"$proj/devkit.toml"
}

# module BODY: add module app-api, whose pom is BODY
module() {
  sed -i 's|</project>|<modules><module>app-api</module></modules></project>|' "$proj/pom.xml"
  mkdir -p "$proj/app-api"
  printf '<project xmlns="http://maven.apache.org/POM/4.0.0">%s</project>\n' "$1" >"$proj/app-api/pom.xml"
}

# compiler_args ATTRIBUTES: a <build> whose compiler plugin sets <compilerArgs ATTRIBUTES>
compiler_args() {
  printf '<build><plugins><plugin><artifactId>maven-compiler-plugin</artifactId><configuration>'
  printf '<compilerArgs%s><arg>-Xlint:none</arg></compilerArgs></configuration></plugin></plugins></build>' "$1"
}

# expect LABEL WANT-STATUS WANT-TEXT [DEVKIT]: run the check; the output must contain WANT-TEXT
expect() {
  local out rc=0
  out=$(PROJECT_ROOT=$proj DEVKIT=${4:-$root} python3 "$check" 2>&1) || rc=$?
  if [[ $rc == "$2" && $out == *"$3"* && $out != *Traceback* ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: exit $rc, want $2 and '$3' in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}
passed="devkit parent version check passed. ($version == v$version)"
required="does not inherit de.vptr.devkit:devkit-parent, which devkit requires since v0.2.0"

project "$(parent)$own"
expect "devkit's parent at the pinned version passes" 0 "$passed"
project "$(parent)$own" ""
expect "a pom without the POM namespace passes" 0 "$passed"
project "$own"
expect "a pom without <parent> fails" 14 "$required"
project "$(parent "$version" .devkit/java/parent/pom.xml org.example:other-parent)$own"
expect "another parent fails" 14 "$required"
project "$(parent "$version" ../pom.xml)$own"
expect "another relativePath fails" 14 "makes Maven look de.vptr.devkit:devkit-parent up in remote repositories"
project "$(parent "$version" "")$own"
expect "an empty relativePath fails" 14 "not empty or absent"
project "$(parent 0.0.0)$own"
expect "a parent version off the pin fails" 14 "but devkit.toml pins v$version; set <parent><version>$version</version>"
# shellcheck disable=SC2016 # a literal Maven property
project "$(parent '${revision}')$own"
expect "a \${revision} parent version fails" 14 "set <parent><version>$version</version>"
mkdir -p "$work/devkit/java/parent"
sed "s|^  <version>$version</version>$|  <version>0.0.0</version>|" "$root/java/parent/pom.xml" \
  >"$work/devkit/java/parent/pom.xml"
project "$(parent)$own"
expect "a pin whose parent POM declares another version fails" 14 \
  "the pinned tag does not match its parent POM" "$work/devkit"
project "$(parent)<artifactId>my-app</artifactId>"
expect "a root pom without its own groupId fails" 14 "has no <groupId> of its own"
project "$(parent)$own<properties><checkstyle.version>1.0</checkstyle.version></properties>"
expect "the root pom redefining a tool version fails" 14 \
  "partial migration: remove <checkstyle.version> from pom.xml; the parent owns it"
project "$(parent)$own"
module '<properties><checkstyle.version>1.0</checkstyle.version></properties>'
expect "a module pom redefining a tool version fails" 14 \
  "partial migration: remove <checkstyle.version> from app-api/pom.xml"
project "$(parent)$own"
module "<profiles><profile><id>p</id>$(compiler_args '')</profile></profiles>"
expect "<compilerArgs> without append in a module's profile fails" 14 \
  'app-api/pom.xml sets maven-compiler-plugin <compilerArgs> without combine.children="append"'
project "$(parent)$own$(compiler_args ' combine.children="append"')"
expect "<compilerArgs> with append passes" 0 "$passed"
project "$(parent)$own"
rm "$proj/pom.xml"
expect "a missing pom.xml fails" 14 "cannot read pom.xml"
project "$(parent)$own"
echo '<project>' >"$proj/pom.xml"
expect "a malformed pom.xml fails" 14 "cannot read pom.xml"
project "$(parent)$own"
printf '[devkit]\nurl = "x"\n' >"$proj/devkit.toml"
expect "devkit.toml without a [devkit] version fails" 14 "devkit.toml has no [devkit] version"

[[ $fails == 0 ]]
