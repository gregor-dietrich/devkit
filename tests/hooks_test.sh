#!/usr/bin/env bash
# Hermetic tests for scripts/hooks.sh and the hooks it installs. Per case, a
# fresh clone of a local bare origin holding a stub project: devkit.toml with
# a pin, .devkit linking to it, and a Makefile whose lint-repo and test
# targets log to $HOOK_LOG and fail when FAIL names them. DEVKIT is this
# repository; git reads no user or system config. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars) CI FAIL GIT_CEILING_DIRECTORIES
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
  $'\t@[ "$${FAIL-}" != "$@" ] || { echo "INTENDED $@ FAILURE"; exit 23; }' >"$src/Makefile"
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
t "--no-verify bypasses pre-commit" case_no_verify
t "pre-push runs lint-repo and test, and blocks on a failure" case_pre_push
t "pre-push warns on a ref that is not HEAD and on a dirty tree" case_pre_push_warns
t "pre-push ignores a deletion-only push" case_pre_push_deletion
t "pre-push installed directly exits 0 on zero refs" case_pre_push_no_refs
t "pre-push.devkit with zero refs runs the gate" case_pre_push_side_no_refs
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

[[ $fails == 0 ]] || {
  echo "$fails case(s) failed"
  exit 1
}
