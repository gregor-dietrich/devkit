#!/usr/bin/env bash
# Tests for scripts/lib/get_uv.sh: per case, a fresh cache and stub uv
# binaries, which print a version and leave a "ran" marker, before the PATH
# the test runs with. The pin carries a local version label no real uv
# reports, so a real uv on that PATH is never chosen. The bootstrap runs
# against a python3 stand-in whose venv's pip "installs" a stub uv. No
# network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
proj=$work/proj pin=0.12.10+devkit.test
mkdir "$proj"
hash=$(printf '1%.0s' {1..64})
printf '[[package]]\nname = "uv"\nversion = "%s"\nwheels = [{ url = "u", hash = "sha256:%s" }]\n' \
  "$pin" "$hash" >"$proj/uv.lock"
base=$PATH
REAL_PYTHON3=$(command -v python3)
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
  # python3 whose "[FLAGS] -m venv DIR" makes a venv of pipvenv/python; the
  # rest is real.
  fake python python3 'case " $* " in *" -m venv "*)
  flags=; while [ "$1" != -m ]; do flags="$flags $1" && shift; done
  "$REAL_PYTHON3" $flags -c "import venv"
  mkdir -p "$3/bin" && cp "$WORK/pipvenv/python" "$3/bin/python" && exit 0
esac
exec "$REAL_PYTHON3" "$@"'
  # The venv's python: "[FLAGS] -m pip install ... -r FILE" records its
  # arguments and FILE, then installs a stub uv and uvx, unless PIP_FAILS is set.
  fake pipvenv python 'echo "$*" >"$WORK/pip-args"
flags=; while [ "$1" != -m ]; do flags="$flags $1" && shift; done
"$REAL_PYTHON3" $flags -c "import pip" 2>/dev/null
for arg; do last=$arg; done
cp "$last" "$WORK/pip-requirements"
[ -z "${PIP_FAILS:-}" ] || { echo "pip: hash mismatch" >&2; exit 1; }
printf "#!/bin/sh\necho \"uv $PIN (x86_64-unknown-linux-gnu)\"\n" >"${0%/*}/uv"
chmod +x "${0%/*}/uv" && touch "${0%/*}/uvx"'
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
    bash -c 'set -euo pipefail; . "$DEVKIT/scripts/lib/get_uv.sh"
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
cached_uv() { echo "$cache/devkit/uv/$pin/bin/uv"; }
read_only() { [[ -z $(find "$1" -type f -perm -u+w) ]]; } # root-safe

case_path_pin() {
  stub "$work/a/uv" "uv $pin"
  run "$work/a"
  chose "$work/a/uv"
}
case_path_pin_build_info() {
  stub "$work/b/uv" "uv $pin (0123abcde 2026-09-04)"
  run "$work/b"
  chose "$work/b/uv"
}
case_path_other_version() {
  stub "$work/c/uv" "uv 0.12.9"
  run "$work/c"
  failed_saying "uv $pin not found, neither on PATH nor in $cache/devkit/uv/$pin; run make install"
}
case_path_prefix_version() {
  stub "$work/d/uv" "uv ${pin}0"
  run "$work/d"
  failed_saying "uv $pin not found"
}
case_cache_hit() {
  stub "$work/c/uv" "uv 0.12.9"
  stub "$(cached_uv)" "uv $pin"
  run "$work/c"
  chose "$(cached_uv)"
}
case_venv_refused() {
  stub "$proj/.venv/bin/uv" "uv $pin"
  run "$proj/.venv/bin"
  failed_saying "uv $pin not found" && [[ ! -e $proj/.venv/bin/ran ]]
}
case_venv_link_refused() {
  mkdir -p "$work/link"
  ln -sf "$proj/.venv/bin/uv" "$work/link/uv"
  run "$work/link"
  failed_saying "uv $pin not found" && [[ ! -e $proj/.venv/bin/ran && ! -e $work/link/ran ]]
}
case_cache_other_version() {
  stub "$(cached_uv)" "uv 0.12.9"
  run
  failed_saying "$(cached_uv) does not report uv $pin; remove $cache/devkit/uv/$pin"
}
case_no_bootstrap_unasked() {
  run "$work/python"
  failed_saying "uv $pin not found" && [[ ! -e $cache/devkit/uv ]]
}
case_bootstrap() {
  rm -f "$work/pip-args"
  run "$work/python" -- UV_BOOTSTRAP=true
  [[ $rc == 0 && $out == *"Installing uv $pin"* && $out == *$'\n'"$(cached_uv)" ]] &&
    [[ $(ls -A "$cache/devkit/uv") == "$pin" && $(ls -A "$cache/devkit/uv/$pin/bin") == uv ]] &&
    read_only "$(cached_uv)" &&
    grep -q -- '-I -m pip install --quiet --disable-pip-version-check --require-hashes --only-binary=:all: --no-deps -r ' \
      "$work/pip-args" &&
    [[ $(<"$work/pip-requirements") == "uv==$pin \\"$'\n'"    --hash=sha256:$hash" ]]
}
case_bootstrap_race() {
  run "$work/racy" "$work/python" -- UV_BOOTSTRAP=true
  [[ $rc == 0 && $out == *$'\n'"$(cached_uv)" ]] &&
    [[ $(ls -A "$cache/devkit/uv") == "$pin" && $(ls -A "$cache/devkit/uv/$pin") == bin ]] &&
    [[ $(ls -A "$cache/devkit/uv/$pin/bin") == uv ]]
}
case_bootstrap_pip_fails() {
  run "$work/python" -- UV_BOOTSTRAP=true PIP_FAILS=1
  failed_saying "pip could not install uv $pin as uv.lock pins it" && [[ -z $(ls -A "$cache/devkit/uv") ]]
}
case_relative_cache() {
  run -- XDG_CACHE_HOME=relative
  failed_saying "the uv cache root relative/devkit/uv is not an absolute path"
}

case_path_pin_after_other() {
  stub "$work/c/uv" "uv 0.12.9"
  stub "$work/a/uv" "uv $pin"
  run "$work/c" "$work/a"
  chose "$work/a/uv"
}
case_path_pin_after_venv() {
  stub "$proj/.venv/bin/uv" "uv $pin"
  rm -f "$proj/.venv/bin/ran"
  stub "$work/a/uv" "uv $pin"
  run "$proj/.venv/bin" "$work/a"
  chose "$work/a/uv" && [[ ! -e $proj/.venv/bin/ran ]]
}
case_venv_hard_link_refused() {
  stub "$proj/.venv/bin/uv" "uv $pin"
  mkdir -p "$work/hard"
  ln -f "$proj/.venv/bin/uv" "$work/hard/uv"
  run "$work/hard"
  failed_saying "uv $pin not found" && [[ ! -e $work/hard/ran ]]
}
case_venv_linked_refused() {
  rm -rf "$proj/.venv" "$work/venv"
  stub "$work/venv/bin/uv" "uv $pin"
  ln -s "$work/venv" "$proj/.venv"
  run "$work/venv/bin"
  failed_saying "uv $pin not found" && [[ ! -e $work/venv/bin/ran ]]
}
case_venv_unresolved_refuses() {
  rm -rf "$proj/.venv"
  ln -s "$work/nowhere" "$proj/.venv"
  stub "$work/a/uv" "uv $pin"
  rm -f "$work/a/ran"
  run "$work/a"
  rm "$proj/.venv"
  failed_saying "uv $pin not found" && [[ ! -e $work/a/ran ]]
}
case_cache_dangling_link() {
  mkdir -p "$cache/devkit/uv"
  ln -s "$work/nowhere" "$cache/devkit/uv/$pin"
  run "$work/python" -- UV_BOOTSTRAP=true
  failed_saying "$(cached_uv) does not report uv $pin; remove $cache/devkit/uv/$pin and run make install" &&
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
  stub "$work/a/uv" "uv $pin"
  run "$work/a" -- UV_PROJECT_ENVIRONMENT=/elsewhere
  chose "$work/a/uv"
}

t "1 a uv on PATH at the pin is chosen" case_path_pin
t "2 a uv on PATH reporting build info after the pin is chosen" case_path_pin_build_info
t "3 a uv on PATH of another version, and no cached one, fails naming the pin" case_path_other_version
t "4 a version that only starts with the pin is another version" case_path_prefix_version
t "5 the cached uv is chosen over a uv of another version on PATH" case_cache_hit
t "6 the uv inside .venv is refused, and never run" case_venv_refused
t "7 a link to the uv inside .venv is refused, and never run" case_venv_link_refused
t "8 a cached uv of another version fails naming the directory" case_cache_other_version
t "9 without UV_BOOTSTRAP=true nothing is installed" case_no_bootstrap_unasked
t "10 UV_BOOTSTRAP=true installs only bin/uv, hash-pinned, and leaves no temp dir" case_bootstrap
t "11 a concurrent bootstrap's copy wins; ours is discarded" case_bootstrap_race
t "12 a failed pip install fails and caches nothing" case_bootstrap_pip_fails
t "13 a relative cache root fails" case_relative_cache
t "14 a pinned uv later on PATH is chosen past one of another version" case_path_pin_after_other
t "15 a pinned uv later on PATH is chosen past the .venv's, which never runs" case_path_pin_after_venv
t "16 a hard link to the uv inside .venv is refused, and never run" case_venv_hard_link_refused
t "17 the uv inside a symlinked .venv is refused, and never run" case_venv_linked_refused
t "18 a .venv that does not resolve refuses every uv on PATH" case_venv_unresolved_refuses
t "19 a dangling cache link fails naming it, and is not bootstrapped over" case_cache_dangling_link
t "20 the bootstrap never runs a project-root venv.py or pip.py" case_bootstrap_shadowing
t "21 UV_PROJECT_ENVIRONMENT is unset for the uv calls" case_project_environment_unset

[[ $fails == 0 ]]
