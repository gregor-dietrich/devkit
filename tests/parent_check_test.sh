#!/usr/bin/env bash
# Tests for scripts/java/parent_check.py: per case, a fresh temp project
# (pom.xml, devkit.toml pinned to devkit's parent version, optionally a
# module) checked against this checkout's java/parent/pom.xml, or against a
# copy declaring another version, or against a fake devkit tree with derived
# parent POMs. No Maven, no network. Prints PASS/FAIL per
# case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=SCRIPTDIR/../scripts/lib/tree.sh
. "$root/scripts/lib/tree.sh"
check=$root/scripts/java/parent_check.py
# Physical: the scripts report resolved paths, and macOS's TMPDIR is under the
# /var -> /private/var symlink. Two steps, so set -e catches a failed mktemp.
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
proj=$work/proj
dk=$work/dk
version=$(parent_version "$root")
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

# derived NAME ARTIFACT UP-COORD VERSION RELATIVE-PATH PROPERTY: the fake devkit tree's java/NAME/pom.xml,
# artifact ARTIFACT, inheriting UP-COORD; its <properties> hold PROPERTY (an XML element) when given
derived() {
  mkdir -p "$dk/java/$1"
  printf '<project xmlns="http://maven.apache.org/POM/4.0.0">%s<groupId>de.vptr.devkit</groupId>' \
    "$(parent "$4" "$5" "$3")" >"$dk/java/$1/pom.xml"
  printf '<artifactId>%s</artifactId><properties>%s</properties></project>\n' "$2" "${6-}" >>"$dk/java/$1/pom.xml"
}
# fake_release: the fake devkit tree $dk with this checkout's parent and a Quarkus parent, consistent
fake_release() {
  rm -rf "$dk"
  mkdir -p "$dk/java/parent"
  cp "$root/java/parent/pom.xml" "$dk/java/parent/pom.xml"
  derived quarkus devkit-quarkus-parent de.vptr.devkit:devkit-parent "$version" ../parent/pom.xml \
    '<quarkus.platform.version>1</quarkus.platform.version>'
}

# module BODY: add module app-api, whose pom is BODY
module() {
  # no sed -i: its argument differs between GNU and BSD
  sed 's|</project>|<modules><module>app-api</module></modules></project>|' "$proj/pom.xml" >"$proj/pom.xml.new"
  mv "$proj/pom.xml.new" "$proj/pom.xml"
  mkdir -p "$proj/app-api"
  printf '<project xmlns="http://maven.apache.org/POM/4.0.0">%s</project>\n' "$1" >"$proj/app-api/pom.xml"
}

# compiler_args ATTRIBUTES: a <build> whose compiler plugin sets <compilerArgs ATTRIBUTES>
compiler_args() {
  printf '<build><plugins><plugin><artifactId>maven-compiler-plugin</artifactId><configuration>'
  printf '<compilerArgs%s><arg>-Xlint:none</arg></compilerArgs></configuration></plugin></plugins></build>' "$1"
}

# spotbugs CONFIG: a <build> whose SpotBugs plugin has the <configuration> CONFIG
spotbugs() {
  printf '<build><plugins><plugin><artifactId>spotbugs-maven-plugin</artifactId>'
  printf '<configuration>%s</configuration></plugin></plugins></build>' "$1"
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
required="does not inherit a devkit parent (de.vptr.devkit:devkit-parent or devkit-quarkus-parent), which devkit requires since v0.2.0"

project "$(parent)$own"
expect "devkit's parent at the pinned version passes" 0 "$passed"
PYTHONSAFEPATH=1 expect "the check runs under PYTHONSAFEPATH=1" 0 "$passed"
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
dk=$work/devkit derived quarkus devkit-quarkus-parent de.vptr.devkit:devkit-parent 0.0.0 ../parent/pom.xml
project "$(parent)$own"
expect "a pin whose parent POM declares another version fails" 14 \
  "the pinned tag does not match its parent POM" "$work/devkit"
project "$(parent)<artifactId>my-app</artifactId>"
expect "a root pom without its own groupId fails" 14 "has no <groupId> of its own"
project "$(parent)$own<properties><checkstyle.version>1.0</checkstyle.version></properties>"
expect "the root pom redefining a tool version fails" 14 \
  "partial migration: remove <checkstyle.version> from pom.xml; the parent owns it"
mpath=../.devkit/java/parent/pom.xml
project "$(parent)$own"
module "$(parent "$version" "$mpath")$own"
expect "a module inheriting devkit's parent by its own path passes" 0 "$passed"
project "$(parent)$own"
module "$(parent "$version" "$mpath")$own<modules><module>api</module></modules>"
mkdir -p "$proj/app-api/api"
printf '<project>%s%s</project>\n' "$(parent "$version" ../.devkit/java/parent/pom.xml)" "$own" >"$proj/app-api/api/pom.xml"
expect "a nested module inheriting devkit's parent by the path from a module fails" 14 \
  "app-api/api/pom.xml's <parent><relativePath> must be ../../.devkit/java/parent/pom.xml"
project "$(parent)$own"
mkdir -p "$proj/x/app-api"
ln -s x/app-api "$proj/app-api"
module "$(parent "$version" "$mpath")$own"
expect "a symlinked module inheriting devkit's parent by the path from its link fails" 14 \
  "app-api/pom.xml's <parent><relativePath> must be ../../.devkit/java/parent/pom.xml"
project "$(parent)$own"
module "$(parent)$own"
expect "a module inheriting devkit's parent by the root's path fails" 14 \
  "app-api/pom.xml's <parent><relativePath> must be $mpath, not .devkit/java/parent/pom.xml"
project "$(parent)$own"
module "$(parent "$version" "")$own"
expect "a module inheriting devkit's parent with an empty relativePath fails" 14 \
  "app-api/pom.xml's <parent><relativePath> must be $mpath, not empty or absent"
project "$(parent)$own"
module "$(parent 0.0.0 "$mpath")$own"
expect "a module inheriting devkit's parent off the pin fails" 14 \
  "app-api/pom.xml inherits de.vptr.devkit:devkit-parent 0.0.0, but devkit.toml pins v$version"
project "$(parent)$own"
module "$(parent "$version" "$mpath")<artifactId>app-api</artifactId>"
expect "a module inheriting devkit's parent without its own groupId fails" 14 \
  "app-api/pom.xml has no <groupId> of its own"
project "$(parent)$own"
module "$(parent "$version" ../pom.xml "my.app:my-app")<artifactId>app-api</artifactId>"
expect "a module inheriting the project's root pom is not checked" 0 "$passed"
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
plugins='<plugin><groupId>x</groupId><artifactId>y</artifactId><version>1</version></plugin>'
project "$(parent)$own$(spotbugs "<plugins>$plugins</plugins>")"
expect "SpotBugs <plugins> without append fails" 14 \
  'pom.xml sets spotbugs-maven-plugin <plugins> without combine.children="append"; Maven merges it with the parent'"'"'s by position and its plugin replaces find-sec-bugs'
project "$(parent)$own$(spotbugs "<plugins combine.children=\"append\">$plugins</plugins>")"
expect "SpotBugs <plugins> with append passes" 0 "$passed"
key=findsecbugs.injection.customconfigfile.CrlfLogInjectionDetector
sinks=$(sed -n "s|^ *<systemPropertyVariables><$key>\\([^<]*\\)</$key></systemPropertyVariables>\$|\\1|p" "$root/java/parent/pom.xml")
# sysprops [ATTRIBUTES] ENTRIES: a SpotBugs <configuration> whose <systemPropertyVariables ATTRIBUTES> holds ENTRIES
sysprops() { spotbugs "<systemPropertyVariables$1>$2</systemPropertyVariables>"; }
in_module() { # BUILD: BUILD in a module's profile
  project "$(parent)$own"
  module "<profiles><profile><id>p</id>$1</profile></profiles>"
}
in_module "$(sysprops '' '<foo>bar</foo>')"
expect "SpotBugs <systemPropertyVariables> with another key passes" 0 "$passed"
in_module "$(sysprops '' "<$key>$sinks:own.txt|CRLF_INJECTION_LOGS</$key>")"
expect "SpotBugs <systemPropertyVariables> joining its own sinks file to the parent's passes" 0 "$passed"
in_module "$(sysprops ' combine.self="override"' "<$key>$sinks</$key>")"
expect "SpotBugs <systemPropertyVariables> override that keeps the parent's sinks passes" 0 "$passed"
in_module "$(sysprops '' "<$key>own.txt|CRLF_INJECTION_LOGS</$key>")"
expect "SpotBugs <systemPropertyVariables> sinks entry without the parent's value, in a module's profile, fails" 14 \
  "app-api/pom.xml sets spotbugs-maven-plugin <$key> without the parent's $sinks"
in_module "$(sysprops '' "<$key></$key>")"
expect "SpotBugs <systemPropertyVariables> with an empty sinks entry fails" 14 \
  "sets spotbugs-maven-plugin <$key> without the parent's $sinks; it replaces the parent's value and drops find-sec-bugs' \
JBoss Logging sinks, so keep that entry in the ':'-joined value."
in_module "$(sysprops ' combine.self="override"' '<foo>bar</foo>')"
expect "SpotBugs <systemPropertyVariables> override without a sinks entry fails" 14 \
  "app-api/pom.xml sets spotbugs-maven-plugin <systemPropertyVariables> with combine.self=\"override\" and without <$key>, \
which drops find-sec-bugs' JBoss Logging sinks; drop the override, or keep $sinks in the ':'-joined value of <$key>."
in_module "$(spotbugs '<jvmArgs>-Xss4m -Xmx1g</jvmArgs>')"
expect "SpotBugs <jvmArgs> with other flags passes" 0 "$passed"
in_module "$(spotbugs "<jvmArgs>-Xss4m -D$key=own.txt|CRLF_INJECTION_LOGS</jvmArgs>")"
expect "SpotBugs <jvmArgs> setting the sinks property fails" 14 \
  "app-api/pom.xml sets -D$key in spotbugs-maven-plugin <jvmArgs>, which the parent's <systemPropertyVariables> entry defeats; \
move a sink file into the value of <systemPropertyVariables><$key>, joined to the parent's with ':'."
project "$(parent)$own$(spotbugs '<jvmArgs>-Xmx1g</jvmArgs>' | sed 's|<configuration>|<configuration combine.self="override">|')"
expect "SpotBugs <configuration> with combine.self=override fails" 14 \
  "pom.xml sets spotbugs-maven-plugin <configuration> with combine.self=\"override\"; it drops the parent's whole configuration \
(find-sec-bugs, its JBoss Logging sinks, the baseline), so drop the override."
project "$(parent)$own$(compiler_args ' combine.self="override" combine.children="append"')"
expect "<compilerArgs> with combine.self=override fails" 14 \
  "pom.xml sets maven-compiler-plugin <compilerArgs> with combine.self=\"override\"; it drops the parent's list whatever \
combine.children says; drop the override and use combine.children=\"append\"."
project "$(parent)$own$(spotbugs "<plugins combine.self=\"override\" combine.children=\"append\">$plugins</plugins>")"
expect "SpotBugs <plugins> with combine.self=override fails" 14 \
  'pom.xml sets spotbugs-maven-plugin <plugins> with combine.self="override"'
fake_release
q=de.vptr.devkit:devkit-quarkus-parent
qpath=.devkit/java/quarkus/pom.xml
unknown="which is none of devkit's parents; Maven would look it up remotely."
project "$(parent "$version" "$qpath" $q)$own"
expect "a root inheriting the Quarkus parent passes" 0 "$passed" "$dk"
project "$(parent)$own"
module "$(parent "$version" "../$qpath" $q)$own"
expect "a module inheriting the Quarkus parent by its own path passes" 0 "$passed" "$dk"
project "$(parent "$version" .devkit/java/parent/pom.xml $q)$own"
expect "a root inheriting the Quarkus parent by the base parent's path fails" 14 \
  "pom.xml's <parent><relativePath> must be $qpath, not .devkit/java/parent/pom.xml" "$dk"
project "$(parent)$own"
module "$(parent "$version" "$mpath" $q)$own"
expect "a module inheriting the Quarkus parent by the base parent's path fails" 14 \
  "app-api/pom.xml's <parent><relativePath> must be ../$qpath, not $mpath" "$dk"
project "$(parent 0.0.0 "$qpath" $q)$own"
expect "a root inheriting the Quarkus parent off the pin fails" 14 \
  "pom.xml inherits $q 0.0.0, but devkit.toml pins v$version" "$dk"
project "$(parent)$own"
module "$(parent 0.0.0 "../$qpath" $q)$own"
expect "a module inheriting the Quarkus parent off the pin fails" 14 \
  "app-api/pom.xml inherits $q 0.0.0, but devkit.toml pins v$version" "$dk"
project "$(parent "$version" "$qpath" $q)<artifactId>my-app</artifactId>"
expect "a root inheriting the Quarkus parent without its own groupId fails" 14 "has no <groupId> of its own" "$dk"
project "$(parent "$version" "$qpath" de.vptr.devkit:devkit-nope)$own"
expect "a root inheriting an unknown de.vptr.devkit artifact fails" 14 \
  "pom.xml's <parent> names de.vptr.devkit:devkit-nope, $unknown" "$dk"
project "$(parent)$own"
module "$(parent "$version" "../$qpath" de.vptr.devkit:devkit-nope)$own"
expect "a module inheriting an unknown de.vptr.devkit artifact fails" 14 \
  "app-api/pom.xml's <parent> names de.vptr.devkit:devkit-nope, $unknown" "$dk"
project "$own"
expect "a root without <parent> fails, naming the shipped parents" 14 \
  "does not inherit a devkit parent (de.vptr.devkit:devkit-parent or devkit-quarkus-parent)" "$dk"
rm "$dk/java/quarkus/pom.xml"
expect "a release without its Quarkus parent fails" 14 \
  "devkit's java/quarkus/pom.xml is missing: a defective devkit release; pin another one." "$dk"
rm "$dk/java/parent/pom.xml"
expect "a release without its base parent fails" 14 "devkit's java/parent/pom.xml is missing: a defective devkit release" "$dk"

defective() { # CASE-LABEL WANT-TEXT: the project inherits the base parent, checked against the tree fake_release left
  project "$(parent)$own"
  expect "$1" 14 "devkit v$version's $2: a defective devkit release; pin another one." "$dk"
}
fake_release
derived quarkus devkit-quarkus-parent de.vptr.devkit:devkit-parent 0.0.0 ../parent/pom.xml
defective "a Quarkus parent off the pin fails" \
  "java/quarkus/pom.xml does not inherit de.vptr.devkit:devkit-parent $version through ../parent/pom.xml"
fake_release
derived quarkus devkit-quarkus-parent de.vptr.devkit:devkit-parent "$version" ../../parent/pom.xml
defective "a Quarkus parent with another relativePath fails" \
  "java/quarkus/pom.xml does not inherit de.vptr.devkit:devkit-parent $version through ../parent/pom.xml"
fake_release
derived quarkus devkit-quarkus-parent org.example:other "$version" ../parent/pom.xml
defective "a Quarkus parent that inherits another parent fails" \
  "java/quarkus/pom.xml does not inherit de.vptr.devkit:devkit-parent $version through ../parent/pom.xml"
fake_release
sed 's|</parent>|</parent><version>1</version>|' "$dk/java/quarkus/pom.xml" >"$dk/java/quarkus/pom.xml.new"
mv "$dk/java/quarkus/pom.xml.new" "$dk/java/quarkus/pom.xml"
defective "a Quarkus parent declaring its own <version> fails" "java/quarkus/pom.xml declares a <version> of its own"
fake_release
sed 's|</parent><groupId>de.vptr.devkit</groupId>|</parent>|' "$dk/java/quarkus/pom.xml" >"$dk/java/quarkus/pom.xml.new"
mv "$dk/java/quarkus/pom.xml.new" "$dk/java/quarkus/pom.xml"
defective "a Quarkus parent without its own <groupId> fails" "java/quarkus/pom.xml declares no <groupId> of its own"
fake_release
sed 's|<parent>.*</parent>||' "$dk/java/quarkus/pom.xml" >"$dk/java/quarkus/pom.xml.new"
mv "$dk/java/quarkus/pom.xml.new" "$dk/java/quarkus/pom.xml"
defective "a Quarkus parent without a <parent> fails" \
  "java/quarkus/pom.xml does not inherit de.vptr.devkit:devkit-parent $version through ../parent/pom.xml"
fake_release
sed "s|</project>|$(compiler_args '')</project>|" "$dk/java/quarkus/pom.xml" >"$dk/java/quarkus/pom.xml.new"
mv "$dk/java/quarkus/pom.xml.new" "$dk/java/quarkus/pom.xml"
project "$(parent)$own"
expect "a Quarkus parent setting <compilerArgs> without append fails" 14 \
  'java/quarkus/pom.xml sets maven-compiler-plugin <compilerArgs> without combine.children="append"; Maven merges it with the parent'"'"'s by position and drops the inherited -Werror, Error Prone or NullAway; devkit'"'"'s own java/quarkus/pom.xml: a defective devkit release; pin another one.' "$dk"
sed "s|<compilerArgs>|<compilerArgs combine.children=\"append\">|" "$dk/java/quarkus/pom.xml" >"$dk/java/quarkus/pom.xml.new"
mv "$dk/java/quarkus/pom.xml.new" "$dk/java/quarkus/pom.xml"
expect "a Quarkus parent setting <compilerArgs> with append passes" 0 "$passed" "$dk"
fake_release
sed "s|</project>|$(spotbugs '<jvmArgs>-Xss4m</jvmArgs>' | sed 's|<configuration>|<configuration combine.self="override">|')</project>|" \
  "$dk/java/quarkus/pom.xml" >"$dk/java/quarkus/pom.xml.new"
mv "$dk/java/quarkus/pom.xml.new" "$dk/java/quarkus/pom.xml"
expect "a Quarkus parent overriding SpotBugs' <configuration> fails" 14 \
  'java/quarkus/pom.xml sets spotbugs-maven-plugin <configuration> with combine.self="override"; it drops the parent'"'"'s whole configuration (find-sec-bugs, its JBoss Logging sinks, the baseline); devkit'"'"'s own java/quarkus/pom.xml: a defective devkit release; pin another one.' "$dk"

fake_release
owned_qv='<quarkus.platform.version>2</quarkus.platform.version>'
project "$(parent)$own<properties>$owned_qv</properties>"
expect "a project on the base parent alone may define quarkus.platform.version" 0 "$passed" "$dk"
project "$(parent "$version" "$qpath" $q)$own<properties>$owned_qv</properties>"
expect "a root inheriting the Quarkus parent defining quarkus.platform.version fails" 14 \
  "partial migration: remove <quarkus.platform.version> from pom.xml; the parent owns it" "$dk"
project "$(parent)$own<properties>$owned_qv</properties>"
module "$(parent "$version" "../$qpath" $q)$own"
expect "a base root defining quarkus.platform.version beside a Quarkus module fails" 14 \
  "partial migration: remove <quarkus.platform.version> from pom.xml" "$dk"
proj=$work/co:lon project "$(parent)$own"
proj=$work/co:lon expect "a project path with ':' fails, as find-sec-bugs would silently not load" 14 \
  "the project path $work/co:lon contains ':'"
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
