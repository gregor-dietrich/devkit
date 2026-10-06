#!/usr/bin/env bash
# Tests for scripts/lib/python.sh: every script that runs a Python helper stops
# at the floor with one ERROR line under a python3 older than 3.11. No network.
# Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
proj=$work/proj
mkdir "$work/bin" "$proj"
touch "$proj/checkstyle-project.xml"
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
# A Maven get_maven.sh accepts.
cat >"$work/bin/mvn" <<'EOF'
#!/bin/bash
echo 'Apache Maven 3.9.9'
EOF
chmod +x "$work/bin/python3" "$work/bin/mvn"

# expect LABEL WANT-STATUS COMMAND...: COMMAND must exit WANT-STATUS with
# $want as its only ERROR line and no traceback
expect() {
  local label=$1 status=$2 out rc=0
  out=$(PATH=$work/bin:$PATH PROJECT_ROOT=$proj DEVKIT=$root JAVA_VERSION=25 "${@:3}" 2>&1) || rc=$?
  if [[ $rc == "$status" && $(grep ERROR <<<"$out") == "$want" && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $status and only [$want] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

expect "lint-pins stops at the floor" 1 "$root/scripts/pins.sh"
expect "lint-decisions stops at the floor" 1 "$root/scripts/decisions.sh"
expect "check stops at the floor" 13 "$root/scripts/java/check.sh"
# shellcheck disable=SC2016 # expanded by the inner bash
expect "get_maven.sh stops at the floor, before the parent POM check" 13 \
  bash -c 'cd "$PROJECT_ROOT" && . "$DEVKIT/scripts/lib/get_maven.sh"'
for script in check install lint test audit; do
  expect "uv $script stops at the floor" 1 "$root/scripts/python/$script.sh"
done

# A python3 that does not run at all: the floor says so instead of a version.
printf '#!/bin/bash\nexit 127\n' >"$work/bin/python3"
want="ERROR: devkit's Python helpers need python3 3.11 or later; found no working python3 on PATH."
expect "lint-pins stops at the floor without a working python3" 1 "$root/scripts/pins.sh"

[[ $fails == 0 ]]
