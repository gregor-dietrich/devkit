#!/usr/bin/env bash
# Hermetic tests for scripts/markdown.sh: a temp HOME and cache, a temp git
# project, devkit's own tree as DEVKIT (read only), and a PATH of the system
# tools the script needs plus stubs for node (which also plays markdown/lint.mjs),
# npm and the markdownlint npm install. No network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars)
export HOME=$work/home XDG_CACHE_HOME=$work/cache GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
export STUBS=$work/stubs LOG=$work/log
mkdir -p "$HOME" "$STUBS" "$work/sys" "$work/nonode"
proj=$work/proj tools=$XDG_CACHE_HOME/devkit/tools controls=$root/markdown/controls
floor=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["engines"]["node"][2:])' \
  "$root/markdown/package.json")
fails=0 devkit=$root

# The tools the script runs, linked into a PATH of their own: the case
# without node must not find one installed on the machine.
for tool in cat chmod cp env find git grep head mkdir mktemp mv python3 rm sha256sum sort; do
  ln -s "$(command -v "$tool")" "$work/sys/$tool"
done
# fake NAME BODY: an executable bash script NAME in $STUBS
fake() { printf '#!/bin/bash\n%s\n' "$2" >"$STUBS/$1" && chmod +x "$STUBS/$1"; }
# shellcheck disable=SC2016 # the bodies expand their variables when they run
{
  # With no argument but --version it is node; otherwise it is the linter, a line
  # per run: "<cwd> | <args, %q-quoted> |". The control run reports what devkit's
  # profile finds unless CONTROL_MODE breaks it; the lint pass exits LINT_RC, only
  # for a run whose arguments contain LINT_RC_FOR when that is set.
  fake node 'if [[ $# == 1 && $1 == --version ]]; then printf "%s\n" "${FAKE_NODE-v$FLOOR}"; exit; fi
printf "%s |" "$PWD" >>"$LOG/mdl" && printf " %q" "$@" >>"$LOG/mdl" && echo " |" >>"$LOG/mdl"
if [[ $PWD != */markdown/controls ]]; then
  [[ -z ${LINT_RC_FOR-} || $* == *"$LINT_RC_FOR"* ]] || exit 0
  exit "${LINT_RC-0}"
fi
case ${CONTROL_MODE-} in
  accept-invalid) exit 0 ;;
  flag-clean) echo "clean.md:1 error MD041/first-line-heading" ;;
esac
[[ ${CONTROL_MODE-} == no-md018 ]] || echo "invalid.md:1:1 error MD018/no-missing-space-atx No space after hash"
[[ ${CONTROL_MODE-} == no-md013 ]] || echo "long-line.md:3:81 error MD013/line-length Line length"
[[ ${CONTROL_MODE-} == exit-zero ]] || exit 1'
  # npm ci installs the markdownlint stub into its cwd, as the real one would;
  # with FAKE_NPM_NOBIN it installs the package but links no bin.
  fake npm 'printf "npm %s in %s\n" "$*" "$PWD" >>"$LOG/npm"
[[ -z ${FAKE_NPM_FAIL-} ]] || exit 1
[[ $1 == ci ]] || exit 0
mkdir -p node_modules/.bin node_modules/markdownlint-cli
[[ -n ${FAKE_NPM_NOBIN-} ]] || cp "$STUBS/markdownlint" node_modules/.bin/'
  fake markdownlint 'echo stub'
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
# with ARGs in the project, node and npm stubs on
# PATH unless NO_NODE is set; the output must contain every WANT-TEXT and no
# Python traceback.
expect() {
  local label=$1 want=$2 args=() out rc=0 text ok=true path=$STUBS:$work/sys
  shift 2
  while [[ $1 != -- ]]; do args+=("$1") && shift; done
  shift
  [[ -z ${NO_NODE-} ]] || path=$work/nonode:$work/sys
  out=$(cd "$proj" && env PATH="$path" PROJECT_ROOT="$proj" \
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
rm -rf "$tools"
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
mods=$(installs)/node_modules lint=$root/markdown/lint.mjs default=$root/markdown/markdownlint.jsonc
holds "the controls run in markdown/controls with devkit's config and no --fix" \
  count mdl "$controls | $lint $mods $default clean.md invalid.md long-line.md |" 1
holds "--fix reaches the lint pass" count mdl "$proj | $lint --fix $mods $default README.md |" 1

# The lint pass.
project README.md docs/guide.md "with space.md" -x.md deleted.md notes.txt .gitignore
printf 'ignored.md\n' >"$proj/.gitignore"
rm "$proj/deleted.md"
touch "$proj/untracked.md" "$proj/ignored.md"
ln -s README.md "$proj/link.md"
expect "the lint pass passes" 0 -- "lint-md: 5 Markdown files checked."
holds "it gets tracked and untracked files, not ignored, deleted or symlinked ones" \
  count mdl "$proj | $lint $mods $default -x.md README.md docs/guide.md untracked.md with\\ space.md |" 1
printf '{}\n' >"$proj/.markdownlint.jsonc"
expect "a project with .markdownlint.jsonc passes" 0 -- "lint-md: 5 Markdown files checked."
holds "the project's .markdownlint.jsonc is used when present" \
  count mdl "$proj | $lint $mods $proj/.markdownlint.jsonc -x.md" 1
LINT_RC=1 expect "lint findings fail" 1 -- "lint-md: markdownlint check FAILED; see the findings above."
LINT_RC=1 expect "findings --fix leaves pass format-md with a NOTE" 0 --fix -- \
  "format-md: NOTE: markdownlint cannot fix the findings above; make lint will fail on these."
LINT_RC=4 expect "a markdownlint error fails format-md" 1 --fix -- \
  "format-md: markdownlint fix FAILED; see the findings above."
expect "an unknown argument exits 2" 2 --check -- "usage: markdown.sh [--fix]"

# Profiles.
project README.md .claude/a.md .claude/sub/b.md .agents/c.md docs/d.md docs/agents/e.md
printf '{}\n' >"$proj/.markdownlint.jsonc"
printf '{}\n' >"$proj/.claude/.markdownlint.jsonc"
printf '{}\n' >"$proj/docs/agents/.markdownlint.jsonc"
printf '[markdown.profiles]\n".claude" = ".claude/.markdownlint.jsonc"\n".agents" = ".claude/.markdownlint.jsonc"\n' >"$proj/devkit.toml"
expect "a project with profiles passes" 0 -- "lint-md: 6 Markdown files checked."
holds "the default group runs once with the project's config" \
  count mdl "$proj | $lint $mods $proj/.markdownlint.jsonc README.md docs/agents/e.md docs/d.md |" 1
holds "each profile runs once with its config" \
  count mdl "$proj | $lint $mods .claude/.markdownlint.jsonc .agents/c.md |" 1
holds "a profile gets its own files" count mdl "$proj | $lint $mods .claude/.markdownlint.jsonc .claude/a.md .claude/sub/b.md |" 1
holds "one run per group, plus the controls" [ "$(wc -l <"$LOG/mdl")" = 4 ]
printf '[markdown.profiles]\n"docs" = ".claude/.markdownlint.jsonc"\n"docs/agents" = "docs/agents/.markdownlint.jsonc"\n' >"$proj/devkit.toml"
expect "nested subtrees pass" 0 -- "lint-md: 6 Markdown files checked."
holds "the longest subtree wins" \
  count mdl "$proj | $lint $mods docs/agents/.markdownlint.jsonc docs/agents/e.md |" 1
holds "a shorter subtree keeps its other files" \
  count mdl "$proj | $lint $mods .claude/.markdownlint.jsonc docs/d.md |" 1
printf '[markdown.profiles]\n".claude" = ".claude/.markdownlint.jsonc"\n' >"$proj/devkit.toml"
touch "$proj/.claude/ignored.md"
printf 'ignored.md\n' >"$proj/.gitignore"
expect "an ignored file is not counted" 0 -- "lint-md: 6 Markdown files checked."
LINT_RC=1 LINT_RC_FOR=.claude/.markdownlint.jsonc expect "findings in one group fail lint-md" 1 -- \
  "lint-md: markdownlint check FAILED; see the findings above."
LINT_RC=4 LINT_RC_FOR=.claude/.markdownlint.jsonc expect "an error in one group fails format-md" 1 --fix -- \
  "format-md: markdownlint fix FAILED; see the findings above."
LINT_RC=1 LINT_RC_FOR=.claude/.markdownlint.jsonc expect "findings in one group pass format-md with a NOTE" 0 --fix -- \
  "format-md: NOTE:"
rm "$LOG/mdl"
LINT_RC=4 LINT_RC_FOR=$proj/.markdownlint.jsonc expect "an error in the default group fails lint-md" 1 -- \
  "lint-md: markdownlint check FAILED; see the findings above."
holds "the groups after a failing one still run" [ "$(wc -l <"$LOG/mdl")" = 3 ]

# devkit.toml errors: one ERROR line each, no traceback (expect checks that).
profile_error() { # profile_error LABEL TOML ERROR
  printf '%s\n' "$2" >"$proj/devkit.toml"
  expect "$1" 1 -- "ERROR: $3"
}
profile_error "invalid TOML" '[markdown' "cannot read devkit.toml:"
profile_error "an unknown key under [markdown]" '[markdown]
extra = 1' "devkit.toml: unknown key(s) under [markdown]: extra"
profile_error "markdown that is not a table" 'markdown = 1' "devkit.toml: markdown must be the table [markdown]"
profile_error "profiles that is not a table" '[markdown]
profiles = ["a"]' "devkit.toml: markdown.profiles must be the table [markdown.profiles]"
for subtree in /abs ../up a/../b ./docs docs/ . ""; do
  profile_error "subtree '$subtree'" "[markdown.profiles]
\"$subtree\" = \".claude/.markdownlint.jsonc\"" "devkit.toml: [markdown.profiles] subtree '$subtree' is not a relative, normalized path"
done
profile_error "a config path with .." '[markdown.profiles]
".claude" = "../x.jsonc"' "devkit.toml: [markdown.profiles] config '../x.jsonc' is not a relative, normalized path"
profile_error "a config that is not a string" '[markdown.profiles]
".claude" = 1' "devkit.toml: [markdown.profiles] config 1 is not a relative, normalized path"
profile_error "a config that is not .jsonc" '[markdown.profiles]
".claude" = "README.md"' "devkit.toml: [markdown.profiles] config 'README.md' is not a .jsonc file in the project"
profile_error "a missing config" '[markdown.profiles]
".claude" = "nope.jsonc"' "devkit.toml: [markdown.profiles] config 'nope.jsonc' is not a .jsonc file in the project"
profile_error "a subtree with no Markdown file" '[markdown.profiles]
".clude" = ".claude/.markdownlint.jsonc"' "devkit.toml: [markdown.profiles] subtree '.clude' holds no Markdown file lint-md checks"
profile_error "an unquoted dotted subtree" '[markdown.profiles]
docs.agents = "x.jsonc"' "devkit.toml: [markdown.profiles] config {'agents': 'x.jsonc'} is not a relative, normalized path inside the project; quote a subtree that holds a dot"

# No profiles: no devkit.toml, or one without [markdown].
rm "$proj/devkit.toml"
expect "no devkit.toml behaves as without profiles" 0 -- "lint-md: 6 Markdown files checked."
printf '[pins]\nextra = []\n' >"$proj/devkit.toml"
rm "$LOG/mdl"
expect "a devkit.toml without [markdown] behaves as without profiles" 0 -- "lint-md: 6 Markdown files checked."
holds "all files run in one group" [ "$(wc -l <"$LOG/mdl")" = 2 ]

# A file name that is not UTF-8 reaches node byte for byte.
latin1=$(printf 'r\xe9.md')
project README.md ".claude/$latin1"
printf '{}\n' >"$proj/.claude/.markdownlint.jsonc"
printf '[markdown.profiles]\n".claude" = ".claude/.markdownlint.jsonc"\n' >"$proj/devkit.toml"
expect "a file name that is not UTF-8 passes" 0 -- "lint-md: 2 Markdown files checked."
holds "it reaches node unchanged" count mdl "$proj | $lint $mods .claude/.markdownlint.jsonc $(printf %q ".claude/$latin1") |" 1

[[ $fails == 0 ]]
