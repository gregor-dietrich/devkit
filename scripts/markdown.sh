#!/bin/bash

set -euo pipefail

# Check the project's Markdown with markdownlint-cli (lint-md), or with --fix
# fix what it can (format-md), at the closure markdown/package-lock.json pins
# (docs/contract.md). Usage: markdown.sh [--fix]

case $#:${1-} in
    0:) fix=() label=lint-md verb=check ;;
    1:--fix) fix=(--fix) label=format-md verb=fix ;;
    *)
        echo "lint-md: unknown argument '$*'; usage: markdown.sh [--fix]" >&2
        exit 2
        ;;
esac

die() {
    echo "ERROR: $*" >&2
    exit 1
}

cd "$PROJECT_ROOT"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

# The *.md files git lists (tracked, plus untracked ones not ignored), each
# once; a tracked file deleted from disk, and a symlink, which --fix would
# write through, are skipped. Filtered here rather than by a pathspec, which
# GIT_LITERAL_PATHSPECS would turn into a literal name.
git ls-files -z --cached --others --exclude-standard >"$tmp/list" 2>"$tmp/err" ||
    die "git cannot list the files in $PROJECT_ROOT: $(head -n 1 "$tmp/err")"
files=()
while IFS= read -r -d '' file; do
    [[ $file != *.md || ! -e $file || -L $file ]] || files+=("$file")
done < <(LC_ALL=C sort -zu "$tmp/list")
if [[ ${#files[@]} == 0 ]]; then
    echo "$label: no Markdown files; nothing to check."
    exit 0
fi

# shellcheck source=SCRIPTDIR/lib/node_closure.sh
. "$DEVKIT/scripts/lib/node_closure.sh"
node_closure "$DEVKIT/markdown" markdownlint "$label"

# mdl ARGS...: markdownlint without the user configuration it merges beneath
# --config: markdownlint_* variables and the files it reads from $HOME. The
# names come from env -0: compgen -e skips names bash cannot hold, such as
# markdownlint_line-length, which markdownlint still reads.
mkdir "$tmp/home"
mdl() {
    local entry name drop=()
    while IFS= read -r -d '' entry; do
        name=${entry%%=*}
        [[ ${name,,} != markdownlint_* ]] || drop+=(-u "$name")
    done < <(env -0)
    env ${drop[@]+"${drop[@]}"} HOME="$tmp/home" "$NODE_TOOL" "$@"
}

# Detector controls: devkit's profile must flag the invalid files and pass the
# clean one, or a passing run would prove nothing. Never with --fix.
config=$DEVKIT/markdown/markdownlint.jsonc
rc=0
out=$(cd "$DEVKIT/markdown/controls" && mdl --config "$config" -- clean.md invalid.md long-line.md 2>&1) || rc=$?
control() { # control EXPECTATION: print the run, fail naming EXPECTATION
    printf '%s\n' "$out" >&2
    die "markdownlint's detector control failed: $1"
}
[[ $rc != 0 ]] || control "it passed invalid.md and long-line.md"
grep -q '^invalid\.md:.*MD018/no-missing-space-atx' <<<"$out" ||
    control "invalid.md was not reported for MD018/no-missing-space-atx"
grep -q '^long-line\.md:.*MD013/line-length' <<<"$out" ||
    control "long-line.md was not reported for MD013/line-length"
! grep -q '^clean\.md:' <<<"$out" || control "clean.md was reported"

[[ ! -f .markdownlint.jsonc ]] || config=$PROJECT_ROOT/.markdownlint.jsonc
rc=0
mdl --config "$config" ${fix[@]+"${fix[@]}"} -- "${files[@]}" || rc=$?
# format-md rewrites and never judges: what --fix leaves (exit 1, findings) is
# lint-md's to fail on, so make format still reaches the language formatter.
if [[ $rc == 1 && $label == format-md ]]; then
    echo "format-md: NOTE: markdownlint cannot fix the findings above; make lint will fail on these."
elif [[ $rc != 0 ]]; then
    echo "$label: markdownlint $verb FAILED; see the findings above." >&2
    exit 1
fi
echo "$label: ${#files[@]} Markdown files checked."
