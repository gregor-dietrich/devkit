#!/usr/bin/env bash
# Tests for scripts/lib/sealed_dir.sh: per case, a fresh directory holding a
# stage (a file, a subdirectory with a file). They assert mode bits, not
# whether a write fails, so they hold under root. No network. Prints PASS/FAIL
# per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
# shellcheck source=SCRIPTDIR/../scripts/lib/sealed_dir.sh
. "$root/scripts/lib/sealed_dir.sh"
trap 'sealed_remove "$work"' EXIT
fails=0 case_no=0

stage() { # stage: a stage in $case, set as $stage
  stage=$case/.tmp.stage
  mkdir -p "$stage/sub"
  echo one >"$stage/file"
  echo two >"$stage/sub/file"
}
writable() { [[ -n $(find "$1" ! -type l -perm -u+w) ]]; } # something in the tree is writable
t() { # t NAME COMMAND...: report whether COMMAND succeeds, in a fresh $case
  local name=$1
  shift
  case=$work/case-$((++case_no))
  mkdir "$case"
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    fails=$((fails + 1))
  fi
}

case_placed() {
  stage
  sealed_place "$stage" "$case/dir" &&
    [[ ! -e $stage && $(<"$case/dir/sub/file") == two ]] && ! writable "$case/dir"
}
case_sealed_wins() { # a concurrent run's sealed copy is there first
  mkdir -p "$case/dir/sub"
  echo won >"$case/dir/file"
  chmod -R a-w "$case/dir"
  stage
  sealed_place "$stage" "$case/dir" &&
    [[ ! -e $stage && $(<"$case/dir/file") == won && ! -e $case/dir/${stage##*/} ]]
}
case_writable_wins() { # an older devkit's entry, directories writable
  mkdir -p "$case/dir"
  echo old >"$case/dir/file"
  stage
  # A read-only stage cannot move into another directory (its ".." changes), so
  # mv fails and the function removes the stage; as root mv nests it instead,
  # and the function removes the nested copy. Either way DIR stays as it was.
  sealed_place "$stage" "$case/dir" &&
    [[ ! -e $stage && ! -e $case/dir/${stage##*/} && $(<"$case/dir/file") == old ]]
}
case_move_fails() { # nothing at DIR and its parent missing: nothing won
  stage
  ! sealed_place "$stage" "$case/missing/dir" && [[ -f $stage/file && ! -e $case/missing ]]
}
case_dangling_link() { # a link to nowhere at DIR is no winner: the caller keeps the stage
  ln -s "$case/nowhere" "$case/dir"
  stage
  ! sealed_place "$stage" "$case/dir" && [[ -f $stage/file && -L $case/dir && ! -e $case/nowhere ]] || return 1
  sealed_remove "$stage"
  [[ ! -e $stage ]]
}
case_remove() {
  stage
  chmod -R a-w "$stage"
  sealed_remove "$stage" "$case/never-there" && [[ ! -e $stage ]]
}
case_link_not_followed() {
  mkdir "$case/outside"
  echo out >"$case/outside/file"
  stage
  ln -s ../outside "$stage/link"
  sealed_place "$stage" "$case/dir" &&
    [[ -L $case/dir/link && -n $(find "$case/outside" -perm -u+w) ]] || return 1
  sealed_remove "$case/dir"
  [[ ! -e $case/dir && -f $case/outside/file ]]
}

t "1 a stage is placed with every file and directory read-only" case_placed
t "2 a sealed DIR already placed wins; the stage is removed" case_sealed_wins
t "3 a writable DIR already there wins; the nested stage is removed" case_writable_wins
t "4 a failed move fails and leaves the stage" case_move_fails
t "5 sealed_remove removes a sealed tree; a missing path is no error" case_remove
t "6 a link in the stage is not followed out of it" case_link_not_followed
t "7 a dangling link at DIR is no winner; the stage is left" case_dangling_link

[[ $fails == 0 ]]
