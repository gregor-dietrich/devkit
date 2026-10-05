#!/usr/bin/env bash
# devkit's test entrypoint, for CI and by hand: tests/run.sh [shell] [java]
# (no argument runs both). Prints PASS/FAIL per check with its time and status.
#   shell  shellcheck every script, then tests/devkitw_test.sh,
#          tests/select_modules_test.sh, tests/kill_test.sh,
#          tests/check_frontend_deps_test.sh, tests/parent_check_test.sh,
#          tests/check_pins_test.sh, tests/check_decisions_test.sh,
#          tests/secrets_test.sh, tests/markdown_test.sh and tests/hooks_test.sh;
#          then run lint-pins and lint-md over devkit itself, and lint-secrets
#          when the pinned gitleaks is already in the tools cache (no download
#          here). Needs git, make, shellcheck, procps (pgrep, ps), tar,
#          sha256sum or shasum, python3 >= 3.11, and node (at or above
#          engines.node in markdown/package.json) with npm, which installs
#          markdownlint-cli from the npm registry on first use.
#   java   tag the tree under test, committed or not, as v<the version of
#          java/parent/pom.xml> in a temp bare repo and run every
#          tests/fixtures/java-* consumer, pinned to that tag over file://
#          and committed as a git repository of its own, through make help,
#          check, lint, test, coverage and format; then break copies of the
#          monolith (format, a shared and a project checkstyle rule, the
#          project rule's suppression, coverage, an image digest, Markdown,
#          a secret committed, staged or unstaged, a missing git object) and
#          expect lint or test to fail for that reason; expect check to fail
#          without checkstyle-project.xml, without devkit's parent and on a
#          parent version that differs from the pin, and lint to fail on the
#          latter too, before Maven runs; then run lint-secrets over devkit
#          itself with the gitleaks that make lint downloaded and verified.
#          audit runs only without an NVD key, where it must refuse to
#          start; kill not at all here (the shell part tests it). Needs
#          JDK 25, Maven >= 3.9.9, python3, curl, tar, node with npm and the
#          network (Maven Central, Eclipse P2, github.com, the npm registry);
#          ~/.m2 is used as is.
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
  check "markdown tests" "$root/tests/markdown_test.sh"
  check "secrets tests" "$root/tests/secrets_test.sh"
  check "hooks tests" "$root/tests/hooks_test.sh"
  check "devkit's own tree passes lint-pins" \
    env PROJECT_ROOT="$root" DEVKIT="$root" "$root/scripts/pins.sh"
  check "devkit's own tree passes lint-md" \
    env PROJECT_ROOT="$root" DEVKIT="$root" "$root/scripts/markdown.sh"
  local version
  version=$(sed -n 's/^version=//p' "$root/scripts/secrets.sh")
  if compgen -G "${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools/gitleaks-$version-*/gitleaks" >/dev/null; then
    own_secrets
  else
    echo "PASS devkit's own repository passes lint-secrets (skipped: gitleaks $version is not cached; the java part runs it)"
  fi
}

own_secrets() {
  check "devkit's own repository passes lint-secrets" \
    env PROJECT_ROOT="$root" DEVKIT="$root" "$root/scripts/secrets.sh"
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

help_lists() { # make help lists lint and format once, the repository gates and the fixture's own target
  local out
  out=$(make --no-print-directory -C "$1" help) && printf '%s\n' "$out" &&
    [[ $(grep -c '^  make lint ' <<<"$out") == 1 && $(grep -c '^  make format ' <<<"$out") == 1 &&
      $out == *"make lint-repo "* && $out == *"make lint-pins "* && $out == *"make lint-secrets "* &&
      $out == *"make lint-md "* && $out == *"make format-md "* && $out == *"make hello "* ]]
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

make_says() { # make_says pass|fail DIR TARGET TEXT...: make TARGET ends so, saying each TEXT
  local out ended=pass text
  out=$(make --no-print-directory -C "$2" "$3" 2>&1) || ended=fail
  for text in "${@:4}"; do [[ $out == *"$text"* ]] || ended="$ended, without '$text'"; done
  [[ $ended == "$1" ]] || {
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
  # Built here, so this file holds no token; edited() leaves the change unstaged.
  secret_negatives
  negative markdown lint "MD018" README.md 's/^# /#/'
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

secret_negatives() { # each scan of the real gitleaks reads what it should
  local leak proj blob
  # Built here, so this file holds no token; edited() leaves the change unstaged.
  leak="gh""p_$(printf '%s' {z..a} {9..0})"
  negative secret lint "leaks found: 1" Makefile "\$a # $leak"
  proj=$work/negative-secret-committed
  edited "$proj" Makefile "\$a # $leak"
  git -C "$proj" commit -q -am leak
  check "java-monolith: a committed secret fails make lint, found in history" \
    make_says fail "$proj" lint "leaks found: 1" \
    "Fingerprint: $(git -C "$proj" rev-parse HEAD):Makefile:github-pat:"
  proj=$work/negative-secret-staged
  edited "$proj" Makefile "\$a # $leak"
  git -C "$proj" add Makefile
  check "java-monolith: a staged secret fails make lint" \
    make_says fail "$proj" lint "leaks found: 1" "Fingerprint: Makefile:github-pat:"
  # gitleaks itself passes a history scan whose git log fails.
  proj=$work/negative-missing-object
  setup "$root/tests/fixtures/java-monolith" "$proj"
  blob=$(git -C "$proj" rev-parse HEAD:compose.yaml)
  rm -f "$proj/.git/objects/${blob:0:2}/${blob:2}"
  check "java-monolith: a missing object fails make lint" \
    make_says fail "$proj" lint "git failed under gitleaks git --log-opts=HEAD"
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
  own_secrets # with the gitleaks the fixtures downloaded
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
