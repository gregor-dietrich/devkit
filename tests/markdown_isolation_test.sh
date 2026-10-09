#!/usr/bin/env bash
# Real-tool tests for markdown/lint.mjs through scripts/markdown.sh: the real node
# and the markdownlint closure in the user's cache (installed on first use, which
# needs the npm registry). A rc file, a .markdownlint.json or a markdownlint_*
# variable must not reach the configuration, a profile reads its own file and its
# extends chain, and lint.mjs prints what markdownlint-cli prints. Prints
# PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # one argument per variable name
unset $(git rev-parse --local-env-vars) $(compgen -e | grep -i '^markdownlint_' || :)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=devkit GIT_AUTHOR_EMAIL=devkit@example.invalid
export GIT_COMMITTER_NAME=devkit GIT_COMMITTER_EMAIL=devkit@example.invalid
proj=$work/proj fails=0 extra=()

export DEVKIT=$root
# shellcheck source=SCRIPTDIR/../scripts/lib/node_closure.sh
. "$root/scripts/lib/node_closure.sh"
node_closure "$root/markdown" markdownlint markdown_isolation_test

# project FILE...: a fresh project with each FILE a heading missing its space
project() {
  rm -rf "$proj"
  git init -q -b main "$proj"
  local file
  for file; do
    mkdir -p "$(dirname "$proj/$file")"
    echo "#Title" >"$proj/$file"
  done
}

# expect LABEL WANT-STATUS [ARG...] -- TEXT...: run scripts/markdown.sh with ARGs
# in the project and the variables in $extra; the output must contain each TEXT,
# and none of those that start with "!".
expect() {
  local label=$1 want=$2 args=() out rc=0 text ok=true
  shift 2
  while [[ $1 != -- ]]; do args+=("$1") && shift; done
  shift
  git -C "$proj" add -A
  out=$(cd "$proj" && env ${extra[@]+"${extra[@]}"} PROJECT_ROOT="$proj" \
    "$root/scripts/markdown.sh" ${args[@]+"${args[@]}"} 2>&1) || rc=$?
  for text in "$@"; do
    if [[ $text == '!'* ]]; then [[ $out != *"${text#!}"* ]] || ok=false; else [[ $out == *"$text"* ]] || ok=false; fi
  done
  if [[ $rc == "$want" && $ok == true ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and [$*] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

failed="lint-md: markdownlint check FAILED"
project README.md
echo '{"MD018": false}' >"$proj/.markdownlintrc"
expect "a root .markdownlintrc does not hide MD018" 1 -- "README.md:1:1 error MD018" "$failed"
project README.md
echo '{"MD018": false}' >"$proj/.markdownlint.json"
expect "a root .markdownlint.json does not hide MD018" 1 -- "README.md:1:1 error MD018" "$failed"
project README.md
extra=(markdownlint_md018=) # empty: markdownlint-cli reads it as off
expect "a markdownlint_md018 variable does not hide MD018" 1 -- "README.md:1:1 error MD018" "$failed"
extra=()

project README.md .claude/x.md
echo '{"MD018": false}' >"$proj/.markdownlint.jsonc"
echo '{"default": true}' >"$proj/.claude/.markdownlint.jsonc"
printf '[markdown.profiles]\n".claude" = ".claude/.markdownlint.jsonc"\n' >"$proj/devkit.toml"
expect "the root .markdownlint.jsonc does not reach a profile" 1 -- \
  ".claude/x.md:1:1 error MD018" "!README.md:1:1 error MD018" "$failed"
echo '{"extends": "../.markdownlint.jsonc"}' >"$proj/.claude/.markdownlint.jsonc"
expect "a profile that extends the root file inherits it" 1 -- \
  "!MD018" "README.md:1 error MD041" ".claude/x.md:1 error MD041"
echo '{"default": false}' >"$proj/.markdownlint.jsonc"
expect "a profile that extends the root file passes under it" 0 -- "lint-md: 2 Markdown files checked."

project README.md bad.md
echo "# Title" >"$proj/README.md"
echo "bad.md" >"$proj/.markdownlintignore"
expect ".markdownlintignore excludes a file" 0 -- "lint-md: 2 Markdown files checked."

project README.md
expect "format-md rewrites #Title" 0 --fix -- "format-md: 1 Markdown files checked."
if [[ $(<"$proj/README.md") == "# Title" ]]; then echo "PASS --fix wrote the space"; else
  echo "FAIL --fix left: $(<"$proj/README.md")"
  fails=$((fails + 1))
fi

project README.md
echo '{"MD018": ' >"$proj/.markdownlint.jsonc"
expect "an invalid configuration fails lint-md" 1 -- "Unable to parse JSON(C)" "$failed"
expect "an invalid configuration fails format-md, not as findings" 1 --fix -- \
  "Unable to parse JSON(C)" "format-md: markdownlint fix FAILED" "!NOTE"

# Parity: markdownlint-cli with nothing to merge prints what lint.mjs prints,
# both on a copy of the controls in the temp dir, away from devkit's tree.
mkdir "$work/home"
cp -R "$root/markdown/controls" "$work/controls"
(cd "$work/controls" && HOME=$work/home "$NODE_TOOL" --config "$root/markdown/markdownlint.jsonc" -- ./*.md) \
  2>"$work/cli" || :
(cd "$work/controls" && node "$root/markdown/lint.mjs" "${NODE_TOOL%/.bin/*}" "$root/markdown/markdownlint.jsonc" ./*.md) \
  2>"$work/lint" || :
if [[ -s $work/cli ]] && cmp -s "$work/cli" "$work/lint"; then
  echo "PASS lint.mjs prints what markdownlint-cli prints on the control files"
else
  echo "FAIL lint.mjs and markdownlint-cli differ on the control files:"
  diff "$work/cli" "$work/lint" || :
  fails=$((fails + 1))
fi

[[ $fails == 0 ]]
