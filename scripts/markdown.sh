#!/bin/bash

set -euo pipefail

# Check the project's Markdown with markdownlint (lint-md), or with --fix fix
# what it can (format-md), at the closure markdown/package-lock.json pins
# (docs/contract.md), each file under its subtree's [markdown.profiles]
# configuration or the default one. Usage: markdown.sh [--fix]

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

# mdl [--fix] MODULES CONFIG FILE...: markdown/lint.mjs, which reads CONFIG and
# its extends chain only, unlike markdownlint-cli, which merges rc files, /etc
# and HOME files, and the cwd's .markdownlint.* beneath --config.
modules=${NODE_TOOL%/.bin/*}
mdl() { node "$DEVKIT/markdown/lint.mjs" "$@"; }

# Detector controls: devkit's profile must flag the invalid files and pass the
# clean one, or a passing run would prove nothing. Never with --fix.
config=$DEVKIT/markdown/markdownlint.jsonc
rc=0
out=$(cd "$DEVKIT/markdown/controls" && mdl "$modules" "$config" clean.md invalid.md long-line.md 2>&1) || rc=$?
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
# shellcheck source=SCRIPTDIR/lib/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor || exit 1
printf '%s\0' "${files[@]}" | python3 -I "$DEVKIT/scripts/markdown_profiles.py" "$config" >"$tmp/groups" || exit 1

found=false failed=false
while IFS= read -r -d '' config; do
    group=()
    while IFS= read -r -d '' file && [[ -n $file ]]; do group+=("$file"); done
    rc=0
    mdl ${fix[@]+"${fix[@]}"} "$modules" "$config" "${group[@]}" || rc=$?
    case $rc in 0) ;; 1) found=true ;; *) failed=true ;; esac
done <"$tmp/groups"
# format-md rewrites and never judges: what --fix leaves (exit 1, findings) is
# lint-md's to fail on, so make format still reaches the language formatter.
if [[ $failed == true || ($found == true && $label == lint-md) ]]; then
    echo "$label: markdownlint $verb FAILED; see the findings above." >&2
    exit 1
elif [[ $found == true ]]; then
    echo "format-md: NOTE: markdownlint cannot fix the findings above; make lint will fail on these."
fi
echo "$label: ${#files[@]} Markdown files checked."
