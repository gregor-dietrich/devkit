#!/usr/bin/env bash
# Hermetic tests for scripts/hooks.sh and the hooks it installs. Per case, a
# fresh clone of a local bare origin holding a stub project: devkit.toml with
# a pin, .devkit linking to it, and a Makefile whose lint-repo and test
# targets log to $HOOK_LOG, fail when FAIL names them, and test also runs the
# shell code in DURING. DEVKIT is this repository; git reads no user or system
# config. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Physical: hooks.sh reports resolved paths, and macOS's TMPDIR is under the
# /var -> /private/var symlink. Two steps: inside a substitution a failed
# mktemp would leave `cd ""`, which bash 3.2 accepts, and the trap would remove
# the caller's directory.
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars) CI FAIL GIT_CEILING_DIRECTORIES
# What the hooks and make gate react to: an ambient one would change the cases.
unset ONLY MAVEN_ARGS MAVEN_OPTS MAVEN_DEBUG_OPTS MAVEN_BASEDIR JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS OPENJ9_JAVA_OPTIONS IBM_JAVA_OPTIONS PYTEST_ADDOPTS PYTEST_PLUGINS COVERAGE_RCFILE COVERAGE_FORCE_CONFIG PYTHONOPTIMIZE MAVEN_SKIP_RC \
  X Y D SEL NOPE F d p r MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKEFILES
export HOME=$work/home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
export DEVKIT=$root HOOK_LOG=$work/hook.log LC_ALL=C
mkdir -p "$HOME"
managed="pre-commit pre-push post-checkout post-merge post-rewrite"
stamp="# devkit:managed-hook"
pin=0123456789abcdef0123456789abcdef01234567
other=fedcba9876543210fedcba9876543210fedcba98
sentinel=$work/branch-code-ran

# The served project, once; each case clones a copy of its bare origin.
src=$work/src
git init -q -b main "$src"
printf '[devkit]\nurl = "file:///nowhere"\nversion = "v9.9.9"\ncommit = "%s"\n' "$pin" >"$src/devkit.toml"
printf '/.devkit\n' >"$src/.gitignore"
printf '%s\n' '.PHONY: lint-repo test' 'lint-repo test:' \
  $'\t@echo "$@ index=$${GIT_INDEX_FILE-unset} dir=$${GIT_DIR-unset}" >>"$$HOOK_LOG"' \
  $'\t@[ "$${FAIL-}" != "$@" ] || { echo "INTENDED $@ FAILURE"; exit 23; }' \
  $'\t@[ "$@" != test ] || eval "$${DURING-}"' >"$src/Makefile"
echo one >"$src/file"
git -C "$src" add -A
git -C "$src" commit -q -m one
git clone -q --bare "$src" "$work/origin-template.git"

fresh() { # a new origin and clone; sets clone, hooks
  rm -rf "$work/case"
  mkdir "$work/case"
  cp -R "$work/origin-template.git" "$work/case/origin.git"
  clone=$work/case/clone hooks=$work/case/clone/.git/hooks
  git clone -q "$work/case/origin.git" "$clone"
  ln -s "$work/cache/$pin" "$clone/.devkit"
  : >"$HOOK_LOG"
  rm -f "$sentinel"
}

run() { # run CMD...: in the clone; sets rc, out (stdout), err (stderr)
  rc=0
  out=$(cd "$clone" && "$@" 2>"$work/err") || rc=$?
  err=$(<"$work/err")
}
say() { # say CMD...: in the clone; sets rc, out (stdout and stderr, as git shows a hook's)
  rc=0 err=""
  out=$(cd "$clone" && "$@" 2>&1) || rc=$?
}
install() { run env PROJECT_ROOT="$clone" "$root/scripts/hooks.sh" install; }
status() { run env PROJECT_ROOT="$clone" "$root/scripts/hooks.sh" status; }
gate() { run env PROJECT_ROOT="$clone" "$@" "$root/scripts/gate.sh"; } # gate [VAR=value...]
g() { git -C "$clone" "$@"; }
logged() { [[ "$(<"$HOOK_LOG")" == "$1" ]]; }
quiet() { [[ $rc == 0 && -z $out && -z $err ]]; }
stamped() { [[ -x $1 && ! -L $1 ]] && grep -qxF "$stamp" "$1"; }
foreign() { # foreign HOOK: a hook of the user's own, which logs its stdin
  printf '#!/bin/sh\ncat >"%s"\n' "$work/$1.stdin" >"$hooks/$1"
  chmod +x "$hooks/$1"
}
fails=0
t() { # t NAME COMMAND...: report whether COMMAND succeeds
  local name=$1
  shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name (rc=$rc, stdout: $out, stderr: $err, log: $(<"$HOOK_LOG"))"
    fails=$((fails + 1))
  fi
}

# Installing.
case_install() {
  fresh
  install
  [[ $rc == 0 && -z $err && $out == *"Installed pre-commit hook."* ]] || return 1
  local hook
  for hook in $managed; do stamped "$hooks/$hook" || return 1; done
}
case_idempotent() {
  fresh
  install
  install
  [[ $rc == 0 && -z $err && $(grep -c 'already installed\.$' <<<"$out") == 5 &&
    $(wc -l <<<"$out") -eq 5 ]]
}
case_stale_refreshed() {
  fresh
  install
  echo '# local edit' >>"$hooks/pre-commit"
  chmod -x "$hooks/post-merge"
  install
  [[ $rc == 0 && -z $err && $out == *"Updated pre-commit hook"* &&
    $out == *"Updated post-merge hook"* ]] &&
    ! grep -q 'local edit' "$hooks/pre-commit" && stamped "$hooks/post-merge"
}
# shellcheck disable=SC2016 # the hook lines, literally
case_foreign_kept() { # and the lines it advises run the gate
  fresh
  foreign pre-commit
  foreign pre-push
  cp "$hooks/pre-commit" "$work/mine"
  install
  [[ $rc == 0 && -z $err ]] && cmp -s "$hooks/pre-commit" "$work/mine" &&
    stamped "$hooks/pre-commit.devkit" && stamped "$hooks/pre-push.devkit" || return 1
  [[ $out == *'           "$(dirname "$0")/pre-commit.devkit" "$@" || exit $?'* &&
    $out == *'           dk_refs=$(mktemp) || exit $?'* ]] || return 1
  local advised
  advised=$(sed -n 's/^           //p' <<<"$out")
  { echo '#!/bin/sh' && sed -n 1p <<<"$advised" && echo 'echo mine >"$HOOK_LOG.mine"'; } >"$hooks/pre-commit"
  { echo '#!/bin/sh' && sed -n 2,4p <<<"$advised" && sed 1d "$work/mine" |
    sed "s|pre-commit.stdin|pre-push.stdin|"; } >"$hooks/pre-push"
  install
  [[ $out == *"Hook pre-commit is not devkit's but already calls pre-commit.devkit"* &&
    $out == *"Hook pre-push is not devkit's but already calls pre-push.devkit"* ]] || return 1
  echo two >>"$clone/file"
  say env FAIL=lint-repo git commit -qam two
  [[ $rc != 0 && $(g rev-list --count HEAD) == 1 && ! -e $HOOK_LOG.mine ]] || return 1
  say git commit -qam two
  [[ $rc == 0 && -e $HOOK_LOG.mine ]] || return 1
  : >"$HOOK_LOG"
  say git push -q origin main
  [[ $rc == 0 && "$(<"$work/pre-push.stdin")" == "refs/heads/main $(g rev-parse HEAD) "* ]] &&
    logged $'lint-repo index=unset dir=unset\ntest index=unset dir=unset'
}
case_dangling_symlink() {
  fresh
  ln -s "$work/case/nowhere/hook" "$hooks/pre-commit"
  install
  [[ $rc == 0 && -z $err && -L $hooks/pre-commit &&
    $(readlink "$hooks/pre-commit") == "$work/case/nowhere/hook" &&
    ! -e $work/case/nowhere ]] && stamped "$hooks/pre-commit.devkit"
}
case_orphan_removed() {
  fresh
  foreign pre-commit
  install
  rm "$hooks/pre-commit"
  install
  [[ $rc == 0 && -z $err && $out == *"Removed the orphaned pre-commit.devkit"* &&
    ! -e $hooks/pre-commit.devkit ]] && stamped "$hooks/pre-commit"
}
case_moved_aside_refreshed() { # by hook managers, to .legacy and .old
  fresh
  install
  mv "$hooks/pre-commit" "$hooks/pre-commit.legacy"
  mv "$hooks/pre-push" "$hooks/pre-push.old"
  echo '# older copy' >>"$hooks/pre-commit.legacy"
  foreign pre-commit
  foreign pre-push
  install
  [[ $rc == 0 && -z $err && $out == *"runs as pre-commit.legacy"* &&
    $out == *"it runs devkit's copy $hooks/pre-push.old"* &&
    ! -e $hooks/pre-commit.devkit && ! -e $hooks/pre-push.devkit ]] &&
    ! grep -q 'older copy' "$hooks/pre-commit.legacy" && stamped "$hooks/pre-commit.legacy"
}
refused() { # refused DIR: install refuses, says the remedy, creates nothing at DIR
  install
  [[ $rc == 1 && -z $out && $err == *"git config core.hooksPath \"$clone/.git/hooks\""* &&
    ! -e $1 && ! -e $hooks/pre-commit ]]
}
case_refuse_work_tree() {
  fresh
  g config core.hooksPath .githooks
  refused "$clone/.githooks"
}
case_refuse_outside() {
  fresh
  g config core.hooksPath "$work/case/shared-hooks"
  refused "$work/case/shared-hooks"
}
case_accept_git_dir() {
  fresh
  g config core.hooksPath "$clone/.git/custom-hooks"
  install
  [[ $rc == 0 && -z $err && ! -e $hooks/pre-commit ]] && stamped "$clone/.git/custom-hooks/pre-commit"
}
case_tilde() {
  fresh
  # shellcheck disable=SC2088 # git expands it, not the shell
  g config core.hooksPath '~/hooks'
  HOME=$clone/.git/home install
  [[ $rc == 0 && -z $err && ! -e "$clone/~" ]] && stamped "$clone/.git/home/hooks/pre-commit"
}
case_make_targets() { # common.mk's wiring
  fresh
  run make -s -f "$root/make/common.mk" hooks
  [[ $rc == 0 && -z $err ]] && stamped "$hooks/pre-push" || return 1
  run make -s -f "$root/make/common.mk" check-hooks
  quiet
}
case_shellcheck() { # the rendered hooks
  fresh
  install
  local hook
  for hook in $managed; do shellcheck "$hooks/$hook" || return 1; done
}

# Gates.
case_switch_runs_nothing() { # nor does a merge: a branch supplies every part
  fresh
  install
  g switch -q -c evil
  local dir
  rm "$clone/.devkit"
  for dir in scripts/hooks .devkit/scripts/hooks; do
    mkdir -p "$clone/$dir"
    for part in pre-commit pre-push pin-notice stale-base-notice; do
      printf '#!/bin/bash\ntouch "%s"\n' "$sentinel" >"$clone/$dir/$part.sh"
    done
  done
  printf '#!/bin/sh\ntouch "%s"\n' "$sentinel" >"$clone/devkitw"
  # shellcheck disable=SC2016 # a make function, for the Makefile
  printf '$(shell touch "%s")\n' "$sentinel" | cat - "$clone/Makefile" >"$work/Makefile"
  mv "$work/Makefile" "$clone/Makefile"
  sed -i.bak "s/$pin/$other/; s/v9.9.9/v6.6.6/" "$clone/devkit.toml"
  rm "$clone/devkit.toml.bak"
  g add -A
  g add -f .devkit
  g commit -q --no-verify -m evil
  say git switch -q main
  ln -s "$work/cache/$pin" "$clone/.devkit"
  say git switch evil
  [[ $rc == 0 && $out == *"NOTE: devkit.toml now pins devkit v6.6.6 (fedcba987654)"* ]] || return 1
  say git switch main
  say git merge --no-edit evil
  [[ $rc == 0 && $out == *"NOTE: devkit.toml now pins devkit v6.6.6"* && ! -e $sentinel ]]
}
case_pre_commit_blocks() {
  fresh
  install
  echo two >>"$clone/file"
  say env FAIL=lint-repo git commit -qam two
  [[ $rc != 0 && $out == *"INTENDED lint-repo FAILURE"* && $(g rev-list --count HEAD) == 1 ]] &&
    logged "lint-repo index=unset dir=unset"
}
case_pre_commit_outer_flags() { # a commit from inside make -i, or a MAKEFILES .IGNORE:, still fails
  fresh
  install
  echo two >>"$clone/file"
  echo .IGNORE: >"$work/ignore.mk"
  local flags
  for flags in MAKEFLAGS=i GNUMAKEFLAGS=-i MAKEFILES="$work/ignore.mk"; do
    say env FAIL=lint-repo "$flags" git commit -qam two
    [[ $rc != 0 && $out == *"INTENDED lint-repo FAILURE"* && $(g rev-list --count HEAD) == 1 ]] || return 1
  done
}
case_pre_commit_env() { # a partial commit, which hands the hook a temporary index
  fresh
  install
  echo two >>"$clone/file"
  say git commit -q -m two file
  [[ $rc == 0 && $out == "pre-commit: make lint-repo"* && $(g rev-list --count HEAD) == 2 ]] &&
    logged "lint-repo index=unset dir=unset"
}
case_no_verify() {
  fresh
  install
  echo two >>"$clone/file"
  say env FAIL=lint-repo git commit -q --no-verify -am two
  [[ $rc == 0 && $(g rev-list --count HEAD) == 2 ]] && logged ""
}
case_pre_push() {
  fresh
  install
  g commit -q --no-verify --allow-empty -m two
  say git push -q origin main
  [[ $rc == 0 && $out != *WARNING* && $(g rev-parse origin/main) == $(g rev-parse HEAD) ]] &&
    logged $'lint-repo index=unset dir=unset\ntest index=unset dir=unset' || return 1
  g commit -q --no-verify --allow-empty -m three
  say env FAIL=test git push -q origin main
  [[ $rc != 0 && $(g rev-parse origin/main) != $(g rev-parse HEAD) ]]
}
case_pre_push_warns() { # a ref that is not HEAD, a dirty tree
  fresh
  install
  g branch other
  g switch -q other
  g commit -q --no-verify --allow-empty -m other
  g switch -q main
  echo dirt >"$clone/untracked"
  say git push -q origin other
  [[ $rc == 0 && $out == *"WARNING: pushing refs/heads/other, which is not HEAD."* &&
    $out == *"WARNING: the work tree is dirty"* ]] && logged $'lint-repo index=unset dir=unset\ntest index=unset dir=unset'
}
case_pre_push_deletion() {
  fresh
  install
  g push -q --no-verify origin main:refs/heads/gone
  say git push -q origin :gone
  [[ $rc == 0 && $out == *"nothing but deletions"* ]] && logged "" &&
    ! g ls-remote --exit-code origin refs/heads/gone >/dev/null
}
case_pre_push_no_refs() { # installed as pre-push: nothing to push
  fresh
  install
  run "$hooks/pre-push" origin "$work/case/origin.git" </dev/null
  quiet && logged ""
}
case_pre_push_side_no_refs() { # called from a foreign hook: gate HEAD
  fresh
  foreign pre-push
  install
  run "$hooks/pre-push.devkit" origin "$work/case/origin.git" </dev/null
  [[ $rc == 0 && -z $err && $out == *"git sent no refs"* ]] &&
    logged $'lint-repo index=unset dir=unset\ntest index=unset dir=unset'
}
case_pre_push_only() { # ONLY left in the shell never narrows the push gate
  fresh
  install
  g commit -q --no-verify --allow-empty -m two
  # shellcheck disable=SC2016 # DURING is evaluated by the stage's recipe
  say env ONLY=x DURING='echo "only=${ONLY-unset}" >>"$HOOK_LOG"' git push -q origin main
  [[ $rc == 0 && $out == *"pre-push: ignoring ONLY (it is 'x'); the push gate is never narrowed"* ]] &&
    logged "$both"$'\nonly=unset'
}
case_pre_push_environment() { # variables that can skip or deselect tests: warn, still gate
  fresh
  install
  local spec var n=0 ok=0
  for spec in "MAVEN_ARGS=-q|MAVEN_ARGS is set (it can skip tests)." \
    "MAVEN_BASEDIR=/x|MAVEN_BASEDIR is set (it moves .mvn/ and the gate configurations, which can skip tests)." \
    "MAVEN_OPTS=-Dx=y|MAVEN_OPTS holds -D (it can skip tests)." \
    "MAVEN_DEBUG_OPTS=-version|MAVEN_DEBUG_OPTS is set (the launcher hands it to java, which can skip tests)." \
    "JAVA_TOOL_OPTIONS=-Dx=y|JAVA_TOOL_OPTIONS holds -D (it can skip tests)." \
    "JDK_JAVA_OPTIONS=-Dx=y|JDK_JAVA_OPTIONS holds -D (it can skip tests)." \
    "_JAVA_OPTIONS=-Dx=y|_JAVA_OPTIONS holds -D (it can skip tests)." \
    "OPENJ9_JAVA_OPTIONS=-Dx=y|OPENJ9_JAVA_OPTIONS holds -D (it can skip tests)." \
    "IBM_JAVA_OPTIONS=-Dx=y|IBM_JAVA_OPTIONS holds -D (it can skip tests)." \
    "MAVEN_OPTS=@file|MAVEN_OPTS holds @argfile (it can skip tests)." \
    "JDK_JAVA_OPTIONS=\"@file\"|JDK_JAVA_OPTIONS holds @argfile (it can skip tests)." \
    "JDK_JAVA_OPTIONS=--list-modules|JDK_JAVA_OPTIONS holds --list-modules (it can skip tests)." \
    "JAVA_TOOL_OPTIONS=-XX:VMOptionsFile=x|JAVA_TOOL_OPTIONS holds -XX:VMOptionsFile (it can skip tests)." \
    "_JAVA_OPTIONS=-XX:Flags=x|_JAVA_OPTIONS holds -XX:Flags (it can skip tests)." \
    "MAVEN_OPTS=-version|MAVEN_OPTS holds -version (it can skip tests)." \
    "MAVEN_OPTS=-Xmx1g --dry-run|MAVEN_OPTS holds --dry-run (it can skip tests)." \
    "MAVEN_OPTS=-Xshare:dump|MAVEN_OPTS holds -Xshare:dump (it can skip tests)." \
    "MAVEN_OPTS=-XX:AOTMode=create|MAVEN_OPTS holds -XX:AOTMode=create (it can skip tests)." \
    "MAVEN_OPTS=--module=x/y|MAVEN_OPTS holds --module (it can skip tests)." \
    "MAVEN_OPTS=-?|MAVEN_OPTS holds -? (it can skip tests)." \
    "MAVEN_OPTS=-fullversion|MAVEN_OPTS holds -fullversion (it can skip tests)." \
    "MAVEN_OPTS=--full-version|MAVEN_OPTS holds --full-version (it can skip tests)." \
    "MAVEN_OPTS=-Xinternalversion|MAVEN_OPTS holds -Xinternalversion (it can skip tests)." \
    "MAVEN_OPTS=-XX:+PrintFlagsInitial|MAVEN_OPTS holds -XX:+PrintFlagsInitial (it can skip tests)." \
    "JAVA_TOOL_OPTIONS=-XX:+PrintSharedArchiveAndExit|JAVA_TOOL_OPTIONS holds -XX:+PrintSharedArchiveAndExit (it can skip tests)." \
    "MAVEN_OPTS=-Xoptionsfile=x|MAVEN_OPTS holds -Xoptionsfile (it can skip tests)." \
    "JAVA_TOOL_OPTIONS=-\"D\"x=y|JAVA_TOOL_OPTIONS holds -D (it can skip tests)." \
    "JAVA_TOOL_OPTIONS=-XX:AOTMode=\"create\"|JAVA_TOOL_OPTIONS holds -XX:AOTMode=create (it can skip tests)." \
    "JDK_JAVA_OPTIONS='-version'|JDK_JAVA_OPTIONS holds -version (it can skip tests)." \
    "MAVEN_OPTS=$(printf -- '-Xmx1g\t-version')|MAVEN_OPTS holds -version (it can skip tests)." \
    "MAVEN_OPTS=--version|MAVEN_OPTS holds --version (it can skip tests)." \
    "MAVEN_OPTS=-help|MAVEN_OPTS holds -help (it can skip tests)." \
    "MAVEN_OPTS=--help|MAVEN_OPTS holds --help (it can skip tests)." \
    "MAVEN_OPTS=-h|MAVEN_OPTS holds -h (it can skip tests)." \
    "MAVEN_OPTS=-X|MAVEN_OPTS holds -X (it can skip tests)." \
    "MAVEN_OPTS=--help-extra|MAVEN_OPTS holds --help-extra (it can skip tests)." \
    "MAVEN_OPTS=-d|MAVEN_OPTS holds -d (it can skip tests)." \
    "MAVEN_OPTS=--describe-module|MAVEN_OPTS holds --describe-module (it can skip tests)." \
    "MAVEN_OPTS=--validate-modules|MAVEN_OPTS holds --validate-modules (it can skip tests)." \
    "MAVEN_OPTS=-jar|MAVEN_OPTS holds -jar (it can skip tests)." \
    "MAVEN_OPTS=-m|MAVEN_OPTS holds -m (it can skip tests)." \
    "MAVEN_OPTS=--module|MAVEN_OPTS holds --module (it can skip tests)." \
    "MAVEN_OPTS=-XX:+JVMCIPrintProperties|MAVEN_OPTS holds -XX:+JVMCIPrintProperties (it can skip tests)." \
    "MAVEN_OPTS=-javaagent:/x.jar|MAVEN_OPTS holds -javaagent (it can skip tests)." \
    "JDK_JAVA_OPTIONS=-agentpath:/x.so|JDK_JAVA_OPTIONS holds -agentpath (it can skip tests)." \
    "MAVEN_OPTS=-agentlib:jdwp=transport=dt_socket|MAVEN_OPTS holds -agentlib (it can skip tests)." \
    "JAVA_TOOL_OPTIONS=-Xrunjdwp:transport=dt_socket|JAVA_TOOL_OPTIONS holds -Xrun (it can skip tests)." \
    "MAVEN_OPTS=-Xlog:help|MAVEN_OPTS holds -Xlog:help (it can skip tests)." \
    "MAVEN_OPTS=-XX:StartFlightRecording:help|MAVEN_OPTS holds -XX:StartFlightRecording:help (it can skip tests)." \
    "JAVA_TOOL_OPTIONS=-Xmx1g -XX:StartFlightRecording=help|JAVA_TOOL_OPTIONS holds -XX:StartFlightRecording=help (it can skip tests)." \
    "MAVEN_OPTS=-Dfoo=help|MAVEN_OPTS holds -D (it can skip tests)." \
    "PYTEST_ADDOPTS=-k x|PYTEST_ADDOPTS is set (it can deselect tests)." \
    "PYTEST_PLUGINS=x|PYTEST_PLUGINS is set (it can deselect tests)." \
    "COVERAGE_RCFILE=x|COVERAGE_RCFILE is set (it can skew coverage)." \
    "COVERAGE_FORCE_CONFIG=x|COVERAGE_FORCE_CONFIG is set (it can skew coverage)." \
    "PYTHONOPTIMIZE=1|PYTHONOPTIMIZE is set (it can strip asserts)."; do
    n=$((n + 1))
    var=${spec%%|*}
    g commit -q --no-verify --allow-empty -m "env$n"
    : >"$HOOK_LOG"
    say env "$var" git push -q origin main
    [[ $rc == 0 && $out == *"WARNING: ${spec#*|}"* ]] && logged "$both" || return 1
  done
  g commit -q --no-verify --allow-empty -m ignoredmvn
  : >"$HOOK_LOG"
  mkdir -p "$clone/.mvn"
  echo -DskipTests >"$clone/.mvn/maven.config"
  echo .mvn/maven.config >>"$clone/.git/info/exclude"
  say git push -q origin main
  [[ $rc == 0 && $out == *"WARNING: git ignores .mvn/ files Maven reads: .mvn/maven.config (they can skip tests)."* ]] && logged "$both" || return 1
  g commit -q --no-verify --allow-empty -m ignoredext
  : >"$HOOK_LOG"
  echo '<extensions/>' >"$clone/.mvn/extensions.xml"
  echo .mvn/extensions.xml >>"$clone/.git/info/exclude"
  say git push -q origin main
  [[ $rc == 0 && $out == *"WARNING: git ignores .mvn/ files Maven reads: .mvn/extensions.xml, .mvn/maven.config (they can skip tests)."* ]] && logged "$both" || return 1
  rm "$clone/.mvn/maven.config" "$clone/.mvn/extensions.xml"
  g commit -q --no-verify --allow-empty -m last
  : >"$HOOK_LOG"
  say env MAVEN_OPTS=-Xmx1g git push -q origin main # no -D: no warning
  [[ $rc == 0 ]] && { unwarned || [[ $out != *WARNING* ]]; } && logged "$both" || return 1
  g commit -q --no-verify --allow-empty -m negated
  : >"$HOOK_LOG"
  say env JAVA_TOOL_OPTIONS=-XX:-DisableExplicitGC git push -q origin main # -D inside a word
  [[ $rc == 0 ]] && { unwarned || [[ $out != *WARNING* ]]; } && logged "$both" || return 1
  g commit -q --no-verify --allow-empty -m notterminal
  : >"$HOOK_LOG"
  say env MAVEN_OPTS='-Xmx1g -Xss1m -Xshare:auto -XX:AOTMode=auto --module-path=x -showversion -da -XX:-DisableExplicitGC -XX:+PrintFlagsFinal -XshowSettings:all -Xlog:gc -verbose:gc --add-opens=java.base/java.lang=ALL-UNNAMED -ea' git push -q origin main # none ends java, reads a file or loads code
  [[ $rc == 0 ]] && { unwarned || [[ $out != *WARNING* ]]; } && logged "$both" || return 1
  g commit -q --no-verify --allow-empty -m quoted
  : >"$HOOK_LOG"
  say env JAVA_TOOL_OPTIONS='-Xmx1g "-Dx=a b"' git push -q origin main
  [[ $rc == 0 && $out == *"WARNING: JAVA_TOOL_OPTIONS holds -D"* ]] && logged "$both" || return 1
  g commit -q --no-verify --allow-empty -m badbyte
  : >"$HOOK_LOG"
  # An invalid byte under a UTF-8 locale must not make the match fail open.
  say env LC_ALL=C.UTF-8 MAVEN_OPTS=$'\xe9 -version' git push -q origin main
  [[ $rc == 0 && $out == *"WARNING: MAVEN_OPTS holds -version (it can skip tests)."* ]] && logged "$both" || return 1
  g commit -q --no-verify --allow-empty -m rc
  : >"$HOOK_LOG"
  echo 'MAVEN_OPTS=-DskipTests' >"$HOME/.mavenrc"
  say git push -q origin main
  ok=0
  [[ $rc == 0 && $out == *"WARNING: $HOME/.mavenrc exists, and Maven runs it (it can skip tests)."* ]] && logged "$both" || ok=1
  rm -f "$HOME/.mavenrc"
  [[ $ok == 0 ]] || return 1
  g commit -q --no-verify --allow-empty -m skiprc
  : >"$HOOK_LOG"
  echo 'MAVEN_OPTS=-DskipTests' >"$HOME/.mavenrc"
  say env MAVEN_SKIP_RC=1 git push -q origin main # no rc-file warning at all
  [[ $rc == 0 && $out != *"mavenrc"* ]] && logged "$both" || ok=1
  rm -f "$HOME/.mavenrc"
  [[ $ok == 0 ]] || return 1
  g commit -q --no-verify --allow-empty -m props
  : >"$HOOK_LOG"
  settings_xml props
  say git push -q origin main
  [[ $rc == 0 && $out == *"WARNING: $HOME/.m2/settings.xml sets profile properties (they can skip tests)."* ]] && logged "$both" || ok=1
  rm -f "$HOME/.m2/settings.xml"
  [[ $ok == 0 ]] || return 1
  g commit -q --no-verify --allow-empty -m benign
  : >"$HOOK_LOG"
  settings_xml benign
  say git push -q origin main # a mirror, and properties only in a comment
  [[ $rc == 0 && $out != *"settings.xml"* ]] && logged "$both" || ok=1
  rm -f "$HOME/.m2/settings.xml"
  [[ $ok == 0 ]] || return 1
  g commit -q --no-verify --allow-empty -m extensions
  : >"$HOOK_LOG"
  mkdir -p "$HOME/.m2"
  : >"$HOME/.m2/extensions.xml" # any content; MAVEN_SKIP_RC does not matter
  say env MAVEN_SKIP_RC=1 git push -q origin main
  [[ $rc == 0 && $out == *"WARNING: $HOME/.m2/extensions.xml exists, and Maven loads its core extensions (they can skip tests)."* ]] && logged "$both" || ok=1
  rm -f "$HOME/.m2/extensions.xml"
  [[ $ok == 0 ]]
}
case_pre_push_home_files() { # settings.xml activeProfiles, a directory at extensions.xml, ignored .mvn/ files
  fresh
  install
  local spec n=0 kind want text="WARNING: $HOME/.m2/settings.xml activates a profile it does not define (a project profile can skip tests)."
  for spec in act_none:warn act_own:quiet act_comment:quiet act_mixed:warn act_ws:quiet; do
    n=$((n + 1))
    kind=${spec%:*} want=${spec#*:}
    g commit -q --no-verify --allow-empty -m "act$n"
    : >"$HOOK_LOG"
    settings_xml "$kind"
    say git push -q origin main
    rm -f "$HOME/.m2/settings.xml"
    [[ $rc == 0 ]] && logged "$both" || return 1
    if [[ $want == warn ]]; then [[ $out == *"$text"* ]] || return 1; else [[ $out != *"activates a profile"* ]] || return 1; fi
  done
  g commit -q --no-verify --allow-empty -m extdir
  : >"$HOOK_LOG"
  mkdir -p "$HOME/.m2/extensions.xml" # Maven loads only a regular file
  say env MAVEN_SKIP_RC=1 git push -q origin main
  rmdir "$HOME/.m2/extensions.xml"
  [[ $rc == 0 && $out != *"extensions.xml"* ]] && logged "$both" || return 1
  local ex=$clone/.git/info/exclude pre="WARNING: git ignores .mvn/ files Maven reads:" post="(they can skip tests)."
  mkdir -p "$clone/.mvn/wrapper"
  g commit -q --no-verify --allow-empty -m jvmconfig
  : >"$HOOK_LOG"
  echo -Xmx1g >"$clone/.mvn/jvm.config"
  echo .mvn/jvm.config >"$ex"
  say git push -q origin main
  [[ $rc == 0 && $out == *"$pre .mvn/jvm.config $post"* ]] && logged "$both" || return 1
  g commit -q --no-verify --allow-empty -m mvndir
  : >"$HOOK_LOG"
  echo x >"$clone/.mvn/maven.config"
  echo .mvn/ >"$ex"
  say git push -q origin main
  [[ $rc == 0 && $out == *"$pre .mvn/jvm.config, .mvn/maven.config $post"* ]] && logged "$both" || return 1
  g commit -q --no-verify --allow-empty -m wrapper
  : >"$HOOK_LOG"
  rm "$clone/.mvn/jvm.config" "$clone/.mvn/maven.config"
  echo jar >"$clone/.mvn/wrapper/maven-wrapper.jar"
  echo .mvn/wrapper/ >"$ex"
  say git push -q origin main # Maven does not read .mvn/wrapper/
  [[ $rc == 0 && $out != *".mvn/"* ]] && logged "$both"
}
case_pre_push_outer_flags() { # a push from inside make -i, or a MAKEFILES .IGNORE:, still fails
  fresh
  install
  g commit -q --no-verify --allow-empty -m two
  local before
  before=$(g rev-parse origin/main)
  say env FAIL=test MAKEFLAGS=i git push -q origin main
  [[ $rc != 0 && $out == *"INTENDED test FAILURE"* && $(g rev-parse origin/main) == "$before" ]] || return 1
  echo .IGNORE: >"$work/ignore.mk"
  say env FAIL=test MAKEFILES="$work/ignore.mk" git push -q origin main
  [[ $rc != 0 && $out == *"INTENDED test FAILURE"* && $(g rev-parse origin/main) == "$before" ]] || return 1
  say env FAIL=test GNUMAKEFLAGS=-i git push -q origin main # read by GNU make 4
  [[ $rc != 0 && $out == *"INTENDED test FAILURE"* && $(g rev-parse origin/main) == "$before" ]]
}
case_part_status() { # a failing gate part ends the hook; a failing notice never does
  fresh
  local fake=$work/case/devkit
  mkdir -p "$fake/scripts/hooks"
  cp "$root"/scripts/hooks/*.sh "$fake/scripts/hooks/"
  printf '#!/bin/bash\nexit 7\n' >"$fake/scripts/hooks/pre-commit.sh"
  printf '#!/bin/bash\nexit 9\n' >"$fake/scripts/hooks/pin-notice.sh"
  printf '#!/bin/bash\ntouch "%s"\n' "$sentinel" >"$fake/scripts/hooks/stale-base-notice.sh"
  DEVKIT=$fake install
  run "$hooks/pre-commit"
  [[ $rc == 7 ]] || return 1
  run "$hooks/post-checkout" "$pin" "$pin" 1
  quiet && [[ -e $sentinel ]]
}
case_outside_project() { # a copy in a tree that is no devkit project does nothing
  fresh
  install
  rm "$clone/devkit.toml"
  echo two >>"$clone/file"
  say env FAIL=lint-repo git commit -qam two
  [[ $rc == 0 && -z $out ]] && logged ""
}

# Notices.
case_pin_mismatch() {
  fresh
  install
  rm "$clone/.devkit"
  say git switch -c b1
  [[ $rc == 0 && $out == *"NOTE: devkit.toml now pins devkit v9.9.9 (0123456789ab), but .devkit points at nothing; run 'make check'"* ]] || return 1
  ln -s "$work/cache/$other" "$clone/.devkit"
  say git switch main
  [[ $rc == 0 && $out == *"but .devkit points at fedcba987654;"* ]] || return 1
  say git commit -q --no-verify --amend --allow-empty -m amended # post-rewrite
  [[ $rc == 0 && $out == *"NOTE: devkit.toml now pins"* ]]
}
case_pin_silent() { # matched; and on a file checkout
  fresh
  install
  say git switch -q -c b1
  [[ $rc == 0 && -z $out ]] || return 1
  rm "$clone/.devkit"
  echo two >>"$clone/file"
  say git checkout -- file
  [[ $rc == 0 && -z $out ]]
}
case_pin_symlinked_toml() {
  fresh
  install
  rm "$clone/.devkit"
  mv "$clone/devkit.toml" "$clone/real.toml"
  ln -s real.toml "$clone/devkit.toml"
  say git switch -q -c b1
  [[ $rc == 0 && -z $out ]]
}
behind() { # origin/main one commit ahead of main, freshly fetched
  git clone -q "$work/case/origin.git" "$work/case/other"
  git -C "$work/case/other" commit -q --allow-empty -m newer
  git -C "$work/case/other" push -q origin main
  g fetch -q
}
case_stale_base() {
  fresh
  install
  behind
  say git switch -c feature
  [[ $rc == 0 && $out == *"WARNING: feature does not contain origin/main"* &&
    $out == *"rebase it: git rebase origin/main."* && $out != *"minutes ago"* ]] || return 1
  say git switch main
  [[ $rc == 0 && $out == *"WARNING: main does not contain origin/main"* &&
    $out == *"git pull --ff-only"* ]]
}
case_stale_base_silent() { # on a current base, and on a detached HEAD
  fresh
  install
  say git switch -q -c feature
  [[ $rc == 0 && -z $out ]] || return 1
  behind
  say git switch -q --detach main
  [[ $rc == 0 && -z $out ]] || return 1
  say git switch -c current origin/main
  [[ $rc == 0 && $out != *WARNING* ]]
}
case_stale_base_origin_head() {
  fresh
  install
  g update-ref refs/remotes/origin/trunk "$(g commit-tree 'HEAD^{tree}' -p HEAD -m newer)"
  g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  g update-ref -d refs/remotes/origin/main
  say git switch -c feature
  [[ $rc == 0 && $out == *"WARNING: feature does not contain origin/trunk"* &&
    $out == *"git rebase origin/trunk."* ]]
}
case_stale_fetch() {
  fresh
  install
  find "$clone/.git/logs/refs/remotes" -type f -exec touch -t 200001010000 {} +
  say git switch -c feature
  [[ $rc == 0 && $out == *"WARNING: origin/main was last fetched more than 60 minutes ago"* &&
    $out != *"does not contain"* ]] || return 1
  rm -rf "$clone/.git/logs/refs/remotes"
  say git switch main
  [[ $rc == 0 && $out == *"WARNING: origin/main has never been fetched here"* ]]
}

# The advisory behind make check.
case_status_missing() {
  fresh
  status
  [[ $rc == 0 && -z $err && $out == "NOTE: the git hooks $managed are not installed"*"run 'make hooks'"* &&
    $out != *$'\n'* ]]
}
case_status_stale() {
  fresh
  install
  echo '# local edit' >>"$hooks/post-merge"
  chmod -x "$hooks/pre-commit"
  status
  [[ $rc == 0 && -z $err && $out == *"WARNING: the installed git hooks post-merge differ"* &&
    $out == *"WARNING: the installed git hooks pre-commit are not executable"* ]]
}
case_status_silent() {
  fresh
  install
  status
  quiet
}
case_status_foreign() {
  fresh
  foreign pre-commit
  install
  status
  quiet || return 1
  echo '# local edit' >>"$hooks/pre-commit.devkit"
  status
  [[ $rc == 0 && $out == *"hooks pre-commit.devkit differ"* ]]
}
case_status_ci() {
  fresh
  CI=true status
  quiet
}
case_status_no_work_tree() {
  fresh
  mkdir "$work/case/plain"
  rc=0
  out=$(cd "$work/case/plain" && GIT_CEILING_DIRECTORIES=$work PROJECT_ROOT=$work/case/plain \
    "$root/scripts/hooks.sh" status 2>"$work/err") || rc=$?
  err=$(<"$work/err")
  quiet
}

# Review hardening: symlinks, path tricks, layouts install refuses.
regular_copy() { [[ -f $1 && ! -L $1 ]] && stamped "$1"; }
case_symlink_tracked() { # an equal-content symlink to a tracked file
  fresh
  install
  cp "$hooks/pre-commit" "$clone/tracked-hook"
  g add tracked-hook
  g commit -q --no-verify -m tracked
  cp "$clone/tracked-hook" "$work/case/before"
  ln -sf "$clone/tracked-hook" "$hooks/pre-commit"
  status
  [[ $rc == 0 && $out == *"hooks pre-commit differ"* ]] || return 1
  install
  [[ $rc == 0 && -z $err && $out == *"Updated pre-commit hook"* ]] && regular_copy "$hooks/pre-commit" &&
    cmp -s "$clone/tracked-hook" "$work/case/before" && [[ -z $(g status --porcelain) ]]
}
case_symlink_side() { # a symlinked pre-commit.devkit beside a foreign hook
  fresh
  foreign pre-commit
  install
  mv "$hooks/pre-commit.devkit" "$work/case/outside"
  cp "$work/case/outside" "$work/case/before"
  ln -s "$work/case/outside" "$hooks/pre-commit.devkit"
  status
  [[ $rc == 0 && $out == *"hooks pre-commit.devkit differ"* ]] || return 1
  install
  [[ $rc == 0 && -z $err && $out == *"Updated the pre-commit copy beside"* ]] &&
    regular_copy "$hooks/pre-commit.devkit" && cmp -s "$work/case/outside" "$work/case/before"
}
case_symlink_ours_outside() { # an "ours" pre-commit symlink to an outside file
  fresh
  install
  mv "$hooks/pre-commit" "$work/case/outside"
  cp "$work/case/outside" "$work/case/before"
  ln -s "$work/case/outside" "$hooks/pre-commit"
  mv "$hooks/pre-push" "$hooks/pre-push.legacy"
  foreign pre-push
  mv "$hooks/pre-push.legacy" "$work/case/outside-legacy"
  ln -s "$work/case/outside-legacy" "$hooks/pre-push.legacy"
  status
  [[ $rc == 0 && $out == *"hooks pre-commit pre-push.legacy differ"* ]] || return 1
  install
  [[ $rc == 0 && -z $err ]] && regular_copy "$hooks/pre-commit" &&
    regular_copy "$hooks/pre-push.legacy" && cmp -s "$work/case/outside" "$work/case/before"
}
case_refuse_dotdot() { # .git/x/../../githooks only looks inside .git
  fresh
  g config core.hooksPath .git/x/../../githooks
  refused "$clone/githooks" && [[ ! -e $clone/.git/x ]]
}
case_hooks_dir_symlink() { # .git/hooks leading into the work tree, or outside
  fresh
  local dir
  for dir in "$clone/githooks" "$work/case/shared"; do
    rm -rf "$hooks"
    mkdir -p "$dir"
    ln -s "$dir" "$hooks"
    install
    [[ $rc == 1 && -z $out && $err == *"git config core.hooksPath \"$clone/.git/hooks\""* &&
      -z $(ls -A "$dir") ]] || return 1
    status
    [[ $rc == 0 && -z $err && $out == "NOTE: core.hooksPath sends this clone's hooks to $dir, outside its git directory"* &&
      $out != *$'\n'* ]] || return 1
  done
}
case_below_top() { # a project in a subdirectory of the repository
  fresh
  mkdir "$clone/sub"
  run env PROJECT_ROOT="$clone/sub" "$root/scripts/hooks.sh" install
  [[ $rc == 1 && -z $out && ! -e $hooks/pre-commit &&
    $err == "ERROR: make hooks needs the project at the git top level ($clone); hooks there would do nothing." ]] || return 1
  run env PROJECT_ROOT="$clone/sub" "$root/scripts/hooks.sh" status
  [[ $rc == 0 && -z $err && $out == "NOTE: this project is below the git top level ($clone)"* && $out != *$'\n'* ]]
}
case_worktree() { # make hooks from a linked worktree: the common hooks dir
  fresh
  g worktree add -q "$work/case/wt"
  run make -s -C "$work/case/wt" -f "$root/make/common.mk" hooks
  [[ $rc == 0 && -z $err && ! -e $work/case/wt/.git/hooks ]] && stamped "$hooks/pre-commit"
}
case_make_n_check() { # make check runs the advisory
  fresh
  run make -n -f "$root/make/common.mk" check
  [[ $rc == 0 && $out == *"\"$root/scripts/hooks.sh\" status"* ]]
}
case_pre_push_env() { # run with git's pointers set, as git runs it
  fresh
  install
  run env GIT_DIR="$clone/.git" GIT_INDEX_FILE="$clone/.git/index" "$hooks/pre-push" origin \
    "$work/case/origin.git" <<<"refs/heads/main $(g rev-parse HEAD) refs/heads/main $(printf '0%.0s' {1..40})"
  [[ $rc == 0 && -z $err && $out != *WARNING* ]] &&
    logged $'lint-repo index=unset dir=unset\ntest index=unset dir=unset'
}
case_status_outside() { # one line, not a NOTE per hook
  fresh
  g config core.hooksPath "$work/case/shared"
  status
  [[ $rc == 0 && -z $err && $out == "NOTE: core.hooksPath sends this clone's hooks to $work/case/shared, outside its git directory, so devkit's git hooks are not installed"* &&
    $out != *$'\n'* ]]
}
case_side_refused() { # a pre-commit.devkit install did not write
  fresh
  foreign pre-commit
  local kind
  for kind in dir file link; do
    rm -rf "$hooks/pre-commit.devkit"
    case $kind in
      dir) mkdir "$hooks/pre-commit.devkit" ;;
      file) echo mine >"$hooks/pre-commit.devkit" ;;
      link) ln -s "$work/case/nowhere" "$hooks/pre-commit.devkit" ;;
    esac
    install
    [[ $rc == 1 && $err == "ERROR: $hooks/pre-commit.devkit is not devkit's copy; move it away and re-run 'make hooks'." ]] &&
      stamped "$hooks/pre-push" || return 1
  done
  [[ -L $hooks/pre-commit.devkit && ! -e $work/case/nowhere ]]
}
case_moved_aside_orphan() { # foreign hook, ours moved aside: the side copy goes
  fresh
  install
  cp "$hooks/pre-commit" "$hooks/pre-commit.devkit"
  mv "$hooks/pre-commit" "$hooks/pre-commit.legacy"
  foreign pre-commit
  install
  [[ $rc == 0 && -z $err && $out == *"Removed the orphaned pre-commit.devkit"* &&
    ! -e $hooks/pre-commit.devkit ]] && stamped "$hooks/pre-commit.legacy"
}

# make gate and the pre-push skip.
rec() { echo "$clone/.git/devkit-verified-head"; }
both=$'lint-repo index=unset dir=unset\ntest index=unset dir=unset'
gated() { # a pushable commit that passed the gate; the log is empty again
  fresh
  install
  g commit -q --no-verify --allow-empty -m two
  gate
  [[ $rc == 0 && -z $err && $out == "make gate: recorded $(g rev-parse HEAD | cut -c1-12) as verified;"* &&
    "$(<"$(rec)")" == "$(g rev-parse HEAD)" ]] && logged "$both" || return 1
  : >"$HOOK_LOG"
}
case_gate_records_and_skips() {
  gated || return 1
  say git push -q origin main
  [[ $rc == 0 && $out == "pre-push: HEAD $(g rev-parse HEAD | cut -c1-12) passed 'make gate' on this clean tree; skipping the gate" &&
    $(g rev-parse origin/main) == $(g rev-parse HEAD) ]] && logged ""
}
case_gate_skip_ignores_only() { # the record-skip path stays silent about ONLY
  gated || return 1
  say env ONLY=x git push -q origin main
  [[ $rc == 0 && $out == "pre-push: HEAD $(g rev-parse HEAD | cut -c1-12) passed 'make gate' on this clean tree; skipping the gate" ]] &&
    logged ""
}
case_gate_pre_push_reruns() { # another commit, a dirty tree, assume-unchanged, skip-worktree
  local kind
  for kind in commit untracked assume skip; do
    gated || return 1
    case $kind in
      commit) g commit -q --no-verify --allow-empty -m three ;;
      untracked) echo dirt >"$clone/untracked" ;;
      assume) g update-index --assume-unchanged file && echo two >>"$clone/file" ;;
      skip) g update-index --skip-worktree file && echo two >>"$clone/file" ;;
    esac
    say git push -q origin main
    [[ $rc == 0 && $out != *skipping* ]] && logged "$both" || return 1
  done
}
case_gate_failure() { # no record, and the record of an earlier pass goes
  gated || return 1
  gate FAIL=test
  [[ $rc != 0 && $out == *"INTENDED test FAILURE"* && $out != *NOTE* && ! -e $(rec) ]]
}
case_gate_only() {
  fresh
  gate ONLY=x
  [[ $rc == 2 && -z $out && $err == "ERROR: make gate runs the whole push gate and records the result; unset ONLY (it is 'x')." ]] &&
    logged "" && [[ ! -e $(rec) ]] || return 1
  run make -s -f Makefile -f "$root/make/common.mk" gate ONLY=x
  [[ $rc != 0 && $err == *"unset ONLY"* ]] && logged "" && [[ ! -e $(rec) ]]
}
# sysrc: a machine-wide mavenrc that exists, which the cases cannot move; the
# assertions that need none say so and skip when it is there.
sysrc() {
  local f
  for f in /usr/local/etc/mavenrc /etc/mavenrc; do
    [[ ! -e $f ]] || { echo "$f"; return 0; }
  done
  return 1
}
unwarned() { # true, with a SKIP line, when a machine-wide mavenrc makes "no warning" untestable
  local f
  f=$(sysrc) || return 1
  echo "SKIP: $f exists; not asserting the absence of a warning" >&2
}
settings_xml() { # settings_xml KIND: writes $HOME/.m2/settings.xml
  mkdir -p "$HOME/.m2"
  case $1 in
    props) echo '<settings><profiles><profile><id>p</id><properties><skipTests>true</skipTests></properties></profile></profiles></settings>' ;;
    act_none) echo '<settings><activeProfiles><activeProfile>p</activeProfile></activeProfiles></settings>' ;;
    act_own) echo '<settings><profiles><profile><id>p</id></profile></profiles><activeProfiles><activeProfile>p</activeProfile></activeProfiles></settings>' ;;
    act_comment) echo '<settings><!-- <activeProfiles><activeProfile>p</activeProfile></activeProfiles> --></settings>' ;;
    act_mixed) echo '<settings><profiles><profile><id>a</id></profile></profiles><activeProfiles><activeProfile>a</activeProfile><activeProfile>b</activeProfile></activeProfiles></settings>' ;;
    act_ws) printf '%s\n' '<settings><profiles><profile><id> p </id></profile></profiles><activeProfiles><activeProfile>' '  p' '</activeProfile></activeProfiles></settings>' ;;
    benign) printf '%s\n' '<settings><mirrors><mirror><id>m</id><url>https://example.invalid</url></mirror></mirrors>' \
      '<!-- <profiles><profile><id>p</id>' '<properties><skipTests>true</skipTests></properties>' \
      '</profile></profiles> -->' '</settings>' ;;
  esac >"$HOME/.m2/settings.xml"
}
norecord() { # norecord REASON [VAR=value...]: passes, runs both stages, records nothing
  local why=$1
  shift
  gate "$@"
  [[ $rc == 0 && $out == "NOTE: make gate passed but did not record HEAD: $why." && ! -e $(rec) ]] &&
    logged "$both"
}
case_gate_dirty_start() {
  local kind
  for kind in untracked assume skip; do
    fresh
    case $kind in
      untracked) echo dirt >"$clone/untracked" ;;
      assume) g update-index --assume-unchanged file && echo two >>"$clone/file" ;;
      skip) g update-index --skip-worktree file && echo two >>"$clone/file" ;;
    esac
    norecord "the tree was not clean at the start" || return 1
  done
}
case_gate_ignored_mvn() { # .mvn/ files Maven reads, ignored by git
  local ex pre="git ignores .mvn/ files Maven reads:" post="(they can skip tests)"
  fresh
  ex=$clone/.git/info/exclude
  mkdir -p "$clone/.mvn/wrapper"
  echo -DskipTests >"$clone/.mvn/maven.config"
  echo .mvn/maven.config >>"$ex"
  norecord "$pre .mvn/maven.config $post" || return 1
  : >"$HOOK_LOG"
  echo '<extensions/>' >"$clone/.mvn/extensions.xml"
  echo .mvn/extensions.xml >>"$ex"
  norecord "$pre .mvn/extensions.xml, .mvn/maven.config $post" || return 1
  : >"$HOOK_LOG"
  # An ignored jvm.config, alone.
  rm "$clone/.mvn/maven.config" "$clone/.mvn/extensions.xml"
  echo -Xmx1g >"$clone/.mvn/jvm.config"
  echo .mvn/jvm.config >"$ex"
  norecord "$pre .mvn/jvm.config $post" || return 1
  : >"$HOOK_LOG"
  # Ignored through a directory pattern: the read files are named, the wrapper's is not.
  echo x >"$clone/.mvn/maven.config"
  echo jar >"$clone/.mvn/wrapper/maven-wrapper.jar"
  echo .mvn/ >"$ex"
  norecord "$pre .mvn/jvm.config, .mvn/maven.config $post" || return 1
  : >"$HOOK_LOG"
  # Ignored through core.excludesFile.
  rm "$clone/.mvn/jvm.config"
  printf '%s\n' .mvn/maven.config .mvn/wrapper/ >"$work/excludes"
  : >"$ex"
  g config core.excludesFile "$work/excludes"
  norecord "$pre .mvn/maven.config $post" || return 1
  g config --unset core.excludesFile
  : >"$HOOK_LOG"
  # .mvn/wrapper/ is not read by Maven: recorded. A committed .mvn/jvm.config too.
  rm "$clone/.mvn/maven.config"
  echo -Xmx1g >"$clone/.mvn/jvm.config"
  echo .mvn/wrapper/maven-wrapper.jar >"$ex"
  g add -f .mvn/jvm.config
  g commit -q --no-verify -m jvmconfig
  if ! unwarned; then
    gate
    [[ $rc == 0 && $out == "make gate: recorded"* ]] || return 1
  fi
}
case_gate_home_files() { # settings.xml activeProfiles and a directory at extensions.xml
  fresh
  local spec kind want ok=0 f
  for f in /usr/local/etc/mavenrc /etc/mavenrc; do
    [[ ! -e $f ]] || { echo "SKIP: $f exists; not asserting the home-directory files" >&2; return 0; }
  done
  for spec in act_none:no act_own:yes act_comment:yes act_mixed:no act_ws:yes; do
    kind=${spec%:*} want=${spec#*:}
    : >"$HOOK_LOG"
    settings_xml "$kind"
    if [[ $want == no ]]; then
      norecord "$HOME/.m2/settings.xml activates a profile it does not define (a project profile can skip tests)" || ok=1
    else
      gate
      [[ $rc == 0 && $out == "make gate: recorded"* ]] || ok=1
      rm -f "$(rec)"
    fi
    rm -f "$HOME/.m2/settings.xml"
    [[ $ok == 0 ]] || return 1
  done
  : >"$HOOK_LOG"
  mkdir -p "$HOME/.m2/extensions.xml" # Maven loads only a regular file
  gate MAVEN_SKIP_RC=1
  rmdir "$HOME/.m2/extensions.xml"
  [[ $rc == 0 && $out == "make gate: recorded"* ]]
}
case_gate_ignored_mvn_during() { # an ignored file that appears during the run
  fresh
  norecord "git ignores .mvn/ files Maven reads that appeared during the run: .mvn/maven.config (they can skip tests)" \
    DURING='mkdir -p .mvn && echo x >.mvn/maven.config && echo .mvn/maven.config >>.git/info/exclude'
}
# Committed POM profiles that activate on the environment or on a file.
pom_pre="the project's POMs depend on ambient state:" pom_post="(they can skip tests)"
fx() { # fx PATH: an <activation> on a file that exists
  echo "<file><exists>$1</exists></file>"; }
pf() { # pf PATH: a POM holding one profile, activated by that file
  prof "$(fx "$1")"; }
prof() { # prof ACTIVATION [ID]: a POM holding one profile
  printf '<project><profiles><profile><id>%s</id><activation>%s</activation></profile></profiles></project>' "${2-p}" "$1"
}
pomproj() { # pomproj [FILE CONTENT]...: a fresh clone with the files committed; any file, Python projects too
  fresh
  while [[ $# -gt 0 ]]; do
    mkdir -p "$(dirname "$clone/$1")"
    printf '%s\n' "$2" >"$clone/$1"
    shift 2
  done
  g add -A && g commit -q --no-verify -m poms
}
ignored() { # ignored FILE...: creates the files in the clone, which git ignores
  local f
  for f; do
    mkdir -p "$(dirname "$clone/$f")"
    echo x >"$clone/$f"
    echo "/$f" >>"$clone/.git/info/exclude"
  done
}
nr() { # nr LINE [VAR=value...]: no record, naming the pom_ambient LINE
  local line=$1
  shift
  : >"$HOOK_LOG"
  norecord "$pom_pre $line $pom_post" "$@"
}
yesrec() { # yesrec [VAR=value...]: recorded
  : >"$HOOK_LOG"
  gate "$@"
  [[ $rc == 0 && $out == "make gate: recorded"* ]]
}
# shellcheck disable=SC2016 # the ${...} are literal Maven expressions
case_gate_pom_env() { # profiles activated by an environment variable
  local env_x='<property><name>env.X</name></property>'
  pomproj pom.xml "$(prof "$env_x")"
  nr "pom.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml "$(prof '<property><name>env.X</name><value>v</value></property>')"
  nr "pom.xml: the environment variable X is set" X=w || return 1
  pomproj pom.xml "$(prof '<property><name>!env.X</name></property>')"
  nr "pom.xml: the environment variable X is set" X=a || return 1
  yesrec || return 1 # unset
  yesrec X= || return 1 # empty counts as unset
  pomproj pom.xml "$(prof '<property><name> env.A-B </name></property>')"
  nr "pom.xml: env.A-B is not a variable name the scan can check" || return 1
  pomproj pom.xml "$(prof '<property><name>env.d</name></property>')"
  nr "pom.xml: the environment variable d is set" d=a || return 1 # a name the scan's own variables use
  pomproj pom.xml '<project><profiles><profile><activation><file><exists>absent</exists></file></activation></profile><profile><activation><property><name>env.d</name></property></activation></profile></profiles></project>'
  nr "pom.xml: the environment variable d is set" d=a || return 1 # a local of the scan must not shadow it
  pomproj pom.xml '<project><profiles><profile><activation><file><exists>absent</exists></file></activation></profile><profile><activation><property><name>env.p</name></property></activation></profile></profiles></project>'
  nr "pom.xml: the environment variable p is set" p=a || return 1
  pomproj pom.xml '<project><profiles><profile><activation><file><exists>${basedir}/absent</exists></file></activation></profile><profile><activation><property><name>env.r</name></property></activation></profile></profiles></project>'
  nr "pom.xml: the environment variable r is set" r=a || return 1
  pomproj pom.xml "<project><!-- $(prof "$env_x") --></project>"
  yesrec X=a
}
case_gate_pom_scope() { # which POMs are read
  local env_x='<property><name>env.X</name></property>'
  pomproj pom.xml '<project><modules><module>mod</module></modules></project>' \
    mod/pom.xml "$(prof "$env_x" | sed 's|<project>|<project><parent><artifactId>r</artifactId></parent>|')" # default parent: ../pom.xml, a cycle
  nr "mod/pom.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml '<project><profiles><profile><id>q</id><modules><module>mod</module></modules></profile></profiles></project>' \
    mod/pom.xml "$(prof "$env_x")"
  nr "mod/pom.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml '<project><modules><module>mod/other.xml</module></modules></project>' mod/other.xml "$(prof "$env_x")"
  nr "mod/other.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml '<project><parent><relativePath>parent/pom.xml</relativePath></parent></project>' parent/pom.xml "$(prof "$env_x")"
  nr "parent/pom.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml '<project><parent><artifactId>r</artifactId></parent></project>' ../pom.xml "$(prof "$env_x")"
  yesrec X=a # the default parent, ../pom.xml, lies outside the tree
}
# shellcheck disable=SC2016 # the ${...} are literal Maven expressions
case_gate_pom_files() { # profiles activated by a file
  local act ok=0
  for act in flag '${basedir}/flag' '${project.basedir}/flag' '${project.rootDirectory}/flag'; do
    pomproj pom.xml "$(pf "$act")"
    ignored flag
    nr "pom.xml: $act exists and git does not track it" || return 1
  done
  pomproj pom.xml "$(pf '${env.D}/flag')"
  ignored flag
  nr "pom.xml: the environment variable D is set" D=/nowhere || return 1
  yesrec || return 1 # D unset: the path is literal
  pomproj pom.xml "$(pf '${user.home}/x')"
  echo x >"$HOME/x"
  nr 'pom.xml: ${user.home}/x exists and git does not track it' || ok=1
  rm -f "$HOME/x"
  [[ $ok == 0 ]] || return 1
  pomproj pom.xml "$(pf '${foo}/x')"
  nr 'pom.xml: ${foo}/x depends on a property' || return 1
  pomproj pom.xml "$(pf file)" # tracked
  yesrec || return 1
  pomproj pom.xml "$(pf dir)" dir/f x # a tracked directory
  yesrec || return 1
  pomproj pom.xml "$(pf absent)"
  yesrec || return 1
  pomproj pom.xml "$(prof '<file><missing>flag</missing></file>')"
  ignored flag
  nr "pom.xml: flag exists and git does not track it" || return 1
  # The root's relative path, found only in a module's directory.
  pomproj pom.xml "<project><modules><module>mod</module></modules>$(prof "$(fx only)" | sed 's|^<project>||')" mod/pom.xml '<project/>'
  ignored mod/only
  nr "pom.xml: only exists and git does not track it" || return 1
  pomproj pom.xml "$(pf '*.flag')"
  ignored a.flag
  yesrec
}
case_gate_pom_during() { # an ignored file that appears during the run
  pomproj pom.xml "$(prof '<file><exists>flag</exists></file>')"
  : >"$HOOK_LOG"
  norecord "the project's POMs depend on ambient state that appeared during the run: pom.xml: flag exists and git does not track it $pom_post" \
    DURING='echo x >flag && echo /flag >>.git/info/exclude'
}
case_pre_push_poms() { # the hook warns on the same profiles, and still gates
  local env_x='<property><name>env.X</name></property>' file_x='<file><exists>flag</exists></file>' spec kind var want
  for spec in "env|X=a|pom.xml: the environment variable X is set" \
    "file|F=1|pom.xml: flag exists and git does not track it" \
    "module|X=a|mod/pom.xml: the environment variable X is set" \
    "parent|X=a|parent/pom.xml: the environment variable X is set" \
    "ignoredparent|F=1|build/pom.xml: git does not track this POM" \
    "unset|F=1|" "tracked|F=1|" "absent|F=1|"; do
    kind=${spec%%|*} var=${spec#*|} want=${var#*|} var=${var%%|*}
    case $kind in
      env | unset) pomproj pom.xml "$(prof "$env_x")" ;;
      file | absent) pomproj pom.xml "$(prof "$file_x")" ;;
      module) pomproj pom.xml '<project><modules><module>mod</module></modules></project>' mod/pom.xml "$(prof "$env_x")" ;;
      parent) pomproj pom.xml '<project><parent><relativePath>parent/pom.xml</relativePath></parent></project>' parent/pom.xml "$(prof "$env_x")" ;;
      ignoredparent) pomproj pom.xml '<project><parent><relativePath>build/pom.xml</relativePath></parent></project>' && ignored build/pom.xml ;;
      tracked) pomproj pom.xml "$(prof "$file_x")" flag x ;;
    esac
    [[ $kind != file ]] || ignored flag
    install
    : >"$HOOK_LOG"
    say env "$var" git push -q origin main
    [[ $rc == 0 ]] && logged "$both" || return 1
    if [[ -n $want ]]; then [[ $out == *"WARNING: $pom_pre $want $pom_post."* ]] || return 1; else [[ $out != *"ambient state"* ]] || return 1; fi
  done
}
case_gate_pom_queue() { # several POMs at once, several profiles in one, one hit per line
  local env_x='<property><name>env.X</name></property>' two
  pomproj pom.xml '<project><modules><module>m1</module><module>m2</module><module>m3</module></modules></project>' \
    m1/pom.xml '<project/>' m2/pom.xml '<project/>' m3/pom.xml "$(prof "$env_x")"
  nr "m3/pom.xml: the environment variable X is set" X=a || return 1
  two='<project><profiles><profile><activation>%s</activation></profile><profile><activation>%s</activation></profile></profiles></project>'
  # shellcheck disable=SC2059 # the format is the template above
  pomproj pom.xml "$(printf "$two" "$env_x" '<property><name>env.Y</name></property>')"
  nr "pom.xml: the environment variable X is set, pom.xml: the environment variable Y is set" X=a Y=b || return 1
  # shellcheck disable=SC2059
  pomproj pom.xml "$(printf "$two" "$env_x" "$env_x")"
  nr "pom.xml: the environment variable X is set" X=a
}
# shellcheck disable=SC2016 # the ${...} are literal Maven expressions
case_gate_pom_env_refs() { # ${env.N} in a path: set counts, empty included; the rest of the path is still checked
  pomproj pom.xml "$(pf '${env.X}flag')"
  ignored flag
  nr "pom.xml: the environment variable X is set" X= || return 1 # Maven substitutes the empty value
  yesrec || return 1 # unset: the path stays literal
  pomproj pom.xml "$(pf '${foo}${env.NOPE}')"
  nr 'pom.xml: ${foo}${env.NOPE} depends on a property' || return 1
  pomproj pom.xml "$(pf '${env.}/x')"
  nr 'pom.xml: env. is not a variable name the scan can check' || return 1
  pomproj pom.xml "$(pf '${env.A-B}/x')"
  nr 'pom.xml: env.A-B is not a variable name the scan can check'
}
case_gate_pom_tags() { # tags with whitespace and attributes, and one that only looks like a tag
  local env_x='<property><name>env.X</name></property>' open='<project><profiles><profile>' close='</profile></profiles></project>'
  pomproj pom.xml "$open<activation >$env_x</activation >$close"
  nr "pom.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml "$open<activation xml:space=\"preserve\">$env_x</activation>$close"
  nr "pom.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml "$open<activation><property ><name foo=\"1\">env.X</name ></property ></activation>$close"
  nr "pom.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml "$open<activation><file ><exists >ignored</exists ></file ></activation>$close"
  ignored ignored
  nr "pom.xml: ignored exists and git does not track it" || return 1
  pomproj pom.xml "<project><names>x</names>$open<activation>$env_x</activation>$close"
  nr "pom.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml '<project><modules ><module >mod</module ></modules ></project>' mod/pom.xml "$(prof "$env_x")"
  nr "mod/pom.xml: the environment variable X is set" X=a || return 1
  pomproj pom.xml '<project><parent ><relativePath >parent/pom.xml</relativePath ></parent ></project>' parent/pom.xml "$(prof "$env_x")"
  nr "parent/pom.xml: the environment variable X is set" X=a
}
# shellcheck disable=SC2016 # the ${...} are literal Maven expressions
case_gate_pom_forms() { # names, values and paths the scan does not resolve
  pomproj pom.xml "$(prof '<property><name>${env.SEL}</name></property>')"
  nr 'pom.xml: ${env.SEL} in an activation depends on a property' SEL=env.X X=1 || return 1
  pomproj pom.xml "$(prof '<property><name>x</name><value>${env.Y}</value></property>')"
  nr 'pom.xml: ${env.Y} in an activation depends on a property' Y=1 || return 1
  local path
  for path in 'flags\skip' 'sub/../x' 'flag/'; do
    pomproj pom.xml "$(pf "$path")"
    nr "pom.xml: $path is a path the scan does not resolve" || return 1
  done
  pomproj pom.xml "$(pf '${project.rootDirectory}/flag')" mod/x x
  yesrec || return 1
  pomproj pom.xml '<project><modules><module>mod</module></modules></project>' mod/pom.xml "$(pf '${project.rootDirectory}/flag')"
  ignored mod/flag
  nr 'mod/pom.xml: ${project.rootDirectory}/flag exists and git does not track it' || return 1
  pomproj pom.xml "$(pf .git)"
  yesrec || return 1 # every checkout has one
  pomproj pom.xml "$(pf dir)"
  ignored dir/f
  nr "pom.xml: dir exists and git does not track it" || return 1 # a directory
  pomproj pom.xml "$(prof '<property><name>foo</name></property>')"
  yesrec X=a
}
# shellcheck disable=SC2016 # the ${...} are literal Maven expressions
case_gate_pom_reactor() { # what the walk lists, and what it notes
  local env_x='<property><name>env.X</name></property>'
  pomproj pom.xml '<project><parent><relativePath>build/pom.xml</relativePath></parent></project>'
  ignored build/pom.xml
  nr "build/pom.xml: git does not track this POM" || return 1
  pomproj pom.xml '<project><modules><module>${m}</module></modules></project>'
  nr 'pom.xml: module ${m} holds a property' || return 1
  pomproj pom.xml '<project><modules><module>../outside</module></modules></project>'
  mkdir -p "$work/case/outside"
  echo '<project/>' >"$work/case/outside/pom.xml"
  nr "pom.xml: module ../outside resolves outside the project" || return 1
  pomproj pom.xml '<project><modules><module>gone</module></modules></project>'
  yesrec || return 1 # a module that does not exist: Maven fails the build
  pomproj pom.xml '<project><modules><module>mod/sub</module></modules></project>' \
    mod/pom.xml "$(prof "$env_x")" mod/sub/pom.xml '<project><parent><artifactId>r</artifactId></parent></project>'
  nr "mod/pom.xml: the environment variable X is set" X=a || return 1 # the default parent
  pomproj pom.xml '<project><modules><module>mod/sub</module></modules></project>' \
    mod/pom.xml "$(prof "$env_x")" mod/sub/pom.xml '<project><parent><relativePath/></parent></project>'
  yesrec X=a || return 1 # an empty relativePath names no parent
  pomproj pom.xml '<project><parent><relativePath>parent</relativePath></parent></project>' parent/pom.xml "$(prof "$env_x")"
  nr "parent/pom.xml: the environment variable X is set" X=a
}
case_gate_pom_text() { # processing instructions and .mvn/maven.config
  local env_x='<property><name>env.X</name></property>'
  pomproj pom.xml "<?x <!-- ?>$(prof "$env_x")"
  nr "pom.xml: holds a processing instruction" X=a || return 1
  pomproj pom.xml $'<?xml version="1.0"?>\n'"$(prof "$env_x")"
  nr "pom.xml: the environment variable X is set" X=a || return 1
  yesrec || return 1 # a leading XML declaration is no processing instruction
  local opt
  for opt in '-f alt/pom.xml' '--file=alt/pom.xml' '-falt/pom.xml' '-T 2 --file alt/pom.xml'; do
    pomproj pom.xml '<project/>' .mvn/maven.config "$opt"
    nr ".mvn/maven.config names the POM to build" || return 1
  done
  pomproj pom.xml '<project/>' .mvn/maven.config '-fae'
  yesrec
}
case_gate_pom_scan_failure() { # a scan that fails refuses to record, and the hook warns and gates
  pomproj pom.xml "$(pf flag)"
  printf junk >"$clone/.git/index"
  : >"$HOOK_LOG"
  gate
  [[ $rc == 0 && $out == *"could not scan the project's POMs"* && ! -e $(rec) ]] && logged "$both" || return 1
  install
  : >"$HOOK_LOG"
  say git push -q origin main
  [[ $rc == 0 && $out == *"WARNING: could not scan the project's POMs; the gate runs anyway."* ]] && logged "$both"
}
pytest_pre="git ignores files pytest reads:" pytest_post="(they can deselect tests or skew coverage)"
prewarns() { # prewarns NAMES [VAR=value...]: the hook warns on them, and still gates
  install
  : >"$HOOK_LOG"
  say env DEVKIT_T= ${2+"${@:2}"} git push -q origin main
  [[ $rc == 0 && $out == *"WARNING: $pytest_pre $1 $pytest_post."* ]] && logged "$both"
}
case_gate_ignored_pytest() { # files pytest reads, ignored by git
  local f
  for f in pytest.ini pytest.toml .pytest.toml .pytest.ini tox.ini setup.cfg .coveragerc .coveragerc.toml; do
    pomproj pyproject.toml '[project]'
    ignored "$f"
    norecord "$pytest_pre $f $pytest_post" || return 1
    prewarns "$f" || return 1
  done
  pomproj pyproject.toml '[project]' packages/core/pyproject.toml '[project]'
  ignored packages/core/pytest.ini packages/pyproject.toml
  norecord "$pytest_pre packages/core/pytest.ini, packages/pyproject.toml $pytest_post" || return 1
  pomproj pyproject.toml '[project]'
  ignored tests/conftest.py packages/core/tests/conftest.py
  norecord "$pytest_pre packages/core/tests/conftest.py, tests/conftest.py $pytest_post" || return 1
  pomproj pyproject.toml '[project]'
  echo pytest.ini >"$work/excludes"
  g config core.excludesFile "$work/excludes"
  echo x >"$clone/pytest.ini"
  norecord "$pytest_pre pytest.ini $pytest_post" || return 1
  if ! unwarned; then
    # Not read, or not counted: recorded.
    pomproj pyproject.toml '[project]'
    ignored .venv/lib/p/conftest.py venv/conftest.py build/conftest.py dist/conftest.py node_modules/conftest.py x.egg/conftest.py \
      _darcs/conftest.py CVS/conftest.py '{arch}/conftest.py' \
      env/pyvenv.cfg env/lib/p/conftest.py docs/pytest.ini
    mkdir -p "$clone/nested"
    git init -q "$clone/nested"
    echo x >"$clone/nested/conftest.py"
    echo x >"$clone/nested/pytest.ini"
    echo /nested/ >>"$clone/.git/info/exclude"
    yesrec || return 1
    pomproj pyproject.toml '[project]' pytest.ini x
    yesrec || return 1
    pomproj other.txt x
    ignored pytest.ini tests/conftest.py
    yesrec || return 1
    pomproj packages/core/pyproject.toml '[project]'
    ignored pytest.ini
    yesrec || return 1
  fi
}
case_gate_ignored_pytest_members() { # a member's own directories, a root conftest.py, test* directories, GIT_LITERAL_PATHSPECS
  pomproj pyproject.toml '[project]'
  ignored conftest.py
  norecord "$pytest_pre conftest.py $pytest_post" || return 1
  # A member named like a skipped directory: its files still count.
  pomproj pyproject.toml '[project]' packages/build/pyproject.toml '[project]'
  ignored packages/build/pytest.ini
  norecord "$pytest_pre packages/build/pytest.ini $pytest_post" || return 1
  pomproj pyproject.toml '[project]' packages/build/pyproject.toml '[project]'
  ignored packages/build/tests/conftest.py
  norecord "$pytest_pre packages/build/tests/conftest.py $pytest_post" || return 1
  # pytest loads test*/conftest.py at startup, whatever the directory holds.
  pomproj pyproject.toml '[project]'
  ignored tests/pyvenv.cfg tests/conftest.py
  norecord "$pytest_pre tests/conftest.py $pytest_post" || return 1
  pomproj pyproject.toml '[project]'
  ignored pytest.ini
  norecord "$pytest_pre pytest.ini $pytest_post" GIT_LITERAL_PATHSPECS=1 || return 1
  # A directory named pyvenv.cfg is no virtual environment.
  pomproj pyproject.toml '[project]'
  mkdir -p "$clone/src/pyvenv.cfg"
  ignored src/sub/conftest.py
  norecord "$pytest_pre src/sub/conftest.py $pytest_post" || return 1
  # A member path git quotes (a double quote) still reaches the screen.
  pomproj pyproject.toml '[project]' 'q"m/pyproject.toml' '[project]'
  ignored 'q"m/pytest.ini'
  norecord "$pytest_pre q\"m/pytest.ini $pytest_post" || return 1
  if ! unwarned; then
    pomproj pyproject.toml '[project]'
    ignored env/conda-meta/history env/lib/p/conftest.py
    yesrec || return 1
    pomproj pyproject.toml '[project]'
    ignored tests/build/conftest.py
    yesrec || return 1
  fi
}
case_gate_ignored_pytest_screen() { # conftest.py above a project directory, __pycache__, a path git quotes, directory patterns, a failing listing
  local d shim
  # pytest loads the conftest.py of every directory above its session directory.
  for d in build .hidden; do
    pomproj pyproject.toml '[tool.pytest.ini_options]' "$d/core/pyproject.toml" '[project]'
    ignored "$d/conftest.py"
    norecord "$pytest_pre $d/conftest.py $pytest_post" || return 1
    prewarns "$d/conftest.py" || return 1
  done
  # A newline in a project directory's name would forge the top level's key.
  pomproj pyproject.toml '[project]'
  mkdir -p "$clone/"$'a\n'
  echo '[project]' >"$clone/"$'a\n/pyproject.toml'
  g add -A && g commit -q --no-verify -m newline
  ignored pytest.ini
  norecord "the files pytest reads could not be screened" || return 1
  # Only the screen's listing fails (not the gitlink one, ls-files -s): strictly_clean passes, and nothing records.
  pomproj pyproject.toml '[project]'
  shim=$work/shim
  mkdir -p "$shim"
  printf '#!/bin/bash\nif [[ " $* " == *" ls-files "* && " $* " == *" -z "* && " $* " != *" -s "* ]]; then exit 1; fi\nexec %q "$@"\n' "$(command -v git)" >"$shim/git"
  chmod +x "$shim/git"
  norecord "the files pytest reads could not be screened" PATH="$shim:$PATH" || return 1
  if ! unwarned; then
    pomproj pyproject.toml '[project]' packages/core/pyproject.toml '[project]'
    ignored src/__pycache__/conftest.py packages/core/src/__pycache__/conftest.py
    yesrec || return 1
    # A path git would quote, in a virtual environment.
    pomproj pyproject.toml '[project]'
    ignored 'env/q"d/conftest.py' env/pyvenv.cfg
    yesrec || return 1
    # Ignored by a directory pattern.
    pomproj pyproject.toml '[project]'
    mkdir -p "$clone/.venv/lib/x"
    echo x >"$clone/.venv/pyvenv.cfg"
    echo x >"$clone/.venv/lib/x/conftest.py"
    echo .venv/ >>"$clone/.git/info/exclude"
    yesrec || return 1
  fi
  pomproj pyproject.toml '[project]'
  mkdir -p "$clone/scratch"
  echo x >"$clone/scratch/conftest.py"
  echo scratch/ >>"$clone/.git/info/exclude"
  norecord "$pytest_pre scratch/conftest.py $pytest_post"
}
case_gate_ignored_pytest_files() { # venv markers and test modules, ignored by git
  local f
  pomproj pyproject.toml '[project]' tests/unit/test_u.py x
  ignored tests/unit/pyvenv.cfg
  norecord "$pytest_pre tests/unit/pyvenv.cfg $pytest_post" || return 1
  prewarns tests/unit/pyvenv.cfg || return 1
  pomproj pyproject.toml '[project]' tests/unit/test_u.py x
  ignored tests/unit/conda-meta/history
  norecord "$pytest_pre tests/unit/conda-meta/history $pytest_post" || return 1
  prewarns tests/unit/conda-meta/history || return 1
  for f in tests/test_scratch.py pkg/x_test.py; do
    pomproj pyproject.toml '[project]'
    ignored "$f"
    norecord "$pytest_pre $f $pytest_post" || return 1
    prewarns "$f" || return 1
  done
  # The hook warns whatever the pathspec switches say; GLOB and NOGLOB together make git die.
  pomproj pyproject.toml '[project]'
  ignored pytest.ini
  prewarns pytest.ini GIT_GLOB_PATHSPECS=1 GIT_NOGLOB_PATHSPECS=1 || return 1
  # A skipped directory's name folds nothing under nocasematch.
  pomproj pyproject.toml '[project]'
  ignored BUILD/conftest.py
  norecord "$pytest_pre BUILD/conftest.py $pytest_post" BASHOPTS=nocasematch || return 1
  if ! unwarned; then
    pomproj pyproject.toml '[project]'
    ignored .venv/pyvenv.cfg env/pyvenv.cfg pyvenv.cfg .venv/lib/p/test_x.py build/test_x.py env/test_x.py
    yesrec || return 1
  fi
}
case_gate_pathspec_switches() { # inherited GIT_*_PATHSPECS neither hide nor invent anything
  pomproj pom.xml "$(pf Foo.txt)" foo.txt x
  ignored Foo.txt
  nr "pom.xml: Foo.txt exists and git does not track it" GIT_ICASE_PATHSPECS=1 || return 1
  pomproj pom.xml "$(pf file)" # tracked
  if ! unwarned; then
    yesrec GIT_LITERAL_PATHSPECS=1 || return 1
  fi
}
case_gate_literal_pathspecs() { # an inherited GIT_LITERAL_PATHSPECS does not blind strictly_clean
  fresh
  g update-index --skip-worktree file && echo two >>"$clone/file"
  norecord "the tree was not clean at the start" GIT_LITERAL_PATHSPECS=1 || return 1
  gated || return 1
  g update-index --skip-worktree file && echo two >>"$clone/file"
  say env GIT_LITERAL_PATHSPECS=1 git push -q origin main
  [[ $rc == 0 && $out != *skipping* ]] && logged "$both"
}
case_gate_ignored_pytest_during() { # an ignored file that appears during the run
  pomproj pyproject.toml '[project]'
  norecord "git ignores files pytest reads that appeared during the run: pytest.ini $pytest_post" \
    DURING='echo x >pytest.ini && echo /pytest.ini >>.git/info/exclude'
}
case_pre_push_ignored_pytest() { # the hook warns on the same files, and still gates
  pomproj pyproject.toml '[project]'
  ignored pytest.ini tests/conftest.py .venv/lib/p/conftest.py
  git init -q "$clone/nested"
  echo x >"$clone/nested/conftest.py"
  echo /nested/ >>"$clone/.git/info/exclude"
  install
  : >"$HOOK_LOG"
  say git push -q origin main
  [[ $rc == 0 && $out == *"WARNING: $pytest_pre pytest.ini, tests/conftest.py $pytest_post."* ]] && logged "$both"
}
hidden() { # the clone's status is empty although file holds an edit (the premise of the cases below)
  [[ -z $(g --no-optional-locks status --porcelain) && $(<"$clone/file") == two ]]
}
strip() { # strip: a clean filter that maps "two" to the committed "one", for file; edit then changes the content, not the size
  echo 'file filter=strip' >>"$clone/.git/info/attributes"
  g config filter.strip.clean 'sed s/two/one/'
}
edit() { echo two >"$clone/file"; }
case_gate_clean_filter() { # a clean filter can make an edit read as clean
  local reason="git reads tracked files through a clean filter or the ident attribute (it can hide an edit): strip"
  fresh
  strip
  edit
  hidden || return 1
  norecord "$reason" || return 1
  # The same through a C-quoted path, which no edit is needed to find.
  fresh
  echo x >"$clone/é.q"
  g add é.q && g commit -q --no-verify -m q
  [[ $(g ls-files) == *'"\303\251.q"'* ]] || return 1
  echo '*.q filter=strip' >>"$clone/.git/info/attributes"
  # Not a conforming process filter: the screen refuses before any status
  # hashes the file through it, so git's reaction to the handshake is moot.
  g config filter.strip.process 'cat'
  norecord "$reason" || return 1
  # An attribute whose driver is not configured, and a driver no path uses.
  fresh
  echo 'file filter=nope' >>"$clone/.git/info/attributes"
  g config filter.other.clean cat
  gate
  [[ $rc == 0 && $out == "make gate: recorded"* && -f $(rec) ]] || return 1
  # The same, with the attribute unset, set or unspecified by a later line
  # (a set one names the driver "set", which is not configured).
  local later
  for later in 'file -filter' 'file filter' 'file !filter'; do
    fresh
    printf '%s\n' 'file filter=strip' "$later" >>"$clone/.git/info/attributes"
    g config filter.strip.clean 'sed s/two/one/'
    gate
    [[ $rc == 0 && $out == "make gate: recorded"* && -f $(rec) ]] || return 1
  done
  # A driver literally named set is a driver, not the attribute's state.
  fresh
  echo 'file filter=set' >>"$clone/.git/info/attributes"
  g config filter.set.clean cat
  norecord "git reads tracked files through a clean filter or the ident attribute (it can hide an edit): set"
}
case_gate_clean_filter_two() { # two configured drivers at once are both named
  fresh
  echo x >"$clone/other"
  g add other && g commit -q --no-verify -m o
  printf '%s\n' 'file filter=strip' 'other filter=cat2' >>"$clone/.git/info/attributes"
  g config filter.strip.clean cat
  g config filter.cat2.clean cat
  norecord "git reads tracked files through a clean filter or the ident attribute (it can hide an edit): strip, cat2"
}
case_gate_clean_filter_during() { # a filter that applies to a file that appeared during the run
  fresh
  norecord "a clean filter or ident attribute that appeared during the run applies to tracked files (it can hide an edit): strip" \
    DURING='echo "file filter=strip" >>.git/info/attributes && git config filter.strip.clean cat'
}
stale() { # a stat a clean filter validated, kept after the filter is removed: status reads the edit as clean
  strip
  sleep 1 # the edit's timestamp must differ from the index's
  edit
  g status --porcelain >/dev/null
  sleep 1
  g status --porcelain >/dev/null
  g config --unset filter.strip.clean
  hidden || return 1
}
case_gate_stale_stat() { # the stat of a removed clean filter cannot hide an edit
  fresh
  stale || return 1
  norecord "the tree was not clean at the start"
}
case_pre_push_stale_stat() {
  gated || return 1
  stale || return 1
  say git push -q origin main
  [[ $rc == 0 && $out != *skipping* ]] && logged "$both"
}
case_gate_clean_filter_submodule() { # a clean filter a submodule's own configuration applies to its files
  fresh
  local sub=$work/case/sub
  git init -q "$sub" && echo x >"$sub/f" && git -C "$sub" add f && git -C "$sub" commit -q -m s
  g -c protocol.file.allow=always submodule -q add "$sub" sm
  g commit -q --no-verify -m sm
  echo 'f filter=strip' >>"$clone/.git/modules/sm/info/attributes"
  git -C "$clone/sm" config filter.strip.clean cat
  norecord "git reads tracked files through a clean filter or the ident attribute (it can hide an edit): sm:strip"
}
case_gate_ident() { # ident collapses $Id: sha $ to $Id$, so a same-size edit inside it reads clean
  fresh
  echo 'file ident' >>"$clone/.git/info/attributes"
  # shellcheck disable=SC2016 # the literal keyword
  echo '$Id$' >"$clone/file"
  g add file && g commit -q --no-verify -m id
  rm "$clone/file" && g checkout -q -- file
  # shellcheck disable=SC2016 # the literal keyword
  [[ $(<"$clone/file") == '$Id: '*' $' ]] || return 1
  sed -i 's/[0-9a-f]\{40\}/0000000000000000000000000000000000000000/' "$clone/file"
  [[ -z $(g --no-optional-locks status --porcelain) ]] || return 1
  norecord "git reads tracked files through a clean filter or the ident attribute (it can hide an edit): ident attribute"
}
case_gate_dedup_collisions() { # the dedup key is the submodule and the driver, not their joined label
  local sub=$work/case/sub
  fresh
  git init -q "$sub" && echo x >"$sub/f" && git -C "$sub" add f && git -C "$sub" commit -q -m s
  g -c protocol.file.allow=always submodule -q add "$sub" .a
  g -c protocol.file.allow=always submodule -q add "$sub" a
  g commit -q --no-verify -m sm
  local m
  for m in .a a; do
    echo 'f filter=strip' >>"$clone/.git/modules/$m/info/attributes"
    git -C "$clone/$m" config filter.strip.clean cat
  done
  norecord "git reads tracked files through a clean filter or the ident attribute (it can hide an edit): .a:strip, a:strip" || return 1
  # A top-level driver named sm:strip and submodule sm's driver strip.
  fresh
  git init -q "$sub" && echo x >"$sub/f" && git -C "$sub" add f && git -C "$sub" commit -q -m s
  g -c protocol.file.allow=always submodule -q add "$sub" sm
  g commit -q --no-verify -m sm
  echo 'f filter=strip' >>"$clone/.git/modules/sm/info/attributes"
  git -C "$clone/sm" config filter.strip.clean cat
  echo 'file filter=sm:strip' >>"$clone/.git/info/attributes"
  g config filter.sm:strip.clean cat
  norecord "git reads tracked files through a clean filter or the ident attribute (it can hide an edit): sm:strip, sm:strip"
}
case_gate_gitlink_unlisted() { # an embedded repository: git submodule cannot list its filters
  fresh
  git init -q "$clone/emb" && echo x >"$clone/emb/f" && git -C "$clone/emb" add f && git -C "$clone/emb" commit -q -m e
  g add emb 2>/dev/null
  g commit -q --no-verify -m emb
  [[ $(g ls-files -s emb) == 160000* ]] || return 1
  norecord "a gitlink has no .gitmodules entry: emb (git submodule cannot list its clean filters)"
}
replaced() { # replaced DIR FILE: stage an edit of FILE and replace HEAD by a commit holding it, so git sees no change
  local tree fake
  echo two >"$1/$2"
  git -C "$1" add "$2"
  tree=$(git -C "$1" write-tree)
  fake=$(git -C "$1" commit-tree "$tree" -m fake)
  git -C "$1" replace -f "$(git -C "$1" rev-parse HEAD)" "$fake"
  [[ -z $(git -C "$1" --no-optional-locks status --porcelain) ]]
}
case_gate_replace_ref() { # a replace ref hides an edit from a plain status
  fresh
  replaced "$clone" file || return 1
  [[ -z $(g --no-optional-locks status --porcelain) ]] || return 1
  norecord "the tree was not clean at the start" || return 1
  # The same in a submodule, where --no-replace-objects does not reach.
  fresh
  local sub=$work/case/sub
  git init -q "$sub" && echo x >"$sub/f" && git -C "$sub" add f && git -C "$sub" commit -q -m s
  g -c protocol.file.allow=always submodule -q add "$sub" sm
  g commit -q --no-verify -m sm
  replaced "$clone/sm" f || return 1
  [[ -z $(g --no-optional-locks status --porcelain) ]] || return 1
  norecord "the tree was not clean at the start"
}
case_pre_push_clean_filter() { # the record does not skip the gate while a clean filter applies
  gated || return 1
  strip
  edit
  hidden || return 1
  say git push -q origin main
  [[ $rc == 0 && $out != *skipping* ]] && logged "$both"
}
fsmonitor() { # fsmonitor: a hook that reports no change (version 1: no output), with status having marked every entry valid
  printf '#!/bin/sh\nexit 0\n' >"$work/fsmonitor-hook"
  chmod +x "$work/fsmonitor-hook"
  g config core.fsmonitor "$work/fsmonitor-hook"
  g config core.fsmonitorHookVersion 1
  g status --porcelain >/dev/null
  g status --porcelain >/dev/null
  sleep 1 # the edit's timestamp must differ from the index's
  edit
}
# Both fsmonitor cases are pinned by the fresh-index status as well as by the
# flag, so neither flag is pinned on its own.
case_gate_fsmonitor() { # an fsmonitor hook that misses an edit
  fresh
  fsmonitor
  hidden || return 1
  norecord "the tree was not clean at the start"
}
case_pre_push_fsmonitor() {
  gated || return 1
  fsmonitor
  hidden || return 1
  say git push -q origin main
  [[ $rc == 0 && $out != *skipping* ]] && logged "$both"
}
case_gate_env() { # git's local environment variables are unset, as pre-push does
  fresh
  gate GIT_DIR="$clone/.git" GIT_INDEX_FILE="$work/no-such-index"
  [[ $rc == 0 && $out == "make gate: recorded"* && -f $(rec) ]] && logged "$both" || return 1
  # Injected configuration cannot hide an edit either.
  fresh
  strip
  g config --unset filter.strip.clean
  edit
  [[ -n $(g --no-optional-locks status --porcelain) ]] || return 1
  local params="'filter.strip.clean=sed s/two/one/'"
  [[ -z $(GIT_CONFIG_PARAMETERS=$params g --no-optional-locks status --porcelain) ]] || return 1
  norecord "the tree was not clean at the start" GIT_CONFIG_PARAMETERS="$params"
}
case_jvm_screen_parity() { # the hook stays self-contained, so the two copies must not drift
  local names=(jvm_option strip_comments sets_properties activates_project_profile trim ignored_mvn ignored_pytest pytest_skips printable pathspec_git strictly_clean clean_filters identifier xml_texts normalize_tags note_ambient read_pom ambient_file candidate_ambient resolve_pom reactor_poms maven_config_file collect_env check_path check_activation ambient_profiles env_hits pom_scan) a b alt
  alt=$(IFS='|' && echo "${names[*]}")
  local extract="/^(file_re|exit_re|jvm_re|help_re|dq)=/p;/^($alt)\\(\\)/,/^}/p"
  a=$(sed -En "$extract" "$root/scripts/gate.sh")
  b=$(sed -En "$extract" "$root/scripts/hooks/pre-push.sh")
  # Every listed helper was extracted: a name changed in both files drops out.
  [[ $(grep -c '_re=' <<<"$a") == 4 && $(grep -cE '^[a-z_]+\(\) \{' <<<"$a") == "${#names[@]}" && $a == "$b" ]]
}
case_gate_environment() { # variables that can skip or deselect tests
  fresh
  norecord "MAVEN_ARGS is set (it can skip tests)" MAVEN_ARGS=-q || return 1
  : >"$HOOK_LOG"
  norecord "MAVEN_BASEDIR is set (it moves .mvn/ and the gate configurations, which can skip tests)" MAVEN_BASEDIR=/x || return 1
  : >"$HOOK_LOG"
  norecord "MAVEN_DEBUG_OPTS is set (the launcher hands it to java, which can skip tests)" MAVEN_DEBUG_OPTS=-version || return 1
  : >"$HOOK_LOG"
  local var
  for var in MAVEN_OPTS JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS OPENJ9_JAVA_OPTIONS IBM_JAVA_OPTIONS; do
    norecord "$var holds -D (it can skip tests)" "$var=-Dx=y" || return 1
    : >"$HOOK_LOG"
  done
  local spec
  for spec in 'MAVEN_OPTS=@file|MAVEN_OPTS holds @argfile' \
    'JDK_JAVA_OPTIONS="@file"|JDK_JAVA_OPTIONS holds @argfile' \
    'JDK_JAVA_OPTIONS=--list-modules|JDK_JAVA_OPTIONS holds --list-modules' \
    'JAVA_TOOL_OPTIONS=-XX:VMOptionsFile=x|JAVA_TOOL_OPTIONS holds -XX:VMOptionsFile' \
    '_JAVA_OPTIONS=-XX:Flags=x|_JAVA_OPTIONS holds -XX:Flags' \
    'MAVEN_OPTS=-version|MAVEN_OPTS holds -version' \
    'MAVEN_OPTS=-Xmx1g --dry-run|MAVEN_OPTS holds --dry-run' \
    'MAVEN_OPTS=-Xshare:dump|MAVEN_OPTS holds -Xshare:dump' \
    'MAVEN_OPTS=-XX:AOTMode=create|MAVEN_OPTS holds -XX:AOTMode=create' \
    'MAVEN_OPTS=--module=x/y|MAVEN_OPTS holds --module' \
    'MAVEN_OPTS=-?|MAVEN_OPTS holds -?' \
    'MAVEN_OPTS=-fullversion|MAVEN_OPTS holds -fullversion' \
    'MAVEN_OPTS=--full-version|MAVEN_OPTS holds --full-version' \
    'MAVEN_OPTS=-Xinternalversion|MAVEN_OPTS holds -Xinternalversion' \
    'MAVEN_OPTS=-XX:+PrintFlagsInitial|MAVEN_OPTS holds -XX:+PrintFlagsInitial' \
    'JAVA_TOOL_OPTIONS=-XX:+PrintSharedArchiveAndExit|JAVA_TOOL_OPTIONS holds -XX:+PrintSharedArchiveAndExit' \
    'MAVEN_OPTS=-Xoptionsfile=x|MAVEN_OPTS holds -Xoptionsfile' \
    'JAVA_TOOL_OPTIONS=-"D"x=y|JAVA_TOOL_OPTIONS holds -D' \
    'JAVA_TOOL_OPTIONS=-XX:AOTMode="create"|JAVA_TOOL_OPTIONS holds -XX:AOTMode=create' \
    "JDK_JAVA_OPTIONS='-version'|JDK_JAVA_OPTIONS holds -version" \
    "MAVEN_OPTS=$(printf -- '-Xmx1g\t-version')|MAVEN_OPTS holds -version" \
    'MAVEN_OPTS=--version|MAVEN_OPTS holds --version' \
    'MAVEN_OPTS=-help|MAVEN_OPTS holds -help' \
    'MAVEN_OPTS=--help|MAVEN_OPTS holds --help' \
    'MAVEN_OPTS=-h|MAVEN_OPTS holds -h' \
    'MAVEN_OPTS=-X|MAVEN_OPTS holds -X' \
    'MAVEN_OPTS=--help-extra|MAVEN_OPTS holds --help-extra' \
    'MAVEN_OPTS=-d|MAVEN_OPTS holds -d' \
    'MAVEN_OPTS=--describe-module|MAVEN_OPTS holds --describe-module' \
    'MAVEN_OPTS=--validate-modules|MAVEN_OPTS holds --validate-modules' \
    'MAVEN_OPTS=-jar|MAVEN_OPTS holds -jar' \
    'MAVEN_OPTS=-m|MAVEN_OPTS holds -m' \
    'MAVEN_OPTS=--module|MAVEN_OPTS holds --module' \
    'MAVEN_OPTS=-XX:+JVMCIPrintProperties|MAVEN_OPTS holds -XX:+JVMCIPrintProperties' \
    'MAVEN_OPTS=-javaagent:/x.jar|MAVEN_OPTS holds -javaagent' \
    'JDK_JAVA_OPTIONS=-agentpath:/x.so|JDK_JAVA_OPTIONS holds -agentpath' \
    'MAVEN_OPTS=-agentlib:jdwp=transport=dt_socket|MAVEN_OPTS holds -agentlib' \
    'JAVA_TOOL_OPTIONS=-Xrunjdwp:transport=dt_socket|JAVA_TOOL_OPTIONS holds -Xrun' \
    'MAVEN_OPTS=-Xlog:help|MAVEN_OPTS holds -Xlog:help' \
    'MAVEN_OPTS=-XX:StartFlightRecording:help|MAVEN_OPTS holds -XX:StartFlightRecording:help' \
    'JAVA_TOOL_OPTIONS=-Xmx1g -XX:StartFlightRecording=help|JAVA_TOOL_OPTIONS holds -XX:StartFlightRecording=help' \
    'MAVEN_OPTS=-Dfoo=help|MAVEN_OPTS holds -D'; do
    norecord "${spec#*|} (it can skip tests)" "${spec%%|*}" || return 1
    : >"$HOOK_LOG"
  done
  norecord "MAVEN_OPTS holds -version (it can skip tests)" LC_ALL=C.UTF-8 $'MAVEN_OPTS=\xe9 -version' || return 1 # invalid byte, UTF-8 locale
  : >"$HOOK_LOG"
  norecord "PYTEST_ADDOPTS is set (it can deselect tests)" "PYTEST_ADDOPTS=-k x" || return 1
  : >"$HOOK_LOG"
  norecord "PYTEST_PLUGINS is set (it can deselect tests)" PYTEST_PLUGINS=x || return 1
  : >"$HOOK_LOG"
  norecord "COVERAGE_RCFILE is set (it can skew coverage)" COVERAGE_RCFILE=x || return 1
  : >"$HOOK_LOG"
  norecord "COVERAGE_FORCE_CONFIG is set (it can skew coverage)" COVERAGE_FORCE_CONFIG=x || return 1
  : >"$HOOK_LOG"
  norecord "PYTHONOPTIMIZE is set (it can strip asserts)" PYTHONOPTIMIZE=1 || return 1
  : >"$HOOK_LOG"
  norecord "JAVA_TOOL_OPTIONS holds -D (it can skip tests)" 'JAVA_TOOL_OPTIONS=-Xmx1g "-Dx=a b"' || return 1
  : >"$HOOK_LOG"
  if ! unwarned; then
    gate MAVEN_OPTS='-Xmx1g -XX:-DisableExplicitGC' # no option starts with -D: recorded
    [[ $rc == 0 && $out == "make gate: recorded"* ]] || return 1
    rm -f "$(rec)"
    : >"$HOOK_LOG"
    gate MAVEN_OPTS='-Xmx1g -Xss1m -Xshare:auto -XX:AOTMode=auto --module-path=x -showversion -da -XX:-DisableExplicitGC -XX:+PrintFlagsFinal -XshowSettings:all -Xlog:gc -verbose:gc --add-opens=java.base/java.lang=ALL-UNNAMED -ea' # none ends java, reads a file or loads code
    [[ $rc == 0 && $out == "make gate: recorded"* ]] || return 1
    rm -f "$(rec)"
    : >"$HOOK_LOG"
  fi
  # Maven runs a mavenrc file unless MAVEN_SKIP_RC is non-empty. A machine-wide
  # one cannot be moved, so it is named first in the reason, as the gate does.
  local f lead="" ok=0
  for f in /usr/local/etc/mavenrc /etc/mavenrc; do
    [[ ! -e $f ]] || lead="$lead$f exists, and Maven runs it (it can skip tests); "
  done
  echo 'MAVEN_OPTS=-DskipTests' >"$HOME/.mavenrc"
  norecord "$lead$HOME/.mavenrc exists, and Maven runs it (it can skip tests)" || ok=1
  : >"$HOOK_LOG"
  gate MAVEN_SKIP_RC=1 # the launcher skips every rc file: recorded
  [[ $rc == 0 && $out == "make gate: recorded"* ]] || ok=1
  rm -f "$HOME/.mavenrc" "$(rec)"
  [[ $ok == 0 ]] || return 1
  : >"$HOOK_LOG"
  settings_xml props
  norecord "${lead}$HOME/.m2/settings.xml sets profile properties (they can skip tests)" || ok=1
  rm -f "$HOME/.m2/settings.xml"
  [[ $ok == 0 ]] || return 1
  : >"$HOOK_LOG"
  settings_xml benign # a mirror, and properties only in a comment: recorded
  gate
  [[ $rc == 0 && ( $out == "make gate: recorded"* || -n $lead ) ]] || ok=1
  rm -f "$HOME/.m2/settings.xml"
  [[ -z $lead ]] || echo "SKIP: a machine-wide mavenrc exists; not asserting the benign settings.xml is recorded" >&2
  [[ $ok == 0 ]] || return 1
  : >"$HOOK_LOG"
  mkdir -p "$HOME/.m2"
  : >"$HOME/.m2/extensions.xml" # any content, and MAVEN_SKIP_RC does not stop Maven loading it
  norecord "${lead}$HOME/.m2/extensions.xml exists, and Maven loads its core extensions (they can skip tests)" MAVEN_SKIP_RC= || ok=1
  : >"$HOOK_LOG"
  norecord "$HOME/.m2/extensions.xml exists, and Maven loads its core extensions (they can skip tests)" MAVEN_SKIP_RC=1 || ok=1
  rm -f "$HOME/.m2/extensions.xml"
  [[ $ok == 0 ]]
}
case_gate_no_reflog() {
  fresh
  rm "$clone/.git/logs/HEAD"
  norecord "no HEAD reflog (core.logAllRefUpdates), so a HEAD move could not be detected"
}
case_gate_nested() { # a project below the top level does not speak for it
  fresh
  mkdir "$clone/sub"
  cp "$clone/Makefile" "$clone/sub/"
  g add sub
  g commit -q --no-verify -m sub
  run env PROJECT_ROOT="$clone/sub" "$root/scripts/gate.sh"
  [[ $rc == 0 && $out == "NOTE: make gate passed but did not record HEAD: the project is not the git top level, whose gate pre-push runs." &&
    ! -e $(rec) ]] && logged "$both"
}
case_gate_tree_changed() {
  fresh
  norecord "the tree changed during the run" DURING='echo dirt >untracked'
}
case_gate_head_moved() { # and came back to the same SHA; and stayed moved
  fresh
  local before
  before=$(g rev-parse HEAD)
  norecord "HEAD moved during the run" DURING='git commit -q --no-verify --allow-empty -m tmp && git reset -q --hard HEAD~1' || return 1
  [[ $(g rev-parse HEAD) == "$before" ]] || return 1
  : >"$HOOK_LOG"
  norecord "HEAD moved during the run" DURING='git commit -q --no-verify --allow-empty -m tmp'
}
case_gate_outer_flags() { # an outer make -i, or a MAKEFILES .IGNORE:, must not reach the stages
  fresh
  run env FAIL=test make -i -s -f Makefile -f "$root/make/common.mk" gate
  [[ $out == *"INTENDED test FAILURE"* && ! -e $(rec) ]] || return 1
  echo .IGNORE: >"$work/ignore.mk"
  gate FAIL=test MAKEFILES="$work/ignore.mk"
  [[ $rc != 0 && ! -e $(rec) ]] || return 1
  gate FAIL=test GNUMAKEFLAGS=-i # read by GNU make 4
  [[ $rc != 0 && ! -e $(rec) ]]
}
case_gate_record_directory() {
  fresh
  mkdir "$(rec)"
  gate
  [[ $rc == 0 && $err == "WARNING: make gate passed but could not record HEAD in .git/devkit-verified-head." &&
    -z $(ls -A "$(rec)") ]] && ! compgen -G "$clone/.git/devkit-verified-head.*" >/dev/null
}
case_gate_reftable() {
  if ! git init -q --ref-format=reftable "$work/probe" 2>/dev/null; then
    echo "NOTE the reftable case is skipped: this git cannot make a reftable repository" >&2
    return 0
  fi
  fresh
  rm -rf "$clone"
  git clone -q --ref-format=reftable "$work/case/origin.git" "$clone"
  ln -s "$work/cache/$pin" "$clone/.devkit"
  gate
  [[ $rc == 0 && $out == "NOTE: make gate passed but did not record HEAD: the reftable ref backend"* && ! -e $(rec) ]]
}
case_gate_worktree() { # a linked worktree's record is its own
  fresh
  install
  g commit -q --no-verify --allow-empty -m two
  g worktree add -q --detach "$work/case/wt" >/dev/null 2>&1 # its post-checkout notice
  git -C "$work/case/wt" commit -q --no-verify --allow-empty -m three
  g reset -q --hard "$(git -C "$work/case/wt" rev-parse HEAD)"
  run env PROJECT_ROOT="$work/case/wt" "$root/scripts/gate.sh"
  [[ $rc == 0 && $out == "make gate: recorded"* && -f $clone/.git/worktrees/wt/devkit-verified-head && ! -e $(rec) ]] || return 1
  : >"$HOOK_LOG"
  say git push -q origin main
  [[ $rc == 0 && $out != *skipping* ]] && logged "$both"
}

t "install writes five executable stamped copies" case_install
t "a second install changes nothing and says so" case_idempotent
t "a stale or non-executable copy is refreshed" case_stale_refreshed
t "a foreign hook is kept; the lines install advises run the gates" case_foreign_kept
t "a dangling foreign symlink is never written through" case_dangling_symlink
t "an orphaned side copy is removed once the hook is ours again" case_orphan_removed
t "copies a hook manager moved to .legacy/.old are refreshed in place" case_moved_aside_refreshed
t "a hooks path inside the work tree is refused" case_refuse_work_tree
t "a hooks path outside the git directory is refused" case_refuse_outside
t "a hooks path inside the git directory is accepted" case_accept_git_dir
t "a ~ in core.hooksPath is expanded" case_tilde
t "make hooks and make check-hooks run the script" case_make_targets
t "the rendered hooks are shellcheck-clean" case_shellcheck
t "switching to and merging a branch runs none of its code" case_switch_runs_nothing
t "pre-commit blocks a commit when lint-repo fails" case_pre_commit_blocks
t "pre-commit's gate sees no GIT_INDEX_FILE or GIT_DIR" case_pre_commit_env
t "pre-commit: outer make flags do not reach lint-repo" case_pre_commit_outer_flags
t "--no-verify bypasses pre-commit" case_no_verify
t "pre-push runs lint-repo and test, and blocks on a failure" case_pre_push
t "pre-push warns on a ref that is not HEAD and on a dirty tree" case_pre_push_warns
t "pre-push ignores a deletion-only push" case_pre_push_deletion
t "pre-push installed directly exits 0 on zero refs" case_pre_push_no_refs
t "pre-push.devkit with zero refs runs the gate" case_pre_push_side_no_refs
t "pre-push ignores ONLY and says so" case_pre_push_only
t "gate.sh and pre-push define the JVM options screen, the settings.xml checks, ignored_mvn, ignored_pytest, pytest_skips, printable, pathspec_git, strictly_clean, clean_filters and the POM profile scan identically" case_jvm_screen_parity
t "pre-push warns on variables, JVM options, a mavenrc, a settings.xml with properties, ~/.m2/extensions.xml and ignored .mvn/ files that can skip or deselect tests, and still gates" case_pre_push_environment
t "pre-push warns on a settings.xml activeProfile it does not define and on ignored .mvn/ files, not on a directory at ~/.m2/extensions.xml" case_pre_push_home_files
t "pre-push warns on POM profiles activated by an environment variable or an untracked file, in modules and parents too, and still gates" case_pre_push_poms
t "pre-push warns on ignored files pytest reads, not on a venv's or a nested repository's, and still gates" case_pre_push_ignored_pytest
t "pre-push: outer make flags do not reach the stages" case_pre_push_outer_flags
t "a failing gate part fails the hook, a failing notice never does" case_part_status
t "a copy does nothing outside a devkit project" case_outside_project
t "the pin notice speaks on a mismatch" case_pin_mismatch
t "the pin notice is silent when matched and on a file checkout" case_pin_silent
t "the pin notice ignores a devkit.toml symlink" case_pin_symlinked_toml
t "stale base: warns when the base tip is missing from HEAD" case_stale_base
t "stale base: silent on a current base and a detached HEAD" case_stale_base_silent
t "stale base: uses origin/HEAD's target" case_stale_base_origin_head
t "stale base: warns when no fetch is recent" case_stale_fetch
t "status names missing hooks without failing" case_status_missing
t "status reports stale and non-executable copies" case_status_stale
t "status is silent after install" case_status_silent
t "status does not nag about a foreign hook, but compares its side copy" case_status_foreign
t "status is silent with CI=true" case_status_ci
t "status is silent outside a work tree" case_status_no_work_tree
t "an equal symlink to a tracked file is replaced, never trusted" case_symlink_tracked
t "a symlinked side copy is replaced with a regular file" case_symlink_side
t "an ours-looking symlink to an outside file is replaced" case_symlink_ours_outside
t "a hooks path with .. below the git directory is refused" case_refuse_dotdot
t ".git/hooks symlinked into the work tree or outside is refused" case_hooks_dir_symlink
t "a project below the git top level is refused, and status says so once" case_below_top
t "make hooks from a linked worktree installs into the common hooks dir" case_worktree
t "make -n check names the hooks advisory" case_make_n_check
t "pre-push run with GIT_DIR/GIT_INDEX_FILE set gates without them" case_pre_push_env
t "status names a hooks path outside the git directory once" case_status_outside
t "a side path install did not write is refused" case_side_refused
t "an orphaned side copy goes when a moved-aside copy is ours" case_moved_aside_orphan

t "make gate records a clean passing HEAD, and pre-push then skips its gate" case_gate_records_and_skips
t "pre-push skip stays silent under ONLY" case_gate_skip_ignores_only
t "pre-push still gates after another commit, and on any not strictly clean tree" case_gate_pre_push_reruns
t "make gate: a failing stage fails, records nothing and removes the old record" case_gate_failure
t "make gate refuses ONLY, also on the make command line" case_gate_only
t "make gate records nothing from a tree not strictly clean at the start" case_gate_dirty_start
t "make gate records nothing under MAVEN_ARGS, MAVEN_BASEDIR, PYTEST_ADDOPTS, PYTEST_PLUGINS, COVERAGE_RCFILE, COVERAGE_FORCE_CONFIG, PYTHONOPTIMIZE, a JVM option that skips or replaces the tests, a mavenrc, a settings.xml with properties or ~/.m2/extensions.xml" case_gate_environment
t "make gate records nothing for a settings.xml activeProfile it does not define, but does for a directory at ~/.m2/extensions.xml" case_gate_home_files
t "make gate records nothing while git ignores a .mvn/ file Maven reads, but does under .mvn/wrapper/ and for a committed one" case_gate_ignored_mvn
t "make gate records nothing for an ignored .mvn/ file that appeared during the run" case_gate_ignored_mvn_during
t "make gate records nothing while git ignores a file pytest reads, but does for a venv's conftest.py, a nested repository, a committed file and a project with no tracked root pyproject.toml" case_gate_ignored_pytest
t "make gate counts a conftest.py above a project directory, fails closed on a project directory name with a newline and on a failing listing, and drops __pycache__, a quoted path in a venv and directory-pattern venvs" case_gate_ignored_pytest_screen
t "make gate counts an ignored venv marker beside tracked files and test modules, and a project under BASHOPTS=nocasematch, and drops a skipped directory's or an untracked environment's" case_gate_ignored_pytest_files
t "make gate reads POMs and files the same under GIT_ICASE_PATHSPECS and GIT_LITERAL_PATHSPECS" case_gate_pathspec_switches
t "make gate counts an ignored root conftest.py, a member named build and a test* directory, and ignores GIT_LITERAL_PATHSPECS" case_gate_ignored_pytest_members
t "an inherited GIT_LITERAL_PATHSPECS does not hide a skip-worktree file from make gate or pre-push" case_gate_literal_pathspecs
t "make gate records nothing for an ignored file pytest reads that appeared during the run" case_gate_ignored_pytest_during
t "make gate records nothing while a clean filter applies to a tracked file (also through a C-quoted path or process), but does for an unconfigured driver, an unused one and an unset attribute" case_gate_clean_filter
t "make gate records nothing for a clean filter that applied during the run" case_gate_clean_filter_during
t "make gate names every configured clean driver" case_gate_clean_filter_two
t "pre-push still gates when a clean filter hides an edit from a recorded HEAD" case_pre_push_clean_filter
t "make gate sees an edit under a stat a since-removed clean filter validated" case_gate_stale_stat
t "pre-push still gates in the same case, from a recorded HEAD" case_pre_push_stale_stat
t "make gate records nothing for a clean filter configured in a submodule" case_gate_clean_filter_submodule
t "make gate records nothing for the ident attribute" case_gate_ident
t "make gate names submodule and top-level drivers whose labels collide" case_gate_dedup_collisions
t "make gate records nothing for a gitlink without a .gitmodules entry, and says so" case_gate_gitlink_unlisted
t "make gate sees an edit a replace ref hides, in a submodule too" case_gate_replace_ref
t "make gate sees an edit an fsmonitor hook missed" case_gate_fsmonitor
t "pre-push still gates when an fsmonitor hook hides an edit from a recorded HEAD" case_pre_push_fsmonitor
t "make gate unsets git's local environment variables, so GIT_INDEX_FILE and GIT_CONFIG_PARAMETERS cannot hide anything" case_gate_env
t "make gate records nothing for a POM profile activated by an environment variable, but does for an unset or empty one and a commented-out profile" case_gate_pom_env
t "make gate reads the POMs of modules, profile modules and parents inside the tree, and nothing outside it" case_gate_pom_scope
t "make gate records nothing for a POM profile activated by an untracked or ignored file or a property path, but does for a tracked or absent one" case_gate_pom_files
t "make gate records nothing for a POM profile file that appeared during the run" case_gate_pom_during
t "make gate reads every POM of a queue, two profiles of one POM, and reports an env variable once" case_gate_pom_queue
t "make gate counts a set or empty \${env.N} in a path and still checks the rest of the path" case_gate_pom_env_refs
t "make gate reads tags with whitespace and attributes, and leaves <names> alone" case_gate_pom_tags
t "make gate counts interpolated names and values, paths it cannot resolve, and ignores .git" case_gate_pom_forms
t "make gate counts an untracked POM, a module with a property or outside the tree, and follows default parents" case_gate_pom_reactor
t "make gate counts a processing instruction and a -f in .mvn/maven.config" case_gate_pom_text
t "make gate refuses to record when the POM scan fails, and pre-push warns" case_gate_pom_scan_failure
t "make gate records nothing without a HEAD reflog" case_gate_no_reflog
t "make gate records nothing for a project below the git top level" case_gate_nested
t "make gate records nothing when the tree changed during the run" case_gate_tree_changed
t "make gate records nothing when HEAD moved during the run, back or not" case_gate_head_moved
t "make gate: outer make flags do not reach the stages" case_gate_outer_flags
t "make gate warns when the record path is a directory, and exits 0" case_gate_record_directory
t "make gate records nothing in a reftable repository" case_gate_reftable
t "make gate's record is per worktree" case_gate_worktree

[[ $fails == 0 ]] || {
  echo "$fails case(s) failed"
  exit 1
}
