#!/usr/bin/env bash
# Tests for scripts/lib/python.sh: every script that runs a Python helper stops
# at the floor with one ERROR line under a python3 older than 3.11. No network,
# no Maven: get_maven.sh checks the floor, and then the parent POM, before it
# fetches the pinned Maven, so a curl stub that logs and fails sits first on
# PATH and every case asserts it was never called and that no pinned Maven was
# installed into the (temporary) XDG_CACHE_HOME. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
proj=$work/proj
mkdir "$work/bin" "$work/curl" "$proj"
touch "$proj/checkstyle-project.xml"
export XDG_CACHE_HOME=$work/cache
# shellcheck disable=SC2016 # expands when the stub runs
printf '#!/bin/sh\necho "curl $*" >>"%s/curl.log"\nexit 22\n' "$work" >"$work/curl/curl"
chmod +x "$work/curl/curl"
export PATH=$work/curl:$PATH
fails=0
want="ERROR: devkit's Python helpers need python3 3.11 or later; found 3.10.12."

# A python3 3.10 for PATH: the floor's probe gets its version and fails, and a
# helper run instead ends in a traceback, as tomllib's import would.
cat >"$work/bin/python3" <<'EOF'
#!/bin/bash
[[ "$1 $2" == "-I -c" ]] && { echo 3.10.12; exit 1; }
echo 'Traceback (most recent call last):' >&2
exit 1
EOF
chmod +x "$work/bin/python3"

# expect LABEL WANT-STATUS COMMAND...: COMMAND must exit WANT-STATUS with
# $want as its only ERROR line and no traceback, call no curl and install no
# Maven. FLOOR_PROJECT is the project root (default $proj), FLOOR_PYBIN the
# directory of the python3 on PATH (default the 3.10 stub's); not PROJECT,
# which make exports
expect() {
  local label=$1 status=$2 out rc=0
  out=$(PATH=${FLOOR_PYBIN:-$work/bin}:$PATH PROJECT_ROOT=${FLOOR_PROJECT:-$proj} DEVKIT=$root JAVA_VERSION=25 "${@:3}" 2>&1) || rc=$?
  if [[ $rc == "$status" && $(grep ERROR <<<"$out") == "$want" && $out != *Traceback* && ! -e $work/curl.log ]] &&
    ! compgen -G "$XDG_CACHE_HOME/devkit/tools/maven-*" >/dev/null; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $status and only [$want] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

expect "lint-pins stops at the floor" 1 "$root/scripts/pins.sh"
expect "lint-decisions stops at the floor" 1 "$root/scripts/decisions.sh"
expect "audit of the npm closures stops at the floor" 1 "$root/scripts/closure_audit.sh" markdown
expect "check stops at the floor" 13 "$root/scripts/java/check.sh"
# shellcheck disable=SC2016 # expanded by the inner bash
expect "get_maven.sh stops at the floor, before the parent POM check" 13 \
  bash -c 'cd "$PROJECT_ROOT" && . "$DEVKIT/scripts/lib/get_maven.sh"'
# shellcheck disable=SC2016 # expanded by the inner bash
expect "get_uv.sh stops at the floor" 1 \
  bash -c 'cd "$PROJECT_ROOT" && . "$DEVKIT/scripts/lib/get_uv.sh"'
for script in check install lint test audit; do
  expect "uv $script stops at the floor" 1 "$root/scripts/python/$script.sh"
done

# The parent POM check, with the real python3: exit 14, also before any download.
mkdir "$work/nostub" "$work/noparent"
echo '<project xmlns="http://maven.apache.org/POM/4.0.0"><groupId>g</groupId><artifactId>a</artifactId><version>1</version></project>' >"$work/noparent/pom.xml"
want="ERROR: pom.xml does not inherit de.vptr.devkit:devkit-parent, which devkit requires since v0.2.0; see \"Upgrading from v0.1.x\" in .devkit/README.md."
# shellcheck disable=SC2016 # expanded by the inner bash
FLOOR_PYBIN=$work/nostub FLOOR_PROJECT=$work/noparent expect "get_maven.sh stops at the parent POM check, before any download" 14 \
  bash -c 'cd "$PROJECT_ROOT" && . "$DEVKIT/scripts/lib/get_maven.sh"'
want="ERROR: devkit's Python helpers need python3 3.11 or later; found 3.10.12."

# A python3 that does not run at all: the floor says so instead of a version.
printf '#!/bin/bash\nexit 127\n' >"$work/bin/python3"
want="ERROR: devkit's Python helpers need python3 3.11 or later; found no working python3 on PATH."
expect "lint-pins stops at the floor without a working python3" 1 "$root/scripts/pins.sh"

[[ $fails == 0 ]]
