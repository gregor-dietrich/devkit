#!/usr/bin/env bash
# Hermetic tests for devkitw: a temp HOME and cache, a local bare repo with
# signed annotated tags whose commits carry the devkitw under test, and a temp
# project pinned to them over file://. The tags are signed with a test key, so
# the project runs a copy of devkitw that trusts it; the shipped one does not.
# Prints PASS/FAIL per case. Needs git 2.34 or later (SSH signing) and
# ssh-keygen (OpenSSH 8.1 or later).
set -euo pipefail

wrapper=$(cd "$(dirname "$0")/.." && pwd)/devkitw
work=$(mktemp -d)
uncache() { chmod -R u+w "$@" 2>/dev/null || :; rm -rf "$@"; } # sealed trees
trap 'uncache "$work"' EXIT
# shellcheck disable=SC2046 # word splitting is intended
unset $(git rev-parse --local-env-vars) GIT_SSH_COMMAND SSH_AUTH_SOCK http_proxy all_proxy ALL_PROXY
export HOME=$work/home XDG_CACHE_HOME=$work/cache GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=$HOME/.gitconfig # never the caller's, nor XDG's
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$HOME" "$work/proj" "$work/empty"
proj=$work/proj cache=$XDG_CACHE_HOME/devkit
nowhere=file://$work/missing.git bare=$work/devkit.git

# swap_signers SRC DEST KEY.pub: copy SRC to DEST with the key type and blob of
# its signers= line replaced by KEY.pub's, and fail unless that is the one line
# that differs.
swap_signers() {
  local line type blob changed
  read -r type blob _ <"$3"
  while IFS= read -r line; do
    if [[ $line == signers=* ]]; then
      printf '%s\n' "${line% * *} $type $blob'" # the last two fields
    else
      printf '%s\n' "$line"
    fi
  done <"$1" >"$2"
  changed=$(diff "$1" "$2" | grep -c '^[<>]' || :)
  [[ $changed == 2 && $(grep -c '^signers=' "$1") == 1 &&
    $(grep -c "^signers='.*'\$" "$1") == 1 ]] || { # one line, one key
    echo "swap_signers: $2 must differ from $1 in only its signers= line" >&2
    exit 1
  }
}

# A test key signs the served tags; another key signs one the wrapper refuses.
ssh-keygen -q -t ed25519 -N '' -C '' -f "$work/key"
ssh-keygen -q -t ed25519 -N '' -C '' -f "$work/otherkey"
git config --global gpg.format ssh
git config --global user.signingKey "$work/key"

# The served devkit: v0.0.1 and v0.0.1b -> c1, v0.0.2 -> c2, all signed, all
# carrying devkitw and on main; v0.0.3 -> c3 on a side branch only. c2 has more
# tags the wrapper must refuse: v0.0.4 lightweight, v0.0.5 unsigned, v0.0.6
# signed by the other key, v0.0.7 a signed tag of v0.0.2's tag, and v0.0.9
# v0.0.2's own tag object under another name. v0.0.8 at c2 is signed, but its
# message mimics headers and a signature: the wrapper must still take it.
# $notag serves no v0.0.2, and $sidemain's main is the side branch.
git init -q -b main "$work/src"
cp "$wrapper" "$work/src/devkitw"
git -C "$work/src" add devkitw
git -C "$work/src" commit -q -m one
git -C "$work/src" tag -a -s v0.0.1 -m v0.0.1
git -C "$work/src" tag -a -s v0.0.1b -m v0.0.1b
c1=$(git -C "$work/src" rev-parse HEAD)
git -C "$work/src" commit -q --allow-empty -m two
git -C "$work/src" tag -a -s v0.0.2 -m v0.0.2
c2=$(git -C "$work/src" rev-parse HEAD)
git -C "$work/src" tag v0.0.4
git -C "$work/src" -c tag.gpgSign=false tag -a v0.0.5 -m v0.0.5
git -C "$work/src" -c user.signingKey="$work/otherkey" tag -a -s v0.0.6 -m v0.0.6
git -C "$work/src" -c advice.nestedTag=false tag -a -s v0.0.7 -m v0.0.7 v0.0.2
printf '%s\n' v0.0.8 '' "tag v9.9.9" "object $c1" '-----BEGIN SSH SIGNATURE-----' \
  >"$work/mimic"
git -C "$work/src" tag -a -s --cleanup=verbatim -F "$work/mimic" v0.0.8
git -C "$work/src" update-ref refs/tags/v0.0.9 "$(git -C "$work/src" rev-parse v0.0.2)"
git -C "$work/src" switch -q -c side
git -C "$work/src" commit -q --allow-empty -m three
git -C "$work/src" tag -a -s v0.0.3 -m v0.0.3
c3=$(git -C "$work/src" rev-parse HEAD)
git -C "$work/src" switch -q main
git clone -q --bare "$work/src" "$bare"
notag=$work/notag.git sidemain=$work/sidemain.git
git clone -q --bare "$work/src" "$notag"
git -C "$notag" tag -d v0.0.2 >/dev/null
git clone -q --bare "$work/src" "$sidemain"
git -C "$sidemain" update-ref refs/heads/main "$c3"
swap_signers "$wrapper" "$proj/devkitw" "$work/key.pub"
chmod +x "$proj/devkitw"

fake() { # fake DIR NAME BODY: an sh script $work/DIR/NAME; see run_with
  mkdir -p "$work/$1"
  printf '#!/bin/sh\n%s\n' "$3" >"$work/$1/$2"
  chmod +x "$work/$1/$2"
}
# Each fake runs with its own dir first on PATH; ${PATH#*:} drops it again.
# shellcheck disable=SC2016 # the bodies expand $0, $1, $@ when they run
{
  fake nogit git ': >"${0%/*}/called"; exit 97'
  # A concurrent run wins the race to the cache dir, or to the link.
  fake racy mv 'PATH=${PATH#*:}; cp -R "$1" "$2"; exec mv "$@"'
  fake older mv 'PATH=${PATH#*:}; cp -R "$1" "$2"; chmod -R u+w "$2"; exec mv "$@"'
  fake nomv mv 'echo "mv: noise" >&2; exit 1'
  fake relink ln 'PATH=${PATH#*:}; for a; do t=$l; l=$a; done
rm -f "$l"; ln -sn "$t" "$l"; exec ln "$@"'
  fake noisy git 'PATH=${PATH#*:}; case " $* " in *" init "*) echo leak ;; esac
exec git "$@"'
  fake hooks post-checkout 'echo leak; touch "${0%/*}/ran"'
  fake ssh ssh 'echo "$*" >"${0%/*}/args"; exit 255'
  fake askpass askpass 'touch "${0%/*}/called"'
  fake noisykeygen ssh-keygen 'echo "Could not verify signature."; echo noise
echo noise >&2; exit 255'
  fake oldkeygen ssh-keygen 'echo "unknown option -- Y" >&2; exit 1'
  fake nopasswd ssh-keygen 'echo "No user exists for uid 12345" >&2; exit 255'
}
# A PATH of only what the wrapper runs before it fetches: no ssh-keygen.
mkdir -p "$work/nokeygen"
for tool in sed grep head cat readlink ln; do
  ln -sf "$(command -v "$tool")" "$work/nokeygen/$tool"
done
cp "$work/nogit/git" "$work/nokeygen/git"

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

[frontend.min-pins]
mirror = "file://$bare"
EOF
}

cwd=$proj
run() { # sets rc, out, err
  rc=0
  out=$(cd "$cwd" && "${runner:-$proj/devkitw}" "$@" 2>"$work/err") || rc=$?
  err=$(<"$work/err")
}
run_on() { # run_on PATH ARGS...: run with PATH alone
  local path=$PATH
  # shellcheck disable=SC2123 # the point: a PATH of our own
  PATH=$1
  shift
  run "$@"
  PATH=$path
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
read_only() { [ -z "$(find "$cache/$1" ! -type l -perm -u+w)" ]; } # files and dirs; root-safe

case_miss() {
  pin "file://$bare" "" v0.0.1 "$c1"
  run path
  ok_at "$c1" && [ -z "$err" ] && cmp -s "$out/devkitw" "$wrapper" &&
    [ "$(<"$out/.devkit-commit")" = "$c1 v0.0.1" ] && [ ! -e "$out/.git" ] &&
    no_temp_left && read_only "$c1"
}
case_hit_offline() {
  pin "$nowhere" "$nowhere" v0.0.1 "$c1"
  run_on "$work/nokeygen" # no git, and no ssh-keygen to check for
  ok_at "$c1" && [ ! -e "$work/nokeygen/called" ]
}
case_wrong_commit() {
  pin "file://$bare" "" v0.0.1 "$c2"
  run path
  one_line_error && [ ! -e "$cache/$c2" ] && no_temp_left
}
case_off_main() { # the tag resolves to the pin, but the commit is not on main
  pin "file://$bare" "" v0.0.3 "$c3"
  run path
  one_line_error && [[ $err == *"not on devkit's main"* ]] &&
    [ ! -e "$cache/$c3" ] && no_temp_left || return 1
  pin "file://$bare" "file://$sidemain" v0.0.3 "$c3" # where c3 is on main
  run path
  one_line_error && [[ $err == *"not on devkit's main"* ]] &&
    [ ! -e "$cache/$c3" ] && no_temp_left
}
refused() { # refused VERSION COMMIT TEXT: the pinned tag fails, caching nothing
  pin "file://$bare" "" "$1" "$2"
  run path
  one_line_error && [[ $err == *"$3"* ]] && [ ! -e "$cache/$2" ] && no_temp_left
}
case_lightweight() { refused v0.0.4 "$c2" "is not an annotated tag"; }
case_unsigned() { refused v0.0.5 "$c2" "not signed by devkit's release key"; }
case_other_key() { refused v0.0.6 "$c2" "not signed by devkit's release key"; }
case_renamed() { # v0.0.2's tag object, served as v0.0.9
  refused v0.0.9 "$c2" "a tag of another name, commit or tag"
}
case_tag_of_tag() { refused v0.0.7 "$c2" "a tag of another name, commit or tag"; }
case_shipped_key() { # the shipped wrapper trusts the release key, not the test key
  local runner=$wrapper
  refused v0.0.2 "$c2" "not signed by devkit's release key"
}
case_keygen_fails() { # its output stays out of the message
  pin "file://$bare" "" v0.0.2 "$c2"
  run_with "$work/noisykeygen" path
  one_line_error && [[ $err == *"not signed by devkit's release key"* &&
    $err != *noise* ]] && [ ! -e "$cache/$c2" ] && no_temp_left
}
case_no_keygen() { # the wrapper checks before it fetches
  pin "file://$bare" "" v0.0.2 "$c2"
  run_on "$work/nokeygen" path
  one_line_error && [[ $err == *"needs ssh-keygen"* ]] &&
    [ ! -e "$work/nokeygen/called" ] && [ ! -e "$cache/$c2" ] && no_temp_left
}
case_old_keygen() { # one without -Y is named as such, not as a bad tag
  pin "file://$bare" "" v0.0.2 "$c2"
  run_with "$work/oldkeygen" path
  one_line_error && [[ $err == *"needs OpenSSH 8.1 or later"* &&
    $err != *"not signed"* ]] && [ ! -e "$cache/$c2" ] && no_temp_left
}
case_mimic() { # message lines like headers or a signature do not confuse it
  pin "file://$bare" "" v0.0.8 "$c2"
  run path
  ok_at "$c2" && [ -z "$err" ] && uncache "${cache:?}/$c2"
}
case_keygen_faults() { # a fault is named as such, not as a bad tag
  pin "file://$bare" "" v0.0.2 "$c2"
  run_with "$work/nopasswd" path
  one_line_error && [[ $err == *"No user exists for uid 12345"* &&
    $err != *"not signed"* ]] && [ ! -e "$cache/$c2" ] && no_temp_left
}
case_mirror() {
  uncache "${cache:?}/$c1"
  pin "$nowhere" "file://$bare" v0.0.1 "$c1"
  run path
  ok_at "$c1" && [ -f "$cache/$c1/.devkit-commit" ]
}
case_url_lacks_tag() { # reachable, so the mirror is not asked
  uncache "${cache:?}/$c2"
  pin "file://$notag" "file://$bare" v0.0.2 "$c2"
  run path
  one_line_error && [[ $err == *"file://$notag serves no tag v0.0.2"* ]] &&
    [ ! -e "$cache/$c2" ] && no_temp_left
}
case_unreachable() {
  uncache "${cache:?}/$c1"
  pin "$nowhere" "$nowhere" v0.0.1 "$c1"
  run path
  one_line_error && [ ! -e "$cache/$c1" ] && no_temp_left
}
case_trailing_mirror() { # pin() puts a reachable mirror in a later table
  uncache "${cache:?}/$c1"
  pin "$nowhere" "" v0.0.1 "$c1"
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
  local ok=0
  pin "file://$bare" "" v0.0.2 "$(tr a-f A-F <<<"$c2")"
  run_with "$work/nogit" path
  one_line_error || ok=1
  pin "file://$bare" "" v0.0.2 "${c2:1}"
  run_with "$work/nogit" path
  one_line_error && [ ! -e "$work/nogit/called" ] || ok=1
  pin "file://$bare" "" v0.0.2 "$c2" # the cases after it pin v0.0.2, pass or fail
  return "$ok"
}
case_unknown_arg() {
  run frobnicate
  [ "$rc" = 2 ] && [[ $err == "devkitw: "* ]]
}
case_hook_env() { # a pre-commit hook exports the caller's repository
  uncache "${cache:?}/$c2"
  export GIT_DIR=$work/caller.git GIT_INDEX_FILE=$work/caller-index
  run path
  unset GIT_DIR GIT_INDEX_FILE
  ok_at "$c2" && [ ! -e "$work/caller.git" ] && [ ! -e "$work/caller-index" ]
}
case_race() { # another run moved its copy into place just before our mv
  uncache "${cache:?}/$c2"
  run_with "$work/racy" path
  ok_at "$c2" && no_temp_left && ! compgen -G "$cache/$c2/.tmp.*" >/dev/null
}
case_race_older() { # an older devkitw's writable copy won: ours is discarded
  uncache "${cache:?}/$c2"
  run_with "$work/older" path
  ok_at "$c2" && no_temp_left && ! compgen -G "$cache/$c2/.tmp.*" >/dev/null &&
    ! read_only "$c2"
}
case_move_fails() {
  uncache "${cache:?}/$c2"
  run_with "$work/nomv" path
  one_line_error && [[ $err == *"$cache/$c2"* && $err != *noise* ]] &&
    [ ! -e "$cache/$c2" ] && no_temp_left
}
case_incomplete() {
  uncache "${cache:?}/$c2"
  mkdir "$cache/$c2"
  run path
  one_line_error && rmdir "$cache/$c2"
}
case_relink_race() { # another run relinks .devkit just before our ln
  ln -sfn "$work/stale" "$proj/.devkit"
  run_with "$work/relink" path
  ok_at "$c2" && [ ! -L "$cache/$c2/$c2" ] && [ ! -e "$cache/$c2/$c2" ]
}
case_git_quiet() { # a global post-checkout hook, and git writing to stdout
  uncache "${cache:?}/$c2"
  git config --global core.hooksPath "$work/hooks"
  run_with "$work/noisy" path
  git config --global --unset core.hooksPath
  ok_at "$c2" && [ ! -e "$work/hooks/ran" ]
}
case_ssh_batch() {
  uncache "${cache:?}/$c2"
  pin "ssh://example.invalid/devkit.git" "file://$bare" v0.0.2 "$c2"
  run_with "$work/ssh" path
  ok_at "$c2" && grep -q 'BatchMode=yes' "$work/ssh/args" &&
    grep -qw 'ServerAliveInterval=10' "$work/ssh/args" &&
    grep -qw 'ServerAliveCountMax=2' "$work/ssh/args"
}
case_askpass() { # a url that answers 401, and an askpass from every source
  uncache "${cache:?}/$c2"
  coproc python3 -I -c 'import http.server as h, sys
class H(h.BaseHTTPRequestHandler):
    def do_GET(self):
        open(sys.argv[1], "w").close()
        self.send_response(401)
        self.end_headers()
    def log_message(self, *a): pass
s = h.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()' "$work/hit"
  # bash unsets COPROC once it reaps a dead server; set -u would then abort
  local pid=$COPROC_PID fd=${COPROC[0]} port
  read -r port <&"$fd" || return 1
  pin "http://127.0.0.1:$port/devkit.git" "" v0.0.2 "$c2"
  git config --global core.askPass "$work/askpass/askpass"
  GIT_ASKPASS=$work/askpass/askpass SSH_ASKPASS=$work/askpass/askpass run path
  git config --global --unset core.askPass
  kill "$pid"
  one_line_error && [ -e "$work/hit" ] && [ ! -e "$work/askpass/called" ] &&
    no_temp_left
}
case_version_mismatch() { # c1 is cached as v0.0.1; v0.0.1b tags it too
  pin "file://$bare" "" v0.0.1 "$c1"
  run path
  pin "file://$bare" "" v0.0.1b "$c1"
  run_with "$work/nogit" path
  one_line_error && [[ $err == *"does not match"*"remove $cache/$c1"* ]] &&
    [ ! -e "$work/nogit/called" ] || return 1
  local cmd=${err#*\(}
  sh -c "${cmd%%)*}"
  run path
  ok_at "$c1" && [ "$(<"$cache/$c1/.devkit-commit")" = "$c1 v0.0.1b" ]
}

t "1 miss fetches, prints the path, marks, links, makes read-only" case_miss
t "2 hit needs no remote and no git" case_hit_offline
t "3 wrong commit fails and caches nothing" case_wrong_commit
t "3b a commit off main fails, the mirror's main notwithstanding" \
  case_off_main
t "3c a lightweight tag fails" case_lightweight
t "3d an unsigned annotated tag fails" case_unsigned
t "3e a tag signed by another key fails" case_other_key
t "3f a signed tag served under another name fails" case_renamed
t "3g a signed tag of a tag fails" case_tag_of_tag
t "3h the shipped wrapper refuses a tag the test key signed" case_shipped_key
t "3i a failing ssh-keygen fails in one line, its output suppressed" \
  case_keygen_fails
t "3j no ssh-keygen fails in one line, before any fetch" case_no_keygen
t "3k an ssh-keygen without -Y is named, not taken for a bad tag" \
  case_old_keygen
t "3l a signed tag whose message mimics headers and a signature passes" \
  case_mimic
t "3m an ssh-keygen that faults is named, not taken for a bad tag" \
  case_keygen_faults
t "4 unreachable url falls back to the mirror" case_mirror
t "4a a reachable url without the tag fails; no mirror fallback" \
  case_url_lacks_tag
t "4b both remotes unreachable fails and caches nothing" case_unreachable
t "4c a mirror outside [devkit] is ignored" case_trailing_mirror
t "5 new pin repoints the link" case_repoint
t "6 .devkit that is a directory fails" case_not_a_link
t "7a missing devkit.toml fails" case_no_toml
t "7b malformed commit fails" case_bad_commit
t "9 unknown argument exits 2" case_unknown_arg
t "10 a git hook's GIT_DIR/GIT_INDEX_FILE are left alone" case_hook_env
t "11 a concurrent run's copy wins; ours is discarded" case_race
t "11b an older devkitw's writable copy wins; ours is discarded" \
  case_race_older
t "11c a failed move fails in one line and leaves no temp dir" \
  case_move_fails
t "12 a cache dir without its marker fails" case_incomplete
t "13 a concurrent relink leaves one link and nothing in the cache" \
  case_relink_race
t "14 neither git hooks nor git's stdout reach the path" case_git_quiet
t "15 ssh runs in batch mode" case_ssh_batch
t "15b a rejected credential fails without asking an askpass" case_askpass
t "16 a cached commit under another version fails until refetched" \
  case_version_mismatch

[ "$fails" = 0 ] || {
  echo "$fails case(s) failed"
  exit 1
}
