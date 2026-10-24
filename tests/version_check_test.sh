#!/usr/bin/env bash
# Tests for scripts/java/version_check.py, run as scripts/java/check.sh runs it
# (python3 -I, PROJECT_ROOT the project): per case, a fresh temp project and
# the pom parse's output. No network: a pom with an artifact to look up makes
# the helper query Maven Central or DEVKIT_MAVEN_MIRROR, so every case either
# holds none (no property, an unresolved one, a managed artifact, the project's
# own modules) or sends the query to a proxy of this host, which urllib honours
# before it resolves the host, so no packet leaves it: a closed port that
# refuses connections, or a recording proxy that keeps each request's first
# line (CONNECT <host>:443, so which repository was asked) and hangs up. What
# a Central answer is made into (outdated, current, ahead) is not tested: it
# needs Central. Prints PASS/FAIL per case.
set -euo pipefail

script=$(cd "$(dirname "$0")/.." && pwd)/scripts/java/version_check.py
# Physical: the script reports resolved paths, and macOS's TMPDIR is under the
# /var -> /private/var symlink. Two steps, so set -e catches a failed mktemp.
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
recorder=''
trap '[[ -z $recorder ]] || kill "$recorder" 2>/dev/null || :; rm -rf "$work"' EXIT
proj=$work/proj
fails=0
ns='xmlns="http://maven.apache.org/POM/4.0.0"'
# Never reach a real proxy, or Central: whatever the caller exports, queries go by default to a refused port.
unset http_proxy HTTP_PROXY ALL_PROXY all_proxy
export https_proxy=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1 no_proxy='' NO_PROXY=''
unset DEVKIT_MAVEN_MIRROR # the mirror cases set it themselves

# The recording proxy: it writes its port to $work/port once listening, and appends the first line of
# every connection to $requests before it hangs up.
requests=$work/requests
python3 -I -c '
import os, socket, sys
server = socket.create_server(("127.0.0.1", 0))
with open(sys.argv[1] + ".new", "w") as port:
    port.write(str(server.getsockname()[1]))
os.replace(sys.argv[1] + ".new", sys.argv[1])
while True:
    connection, _ = server.accept()
    with connection:
        line = connection.makefile("rb").readline()
        with open(sys.argv[2], "ab") as log:
            log.write(line)
' "$work/port" "$requests" &
recorder=$!
for _ in {1..100}; do [[ -s $work/port ]] && break; sleep 0.1; done
[[ -s $work/port ]] || { echo "FAIL the recording proxy did not start"; exit 1; }
recording=http://127.0.0.1:$(<"$work/port")

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

# sent WANT LABEL WANT-STATUS WANT-TEXT...: expect, with the queries sent to the recording proxy,
# whose every request line must then contain WANT, or which must see no request at all for an empty
# WANT; one PASS or FAIL line
sent() {
  local want=$1 got line bad=''
  shift
  : >"$requests"
  local out
  out=$(https_proxy=$recording HTTPS_PROXY=$recording expect "$@") || :
  got=$(tr -d '\r' <"$requests")
  if [[ -z $want ]]; then
    [[ -z $got ]] || bad=1
  else
    [[ -n $got ]] || bad=1
    while IFS= read -r line; do [[ -z $line || $line == *"$want"* ]] || bad=1; done <<<"$got"
  fi
  if [[ -n $bad && $out == PASS* ]]; then
    out="FAIL $1: the proxy received '$got', not '${want:-nothing}'"
  elif [[ -n $bad ]]; then
    out+=$'\n'"  and the proxy received '$got', not '${want:-nothing}'"
  fi
  printf '%s\n' "$out"
  [[ $out != FAIL* ]] || fails=$((fails + 1))
}

project "$own<properties><lib.version>1.0</lib.version></properties><dependencies>$(dep org.example lib "$(ref lib.version)")</dependencies>"
sent "CONNECT repo1.maven.org:443" "without DEVKIT_MAVEN_MIRROR the lookup goes to Central" 0 \
  "against Maven Central..." "Could not check (1):"
DEVKIT_MAVEN_MIRROR='' sent "CONNECT repo1.maven.org:443" "an empty DEVKIT_MAVEN_MIRROR means Central" 0 \
  "against Maven Central..." "Could not check (1):"
DEVKIT_MAVEN_MIRROR=https://mirror.example/m2/ sent "CONNECT mirror.example:443" \
  "DEVKIT_MAVEN_MIRROR replaces Central, a trailing slash dropped" 0 \
  "against https://mirror.example/m2..." "Could not check (1):" "!repo1.maven.org"
# The values tests/pinned_maven_test.sh refuses, refused here too (its own copy of the rule), before any lookup and unprinted.
for value in https://user:s3cret@mirror.example/m2 http://s3cret@mirror.example/m2 https:///u:s3cret@h \
  https://u:s3cret/ss@h https:/u:s3cret@h //u:s3cret@h; do
  DEVKIT_MAVEN_MIRROR=$value sent "" "a mirror naming a user or password is refused unprinted (${value//s3cret/***})" 1 \
    "ERROR: DEVKIT_MAVEN_MIRROR names a user or password" "!s3cret" "!Checking"
done
for pair in "https://|DEVKIT_MAVEN_MIRROR=" "https://h |https://h" "https://h/p?token=x|token" "https://h#f|https://h#" \
  $'https://h/p\nx|h/p' "http://mirror.example/m2|mirror.example"; do
  value=${pair%%|*} leak=${pair#*|}
  DEVKIT_MAVEN_MIRROR=$value sent "" "a malformed mirror is refused unprinted (without '$leak')" 1 \
    "ERROR: DEVKIT_MAVEN_MIRROR must be an https:// base URL with a host and no query, fragment or whitespace" \
    "!$leak" "!Checking"
done

project "$own<properties><lib.version>1.0</lib.version></properties><dependencies>$(dep org.example lib "$(ref lib.version)")</dependencies>"
DEVKIT_MAVEN_MIRROR=https://mirror.example:8443/m2 sent "CONNECT mirror.example:8443" "a mirror with a port is accepted, and the lookup goes to it" 0 \
  "against https://mirror.example:8443/m2..." "Could not check (1):" "!repo1.maven.org"
# Accepted by the rule, but no usable URL: a failed lookup, not a traceback.
for pair in "port|https://h:abc/m2" "zero-width space|https://h.invalid/p"$'\xe2\x80\x8b'"q"; do
  DEVKIT_MAVEN_MIRROR=${pair#*|} sent "" "a mirror with a ${pair%%|*} that is no usable URL fails the lookup, not the report" 0 \
    "Could not check (1):" "Error: org.example:lib"
done

# unit LABEL CODE: CODE, run with the script imported as v, must print PASS (these need TLS to reach otherwise)
unit() {
  local out
  out=$(python3 -I -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("v", sys.argv[1])
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
'"$2"'
print("PASS")' "$script" 2>&1) || :
  if [[ $out == PASS ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: got:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}
unit "a redirect to http is refused" \
  'assert v.HttpsOnlyRedirects().redirect_request(v.urllib.request.Request("https://a/m"), None, 302, "", {}, "http://a/m") is None'
unit "a redirect to https is followed" \
  'assert v.HttpsOnlyRedirects().redirect_request(v.urllib.request.Request("https://a/m"), None, 302, "", {}, "https://b/m").full_url == "https://b/m"'
unit "a version of non-ASCII digits is not stable" 'assert not v.is_stable("\u00b2")'
unit "a latest that is no number is classified, not parsed" \
  'assert v.compare("1.0", "4.0.0-beta-4") == v.compare("1.0-rc1", "4.0.0-beta-4") == "unordered"'

[[ $fails == 0 ]]
