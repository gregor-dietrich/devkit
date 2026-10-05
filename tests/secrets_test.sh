#!/usr/bin/env bash
# Hermetic tests for scripts/secrets.sh: a temp copy of devkit's scripts/
# whose linux_x64 hash is replaced by that of a fixture tarball, holding a
# fake gitleaks that logs its argv; stubs for uname, curl (copies the fixture
# asset, or fails) and tar (logs, then runs the real one); temp git projects.
# No network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars) GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
export HOME=$work/home XDG_CACHE_HOME=$work/cache GIT_CEILING_DIRECTORIES=$work
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 # no signing, no hooks from the user
export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
export LOG=$work/log # every stub and the fake gitleaks append a line here
mkdir -p "$HOME" "$work/plain"
tools=$XDG_CACHE_HOME/devkit/tools
version=$(sed -n 's/^version=//p' "$root/scripts/secrets.sh")
installed=$tools/gitleaks-$version-linux_x64

# The release asset stand-in: a tarball with a gitleaks that logs its argv
# and the config variables it sees, logs the git configuration values it would
# run git with, prints $FAKE_GL_LOG to stderr when argv
# holds $FAKE_GL_LOG_ON, and fails when argv holds $FAKE_GL_FAIL.
mkdir "$work/asset"
# shellcheck disable=SC2016 # expands when the fake runs
printf '%s\n' '#!/bin/sh' \
  'echo "gitleaks $* config=${GITLEAKS_CONFIG-unset} toml=${GITLEAKS_CONFIG_TOML-unset}" >>"$LOG"' \
  'c() { git config --get "$1" || echo unset; }' \
  'echo "gitcfg $(c log.showRoot) $(c color.ui) $(c color.diff) $(c diff.noprefix) $(c core.quotePath) $(c user.name)" >>"$LOG"' \
  'case " $* " in *" ${FAKE_GL_LOG_ON:-none} "*) printf "%s\n" "$FAKE_GL_LOG" >&2 ;; esac' \
  'case " $* " in *" ${FAKE_GL_FAIL:-none} "*) exit 1 ;; esac' >"$work/asset/gitleaks"
chmod +x "$work/asset/gitleaks"
echo "not the gitleaks binary" >"$work/asset/README.md"
tar -czf "$work/good.tar.gz" -C "$work/asset" gitleaks README.md
tar -czf "$work/bad.tar.gz" -C "$work/asset" README.md

# The devkit under test: scripts/ with the linux_x64 pin moved to the fixture.
# shellcheck source=SCRIPTDIR/../scripts/lib/sha256.sh
. "$root/scripts/lib/sha256.sh"
pinned=$(sed -n 's/^ *Linux\/x86_64) platform=linux_x64 sha256=\([0-9a-f]\{64\}\) ;;$/\1/p' \
  "$root/scripts/secrets.sh")
devkit=$work/devkit
mkdir "$devkit"
cp -R "$root/scripts" "$devkit/"
sed "s/$pinned/$(sha256_of "$work/good.tar.gz")/" "$root/scripts/secrets.sh" >"$devkit/scripts/secrets.sh"

# Stubs, first on PATH; ${PATH#*:} drops their directory again.
mkdir "$work/bin"
stub() { # stub NAME BODY
  printf '#!/bin/sh\n%s\n' "$2" >"$work/bin/$1"
  chmod +x "$work/bin/$1"
}
# shellcheck disable=SC2016 # the bodies expand when the stubs run
{
  stub uname 'case $1 in -s) echo "${FAKE_UNAME_S:-Linux}" ;; -m) echo "${FAKE_UNAME_M:-x86_64}" ;; esac'
  stub curl 'echo "curl $*" >>"$LOG"
[ -z "${FAKE_CURL_FAIL-}" ] || exit 22
while [ $# -gt 0 ]; do [ "$1" = -o ] && cp "$FAKE_ASSET" "$2"; shift; done'
  stub tar 'echo "tar $*" >>"$LOG"; PATH=${PATH#*:}; exec tar "$@"'
  # A concurrent run moves its copy into place just before our mv.
  mkdir "$work/racy"
  printf '#!/bin/sh\n%s\n' 'PATH=${PATH#*:}; cp -R "$1" "$2"; exec mv "$@"' >"$work/racy/mv"
  chmod +x "$work/racy/mv"
}
export PATH=$work/bin:$PATH FAKE_ASSET=$work/good.tar.gz

# project DIR: a git repository in DIR with two commits
project() {
  rm -rf "$1"
  git init -q -b main "$1"
  echo one >"$1/file"
  git -C "$1" add file
  git -C "$1" commit -q -m one
  echo two >>"$1/file"
  git -C "$1" commit -q -am two
}
proj=$work/proj
project "$proj"

run() { # run [DIR]: the gate over DIR (default $proj); sets rc, out, err
  : >"$LOG"
  rc=0
  out=$(PROJECT_ROOT=${1:-$proj} DEVKIT=$devkit "$devkit/scripts/secrets.sh" 2>"$work/err") || rc=$?
  err=$(<"$work/err")
}
fails=0
t() { # t NAME COMMAND...: report whether COMMAND succeeds
  local name=$1
  shift
  if "$@" && [[ "$out$err" != *Traceback* ]]; then
    echo "PASS $name"
  else
    echo "FAIL $name (rc=$rc, stdout: $out, stderr: $err, log: $(<"$LOG"))"
    fails=$((fails + 1))
  fi
}
logged() { grep -q "^$1" "$LOG"; } # logged PREFIX: a log line starts with PREFIX
nothing_cached() { ! compgen -G "$tools/gitleaks-*" >/dev/null && ! compgen -G "$tools/.tmp.*" >/dev/null; }
one_error() { [[ $rc == 1 && $err == "ERROR: lint-secrets: "*"$1"* && $err != *$'\n'* ]]; }
scans=("git . --log-opts=HEAD" "git . --staged" "git . --pre-commit")
scanned() { # scanned SCAN...: the fake gitleaks ran exactly these, in order
  local want=() scan
  for scan in "$@"; do want+=("gitleaks $scan --redact --no-banner --verbose config=unset toml=unset"); done
  [[ $(grep '^gitleaks ' "$LOG" || :) == "$(printf '%s\n' "${want[@]}")" ]]
}

case_mismatch() {
  FAKE_ASSET=$work/bad.tar.gz run
  one_error "sha256 mismatch" && logged curl && ! logged tar && nothing_cached
}
case_no_download() {
  FAKE_CURL_FAIL=1 run
  one_error "cannot download https://github.com/" && nothing_cached
}
case_install() {
  run
  [[ $rc == 0 && -z $err && -x $installed/gitleaks && -z $(find "$installed" -type f -perm -u+w) ]] &&
    [[ $(ls -A "$installed") == gitleaks ]] && ! compgen -G "$tools/.tmp.*" >/dev/null &&
    grep -q "^curl -fsSL --proto =https --tlsv1.2 --connect-timeout 10 --max-time 300 -o $tools/.tmp.[^ ]*/asset.tar.gz https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_linux_x64.tar.gz$" "$LOG" &&
    grep -q "^tar -xzf $tools/.tmp.[^ ]*/asset.tar.gz -C $tools/.tmp.[^ ]* gitleaks$" "$LOG" || return 1
  run
  [[ $rc == 0 ]] && ! logged curl && ! logged tar
}
case_race() { # a concurrent run's install wins; ours is discarded
  rm -rf "$installed"
  PATH=$work/racy:$PATH run
  [[ $rc == 0 && -z $err && $(ls -A "$installed") == gitleaks ]] &&
    ! compgen -G "$tools/.tmp.*" >/dev/null && scanned "${scans[@]}"
}
case_platforms() { # each pinned platform fetches its own asset (the fake fails its pin)
  local uname platform
  for uname in Linux/aarch64:linux_arm64 Linux/arm64:linux_arm64 Darwin/x86_64:darwin_x64 Darwin/arm64:darwin_arm64; do
    platform=${uname#*:} uname=${uname%:*}
    FAKE_UNAME_S=${uname%/*} FAKE_UNAME_M=${uname#*/} run
    one_error "sha256 mismatch" && grep -q "/gitleaks_${version}_$platform.tar.gz$" "$LOG" &&
      ! logged tar || return 1
  done
}
case_unsupported() {
  FAKE_UNAME_S=FreeBSD FAKE_UNAME_M=amd64 run
  one_error "FreeBSD/amd64" && ! logged curl && ! logged gitleaks || return 1
  FAKE_UNAME_M=i686 run
  one_error "Linux/i686" && ! logged curl
}
case_three_scans() {
  run
  [[ $rc == 0 && -z $err ]] && scanned "${scans[@]}" && ! grep -q '^gitleaks dir' "$LOG"
}
# gl_log LEVEL MESSAGE: a gitleaks log line, coloured as gitleaks 8.30.1 writes it
gl_log() { printf '\e[90m11:57PM\e[0m \e[31m%s\e[0m \e[1m%s\e[0m' "$1" "$2"; }
case_git_error() { # gitleaks exits 0 when git fails under it; the gate does not
  local scan
  for scan in --log-opts=HEAD --staged --pre-commit; do
    FAKE_GL_LOG_ON=$scan FAKE_GL_LOG=$(gl_log ERR '[git] fatal: unable to read 0123abcd') run
    [[ $rc == 1 && $out == *"[git] fatal: unable to read 0123abcd"* ]] &&
      [[ $err == "ERROR: lint-secrets: git failed under gitleaks git $scan "*$'\n'"ERROR: lint-secrets: gitleaks failed"* ]] &&
      scanned "${scans[@]}" || return 1
  done
  FAKE_GL_LOG_ON=--staged FAKE_GL_LOG=$'\e[31mERR\e[0m \e[1m[git] fatal: no timestamp\e[0m' run
  [[ $rc == 1 && $err == "ERROR: lint-secrets: git failed under gitleaks git --staged "* ]] || return 1
  # Controls: git at another level, and another error, do not fail the gate.
  FAKE_GL_LOG_ON=--staged FAKE_GL_LOG=$(gl_log INF '[git] note') run
  [[ $rc == 0 && -z $err ]] || return 1
  FAKE_GL_LOG_ON=--staged FAKE_GL_LOG=$(gl_log ERR 'something [git] said') run
  [[ $rc == 0 && -z $err ]]
}
case_git_config() { # the overrides beat the repository's config; the caller's stay
  local kv
  project "$work/cfg"
  for kv in log.showRoot=false color.ui=always color.diff=always diff.noprefix=true core.quotePath=false; do
    git -C "$work/cfg" config "${kv%%=*}" "${kv#*=}"
  done
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=caller run "$work/cfg"
  [[ $rc == 0 && $(grep -c '^gitcfg true never never false true caller$' "$LOG") == 3 ]]
}
case_scan_fails() { # the other two still run, and the gate fails at the end
  local scan
  for scan in --log-opts=HEAD --staged --pre-commit; do
    FAKE_GL_FAIL=$scan run
    one_error "rotate it; history keeps a committed one" && [[ $err == *.gitleaksignore* ]] &&
      scanned "${scans[@]}" || return 1
  done
}
case_shallow() {
  git clone -q --depth 1 "file://$proj" "$work/shallow"
  run "$work/shallow"
  one_error "shallow clone; lint-secrets scans the full history: check out with full history (actions/checkout fetch-depth: 0)" &&
    ! logged gitleaks
}
case_unborn() {
  git init -q -b main "$work/unborn"
  echo staged >"$work/unborn/file"
  git -C "$work/unborn" add file
  run "$work/unborn"
  [[ $rc == 0 && -z $err && $out == *"no commit yet; skipping the history scan"* ]] &&
    scanned "${scans[@]:1}"
}
case_config_env() {
  GITLEAKS_CONFIG=$work/other.toml GITLEAKS_CONFIG_TOML='[extend]' run
  [[ $rc == 0 ]] && scanned "${scans[@]}"
}
case_not_a_work_tree() {
  run "$work/plain"
  one_error "is not a git work tree" && ! logged curl && ! logged gitleaks
}
case_pins() { # every arm of the shipped script pins a platform and a sha256
  local arms
  # shellcheck disable=SC2016 # the script's literal text
  arms=$(sed -n '/^case "$(uname -s)\/$(uname -m)" in$/,/^esac$/p' "$root/scripts/secrets.sh")
  [[ $(grep -c ') platform=' <<<"$arms") == 4 &&
    $(grep -cE '^  [A-Za-z0-9_/ |]+\) platform=[a-z0-9_]+ sha256=[0-9a-f]{64} ;;$' <<<"$arms") == 4 &&
    $(grep -c '^  \*) die ' <<<"$arms") == 1 && $(wc -l <<<"$arms") == 7 ]] &&
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
case_sha256_of() { # the concatenation, in order
  printf 'ab' >"$work/ab" && printf 'a' >"$work/a" && printf 'b' >"$work/b"
  [[ $(sha256_of "$work/a" "$work/b") == "$(sha256_of "$work/ab")" &&
    $(sha256_of "$work/ab") == fb8e20fc2e4c3f248c60c39bd652f3c1347298bb977b8b4d5903b85055620603 ]]
}

t "1 a mismatched asset fails before tar, caching nothing" case_mismatch
t "2 a failed download fails, caching nothing" case_no_download
t "3 a matching asset installs read-only; the next run downloads nothing" case_install
t "3b a concurrent install wins; ours is discarded" case_race
t "4 each pinned platform fetches its own asset" case_platforms
t "5 an unsupported platform fails before any download" case_unsupported
t "6 the three scans run in order, and never dir" case_three_scans
t "7 a failing scan does not stop the others; the gate fails at the end" case_scan_fails
t "7b a git error gitleaks exits 0 on fails that scan" case_git_error
t "7c git config overrides reach gitleaks' git, after the caller's" case_git_config
t "8 a shallow clone fails before any scan" case_shallow
t "9 an unborn HEAD skips the history scan and passes" case_unborn
t "10 GITLEAKS_CONFIG and GITLEAKS_CONFIG_TOML do not reach gitleaks" case_config_env
t "11 a directory that is not a work tree fails" case_not_a_work_tree
t "12 every platform arm pins a sha256" case_pins
t "13 sha256_of hashes the concatenation" case_sha256_of

[[ $fails == 0 ]] || {
  echo "$fails case(s) failed"
  exit 1
}
