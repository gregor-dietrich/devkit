#!/usr/bin/env bash
# devkit's test entrypoint, for CI and by hand: tests/run.sh [shell] [java]
# (no argument runs both). Prints PASS/FAIL per check with its time and status.
#   shell  shellcheck every script, then tests/devkitw_test.sh,
#          tests/select_modules_test.sh, tests/kill_test.sh,
#          tests/check_frontend_deps_test.sh, tests/parent_check_test.sh,
#          tests/check_pins_test.sh and tests/check_decisions_test.sh; then
#          run lint-pins over devkit itself. Needs git, shellcheck, procps
#          (pgrep, ps) and python3 >= 3.11.
#   java   tag the tree under test, committed or not, as v<the version of
#          java/parent/pom.xml> in a temp bare repo and run every
#          tests/fixtures/java-* consumer, pinned to that tag over file://
#          and committed as a git repository of its own, through make help,
#          check, lint, test, coverage and format; then break copies of the
#          monolith (format, a shared and a project checkstyle rule, the
#          project rule's suppression, coverage, an image digest) and
#          expect lint or test to fail for that reason; expect check to fail
#          without checkstyle-project.xml, without devkit's parent and on a
#          parent version that differs from the pin, and lint to fail on the
#          latter too, before Maven runs.
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
  check "check_frontend_deps tests" "$root/tests/check_frontend_deps_test.sh"
  check "parent_check tests" "$root/tests/parent_check_test.sh"
  check "check_pins tests" "$root/tests/check_pins_test.sh"
  check "check_decisions tests" "$root/tests/check_decisions_test.sh"
  check "devkit's own tree passes lint-pins" \
    env PROJECT_ROOT="$root" DEVKIT="$root" "$root/scripts/pins.sh"
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

help_lists() { # make help lists lint once, the repository gates and the fixture's own target
  local out
  out=$(make --no-print-directory -C "$1" help) && printf '%s\n' "$out" &&
    [[ $(grep -c '^  make lint ' <<<"$out") == 1 && $out == *"make lint-repo "* &&
      $out == *"make lint-pins "* && $out == *"make hello "* ]]
}

setup() { # setup FIXTURE DIR: copy FIXTURE to DIR, pinned to the tag, as a git repo
  cp -R "$1" "$2"
  cp "$root/devkitw" "$2/"
  printf '[devkit]\nurl = "file://%s"\nversion = "%s"\ncommit = "%s"\n' \
    "$bare" "$tag" "$commit" >"$2/devkit.toml"
  # The repository gates read the files git lists.
  git -C "$2" init -q -b main && git -C "$2" add -A && git -C "$2" commit -q -m fixture
}

run_fixture() { # run_fixture DIR
  local name=${1##*/} proj=$work/${1##*/} target
  setup "$1" "$proj"
  check "$name: make help" help_lists "$proj"
  for target in check lint test coverage format; do
    check "$name: make $target" make --no-print-directory -C "$proj" "$target"
  done
  check "$name: no source changed (format included)" diff -r -x target \
    -x .git -x .devkit -x devkitw -x devkit.toml -x .coverage.md "$1" "$proj"
}

make_says() { # make_says pass|fail DIR TARGET TEXT: make TARGET ends so, saying TEXT
  local out ended=pass
  out=$(make --no-print-directory -C "$2" "$3" 2>&1) || ended=fail
  [[ $ended == "$1" && $out == *"$4"* ]] || {
    printf '%s\n' "$out"
    return 1
  }
}

edited() { # edited DIR FILE SED: a monolith copy in DIR with FILE run through SED
  setup "$root/tests/fixtures/java-monolith" "$1"
  sed "$3" "$1/$2" >"$1/$2.new" && mv "$1/$2.new" "$1/$2"
}

negative() { # negative NAME TARGET TEXT FILE SED: break FILE in a monolith copy
  edited "$work/negative-$1" "$4" "$5"
  check "java-monolith: a $1 break fails make $2" \
    make_says fail "$work/negative-$1" "$2" "$3"
}

negatives() {
  local main=src/main/java/devkit/fixture/Greeter.java
  local test=src/test/java/devkit/fixture/GreeterTest.java
  negative format lint "format violations" "$main" 's/^    public/  public/'
  negative checkstyle lint "Fully Qualified Class Names" "$main" \
    's/return name\./return java.util.Objects.requireNonNull(name)./'
  negative project-checkstyle lint "Fixture project rule" "$main" \
    's/^package .*/&\n\nimport java.util.Objects;/; s/return name\./return Objects.requireNonNull(name)./'
  # GreeterTest imports the banned class too; only its suppression lets lint pass.
  negative suppression lint "Fixture project rule" checkstyle-suppressions.xml '/FixtureObjects/d'
  # The blank-name branch goes untested; the test itself still passes.
  negative coverage test "Coverage checks have not been met" "$test" \
    's/greet(" ")/greet("world")/'
  negative digest lint "it carries no digest" compose.yaml 's/@sha256:[0-9a-f]*//'
  local parent_off_pin='/<parent>/,/<\/parent>/s|<version>[^<]*</version>|<version>0.0.0</version>|'
  negative parent-version check "devkit.toml pins" pom.xml "$parent_off_pin"
  negative parent-version-lint lint "devkit.toml pins" pom.xml "$parent_off_pin"
  negative no-parent check "which devkit requires since v0.2.0" pom.xml '/<parent>/,/<\/parent>/d'
  local proj=$work/no-project-checkstyle
  setup "$root/tests/fixtures/java-monolith" "$proj"
  rm "$proj/checkstyle-project.xml"
  check "java-monolith: make check fails without checkstyle-project.xml" \
    make_says fail "$proj" check "checkstyle-project.xml"
  NVD_API_KEY='' check "java-monolith: make audit fails without an NVD key" \
    make_says fail "$work/java-monolith" audit "NVD_API_KEY not set"
}

parent_version() { # the literal <version> of devkit's parent POM
  python3 -c 'import sys, xml.etree.ElementTree as ET
version = ET.parse(sys.argv[1]).getroot().findtext("{http://maven.apache.org/POM/4.0.0}version")
sys.exit("java/parent/pom.xml declares no <version>") if not version else print(version.strip())' \
    "$root/java/parent/pom.xml"
}

java_part() {
  work=$(mktemp -d) tag=v$(parent_version) bare=$work/devkit.git
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
