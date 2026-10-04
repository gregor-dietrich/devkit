#!/usr/bin/env bash
# devkit's test entrypoint, for CI and by hand: tests/run.sh [shell] [java]
# (no argument runs both). Prints PASS/FAIL per check with its time and status.
#   shell  shellcheck every script, then tests/devkitw_test.sh,
#          tests/select_modules_test.sh and tests/kill_test.sh.
#   java   tag the tree under test, committed or not, in a temp bare repo and
#          run every tests/fixtures/java-* consumer, pinned to that tag over
#          file://, through make help, check, lint, test, coverage and format;
#          then break copies of the monolith (format, a shared checkstyle
#          rule, coverage) and expect lint or test to fail for that reason.
#          audit runs only without an NVD key, where it must refuse to
#          start; kill not at all here (the shell part tests it). Needs
#          JDK 25, Maven >= 3.9.9, python3 and the network (Maven Central,
#          Eclipse P2); ~/.m2 is used as is.
set -euo pipefail
shopt -s globstar

root=$(cd "$(dirname "$0")/.." && pwd)
fails=0

check() { # check LABEL COMMAND...: run COMMAND and report how it went
  local label=$1 start=$SECONDS rc=0
  shift
  "$@" || rc=$?
  if [[ $rc == 0 ]]; then
    echo "PASS $label ($((SECONDS - start))s)"
  else
    echo "FAIL $label (exit $rc, $((SECONDS - start))s)"
    fails=$((fails + 1))
  fi
}

shellcheck_all() {
  (cd "$root" && shellcheck -x devkitw scripts/**/*.sh tests/*.sh)
}

shell_part() {
  check "shellcheck" shellcheck_all
  check "devkitw tests" "$root/tests/devkitw_test.sh"
  check "select_modules tests" "$root/tests/select_modules_test.sh"
  check "kill tests" "$root/tests/kill_test.sh"
}

# The devkit a fixture pins: the tree under test as tag $tag in bare repo $bare.
publish() {
  local src=$work/src
  mkdir "$src"
  git -C "$root" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do
      [[ ! -e $root/$f ]] || printf '%s\0' "$f" # skip deleted tracked files
    done | tar -C "$root" --null -T - -cf - | tar -C "$src" -xf -
  export GIT_CONFIG_GLOBAL=/dev/null # from here on: no signing, no url rewrites
  git -C "$src" init -q -b main
  git -C "$src" add -A
  git -C "$src" commit -q -m "tree under test"
  git -C "$src" tag -a "$tag" -m "$tag"
  git clone -q --bare "$src" "$bare"
  commit=$(git -C "$src" rev-parse HEAD)
}

help_lists() { # make help names a devkit target and the fixture's own one
  local out
  out=$(make --no-print-directory -C "$1" help) && printf '%s\n' "$out" &&
    [[ $out == *"make lint "* && $out == *"make hello "* ]]
}

setup() { # setup FIXTURE DIR: copy FIXTURE to DIR, pinned to the tag
  cp -R "$1" "$2"
  cp "$root/devkitw" "$2/"
  printf '[devkit]\nurl = "file://%s"\nversion = "%s"\ncommit = "%s"\n' \
    "$bare" "$tag" "$commit" >"$2/devkit.toml"
}

run_fixture() { # run_fixture DIR
  local name=${1##*/} proj=$work/${1##*/} target
  setup "$1" "$proj"
  check "$name: make help" help_lists "$proj"
  for target in check lint test coverage format; do
    check "$name: make $target" make --no-print-directory -C "$proj" "$target"
  done
  check "$name: no source changed (format included)" diff -r -x target \
    -x .devkit -x devkitw -x devkit.toml -x .coverage.md "$1" "$proj"
}

fails_with() { # fails_with DIR TARGET TEXT: make TARGET fails, saying TEXT
  local out rc=0
  out=$(make --no-print-directory -C "$1" "$2" 2>&1) || rc=$?
  [[ $rc != 0 && $out == *"$3"* ]] || {
    printf '%s\n' "$out"
    return 1
  }
}

negative() { # negative NAME TARGET TEXT FILE SED: break FILE in a monolith copy
  local proj=$work/negative-$1
  setup "$root/tests/fixtures/java-monolith" "$proj"
  sed "$5" "$proj/$4" >"$proj/$4.new" && mv "$proj/$4.new" "$proj/$4"
  check "java-monolith: a $1 break fails make $2" fails_with "$proj" "$2" "$3"
}

negatives() {
  local main=src/main/java/devkit/fixture/Greeter.java
  local test=src/test/java/devkit/fixture/GreeterTest.java
  negative format lint "format violations" "$main" 's/^    public/  public/'
  negative checkstyle lint "Fully Qualified Class Names" "$main" \
    's/return name\./return java.util.Objects.requireNonNull(name)./'
  # The blank-name branch goes untested; the test itself still passes.
  negative coverage test "Coverage checks have not been met" "$test" \
    's/greet(" ")/greet("world")/'
  NVD_API_KEY='' check "java-monolith: make audit fails without an NVD key" \
    fails_with "$work/java-monolith" audit "NVD_API_KEY not set"
}

java_part() {
  work=$(mktemp -d) tag=v0.0.0-test bare=$work/devkit.git
  trap 'rm -rf "$work"' EXIT
  # shellcheck disable=SC2046 # one argument per variable name
  unset $(git rev-parse --local-env-vars) ONLY PROJECT_ROOT REVISION
  export XDG_CACHE_HOME=$work/cache GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
  export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
  publish
  for fixture in "$root"/tests/fixtures/java-*/; do
    run_fixture "${fixture%/}"
  done
  negatives
}

[[ $# -gt 0 ]] || set -- shell java
for part in "$@"; do
  case $part in
    shell | java) "${part}_part" ;;
    *)
      echo "usage: tests/run.sh [shell] [java]" >&2
      exit 2
      ;;
  esac
done
[[ $fails == 0 ]] || {
  echo "$fails check(s) failed"
  exit 1
}
