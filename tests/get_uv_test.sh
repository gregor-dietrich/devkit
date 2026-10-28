#!/usr/bin/env bash
# Tests for scripts/lib/get_uv.sh: per case, a fresh cache and stub uv
# binaries, which print a version and leave a "ran" marker, in that cache and
# before the PATH the test runs with. The pin carries a local version label no
# real uv reports, so a real uv on that PATH is never chosen. The bootstrap
# runs against a python3 stand-in whose venv's pip "installs" a stub uv. No
# network. Prints PASS/FAIL per case.
set -euo pipefail

uncache() { chmod -R u+w "$@" 2>/dev/null || :; rm -rf "$@"; } # the caches are read-only, directories too
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=SCRIPTDIR/../scripts/lib/sha256.sh
. "$root/scripts/lib/sha256.sh"
work=$(mktemp -d)
trap 'uncache "$work"' EXIT
proj=$work/proj pin=0.13.6+devkit.test
mkdir "$proj"
hash=$(printf '1%.0s' {1..64}) other_hash=$(printf '2%.0s' {1..64})
lock() { # lock [HASH]: proj/uv.lock, whose uv wheel lists HASH (none when empty)
  printf '[[package]]\nname = "uv"\nversion = "%s"\nwheels = [{ url = "u"%s }]\n' \
    "$pin" "${1:+, hash = \"sha256:$1\"}" >"$proj/uv.lock"
}
lock "$hash"
base=$PATH
REAL_PYTHON3=$(command -v python3)
abi=$("$REAL_PYTHON3" -I "$root/scripts/python/uv_project.py" uv-platform)
export REAL_PYTHON3 WORK=$work PIN=$pin
fails=0 case_no=0

stub() { # stub PATH VERSION-LINE: a uv at PATH that prints VERSION-LINE
  mkdir -p "${1%/*}"
  # shellcheck disable=SC2016 # $0 expands when the stub runs
  printf '#!/bin/sh\ntouch "${0%%/*}/ran"\necho "%s"\n' "$2" >"$1"
  chmod +x "$1"
}
# fake DIR NAME BODY: an sh script $work/DIR/NAME
fake() {
  mkdir -p "$work/$1"
  printf '#!/bin/sh\n%s\n' "$3" >"$work/$1/$2"
  chmod +x "$work/$1/$2"
}
# shellcheck disable=SC2016 # the bodies expand when they run
{
  # Both stand-ins first have the real python3 import the module they were
  # asked to run, with the flags before their -m, so a project file shadowing
  # it runs where the real interpreter would run it.
  # python3 whose "[FLAGS] -m venv DIR" makes a venv of pipvenv/python and whose
  # uv-platform prints FAKE_ABI when that is set; the rest is real.
  fake python python3 'case " $* " in *" -m venv "*)
  flags=; while [ "$1" != -m ]; do flags="$flags $1" && shift; done
  "$REAL_PYTHON3" $flags -c "import venv"
  mkdir -p "$3/bin" && cp "$WORK/pipvenv/python" "$3/bin/python" && exit 0 ;;
*" uv-platform "*) [ -z "${FAKE_ABI:-}" ] || { echo "$FAKE_ABI" && exit 0; } ;;
esac
exec "$REAL_PYTHON3" "$@"'
  # The venv's python: "[FLAGS] -m pip install ... -r FILE" records its
  # arguments, PIP_INDEX_URL and FILE, then installs a stub uv and uvx, unless
  # PIP_FAILS is set (it fails) or PIP_NOOP is (it succeeds and installs nothing).
  fake pipvenv python 'echo "$*" >"$WORK/pip-args"; echo "${PIP_INDEX_URL-}" >"$WORK/pip-index"
flags=; while [ "$1" != -m ]; do flags="$flags $1" && shift; done
"$REAL_PYTHON3" $flags -c "import pip" 2>/dev/null
for arg; do last=$arg; done
cp "$last" "$WORK/pip-requirements"
[ -z "${PIP_FAILS:-}" ] || { echo "pip: hash mismatch" >&2; exit 1; }
[ -z "${PIP_NOOP:-}" ] || exit 0
printf "#!/bin/sh\necho \"uv $PIN (x86_64-unknown-linux-gnu)\"\n" >"${0%/*}/uv"
chmod +x "${0%/*}/uv" && touch "${0%/*}/uvx"'
  # A move that fails.
  fake failmv mv 'exit 1'
  # A copy that fails only into a bin/uv, as the bootstrap's copy of the installed uv does.
  fake failcp cp 'for last; do :; done
case $last in */bin/uv) exit 1 ;; esac
PATH=${PATH#*:}; exec cp "$@"'
  # A concurrent run moves its copy into place just before our mv.
  fake racy mv 'PATH=${PATH#*:}; cp -R "$1" "$2"; exec mv "$@"'
}

# run [DIR...] [-- VAR=VALUE...]: source get_uv.sh in the project with each
# DIR before the base PATH and the case's cache; sets rc, out (UV_CMD, and
# UV_PROJECT_ENVIRONMENT when still set)
run() {
  local prefix=
  while [[ $# -gt 0 && $1 != -- ]]; do prefix+=$1: && shift; done
  [[ $# == 0 ]] || shift
  rc=0
  # shellcheck disable=SC2016 # expanded by the inner bash
  out=$(cd "$proj" && env PATH="$prefix$base" DEVKIT="$root" PROJECT_ROOT="$proj" XDG_CACHE_HOME="$cache" "$@" \
    bash -c 'set -uo pipefail; [ -n "${NO_ERREXIT-}" ] || set -e; . "$DEVKIT/scripts/lib/get_uv.sh"
      echo "$UV_CMD${UV_PROJECT_ENVIRONMENT+ UV_PROJECT_ENVIRONMENT=$UV_PROJECT_ENVIRONMENT}"' 2>&1) || rc=$?
}
t() { # t NAME COMMAND...: report whether COMMAND succeeds, with a fresh cache
  local name=$1
  shift
  cache=$work/cache-$((++case_no))
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name (rc=$rc, output: $out)"
    fails=$((fails + 1))
  fi
}
chose() { [[ $rc == 0 && $out == "$1" ]]; }
failed_saying() { [[ $rc != 0 && $out == *"ERROR: "*"$1"* && $out != *Traceback* ]]; }
tools_of() { echo "$cache/devkit/tools"; }
# cached_dir [HASH [ABI]]: where the uv of a lock listing HASH (default: the test lock's), for a
# python3 reporting ABI (default: the real one's), is cached
cached_dir() {
  local key
  key=$(sha256_of <(printf 'uv==%s \\\n    --hash=sha256:%s\n' "$pin" "${1:-$hash}"))
  echo "$cache/devkit/tools/uv-$pin-$(uname -s)-$(uname -m)-${2:-$abi}-${key:0:16}"
}
cached_uv() { echo "$(cached_dir "$@")/bin/uv"; }
read_only() { [[ -z $(find "$1" ! -type l -perm -u+w) ]]; } # files and directories; root-safe
remove_hint() { echo "remove $1 (chmod -R u+w '$1'; rm -rf '$1') and run make install"; }

case_cache_hit() {
  stub "$(cached_uv)" "uv $pin"
  run
  chose "$(cached_uv)"
}
case_cache_hit_build_info() {
  stub "$(cached_uv)" "uv $pin (0123abcde 2026-09-04)"
  run
  chose "$(cached_uv)"
}
case_cache_prefix_version() {
  stub "$(cached_uv)" "uv ${pin}0"
  run
  failed_saying "$(cached_uv) does not report uv $pin"
}
case_cache_other_version() {
  stub "$(cached_uv)" "uv 0.12.9"
  run
  failed_saying "$(cached_uv) does not report uv $pin (uv 0.12.9); $(remove_hint "$(cached_dir)")"
}
case_cache_unrunnable() {
  mkdir -p "$(dirname "$(cached_uv)")"
  printf '#!/bin/sh\necho "bad ELF interpreter" >&2\nexit 1\n' >"$(cached_uv)"
  chmod +x "$(cached_uv)"
  run
  failed_saying "$(cached_uv) does not report uv $pin (bad ELF interpreter); $(remove_hint "$(cached_dir)")"
}
case_cache_over_path() {
  stub "$(cached_uv)" "uv $pin"
  stub "$work/pa/uv" "uv $pin"
  rm -f "$work/pa/ran"
  run "$work/pa"
  chose "$(cached_uv)" && [[ ! -e $work/pa/ran ]]
}
case_path_pin_not_run() {
  stub "$work/pb/uv" "uv $pin"
  rm -f "$work/pb/ran"
  run "$work/pb"
  failed_saying "uv $pin, as uv.lock pins it, is not installed in $(cached_dir); run make install" &&
    [[ ! -e $work/pb/ran && ! -e $(tools_of) ]]
}
case_no_bootstrap_unasked() {
  run "$work/python"
  failed_saying "uv $pin, as uv.lock pins it, is not installed in $(cached_dir); run make install" &&
    [[ ! -e $(tools_of) ]]
}
case_other_hashes() {
  local first second ok=0
  stub "$(cached_uv)" "uv $pin"
  rm -f "$(dirname "$(cached_uv)")/ran"
  lock "$other_hash"
  run
  first=$rc out1=$out
  run "$work/python" -- UV_BOOTSTRAP=true
  second=$rc
  lock "$hash"
  [[ $first != 0 && $out1 == *"ERROR: uv $pin, as uv.lock pins it, is not installed in $(cached_dir "$other_hash"); run make install"* &&
    ! -e $(dirname "$(cached_uv)")/ran && $second == 0 && $out == *$'\n'"$(cached_uv "$other_hash")" &&
    -x $(cached_uv) && -x $(cached_uv "$other_hash") ]] || ok=1
  return $ok
}
case_bootstrap() {
  local key
  rm -f "$work/pip-args"
  run "$work/python" -- UV_BOOTSTRAP=true
  key=$(sha256_of "$work/pip-requirements")
  [[ $rc == 0 && $out == *"Installing uv $pin"* && $out == *$'\n'"$(cached_uv)" ]] &&
    [[ $(ls -A "$(tools_of)") == "uv-$pin-$(uname -s)-$(uname -m)-$abi-${key:0:16}" && $(ls -A "$(cached_dir)/bin") == uv ]] &&
    read_only "$(cached_dir)" &&
    grep -q -- '-I -m pip install --quiet --disable-pip-version-check --require-hashes --only-binary=:all: --no-deps -r ' \
      "$work/pip-args" &&
    [[ $(<"$work/pip-requirements") == "uv==$pin \\"$'\n'"    --hash=sha256:$hash" ]]
}
case_bootstrap_race() {
  run "$work/racy" "$work/python" -- UV_BOOTSTRAP=true
  [[ $rc == 0 && $out == *$'\n'"$(cached_uv)" ]] &&
    [[ $(ls -A "$(tools_of)") == "$(basename "$(cached_dir)")" && $(ls -A "$(cached_dir)") == bin ]] &&
    [[ $(ls -A "$(cached_dir)/bin") == uv ]]
}
case_bootstrap_move_fails() {
  run "$work/failmv" "$work/python" -- UV_BOOTSTRAP=true
  failed_saying "cannot move the installed uv $pin into $(cached_dir)" && [[ -z $(ls -A "$(tools_of)") ]]
}
case_bootstrap_pip_fails() {
  run "$work/python" -- UV_BOOTSTRAP=true PIP_FAILS=1
  failed_saying "pip could not install uv $pin as uv.lock pins it" && [[ $out == *PIP_INDEX_URL* ]] &&
    [[ -z $(ls -A "$(tools_of)") ]]
}
case_bootstrap_pip_installs_nothing() {
  run "$work/python" -- UV_BOOTSTRAP=true PIP_NOOP=1
  failed_saying "pip reported success but installed no uv into its throwaway venv; PIP_TARGET, PIP_PREFIX, PIP_ROOT or PIP_DRY_RUN" &&
    [[ -z $(ls -A "$(tools_of)") ]]
}
case_bootstrap_errexit_off() { # the caller's errexit off, as in a || list: still no fall-through
  run "$work/python" -- UV_BOOTSTRAP=true PIP_FAILS=1 NO_ERREXIT=1
  failed_saying "pip could not install uv $pin as uv.lock pins it" && [[ $out != *"does not report uv"* ]] &&
    [[ -z $(ls -A "$(tools_of)") ]]
}
case_bootstrap_copy_fails() {
  run "$work/failcp" "$work/python" -- UV_BOOTSTRAP=true
  failed_saying "cannot copy the installed uv into " && [[ $out != *"does not report uv"* ]] &&
    [[ -z $(ls -A "$(tools_of)") ]]
}
case_bootstrap_stage_not_pin() { # a copy that does not run as the pin is never sealed
  run "$work/python" -- UV_BOOTSTRAP=true PIN=0.0.1
  failed_saying "the uv pip installed does not run as uv $pin (uv 0.0.1 (x86_64-unknown-linux-gnu))" &&
    [[ -z $(ls -A "$(tools_of)") ]]
}
case_abi_keys_copy() { # machines differing only in libc or pointer width keep a copy each
  run "$work/python" -- UV_BOOTSTRAP=true FAKE_ABI=glibc64
  local first=$rc
  run "$work/python" -- UV_BOOTSTRAP=true FAKE_ABI=musl64
  [[ $first == 0 && $rc == 0 && $out == *$'\n'"$(cached_uv "$hash" musl64)" ]] &&
    (($(find "$(tools_of)" -mindepth 1 -maxdepth 1 | wc -l) == 2)) && # arithmetic: BSD wc pads the count
    [[ -x $(cached_uv "$hash" glibc64) && -x $(cached_uv "$hash" musl64) ]]
}
case_abi_unusable() {
  run "$work/python" -- UV_BOOTSTRAP=true FAKE_ABI=../x
  failed_saying "is not usable in a cache path" && [[ ! -e $(tools_of) ]]
}
case_pip_index() {
  rm -f "$work/pip-args" "$work/pip-index"
  run "$work/python" -- UV_BOOTSTRAP=true PIP_INDEX_URL=https://mirror.invalid/simple
  [[ $rc == 0 && $(<"$work/pip-index") == https://mirror.invalid/simple ]] &&
    ! grep -Eq -- '--(index-url|isolated|no-index)' "$work/pip-args"
}
case_relative_cache() {
  run -- XDG_CACHE_HOME=relative
  failed_saying "the tools cache root relative/devkit/tools is not an absolute path"
}
case_cache_dangling_link() {
  mkdir -p "$(tools_of)"
  ln -s "$work/nowhere" "$(cached_dir)"
  run "$work/python" -- UV_BOOTSTRAP=true
  failed_saying "$(cached_uv) does not report uv $pin (" && [[ $out == *"); $(remove_hint "$(cached_dir)")"* ]] &&
    [[ $out != *"Installing uv"* ]]
}
case_bootstrap_shadowing() {
  printf 'open("%s", "w").close()\n' "$work/shadow-ran" >"$proj/venv.py"
  cp "$proj/venv.py" "$proj/pip.py"
  run "$work/python" -- UV_BOOTSTRAP=true
  rm "$proj/venv.py" "$proj/pip.py"
  [[ $rc == 0 && $out == *$'\n'"$(cached_uv)" && ! -e $work/shadow-ran ]]
}
case_project_environment_unset() {
  stub "$(cached_uv)" "uv $pin"
  run -- UV_PROJECT_ENVIRONMENT=/elsewhere
  chose "$(cached_uv)"
}
case_lock_without_hash() {
  stub "$work/pc/uv" "uv $pin"
  rm -f "$work/pc/ran"
  lock
  run "$work/pc"
  lock "$hash"
  failed_saying "no sha256 hash" && [[ ! -e $work/pc/ran ]]
}
case_lock_below_floor() { # fails before pip is ever run
  rm -f "$work/pip-args"
  pin=0.13.5 lock "$hash"
  run "$work/python" -- UV_BOOTSTRAP=true
  pin=0.13.6+devkit.test lock "$hash"
  failed_saying "uv.lock pins uv 0.13.5, below devkit's minimum 0.13.6" && [[ ! -e $work/pip-args && ! -e $(tools_of) ]]
}

t "1 the cached uv at the pin is chosen" case_cache_hit
t "2 a cached uv reporting build info after the pin is chosen" case_cache_hit_build_info
t "3 a version that only starts with the pin is another version" case_cache_prefix_version
t "4 a cached uv of another version fails naming the directory" case_cache_other_version
t "5 the cached uv is chosen over a pinned uv first on PATH, which never runs" case_cache_over_path
t "6 a pinned uv on PATH and nothing cached fails naming make install, and never runs" case_path_pin_not_run
t "7 without UV_BOOTSTRAP=true nothing is installed" case_no_bootstrap_unasked
t "8 a lock with other hashes fails without running the first copy, and gets its own" case_other_hashes
t "9 UV_BOOTSTRAP=true installs only bin/uv, hash-pinned and keyed, and leaves no temp dir" case_bootstrap
t "10 a concurrent bootstrap's copy wins; ours is discarded" case_bootstrap_race
t "11 a failed pip install fails, names PIP_INDEX_URL and caches nothing" case_bootstrap_pip_fails
t "12 a pip that installs no uv fails in one line and caches nothing" case_bootstrap_pip_installs_nothing
t "13 PIP_INDEX_URL reaches pip, which is not given an index of its own" case_pip_index
t "14 a relative cache root fails" case_relative_cache
t "15 a dangling cache link fails naming it, and is not bootstrapped over" case_cache_dangling_link
t "16 the bootstrap never runs a project-root venv.py or pip.py" case_bootstrap_shadowing
t "17 UV_PROJECT_ENVIRONMENT is unset for the uv calls" case_project_environment_unset
t "18 a failed move fails in one line and leaves no temp dir" case_bootstrap_move_fails
t "19 a lock whose uv wheels carry no hash fails, with a pinned uv on PATH" case_lock_without_hash
t "20 a cached uv that does not run fails with what it printed" case_cache_unrunnable
t "21 with the caller's errexit off, a failed pip fails without falling through" case_bootstrap_errexit_off
t "22 a failed copy of the installed uv fails and caches nothing" case_bootstrap_copy_fails
t "23 a staged uv that is not the pin is never sealed" case_bootstrap_stage_not_pin
t "24 python3s differing in libc or pointer width keep their own copies" case_abi_keys_copy
t "25 an unusable platform part fails before anything is installed" case_abi_unusable
t "26 a lock whose uv is below the minimum fails before pip runs" case_lock_below_floor

[[ $fails == 0 ]]
