#!/usr/bin/env bash
# Tests for scripts/python/duplication.py with the real jscpd of devkit's
# jscpd/ closure, which scripts/lib/node_closure.sh installs once into the
# caller's cache, as make lint would (node, npm and, the first time, the npm
# registry), and stubs for its failures: a temp project, its own git
# repository, holding a clone (src/a.py, src/b.py) and a unique file, with
# devkit.toml written per case. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export DEVKIT=$root
# shellcheck source=SCRIPTDIR/../scripts/lib/node_closure.sh
. "$root/scripts/lib/node_closure.sh"
node_closure "$root/jscpd" jscpd "duplication tests" >/dev/null
jscpd=$NODE_TOOL
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars) XDG_CONFIG_HOME
export XDG_CACHE_HOME=$work/cache GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export PROJECT_ROOT=$work/proj
proj=$PROJECT_ROOT fails=0

git init -q "$proj"
mkdir "$proj/src"
cp "$root/jscpd/controls/duplicate_a.py" "$proj/src/a.py"
cp "$root/jscpd/controls/duplicate_b.py" "$proj/src/b.py"
cp "$root/jscpd/controls/unique.py" "$proj/src/c.py"
# jscpd stubs: one that writes no report, one that fails, one that writes
# $REPORT as its report, and one that hangs with a child, whose pid it writes
# to $work/child.
printf '#!/bin/sh\nexit 0\n' >"$work/silent"
printf '#!/bin/sh\necho "jscpd stub broke" >&2\nexit 3\n' >"$work/broken"
# shellcheck disable=SC2016 # the stubs expand their variables when they run
{
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = --output ] && out=$2; shift; done\n'
  printf 'mkdir -p "$out" && printf "%%s" "$REPORT" >"$out/jscpd-report.json"\n'
} >"$work/reports"
printf '#!/bin/sh\nsleep 60 >/dev/null 2>&1 &\necho $! >"%s/child"\nwait\n' "$work" >"$work/hangs"
chmod +x "$work/silent" "$work/broken" "$work/reports" "$work/hangs"

config() { printf '%s\n' "$@" >"$proj/devkit.toml"; } # config LINE...: devkit.toml holds the LINEs

# expect LABEL WANT-STATUS ARG... -- WANT-TEXT...: $driver ARGs end with
# WANT-STATUS, saying every WANT-TEXT, and no Python traceback.
driver=(python3 "$root/scripts/python/duplication.py")
expect() {
  local label=$1 want=$2 args=() out rc=0 text ok=true
  shift 2
  while [[ $1 != -- ]]; do args+=("$1") && shift; done
  shift
  out=$(cd "$work" && "${driver[@]}" "${args[@]}" 2>&1) || rc=$?
  for text in "$@"; do [[ $out == *"$text"* ]] || ok=false; done
  if [[ $rc == "$want" && $ok == true && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and each of [$*] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

table='[python.duplication]'
paths='paths = ["src"]'
entry='[[python.duplication.accepted]]'
ab='files = ["src/b.py", "src/a.py"]'

# Configuration.
config '[devkit]' 'version = "v0.0.0"'
expect "no [python.duplication] table fails" 1 check-config -- \
  "ERROR: devkit.toml has no [python.duplication] table"
config "$table"
expect "no paths fails" 1 check-config -- "ERROR: [python.duplication] in devkit.toml sets no paths"
config "$table" 'paths = []'
expect "empty paths fail" 1 check-config -- "paths must be a non-empty list"
config "$table" 'paths = ["src", "nope"]'
expect "a missing path fails" 1 check-config -- "lists nope in paths, which does not exist"
config "$table" 'paths = ["src/../.."]'
expect "a path outside the project root fails" 1 check-config -- "which leaves the project root"
config "$table" "paths = [\"$proj/src\"]"
expect "an absolute path fails" 1 check-config -- "lists the absolute path $proj/src in paths"
config "$table" "$paths" 'min-tokens = 0'
expect "min-tokens 0 fails" 1 check-config -- "min-tokens must be a positive integer (default 50), not 0"
config "$table" "$paths" 'min-tokens = "50"'
expect "a quoted min-tokens fails" 1 check-config -- "min-tokens must be a positive integer"
config "$table" "$paths" 'ignore = "**/b.py"'
expect "an ignore string fails" 1 check-config -- "ignore must be a list of jscpd glob patterns"
config "$table" "$paths" 'ignore = ["**/{a,b}.py"]'
expect "an ignore glob with a comma fails" 1 check-config -- "holds a comma, which jscpd splits on"
config "$table" "$paths" 'min_tokens = 10'
expect "an unknown key fails" 1 check-config -- "sets unknown key(s) min_tokens"
config "$table" "$paths" "$entry" 'files = ["src/a.py"]' 'reason = "deliberate"'
expect "an accepted entry with one file fails" 1 check-config -- \
  "[[python.duplication.accepted]] in devkit.toml entry 1 needs files"
config "$table" "$paths" "$entry" "$ab"
expect "an accepted entry without a reason fails" 1 check-config -- \
  "entry 1 (src/a.py  ~  src/b.py) needs a reason"
config "$table" "$paths" "$entry" "$ab" 'reason = " "'
expect "an accepted entry with a blank reason fails" 1 check-config -- "entry 1 (src/a.py  ~  src/b.py) needs a reason"
config "$table" "$paths" "$entry" "$ab" 'reason = "one"' "$entry" 'files = ["src/a.py", "src/b.py"]' 'reason = "two"'
expect "a pair accepted twice, in either order, fails" 1 check-config -- "accepts src/a.py  ~  src/b.py twice"
config "$table" "$paths" "$entry" "$ab" 'reason = "deliberate"' 'reasons = "typo"'
expect "an unknown key in an accepted entry fails" 1 check-config -- \
  "entry 1 sets unknown key(s) reasons; it reads only files and reason."
config "$table" 'paths = ["src", "src/c.py"]' "$entry" "$ab" 'reason = "deliberate"'
expect "a valid table passes check-config" 0 check-config -- \
  "[python.duplication]: jscpd scans the 3 Python file(s) git lists under src, src/c.py."
mkdir "$proj/empty"
touch "$proj/empty/notes.txt"
config "$table" 'paths = ["empty"]'
none="ERROR: git lists no Python files under [python.duplication] in devkit.toml's paths (empty)"
expect "paths without Python files fail check-config" 1 check-config -- "$none"
expect "paths without Python files fail run before jscpd runs" 1 run "$work/broken" -- "$none"
mkdir -p "$work/nogit/src"
cp "$proj/src/a.py" "$work/nogit/src/"
printf '%s\n' "$table" "$paths" >"$work/nogit/devkit.toml"
PROJECT_ROOT=$work/nogit GIT_CEILING_DIRECTORIES=$work expect "a project outside a git work tree fails" 1 check-config -- \
  "ERROR: git cannot list the files in $work/nogit: "
config "$table"
expect "run validates the table before jscpd runs" 1 run "$work/broken" -- \
  "ERROR: [python.duplication] in devkit.toml sets no paths"

# Scans.
config "$table" "$paths"
expect "a clone fails naming its pair and lines" 1 run "$jscpd" -- \
  "ERROR: duplicated code not accepted in devkit.toml: src/a.py  ~  src/b.py" "    src/a.py:" \
  "To fix: extract the shared code, or accept the pair"
config "$table" "$paths" "$entry" "$ab" 'reason = "deliberate"'
expect "the clone accepted passes" 0 run "$jscpd" -- "jscpd: no duplicated code beyond the 1 accepted file pair(s)."
config "$table" "$paths" "$entry" "$ab" 'reason = "deliberate"' "$entry" 'files = ["src/c.py", "src/a.py"]' 'reason = "gone"'
expect "a stale accepted entry fails" 1 run "$jscpd" -- \
  "ERROR: stale [[python.duplication.accepted]] entry, no longer duplicated: src/a.py  ~  src/c.py" \
  "To fix: remove the stale entries from devkit.toml."
# src/d.py, a third copy, accepted with src/a.py: ignoring src/b.py must keep it scanned.
cp "$proj/src/a.py" "$proj/src/d.py"
ad='files = ["src/a.py", "src/d.py"]'
config "$table" "$paths" 'ignore = ["**/b.py"]' "$entry" "$ad" 'reason = "deliberate"'
expect "an ignore glob excludes a file" 0 run "$jscpd" -- "jscpd: no duplicated code beyond the 1 accepted"
config "$table" "$paths" 'ignore = ["src/b.py"]' "$entry" "$ad" 'reason = "deliberate"'
expect "a project-relative ignore glob excludes a file" 0 run "$jscpd" -- "jscpd: no duplicated code beyond the 1 accepted"
rm "$proj/src/d.py"
config "$table" "$paths" 'ignore = ["-x"]'
expect "an ignore glob that starts with a dash is a glob, not an option" 1 run "$jscpd" -- \
  "ERROR: duplicated code not accepted in devkit.toml: src/a.py  ~  src/b.py"
config "$table" "$paths" 'min-tokens = 500'
expect "min-tokens above the clone passes" 0 run "$jscpd" -- "jscpd: no duplicated code"
config "$table" 'paths = ["src", "src/a.py"]' "$entry" "$ab" 'reason = "deliberate"'
expect "overlapping paths scan each file once" 0 run "$jscpd" -- "jscpd: no duplicated code beyond the 1 accepted"

# What jscpd scans: the files git lists, whatever jscpd's own walker would skip.
config "$table" "$paths"
clone="ERROR: duplicated code not accepted in devkit.toml: src/a.py  ~  src/b.py"
mkdir "$proj/.config"
for decoy in "$work/.jscpd.json" "$proj/.jscpd.json" "$proj/.config/jscpd.json"; do
  printf '{"minTokens": 500, "ignore": ["**/b.py"]}\n' >"$decoy"
done
expect "a .jscpd.json in the project, its .config or the working directory does not apply" 1 run "$jscpd" -- "$clone"
rm -r "$work/.jscpd.json" "$proj/.jscpd.json" "$proj/.config"
echo b.py >"$proj/src/.ignore"
expect "a .ignore in a scanned directory does not apply" 1 run "$jscpd" -- "$clone"
mv "$proj/src/.ignore" "$work/.ignore"
expect "a .ignore above the project does not apply" 1 run "$jscpd" -- "$clone"
rm "$work/.ignore"
mkdir -p "$work/home/.config/git" "$work/xdg/git"
echo b.py | tee "$work/home/.config/git/ignore" >"$work/xdg/git/ignore"
HOME=$work/home expect "the user's git excludes in HOME do not apply" 1 run "$jscpd" -- "$clone"
XDG_CONFIG_HOME=$work/xdg expect "the user's git excludes in XDG_CONFIG_HOME do not apply" 1 run "$jscpd" -- "$clone"
NODE_OPTIONS="--require=$work/missing.js" expect "NODE_OPTIONS does not reach jscpd's Node.js" 1 run "$jscpd" -- "$clone"
echo b.py >"$proj/.gitignore"
git -C "$proj" add -f src/b.py
expect "a tracked file .gitignore matches is scanned" 1 run "$jscpd" -- "$clone"
echo d.py >>"$proj/.gitignore"
cp "$proj/src/a.py" "$proj/src/d.py"
config "$table" "$paths" "$entry" "$ab" 'reason = "deliberate"'
expect "an untracked file .gitignore matches is not scanned" 0 run "$jscpd" -- "beyond the 1 accepted"
git -C "$proj" rm -q --cached src/b.py
rm "$proj/.gitignore" "$proj/src/d.py"
mkdir "$proj/src/.hidden"
cp "$proj/src/a.py" "$proj/src/.hidden/d.py"
expect "a file in a hidden directory is scanned" 1 run "$jscpd" -- \
  "ERROR: duplicated code not accepted in devkit.toml: src/.hidden/d.py  ~  src/a.py"
rm -r "$proj/src/.hidden"

# Detector control and jscpd failures.
config "$table" "$paths"
control="ERROR: jscpd's detector control failed: it reported"
REPORT='{"duplicates": []}' expect "a jscpd that reports no clone fails the detector control" 1 run "$work/reports" -- \
  "$control no clone, not exactly duplicate_a.py  ~  duplicate_b.py"
clone() { # clone FILE FILE: a clone of the two control files in jscpd's report format
  printf '{"firstFile": {"name": "%s", "start": 1, "end": 9}, "secondFile": {"name": "%s", "start": 1, "end": 9}, "tokens": 60}' \
    "$root/jscpd/controls/$1" "$root/jscpd/controls/$2"
}
REPORT="{\"duplicates\": [$(clone duplicate_a.py duplicate_b.py), $(clone duplicate_a.py unique.py)]}" \
  expect "a jscpd that reports an extra control pair fails the detector control" 1 run "$work/reports" -- \
  "$control duplicate_a.py  ~  duplicate_b.py, duplicate_a.py  ~  unique.py, not exactly"
expect "a jscpd that writes no report fails" 1 run "$work/silent" -- "ERROR: jscpd wrote no report"
REPORT='not json' expect "an unreadable report fails" 1 run "$work/reports" -- "ERROR: cannot read jscpd's report:"
REPORT='{"clones": []}' expect "a report without a list of duplicates fails" 1 run "$work/reports" -- \
  "ERROR: jscpd's report holds no list of duplicates"
REPORT='{"duplicates": [{"firstFile": {}}]}' expect "a report with a clone without its files fails" 1 run "$work/reports" -- \
  "ERROR: jscpd's report has a clone without its files"
driver=(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv.pop(1)); import duplication; duplication.TIMEOUT = 1; duplication.main()'
  "$root/scripts/python")
expect "a jscpd past the timeout fails" 1 run "$work/hangs" -- "ERROR: jscpd did not finish within 1 seconds; it was killed."
driver=(python3 "$root/scripts/python/duplication.py")
gone() { # gone PID: PID has exited within 2 seconds; a zombie counts, as a container's PID 1 may never reap it
  for _ in {1..10}; do
    kill -0 "$1" 2>/dev/null && [[ $(ps -o stat= -p "$1") != Z* ]] || return 0
    sleep 0.2
  done
  return 1
}
if gone "$(cat "$work/child")"; then
  echo "PASS the timeout kills jscpd's children too"
else
  echo "FAIL the timeout kills jscpd's children too: pid $(cat "$work/child") still runs"
  fails=$((fails + 1))
fi
expect "a failing jscpd fails with its output" 1 run "$work/broken" -- \
  "ERROR: jscpd failed (exit 3). It reported:" "jscpd stub broke"
expect "a jscpd that does not run fails" 1 run "$work/missing" -- "ERROR: cannot run jscpd:"
expect "an unknown command exits 2" 2 lint -- "usage: duplication.py {check-config|run JSCPD}"

[[ $fails == 0 ]]
