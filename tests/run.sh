#!/usr/bin/env bash
# devkit's test entrypoint, for CI and by hand: tests/run.sh [shell] [java]
# [python], each part at most once (no argument runs all three). Prints
# PASS/FAIL per check with its time and status. java and python share one temp
# dir (TMPDIR is honoured) and the tree under test, published once.
#   shell  shellcheck every script, then tests/devkitw_test.sh,
#          tests/select_modules_test.sh, tests/make_test.sh,
#          tests/kill_test.sh, tests/check_frontend_deps_test.sh,
#          tests/parent_check_test.sh, tests/check_pins_test.sh,
#          tests/check_decisions_test.sh, tests/devkitw_lint_test.sh,
#          tests/python_floor_test.sh, tests/secrets_test.sh,
#          tests/markdown_test.sh, tests/hooks_test.sh,
#          tests/uv_project_test.sh, tests/get_uv_test.sh,
#          tests/sealed_dir_test.sh, tests/coverage_floor_test.sh,
#          tests/python_clean_test.sh, tests/java_clean_test.sh,
#          tests/duplication_test.sh, tests/anchored_match_test.sh,
#          tests/markdown_isolation_test.sh, tests/closure_audit_test.sh
#          and tests/tag_test.sh,
#          and that no includedLicense of the parent is empty or holds a line
#          break, a tab, a double space or edge whitespace, that no name is
#          listed twice and that the allowlist names the licenses devkit's
#          own tests rely on, and that each of those failures is reported;
#          make lint-repo, not this, gates devkit's own tree. Needs git
#          >= 2.34 (SSH signing), make, shellcheck, ssh-keygen (OpenSSH 8.1
#          or later), bash >= 4 (shopt globstar; macOS ships 3.2), procps
#          (pgrep, ps), tar, sha256sum or shasum,
#          python3 >= 3.11, and node (at or above engines.node in
#          markdown/package.json and jscpd/package.json) with npm, which
#          installs markdownlint-cli and jscpd from the npm registry on
#          first use.
#   java   tag the tree under test, committed or not, as v<the version of
#          java/parent/pom.xml> in a temp bare repo and run every
#          tests/fixtures/java-* consumer, pinned to that tag over file://
#          and committed as a git repository of its own, through make help,
#          check, lint, test, coverage and format; then make install
#          java-multimodule into a local repository of its own, which reads
#          through to ~/.m2, and expect its installed poms to name neither
#          devkit's parent nor an unresolved ${...}, and make test ONLY=app
#          to resolve core from them offline, and make test of a copy whose
#          app depends on a jar without a license to fail twice in a row,
#          without a clean between, and to pass once the module's
#          override-THIRD-PARTY.properties declares one, leaving its
#          sources unchanged, and of a copy whose app depends on a jar under
#          a license the parent does not list to fail twice in a row the
#          same way, and to pass once the module appends that license to
#          includedLicenses, and then, in that copy, two more jars each
#          under an allowed and a commercial license to pass;
#          then break copies of the monolith
#          (format, a shared and a project checkstyle rule, the project
#          rule's suppression, coverage, an image digest, Markdown, a secret
#          committed, staged or unstaged, a missing git object, a devkitw
#          without its revision line) and expect lint or test to fail for
#          that reason, and make format to
#          fix the format break so that lint passes; expect check to fail
#          without checkstyle-project.xml, on a FRONTEND_DIR that is neither
#          one of MODULES nor . in a monolith (and to pass on . there,
#          and on a listed module in java-multimodule),
#          without devkit's parent and on a
#          parent version that differs from the pin, and lint to fail on the
#          latter too, before Maven runs. Expect test to fail on a profile
#          MAVEN_ARGS requests, under mvn and under a script-only ./mvnw, and
#          check to fail on a ./mvnw that launches a maven-wrapper jar.
#          audit runs only without an NVD key, where it must refuse to
#          start; kill not at all here (the shell part tests it). Needs
#          JDK 25, Maven >= 3.9.9, python3, git >= 2.34 and ssh-keygen
#          (OpenSSH 8.1 or later), to sign and verify the tag, curl, tar,
#          node with npm and the network (Maven Central, Eclipse P2,
#          github.com, the npm registry);
#          ~/.m2 is used as is, and never installed into; the install checks
#          assume ~/.m2/repository is the local repository, and their offline
#          make test fails on missing plugins when settings.xml moves it.
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
#          project. Needs git >= 2.34, make, ssh-keygen (OpenSSH 8.1 or
#          later), python3 >= 3.11 with venv and pip, curl, tar, sha256sum or
#          shasum and the network (PyPI, its advisory API, github.com, and
#          uv's Python downloads when no CPython of the pin is installed),
#          and node with npm for the copy-paste gate, which installs jscpd
#          from the npm registry; the fixtures hold no Markdown, so lint-md
#          does not run markdownlint.
set -euo pipefail
if ((BASH_VERSINFO[0] < 4)); then
  echo "ERROR: tests/run.sh needs bash 4 or later (globstar); this is bash $BASH_VERSION." >&2
  exit 1
fi
shopt -s globstar

root=$(cd "$(dirname "$0")/.." && pwd)
fails=0

uncache() { chmod -R u+w "$@" 2>/dev/null || :; rm -rf "$@"; } # the caches are read-only, directories too
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
  check "make tests" "$root/tests/make_test.sh"
  check "kill tests" "$root/tests/kill_test.sh"
  check "check_frontend_deps tests" "$root/tests/check_frontend_deps_test.sh"
  check "parent_check tests" "$root/tests/parent_check_test.sh"
  check "check_pins tests" "$root/tests/check_pins_test.sh"
  check "check_decisions tests" "$root/tests/check_decisions_test.sh"
  check "devkitw lint tests" "$root/tests/devkitw_lint_test.sh"
  check "python floor tests" "$root/tests/python_floor_test.sh"
  check "markdown tests" "$root/tests/markdown_test.sh"
  check "secrets tests" "$root/tests/secrets_test.sh"
  check "hooks tests" "$root/tests/hooks_test.sh"
  check "uv_project tests" "$root/tests/uv_project_test.sh"
  check "get_uv tests" "$root/tests/get_uv_test.sh"
  check "sealed_dir tests" "$root/tests/sealed_dir_test.sh"
  check "coverage_floor tests" "$root/tests/coverage_floor_test.sh"
  check "python clean tests" "$root/tests/python_clean_test.sh"
  check "java clean tests" "$root/tests/java_clean_test.sh"
  check "duplication tests" "$root/tests/duplication_test.sh"
  check "anchored_match tests" "$root/tests/anchored_match_test.sh"
  check "markdown isolation tests" "$root/tests/markdown_isolation_test.sh"
  check "closure_audit tests" "$root/tests/closure_audit_test.sh"
  check "tag tests" "$root/tests/tag_test.sh"
  check "parent: no includedLicense entry is empty or holds a line break, a tab, a double space or edge whitespace, none is listed twice, and the allowlist names the required licenses" \
    license_lists_whole "$root/java/parent/pom.xml"
  check "parent: the license lists check rejects an includedLicense name wrapped over a line" \
    lists_reject 's|<includedLicense>Plexus<|<includedLicense>Plex\nus<|' "includedLicense entries that can never match"
  check "parent: the license lists check rejects an includedLicense name with a tab" \
    lists_reject 's|<includedLicense>Plexus<|<includedLicense>Plex\tus<|' "includedLicense entries that can never match"
  check "parent: the license lists check rejects an includedLicense name with a double space" \
    lists_reject 's|<includedLicense>MIT License<|<includedLicense>MIT  License<|' "includedLicense entries that can never match"
  check "parent: the license lists check rejects an includedLicense name with edge whitespace" \
    lists_reject 's|<includedLicense>Plexus<|<includedLicense> Plexus<|' "includedLicense entries that can never match"
  check "parent: the license lists check rejects an includedLicense name listed twice" \
    lists_reject 's|<includedLicense>Plexus</includedLicense>|&&|' "includedLicense entries listed twice"
  check "parent: the license lists check rejects an allowlist without a required name" \
    lists_reject '/<includedLicense>Unknown license</d' "required names missing from the allowlist"
}

# license_lists_whole POM: each includedLicense is one name, compared to a license name exactly as
# it stands, so it must not carry whitespace (Maven trims edge whitespace in element text, so that
# is harmless to the plugin, but kept out of the pom). The allowlist keeps the names devkit's own
# tests and fixtures rely on: "MIT License", for foreign_group's override; "Unknown license", the
# plugin's key for a dependency with no license, which failOnMissing must keep reporting as
# foreign_group expects; "Eclipse Public License v2.0", the license of the fixtures' junit jars;
# "The Apache License, Version 2.0", that of their opentest4j and apiguardian jars. No name is
# listed twice.
license_lists_whole() {
  python3 -c 'import re, sys, xml.etree.ElementTree as ET
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
root = ET.parse(sys.argv[1]).getroot()
included = [e.text or "" for e in root.iterfind(".//m:includedLicense", ns)]
odd = lambda e: not e or re.search(r"[\n\t]|  |^\s|\s$", e)
required = {"Eclipse Public License v2.0", "The Apache License, Version 2.0", "MIT License", "Unknown license"}
problems = {
    "includedLicense entries that can never match": [e for e in included if odd(e)],
    "includedLicense entries listed twice": sorted({e for e in included if included.count(e) > 1}),
    "required names missing from the allowlist": sorted(required - set(included)),
}
bad = {k: v for k, v in problems.items() if v}
sys.exit(f"license lists: {bad!r}") if bad or not included else None' "$1"
}

lists_reject() { # lists_reject SED TEXT: the check fails on the parent run through SED (which must change it), saying TEXT
  local edited err
  edited=$(sed "$1" "$root/java/parent/pom.xml") && [[ $edited != "$(<"$root/java/parent/pom.xml")" ]] &&
    ! err=$(license_lists_whole /dev/stdin <<<"$edited" 2>&1) && [[ $err == *"$2"* ]]
}

listed() { # listed SRC DEST: copy to DEST what git lists in SRC, tracked or untracked but not ignored
  mkdir "$2"
  git -C "$1" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do
      [[ ! -e $1/$f ]] || printf '%s\0' "$f" # skip deleted tracked files
    done | tar -C "$1" --null -T - -cf - | tar -C "$2" -xf -
}

# swap_signers FILE KEY.pub: replace the key type and blob of the signers= line
# of FILE by KEY.pub's, and fail unless that is the one line that changed.
swap_signers() {
  local line type blob changed
  read -r type blob _ <"$2"
  while IFS= read -r line; do
    if [[ $line == signers=* ]]; then
      printf '%s\n' "${line% * *} $type $blob'" # the last two fields
    else
      printf '%s\n' "$line"
    fi
  done <"$1" >"$1.new"
  changed=$(diff "$1" "$1.new" | grep -c '^[<>]' || :)
  [[ $changed == 2 && $(grep -c '^signers=' "$1") == 1 &&
    $(grep -c "^signers='.*'\$" "$1") == 1 ]] || { # one line, one key
    echo "swap_signers: $1 must change in only its signers= line" >&2
    return 1
  }
  cat "$1.new" >"$1" && rm "$1.new" # in place, keeping the mode
}

# The devkit a fixture pins: the tree under test as tag $tag on main (devkitw
# refuses a tag off main), signed by a key made here, in bare repo $bare. The
# tree's devkitw trusts the release key, so the published copy trusts this one.
publish() {
  local src=$work/src key=$work/release-key
  listed "$root" "$src"
  export GIT_CONFIG_GLOBAL=/dev/null # from here on: no url rewrites, no signing config
  ssh-keygen -q -t ed25519 -N '' -C '' -f "$key"
  swap_signers "$src/devkitw" "$key.pub"
  git -C "$src" init -q -b main
  git -C "$src" add -A
  git -C "$src" commit -q -m "tree under test"
  git -C "$src" -c gpg.format=ssh -c user.signingKey="$key" \
    tag -a -s -m "$tag" "$tag"
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
  cp "$work/src/devkitw" "$2/" # the published copy, which trusts the test key
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

sed_into() { # sed_into FILE SED: FILE run through SED in place, keeping its mode
  sed "$2" "$1" >"$1.new" && cat "$1.new" >"$1" && rm "$1.new"
}

edited() { # edited DIR FILE SED: a monolith copy in DIR with FILE run through SED
  setup "$root/tests/fixtures/java-monolith" "$1"
  sed_into "$1/$2" "$3"
}

negative() { # negative NAME TARGET TEXT FILE SED: break FILE in a monolith copy
  edited "$work/negative-$1" "$4" "$5"
  check "java-monolith: a $1 break fails make $2" \
    make_says fail "$work/negative-$1" "$2" "$3"
}

formatted() { # formatted FILE SED: make format undoes SED's break in a monolith copy, so that lint passes
  edited "$work/formatted" "$1" "$2" &&
    make_says pass "$work/formatted" format && make_says pass "$work/formatted" lint
}

negatives() {
  local main=src/main/java/devkit/fixture/Greeter.java
  local test=src/test/java/devkit/fixture/GreeterTest.java indent='s/^    public/  public/'
  negative format lint "format violations" "$main" "$indent"
  check "java-monolith: make format fixes a format break" formatted "$main" "$indent"
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
  negative devkitw lint "cp .devkit/devkitw devkitw" devkitw '/^# devkitw revision/d'
  negative no-parent check "which devkit requires since v0.2.0" pom.xml '/<parent>/,/<\/parent>/d'
  negative frontend-dir check "is neither one of MODULES" Makefile \
    's/^FRONTEND_DIR .*/FRONTEND_DIR := web/'
  negative frontend-root check "is neither one of MODULES" Makefile \
    's/^MODULES .*/MODULES := core/; s/^FRONTEND_DIR .*/FRONTEND_DIR := ./'
  negative frontend-words check "names several directories" Makefile \
    's/^MODULES .*/MODULES := core app/; s/^FRONTEND_DIR .*/FRONTEND_DIR := core app/'
  edited "$work/frontend-root" Makefile 's/^FRONTEND_DIR .*/FRONTEND_DIR := ./'
  check "java-monolith: make check passes with FRONTEND_DIR := ." \
    make_says pass "$work/frontend-root" check
  setup "$root/tests/fixtures/java-multimodule" "$work/frontend-module"
  sed_into "$work/frontend-module/Makefile" 's/^FRONTEND_DIR .*/FRONTEND_DIR := app/'
  check "java-multimodule: make check passes with FRONTEND_DIR := app" \
    make_says pass "$work/frontend-module" check
  local proj=$work/no-project-checkstyle
  setup "$root/tests/fixtures/java-monolith" "$proj"
  rm "$proj/checkstyle-project.xml"
  check "java-monolith: make check fails without checkstyle-project.xml" \
    make_says fail "$proj" check "checkstyle-project.xml"
  NVD_API_KEY='' check "java-monolith: make audit fails without an NVD key" \
    make_says fail "$work/java-monolith" audit "NVD_API_KEY not set"
  wrapper_checks
}

wrapped() { # wrapped DIR TYPE: DIR gets ./mvnw of distribution TYPE, for Maven 3.9.9, from the plugin get_maven.sh names
  local plugin
  plugin=$(grep -o 'org\.apache\.maven\.plugins:maven-wrapper-plugin:[0-9.]*' "$root/scripts/lib/get_maven.sh")
  (cd "$1" && ./devkitw path >/dev/null && mvn -B -q -N "$plugin:wrapper" -Dtype="$2" -Dmaven=3.9.9)
}

# A profile MAVEN_ARGS requests applies under either launcher get_maven.sh picks. The probe profile
# asks for a release no javac knows, so make test fails at compile only when the profile applies
# (javac's own message is localized). A ./mvnw that launches a wrapper jar, which ignores
# MAVEN_ARGS, fails make check.
wrapper_checks() {
  local proj=$work/profile old=$work/old-mvn jar=$work/negative-wrapper-jar
  local compiling=("Fatal error compiling" 99)
  edited "$proj" pom.xml \
    's|^</project>|  <profiles><profile><id>probe</id><properties><maven.compiler.release>99</maven.compiler.release></properties></profile></profiles>\n&|'
  check "java-monolith: a script-only ./mvnw is generated" wrapped "$proj" only-script
  MAVEN_ARGS=-Pprobe check "java-monolith: a profile in MAVEN_ARGS applies under mvn" \
    make_says fail "$proj" test "${compiling[@]}"
  # get_maven.sh passes over an mvn below 3.9.9 for ./mvnw; this one fails any build it is given.
  mkdir "$old"
  cat >"$old/mvn" <<'EOF'
#!/bin/sh
[ "$*" = "-B -version" ] && echo "Apache Maven 3.0.0" || exit 1
EOF
  chmod +x "$old/mvn"
  PATH=$old:$PATH MAVEN_ARGS=-Pprobe check "java-monolith: a profile in MAVEN_ARGS applies under ./mvnw" \
    make_says fail "$proj" test "${compiling[@]}"
  setup "$root/tests/fixtures/java-monolith" "$jar"
  check "java-monolith: a wrapper-jar ./mvnw is generated" wrapped "$jar" source
  check "java-monolith: make check fails on a ./mvnw that launches a wrapper jar" \
    make_says fail "$jar" check "launches a maven-wrapper jar, which ignores MAVEN_ARGS"
}

secret_negatives() { # each scan of the real gitleaks reads what it should
  local leak append proj blob
  # Built here, so this file holds no token; edited() leaves the change unstaged.
  leak="gh""p_$(printf '%s' {z..a} {9..0})"
  append="\$s/\$/\\n# $leak/" # a last line holding it: s, since BSD sed has no one-line a
  negative secret lint "leaks found: 1" Makefile "$append"
  proj=$work/negative-secret-committed
  edited "$proj" Makefile "$append"
  git -C "$proj" commit -q -am leak
  check "java-monolith: a committed secret fails make lint, found in history" \
    make_says fail "$proj" lint "leaks found: 1" \
    "Fingerprint: $(git -C "$proj" rev-parse HEAD):Makefile:github-pat:"
  proj=$work/negative-secret-staged
  edited "$proj" Makefile "$append"
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
  trap 'uncache "$work"' EXIT
  # shellcheck disable=SC2046 # one argument per variable name
  unset $(git rev-parse --local-env-vars) ONLY PROJECT_ROOT REVISION JUNIT_DIR COVERAGE_FLOOR MODULES SSH_AUTH_SOCK
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
  out_of_reactor
  check "java-multimodule: a dependency under a groupId that only starts with the project's is still license-checked, by every make test until an override declares its license" \
    foreign_group
  check "java-multimodule: a dependency under an unlisted license fails every make test, until the module appends it to includedLicenses, and two dependencies under an allowed and a commercial license pass" \
    unlisted
  negatives
}

flattened() { # flattened DIR: DIR holds installed poms, none naming devkit's parent or an unresolved ${...}
  [[ -n $(find "$1" -name '*.pom') ]] || return
  grep -rE --include='*.pom' 'devkit-parent|\$\{' "$1"
  (($? == 1)) # no match; 2, an error, fails too
}

# java-multimodule's app depends on core. Installed, the poms are flattened, so make test ONLY=app
# (-pl without -am) reads core from the local repository, offline. The fixture runs above filled
# ~/.m2 with every plugin make test needs; installs go to $work/m2 instead, so a SNAPSHOT never
# lands there.
out_of_reactor() {
  local proj=$work/out-of-reactor m2=$work/m2
  local -x MAVEN_ARGS="-Dmaven.repo.local=$m2 -Dmaven.repo.local.tail=$HOME/.m2/repository"
  setup "$root/tests/fixtures/java-multimodule" "$proj"
  check "java-multimodule: make install" make_says pass "$proj" install "Install completed."
  check "java-multimodule: installed poms name neither devkit's parent nor an unresolved \${...}" \
    flattened "$m2/devkit/fixture"
  MAVEN_ARGS="$MAVEN_ARGS -o" ONLY=app check "java-multimodule: make test ONLY=app resolves core offline" \
    make_says pass "$proj" test "Starting tests for app..." "Tests completed."
}

# install_dep NAME [LICENSE...]: a jar installed into the caller's MAVEN_ARGS repository as
# devkit.fixture.other:NAME:1.0, under each LICENSE given (alternatives), else with no license metadata.
install_dep() {
  local dep=$work/dep-$1 pom=() licenses='' name
  mkdir "$dep" && echo x >"$dep/x.txt" && jar cf "$dep/x.jar" -C "$dep" x.txt || return
  for name in "${@:2}"; do licenses+="<license><name>$name</name></license>"; done
  if [[ -n $licenses ]]; then
    printf '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>
<groupId>devkit.fixture.other</groupId><artifactId>%s</artifactId><version>1.0</version>
<licenses>%s</licenses></project>\n' "$1" "$licenses" >"$dep/pom.xml"
    pom=(-DpomFile="$dep/pom.xml")
  fi
  mvn -B -q install:install-file -Dfile="$dep/x.jar" -DgroupId=devkit.fixture.other -DartifactId="$1" \
    -Dversion=1.0 -Dpackaging=jar ${pom[@]+"${pom[@]}"}
}

depend_on() { # depend_on DIR NAME: DIR's app depends on devkit.fixture.other:NAME:1.0
  sed_into "$1/app/pom.xml" "s|^  <dependencies>|&\\n    <dependency>\\n      <groupId>devkit.fixture.other</groupId>\\n      <artifactId>$2</artifactId>\\n      <version>1.0</version>\\n    </dependency>|"
}

# with_dep DIR [LICENSE...]: a copy of java-multimodule in DIR whose app depends on a jar installed
# by install_dep as devkit.fixture.other:<DIR's name>:1.0.
with_dep() {
  install_dep "${1##*/}" "${@:2}" && setup "$root/tests/fixtures/java-multimodule" "$1" &&
    depend_on "$1" "${1##*/}"
}

# The parent excludes the project's own groupId from the license check by a pattern that ends it
# ((?=:)). A license-less jar under devkit.fixture.other, which only starts with the fixture's
# devkit.fixture, must still fail make test; with a bare ^\Qdevkit.fixture\E it would pass.
foreign_group() {
  local proj=$work/foreign-group
  local -x MAVEN_ARGS="-Dmaven.repo.local=$work/m2 -Dmaven.repo.local.tail=$HOME/.m2/repository -o"
  with_dep "$proj" || return
  # Twice: a failed run's THIRD-PARTY.txt let the next, un-cleaned one skip the license goal.
  ONLY=app make_says fail "$proj" test "There are some dependencies with no license" &&
    ONLY=app make_says fail "$proj" test "There are some dependencies with no license" || return
  # Declared as docs/contract.md says, committed: the plugin reads it and writes nothing to src.
  local override=app/src/license/override-THIRD-PARTY.properties changed
  mkdir -p "$proj/${override%/*}" && echo "devkit.fixture.other--${proj##*/}--1.0=MIT License" >"$proj/$override" &&
    git -C "$proj" add "$override" && git -C "$proj" commit -q -m override &&
    ONLY=app make_says pass "$proj" test && changed=$(git -C "$proj" status --porcelain -- app/src) &&
    [[ -z $changed ]]
}

# The parent allows only the licenses it lists under includedLicenses; FSL-1.1-ALv2 is not one of
# them, so a dependency under it fails make test, every time. A module appends the name with
# combine.children="append" and the dependency then passes. A second dependency, under the
# parent's first listed name, keeps passing only if the module's list is appended: without the
# attribute the module's names replace the parent's whole list. A third, under an unlisted name
# and the parent's first listed one, passes throughout: the plugin passes a dependency when any
# one of its licenses is listed. Last, two dependencies each under the parent's first listed name
# and "Commercial" pass: the parent sets no excludedLicenses, which plugin 2.7.1 would crash on
# (ConcurrentModificationException) with two such dependencies.
unlisted() {
  local proj=$work/unlisted first
  local -x MAVEN_ARGS="-Dmaven.repo.local=$work/m2 -Dmaven.repo.local.tail=$HOME/.m2/repository -o"
  first=$(python3 -c 'import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).getroot().find(".//{http://maven.apache.org/POM/4.0.0}includedLicense").text)' \
    "$root/java/parent/pom.xml") &&
    with_dep "$proj" "FSL-1.1-ALv2" && install_dep unlisted-first "$first" &&
    install_dep unlisted-any "Proprietary-Test" "$first" &&
    depend_on "$proj" unlisted-first && depend_on "$proj" unlisted-any || return
  # Twice: a failed run's THIRD-PARTY.txt let the next, un-cleaned one skip the license goal.
  ONLY=app make_says fail "$proj" test "There are some forbidden licenses used" &&
    ONLY=app make_says fail "$proj" test "There are some forbidden licenses used" || return
  # Appended, committed: the module's list adds to the parent's instead of replacing it.
  sed_into "$proj/app/pom.xml" "s|^</project>|  <build>\\n    <plugins>\\n      <plugin>\\n        <groupId>org.codehaus.mojo</groupId>\\n        <artifactId>license-maven-plugin</artifactId>\\n        <executions>\\n          <execution>\\n            <id>add-third-party</id>\\n            <configuration>\\n              <includedLicenses combine.children=\"append\">\\n                <includedLicense>FSL-1.1-ALv2</includedLicense>\\n              </includedLicenses>\\n            </configuration>\\n          </execution>\\n        </executions>\\n      </plugin>\\n    </plugins>\\n  </build>\\n&|" &&
    git -C "$proj" add app/pom.xml && git -C "$proj" commit -q -m append &&
    ONLY=app make_says pass "$proj" test || return
  # Dual-licensed under an allowed and a commercial name, two of them: the pass the parent keeps by
  # setting no excludedLicenses.
  install_dep unlisted-dual-1 "$first" "Commercial" && install_dep unlisted-dual-2 "$first" "Commercial" &&
    depend_on "$proj" unlisted-dual-1 && depend_on "$proj" unlisted-dual-2 &&
    ONLY=app make_says pass "$proj" test
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
  [[ -z ${4:-} ]] || sed_into "$dir/$4" "$5" || return
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
    's/^dependencies = \[\]/dependencies = ["six", "helper"]/; s|^package = false$|&\n[tool.uv.sources]\nhelper = { path = "libs/helper" }|' &&
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
  py_negative anchored-match lint "anchored .match() not accepted in devkit.toml: $greeter:" single installed "$greeter" \
    's/^"""Builds greetings."""$/&\n\nimport re/; s/if not name.strip():/if not name.strip() or re.match(r"^[a-z]+$", name):/'
  # shellcheck disable=SC2016 # sed's own $ addresses the last line
  py_negative anchored-match-config check "needs a reason saying why the match is safe" single "" devkit.toml \
    '$s/$/\n\n[[python.anchored-match.accepted]]\nfile = "src\/devkit_fixture\/greeter.py"\nfunction = "greet"/'
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
