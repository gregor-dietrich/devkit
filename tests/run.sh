#!/usr/bin/env bash
# devkit's test entrypoint, for CI and by hand: tests/run.sh [shell] [java]
# [python] [floor], each part at most once (no argument runs all four). Prints
# PASS/FAIL per check with its time and status. The parts always run in that
# order, whatever the command line's: floor follows python, whose first make
# install must bootstrap uv. floor, java and python share one temp dir (TMPDIR
# is honoured); java and python also share the tree under test, published once
# by whichever runs first.
#   shell  shellcheck every script, then tests/devkitw_test.sh,
#          tests/select_modules_test.sh, tests/make_test.sh,
#          tests/kill_test.sh, tests/check_frontend_deps_test.sh,
#          tests/parent_check_test.sh, tests/check_pins_test.sh,
#          tests/check_decisions_test.sh, tests/devkitw_lint_test.sh,
#          tests/python_floor_test.sh, tests/secrets_test.sh,
#          tests/markdown_test.sh, tests/hooks_test.sh,
#          tests/uv_project_test.sh, tests/get_uv_test.sh,
#          tests/pinned_maven_test.sh, tests/mvn_checked_test.sh,
#          tests/formatter_lockfile_test.sh,
#          tests/sealed_dir_test.sh,
#          tests/coverage_floor_test.sh, tests/coverage_test.sh,
#          tests/version_check_test.sh, tests/python_invocations_test.sh,
#          tests/python_clean_test.sh, tests/python_audit_test.sh,
#          tests/python_audit_judge_test.sh,
#          tests/java_clean_test.sh,
#          tests/duplication_test.sh, tests/anchored_match_test.sh,
#          tests/markdown_isolation_test.sh, tests/closure_audit_test.sh,
#          tests/tag_test.sh and tests/git_tooling_test.sh,
#          and that no includedLicense of the parent is empty or holds a line
#          break, a tab, a double space or edge whitespace, that no name is
#          listed twice and that the allowlist names the licenses devkit's
#          own tests rely on, and that each of those failures is reported,
#          and that docs/contract.md lists the parent's *.version properties
#          and execution ids, no more and no fewer, and that each way of
#          drifting is reported, that spotbugs-plugin.version is
#          spotbugs.version plus a fourth component, and that the parent's
#          SpotBugs analyzer dependency excludes log4j-core, as the plugin's
#          own declaration does, and that the parent itself declares UTF-8
#          as its source and report encoding, and that each of those three
#          checks rejects a copy of the parent that breaks it (a plugin
#          bumped alone, a log4j exclusion of another groupId, no report
#          encoding),
#          and that java/config/findsecbugs-crlf-jboss-logging.txt passes
#          scripts/java/jboss_logging_sinks.py --check and that the check
#          rejects a copy whose long-argument line lists the argument's
#          slots instead of the format's, that java/config/pmd-ruleset.xml
#          sets no property but the ones devkit means to and that the check
#          rejects a raised complexity threshold and an extra property,
#          and that java/checksums/checksums.sha256 lists the jar of every
#          plugin (find-sec-bugs' detector included), plugin dependency and
#          annotation processor the parent pins and of the plugins
#          check_frontend_deps.py runs, and that a file without one is
#          rejected, naming it and make maven-checksums, that the
#          enforcer's jar, find-sec-bugs' jar and the pinned Maven
#          distribution's own line are among them (the last needs the
#          line of the pin in scripts/lib/pinned_maven.sh, so a Maven
#          bump without make maven-checksums fails here), and that
#          MVN_LAUNCHER and pinned_maven.sh are used only where they may be;
#          make lint-repo, not this, gates devkit's own tree. Needs git
#          >= 2.34 (SSH signing), make, shellcheck, ssh-keygen (OpenSSH 8.1
#          or later), bash >= 4 (shopt globstar; macOS ships 3.2), procps
#          (pgrep, ps), tar, sha256sum or shasum,
#          python3 >= 3.11, and node (at or above engines.node in
#          markdown/package.json and jscpd/package.json) with npm, which
#          installs markdownlint-cli and jscpd from the npm registry on
#          first use.
#   floor  install the uv the python-uv-single fixture's uv.lock pins (the
#          python part's copy, when it ran first), have it create venvs of
#          CPython 3.11 (the helpers' floor) and 3.14 (newest_python, the
#          newest stable, for the anchored-match gate that runs on the
#          project's Python; a check fails when the pinned uv lists a newer
#          stable minor), check each version, compile every scripts/**/*.py
#          under each, and run every shell-part test (not the shellcheck run,
#          not the parent checks) under each. uv uses an installed CPython of
#          the minor before it downloads one. The floor's isolation: no uv
#          configuration file (--no-config: the venvs are made under the temp
#          dir, where uv would otherwise read a uv.toml from a parent
#          directory), XDG_*, the
#          pip cache and uv's Python downloads in the temp dir, no inherited
#          UV_*, PIP_*, VIRTUAL_ENV or PYTHONPATH, no bytecode written;
#          system-level uv configuration (/etc/uv) is not isolated. Needs what
#          the shell part needs, python3 with venv and pip, and the network
#          (PyPI, github.com for uv's Python downloads, the npm registry).
#   java   tag the tree under test, committed or not, as v<the version of
#          java/parent/pom.xml> in a temp bare repo and run every
#          tests/fixtures/java-* consumer, pinned to that tag over file://
#          and committed as a git repository of its own, through make help,
#          check, lint, test, coverage and format, the passing lint, test
#          and coverage logs without a [WARNING] line; then make install
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
#          then alter the compiler plugin's jar in a copy's local repository
#          (read-through to ~/.m2 otherwise) and expect lint to fail on a
#          checksum mismatch (java/checksums), and
#          break copies of the monolith
#          (format, a shared and a project checkstyle rule, the project
#          rule's suppression, coverage, an image digest, Markdown, a secret
#          committed, staged or unstaged, behind a -diff attribute, in a
#          conflict resolution, a change a clean merge adds or behind a
#          textconv driver, a missing git object, a devkitw without its
#          revision line) and expect lint or test to fail for that reason
#          (and the conflict resolution's fingerprint in .gitleaksignore to
#          pass lint), and make format to
#          fix the format break so that lint passes; expect check to fail
#          without checkstyle-project.xml, on a FRONTEND_DIR that is neither
#          one of MODULES nor . in a monolith (and to pass on . there,
#          and on a listed module in java-multimodule),
#          without devkit's parent, on a JDK other than JAVA_VERSION
#          (test too) and on a Maven outside devkit.maven.range, and on a
#          parent version that differs from the pin, and lint to fail on the
#          latter too, before Maven runs. Expect test to fail on a profile
#          MAVEN_ARGS requests, under the Maven devkit pins, which the first
#          make target downloads into the temp dir's tools cache. Expect
#          every upper-case variable Maven's launcher expands to be one it
#          sets itself, one listed as harmless, or one make gate and
#          pre-push screen, hooks_test.sh tests and clean_env clears, and
#          the check to fail on a Maven other than the one the lists were
#          reviewed against.
#          Expect lint to fail on a duplicated block, CPD naming each place.
#          Expect lint to fail on a test whose only check is an assertion
#          helper PMD does not know, naming the PMD violation, until the
#          pom's pmd.extraAssertMethodNames names it, and then to pass
#          whatever plugin-level resources configuration the pom carries.
#          Expect the monolith to resolve spotbugs-annotations, provided, at
#          the parent's spotbugs.version, SpotBugs to report that analyzer,
#          the parent's UTF-8 encoding to reach it, jars under the common
#          license spellings to pass, checkstyle-xpath-suppressions.xml to
#          suppress a violation from another working directory and another
#          maven.multiModuleProjectDirectory too, a NullAway suppression to
#          fail lint in main sources, also in a checkout below a src/test
#          directory, and pass in tests, make test with the integration tests
#          on (MAVEN_ARGS=-DskipITs=false) to pass, and the parent's
#          exclusions on the SpotBugs analyzer to equal the plugin pom's own,
#          each case of tests/fixtures/checkstyle-cases, in a copy below a
#          src/test directory, to report the shared Checkstyle rules its
#          directory is named after and nothing else, the allowed ones
#          nothing, and the test exemptions of ConsoleOutput and LogManager to
#          pass their test cases,
#          and find-sec-bugs to run: an XML parser open to external entities
#          and a JBoss Logging call of an untrusted value to fail lint, the
#          JAX-RS endpoint marker excluded, with no analysis error. Expect
#          javac's serial and this-escape lint to fail lint under -Werror,
#          naming the file and position; once the module appends
#          -Xlint:-serial or -Xlint:-this-escape, SpotBugs' matching pattern
#          to fail it where SpotBugs reports the construct, and lint to pass
#          once that pattern is excluded, or at once for a constructor
#          handing this out, which SpotBugs does not report; and PMD's
#          ConstructorCallsOverridableMethod to fail it too, until the
#          module's own pmd-ruleset.xml references the kit's filtered copy and
#          excludes that rule (docs/contract.md), which still leaves PMD's
#          other rules and pmd.extraAssertMethodNames in force; the same in a
#          java-multimodule module, whose reference is
#          <module dir>/target/devkit/pmd-ruleset.xml, for lint and lint
#          ONLY=<module dir>. Expect a catch that throws a new exception
#          without the caught one as its cause and a method over
#          PMD's default cyclomatic complexity to fail lint, naming
#          PreserveStackTrace and CyclomaticComplexity. Expect imports
#          of java, org and jakarta in the order from before jakarta joined
#          the import order to fail lint, and make format to put jakarta
#          after java and before org. Expect the
#          committed java/checksums/checksums.sha256 to list every artifact
#          of the formatter version the parent pins, whose lockfile
#          spotless-lib-extra (from ~/.m2, after the fixtures ran) embeds
#          (scripts/java/formatter_lockfile.py), so that a bump of
#          eclipse-formatter.version without make maven-checksums fails.
#          audit runs only without an NVD key, where it must refuse to
#          start; kill not at all here (the shell part tests it). Needs
#          JDK 25, python3, git >= 2.36 (SSH signing; lint-secrets' remerge)
#          and ssh-keygen (OpenSSH 8.1 or later), to sign and verify the tag,
#          curl, tar, sha256sum or shasum, node with npm and the network (the
#          default DEVKIT_MAVEN_MIRROR list, of which Maven Central alone
#          suffices, github.com, the npm registry);
#          ~/.m2 is used as is, and never installed into; tampered_plugin
#          copies the compiler plugin's jar from ~/.m2/repository, and the
#          install checks assume it is the local repository, and their
#          offline make test fails on missing plugins when settings.xml moves
#          it.
#   python run every tests/fixtures/python-* consumer, pinned the same way, in
#          an environment no later part inherits: user-level uv configuration
#          (XDG_CONFIG_HOME), the caches and uv's Python downloads in the temp
#          dir, no pip configuration file, no inherited UV_*, PIP_*,
#          VIRTUAL_ENV or PYTHONPATH; the first make install runs the
#          hash-verified uv bootstrap, whatever uv is on PATH, and the second
#          fixture reuses its copy; system-level uv configuration (/etc/uv) is
#          not isolated. Then make
#          help, install, check, lint, test, format and audit (nothing to
#          audit); ruff's walk must skip the .devkit link, and nothing but
#          caches and .venv may change (uv.lock included). Then break copies
#          and expect lint (format, an unused import, an unused function, a
#          duplicated test module, an unparseable file only the anchored-match
#          gate reads, which it must report with .venv's Python), run no .pth
#          file of .venv's site-packages in that gate (with -S dropped, in a
#          scratch copy of lint.sh, it must), test
#          (coverage, coverage not activated, a package installed behind uv's
#          back or a uv.lock changed without make install, the pinned uv copy
#          missing, a workspace member's or a packaged root's pyproject.toml
#          touched; and make test must clear pytest's cache, --lf in addopts,
#          and ignore a stale .coverage under --cov-append), install (a stale
#          uv.lock),
#          check (a tool missing from .venv, no pytest-cov, the Python pin, a
#          Python pin of 3.10 or 3.9, which fails, and of 3.11, which passes
#          the floor and fails at the next check, its format, no
#          .python-version, COVERAGE_FLOOR unset or not a percent, no install,
#          MODULES against the workspace or as a glob, no [python.duplication] or
#          [tool.vulture] paths) and audit (a vulnerable dependency, one only
#          OSV lists, one only win32 installs) to fail for that reason. Expect
#          make format to fix a format and an unused-import break so that lint
#          passes, and audit to pass on current runtime dependencies, one of
#          them through a local path dependency, on runtime dependencies only
#          win32 installs, and on a name locked at two versions. In the
#          workspace, whose core is a package and app a virtual member: test
#          ONLY=packages/app tests app alone, lint
#          ONLY=packages/app passes over a format break in core that lint
#          fails, and JUNIT_DIR=reports writes one report per member into the
#          project. Needs git >= 2.36 (SSH signing; lint-secrets' remerge),
#          make, ssh-keygen (OpenSSH 8.1 or later), python3 >= 3.11 with venv
#          and pip, curl, tar, sha256sum or shasum and the network (PyPI, its
#          advisory API, api.osv.dev, github.com, and uv's Python downloads
#          when no CPython of the pin is installed), and node with npm for
#          the copy-paste gate, which installs jscpd from the npm registry;
#          the fixtures hold no
#          Markdown, so lint-md does not run markdownlint.
set -euo pipefail
if ((BASH_VERSINFO[0] < 4)); then
  echo "ERROR: tests/run.sh needs bash 4 or later (globstar); this is bash $BASH_VERSION." >&2
  exit 1
fi
shopt -s globstar

root=$(cd "$(dirname "$0")/.." && pwd)
fails=0
# Set by prepare and publish, which skip when they are set, so none may come from the caller's environment.
work='' label_prefix='' tag='' bare='' commit=''
newest_python=3.14 # the newest stable CPython; floor_newest_stable fails when the pinned uv offers a newer one
# shellcheck source=SCRIPTDIR/../scripts/lib/tree.sh
. "$root/scripts/lib/tree.sh"

uncache() { chmod -R u+w "$@" 2>/dev/null || :; rm -rf "$@"; } # the caches are read-only, directories too
check() { # check LABEL COMMAND...: run COMMAND and report how it went
  local label=$1 start=$SECONDS rc=0
  shift
  "$@" || rc=$?
  if [[ $rc == 0 ]]; then
    echo "PASS ${label_prefix-}$label ($((SECONDS - start))s)"
  else
    echo "FAIL ${label_prefix-}$label (exit $rc, $((SECONDS - start))s)"
    fails=$((fails + 1))
  fi
}

shellcheck_all() {
  (cd "$root" && shellcheck -x devkitw scripts/**/*.sh tests/*.sh)
}

shell_tests() { # every test file of the shell part, run again by the floor part
  check "devkitw tests" "$root/tests/devkitw_test.sh"
  check "select_modules tests" "$root/tests/select_modules_test.sh"
  check "make tests" "$root/tests/make_test.sh"
  check "kill tests" "$root/tests/kill_test.sh"
  check "check_frontend_deps tests" "$root/tests/check_frontend_deps_test.sh"
  check "formatter_lockfile tests" "$root/tests/formatter_lockfile_test.sh"
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
  check "pinned_maven tests" "$root/tests/pinned_maven_test.sh"
  check "mvn_checked tests" "$root/tests/mvn_checked_test.sh"
  check "sealed_dir tests" "$root/tests/sealed_dir_test.sh"
  check "coverage_floor tests" "$root/tests/coverage_floor_test.sh"
  check "coverage tests" "$root/tests/coverage_test.sh"
  check "version_check tests" "$root/tests/version_check_test.sh"
  check "python invocations tests" "$root/tests/python_invocations_test.sh"
  check "python clean tests" "$root/tests/python_clean_test.sh"
  check "python audit tests" "$root/tests/python_audit_test.sh"
  check "python audit judge tests" "$root/tests/python_audit_judge_test.sh"
  check "java clean tests" "$root/tests/java_clean_test.sh"
  check "duplication tests" "$root/tests/duplication_test.sh"
  check "anchored_match tests" "$root/tests/anchored_match_test.sh"
  check "markdown isolation tests" "$root/tests/markdown_isolation_test.sh"
  check "closure_audit tests" "$root/tests/closure_audit_test.sh"
  check "tag tests" "$root/tests/tag_test.sh"
  check "git tooling tests" "$root/tests/git_tooling_test.sh"
}

shell_part() {
  check "shellcheck" shellcheck_all
  shell_tests
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
  check "pmd-ruleset.xml: sets no property but the assertion helpers, the thresholds of TooManyMethods and TooManyFields and LinguisticNaming's two checks, so the complexity rules run at PMD's defaults" \
    ruleset_thresholds_default "$root/java/config/pmd-ruleset.xml"
  check "pmd-ruleset.xml: the property check rejects a raised complexity threshold" \
    ruleset_thresholds_reject 's|<rule ref="category/java/design.xml/TooManyFields">|<rule ref="category/java/design.xml/CyclomaticComplexity">\n        <properties><property name="methodReportLevel" value="30" /></properties>\n    </rule>\n    &|'
  check "pmd-ruleset.xml: the property check rejects reportLevel on a rule that may set another property" \
    ruleset_thresholds_reject 's|<property name="maxmethods" value="40" />|&<property name="reportLevel" value="60" />|'
  check "parent: spotbugs-plugin.version is spotbugs.version plus a fourth component" spotbugs_versions_match
  check "parent: the SpotBugs analyzer dependency excludes log4j-core, as the plugin's own declaration does" \
    spotbugs_log4j_excluded "$root/java/parent/pom.xml"
  check "parent: java/parent/pom.xml declares UTF-8 as the source and report encoding" \
    parent_encodings "$root/java/parent/pom.xml"
  check "parent: the spotbugs-plugin.version check rejects a plugin bumped without the analyzer" \
    lists_reject 's|<spotbugs-plugin.version>4.10.5.0<|<spotbugs-plugin.version>4.10.6.0<|' "" spotbugs_versions_match
  check "parent: the log4j-core exclusion check rejects an exclusion of another groupId" \
    lists_reject '/<exclusion>/,/<\/exclusion>/s|<groupId>org.apache.logging.log4j<|<groupId>org.example<|' "does not exclude log4j-core" spotbugs_log4j_excluded
  check "parent: the encoding check rejects a parent without the report encoding" \
    lists_reject '/<project.reporting.outputEncoding>/d' "" parent_encodings
  check "parent: java/config/findsecbugs-crlf-jboss-logging.txt lists exactly the sink slots of its owners' log methods" \
    sink_file_valid "$root/java/config/findsecbugs-crlf-jboss-logging.txt"
  check "parent: the sink file check rejects a long overload whose indices are the long's slots, naming the line" \
    sink_file_reject 's|^\(org/jboss/logging/Logger.tracef(Ljava/lang/String;J)V:\).*|\10,1|' "Logger.tracef(Ljava/lang/String;J)V:0,1"
  check "parent: docs/contract.md lists the parent's version properties and execution ids, no more and no fewer" \
    contract_lists_match "$root/java/parent/pom.xml" "$root/docs/contract.md"
  check "parent: the contract lists check rejects a version property the contract does not list" \
    contract_lists_reject pom 's|<jacoco-plugin.version>|<extra-plugin.version>1</extra-plugin.version>&|' "lacks the parent's version propert(ies): extra-plugin.version"
  check "parent: the contract lists check rejects a listed version property the parent lacks" \
    contract_lists_reject pom 's|jacoco-plugin.version>|jacoco-gone.version>|g' "has no version propert(ies) the contract lists: jacoco-plugin.version"
  check "parent: the contract lists check rejects an execution id the contract does not list" \
    contract_lists_reject pom 's|<id>environment</id>|<id>environment</id></execution><execution><id>extra-id</id>|' "lacks the parent's execution id(s): extra-id"
  check "parent: the contract lists check rejects a listed execution id the parent lacks" \
    contract_lists_reject pom 's|<id>pmd-ruleset</id>|<id>pmd-renamed</id>|' "has no execution with the id(s) the contract lists: pmd-ruleset"
  check "parent: the contract lists check rejects an execution id held by two executions" \
    contract_lists_reject pom 's|<id>flatten</id>|&</execution><execution>|' "has more than one execution with the id(s): default"
  check "parent: the contract lists check rejects a contract whose id list is reworded" \
    contract_lists_reject contract 's|The ids are|The names are|' "no \"The ids are\""
  check "parent: the contract lists check rejects a contract whose pin list is reworded" \
    contract_lists_reject contract 's|^- It pins every gate tool|- It sets every gate tool|' "no bullet starts with"
  check "parent: the contract lists check rejects a list too short to be the real one" \
    contract_lists_reject pom '/<properties>/,/<\/properties>/d' "parsed 0 properties"
  check "parent: the contract lists check rejects a parent without a non-override execution id" \
    contract_lists_reject pom 's|<id>flatten</id>|<id>flatten-x</id>|' "has lost the non-override execution id(s): flatten"
  # shellcheck disable=SC2016 # backticks of the sed pattern are literal
  check "parent: the contract lists check rejects an execution id only the contract lists" \
    contract_lists_reject contract 's|`pmd-ruleset`|`pmd-ruleset`, `ghost-id`|' "has no execution with the id(s) the contract lists: ghost-id"
  # shellcheck disable=SC2016 # backticks of the sed pattern are literal
  check "parent: the contract lists check rejects a listed execution id that is no override point" \
    contract_lists_reject contract 's|`pmd-ruleset`|`pmd-ruleset`, `flatten`|' "lists execution id(s) that are no override point: flatten"
  check "parent: the contract lists check rejects an execution id the contract places in another plugin" \
    contract_lists_reject contract 's|(JaCoCo)|(SpotBugs)|' "names another plugin than the parent's for the execution id(s): check, prepare-agent, report"
  check "parent: java/checksums lists the jar of every plugin and annotation processor the parent pins" \
    checksums_cover "$root/java/parent/pom.xml" "$root/java/checksums/checksums.sha256" "$(frontend_plugins "$root")" "$(maven_pin "$root")"
  check "parent: the checksums check rejects a file without a pinned plugin's jar, naming it and make maven-checksums" \
    checksums_reject '/\/maven-compiler-plugin\/.*\.jar$/d' "maven-compiler-plugin-" "make maven-checksums"
  check "parent: the checksums check rejects a file without a pinned annotation processor's jar" \
    checksums_reject '/\/nullaway\/.*\.jar$/d' "com/uber/nullaway/nullaway/" "make maven-checksums"
  check "parent: the checksums check rejects a file without a pinned plugin dependency's jar" \
    checksums_reject '/\/checkstyle\/[0-9.]*\/checkstyle-[0-9.]*\.jar$/d' "com/puppycrawl/tools/checkstyle/" "make maven-checksums"
  check "parent: the checksums check rejects a file without the pinned Maven distribution's line (java/checksums holds it)" \
    checksums_reject '/\/apache-maven-[0-9.]*-bin\.tar\.gz$/d' "apache-maven-" "make maven-checksums"
  check "parent: the checksums check rejects a file without the enforcer plugin's jar" \
    checksums_reject '/\/maven-enforcer-plugin\/.*\.jar$/d' "maven-enforcer-plugin-" "make maven-checksums"
  check "parent: the checksums check rejects a file without find-sec-bugs' jar" \
    checksums_reject '/\/findsecbugs-plugin\/.*\.jar$/d' "com/h3xstream/findsecbugs/findsecbugs-plugin/" "make maven-checksums"
  check "scripts: MVN_LAUNCHER, which skips the checksums check, is used only by get_maven.sh, mvn_checked.sh and maven_checksums.sh" \
    launcher_uses scripts/lib/get_maven.sh scripts/lib/mvn_checked.sh scripts/maven_checksums.sh
  check "parent: the checksums check rejects a file without the plugins check_frontend_deps.py runs" \
    checksums_reject '/\/maven-help-plugin\/.*\.jar$/d;/\/maven-dependency-plugin\/.*\.jar$/d' \
    "maven-help-plugin-" "maven-dependency-plugin-" "make maven-checksums"
}

# checksums_cover POM FILE FRONTEND DIST: FILE, a trusted checksums file (scripts/lib/mvn_checked.sh),
# lists the jar of every plugin POM declares with a version (a SpotBugs detector under the plugin's
# configuration/plugins included), of the dependencies of those plugins, of the
# annotationProcessorPaths and of the plugins FRONTEND (frontend_plugins of
# scripts/lib/tree.sh: groupId:artifactId:version, one per line) names, at the path the local
# repository gives it, and holds the line DIST (maven_pin of tree.sh: the pinned Maven, whose
# default lifecycle plugins the file records). Only top-level jars are checked, not their transitive
# closure. A bump of a plugin, plugin dependency, processor or Maven version without
# scripts/maven_checksums.sh leaves an entry out and fails; the formatter's artifacts are not in the
# POM's declarations, and formatter_lockfile.py covers them (the java part's check of the committed file).
checksums_cover() {
  # shellcheck disable=SC2016 # the program's ${...} is a Maven property, not a shell expansion
  python3 -c 'import re, sys, xml.etree.ElementTree as ET
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
root = ET.parse(sys.argv[1]).getroot()
props = {p.tag.split("}")[1]: (p.text or "").strip() for p in root.find("m:properties", ns)}
def coordinate(e, group):
    version = e.findtext("m:version", "", ns).strip()
    version = re.sub(r"\$\{([^}]+)\}", lambda m: props.get(m[1], m[0]), version)
    group = e.findtext("m:groupId", group, ns).strip().replace(".", "/")
    artifact = e.findtext("m:artifactId", "", ns).strip()
    return f"{group}/{artifact}/{version}/{artifact}-{version}.jar"
pinned = set()
for plugin in root.iterfind(".//m:plugin", ns):
    if plugin.findtext("m:version", "", ns).strip():
        pinned.add(coordinate(plugin, "org.apache.maven.plugins"))
        pinned.update(coordinate(d, "") for d in plugin.iterfind("m:dependencies/m:dependency", ns) if d.findtext("m:version", "", ns).strip())
pinned.update(coordinate(p, "") for p in root.iterfind(".//m:annotationProcessorPaths/m:path", ns))
frontend = sys.argv[3].split()
for coordinates in frontend:
    group, artifact, version = coordinates.split(":")
    pinned.add("/".join((group.replace(".", "/"), artifact, version, f"{artifact}-{version}.jar")))
lines = open(sys.argv[2]).read().splitlines()
listed = {line.split("  ", 1)[1] for line in lines if "  " in line}
missing = sorted(pinned - listed) + ([] if sys.argv[4] in lines else [sys.argv[4].split("  ", 1)[1]])
# The parent pins well over 12 jars (plugins, their dependencies, processors) and FRONTEND two plugins:
# fewer means this parse stopped matching the files, which no re-record fixes.
sys.exit("maven_pin printed no distribution line (scripts/lib/pinned_maven.sh pins no version or sha256)") if "  " not in sys.argv[4].strip() else None
sys.exit("the parent POM or check_frontend_deps.py was not parsed as expected (" + str(len(pinned)) + " jars, " + str(len(frontend)) + " frontend plugins): update this check, not the checksums file") if len(pinned) < 12 or len(frontend) != 2 else None
sys.exit("java/checksums/checksums.sha256 lacks " + ", ".join(missing) + ": run make maven-checksums and commit the result") if missing else None' "$1" "$2" "$3" "$4"
}

# launcher_uses FILE...: no file of scripts/ and make/ but FILE... (relative to the root) names
# MVN_LAUNCHER, the Maven that does not verify checksums: get_maven.sh sets it, mvn_checked.sh and
# maven_checksums.sh wrap or stand in for it. Any other use would build unchecked.
# pinned_maven.sh, which installs and prints that Maven, is named only by get_maven.sh, maven_checksums.sh,
# tree.sh (the pin's reader) and itself: any other caller would run a launcher get_maven.sh did not vet.
launcher_uses() {
  local found extra
  found=$(cd "$root" && grep -rlF MVN_LAUNCHER scripts make | LC_ALL=C sort) || return
  extra=$(comm -23 <(printf '%s\n' "$found") <(printf '%s\n' "$@" | LC_ALL=C sort))
  [[ -z $extra ]] || { echo "MVN_LAUNCHER is used by: $extra"; return 1; }
  found=$(cd "$root" && grep -rlF pinned_maven.sh scripts make | LC_ALL=C sort) || return
  extra=$(comm -23 <(printf '%s\n' "$found") <(printf '%s\n' scripts/lib/{get_maven,pinned_maven,tree}.sh scripts/maven_checksums.sh | LC_ALL=C sort))
  [[ -z $extra ]] || { echo "pinned_maven.sh is named by: $extra"; return 1; }
}

checksums_reject() { # checksums_reject SED TEXT...: the check fails on the checksums file run through SED (which must change it), saying each TEXT
  local file=$root/java/checksums/checksums.sha256 edited err text
  edited=$(sed "$1" "$file") && [[ $edited != "$(<"$file")" ]] &&
    ! err=$(checksums_cover "$root/java/parent/pom.xml" /dev/stdin "$(frontend_plugins "$root")" "$(maven_pin "$root")" <<<"$edited" 2>&1) || return
  for text in "${@:2}"; do [[ $err == *"$text"* ]] || return; done
}

# license_lists_whole POM: each includedLicense is one name, compared to a license name exactly as
# it stands, so it must not carry whitespace (Maven trims edge whitespace in element text, so that
# is harmless to the plugin, but kept out of the pom). The allowlist keeps the names devkit's own
# tests and fixtures rely on: "MIT License", for foreign_group's override; "Unknown license", the
# plugin's key for a dependency with no license, which failOnMissing must keep reporting as
# foreign_group expects; "Eclipse Public License v2.0", the license of the fixtures' junit jars;
# "The Apache License, Version 2.0", that of their opentest4j and apiguardian jars; "GNU LESSER
# GENERAL PUBLIC LICENSE, Version 2.1" and "The Apache Software License, Version 2.0", those of
# java-monolith's spotbugs-annotations and its jsr305; "Apache-2.0", that of its assertj-core. No
# name is listed twice.
license_lists_whole() {
  python3 -c 'import re, sys, xml.etree.ElementTree as ET
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
root = ET.parse(sys.argv[1]).getroot()
included = [e.text or "" for e in root.iterfind(".//m:includedLicense", ns)]
odd = lambda e: not e or re.search(r"[\n\t]|  |^\s|\s$", e)
required = {"Eclipse Public License v2.0", "The Apache License, Version 2.0", "MIT License", "Unknown license",
    "GNU LESSER GENERAL PUBLIC LICENSE, Version 2.1", "The Apache Software License, Version 2.0", "Apache-2.0"}
problems = {
    "includedLicense entries that can never match": [e for e in included if odd(e)],
    "includedLicense entries listed twice": sorted({e for e in included if included.count(e) > 1}),
    "required names missing from the allowlist": sorted(required - set(included)),
}
bad = {k: v for k, v in problems.items() if v}
sys.exit(f"license lists: {bad!r}") if bad or not included else None' "$1"
}

lists_reject() { # lists_reject SED TEXT [CHECK]: CHECK (default license_lists_whole) fails on a copy of the parent run through SED (which must change it), saying TEXT
  local copy err
  copy=$(mktemp) && sed "$1" "$root/java/parent/pom.xml" >"$copy" && ! cmp -s "$copy" "$root/java/parent/pom.xml" &&
    ! err=$("${3:-license_lists_whole}" "$copy" 2>&1) && [[ $err == *"$2"* ]]
  local status=$?
  rm -f "$copy"
  return $status
}

# ruleset_thresholds_default FILE: the PMD ruleset FILE sets no property but the ones devkit means to
# set: the assertion helpers of UnitTestShouldIncludeAssert, the 40 of TooManyMethods and
# TooManyFields, and the two LinguisticNaming checks it narrows off. Any other, such as a raised
# threshold of a complexity rule, fails, so the rules run at PMD's defaults.
ruleset_thresholds_default() {
  python3 -I -c 'import sys, xml.etree.ElementTree as ET
ns = {"p": "http://pmd.sourceforge.net/ruleset/2.0.0"}
allowed = {"UnitTestShouldIncludeAssert": {"extraAssertMethodNames"}, "TooManyMethods": {"maxmethods"},
           "TooManyFields": {"maxfields"}, "LinguisticNaming": {"checkGetters", "checkPrefixedTransformMethods"}}
rules = ET.parse(sys.argv[1]).getroot().findall("p:rule", ns)
set_ = {(r.get("ref", "").rsplit("/", 1)[-1], p.get("name")) for r in rules for p in r.iterfind("p:properties/p:property", ns)}
extra = {s for s in set_ if s[1] not in allowed.get(s[0], ())}
sys.exit(f"{sys.argv[1]} sets no property at all (namespace or structure changed?)") if not set_ else None
sys.exit(f"{sys.argv[1]} sets properties devkit does not: {sorted(extra)}") if extra else None' "$1"
}

# ruleset_thresholds_reject SED: the check fails on a copy of the shipped ruleset run through SED
# (which must change it).
ruleset_thresholds_reject() {
  local file=$root/java/config/pmd-ruleset.xml copy err
  copy=$(mktemp) && sed "$1" "$file" >"$copy" && ! cmp -s "$copy" "$file" &&
    ! err=$(ruleset_thresholds_default "$copy" 2>&1) && [[ $err == *"sets properties devkit does not"* ]]
  local status=$?
  rm -f "$copy"
  return $status
}

# sink_file_valid FILE: scripts/java/jboss_logging_sinks.py accepts the SpotBugs sink file FILE.
sink_file_valid() {
  python3 -I "$root/scripts/java/jboss_logging_sinks.py" --check "$1"
}

# sink_file_reject SED TEXT: the sink check fails on a copy of the shipped file run through SED (which
# must change it), saying TEXT.
sink_file_reject() {
  local file=$root/java/config/findsecbugs-crlf-jboss-logging.txt copy err
  copy=$(mktemp) && sed "$1" "$file" >"$copy" && ! cmp -s "$copy" "$file" &&
    ! err=$(sink_file_valid "$copy" 2>&1) && [[ $err == *"$2"* ]]
  local status=$?
  rm -f "$copy"
  return $status
}

# contract_lists_match POM CONTRACT: docs/contract.md lists, by hand, the parent's version properties
# (the bullet "It pins every gate tool's version") and its execution ids (after "The ids are"): a
# consumer's override of either silently stops working when the name drifts. Both lists must equal
# the POM's: every project property ending in .version, and every execution id (an execution
# without one has Maven's implicit id, default). Two executions must not share an id even across
# plugins, which Maven allows: the contract's list is flat, so a shared id would hide one plugin's
# rename behind another's. Each id must sit in the plugin the contract names after it: the name,
# lowercased, is part of that plugin's artifactId. The ids in
# not_override are no override point (the contract's flatten bullet: its configuration is not
# one), so the contract does not list them; each must still exist, so the set cannot go stale. An
# anchor not found or a list of fewer than 10 entries means the contract was reworded, which fails
# here rather than passing vacuously.
contract_lists_match() {
  python3 -c 'import re, sys, xml.etree.ElementTree as ET
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
not_override = {"flatten"}
root = ET.parse(sys.argv[1]).getroot()
props = {e.tag.split("}")[1] for e in root.iterfind("m:properties/*", ns) if e.tag.endswith(".version")}
execs = [(p.findtext("m:artifactId", "", ns), e.findtext("m:id", "default", ns))
         for p in root.iterfind(".//m:plugin", ns) for e in p.iterfind("m:executions/m:execution", ns)]
all_ids = [i for _, i in execs]
ids = set(all_ids) - not_override
lines = open(sys.argv[2]).read().split("\n")
def bullet(start):
    first = [i for i, l in enumerate(lines) if l.startswith(start)]
    if not first:
        sys.exit(f"contract lists: no bullet starts with {start!r}: update this check")
    end = next((i for i in range(first[0] + 1, len(lines)) if lines[i] and lines[i][0] != " "), len(lines))
    return "\n".join(lines[first[0]:end])
ticks = lambda t: set(re.findall(r"\x60([^\x60]+)\x60", t))
pins = bullet("- It pins every gate tool\x27s version")
listed = bullet("- The property names above and the execution ids are contract")
if "The ids are" not in listed:
    sys.exit("contract lists: no \"The ids are\" in the contract bullet: update this check")
c_props = {t for t in ticks(pins) if t.endswith(".version")}
c_ids = ticks(listed.split("The ids are", 1)[1])
owner = {i: name.lower() for g, name in re.findall(r"((?:\x60[^\x60]+\x60[\s,]*(?:and\s+)?)+)\(([^)]+)\)", listed) for i in ticks(g)}
if min(len(props), len(ids), len(c_props), len(c_ids)) < 10:
    sys.exit(f"contract lists: parsed {len(props)} properties, {len(ids)} ids from the pom, {len(c_props)} and {len(c_ids)} from the contract: update this check")
sep = ", "
msgs = [f"{who} {what}: {sep.join(sorted(d))}" for who, what, d in (
    ("docs/contract.md", "lacks the parent\x27s version propert(ies)", props - c_props),
    ("java/parent/pom.xml", "has no version propert(ies) the contract lists", c_props - props),
    ("docs/contract.md", "lacks the parent\x27s execution id(s)", ids - c_ids),
    ("java/parent/pom.xml", "has no execution with the id(s) the contract lists", c_ids - set(all_ids)),
    ("docs/contract.md", "lists execution id(s) that are no override point", c_ids & not_override),
    ("docs/contract.md", "names another plugin than the parent\x27s for the execution id(s)",
     {i for a, i in execs if i in c_ids and owner.get(i, "(none)") not in a}),
    ("java/parent/pom.xml", "has more than one execution with the id(s)", {i for i in all_ids if all_ids.count(i) > 1}),
    ("java/parent/pom.xml", "has lost the non-override execution id(s)", not_override - set(all_ids))) if d]
sys.exit("\n".join(msgs)) if msgs else None' "$1" "$2"
}

contract_lists_reject() { # contract_lists_reject pom|contract SED TEXT: the check fails on that file run through SED (which must change it), saying TEXT
  local pom=$root/java/parent/pom.xml contract=$root/docs/contract.md edited err
  case $1 in
    pom) edited=$(sed "$2" "$pom") && [[ $edited != "$(<"$pom")" ]] &&
      ! err=$(contract_lists_match /dev/stdin "$contract" <<<"$edited" 2>&1) ;;
    *) edited=$(sed "$2" "$contract") && [[ $edited != "$(<"$contract")" ]] &&
      ! err=$(contract_lists_match "$pom" /dev/stdin <<<"$edited" 2>&1) ;;
  esac && [[ $err == *"$3"* ]]
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
publish() { # at most once per run
  [[ -z $commit ]] || return 0
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

# add_assert_helper DIR: a test in the monolith copy DIR whose only check is a helper PMD does not
# know.
add_assert_helper() {
  local testdir=$1/src/test/java/devkit/fixture
  # No assert*, verify* or check* in the names: PMD accepts those by default.
  cat >"$testdir/GreetingIs.java" <<'JAVA'
package devkit.fixture;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class GreetingIs {

    private GreetingIs() {
    }

    static void greetingIs(String expected, String name) {
        assertEquals(expected, new Greeter().greet(name));
    }
}
JAVA
  cat >"$testdir/HelperTest.java" <<'JAVA'
package devkit.fixture;

import org.junit.jupiter.api.Test;

class HelperTest {

    @Test
    void greetsByHelper() {
        GreetingIs.greetingIs("Hello, Ada", "Ada");
    }
}
JAVA
}

assert_helper_checks() { # a test whose only check is a helper PMD does not know fails lint until the pom names it
  local dir=$work/negative-assert-helper
  setup "$root/tests/fixtures/java-monolith" "$dir"
  add_assert_helper "$dir"
  check "java-monolith: an unknown assertion helper fails make lint, PMD finding one violation" \
    make_says fail "$dir" lint "has found 1 violation" "PMD Failure: devkit.fixture.HelperTest:8 Rule:UnitTestShouldIncludeAssert"
  sed_into "$dir/pom.xml" 's|<maven.compiler.release>|<pmd.extraAssertMethodNames>statusCode,greetingIs</pmd.extraAssertMethodNames>\n    &|'
  # A project's own resources configuration that would copy XML unfiltered must not reach the ruleset.
  sed_into "$dir/pom.xml" 's|</project>|  <build><plugins><plugin><artifactId>maven-resources-plugin</artifactId><configuration><nonFilteredFileExtensions><nonFilteredFileExtension>xml</nonFilteredFileExtension></nonFilteredFileExtensions></configuration></plugin></plugins></build>\n&|'
  check "java-monolith: pmd.extraAssertMethodNames makes make lint accept it, whatever the project's plugin-level resources configuration" \
    make_says pass "$dir" lint
}

cpd_duplicate() { # a class holding one block twice fails lint, CPD naming the file and line of each copy
  local dir=$work/negative-cpd
  setup "$root/tests/fixtures/java-monolith" "$dir"
  cat >"$dir/src/main/java/devkit/fixture/Dup.java" <<'JAVA'
package devkit.fixture;

/** Holds two copies of one block. */
public final class Dup {

    private Dup() {
    }

    /** First copy. */
    public static int first(int a, int b) {
        int sum = 0;
        for (int i = a; i < b; i++) {
            if (i % 2 == 0) {
                sum += i * 3;
            } else {
                sum -= i * 5;
            }
            if (sum > 1000) {
                sum = sum / 2 + i;
            }
        }
        return sum + a * b - (a + b) * 7;
    }

    /** Second copy. */
    public static int second(int a, int b) {
        int sum = 0;
        for (int i = a; i < b; i++) {
            if (i % 2 == 0) {
                sum += i * 3;
            } else {
                sum -= i * 5;
            }
            if (sum > 1000) {
                sum = sum / 2 + i;
            }
        }
        return sum + a * b - (a + b) * 7;
    }
}
JAVA
  make_says fail "$dir" lint "CPD Failure: Found" "Dup.java line 10" "Dup.java line 26"
}

# A violation the shared config reports on an AST node (an abbreviation in a method name) fails lint
# until checkstyle-xpath-suppressions.xml, which the parent wires like checkstyle-suppressions.xml,
# suppresses it. make lint runs in the project root, where the unwired property's default would find
# the file too, so Checkstyle also runs from another working directory, and with a
# maven.multiModuleProjectDirectory other than the project: only the parent's wiring to
# ${project.basedir} finds the file there, not one to the former (equal to it in a monolith).
xpath_suppression() {
  local dir=$work/negative-xpath other=$work/negative-xpath-root
  edited "$dir" src/main/java/devkit/fixture/Greeter.java \
    's|^}$|\n    /** Parses. */\n    public String parseURL() {\n        return "";\n    }\n}|' &&
    make_says fail "$dir" lint "Checkstyle violation" || return
  cat >"$dir/checkstyle-xpath-suppressions.xml" <<'XML'
<?xml version="1.0"?>
<!DOCTYPE suppressions PUBLIC "-//Checkstyle//DTD SuppressionXpathFilter Experimental Configuration 1.2//EN" "https://checkstyle.org/dtds/suppressions_1_2_xpath_experimental.dtd">
<suppressions>
    <suppress-xpath checks="AbbreviationAsWordInName" query="//METHOD_DEF[./IDENT[@text='parseURL']]/IDENT" />
</suppressions>
XML
  make_says pass "$dir" lint || return
  local mvn
  mvn=$("$root/scripts/lib/pinned_maven.sh") && mkdir "$other" && ln -s "$dir/.devkit" "$other/.devkit" &&
    (cd "$work" && "$mvn" -B -q -f "$dir/pom.xml" -Dmaven.multiModuleProjectDirectory="$other" checkstyle:check)
}

# jakarta_path_stub SRC: SRC/jakarta/ws/rs/Path.java, a stub of the JAX-RS annotation (the detectors and
# the formatter's import order match by name, so no JAX-RS jar is needed)
jakarta_path_stub() {
  mkdir -p "$1/jakarta/ws/rs" &&
    cat >"$1/jakarta/ws/rs/Path.java" <<'JAVA'
package jakarta.ws.rs;

import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;

/** A stub of the JAX-RS annotation. */
@Retention(RetentionPolicy.RUNTIME)
public @interface Path {

    /**
     * The path.
     *
     * @return the path
     */
    String value();
}
JAVA
}

# find_sec_bugs: a monolith copy with an XML parser open to external entities and logging calls of an
# untrusted value, in a JAX-RS endpoint (Path, JBoss Logging's Logger and Quarkus' Log are stubbed, as
# the fixture stubs Quarkus' test annotations), fails make lint with exactly those two finding types:
# not JAXRS_ENDPOINT, which the baseline excludes, and no analysis error. The calls are to Logger's
# infof, to its overload with a long argument, whose format is checked at its own stack slot (a
# constant format with a long is no finding), and to Log's static infof. The stubs carry no logic: the
# detectors match by class and descriptor.
find_sec_bugs() {
  local dir=$work/find-sec-bugs src
  setup "$root/tests/fixtures/java-monolith" "$dir" || return
  src=$dir/src/main/java
  mkdir -p "$src/org/jboss/logging" || return
  jakarta_path_stub "$src" || return
  cat >"$src/org/jboss/logging/Logger.java" <<'JAVA'
package org.jboss.logging;

/** A stub of JBoss Logging's logger. */
public final class Logger {

    private static final Logger LOG = new Logger();

    private Logger() {
    }

    /**
     * Gets the logger.
     *
     * @param type the logging class
     * @return the logger
     */
    public static Logger getLogger(Class<?> type) {
        return LOG;
    }

    /**
     * Logs, formatted.
     *
     * @param format the format
     * @param param1 its argument
     */
    public void infof(String format, Object param1) {
        // Nothing to log in a stub.
    }

    /**
     * Logs, formatted, with a long argument.
     *
     * @param format the format
     * @param param1 its argument
     */
    public void tracef(String format, long param1) {
        // Nothing to log in a stub.
    }
}
JAVA
  mkdir -p "$src/io/quarkus/logging" || return
  cat >"$src/io/quarkus/logging/Log.java" <<'JAVA'
package io.quarkus.logging;

/** A stub of Quarkus' static logging facade. */
public final class Log {

    private Log() {
    }

    /**
     * Logs, formatted.
     *
     * @param format the format
     * @param param1 its argument
     */
    public static void infof(String format, Object param1) {
        // Nothing to log in a stub.
    }
}
JAVA
  cat >"$src/devkit/fixture/XmlReader.java" <<'JAVA'
package devkit.fixture;

import io.quarkus.logging.Log;
import jakarta.ws.rs.Path;
import java.io.IOException;
import java.io.InputStream;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.parsers.ParserConfigurationException;
import org.jboss.logging.Logger;
import org.w3c.dom.Document;
import org.xml.sax.SAXException;

/** Reads XML. */
public final class XmlReader {

    private static final Logger LOG = Logger.getLogger(XmlReader.class);

    /**
     * Reads a document.
     *
     * @param in the document
     * @param name its name
     * @return the parsed document
     * @throws IOException if reading fails
     * @throws ParserConfigurationException if no parser is available
     * @throws SAXException if the document is malformed
     */
    @Path("xml")
    public Document read(InputStream in, String name)
            throws IOException, ParserConfigurationException, SAXException {
        LOG.infof("reading %s", name);
        return DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(in);
    }

    /**
     * Logs a name as the format of a long overload.
     *
     * @param name the name
     */
    public void named(String name) {
        LOG.tracef(name, 1L);
    }

    /**
     * Logs a number under a constant format.
     *
     * @param n the number
     */
    public void count(long n) {
        LOG.tracef("count %d", n);
    }

    /**
     * Logs a name through Quarkus' static facade.
     *
     * @param name the name
     */
    public void quarkus(String name) {
        Log.infof("quarkus %s", name);
    }
}
JAVA
  make_says pass "$dir" format && make_says fail "$dir" lint "XXE_DOCUMENT" || return
  python3 -I -c 'import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
got = {b.get("type") for b in root.iter("BugInstance")}
logged = {b.find("Method").get("name") for b in root.iter("BugInstance") if b.get("type") == "CRLF_INJECTION_LOGS"}
errors = root.find("Errors").get("errors")
sys.exit(f"SpotBugs reported {sorted(got)!r} on {sorted(logged)!r} with {errors} analysis errors") if got != {"XXE_DOCUMENT", "CRLF_INJECTION_LOGS"} or logged != {"read", "named", "quarkus"} or errors != "0" else None' "$dir/target/spotbugsXml.xml"
}

# nullaway_below_src_test FILE: the NullAway-suppression break of FILE in a monolith copy below a
# src/test directory still fails make lint.
nullaway_below_src_test() {
  local dir=$work/ancestor/src/test/proj
  mkdir -p "${dir%/*}" &&
    edited "$dir" "$1" 's/^public final class/@SuppressWarnings("NullAway")\n&/' &&
    make_says fail "$dir" lint "Do not suppress NullAway"
}

# nullaway_in_tests DIR FILE: FILE of the monolith copy DIR carries the suppression (the sed must have
# changed it), and make lint passes.
nullaway_in_tests() {
  grep -qF '@SuppressWarnings("NullAway")' "$1/$2" && make_says pass "$1" lint "Lint checks completed."
}

# javac_lint LINT SED PATTERN [NAME [PMD]]: SED's break of Greeter in a monolith copy fails make
# lint on javac's LINT under -Werror, naming the file and position of the warning (mvn_checked.sh's
# logger keys keep it under -q). Once the copy appends -Xlint:-LINT to its compilerArgs, as a module
# whose framework needs that does, javac is silent: a non-empty PATTERN makes lint fail on SpotBugs'
# PATTERN for the same construct, and it passes once the class excludes PATTERN; an empty one is a
# construct only javac reports, which then passes. A non-empty PMD is a PMD rule that reports the
# construct too: lint then fails on it, naming Rule:<PMD>, and passes once pmd_without drops it.
# NAME (default LINT) keeps the copies of one LINT's cases apart.
javac_lint() {
  local dir=$work/javac-${4:-$1}
  edited "$dir" src/main/java/devkit/fixture/Greeter.java "$2" && make_says fail "$dir" lint "-Werror" "Greeter.java:[" || return
  sed_into "$dir/pom.xml" "s|^</project>|  <build>\\n    <plugins>\\n      <plugin>\\n        <artifactId>maven-compiler-plugin</artifactId>\\n        <configuration>\\n          <compilerArgs combine.children=\"append\">\\n            <arg>-Xlint:-$1</arg>\\n          </compilerArgs>\\n        </configuration>\\n      </plugin>\\n    </plugins>\\n  </build>\\n&|" || return
  [[ -z $3 ]] || {
    make_says fail "$dir" lint "$3" &&
      sed_into "$dir/spotbugs-exclude.xml" "s|\" />\$|\">\\n  <Match>\\n    <Class name=\"devkit.fixture.Greeter\" />\\n    <Bug pattern=\"$3\" />\\n  </Match>\\n</FindBugsFilter>|"
  } || return
  [[ -z ${5-} ]] || { make_says fail "$dir" lint "Rule:$5" && pmd_without "$dir" "$5"; } || return
  make_says pass "$dir" lint "Lint checks completed."
}

# pmd_without DIR RULE [REF]: the project or module DIR drops RULE of devkit's PMD ruleset, as
# docs/contract.md teaches: its pom redeclares PMD's <rulesets> with its own pmd-ruleset.xml, which
# references the filtered copy of the kit's at REF (default target/devkit/pmd-ruleset.xml, relative
# to Maven's directory) and excludes RULE. The pom holds a <build> with <plugins> (javac_lint's
# does) or none at all.
pmd_without() {
  # shellcheck disable=SC2016 # the literal ${project.basedir} is for Maven
  local plugin='      <plugin>\n        <artifactId>maven-pmd-plugin</artifactId>\n        <configuration>\n          <rulesets>\n            <ruleset>${project.basedir}/pmd-ruleset.xml</ruleset>\n          </rulesets>\n        </configuration>\n      </plugin>\n'
  if grep -q '^    </plugins>' "$1/pom.xml"; then
    sed_into "$1/pom.xml" "s|^    </plugins>|$plugin&|"
  else
    sed_into "$1/pom.xml" "s|^</project>|  <build>\\n    <plugins>\\n$plugin    </plugins>\\n  </build>\\n&|"
  fi || return
  # shellcheck disable=SC2016 # the literal ${project.basedir} is for Maven
  grep -qF '${project.basedir}/pmd-ruleset.xml' "$1/pom.xml" || {
    echo "pmd_without: $1/pom.xml did not take the <rulesets> edit" >&2
    return 1
  }
  cat >"$1/pmd-ruleset.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<ruleset name="Module PMD Rules"
    xmlns="http://pmd.sourceforge.net/ruleset/2.0.0"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://pmd.sourceforge.net/ruleset/2.0.0 https://pmd.sourceforge.io/ruleset_2_0_0.xsd">
  <description>devkit's rules without $2.</description>
  <rule ref="${3:-target/devkit/pmd-ruleset.xml}">
    <exclude name="$2" />
  </rule>
</ruleset>
XML
}

# jakarta_order: a monolith copy whose class imports java, org and jakarta in the order before jakarta
# joined the import order (jakarta last) fails make lint with the format violation, and make format
# puts jakarta after java and before org, so that lint passes. Path is stubbed by jakarta_path_stub.
jakarta_order() {
  local dir=$work/jakarta-order src
  setup "$root/tests/fixtures/java-monolith" "$dir" || return
  src=$dir/src/main/java
  jakarta_path_stub "$src" || return
  cat >"$src/devkit/fixture/Endpoint.java" <<'JAVA'
package devkit.fixture;

import java.util.List;

import org.w3c.dom.Node;

import jakarta.ws.rs.Path;

/** An endpoint. */
@Path("endpoint")
public final class Endpoint {

    /**
     * Counts the nodes.
     *
     * @param nodes the nodes
     * @return their number
     */
    public int count(List<Node> nodes) {
        return nodes.size();
    }
}
JAVA
  make_says fail "$dir" lint "format violations" &&
    make_says pass "$dir" format && make_says pass "$dir" lint &&
    [[ $(grep '^import' "$src/devkit/fixture/Endpoint.java" | sed -n 2p) == 'import jakarta.ws.rs.Path;' ]]
}

# checkstyle_report REPORT DIR CASES [ID...]: REPORT, the Checkstyle result of the checkstyle_cases
# copy in DIR, holds for each case file exactly the rule ids its directory is named after, less the
# IDs for a src/test file (the ones the run exempts there), and none for allowed/. A file missing
# from the report fails, as does a number of case files other than CASES.
checkstyle_report() {
  python3 -I - "$@" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

report, root, cases, exempt = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]), set(sys.argv[4:])
PREFIX = "com.puppycrawl.tools.checkstyle.checks."


def rule(source):
    """The module id after the check's class, else the check's name"""
    check, _, module_id = source.partition("#")
    return module_id or check.removeprefix(PREFIX).rsplit(".", 1)[-1].removesuffix("Check")


found = {
    Path(f.get("name", "")).resolve(): {rule(e.get("source", "")) for e in f.iter("error")}
    for f in ET.parse(report).getroot().iter("file")
}
problems, checked = [], 0
for kind in ("main", "test"):
    for java in sorted((root / "src" / kind / "java" / "cases").rglob("*.java")):
        name = java.parent.name
        want = set() if name == "allowed" else set(name.split("+")) - (exempt if kind == "test" else set())
        got = found.get(java.resolve())
        checked += 1
        if got is None:
            problems.append(f"{kind}/{name}/{java.name}: not in the report")
        elif got != want:
            problems.append(f"{kind}/{name}/{java.name}: expected {sorted(want)}, got {sorted(got)}")
if checked != cases:
    problems.append(f"{checked} case files found, expected {cases}")
sys.exit("\n".join(problems)) if problems else None
PY
}

# checkstyle_cases: tests/fixtures/checkstyle-cases in a java-monolith copy, main/ and test/ as
# src/main/java/cases and src/test/java/cases. A directory named by a rule's id (by its check's
# name where it has none), or by several joined with +, holds files that must each report those
# rules and nothing else; allowed/ holds files that must report nothing. Only the shared Checkstyle
# execution runs, through the pinned Maven and mvn_checked.sh, so the cases need not compile. The
# copy sits below a src/test directory, as a checkout may: the kit's own exemption of
# SuppressWarningsNullAway must still hold only for the copy's src/test, and the documented test
# exemptions for ConsoleOutput and LogManager, in a second run, must pass the test/ cases there as
# well.
checkstyle_cases() {
  local dir=$work/below/src/test/checkstyle-cases mvn kind cases java id
  local exempt=(RegexpSinglelineJava.ConsoleOutput IllegalImport.LogManager)
  cases=$(find "$root/tests/fixtures/checkstyle-cases" -name '*.java' | wc -l) &&
    mkdir -p "${dir%/*}" || return
  setup "$root/tests/fixtures/java-monolith" "$dir" &&
    make --no-print-directory -C "$dir" help >/dev/null || return # links .devkit
  for kind in main test; do
    mkdir -p "$dir/src/$kind/java/cases" &&
      cp -r "$root/tests/fixtures/checkstyle-cases/$kind/." "$dir/src/$kind/java/cases/" || return
  done
  mvn=$("$root/scripts/lib/pinned_maven.sh") &&
    java=$(sed -n 's/^JAVA_VERSION := //p' "$dir/Makefile") && [[ -n $java ]] || return
  checkstyle_only() {
    rm -rf "$dir/target"
    (cd "$dir" && MVN_LAUNCHER="$mvn" JAVA_VERSION=$java "$root/scripts/lib/mvn_checked.sh" -B -q \
      org.apache.maven.plugins:maven-checkstyle-plugin:check@checkstyle >"$dir.checkstyle.log" 2>&1)
    # The check fails the build on the cases; the report is what counts
    [[ -s $dir/target/checkstyle-result.xml ]] || {
      tail -n 40 "$dir.checkstyle.log"
      return 1
    }
  }
  checkstyle_only && checkstyle_report "$dir/target/checkstyle-result.xml" "$dir" "$cases" || return
  for id in "${exempt[@]}"; do
    sed_into "$dir/checkstyle-suppressions.xml" 's#^</suppressions>#    <suppress id="'"$id"'" files="[\\\\/]src[\\\\/]test[\\\\/](?!.*[\\\\/]src[\\\\/](main|test)[\\\\/])" />\n&#' || return
  done
  checkstyle_only && checkstyle_report "$dir/target/checkstyle-result.xml" "$dir" "$cases" "${exempt[@]}"
}

# catch_without_cause: a sed that adds to Greeter a method whose catch throws a new exception
# without the caught one as its cause (PMD's PreserveStackTrace).
catch_without_cause() {
  printf '%s' 's/^}$/\n    \/** Parses {@code text}, losing the cause. *\/\n    public int lossy(String text) {\n        try {\n            return Integer.parseInt(text);\n        } catch (NumberFormatException e) {\n            throw new IllegalArgumentException("bad number");\n        }\n    }\n}/'
}

# many_branches: a sed that adds to Greeter a method of eleven if branches, over PMD's cyclomatic
# complexity of 10.
many_branches() {
  local body='' i
  for i in {1..11}; do body+="        if (n == $i) {\\n            return $i;\\n        }\\n"; done
  printf '%s' "s/^}\$/\\n    \\/** Names a number. *\\/\\n    public int branchy(int n) {\\n${body}        return 0;\\n    }\\n}/"
}

# pmd_recipe_keeps: a monolith copy that drops PMD's ConstructorCallsOverridableMethod through its
# own pmd-ruleset.xml still has the filtered pmd.extraAssertMethodNames (an unknown assertion helper
# named there passes) and PMD's other rules (a catch without the cause fails on PreserveStackTrace
# alone).
pmd_recipe_keeps() {
  local dir=$work/pmd-recipe
  setup "$root/tests/fixtures/java-monolith" "$dir" && add_assert_helper "$dir" &&
    sed_into "$dir/pom.xml" 's|<maven.compiler.release>|<pmd.extraAssertMethodNames>greetingIs</pmd.extraAssertMethodNames>\n    &|' &&
    pmd_without "$dir" ConstructorCallsOverridableMethod &&
    make_says pass "$dir" lint "Lint checks completed." &&
    sed_into "$dir/src/main/java/devkit/fixture/Greeter.java" "$(catch_without_cause)" &&
    make_says fail "$dir" lint "has found 1 violation" "Rule:PreserveStackTrace"
}

# pmd_module_recipe: in java-multimodule, a package-private class of app whose constructor calls an
# overridable method (SpotBugs' MC_OVERRIDABLE_METHOD_CALL_IN_CONSTRUCTOR, excluded in app) fails
# make lint on PMD's ConstructorCallsOverridableMethod, until app's own pmd-ruleset.xml references
# app/target/devkit/pmd-ruleset.xml, as MODULES lists the module, and excludes the rule: lint and
# lint ONLY=app then pass, with app's pmd.extraAssertMethodNames, which only app's pom names,
# reaching the test that checks through a helper. ONLY=app reads core from the local repository
# out_of_reactor installed it into, so this runs after it.
pmd_module_recipe() {
  local dir=$work/pmd-module-recipe app=$work/pmd-module-recipe/app
  local srcdir=$app/src/main/java/devkit/fixture/app testdir=$app/src/test/java/devkit/fixture/app
  setup "$root/tests/fixtures/java-multimodule" "$dir" || return
  cat >"$srcdir/Boxed.java" <<'JAVA'
package devkit.fixture.app;

/** Fills its label on construction. */
class Boxed {

    private String label = "";

    Boxed() {
        fill();
    }

    String label() {
        return label;
    }

    void fill() {
        label = "boxed";
    }
}
JAVA
  # No assert*, verify* or check* in the names: PMD accepts those by default.
  cat >"$testdir/ParityIs.java" <<'JAVA'
package devkit.fixture.app;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class ParityIs {

    private ParityIs() {
    }

    static void parityIs(String expected, int number) {
        assertEquals(expected, new Parity().of(number));
    }
}
JAVA
  cat >"$testdir/HelperTest.java" <<'JAVA'
package devkit.fixture.app;

import org.junit.jupiter.api.Test;

class HelperTest {

    @Test
    void namesByHelper() {
        ParityIs.parityIs("even", 2);
    }
}
JAVA
  sed_into "$app/spotbugs-exclude.xml" "s|\" />\$|\">\\n  <Match>\\n    <Class name=\"devkit.fixture.app.Boxed\" />\\n    <Bug pattern=\"MC_OVERRIDABLE_METHOD_CALL_IN_CONSTRUCTOR\" />\\n  </Match>\\n</FindBugsFilter>|" &&
    sed_into "$app/pom.xml" 's|^  <artifactId>app</artifactId>|&\n\n  <properties>\n    <pmd.extraAssertMethodNames>parityIs</pmd.extraAssertMethodNames>\n  </properties>|' &&
    make_says fail "$dir" lint "has found 1 violation" "Rule:ConstructorCallsOverridableMethod" &&
    pmd_without "$app" ConstructorCallsOverridableMethod app/target/devkit/pmd-ruleset.xml &&
    make_says pass "$dir" lint "Lint checks completed." &&
    ONLY=app MAVEN_ARGS="-Dmaven.repo.local=$work/m2 -Dmaven.repo.local.tail=$HOME/.m2/repository -o" \
      make_says pass "$dir" lint "Lint checks completed."
}

negatives() {
  assert_helper_checks
  check "java-monolith: a duplicated block fails make lint, CPD naming each place" \
    cpd_duplicate
  check "java-monolith: a Serializable class without a serialVersionUID fails make lint, until the module appends -Xlint:-serial and excludes SpotBugs' SE_NO_SERIALVERSIONID" \
    javac_lint serial 's/^import edu/import java.io.Serializable;\n\nimport edu/; s/^public final class Greeter {/public final class Greeter implements Serializable {/' \
    SE_NO_SERIALVERSIONID
  check "java-monolith: a constructor calling an overridable method fails make lint, until the module appends -Xlint:-this-escape, excludes SpotBugs' MC_OVERRIDABLE_METHOD_CALL_IN_CONSTRUCTOR and drops PMD's ConstructorCallsOverridableMethod through its own pmd-ruleset.xml" \
    javac_lint this-escape 's/^public final class Greeter {/public class Greeter {\n\n    \/** Greets once on construction. *\/\n    public Greeter() {\n        greet("x");\n    }/' \
    MC_OVERRIDABLE_METHOD_CALL_IN_CONSTRUCTOR "" ConstructorCallsOverridableMethod
  check "java-monolith: the module's own pmd-ruleset.xml keeps PMD's other rules and pmd.extraAssertMethodNames in force" \
    pmd_recipe_keeps
  check "java-multimodule: a module's own pmd-ruleset.xml referencing <module dir>/target/devkit/pmd-ruleset.xml drops a PMD rule from make lint and make lint ONLY=app, keeping the module's pmd.extraAssertMethodNames" \
    pmd_module_recipe
  check "java-monolith: a constructor handing this out to a static list fails make lint, which SpotBugs does not report, until the module appends -Xlint:-this-escape" \
    javac_lint this-escape 's/^import edu/import java.util.ArrayList;\nimport java.util.List;\n\nimport edu/; s/^public final class Greeter {/public class Greeter {\n\n    private static final List<Object> SEEN = new ArrayList<>();\n\n    \/** Registers itself on construction. *\/\n    public Greeter() {\n        SEEN.add(this);\n    }/' \
    "" this-escape-handed
  check "java-monolith: checkstyle-xpath-suppressions.xml suppresses a violation make lint reports" \
    xpath_suppression
  check "java-monolith: find-sec-bugs runs: an XML parser open to external entities and a JBoss Logging or Quarkus Log call of an untrusted value fail make lint, also as the format of a long overload and not under a constant format with a long, the JAX-RS endpoint marker excluded, with no analysis error" \
    find_sec_bugs
  local main=src/main/java/devkit/fixture/Greeter.java
  local test=src/test/java/devkit/fixture/GreeterTest.java indent='s/^    public/  public/'
  negative format lint "format violations" "$main" "$indent"
  check "java-monolith: make format fixes a format break" formatted "$main" "$indent"
  check "java-monolith: imports of java, org and jakarta in the order before jakarta joined it fail make lint, and make format puts jakarta after java" \
    jakarta_order
  negative preserve-stack-trace lint "Rule:PreserveStackTrace" "$main" "$(catch_without_cause)"
  negative cyclomatic-complexity lint "Rule:CyclomaticComplexity" "$main" "$(many_branches)"
  negative checkstyle lint "fully qualified class names (FQCN)" "$main" \
    's/return name\./return java.util.Objects.requireNonNull(name)./'
  negative project-checkstyle lint "Fixture project rule" "$main" \
    's/^package .*/&\n\nimport java.util.Objects;/; s/return name\./return Objects.requireNonNull(name)./'
  # GreeterTest imports the banned class too; only its suppression lets lint pass.
  negative suppression lint "Fixture project rule" checkstyle-suppressions.xml '/FixtureObjects/d'
  # The shared config bans a NullAway suppression in main sources and exempts src/test, with no
  # line in the fixture's checkstyle-suppressions.xml.
  negative nullaway-suppression lint "Do not suppress NullAway" "$main" \
    's/^public final class/@SuppressWarnings("NullAway")\n&/'
  # The exemption is of the checkout's own src/test, not of an ancestor directory named so.
  check "java-monolith: a NullAway suppression in a main source fails make lint in a checkout below a src/test directory" \
    nullaway_below_src_test "$main"
  edited "$work/nullaway-in-tests" "$test" 's/^    @Test$/    @SuppressWarnings("NullAway")\n&/'
  check "java-monolith: a NullAway suppression in a test source passes make lint" \
    nullaway_in_tests "$work/nullaway-in-tests" "$test"
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
  negative java-version check "point JAVA_HOME at that JDK" Makefile 's/^JAVA_VERSION .*/JAVA_VERSION := 24/'
  negative java-version-test test "point JAVA_HOME at that JDK" Makefile 's/^JAVA_VERSION .*/JAVA_VERSION := 24/'
  local bypass # the enforcer's own switches, in MAVEN_ARGS, must not silence the JDK check
  for bypass in skip=true fail=false skipRules=requireJavaVersion rules=requireMavenVersion; do
    MAVEN_ARGS=-Denforcer.$bypass negative "java-version-${bypass%%=*}" check "point JAVA_HOME at that JDK" Makefile \
      's/^JAVA_VERSION .*/JAVA_VERSION := 24/'
  done
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
  check "java-monolith: a plugin jar altered in the local repository fails make lint on a checksum mismatch" \
    tampered_plugin
  launcher_checks
}

# The other checks pass with the shared checksums file (scripts/lib/mvn_checked.sh) dead too, as
# every misconfiguration of it passes silently, so this one proves it live end to end. A lint
# passes with the local repository empty and reading through to ~/.m2 (a hit there is verified too:
# a tampered jar in a tail fails the same way). Then the compiler plugin's jar, copied from ~/.m2
# into that repository with one byte added, must fail the build naming the plugin and the hash the
# file lists ("Checksum validation failed ... Trusted Checksums Source: summaryFile"), not as a
# missing plugin. Once more with the resolver's
# own keys in MAVEN_ARGS asking for record mode (which would write what the build resolves instead
# of verifying it) and for verification off, and again with scope=project, then with record=true
# and the scope in .mvn/maven.config: the wrapper's keys, last on the command line, must win.
tampered_plugin() {
  local proj=$work/negative-checksum m2=$work/m2-checksum version dir jar hash
  version=$(parent_property compiler-plugin.version)
  [[ -n $version ]] || return
  dir=org/apache/maven/plugins/maven-compiler-plugin/$version jar=maven-compiler-plugin-$version.jar
  hash=$(sed -n "s|^\([0-9a-f]*\)  $dir/$jar\$|\1|p" "$root/java/checksums/checksums.sha256")
  [[ -n $hash ]] || return
  local -x MAVEN_ARGS="-Dmaven.repo.local=$m2 -Dmaven.repo.local.tail=$HOME/.m2/repository"
  setup "$root/tests/fixtures/java-monolith" "$proj" && make_says pass "$proj" lint "Lint checks completed." &&
    mkdir -p "$m2/$dir" && cp "$HOME/.m2/repository/$dir/"* "$m2/$dir/" && echo x >>"$m2/$dir/$jar" &&
    make_says fail "$proj" lint "maven-compiler-plugin:$version or one of its dependencies could not be resolved" "$hash" &&
    MAVEN_ARGS="$MAVEN_ARGS -Daether.artifactResolver.postProcessor.trustedChecksums.record=true -Daether.artifactResolver.postProcessor.trustedChecksums=false -Daether.trustedChecksumsSource.summaryFile=false" \
      make_says fail "$proj" lint "$hash" &&
    MAVEN_ARGS="$MAVEN_ARGS -Daether.artifactResolver.postProcessor.trustedChecksums.scope=project" \
      make_says fail "$proj" lint "$hash" &&
    printf '%s\n' -Daether.artifactResolver.postProcessor.trustedChecksums.record=true \
      -Daether.artifactResolver.postProcessor.trustedChecksums.scope=project >"$proj/.mvn/maven.config" &&
    make_says fail "$proj" lint "$hash"
}

# A profile MAVEN_ARGS requests applies under devkit's Maven. The probe profile asks for a release no
# javac knows, so make test fails at compile only when the profile applies (javac's own message is
# localized). A Maven outside devkit.maven.range fails make check, and launcher_inputs checks that
# the pinned launcher reads no variable the screen and clean_env leave unaccounted for.
launcher_checks() {
  local proj=$work/profile
  edited "$proj" pom.xml \
    's|^</project>|  <profiles><profile><id>probe</id><properties><maven.compiler.release>99</maven.compiler.release></properties></profile></profiles>\n&|'
  MAVEN_ARGS=-Pprobe check "java-monolith: a profile in MAVEN_ARGS applies under devkit's Maven" \
    make_says fail "$proj" test "Fatal error compiling" 99
  MAVEN_ARGS='-Ddevkit.maven.range=[99,)' check "java-monolith: Maven outside devkit.maven.range fails make check" \
    make_says fail "$proj" check "RequireMavenVersion"
  check "scripts: the pinned Maven launcher reads no variable make gate, pre-push and clean_env leave unaccounted for" \
    launcher_inputs
}

# launcher_inputs: every upper-case variable the pinned bin/mvn expands (outside a comment) is one it
# sets before reading, one listed here as harmless, or one that make gate and pre-push screen (outside
# a comment), hooks_test.sh tests in a `VAR=` case and clean_env clears. The lists are reviewed against
# one launcher, so a Maven bump fails here until they are reviewed again, naming any variable the new
# launcher adds. Only the launcher's own expansions count: what Maven's Java side reads is not a
# launcher input (env.MAVEN_REPO_CENTRAL relocates Central but cannot skip tests, and the checksums
# file is origin-unaware).
launcher_inputs() {
  local mvn var file names unknown="" reviewed=3.10.0 screened="MAVEN_ARGS MAVEN_OPTS MAVEN_DEBUG_OPTS MAVEN_BASEDIR"
  # Set by the launcher itself before it reads them.
  local own="PRG MAVEN_HOME JAVACMD CLASSWORLDS_JAR CLASSWORLDS_LAUNCHER JLINE_NATIVE_PATH MAVEN_PROJECTBASEDIR"
  # HOME and MAVEN_SKIP_RC pick the rc files the screen checks; JAVA_HOME's JDK has its major version
  # checked by the parent's enforcer on every Maven call; CLASSPATH is read only under Cygwin or MinGW;
  # MAVEN_CONFIG reaches only MAVEN_CMD_LINE_ARGS, which Maven does not read (clean_env clears it all
  # the same).
  local harmless="HOME MAVEN_SKIP_RC JAVA_HOME CLASSPATH MAVEN_CONFIG"
  # uncommented: stdin without its full-line and trailing comments
  uncommented() { sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]]#.*//'; }
  mvn=$("$root/scripts/lib/pinned_maven.sh") || return
  names=" $(sed '/^[[:space:]]*#/d' "$mvn" | LC_ALL=C grep -oE '\$\{?[A-Z_][A-Z0-9_]*' | tr -d '{$' | LC_ALL=C sort -u | tr '\n' ' ')"
  for var in $names; do
    [[ " $screened $own $harmless " == *" $var "* ]] || unknown="$unknown $var"
  done
  [[ -z $unknown ]] || { echo "$mvn reads:$unknown"; return 1; }
  [[ $(maven_version "$root") == "$reviewed" ]] ||
    { echo "launcher_inputs' lists were reviewed against Maven $reviewed's bin/mvn: review them for $mvn, then raise reviewed="; return 1; }
  for var in $screened; do
    [[ $names == *" $var "* ]] || { echo "$mvn no longer reads $var: drop it from screened"; return 1; }
    for file in scripts/gate.sh scripts/hooks/pre-push.sh; do
      grep -qw "$var" <<<"$(uncommented <"$root/$file")" || { echo "$file does not screen $var"; return 1; }
    done
    grep -qE "(^|[^A-Za-z0-9_])$var=" <<<"$(uncommented <"$root/tests/hooks_test.sh")" || { echo "tests/hooks_test.sh has no case setting $var="; return 1; }
    grep -qw "$var" <<<"$(sed -n '/^clean_env()/,/^}/p' "$root/scripts/lib/tree.sh" | uncommented)" || { echo "clean_env keeps $var"; return 1; }
  done
}

conflicted() { # conflicted DIR BRANCH: merging BRANCH fails and leaves a merge to resolve
  if git -C "$1" merge -q --no-edit "$2" >/dev/null || ! git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null; then
    echo "merging $2 did not stop on a conflict"
    return 1
  fi
}

secret_negatives() { # each scan of the real gitleaks reads what it should
  local leak older append proj blob sha old
  # Built here, so this file holds no token; edited() leaves the change unstaged.
  leak="gh""p_$(printf '%s' {z..a} {9..0})"
  older="gh""p_$(printf '%s' {Z..A} {9..0})" # another value, so another fingerprint (gitleaks skips {9..0}{a..z})
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
  # A secret the history scan reads only through its log options (--text,
  # --diff-merges=remerge, --no-textconv); each is in no commit's plain diff.
  proj=$work/negative-secret-diff-attribute
  setup "$root/tests/fixtures/java-monolith" "$proj"
  printf 'token = %s\n' "$leak" >"$proj/secret.cfg"
  git -C "$proj" add secret.cfg
  git -C "$proj" commit -q -m leak
  sha=$(git -C "$proj" rev-parse HEAD)
  printf 'secret.cfg -diff\n' >"$proj/.gitattributes"
  git -C "$proj" add .gitattributes
  git -C "$proj" commit -q -m hide
  check "java-monolith: a secret behind a -diff attribute fails make lint, found in history" \
    make_says fail "$proj" lint "leaks found: 1" "Fingerprint: $sha:secret.cfg:github-pat:"
  proj=$work/negative-secret-merge
  setup "$root/tests/fixtures/java-monolith" "$proj"
  # A secret older than the merge and its branch point: a scan that stopped at the merge's entry would miss it.
  printf 'token = %s\n' "$older" >"$proj/old.cfg"
  git -C "$proj" add old.cfg
  git -C "$proj" commit -q -m older
  old=$(git -C "$proj" rev-parse HEAD)
  printf 'key = base\n' >"$proj/merge.cfg"
  git -C "$proj" add merge.cfg
  git -C "$proj" commit -q -m base
  git -C "$proj" checkout -q -b side
  printf 'key = side\n' >"$proj/merge.cfg"
  git -C "$proj" commit -q -am side
  git -C "$proj" checkout -q main # setup inits it
  printf 'key = main\n' >"$proj/merge.cfg"
  git -C "$proj" commit -q -am main
  check "java-monolith: the merge conflicts, as meant" conflicted "$proj" side
  printf 'key = %s\n' "$leak" >"$proj/merge.cfg"
  git -C "$proj" add merge.cfg
  git -C "$proj" commit -q --no-edit
  sha=$(git -C "$proj" rev-parse HEAD)
  # gitleaks' parser reads remerge's conflict header as the path b/merge.cfg.
  check "java-monolith: a secret in a conflict resolution fails make lint, found in the merge and in the older commit" \
    make_says fail "$proj" lint "leaks found: 2" \
    "Fingerprint: $sha:b/merge.cfg:github-pat:" "Fingerprint: $old:old.cfg:github-pat:"
  printf '%s:b/merge.cfg:github-pat:1\n' "$sha" >"$proj/.gitleaksignore"
  git -C "$proj" add .gitleaksignore
  git -C "$proj" commit -q -m ignore
  check "java-monolith: ignoring only the conflict resolution's fingerprint still fails make lint on the older commit" \
    make_says fail "$proj" lint "leaks found: 1" "Fingerprint: $old:old.cfg:github-pat:"
  printf '%s:old.cfg:github-pat:1\n' "$old" >>"$proj/.gitleaksignore"
  git -C "$proj" commit -q -am ignore-older
  check "java-monolith: both printed fingerprints in .gitleaksignore pass make lint" \
    make_says pass "$proj" lint
  proj=$work/negative-secret-clean-merge
  setup "$root/tests/fixtures/java-monolith" "$proj"
  git -C "$proj" checkout -q -b side
  printf 'key = side\n' >"$proj/side.cfg"
  git -C "$proj" add side.cfg
  git -C "$proj" commit -q -m side
  git -C "$proj" checkout -q main
  printf 'key = main\n' >"$proj/main.cfg"
  git -C "$proj" add main.cfg
  git -C "$proj" commit -q -m main
  git -C "$proj" merge -q --no-commit --no-ff side >/dev/null
  printf 'token = %s\n' "$leak" >>"$proj/side.cfg"
  git -C "$proj" add side.cfg
  git -C "$proj" commit -q --no-edit
  check "java-monolith: a change a clean merge adds fails make lint, found in the merge" \
    make_says fail "$proj" lint "leaks found: 1" \
    "Fingerprint: $(git -C "$proj" rev-parse HEAD):side.cfg:github-pat:"
  proj=$work/negative-secret-textconv
  setup "$root/tests/fixtures/java-monolith" "$proj"
  git -C "$proj" config diff.hide.textconv 'sed d' # this copy only
  printf 'secret.cfg diff=hide\n' >"$proj/.gitattributes"
  printf 'token = %s\n' "$leak" >"$proj/secret.cfg"
  git -C "$proj" add .gitattributes secret.cfg
  git -C "$proj" commit -q -m leak
  check "java-monolith: a secret behind a textconv driver fails make lint, found in history" \
    make_says fail "$proj" lint "leaks found: 1" \
    "Fingerprint: $(git -C "$proj" rev-parse HEAD):secret.cfg:github-pat:"
  # gitleaks itself passes a history scan whose git log fails.
  proj=$work/negative-missing-object
  setup "$root/tests/fixtures/java-monolith" "$proj"
  blob=$(git -C "$proj" rev-parse HEAD:compose.yaml)
  rm -f "$proj/.git/objects/${blob:0:2}/${blob:2}"
  check "java-monolith: a missing object fails make lint" \
    make_says fail "$proj" lint "git failed under gitleaks git --log-opts=HEAD"
}

prepare() { # once per run: the temp dir and a clean environment
  [[ -z $work ]] || return 0
  work=$(mktemp -d) tag=v$(parent_version "$root") bare=$work/devkit.git
  trap 'uncache "$work"' EXIT
  clean_env
  # No system or user git attributes either (a machine-wide merge=union would resolve the conflict test's merge).
  mkdir "$work/xdg-config"
  export XDG_CACHE_HOME=$work/cache GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1 XDG_CONFIG_HOME=$work/xdg-config
  export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
  export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
}

isolated() { # isolated COMMAND...: run COMMAND in a subshell, so that no later part inherits its environment; $work/fails carries the count back
  (
    "$@"
    echo "$fails" >"$work/fails"
  )
  fails=$(<"$work/fails")
}

# parent_property NAME [POM]: the value of POM's (default: the parent under test) property NAME, when on one line.
parent_property() { sed -n "s|^ *<$1>\\(.*\\)</$1>.*|\\1|p" "${2:-$root/java/parent/pom.xml}"; }

# spotbugs_version [POM]: the spotbugs.version property of the parent under test.
spotbugs_version() { parent_property spotbugs.version "$@"; }

# spotbugs_versions_match: spotbugs-plugin.version is spotbugs.version plus a fourth component, so a
# release that bumps the plugin and forgets the analyzer fails here, offline.
spotbugs_versions_match() {
  local plugin analyzer
  plugin=$(parent_property spotbugs-plugin.version "$@")
  analyzer=$(spotbugs_version "$@")
  [[ -n $analyzer && $plugin =~ ^${analyzer//./\\.}\.[0-9]+$ ]]
}

# spotbugs_log4j_excluded POM: POM's declaration of the SpotBugs analyzer as a plugin dependency, which
# replaces the plugin's own, repeats that one's exclusion of log4j-core (the plugin logs through
# log4j-to-slf4j).
spotbugs_log4j_excluded() {
  python3 -I -c 'import sys, xml.etree.ElementTree as ET
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
name = lambda e: e.findtext("m:artifactId", "", ns)
deps = [d for p in ET.parse(sys.argv[1]).getroot().iterfind(".//m:plugin", ns) if name(p) == "spotbugs-maven-plugin"
        for d in p.iterfind("m:dependencies/m:dependency", ns) if name(d) == "spotbugs"]
ok = deps and all(any((e.findtext("m:groupId", "", ns), name(e)) == ("org.apache.logging.log4j", "log4j-core") for e in d.iterfind("m:exclusions/m:exclusion", ns)) for d in deps)
sys.exit(None if ok else "the SpotBugs analyzer dependency does not exclude log4j-core")' "$1"
}

# parent_encodings POM: POM itself declares UTF-8 as the source and report encoding. Maven 3.10's super POM
# sets both too, so source_encoding below cannot tell when the parent drops them.
parent_encodings() {
  local property
  for property in project.build.sourceEncoding project.reporting.outputEncoding; do
    grep -qx " *<$property>UTF-8</$property>" "$1" || return
  done
}

# source_encoding DIR: the parent's UTF-8 source and report encoding reach DIR, whose pom sets neither
# (one help:evaluate of the project's properties).
source_encoding() {
  local mvn help property
  mvn=$("$root/scripts/lib/pinned_maven.sh") && help=$(frontend_plugins "$root" | grep ':maven-help-plugin:') &&
    (cd "$1" && "$mvn" -B -q "$help:evaluate" -Dexpression=project.properties -Doutput="$1.properties") || return
  for property in project.build.sourceEncoding project.reporting.outputEncoding; do
    grep -qF "<$property>UTF-8</$property>" "$1.properties" || return
  done
}

# annotations_managed DIR: dependency:list, run by the pinned Maven, resolves DIR's spotbugs-annotations
# at the parent's spotbugs.version, in scope provided.
annotations_managed() {
  local mvn want dep
  mvn=$("$root/scripts/lib/pinned_maven.sh") && want=$(spotbugs_version) && [[ -n $want ]] &&
    dep=$(frontend_plugins "$root" | grep ':maven-dependency-plugin:') &&
    (cd "$1" && "$mvn" -B -q "$dep:list" -DincludeArtifactIds=spotbugs-annotations -DoutputFile="$1.deps") &&
    grep -qF "com.github.spotbugs:spotbugs-annotations:jar:$want:provided" "$1.deps"
}

# integration_tests DIR: make test in DIR with the integration tests on passes, and failsafe ran GreeterIT
# (make coverage, which also runs them, ignores test failures).
integration_tests() {
  local -x MAVEN_ARGS=-DskipITs=false
  make_says pass "$1" test "Tests completed." && [[ -f $1/target/failsafe-reports/devkit.fixture.GreeterIT.txt ]]
}

# spotbugs_exclusions_match PARENT_POM M2: PARENT_POM's declaration of the analyzer as a plugin dependency,
# which replaces the plugin's own, excludes the same artifacts as the plugin's own declaration, in the
# plugin's pom in the local repository M2 (a later plugin release may add an exclusion).
spotbugs_exclusions_match() {
  local plugin
  plugin=$(parent_property spotbugs-plugin.version "$1") && [[ -n $plugin ]] || return
  python3 -I -c 'import sys, xml.etree.ElementTree as ET
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
name = lambda e: e.findtext("m:artifactId", "", ns)
def excluded(deps):
    found = [d for d in deps if name(d) == "spotbugs"]
    if len(found) != 1:
        sys.exit(f"{len(found)} declarations of the SpotBugs analyzer where one is expected")
    return {(e.findtext("m:groupId", "", ns), name(e)) for e in found[0].iterfind("m:exclusions/m:exclusion", ns)}
parent = ET.parse(sys.argv[1]).getroot()
own = ET.parse(sys.argv[2]).getroot()
ours = excluded(d for p in parent.iterfind(".//m:plugin", ns) if name(p) == "spotbugs-maven-plugin"
                for d in p.iterfind("m:dependencies/m:dependency", ns))
theirs = excluded(own.iterfind("m:dependencies/m:dependency", ns))
sys.exit(f"the parent excludes {sorted(ours)!r}, the plugin {sorted(theirs)!r}") if ours != theirs else None' \
    "$1" "$2/com/github/spotbugs/spotbugs-maven-plugin/$plugin/spotbugs-maven-plugin-$plugin.pom"
}

# analyzer_version XML: SpotBugs' report XML names the parent's spotbugs.version as its analyzer.
analyzer_version() {
  python3 -I -c 'import sys, xml.etree.ElementTree as ET
got = ET.parse(sys.argv[1]).getroot().get("version")
sys.exit(f"SpotBugs ran {got!r}, the parent says {sys.argv[2]!r}") if got != sys.argv[2] else None' "$1" "$(spotbugs_version)"
}

# no_analysis_errors DIR MODULE...: each MODULE of DIR has a SpotBugs report with errors="0".
no_analysis_errors() {
  local module
  for module in "${@:2}"; do
    python3 -I -c 'import sys, xml.etree.ElementTree as ET
errors = ET.parse(sys.argv[1]).getroot().find("Errors").get("errors")
sys.exit(f"{sys.argv[1]}: {errors} analysis errors") if errors != "0" else None' "$1/$module/target/spotbugsXml.xml" || return
  done
}

# no_warning_lines DIR TARGET...: none of the logs of DIR's passing TARGETs holds a [WARNING] line.
# Under -q such a line is a finding the two loggers mvn_checked.sh raises let through, or noise to fix.
no_warning_lines() {
  local target log
  for target in "${@:2}"; do
    log=$1.$target.log
    [[ -s $log ]] || {
      echo "$log is missing or empty"
      return 1
    }
    ! grep -n '^\[WARNING\]' "$log" || return
  done
}

java_part() {
  prepare
  publish
  for fixture in "$root"/tests/fixtures/java-*/; do
    run_fixture "${fixture%/}" "check lint test coverage format"
    check "$(basename "$fixture"): passing Maven targets print no [WARNING] line" \
      no_warning_lines "$work/$(basename "$fixture")" lint test coverage
    unchanged "${fixture%/}" target .coverage.md
  done
  check "java-monolith: the first make target downloads devkit's Maven" \
    grep -q "Downloading Maven $(maven_version "$root") from" "$work/java-monolith.check.log"
  check "java-monolith: spotbugs-annotations, declared without a version, resolves, provided, to the parent's spotbugs.version" \
    annotations_managed "$work/java-monolith"
  check "java-monolith: the SpotBugs run reports the parent's spotbugs.version" \
    analyzer_version "$work/java-monolith/target/spotbugsXml.xml"
  check "java-multimodule: every module's SpotBugs run reports no analysis error" \
    no_analysis_errors "$work/java-multimodule" core app
  check "java-monolith: the parent's UTF-8 source and report encoding reach a fixture that sets neither" \
    source_encoding "$work/java-monolith"
  check "java-monolith: make test with the integration tests on passes, the parent's quarkus.jacoco.report=false reaching failsafe too" \
    integration_tests "$work/java-monolith"
  check "parent: the SpotBugs analyzer dependency excludes what the plugin's own declaration of it excludes" \
    spotbugs_exclusions_match "$root/java/parent/pom.xml" "$HOME/.m2/repository"
  check "parent: the committed checksums list the artifacts of the formatter version Spotless runs, whose lockfile spotless-lib-extra embeds" \
    python3 -I "$root/scripts/java/formatter_lockfile.py" "$root/java/parent/pom.xml" "$HOME/.m2/repository" "$root/java/checksums/checksums.sha256"
  out_of_reactor
  check "java-multimodule: a dependency under a groupId that only starts with the project's is still license-checked, by every make test until an override declares its license" \
    foreign_group
  check "java-multimodule: a dependency under an unlisted license fails every make test, until the module appends it to includedLicenses, and two dependencies under an allowed and a commercial license pass" \
    unlisted
  check "java-multimodule: dependencies under the common spellings of allowed licenses pass make test" spellings
  check "java-monolith: each Checkstyle case reports the rules its directory names and nothing else, the allowed forms pass, and the documented test exemptions pass the ConsoleOutput and LogManager cases" \
    checkstyle_cases
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
  local dep=$work/dep-$1 pom=() licenses='' name mvn
  mvn=$("$root/scripts/lib/pinned_maven.sh") || return 1
  mkdir "$dep" && echo x >"$dep/x.txt" && jar cf "$dep/x.jar" -C "$dep" x.txt || return
  for name in "${@:2}"; do licenses+="<license><name>$name</name></license>"; done
  if [[ -n $licenses ]]; then
    printf '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>
<groupId>devkit.fixture.other</groupId><artifactId>%s</artifactId><version>1.0</version>
<licenses>%s</licenses></project>\n' "$1" "$licenses" >"$dep/pom.xml"
    pom=(-DpomFile="$dep/pom.xml")
  fi
  "$mvn" -B -q install:install-file -Dfile="$dep/x.jar" -DgroupId=devkit.fixture.other -DartifactId="$1" \
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

# Spellings of allowed licenses that real artifacts declare (Vaadin's and Undertow's
# "Apache License Version 2.0" first): jars under each, in one module, pass make test.
spellings() {
  local proj=$work/spellings i=0 name
  local -x MAVEN_ARGS="-Dmaven.repo.local=$work/m2 -Dmaven.repo.local.tail=$HOME/.m2/repository -o"
  local names=("Apache License Version 2.0" "Apache 2.0" "Apache 2" "Eclipse Public License 2.0"
    "Eclipse Public License, Version 2.0" "GNU General Public License, version 2 with the GNU Classpath Exception"
    "GNU General Public License, version 2, with the Classpath Exception" "GNU LESSER GENERAL PUBLIC LICENSE, Version 2.1"
    "CDDL + GPLv2 with classpath exception" "Universal Permissive License, Version 1.0" "UPL-1.0")
  with_dep "$proj" "${names[0]}" || return
  for name in "${names[@]:1}"; do
    install_dep "spelling-$((++i))" "$name" && depend_on "$proj" "spelling-$i" || return
  done
  ONLY=app make_says pass "$proj" test "Tests completed."
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
  # Under the cutoff a fixture's committed uv.lock was made with (README, "Gating devkit itself"):
  # what a test adds resolves no release younger than 24 hours, and the plain lock after it keeps
  # the versions and drops the recorded cutoff (uv sync --locked rejects a lock that records one).
  (cd "$1" && "$uv" lock -q --exclude-newer "24 hours" && "$uv" lock -q) && installed "$1"
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

py_touched() { # py_touched FIXTURE FILE [SED]: FILE touched after the install (SED first, relocked) fails make test until make install
  local dir=$work/py-touched-$1
  if [[ -n ${3:-} ]]; then py_copy "$1" "touched-$1" relocked "$2" "$3"; else py_copy "$1" "touched-$1" installed; fi || return
  make_says pass "$dir" test || return # the control: untouched, make test passes
  sleep 1 # the touch must change the mtime uv compares
  touch "$dir/$2"
  make_says fail "$dir" test "uv cannot confirm .venv matches uv.lock" "make install"
}

py_no_uv() { # the pinned uv copy missing (an empty tools cache) fails make test, saying make install
  py_copy single no-uv installed &&
    XDG_CACHE_HOME=$work/no-uv-cache make_says fail "$work/py-no-uv" test "is not installed in" "make install"
}

py_uninstalled() { # a dev tool removed from .venv behind uv's back is drift
  local dir=$work/py-uninstalled
  py_copy single uninstalled installed &&
    "$uv" pip uninstall -q --python "$dir/.venv/bin/python" vulture &&
    make_says fail "$dir" check "uv cannot confirm .venv matches uv.lock" &&
    make_says fail "$dir" test "uv cannot confirm .venv matches uv.lock"
}

py_drifted() { # py_drifted NAME: a package installed behind uv's back (extra), or a uv.lock changed without make install (lock), fails make test
  local dir=$work/py-drift-$1
  py_copy single "drift-$1" installed || return
  # Under devkit's 24-hour pin cutoff (README, Gating devkit itself), and the lock change drops a dependency, so nothing resolves anew.
  if [[ $1 == extra ]]; then
    "$uv" pip install -q --exclude-newer "24 hours" --python "$dir/.venv/bin/python" six
  else
    sed_into "$dir/pyproject.toml" 's/"vulture", //' && (cd "$dir" && "$uv" lock -q)
  fi && make_says fail "$dir" test "uv cannot confirm .venv matches uv.lock" "make install"
}

py_cache_cleared() { # --lf in addopts, a planted lastfailed naming one test: make test still runs both and passes
  local dir=$work/py-cache-cleared
  py_copy single cache-cleared installed pyproject.toml 's/^addopts = "/addopts = "--lf /' || return
  mkdir -p "$dir/.pytest_cache/v/cache" &&
    echo '{"tests/test_greeter.py::test_rejects_a_blank_name": true}' >"$dir/.pytest_cache/v/cache/lastfailed" &&
    make_says pass "$dir" test "2 passed"
}

# py_stale_coverage NAME FILE SED: SED on pyproject.toml makes --cov-append (and a data_file) in the
# configuration read FILE, which a direct pytest run fills in full, with the branch data make test
# collects, so that it combines; a test deleted: make test fails the floor and leaves FILE alone.
py_stale_coverage() {
  local dir=$work/py-$1 before
  py_copy single "$1" installed pyproject.toml "$3" &&
    (cd "$dir" && .venv/bin/pytest -q --cov-branch >/dev/null 2>&1) && [[ -s $dir/$2 ]] || return
  sed_into "$dir/tests/test_greeter.py" "/^def test_rejects_a_blank_name/,\$d" && before=$(cksum <"$dir/$2") &&
    make_says fail "$dir" test "is below COVERAGE_FLOOR 100%" && [[ $(cksum <"$dir/$2") == "$before" ]]
}

py_no_cacheprovider() { # -p no:cacheprovider in addopts: pytest still accepts --cache-clear, so make test passes
  py_copy single no-cacheprovider installed pyproject.toml 's/^addopts = "/addopts = "-p no:cacheprovider /' &&
    make_says pass "$work/py-no-cacheprovider" test "2 passed"
}

py_redirected() { # UV_PROJECT or UV_WORKING_DIR naming a synced project does not vouch for a drifted one
  local dir=$work/py-redirected
  py_copy single redirect-synced installed && py_copy single redirected installed &&
    "$uv" pip install -q --exclude-newer "24 hours" --python "$dir/.venv/bin/python" six &&
    UV_PROJECT=$work/py-redirect-synced make_says fail "$dir" test "uv cannot confirm .venv matches uv.lock" &&
    UV_WORKING_DIR=$work/py-redirect-synced make_says fail "$dir" test "uv cannot confirm .venv matches uv.lock"
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
  local dir=$work/py-vulnerable
  py_copy single vulnerable relocked pyproject.toml 's/^dependencies = \[\]/dependencies = ["jinja2==3.1.4"]/' &&
    make_says fail "$dir" audit "in 1 package" "jinja2" "3.1.4" &&
    accepted jinja2 GHSA-0000-0000-0000 "$dir" && make_says fail "$dir" audit "jinja2" "3.1.4" "stale"
}

# accepted PACKAGE ID DIR: DIR's devkit.toml gains an [[python.audit.accepted]] entry
accepted() {
  printf '\n[[python.audit.accepted]]\npackage = "%s"\nid = "%s"\nreason = "accepted by the python part"\n' "$1" "$2" >>"$3/devkit.toml"
}

# A dependency whose advisory only OSV carries (mako 1.4.1, PYSEC-2026-4243 = GHSA-5639-2j2p-m4mx,
# 2026-10): the PyPI run alone passes it, so only the OSV run can fail this. It stops discriminating
# once PyPI lists the advisory, which is why tests/python_audit_test.sh stubs pip-audit and asserts
# both runs.
py_osv_only() {
  local dir=$work/py-osv-only out alias
  py_copy single osv-only relocked pyproject.toml 's/^dependencies = \[\]/dependencies = ["mako==1.4.1"]/' || return
  # One run: it must fail on the OSV-only row, and the alias the real row carries (read from the
  # same output) is what an entry accepts it by.
  out=$(make --no-print-directory -C "$dir" audit 2>&1) && { printf 'make audit passed:\n%s\n' "$out"; return 1; }
  for text in mako 1.4.1 PYSEC-2026-4243; do
    [[ $out == *"$text"* ]] || { printf 'no %s in:\n%s\n' "$text" "$out"; return 1; }
  done
  alias=$(grep 'PYSEC-2026-4243 (aliases' <<<"$out" | grep -o 'GHSA-[0-9a-z]\{4\}-[0-9a-z]\{4\}-[0-9a-z]\{4\}' | head -n 1 || true)
  [[ -n $alias ]] || { printf 'no GHSA alias in:\n%s\n' "$out"; return 1; }
  accepted mako "$alias" "$dir" && make_says pass "$dir" audit "Audit completed" "accepted by the python part"
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

# A dependency only win32 installs, with live advisories: audited on Linux too, so audit fails on it.
py_marker_false() {
  local dir=$work/py-marker-false
  py_copy single marker-false relocked pyproject.toml \
    "s/^dependencies = \[\]/dependencies = [\"six\", \"jinja2==3.1.4 ; sys_platform == 'win32'\"]/" &&
    make_says fail "$dir" audit "jinja2 3.1.4: " "not accepted in devkit.toml"
}

# Every runtime dependency is one only win32 installs: audit still passes.
py_marker_only() {
  py_copy single marker-only relocked pyproject.toml \
    "s/^dependencies = \[\]/dependencies = [\"six ; sys_platform == 'win32'\"]/" &&
    make_says pass "$work/py-marker-only" audit "no advisory beyond the 0 accepted" "Audit completed"
}

# One name locked at two versions, one per platform: audit passes once both are audited.
py_forked() {
  local dir=$work/py-forked
  py_copy single forked relocked pyproject.toml \
    "s/^dependencies = \[\]/dependencies = [\"six==1.16.0 ; sys_platform == 'win32'\", \"six==1.17.0 ; sys_platform != 'win32'\"]/" &&
    [[ $(grep -A1 '^name = "six"$' "$dir/uv.lock" | grep -c '^version = ') == 2 ]] &&
    make_says pass "$dir" audit "no advisory beyond the 0 accepted" "Audit completed" "over the 2 pinned packages"
}

py_duplicated() { # a test module, one test longer, copied whole: a clone over 50 tokens
  local dir=$work/py-duplication
  py_copy single duplication installed tests/test_greeter.py \
    's/^        greet(" ")$/&\n\n\ndef test_greets_twice() -> None:\n    assert greet("a") + greet("b") == "Hello, aHello, b"/' &&
    cp "$dir/tests/test_greeter.py" "$dir/tests/test_greeter_copy.py" &&
    make_says fail "$dir" lint "duplicated code not accepted in devkit.toml: tests/test_greeter.py  ~  tests/test_greeter_copy.py"
}

py_venv_parses() { # make lint's anchored-match gate reports a file only .venv's Python reads, by that Python
  local dir=$work/py-venv-parses
  py_copy single venv-parses installed &&
    printf '\n[tool.ruff]\nextend-exclude = ["broken.py"]\n' >>"$dir/pyproject.toml" &&
    printf 'def broken(:\n' >"$dir/broken.py" &&
    make_says fail "$dir" lint "ERROR: cannot parse broken.py with Python $(<"$root/tests/fixtures/python-uv-single/.python-version")" "/.venv/bin/python): SyntaxError:"
}

# A .pth file in .venv's site-packages runs whenever a Python of that venv starts with site, and logs its
# command line. make lint runs vulture there (so the log must show the planted file live) and the anchored-match
# gate, which runs with -I -S and so must not appear in the log.
py_pth_isolated() {
  local dir=$work/py-pth log=$work/py-pth.log site
  py_copy single pth installed || return
  site=$(echo "$dir"/.venv/lib/python3*/site-packages) && [[ -d $site ]] || return
  printf 'import sys; open("%s", "a").write(" ".join(sys.orig_argv) + chr(10))\n' "$log" >"$site/devkit_marker.pth"
  make_says pass "$dir" lint && [[ -s $log && $(<"$log") == *"/bin/vulture"* && $(<"$log") != *anchored_match* ]]
}

# The same project with lint.sh's -S dropped, from a scratch copy of the tree under test (never the repo):
# the anchored-match gate then runs the planted file, so the check above discriminates.
py_pth_needs_s() {
  local dir=$work/py-pth log=$work/py-pth.log copy=$work/src-no-s
  cp -R "$work/src" "$copy" && sed_into "$copy/scripts/python/lint.sh" 's/ -I -S / -I /' &&
    ! cmp -s "$work/src/scripts/python/lint.sh" "$copy/scripts/python/lint.sh" || return
  rm -f "$log"
  PROJECT_ROOT=$dir DEVKIT=$copy MODULES='' "$copy/scripts/python/lint.sh" >"$work/py-pth-no-s.log" 2>&1 || :
  [[ -s $log && $(<"$log") == *anchored_match* ]]
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
  py_negative python-floor check ".python-version pins 3.10, but devkit needs CPython 3.11 or later" single "" .python-version 's/.*/3.10/'
  py_negative python-floor-3-9 check ".python-version pins 3.9, but devkit needs CPython 3.11 or later" single "" .python-version 's/.*/3.9/'
  # At the floor: past the version check, the next one (no .venv in an uninstalled copy) fails.
  py_negative python-floor-3-11 check "no .venv; run make install" single "" .python-version 's/.*/3.11/'
  check "python-uv-single: make lint's anchored-match gate parses with .venv's Python" py_venv_parses
  check "python-uv-single: make lint's anchored-match gate runs no .pth file of .venv's site-packages" py_pth_isolated
  check "python-uv-single: without -S in lint.sh (a scratch copy) the anchored-match gate runs the planted .pth file" py_pth_needs_s
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
  check "python-uv-single: a package installed behind uv's back fails make test" py_drifted extra
  check "python-uv-single: a uv.lock changed without make install fails make test" py_drifted lock
  check "python-uv-workspace: a touched member pyproject.toml fails make test until make install" \
    py_touched workspace packages/core/pyproject.toml
  check "python-uv-single: a touched packaged root's pyproject.toml fails make test until make install" \
    py_touched single pyproject.toml \
    's/^package = false/package = true\n\n[build-system]\nrequires = ["uv_build>=0.12.23,<0.13"]\nbuild-backend = "uv_build"/'
  check "python-uv-single: a missing pinned uv copy fails make test, saying make install" py_no_uv
  check "python-uv-single: make test clears pytest's cache, so --lf in addopts runs every test" py_cache_cleared
  check "python-uv-single: make test ignores a stale .coverage under --cov-append and leaves it alone" \
    py_stale_coverage stale-coverage .coverage 's/^addopts = "/addopts = "--cov-append /'
  # shellcheck disable=SC2016 # sed's own $ addresses the last line
  check "python-uv-single: make test ignores a stale file named by a data_file setting and leaves it alone" \
    py_stale_coverage stale-data-file .stale-coverage \
    '$s/$/\n\n[tool.coverage.run]\ndata_file = ".stale-coverage"/; s/^addopts = "/addopts = "--cov-append /'
  check "python-uv-single: -p no:cacheprovider in addopts still passes make test" py_no_cacheprovider
  check "python-uv-single: UV_PROJECT or UV_WORKING_DIR naming a synced project does not hide drift from make test" py_redirected
  check "python-uv-workspace: make test ONLY=packages/app tests app alone" py_only_app
  check "python-uv-workspace: make lint ONLY=packages/app skips core's ruff passes" py_only_lint "$quotes"
  check "python-uv-workspace: JUNIT_DIR=reports writes one report per member into the project" py_junit
  check "python-uv-single: a vulnerable dependency fails make audit" py_vulnerable
  check "python-uv-single: a dependency with an OSV-only advisory fails make audit" py_osv_only
  check "python-uv-single: make audit passes on current dependencies, leaving a path one out" py_audited
  check "python-uv-single: a dependency only win32 installs is audited, failing make audit on its advisory" py_marker_false
  check "python-uv-single: make audit passes when every runtime dependency is one only win32 installs" py_marker_only
  check "python-uv-single: make audit passes a name locked at two versions, one per platform" py_forked
}

python_part() {
  prepare
  publish
  isolated python_checks # it sets an environment; check counts failures there
}

shared_uv_copy() { # shared_uv_copy LOG COPY...: exactly one COPY exists, and LOG shows no uv install
  local log=$1
  shift
  [[ $# == 1 && -d $1 ]] && ! grep -q "Installing uv" "$log"
}

uv_sandbox() {
  # User-level uv configuration (XDG_CONFIG_HOME), the caches (XDG_CACHE_HOME, PIP_CACHE_DIR: pip
  # ignores XDG_CACHE_HOME on macOS) and uv's Python downloads stay in $work, and pip reads no
  # configuration file. The first make install bootstraps uv, whatever uv is on PATH; later ones
  # find its copy in the cache.
  # shellcheck disable=SC2046 # one argument per variable name
  unset VIRTUAL_ENV PYTHONPATH $(compgen -e | grep -E '^(UV|PIP)_')
  export XDG_CONFIG_HOME=$work/config UV_PYTHON_INSTALL_DIR=$work/uv-python npm_config_cache=$work/npm-cache \
    PIP_CONFIG_FILE=/dev/null PIP_CACHE_DIR=$work/pip-cache
}

python_checks() {
  local fixtures=("$root"/tests/fixtures/python-*/) first pin uv fixture copies
  first=${fixtures[0]%/}
  pin=$(PROJECT_ROOT=$first python3 "$root/scripts/python/uv_project.py" uv-version)
  uv_sandbox
  for fixture in "${fixtures[@]}"; do
    fixture=${fixture%/}
    run_fixture "$fixture" "install check lint test format"
    check "${fixture##*/}: make audit has nothing to audit" \
      make_says pass "$work/${fixture##*/}" audit "nothing to audit"
    check "${fixture##*/}: ruff's walk skips the .devkit link" ruff_skips_devkit "$work/${fixture##*/}"
    unchanged "$fixture" .venv __pycache__ .pytest_cache .ruff_cache .coverage
  done
  check "${first##*/}: the first make install bootstraps uv" grep -q "Installing uv $pin" "$work/${first##*/}.install.log"
  copies=("$XDG_CACHE_HOME/devkit/tools/uv-$pin-"*)
  check "the fixtures, locking the same uv by the same hashes, share one copy" \
    shared_uv_copy "$work/$(basename "${fixtures[1]}").install.log" "${copies[@]}"
  uv=${copies[0]}/bin/uv # it locks the copies too
  python_negatives
}

floor_uv() { # the uv the python-uv-single fixture's uv.lock pins, bootstrapped as make install does; its path in $work/uv-cmd
  (
    cd "$root/tests/fixtures/python-uv-single"
    export DEVKIT=$root PROJECT_ROOT=$PWD UV_BOOTSTRAP=true
    # shellcheck source=SCRIPTDIR/../scripts/lib/get_uv.sh
    . "$root/scripts/lib/get_uv.sh"
    echo "$UV_CMD" >"$work/uv-cmd"
  )
}

floor_venv() { # floor_venv VERSION DIR: a CPython VERSION venv at DIR, whose python3 reports VERSION; fails when either check does
  local version=$1 dir=$2 before=$fails
  # shellcheck disable=SC2031 # floor_checks sets UV_CMD from $work/uv-cmd; floor_uv sets its own in a subshell, by sourcing get_uv.sh
  # --no-config: $dir is under $work, and uv would read a uv.toml of a parent directory.
  check "floor: uv creates a CPython $version venv" "$UV_CMD" venv --no-config --quiet --python "$version" "$dir"
  ((fails == before)) || return 1
  check "floor: python3 on PATH is $version" \
    env PATH="$dir/bin:$PATH" python3 -I -c "import sys; sys.exit(sys.version_info[:2] != (${version/./, }))"
  ((fails == before))
}

compile_helpers() { # every Python helper compiles under the python3 on PATH, writing no bytecode
  python3 -I -c 'import sys; [compile(open(f, "rb").read(), f, "exec") for f in sys.argv[1:]]' "$root"/scripts/**/*.py
}

floor_newest_stable() { # the pinned uv offers no stable CPython minor newer than $newest_python
  # shellcheck disable=SC2031 # as in floor_venv
  "$UV_CMD" python list --only-downloads --no-config --output-format json | python3 -I -c '
import json, re, sys
want = tuple(map(int, sys.argv[1].split(".")))
stable = {(v["version_parts"]["major"], v["version_parts"]["minor"]): v["version"]
          for v in json.load(sys.stdin)
          if v["implementation"] == "cpython" and re.fullmatch(r"\d+\.\d+\.\d+", v["version"])}
if want not in stable:
    sys.exit(f"the pinned uv lists no stable CPython {sys.argv[1]}; newest_python in tests/run.sh is stale")
newer = sorted(m for m in stable if m > want)
if newer:
    sys.exit(f"the pinned uv offers stable CPython {newer[-1][0]}.{newer[-1][1]}: raise newest_python in tests/run.sh")
' "$newest_python"
}

# Never falls back to the system python3: a venv that cannot be built skips its tests.
floor_checks() {
  local before=$fails
  uv_sandbox
  export PYTHONDONTWRITEBYTECODE=1 # the tests run python3 without -B; nothing is written into the tree
  check "floor: the pinned uv is installed" floor_uv
  ((fails == before)) || return 0
  UV_CMD=$(<"$work/uv-cmd")
  cd "$work"
  check "floor: the pinned uv offers no stable CPython newer than $newest_python" floor_newest_stable
  if floor_venv 3.11 "$work/floor-venv"; then
    PATH=$work/floor-venv/bin:$PATH label_prefix='python3 3.11: ' check "scripts/**/*.py compile" compile_helpers
    PATH=$work/floor-venv/bin:$PATH label_prefix='python3 3.11: ' shell_tests
  fi
  if floor_venv "$newest_python" "$work/newest-venv"; then
    PATH=$work/newest-venv/bin:$PATH label_prefix="python3 $newest_python: " check "scripts/**/*.py compile" compile_helpers
    PATH=$work/newest-venv/bin:$PATH label_prefix="python3 $newest_python: " shell_tests
  fi
}

floor_part() {
  prepare
  isolated floor_checks
}

[[ $# -gt 0 ]] || set -- shell java python floor
seen=' '
for part in "$@"; do
  [[ $part =~ ^(shell|floor|java|python)$ && $seen != *" $part "* ]] || {
    echo "usage: tests/run.sh [shell] [java] [python] [floor], each part at most once" >&2
    exit 2
  }
  seen+="$part "
done
# A fixed order, whatever the command line's: floor must follow python, whose first make install
# must find no uv in the shared cache to show that it bootstraps one.
for part in shell java python floor; do [[ $seen != *" $part "* ]] || "${part}_part"; done
[[ $fails == 0 ]] || {
  echo "$fails check(s) failed"
  exit 1
}
