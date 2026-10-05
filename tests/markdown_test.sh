#!/usr/bin/env bash
# Hermetic tests for scripts/markdown.sh: a temp HOME and cache, a temp git
# project, devkit's own tree as DEVKIT (read only), and a PATH of the system
# tools the script needs plus stubs for node, npm and the markdownlint npm
# installs. No network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars) $(compgen -e | grep -i '^markdownlint_' || :)
export HOME=$work/home XDG_CACHE_HOME=$work/cache GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
export STUBS=$work/stubs LOG=$work/log
mkdir -p "$HOME" "$STUBS" "$work/sys" "$work/nonode"
proj=$work/proj tools=$XDG_CACHE_HOME/devkit/tools controls=$root/markdown/controls
floor=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["engines"]["node"][2:])' \
  "$root/markdown/package.json")
fails=0 devkit=$root extra=()

# The tools the script runs, linked into a PATH of their own: the case
# without node must not find one installed on the machine.
for tool in cat chmod cp env find git grep head mkdir mktemp mv python3 rm sha256sum sort; do
  ln -s "$(command -v "$tool")" "$work/sys/$tool"
done
# fake NAME BODY: an executable bash script NAME in $STUBS
fake() { printf '#!/bin/bash\n%s\n' "$2" >"$STUBS/$1" && chmod +x "$STUBS/$1"; }
# shellcheck disable=SC2016 # the bodies expand their variables when they run
{
  fake node 'printf "%s\n" "${FAKE_NODE-v$FLOOR}"'
  # npm ci installs the markdownlint stub into its cwd, as the real one would;
  # with FAKE_NPM_NOBIN it installs the package but links no bin.
  fake npm 'printf "npm %s in %s\n" "$*" "$PWD" >>"$LOG/npm"
[[ -z ${FAKE_NPM_FAIL-} ]] || exit 1
[[ $1 == ci ]] || exit 0
mkdir -p node_modules/.bin node_modules/markdownlint-cli
[[ -n ${FAKE_NPM_NOBIN-} ]] || cp "$STUBS/markdownlint" node_modules/.bin/'
  # A line per run: "<cwd> | <args, %q-quoted> | <markdownlint_* variables> HOME=<home>".
  # The control run reports what devkit's profile finds unless CONTROL_MODE
  # breaks it; the lint pass exits LINT_RC.
  fake markdownlint '{
  printf "%s |" "$PWD" && printf " %q" "$@" && printf " |"
  while IFS= read -r -d "" e; do
    n=${e%%=*} && [[ ${n,,} != markdownlint_* ]] || printf " %s" "$n"
  done < <(env -0)
  printf " HOME=%s\n" "$HOME"
} >>"$LOG/mdl"
[[ $PWD == */markdown/controls ]] || exit "${LINT_RC-0}"
case ${CONTROL_MODE-} in
  accept-invalid) exit 0 ;;
  flag-clean) echo "clean.md:1 error MD041/first-line-heading" ;;
esac
[[ ${CONTROL_MODE-} == no-md018 ]] || echo "invalid.md:1:1 error MD018/no-missing-space-atx No space after hash"
[[ ${CONTROL_MODE-} == no-md013 ]] || echo "long-line.md:3:81 error MD013/line-length Line length"
[[ ${CONTROL_MODE-} == exit-zero ]] || exit 1'
}

# project FILE...: a fresh project with each FILE committed (a line of text)
project() {
  rm -rf "$proj" "$LOG"
  mkdir -p "$LOG"
  git init -q -b main "$proj"
  local file
  for file; do
    mkdir -p "$(dirname "$proj/$file")"
    echo "# Title" >"$proj/$file"
  done
  git -C "$proj" add -A
  git -C "$proj" commit -q --allow-empty -m case
}

# expect LABEL WANT-STATUS [ARG...] -- WANT-TEXT...: run $devkit's script
# with ARGs in the project and the variables in $extra, node and npm stubs on
# PATH unless NO_NODE is set; the output must contain every WANT-TEXT and no
# Python traceback.
expect() {
  local label=$1 want=$2 args=() out rc=0 text ok=true path=$STUBS:$work/sys
  shift 2
  while [[ $1 != -- ]]; do args+=("$1") && shift; done
  shift
  [[ -z ${NO_NODE-} ]] || path=$work/nonode:$work/sys
  out=$(cd "$proj" && env ${extra[@]+"${extra[@]}"} PATH="$path" PROJECT_ROOT="$proj" \
    DEVKIT="$devkit" FLOOR="$floor" "$devkit/scripts/markdown.sh" ${args[@]+"${args[@]}"} 2>&1) || rc=$?
  for text in "$@"; do [[ $out == *"$text"* ]] || ok=false; done
  if [[ $rc == "$want" && $ok == true && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and each of [$*] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

# holds LABEL COMMAND...: COMMAND must succeed
holds() {
  local label=$1
  shift
  if "$@"; then
    echo "PASS $label"
  else
    echo "FAIL $label"
    fails=$((fails + 1))
  fi
}
count() { [[ $(grep -c -F -- "$2" "$LOG/$1" 2>/dev/null) == "$3" ]]; } # count LOG TEXT N
installs() { compgen -G "$tools/markdownlint-*" || :; } # the installed closures
installed() { # one closure at tools/markdownlint-<16 hex>, with its markdownlint
  [[ $(installs) =~ /markdownlint-[0-9a-f]{16}$ && -x $(installs)/node_modules/.bin/markdownlint ]]
}
scrubbed() { # every markdownlint run: no markdownlint_* variable, not the user's HOME
  ! grep -qi -e 'markdownlint_' -e "HOME=$HOME\$" "$LOG/mdl"
}

# Discovery and the Node check.
project notes.txt
NO_NODE=1 expect "a project without Markdown passes with no node on PATH" 0 -- \
  "lint-md: no Markdown files; nothing to check."
rm -rf "$proj" && mkdir "$proj"
GIT_CEILING_DIRECTORIES=$work expect "a directory outside a git work tree fails" 1 -- \
  "ERROR: git cannot list the files in $proj"
project README.md
NO_NODE=1 expect "node missing fails naming the floor" 1 -- \
  "ERROR: node not found; lint-md needs Node.js >= $floor and npm on PATH."
FAKE_NODE=v1.0.0 expect "Node.js v1.0.0 fails" 1 -- "ERROR: Node.js v1.0.0 on PATH is below $floor"
FAKE_NODE=v99.0.0-nightly1 expect "Node.js v99.0.0-nightly1 passes" 0 -- "lint-md: 1 Markdown files checked."
# Version order, not text order: 22.3.0 sorts after 22.22.2 and 100 before 22 as text.
FAKE_NODE=v22.3.0 expect "Node.js v22.3.0 fails" 1 -- "ERROR: Node.js v22.3.0 on PATH is below $floor"
FAKE_NODE=v100.0.0 expect "Node.js v100.0.0 passes" 0 -- "lint-md: 1 Markdown files checked."
FAKE_NODE=garbage expect "an unreadable node version fails" 1 -- \
  "ERROR: cannot read a version from 'node --version' ('garbage')"

# Installation.
rm -rf "$tools"
project README.md
expect "the first run installs and passes" 0 -- "lint-md: 1 Markdown files checked."
holds "the first run calls npm ci --ignore-scripts once" count npm "npm ci --ignore-scripts" 1
holds "it installs at tools/markdownlint-<16 hex>" installed
rm -f "$LOG/npm"
expect "the second run passes" 0 -- "lint-md: 1 Markdown files checked."
holds "the second run makes no npm call" [ ! -e "$LOG/npm" ]
rm -f "$(installs)/node_modules/.bin/markdownlint"
expect "a cache dir without its markdownlint fails naming it" 1 -- \
  "ERROR: $(installs) is incomplete; remove it and retry"
rm -rf "$tools"
FAKE_NPM_FAIL=1 expect "an npm failure fails" 1 -- \
  "ERROR: cannot install markdownlint-cli (npm ci failed; the first run needs the npm registry)"
holds "an npm failure leaves no install and no temp dir" [ -z "$(installs)$(compgen -G "$tools/.tmp.*")" ]
FAKE_NPM_NOBIN=1 expect "an npm ci that links no markdownlint fails" 1 -- \
  "ERROR: npm ci did not install markdownlint (check npm's bin-links setting)"
holds "it leaves no install and no temp dir" [ -z "$(installs)$(compgen -G "$tools/.tmp.*")" ]
expect "a later run installs" 0 -- "lint-md: 1 Markdown files checked."
mkdir "$work/devkit"
cp -R "$root/scripts" "$root/markdown" "$work/devkit/"
echo >>"$work/devkit/markdown/package-lock.json"
devkit=$work/devkit expect "a devkit with another package-lock.json passes" 0 -- \
  "lint-md: 1 Markdown files checked."
holds "another package-lock.json installs under another key" \
  [ "$(installs | grep -cE '/markdownlint-[0-9a-f]{16}$')" = 2 ]

# Detector controls.
control="ERROR: markdownlint's detector control failed:"
CONTROL_MODE=accept-invalid expect "a control run that passes everything fails" 1 -- \
  "$control it passed invalid.md and long-line.md"
CONTROL_MODE=exit-zero expect "a control run that reports but exits 0 fails" 1 -- \
  "$control it passed invalid.md and long-line.md"
CONTROL_MODE=no-md018 expect "a control run without MD018 fails" 1 -- \
  "$control invalid.md was not reported for MD018/no-missing-space-atx"
CONTROL_MODE=no-md013 expect "a control run without MD013 fails" 1 -- \
  "$control long-line.md was not reported for MD013/line-length"
CONTROL_MODE=flag-clean expect "a control run that flags clean.md fails" 1 -- \
  "$control clean.md was reported"
project README.md
expect "with --fix, both runs pass" 0 --fix -- "format-md: 1 Markdown files checked."
holds "the controls run in markdown/controls with devkit's config and no --fix" \
  count mdl "$controls | --config $root/markdown/markdownlint.jsonc -- clean.md invalid.md long-line.md |" 1
holds "--fix reaches the lint pass" count mdl "$proj | --config $root/markdown/markdownlint.jsonc --fix -- README.md" 1

# The lint pass.
project README.md docs/guide.md "with space.md" -x.md deleted.md notes.txt .gitignore
printf 'ignored.md\n' >"$proj/.gitignore"
rm "$proj/deleted.md"
touch "$proj/untracked.md" "$proj/ignored.md"
ln -s README.md "$proj/link.md"
extra=(markdownlint_config=/elsewhere MARKDOWNLINT_MD041=false markdownlint_line-length=false)
expect "the lint pass passes" 0 -- "lint-md: 5 Markdown files checked."
extra=()
holds "it gets tracked and untracked files, not ignored, deleted or symlinked ones, after --" \
  count mdl "$proj | --config $root/markdown/markdownlint.jsonc -- -x.md README.md docs/guide.md untracked.md with\\ space.md |" 1
holds "markdownlint runs without markdownlint_* variables (markdownlint_line-length too) or the user's HOME" \
  scrubbed
printf '{}\n' >"$proj/.markdownlint.jsonc"
expect "a project with .markdownlint.jsonc passes" 0 -- "lint-md: 5 Markdown files checked."
holds "the project's .markdownlint.jsonc is used when present" \
  count mdl "$proj | --config $proj/.markdownlint.jsonc --" 1
LINT_RC=1 expect "lint findings fail" 1 -- "lint-md: markdownlint check FAILED; see the findings above."
LINT_RC=1 expect "findings --fix leaves pass format-md with a NOTE" 0 --fix -- \
  "format-md: NOTE: markdownlint cannot fix the findings above; make lint will fail on these."
LINT_RC=4 expect "a markdownlint error fails format-md" 1 --fix -- \
  "format-md: markdownlint fix FAILED; see the findings above."
expect "an unknown argument exits 2" 2 --check -- "usage: markdown.sh [--fix]"

[[ $fails == 0 ]]
