#!/usr/bin/env bash
# Tests for scripts/java/version_check.py, run as scripts/java/check.sh runs it
# (python3 -I, PROJECT_ROOT the project): per case, a fresh temp project and the
# pom parse's output; the unit cases import the script and stub the opener,
# main() runs included. No network: a pom with an artifact to look up makes the
# helper query the default mirrors or DEVKIT_MAVEN_MIRROR's, so every case
# either holds none (no property, an unresolved one, a managed artifact, the
# project's own modules) or sends the query to a proxy of this host, which urllib
# honours before it resolves the host, so no packet leaves it: a closed port that
# refuses connections, or a recording proxy that keeps each request's first line
# (CONNECT <host>:<port>, so which repositories were asked, in which order) and
# hangs up. What a repository's answer is made into (outdated, current, ahead)
# is tested only through the unit cases' stubs. Prints PASS/FAIL per case.
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
# The default list, hardcoded so that a changed default fails here: as the header names it, and as
# the proxy sees it.
default_list='https://maven.vptr.de/central, then https://maven-central.storage-download.googleapis.com/maven2, then https://repo.maven.apache.org/maven2'
default_hosts='maven.vptr.de:443 maven-central.storage-download.googleapis.com:443 repo.maven.apache.org:443'

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
  "Checking 0 version properties (0 artifacts) against $default_list..." "Up to date: 0" "!Notes:"

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
expect "an artifact to look up is sent to the default mirrors, which the refused proxy fails: unchecked, with the cause" 0 \
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
# whose requests, as the CONNECT targets joined by spaces in the order sent, must be WANT, or none at
# all for an empty WANT; one PASS or FAIL line
sent() {
  local want=$1 got out bad=''
  shift
  : >"$requests"
  out=$(https_proxy=$recording HTTPS_PROXY=$recording expect "$@") || :
  got=$(tr -d '\r' <"$requests" | awk 'NF { printf "%s%s", sep, $2; sep = " " }')
  [[ $got == "$want" ]] || bad=1
  if [[ -n $bad && $out == PASS* ]]; then
    out="FAIL $1: the proxy received '$got', not '${want:-nothing}'"
  elif [[ -n $bad ]]; then
    out+=$'\n'"  and the proxy received '$got', not '${want:-nothing}'"
  fi
  [[ $out == PASS* || $out == FAIL* ]] || out="FAIL $1: expect printed '$out'"
  printf '%s\n' "$out"
  [[ $out == PASS* ]] || fails=$((fails + 1))
}

project "$own<properties><lib.version>1.0</lib.version></properties><dependencies>$(dep org.example lib "$(ref lib.version)")</dependencies>"
sent "$default_hosts" "without DEVKIT_MAVEN_MIRROR the lookup goes to each default mirror in turn" 0 \
  "against $default_list..." "Could not check (1):"
for value in '' $' \t'; do
  DEVKIT_MAVEN_MIRROR=$value sent "$default_hosts" "an empty or blank DEVKIT_MAVEN_MIRROR means the default list" 0 \
    "against $default_list..." "Could not check (1):"
done
DEVKIT_MAVEN_MIRROR=https://mirror.example/m2/ sent "mirror.example:443" \
  "DEVKIT_MAVEN_MIRROR replaces the default list, a trailing slash dropped" 0 \
  "against https://mirror.example/m2..." "Could not check (1):" "!maven.vptr.de" "!repo.maven.apache.org"
DEVKIT_MAVEN_MIRROR=$'  https://a.example/m2/\thttps://b.example\n' sent "a.example:443 b.example:443" \
  "a list split at spaces, tabs and line breaks is asked in order, trailing slash dropped" 0 \
  "against https://a.example/m2, then https://b.example..." "Could not check (1):"
# The values tests/pinned_maven_test.sh refuses, refused here too (its own copy of the rule), before any lookup and
# unprinted, each alone and as the second entry after a valid one; the two files keep their lists in step.
for value in https://user:s3cret@mirror.example/m2 http://s3cret@mirror.example/m2 https:///u:s3cret@h \
  https://u:s3cret/ss@h https:/u:s3cret@h //u:s3cret@h; do
  for list in "$value" "https://ok.example $value"; do
    DEVKIT_MAVEN_MIRROR=$list sent "" "a mirror naming a user or password is refused unprinted (${list//s3cret/***})" 1 \
      "ERROR: DEVKIT_MAVEN_MIRROR names a user or password" "!s3cret" "!Checking"
  done
done
# http://mirror.example is only here: the shell side tests http in its own case_mirror_http.
for pair in "https://|DEVKIT_MAVEN_MIRROR=" $'https://h\r|https://h' "https://h/p?token=x|token" "https://h#f|https://h#" \
  $'https://h/p\nx|h/p' $'https://h/p\x1b[31m|h/p' "http://mirror.example/m2|mirror.example"; do
  for list in "${pair%%|*}" "https://ok.example ${pair%%|*}"; do
    DEVKIT_MAVEN_MIRROR=$list sent "" "a malformed mirror is refused unprinted (without '${pair#*|}')" 1 \
      "ERROR: each entry of DEVKIT_MAVEN_MIRROR must be an https:// base URL with a host and no query, fragment, whitespace or control character" \
      "!${pair#*|}" "!Checking"
  done
done
# Only here: Python's \s refuses the non-ASCII whitespace U+00A0 that bash's [:space:] accepts (measured), the
# documented "at least as strictly".
DEVKIT_MAVEN_MIRROR=$'https://a.example\xc2\xa0https://b.example' sent "" "U+00A0 between two entries is refused unprinted (without 'a.example')" 1 \
  "ERROR: each entry of DEVKIT_MAVEN_MIRROR must be an https:// base URL with a host and no query, fragment, whitespace or control character" \
  "!a.example" "!Checking"

DEVKIT_MAVEN_MIRROR=https://mirror.example:8443/m2 sent "mirror.example:8443" "a mirror with a port is accepted, and the lookup goes to it" 0 \
  "against https://mirror.example:8443/m2..." "Could not check (1):" "!maven.vptr.de"
# Accepted by the rule, but no usable URL: a failed lookup, not a traceback.
for pair in "non-numeric port|https://h:abc/m2" "zero-width space|https://h.invalid/p"$'\xe2\x80\x8b'"q"; do
  DEVKIT_MAVEN_MIRROR=${pair#*|} sent "" "a mirror with a ${pair%%|*} that is no usable URL fails the lookup, not the report" 0 \
    "Could not check (1):" "Error: org.example:lib"
done

project "$own<properties><a.version>1.0</a.version><b.version>1.0</b.version></properties><dependencies>$(dep org.example a "$(ref a.version)")$(dep org.example b "$(ref b.version)")</dependencies>"
DEVKIT_MAVEN_MIRROR='https://a.example https://b.example' sent "a.example:443 b.example:443" \
  "two pins over two entries that never answer ask each entry once in total" 0 "Could not check (2):" "which the rest of this run skips"

# unit LABEL CODE: CODE, run with the script imported as v and OPENER stubbable, must print PASS. The
# prelude: Stub(BODY, DELAY) serves BODY without TLS after DELAY seconds; meta/versions build metadata;
# lookup(BODY, NAME=VALUE...) runs one lookup with module globals patched; redirect(URL, FP, OLD) asks
# the redirect handler about a redirect to URL; ByArtifact(ARTIFACT=BODY...) serves each artifact its
# own BODY; report(BODY) is the stdout of main() on BODY or a ByArtifact; bump(PINNED, ARTIFACT=BODY...)
# is get_bump_target's result for a pin at PINNED over those artifacts of group g; failover(A, B) is
# (result, bases left, URLs asked) of one lookup over the bases https://a and https://b, which answer
# A and B, each a body or an exception to raise
unit() {
  local out
  out=$(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv.pop(1)); import version_check as v
import contextlib, io, signal, time
class Stub:
    def __init__(self, body=b"", delay=0): self.body, self.delay = body, delay
    def open(self, url, timeout=None):
        time.sleep(self.delay)
        return io.BufferedReader(io.BytesIO(self.body))
def meta(inner): return ("<metadata><versioning>" + inner + "</versioning></metadata>").encode()
def versions(*vs): return meta("<versions>" + "".join(f"<version>{x}</version>" for x in vs) + "</versions>")
class Routed:
    def __init__(self, routes): self.routes, self.asked = routes, []
    def open(self, url, timeout=None):
        self.asked.append(url)
        answer = next(a for prefix, a in self.routes.items() if url.startswith(prefix))
        if isinstance(answer, Exception): raise answer
        return io.BufferedReader(io.BytesIO(answer))
def failover(a, b, artifact="a"):
    v.OPENER, bases = Routed({"https://a/": a, "https://b/": b}), ["https://a", "https://b"]
    return v.get_latest_version(bases, "g", artifact), bases, v.OPENER.asked
def status(code): return v.urllib.error.HTTPError("", code, "", {}, None)
def lookup(body, **patch):
    v.OPENER = Stub(body)
    for name, value in patch.items(): setattr(v, name, value)
    return v.get_latest_version(["https://a"], "g", "a")
def redirect(url, fp=None, old=None):
    return v.HttpsOnlyRedirects().redirect_request(old or v.urllib.request.Request("https://a/m"), fp, 302, "", {}, url)
class ByArtifact:
    def __init__(self, **bodies): self.bodies = bodies
    def open(self, url, timeout=None): return io.BufferedReader(io.BytesIO(self.bodies[url.split("/")[-2]]))
def report(body):
    v.OPENER, out = body if isinstance(body, ByArtifact) else Stub(body), io.StringIO()
    with contextlib.redirect_stdout(out): v.main()
    return out.getvalue()
def bump(pinned, **bodies):
    v.OPENER = ByArtifact(**bodies)
    return v.get_bump_target(v.Pin("p", pinned, [v.Coordinate("g", a) for a in bodies], True), ["https://r"])
'"$2"'
print("PASS")' "${script%/*}" 2>"$work/err") || :
  if [[ $out == PASS ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: got:"
    printf '%s\n' "$out" "$(<"$work/err")"
    fails=$((fails + 1))
  fi
}
for scheme in http ftp; do
  unit "a redirect to $scheme is refused" 'assert redirect("'$scheme'://a/m") is None'
done
unit "a redirect to https is followed" 'assert redirect("https://b/m").full_url == "https://b/m"'
unit "a followed redirect closes the old body and drops Proxy-authorization" '
old, fp = v.urllib.request.Request("https://a/m"), io.BytesIO()
old.add_header("Proxy-authorization", "Basic x")
new = redirect("https://b/m", fp, old)
assert fp.closed and "Proxy-authorization" not in new.headers and "Proxy-authorization" in old.headers'
unit "the opener's only redirect handler is the https-only one" \
  'hs = [h for h in v.OPENER.handlers if isinstance(h, v.urllib.request.HTTPRedirectHandler)]; assert [type(h) for h in hs] == [v.HttpsOnlyRedirects]'
unit "the lookup goes through the opener, the timer disarmed" '
assert lookup(versions("1.0", "2.0")) == "2.0" and signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)'
unit "metadata over the size cap is given up, the timer disarmed" '
assert lookup(versions("1.0", "2.0"), MAX_METADATA_BYTES=10) is None and signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)'
unit "a lookup is cut off by the wall clock, the timer disarmed" '
v.OPENER, v.LOOKUP_DEADLINE, start = Stub(versions("1.0"), delay=2), 0.2, time.monotonic()
assert v.get_latest_version(["https://a"], "g", "a") is None and time.monotonic() - start < 1
assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)'
unit "a lookup is cut off though the connect loop catches OSError, the timer disarmed" '
class Swallow(Stub):
    def open(self, url, timeout=None):
        try: time.sleep(3)
        except OSError: time.sleep(3)
        return super().open(url, timeout)
v.OPENER, v.LOOKUP_DEADLINE, start = Swallow(versions("1.0")), 0.2, time.monotonic()
assert v.get_latest_version(["https://a"], "g", "a") is None and time.monotonic() - start < 1
assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)'
unit "metadata with a DOCTYPE and an entity is refused" \
  'assert lookup(b"<!DOCTYPE m [<!ENTITY e \"1.0\">]><metadata><versioning><versions><version>&e;</version></versions></versioning></metadata>") is None'
for encoding in xxx shift_jis; do
  unit "an encoding declaration of $encoding is malformed metadata, not a traceback" \
    'assert lookup(b"<?xml version=\"1.0\" encoding=\"'$encoding'\"?><metadata/>") is None'
done
ua=https://a/g/a/maven-metadata.xml ub=https://b/g/a/maven-metadata.xml
both='["https://a", "https://b"]'
unit "an entry that gives no answer is dropped for the rest of the run, and the next one's answer returned" '
assert failover(v.urllib.error.URLError("refused"), versions("1.0", "2.0")) == ("2.0", ["https://b"], ["'$ua'", "'$ub'"])'
unit "an entry that times out is dropped for the rest of the run, and the next one's answer returned" '
assert failover(v.LookupTimeout("t"), versions("2.0")) == ("2.0", ["https://b"], ["'$ua'", "'$ub'"])'
unit "an entry that answers 5xx or 429 is kept, and the next one's answer returned" '
for code in (429, 500, 503, 599):
    assert failover(status(code), versions("2.0")) == ("2.0", '"$both"', ["'$ua'", "'$ub'"]), code'
unit "any other status is final: no answer from the next entry, the entry kept" '
for code in (301, 403, 404):
    assert failover(status(code), versions("2.0")) == (None, '"$both"', ["'$ua'"]), code'
unit "oversized or malformed metadata is final: the next entry is not asked" '
assert failover(versions("1.0", "2.0"), versions("3.0")) == ("2.0", '"$both"', ["'$ua'"])
v.MAX_METADATA_BYTES = 10
assert failover(versions("1.0", "2.0"), versions("3.0")) == (None, '"$both"', ["'$ua'"])
v.MAX_METADATA_BYTES = 1 << 20
assert failover(b"<metadata", versions("3.0")) == (None, '"$both"', ["'$ua'"])'
unit "entries that are all dead leave nothing to ask, and a later lookup makes no request" '
got, bases, asked = failover(v.urllib.error.URLError("refused"), v.LookupTimeout("t"))
assert (got, bases, asked) == (None, [], ["'$ua'", "'$ub'"])
assert v.get_latest_version(bases, "g", "b") is None and asked == ["'$ua'", "'$ub'"]'
unit "an artifact with a space or a non-ASCII character is asked percent-encoded, its 404 final, both entries kept" '
for artifact, enc in (("a b", "a%20b"), ("\u00e9", "%C3%A9")):
    got = failover(status(404), versions("2.0"), artifact)
    assert got == (None, '"$both"', ["https://a/g/" + enc + "/maven-metadata.xml"]), got'
unit "a repeated entry, with or without a trailing slash, is asked once" '
v.os.environ["DEVKIT_MAVEN_MIRROR"] = "https://h https://h/ https://i https://h"
assert v.repositories() == ["https://h", "https://i"]'
unit "entries that all answer 5xx are all kept" '
assert failover(status(503), status(500)) == (None, '"$both"', ["'$ua'", "'$ub'"])'
unit "the default list is the one scripts/lib/pinned_maven.sh holds" \
  'assert " ".join(v.DEFAULT_MIRRORS) == "'"$(sed -n 's/^default_mirrors=(\(.*\))$/\1/p' "${script%/java/*}/lib/pinned_maven.sh")"'"'
PROJECT_ROOT=$proj DEVKIT_MAVEN_MIRROR='https://a.example https://b.example' unit "two pins over two dead entries print the skip line once per entry" '
class Dead:
    def open(self, url, timeout=None): raise v.urllib.error.URLError("refused")
v.OPENER, err = Dead(), io.StringIO()
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err): v.main()
assert err.getvalue().count("which the rest of this run skips") == 2, err.getvalue()'
unit "a version of non-ASCII digits is not stable" 'assert not v.is_stable("\u00b2")'
unit "a non-ASCII-digit version is skipped for the stable one" 'assert lookup(versions("1.0", "\u00b2")) == "1.0"'
unit "a version of 5000 digits is unusable, not a traceback" 'assert lookup(versions("9" * 5000)) is None'
unit "a marker with a control character, a space, a comma or over 100 characters is no version, a plain one is" '
for bad in ("4.0&#x9b;31m", "4.0&#x7f;", "4.0&#xa;forged", "4.0&#x9;x", "3.0-beta, g:x at 9.9", "1" + "a" * 100):
    assert lookup(meta(f"<release>{bad}</release>")) is None, bad
for good in ("4.0.0-beta-4", "2.0.0.Final", "1.0+build_2", "1" + "a" * 99):
    assert lookup(meta(f"<release>{good}</release>")) == good, good'
unit "a latest that is no number is classified, not parsed" \
  'assert v.compare("1.0", "4.0.0-beta-4") == v.compare("1.0-rc1", "4.0.0-beta-4") == "unordered"'
project "$own<properties><lib.version>1.0</lib.version></properties><dependencies>$(dep org.example lib "$(ref lib.version)")</dependencies>"
PROJECT_ROOT=$proj unit "a release marker that is no number is printed as not compared" \
  'assert "is not numeric, not compared" in report(meta("<release>4.0.0-beta-4</release>"))'
unit "a pin's numeric artifacts hold it at their lowest latest, ordered as numbers" '
assert bump("1.0", a=versions("10.0"), b=versions("9.0")) == \
  ("9.0", "outdated", ["p held at 9.0 by its oldest artifact; newer available: g:a at 10.0"])'
unit "a pin mixing a numeric and a marker-only artifact is not compared, at the marker too, in either order" '
numeric, marker = versions("2.0"), meta("<release>3.0-beta</release>")
for pinned in ("1.0", "3.0-beta"):
    for got, a, b in [(bump(pinned, a=numeric, b=marker), "2.0", "3.0-beta"), (bump(pinned, a=marker, b=numeric), "3.0-beta", "2.0")]:
        assert got == ("3.0-beta", "unordered", [f"p not compared, a latest release is not numeric: g:a at {a}, g:b at {b}"]), got'
unit "a pin over differing markers names each, in no order, and is not compared at either" '
for pinned in ("3.0-beta", "2.0-rc1"):
    got = bump(pinned, a=meta("<release>3.0-beta</release>"), b=meta("<release>2.0-rc1</release>"))
    assert got == ("3.0-beta", "unordered", ["p not compared, a latest release is not numeric: g:a at 3.0-beta, g:b at 2.0-rc1"]), got'
unit "a pin over agreeing markers has no note, and is current at the marker" '
same = meta("<release>3.0-beta</release>")
assert bump("1.0", a=same, b=same) == ("3.0-beta", "unordered", []) and bump("3.0-beta", a=same, b=same) == ("3.0-beta", "current", [])'
unit "a pin with an artifact that could not be checked gets no target, whichever it is" '
assert bump("1.0", a=b"", b=versions("2.0")) == (None, "unchecked", ["could not check g:a"])
assert bump("1.0", a=versions("2.0"), b=b"") == (None, "unchecked", ["could not check g:b"])'
project "$own<properties><lib.version>1.0</lib.version></properties><dependencies>$(dep org.example a "$(ref lib.version)")$(dep org.example b "$(ref lib.version)")</dependencies>"
PROJECT_ROOT=$proj unit "a mixed pin is printed as not compared, and not as outdated" '
out = report(ByArtifact(a=versions("2.0"), b=meta("<release>3.0-beta</release>")))
assert "lib.version pinned at 1.0, latest release 3.0-beta is not numeric, not compared" in out and "Outdated" not in out, out'
PROJECT_ROOT=$proj unit "a pin with an artifact that could not be checked is printed under Could not check" '
out = report(ByArtifact(a=versions("2.0"), b=b""))
assert "Could not check (1):\n  lib.version (1.0)" in out and "Outdated" not in out, out'
for pair in "2.0|Outdated (1):" "1.0|Up to date: 1" "0.9|newer than the latest release"; do
  PROJECT_ROOT=$proj unit "a latest of ${pair%%|*} for the 1.0 pin prints '${pair#*|}'" \
    'assert "'"${pair#*|}"'" in report(versions("'"${pair%%|*}"'"))'
done

[[ $fails == 0 ]]
