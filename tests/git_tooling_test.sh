#!/usr/bin/env bash
# Hermetic tests for scripts/branch.sh and scripts/rebase.sh: branch refuses to
# reset an existing branch over uncommitted tracked changes or an untracked
# file in the reset's way, leaving origin untouched, and otherwise resets and
# pushes it; rebase rebases locally and leaves the remote alone.
# Per case, a fresh bare origin and a clone of it; git reads no user or system
# config. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars) CI REVISION GIT_CEILING_DIRECTORIES SSH_AUTH_SOCK
export HOME=$work/home GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=$HOME/.gitconfig # never the caller's, nor XDG's
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export LC_ALL=C
mkdir -p "$HOME"
git config --global init.defaultBranch main

origin=$work/origin.git clone=$work/clone
fresh() { # a new bare origin and a clone of it, one commit on main
  rm -rf "$origin" "$clone"
  git init -q --bare "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  echo one >"$clone/file"
  echo shared >"$clone/shared"
  git -C "$clone" add file shared
  git -C "$clone" commit -q -m one
  git -C "$clone" push -q origin main
}
g() { git -C "$clone" "$@"; }
commit_on() { # commit_on FILE TEXT: a commit changing FILE on the current branch
  echo "$2" >"$clone/$1"
  g add "$1"
  g commit -q -m "$2"
}
run() { # run SCRIPT ANSWER...: one answer per line on stdin; sets rc, out and err
  local s=$1
  shift
  rc=0
  out=$(cd "$clone" && env PROJECT_ROOT="$clone" "$root/scripts/$s" < <(printf '%s\n' "$@") 2>"$work/err") || rc=$?
  err=$(<"$work/err")
}
remote_ref() { git -C "$origin" rev-parse -q --verify "refs/heads/$1" || echo absent; }
fails=0
t() { # t NAME COMMAND...: report whether COMMAND succeeds
  local name=$1
  shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name (rc=$rc, stdout: $out, stderr: $err)"
    fails=$((fails + 1))
  fi
}

case_branch_dirty() { # a tracked modification the checkout would carry is not reset away
  fresh
  g branch feature
  g checkout -q -b work
  echo modified >>"$clone/shared"
  run branch.sh feature origin/main
  [[ $rc == 1 && $err == *"Uncommitted changes in the working tree would be lost by the reset to origin/main; commit or stash them first."* ]] &&
    [[ $(g rev-parse --abbrev-ref HEAD) == work ]] &&
    [[ $(<"$clone/shared") == $'shared\nmodified' ]] &&
    [[ $(remote_ref feature) == absent ]]
}
case_branch_staged() { # a staged-only change is refused too
  fresh
  g branch feature
  g checkout -q -b work
  echo modified >>"$clone/shared"
  g add shared
  run branch.sh feature origin/main
  [[ $rc == 1 && $err == *"Uncommitted changes in the working tree"* ]] &&
    [[ $(g rev-parse --abbrev-ref HEAD) == work ]] &&
    [[ $(g diff --cached --name-only) == shared ]] &&
    [[ $(remote_ref feature) == absent ]]
}
case_branch_current() { # the target is the current branch, with a tracked edit
  local before
  fresh
  g checkout -q -b feature
  commit_on file stale
  g push -q origin feature
  before=$(g rev-parse feature)
  echo modified >>"$clone/shared"
  run branch.sh feature origin/main
  [[ $rc == 1 && $err == *"Uncommitted changes in the working tree"* ]] &&
    [[ $(g rev-parse feature) == "$before" ]] &&
    [[ $(<"$clone/shared") == $'shared\nmodified' ]] &&
    [[ $(remote_ref feature) == "$before" ]]
}
case_branch_remote_only() { # a target only on origin is refused with a tracked edit
  fresh
  g checkout -q -b feature
  g push -q origin feature
  g checkout -q main
  g branch -q -D feature
  echo modified >>"$clone/shared"
  run branch.sh feature origin/main
  [[ $rc == 1 && $err == *"Uncommitted changes in the working tree"* ]] &&
    ! g show-ref --verify --quiet refs/heads/feature &&
    [[ $(g rev-parse --abbrev-ref HEAD) == main ]] &&
    [[ $(remote_ref feature) == "$(g rev-parse main)" ]]
}
case_branch_untracked() { # an untracked file the source tracks is not overwritten
  fresh
  g branch feature
  commit_on new theirs
  g push -q origin main
  g checkout -q -b work feature
  echo mine >"$clone/new"
  run branch.sh feature origin/main
  [[ $rc != 0 ]] &&
    [[ $(<"$clone/new") == mine ]] &&
    [[ $(remote_ref feature) == absent ]]
}
case_branch_clean() { # a clean tree: the existing branch is reset to the source and pushed
  fresh
  g checkout -q -b feature
  commit_on file stale
  g push -q origin feature
  g checkout -q main
  run branch.sh feature origin/main
  [[ $rc == 0 ]] &&
    [[ $(g rev-parse feature) == "$(g rev-parse origin/main)" ]] &&
    [[ $(git -C "$origin" rev-parse feature) == "$(g rev-parse origin/main)" ]]
}
case_rebase_local() { # rebase rewrites the local branch only
  local remote
  fresh
  g checkout -q -b feature
  commit_on other mine
  g push -q -u origin feature
  remote=$(git -C "$origin" rev-parse feature)
  g checkout -q main
  commit_on file two
  g push -q origin main
  g checkout -q feature
  run rebase.sh origin/main
  [[ $rc == 0 && $out == *"Rebase completed; review it, then push with git push --force-with-lease --force-if-includes."* ]] &&
    [[ $(git -C "$origin" rev-parse feature) == "$remote" ]] &&
    [[ $(g rev-parse feature^) == "$(g rev-parse origin/main)" ]]
}

t "branch onto an existing branch refuses uncommitted tracked changes" case_branch_dirty
t "branch refuses a staged-only change" case_branch_staged
t "branch refuses a tracked edit when the target is the current branch" case_branch_current
t "branch refuses a tracked edit when the target is only on origin" case_branch_remote_only
t "branch refuses where an untracked file is in the reset's way" case_branch_untracked
t "branch onto an existing branch resets and pushes it on a clean tree" case_branch_clean
t "rebase rebases locally and does not push" case_rebase_local

[[ $fails == 0 ]] || {
  echo "$fails case(s) failed"
  exit 1
}
