#!/usr/bin/env bash
# devkit's test entrypoint, for CI and by hand: tests/run.sh [shell] [java]
# [python], each part at most once (no argument runs all three). Prints
# PASS/FAIL per check with its time and status. java and python share one temp
# dir (TMPDIR is honoured) and the tree under test, published once.
#   shell  shellcheck every script, then tests/devkitw_test.sh,
#          tests/select_modules_test.sh, tests/kill_test.sh,
#          tests/check_frontend_deps_test.sh, tests/parent_check_test.sh,
#          tests/check_pins_test.sh, tests/check_decisions_test.sh,
#          tests/python_floor_test.sh, tests/secrets_test.sh,
#          tests/markdown_test.sh, tests/hooks_test.sh,
#          tests/uv_project_test.sh, tests/get_uv_test.sh,
#          tests/coverage_floor_test.sh, tests/python_clean_test.sh and
#          tests/duplication_test.sh; then run lint-pins and lint-md over
#          devkit itself, and lint-secrets when the pinned gitleaks is
#          already in the tools cache (no download here). Needs git,
#          make, shellcheck, procps (pgrep, ps), tar, sha256sum or shasum,
#          python3 >= 3.11, and node (at or above engines.node in
#          markdown/package.json and jscpd/package.json) with npm, which
#          installs markdownlint-cli and jscpd from the npm registry on
#          first use.
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
#   python run every tests/fixtures/python-* consumer, pinned the same way, in
#          an environment no later part inherits: user-level uv configuration
#          (XDG_CONFIG_HOME), the caches and uv's Python downloads in the temp
#          dir, no pip configuration file, no inherited UV_*, PIP_*,
#          VIRTUAL_ENV or PYTHONPATH, and no uv of the fixtures' pin on PATH,
#          so the first make install runs the hash-verified uv bootstrap;
#          system-level uv configuration (/etc/uv) is not isolated. Then make
#          help, install, check, lint, test, format and audit (nothing to
#          audit); ruff's walk must skip the .devkit link, and nothing but
#          caches and .venv may change (uv.lock included). Then break copies
#          and expect lint (format, an unused import, an unused function, a
#          duplicated test module), test (coverage, coverage not activated),
#          install (a stale uv.lock), check (a tool missing from .venv, no
#          pytest-cov, the Python pin, its format, no .python-version,
#          COVERAGE_FLOOR unset or not a percent, no install, MODULES against
#          the workspace or as a glob, no [python.duplication] or
#          [tool.vulture] paths) and audit (a vulnerable dependency) to fail
#          for that reason. Expect make format to fix a format and an
#          unused-import break so that lint passes, and audit to pass on
#          current runtime dependencies, one of them through a local path
#          dependency. In the workspace, whose core is a package and app a
#          virtual member: test ONLY=packages/app tests app alone, lint
#          ONLY=packages/app passes over a format break in core that lint
#          fails, and JUNIT_DIR=reports writes one report per member into the
#          project. Needs git, make, python3 >= 3.11 with venv and pip, curl,
#          tar, sha256sum or shasum and the network (PyPI, its advisory API,
#          github.com, and uv's Python downloads when no CPython of the pin is
#          installed), and node with npm for the copy-paste gate, which
#          installs jscpd from the npm registry; the fixtures hold no Markdown,
#          so lint-md does not run markdownlint.
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
  check "python floor tests" "$root/tests/python_floor_test.sh"
  check "markdown tests" "$root/tests/markdown_test.sh"
  check "secrets tests" "$root/tests/secrets_test.sh"
  check "hooks tests" "$root/tests/hooks_test.sh"
  check "uv_project tests" "$root/tests/uv_project_test.sh"
  check "get_uv tests" "$root/tests/get_uv_test.sh"
  check "coverage_floor tests" "$root/tests/coverage_floor_test.sh"
  check "python clean tests" "$root/tests/python_clean_test.sh"
  check "duplication tests" "$root/tests/duplication_test.sh"
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

listed() { # listed SRC DEST: copy to DEST what git lists in SRC, tracked or untracked but not ignored
  mkdir "$2"
  git -C "$1" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do
      [[ ! -e $1/$f ]] || printf '%s\0' "$f" # skip deleted tracked files
    done | tar -C "$1" --null -T - -cf - | tar -C "$2" -xf -
}

# The devkit a fixture pins: the tree under test as tag $tag in bare repo $bare.
publish() {
  local src=$work/src
  listed "$root" "$src"
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
  listed "$1" "$2" # never a .venv, .devkit or cache of a developer's
  cp "$root/devkitw" "$2/"
  printf '[devkit]\nurl = "file://%s"\nversion = "%s"\ncommit = "%s"\n' \
    "$bare" "$tag" "$commit" >"$2/devkit.toml"
  # The fixture's own devkit.toml, if any, follows the pin.
  [[ ! -f $1/devkit.toml ]] || printf '\n%s\n' "$(<"$1/devkit.toml")" >>"$2/devkit.toml"
  # The repository gates read the files git lists.
  git -C "$2" init -q -b main && git -C "$2" add -A && git -C "$2" commit -q -m fixture
}

logged() { # logged DIR TARGET: make TARGET in DIR, its output also kept in DIR.TARGET.log
  make --no-print-directory -C "$1" "$2" 2>&1 | tee "$1.$2.log"
}

# run_fixture DIR TARGETS: make help, then each of TARGETS (space-separated) in $work/<DIR's name>,
# a pinned copy of DIR.
run_fixture() {
  local name=${1##*/} proj=$work/${1##*/} target
  setup "$1" "$proj"
  check "$name: make help" help_lists "$proj"
  for target in $2; do
    check "$name: make $target" logged "$proj" "$target"
  done
}

# unchanged DIR EXCLUDE...: run_fixture's copy of DIR differs from DIR only in .git, the .devkit
# link, devkitw, the pin (devkit.toml) and each EXCLUDE.
unchanged() {
  local excludes=() exclude
  for exclude in .git .devkit devkitw devkit.toml "${@:2}"; do
    excludes+=(-x "$exclude")
  done
  check "${1##*/}: no source changed (format included)" diff -r "${excludes[@]}" "$1" "$work/${1##*/}"
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

prepare() { # once per run: the temp dir, a clean environment and the published tree under test
  [[ -z ${work:-} ]] || return 0
  work=$(mktemp -d) tag=v$(parent_version) bare=$work/devkit.git
  trap 'rm -rf "$work"' EXIT
  # shellcheck disable=SC2046 # one argument per variable name
  unset $(git rev-parse --local-env-vars) ONLY PROJECT_ROOT REVISION JUNIT_DIR COVERAGE_FLOOR MODULES
  export XDG_CACHE_HOME=$work/cache GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
  export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
  publish
}

java_part() {
  prepare
  for fixture in "$root"/tests/fixtures/java-*/; do
    run_fixture "${fixture%/}" "check lint test coverage format"
    unchanged "${fixture%/}" target .coverage.md
  done
  negatives
  own_secrets # with the gitleaks the fixtures downloaded
}

ruff_skips_devkit() { # ruff's walk of DIR lists files, none of them through the .devkit link
  local files
  files=$(cd "$1" && .venv/bin/ruff check --show-files .) && [[ -n $files && $files != *"/.devkit/"* ]]
}

installed() { # installed DIR: make install in DIR, its output shown only when it fails
  make --no-print-directory -C "$1" install >"$1.install.log" 2>&1 || {
    cat "$1.install.log"
    return 1
  }
}

relocked() { # relocked DIR: uv lock in DIR with the pinned uv, then installed
  (cd "$1" && "$uv" lock -q) && installed "$1"
}

# py_copy FIXTURE NAME INSTALL [FILE SED]: $work/py-NAME, a pinned copy of the python-uv-FIXTURE
# fixture, installed first when INSTALL is "installed", then FILE run through SED, then relocked
# when INSTALL is "relocked".
py_copy() {
  local dir=$work/py-$2
  setup "$root/tests/fixtures/python-uv-$1" "$dir"
  [[ $3 != installed ]] || installed "$dir" || return
  [[ -z ${4:-} ]] || { sed "$5" "$dir/$4" >"$dir/$4.new" && mv "$dir/$4.new" "$dir/$4"; } || return
  [[ $3 != relocked ]] || relocked "$dir"
}

py_breaks() { # py_breaks NAME TARGET TEXT FIXTURE INSTALL [FILE SED]: make TARGET fails saying TEXT
  py_copy "$4" "$1" "$5" "${@:6}" && make_says fail "$work/py-$1" "$2" "$3"
}

py_negative() { # py_negative NAME TARGET TEXT FIXTURE INSTALL [FILE SED]
  check "python-uv-$4: a $1 break fails make $2" py_breaks "$@"
}

py_removed() { # py_removed NAME TARGET TEXT FIXTURE FILE: without FILE, make TARGET fails saying TEXT
  py_copy "$4" "$1" "" && rm "$work/py-$1/$5" && make_says fail "$work/py-$1" "$2" "$3"
}

py_uninstalled() { # a dev tool removed from .venv behind uv's back is drift
  local dir=$work/py-uninstalled
  py_copy single uninstalled installed &&
    "$uv" pip uninstall -q --python "$dir/.venv/bin/python" vulture &&
    make_says fail "$dir" check "uv cannot confirm .venv matches uv.lock"
}

py_only_app() { # ONLY=packages/app tests app, and never core
  local dir=$work/py-only out
  py_copy workspace only installed || return
  out=$(ONLY=packages/app make --no-print-directory -C "$dir" test 2>&1) &&
    [[ $out == *"Testing packages/app"* && $out != *packages/core* ]] && return
  printf '%s\n' "$out"
  return 1
}

py_only_lint() { # py_only_lint SED: core's greeter.py run through SED fails lint, not lint ONLY=packages/app
  local dir=$work/py-only-lint
  py_copy workspace only-lint installed packages/core/src/devkit_core/greeter.py "$1" &&
    ONLY=packages/app make_says pass "$dir" lint && make_says fail "$dir" lint "File would be reformatted"
}

py_junit() { # a relative JUNIT_DIR is the project's: one report per member there
  local dir=$work/py-junit
  py_copy workspace junit installed && JUNIT_DIR=reports make_says pass "$dir" test &&
    [[ -s $dir/reports/core.xml && -s $dir/reports/app.xml ]]
}

py_formatted() { # py_formatted FILE SED: make format undoes SED's breaks, so that lint passes
  py_copy single formatted installed "$1" "$2" &&
    make_says pass "$work/py-formatted" format && make_says pass "$work/py-formatted" lint
}

# A runtime dependency with known advisories, locked and installed. Not one pip-audit itself
# imports (urllib3, requests, ...): .venv holds both, and an old pin of those breaks pip-audit.
py_vulnerable() {
  py_copy single vulnerable relocked pyproject.toml 's/^dependencies = \[\]/dependencies = ["jinja2==3.1.4"]/' &&
    make_says fail "$work/py-vulnerable" audit "in 1 package" "jinja2 3.1.4"
}

# Current runtime dependencies without advisories, neither one pip-audit imports: six, and attrs
# through helper, a local path dependency (core's pyproject.toml renamed), which audit leaves out.
py_audited() {
  local dir=$work/py-audited helper=$work/py-audited/libs/helper
  py_copy single audited "" pyproject.toml \
    's/^dependencies = \[\]/dependencies = ["six", "helper"]/; /^package = false$/a [tool.uv.sources]\nhelper = { path = "libs/helper" }' &&
    mkdir -p "$helper/src/helper" && touch "$helper/src/helper/__init__.py" &&
    sed 's/"devkit-core"/"helper"/; s/^dependencies = \[\]/dependencies = ["attrs"]/' \
      "$root/tests/fixtures/python-uv-workspace/packages/core/pyproject.toml" >"$helper/pyproject.toml" &&
    relocked "$dir" && make_says pass "$dir" audit "Audit completed"
}

py_duplicated() { # a test module, one test longer, copied whole: a clone over 50 tokens
  local dir=$work/py-duplication
  py_copy single duplication installed tests/test_greeter.py \
    's/^        greet(" ")$/&\n\n\ndef test_greets_twice() -> None:\n    assert greet("a") + greet("b") == "Hello, aHello, b"/' &&
    cp "$dir/tests/test_greeter.py" "$dir/tests/test_greeter_copy.py" &&
    make_says fail "$dir" lint "duplicated code not accepted in devkit.toml: tests/test_greeter.py  ~  tests/test_greeter_copy.py"
}

python_negatives() {
  local greeter=src/devkit_fixture/greeter.py test=tests/test_greeter.py
  local quotes="s/f\"Hello, {name}\"/f'Hello, {name}'/" import='s/^"""Builds greetings."""$/&\n\nimport os/'
  py_negative format lint "File would be reformatted" single installed "$greeter" "$quotes"
  py_negative unused-import lint "F401" single installed "$greeter" "$import"
  py_negative unused-function lint "unused function 'unused'" single installed "$greeter" \
    's/^    return f"Hello, {name}"$/&\n\n\ndef unused() -> None:\n    """Nothing calls it."""/'
  check "python-uv-single: a duplication break fails make lint" py_duplicated
  check "python-uv-single: make format fixes a format and an unused-import break" py_formatted "$greeter" "$quotes; $import"
  py_negative duplication-config check "[python.duplication] in devkit.toml sets no paths" single "" devkit.toml '/^paths = /d'
  py_negative vulture-paths check "sets no [tool.vulture] paths" single "" pyproject.toml '/^paths = /d'
  py_negative coverage test "is below COVERAGE_FLOOR 100%" single installed "$test" "/^def test_rejects_a_blank_name/,\$d"
  py_negative coverage-activation test "wrote no coverage report" single installed pyproject.toml 's/--cov=src //'
  py_negative stale-lock install "needs to be updated" single "" pyproject.toml 's/^dependencies = \[\]/dependencies = ["urllib3"]/'
  py_negative python-pin check ".python-version pins 3.99" single installed .python-version 's/.*/3.99/'
  py_negative python-patch-pin check ".python-version pins 3.13.99" single installed .python-version 's/.*/3.13.99/'
  py_negative python-pin-format check "major.minor" single "" .python-version 's/.*/3/'
  check "python-uv-single: a missing .python-version fails make check" \
    py_removed no-python-version check "no .python-version at the project root" single .python-version
  py_negative coverage-floor check "COVERAGE_FLOOR is not set" single "" Makefile '/^COVERAGE_FLOOR/d'
  py_negative coverage-floor-range check "COVERAGE_FLOOR '101' is not a percent" single "" Makefile 's/:= 100$/:= 101/'
  py_negative never-installed check "no .venv; run make install" single ""
  py_negative pytest-cov check "has no pytest_cov" single relocked pyproject.toml 's/"pytest-cov", //'
  py_negative modules check "differs from the packages uv.lock records" workspace "" Makefile \
    's|packages/core packages/app|packages/core|'
  py_negative modules-glob check "holds a glob character" workspace "" Makefile 's|packages/core packages/app|packages/*|'
  check "python-uv-single: a tool removed from .venv fails make check" py_uninstalled
  check "python-uv-workspace: make test ONLY=packages/app tests app alone" py_only_app
  check "python-uv-workspace: make lint ONLY=packages/app skips core's ruff passes" py_only_lint "$quotes"
  check "python-uv-workspace: JUNIT_DIR=reports writes one report per member into the project" py_junit
  check "python-uv-single: a vulnerable dependency fails make audit" py_vulnerable
  check "python-uv-single: make audit passes on current dependencies, leaving a path one out" py_audited
}

python_part() {
  prepare
  # A subshell, so that no later part inherits the environment python_checks sets; check counts
  # failures there, and $work/fails carries the count back.
  (
    python_checks
    echo "$fails" >"$work/fails"
  )
  fails=$(<"$work/fails")
}

python_checks() {
  local fixtures=("$root"/tests/fixtures/python-*/) first pin uv dir path='' dirs fixture
  first=${fixtures[0]%/}
  pin=$(PROJECT_ROOT=$first python3 "$root/scripts/python/uv_project.py" uv-version)
  uv=$XDG_CACHE_HOME/devkit/uv/$pin/bin/uv # where the bootstrap puts it; it locks the copies too
  # User-level uv configuration (XDG_CONFIG_HOME), the caches (XDG_CACHE_HOME) and uv's Python
  # downloads stay in $work, and pip reads no configuration file. No uv of the pin on PATH, so
  # the first make install runs the hash-verified bootstrap; later ones find its uv in the cache.
  # shellcheck disable=SC2046 # one argument per variable name
  unset VIRTUAL_ENV PYTHONPATH $(compgen -e | grep -E '^(UV|PIP)_')
  export XDG_CONFIG_HOME=$work/config UV_PYTHON_INSTALL_DIR=$work/uv-python npm_config_cache=$work/npm-cache \
    PIP_CONFIG_FILE=/dev/null
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    [[ -x $dir/uv && "$("$dir/uv" --version 2>/dev/null) " == "uv $pin "* ]] || path+=${path:+:}$dir
  done
  export PATH=$path
  for fixture in "${fixtures[@]}"; do
    fixture=${fixture%/}
    run_fixture "$fixture" "install check lint test format"
    check "${fixture##*/}: make audit has nothing to audit" \
      make_says pass "$work/${fixture##*/}" audit "nothing to audit"
    check "${fixture##*/}: ruff's walk skips the .devkit link" ruff_skips_devkit "$work/${fixture##*/}"
    unchanged "$fixture" .venv __pycache__ .pytest_cache .ruff_cache .coverage
  done
  check "${first##*/}: the first make install bootstraps uv" grep -q "Installing uv $pin" "$work/${first##*/}.install.log"
  python_negatives
}

[[ $# -gt 0 ]] || set -- shell java python
seen=' '
for part in "$@"; do
  [[ $part =~ ^(shell|java|python)$ && $seen != *" $part "* ]] || {
    echo "usage: tests/run.sh [shell] [java] [python], each part at most once" >&2
    exit 2
  }
  seen+="$part "
done
for part in "$@"; do "${part}_part"; done
[[ $fails == 0 ]] || {
  echo "$fails check(s) failed"
  exit 1
}
