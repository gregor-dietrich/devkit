#!/usr/bin/env bash
# Hermetic tests for devkitw: a temp HOME and cache, a local bare repo with
# two annotated tags whose commits carry the devkitw under test, and a temp
# project pinned to them over file://. Prints PASS/FAIL per case.
set -euo pipefail

wrapper=$(cd "$(dirname "$0")/.." && pwd)/devkitw
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # word splitting is intended
unset $(git rev-parse --local-env-vars)
export HOME=$work/home XDG_CACHE_HOME=$work/cache GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$HOME" "$work/proj" "$work/empty" "$work/nogit" "$work/racy"
proj=$work/proj cache=$XDG_CACHE_HOME/devkit
nowhere=file://$work/missing.git bare=$work/devkit.git

# The served devkit: v0.0.1 -> c1, v0.0.2 -> c2, both carrying devkitw.
git init -q -b main "$work/src"
cp "$wrapper" "$work/src/devkitw"
git -C "$work/src" add devkitw
git -C "$work/src" commit -q -m one
git -C "$work/src" tag -a v0.0.1 -m v0.0.1
c1=$(git -C "$work/src" rev-parse HEAD)
git -C "$work/src" commit -q --allow-empty -m two
git -C "$work/src" tag -a v0.0.2 -m v0.0.2
c2=$(git -C "$work/src" rev-parse HEAD)
git clone -q --bare "$work/src" "$bare"
cp "$wrapper" "$proj/devkitw"
printf '#!/bin/sh\ntouch "%s/git-called"\nexit 97\n' "$work" >"$work/nogit/git"
# A mv that lets a concurrent run win the race to the target first.
# shellcheck disable=SC2016 # the $1, $2, $@ belong to the generated script
printf '#!/bin/sh\ncp -R "$1" "$2"\nexec %s "$@"\n' "$(command -v mv)" \
  >"$work/racy/mv"
chmod +x "$work/nogit/git" "$work/racy/mv"

pin() { # pin URL MIRROR VERSION COMMIT (an empty MIRROR is omitted)
  local mirror=${2:+"mirror= \"$2\""}
  cat >"$proj/devkit.toml" <<EOF
[other]
version = "v9.9.9"

# devkit pin
[devkit]
url   =   "$1"
$mirror
# commit = "0000000000000000000000000000000000000000"
version="$3"
commit = "$4"  # the commit the tag resolves to
EOF
}

cwd=$proj
run() { # sets rc, out, err
  rc=0
  out=$(cd "$cwd" && "$proj/devkitw" "$@" 2>"$work/err") || rc=$?
  err=$(<"$work/err")
}
run_with() { # run_with DIR ARGS...: run with DIR first on PATH
  local path=$PATH
  PATH=$1:$PATH
  shift
  run "$@"
  PATH=$path
}
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
linked() { [ "$(readlink "$proj/.devkit")" = "$cache/$1" ]; }
ok_at() { [ "$rc" = 0 ] && [ "$out" = "$cache/$1" ] && linked "$1"; }
one_line_error() { # non-zero, one stderr line, prefixed
  [[ $rc != 0 && $err == "devkitw: "* && $err != *$'\n'* ]]
}
no_temp_left() { ! compgen -G "$cache/.tmp.*" >/dev/null; }

case_miss() {
  pin "file://$bare" "" v0.0.1 "$c1"
  run path
  ok_at "$c1" && [ -z "$err" ] && [ "$(cat "$out/.devkit-commit")" = "$c1" ] &&
    cmp -s "$out/devkitw" "$wrapper" && [ ! -e "$out/.git" ] && no_temp_left
}
case_hit_offline() {
  pin "$nowhere" "$nowhere" v0.0.1 "$c1"
  run_with "$work/nogit"
  ok_at "$c1" && [ ! -e "$work/git-called" ]
}
case_wrong_commit() {
  pin "file://$bare" "" v0.0.1 "$c2"
  run path
  one_line_error && [ ! -e "$cache/$c2" ] && no_temp_left
}
case_mirror() {
  rm -rf "${cache:?}/$c1"
  pin "$nowhere" "file://$bare" v0.0.1 "$c1"
  run path
  ok_at "$c1" && [ -f "$cache/$c1/.devkit-commit" ]
}
case_unreachable() {
  rm -rf "${cache:?}/$c1"
  pin "$nowhere" "$nowhere" v0.0.1 "$c1"
  run path
  one_line_error && [ ! -e "$cache/$c1" ] && no_temp_left
}
case_repoint() {
  pin "file://$bare" "" v0.0.2 "$c2"
  run path
  ok_at "$c2"
}
case_not_a_link() { # and leaves the directory alone
  rm "$proj/.devkit"
  mkdir "$proj/.devkit"
  touch "$proj/.devkit/mine"
  run path
  one_line_error && [ -f "$proj/.devkit/mine" ]
  local ok=$?
  rm -rf "$proj/.devkit"
  return "$ok"
}
case_no_toml() {
  cwd=$work/empty
  run path
  cwd=$proj
  one_line_error
}
case_bad_commit() { # rejected before any git call
  pin "file://$bare" "" v0.0.2 "$(tr a-f A-F <<<"$c2")"
  run_with "$work/nogit" path
  one_line_error || return 1
  pin "file://$bare" "" v0.0.2 "${c2:1}"
  run_with "$work/nogit" path
  one_line_error && [ ! -e "$work/git-called" ]
}
case_self_check() {
  pin "file://$bare" "" v0.0.2 "$c2"
  run self-check
  [ "$rc" = 0 ] && [ -z "$out" ] || return 1
  echo '# local edit' >>"$proj/devkitw"
  run self-check
  cp "$wrapper" "$proj/devkitw"
  [ "$rc" = 1 ] && one_line_error
}
case_unknown_arg() {
  run frobnicate
  [ "$rc" = 2 ] && [[ $err == "devkitw: "* ]]
}
case_hook_env() { # a pre-commit hook exports the caller's repository
  rm -rf "${cache:?}/$c2"
  export GIT_DIR=$work/caller.git GIT_INDEX_FILE=$work/caller-index
  run path
  unset GIT_DIR GIT_INDEX_FILE
  ok_at "$c2" && [ ! -e "$work/caller.git" ] && [ ! -e "$work/caller-index" ]
}
case_race() { # another run moved its copy into place just before our mv
  rm -rf "${cache:?}/$c2"
  run_with "$work/racy" path
  ok_at "$c2" && no_temp_left && ! compgen -G "$cache/$c2/.tmp.*" >/dev/null
}
case_incomplete() {
  rm -rf "${cache:?}/$c2"
  mkdir "$cache/$c2"
  run path
  one_line_error && rmdir "$cache/$c2"
}

t "1 miss fetches, prints the path, marks and links" case_miss
t "2 hit needs no remote and no git" case_hit_offline
t "3 wrong commit fails and caches nothing" case_wrong_commit
t "4 unreachable url falls back to the mirror" case_mirror
t "4b both remotes unreachable fails and caches nothing" case_unreachable
t "5 new pin repoints the link" case_repoint
t "6 .devkit that is a directory fails" case_not_a_link
t "7a missing devkit.toml fails" case_no_toml
t "7b malformed commit fails" case_bad_commit
t "8 self-check: 0 when identical, 1 when the copy differs" case_self_check
t "9 unknown argument exits 2" case_unknown_arg
t "10 a git hook's GIT_DIR/GIT_INDEX_FILE are left alone" case_hook_env
t "11 a concurrent run's copy wins; ours is discarded" case_race
t "12 a cache dir without its marker fails" case_incomplete

[ "$fails" = 0 ] || {
  echo "$fails case(s) failed"
  exit 1
}
