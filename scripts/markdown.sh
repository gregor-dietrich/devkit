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
tmp=$(mktemp -d) stage=
trap 'rm -rf "$tmp" ${stage:+"$stage"}' EXIT
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

# Node.js at or above the closure's floor, engines.node in package.json.
floor=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["engines"]["node"])' \
    "$DEVKIT/markdown/package.json" 2>/dev/null) || floor=
[[ $floor =~ ^\>=([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
    die "$DEVKIT/markdown/package.json has no engines.node of the form '>=X.Y.Z'"
floor=${BASH_REMATCH[1]}
command -v node >/dev/null || die "node not found; $label needs Node.js >= $floor and npm on PATH."
found=$(node --version 2>/dev/null) || found=
version=${found#v}
version=${version%%-*} # a prerelease (-nightly..., -rc...) counts as its release
[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] ||
    die "cannot read a version from 'node --version' ('$found'); $label needs Node.js >= $floor."
printf -v versions '%s\n%s' "$floor" "$version"
[[ $versions == "$(sort -V <<<"$versions")" ]] ||
    die "Node.js $found on PATH is below $floor, which devkit's markdownlint closure requires."

# The pinned closure, installed once per lockfile into the user's cache.
root=${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools
[[ $root == /* ]] || die "cache root $root is not an absolute path"
if command -v sha256sum >/dev/null; then
    sum=(sha256sum)
elif command -v shasum >/dev/null; then
    sum=(shasum -a 256)
else
    die "neither sha256sum nor shasum found; $label needs one to key its cache"
fi
key=$(cat "$DEVKIT/markdown/package.json" "$DEVKIT/markdown/package-lock.json" | "${sum[@]}")
dir=$root/markdownlint-${key:0:16}
bin=$dir/node_modules/.bin/markdownlint
if [[ -e $dir || -L $dir ]]; then
    [[ -x $bin ]] || die "$dir is incomplete; remove it and retry"
else
    command -v npm >/dev/null || die "npm not found; $label needs it on PATH to install markdownlint-cli once."
    mkdir -p "$root"
    stage=$(mktemp -d "$root/.tmp.XXXXXX")
    cp "$DEVKIT/markdown/package.json" "$DEVKIT/markdown/package-lock.json" "$stage/"
    echo "$label: installing markdownlint-cli into $dir..."
    (cd "$stage" && NPM_CONFIG_UPDATE_NOTIFIER=false npm ci --ignore-scripts --no-audit --no-fund --loglevel=error) ||
        die "cannot install markdownlint-cli (npm ci failed; the first run needs the npm registry)"
    [[ -x $stage/node_modules/.bin/markdownlint ]] ||
        die "npm ci did not install markdownlint (check npm's bin-links setting)"
    # Read-only, so an edit inside the cache cannot change every project's gate.
    find "$stage" -type f -exec chmod a-w {} +
    mv "$stage" "$dir"
    rm -rf "${dir:?}/${stage##*/}" # a concurrent run won: mv nested ours in it
    stage=
fi

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
    env ${drop[@]+"${drop[@]}"} HOME="$tmp/home" "$bin" "$@"
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
