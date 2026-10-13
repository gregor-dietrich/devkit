#!/usr/bin/env bash
# Hermetic tests for scripts/tag.sh: the tag shape, the suggestion, and the
# refusals (HEAD not the tip of origin's default branch, a dirty tree), and
# for scripts/untag.sh's default. Per case, a fresh bare origin and a clone of
# it; tags are really signed, with a throwaway SSH key. git reads no user or
# system config. Prints PASS/FAIL per case. Needs git 2.34 or later (SSH
# signing) and ssh-keygen (OpenSSH 8.1 or later).
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
ssh-keygen -q -t ed25519 -N '' -C '' -f "$work/key"
git config --global gpg.format ssh
git config --global user.signingKey "$work/key"
git config --global init.defaultBranch main

origin=$work/origin.git clone=$work/clone
fresh() { # a new bare origin and a clone of it, one commit on main
  rm -rf "$origin" "$clone"
  git init -q --bare "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  echo one >"$clone/file"
  git -C "$clone" add file
  git -C "$clone" commit -q -m one
  git -C "$clone" push -q origin main
}
g() { git -C "$clone" "$@"; }
seed() {
  local t
  for t in "$@"; do g tag "$t"; done
  g push -q origin --tags
}
tags() { git -C "$1" tag -l | sort | tr '\n' ' '; }
script=tag.sh # a case sets its own with local
run() { run_in <(printf '%s\n' "$1") "${@:2}"; } # run LINE [VAR=value...]: LINE answers the prompt
run_in() { # run_in FILE [VAR=value...]: $script in the clone, reading FILE; sets rc, out, err and the tags before
  local in=$1
  shift
  before="$(tags "$origin")|$(tags "$clone")"
  rc=0
  out=$(cd "$clone" && env PROJECT_ROOT="$clone" DEVKIT="$root" "$@" "$root/scripts/$script" <"$in" 2>"$work/err") || rc=$?
  err=$(<"$work/err")
}
untouched() { [[ "$(tags "$origin")|$(tags "$clone")" == "$before" ]]; } # no tag created, locally or on origin
refused() { [[ $rc != 0 && $err == *"$1"* ]] && untouched; }
has_tag() { [[ " $(tags "$origin")" == *" $1 "* && " $(tags "$clone")" == *" $1 "* ]]; }
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

# case_suggest EXPECTED SEED...: accepting the default creates EXPECTED, a
# signed annotated tag, locally and on origin.
case_suggest() {
  local want=$1
  shift
  fresh
  seed "$@"
  run ""
  [[ $rc == 0 ]] && has_tag "$want" &&
    [[ $(g cat-file -t "refs/tags/$want") == tag ]] &&
    g cat-file tag "$want" | grep -q 'BEGIN SSH SIGNATURE'
}
case_no_tags() {
  fresh
  run ""
  refused "release tag"
}
case_typed() {
  fresh
  seed v0.5.0
  run "v3.0.0-rc1"
  [[ $rc == 0 ]] && has_tag v3.0.0-rc1
}
case_revision() {
  fresh
  run "" REVISION=1.0.0rc1
  [[ $rc == 0 ]] && has_tag 1.0.0rc1
}
case_ignores_unshaped() { # the latest is the highest release-shaped tag
  fresh
  seed 1.0.0 1.0.0-SNAPSHOT 2.0 junk
  run ""
  [[ $rc == 0 ]] && has_tag 1.0.1
}
case_mixed_prefix() { # git's version sort ranks v0.9.0 above 1.0.0 (contract.md)
  fresh
  seed 1.0.0 v0.9.0
  run ""
  [[ $rc == 0 ]] && has_tag v0.9.1
}
case_bad_shape() { # case_bad_shape VERSION: typed, and as REVISION
  fresh
  seed v0.5.0
  run "$1"
  refused "release tag" || return 1
  run "" REVISION="$1"
  refused "release tag"
}
case_empty_revision_prompts() { # an empty REVISION still prompts
  fresh
  seed v0.5.0
  run "" REVISION=
  [[ $rc == 0 ]] && has_tag v0.5.1
}
case_eof() { # end of input at the prompt (Ctrl-D, no terminal) is no answer
  fresh
  seed v0.5.0
  run_in /dev/null
  refused "No answer"
}
case_revision_named() { # a refused REVISION says where the value came from
  fresh
  run "" REVISION=1.0.0-SNAPSHOT
  refused "(from REVISION)"
}
case_no_remote_head() { # an origin whose HEAD names no branch
  fresh
  git -C "$origin" symbolic-ref HEAD refs/heads/none
  run "1.0.0"
  refused "Cannot read origin's default branch tip"
}
case_head_suffix() { # a ref ending in /HEAD on origin does not hide the tip
  fresh
  g checkout -q -b scratch
  echo scratch >"$clone/file"
  g commit -q -am scratch
  g push -q origin scratch:refs/heads/x/HEAD
  g checkout -q main
  run "1.0.0"
  [[ $rc == 0 ]] && has_tag 1.0.0
}
case_eof_partial() { # an answer without its newline, then end of input, is an answer
  fresh
  run_in <(printf '%s' 1.0.0)
  [[ $rc == 0 ]] && has_tag 1.0.0
}
case_sign_fails() { # a tag that cannot be signed is not created, nor pushed
  fresh
  g config user.signingKey "$work/missing-key"
  run "1.0.0"
  [[ $rc != 0 ]] && untouched
}
case_push_fails() { # a rejected push leaves no tag behind, locally either
  fresh
  printf '#!/bin/sh\nexit 1\n' >"$origin/hooks/pre-receive"
  chmod +x "$origin/hooks/pre-receive"
  run "1.0.0"
  refused "Push failed"
}
case_untag_eof() { # untag at end of input deletes nothing
  local script=untag.sh
  fresh
  seed 1.0.0
  run_in /dev/null
  refused "No answer"
}
case_untag_latest() { # untag defaults to the latest release, an rc sorting before its final
  local script=untag.sh
  fresh
  seed 1.0.0rc1 1.0.0 junk
  run ""
  [[ $rc == 0 && " $(tags "$origin")" != *" 1.0.0 "* && " $(tags "$clone")" != *" 1.0.0 "* ]] &&
    has_tag 1.0.0rc1
}
case_untag_none() { # no release tag, no default, and an empty answer deletes nothing
  local script=untag.sh
  fresh
  seed junk
  run ""
  refused "No tag given"
}
case_behind() {
  fresh
  echo two >"$clone/file"
  g commit -q -am two
  g push -q origin main
  g checkout -q --detach HEAD^
  run "1.0.0"
  refused "tip of origin's default branch" || return 1
  run "" REVISION=1.0.0
  refused "tip of origin's default branch"
}
case_other_branch() {
  fresh
  g checkout -q -b side
  echo side >"$clone/file"
  g commit -q -am side
  g push -q origin side
  run "1.0.0"
  refused "tip of origin's default branch"
}
case_unpushed() { # ahead of origin's tip is not the tip either
  fresh
  echo two >"$clone/file"
  g commit -q -am two
  run "1.0.0"
  refused "tip of origin's default branch"
}
case_dirty() {
  fresh
  echo dirty >>"$clone/file"
  run "1.0.0"
  refused "not clean" || return 1
  run "" REVISION=1.0.0
  refused "not clean"
}
case_untracked_hidden() { # the config does not hide untracked files from the gate
  fresh
  g config status.showUntrackedFiles no
  echo new >"$clone/untracked"
  run "1.0.0"
  refused "not clean"
}
case_untracked() {
  fresh
  echo new >"$clone/untracked"
  run "1.0.0"
  refused "not clean" || return 1
  run "" REVISION=1.0.0
  refused "not clean"
}

t "suggests the next patch of v0.5.0" case_suggest v0.5.1 v0.5.0
t "suggests the next patch of 1.2.3, the highest tag winning" case_suggest 1.2.4 1.2.3 1.2.0 1.1.9
t "orders versions numerically: 1.10.0 is above 1.9.9" case_suggest 1.10.1 1.9.9 1.10.0
t "suggests the next rc of 1.0.0rc1" case_suggest 1.0.0rc2 1.0.0rc1
t "suggests the next rc of v2.0.0-rc3" case_suggest v2.0.0-rc4 v2.0.0-rc3
t "an rc sorts before its final: 1.0.0rc1 and 1.0.0 suggest 1.0.1" case_suggest 1.0.1 1.0.0rc1 1.0.0
t "an rc sorts before its final: v1.0.0-rc2 and v1.0.0 suggest v1.0.1" case_suggest v1.0.1 v1.0.0-rc2 v1.0.0
t "orders rc numbers numerically: 1.0.0rc10 is above 1.0.0rc9" case_suggest 1.0.0rc11 1.0.0rc9 1.0.0rc10
t "no tag, no suggestion, and an empty answer is refused" case_no_tags
t "end of input at the prompt tags nothing" case_eof
t "a refused REVISION is named as the source" case_revision_named
t "tags not release-shaped are ignored" case_ignores_unshaped
t "a v-prefixed tag ranks above a bare one in the suggestion" case_mixed_prefix
t "an answer without a trailing newline is taken" case_eof_partial
t "a tag that cannot be signed is not created" case_sign_fails
t "a rejected push leaves no local tag" case_push_fails
t "a typed version is taken" case_typed
t "REVISION skips the prompt" case_revision
t "an empty REVISION prompts" case_empty_revision_prompts
for v in 1.2 01.2.3 1.2.3-SNAPSHOT 1.2.3rc01 V1.2.3 1.2.3-rc 1.2.3rc 1.2.3.4 v 1.2.3-rc1-x; do
  t "refuses the shape '$v', typed and as REVISION" case_bad_shape "$v"
done
t "refuses when HEAD is behind origin's tip" case_behind
t "refuses when HEAD is a commit not on the default branch" case_other_branch
t "refuses when HEAD is ahead of origin's tip" case_unpushed
t "refuses a tree with a modified file" case_dirty
t "refuses a tree with an untracked file" case_untracked
t "refuses a tree with an untracked file under status.showUntrackedFiles=no" case_untracked_hidden
t "refuses when origin's HEAD names no branch" case_no_remote_head
t "a ref ending in /HEAD on origin is not taken for its HEAD" case_head_suffix
t "untag defaults to the latest release tag, an rc before its final" case_untag_latest
t "untag at end of input deletes nothing" case_untag_eof
t "untag without a release tag has no default and deletes nothing" case_untag_none

[[ $fails == 0 ]] || {
  echo "$fails case(s) failed"
  exit 1
}
