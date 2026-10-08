#!/bin/bash
# Install or report the project's git hooks (docs/contract.md, Git hooks).
# Usage: scripts/hooks.sh install   (make hooks)
#        scripts/hooks.sh status    (make check-hooks, part of make check)
#
#   pre-commit     make lint-repo              scripts/hooks/pre-commit.sh
#   pre-push       make lint-repo test         scripts/hooks/pre-push.sh
#                  (skipped for a HEAD that make gate passed on a clean tree)
#   post-checkout  pin and stale-base notices  pin-notice.sh, stale-base-notice.sh
#   post-merge     pin notice                  pin-notice.sh
#   post-rewrite   pin notice                  pin-notice.sh
#
# Each hook is a self-contained copy of the parts in $DEVKIT/scripts/hooks/,
# never a call into the work tree: a hook that ran a tracked script would let
# a mere checkout of a branch run that branch's code. The notices run no make
# target and nothing the work tree supplies: they read devkit.toml as data,
# and of .devkit only the link, so a checkout, merge or rewrite runs no code
# the branch brings. The gates run the work tree's make targets, as a `make`
# there would. The hooks act only when the project is the git top level,
# which `install` requires. The price of copies is staleness: a new devkit
# reaches the hooks only through `make hooks`, and `status` says when a copy
# differs from what the pinned devkit renders. Every worktree of a clone
# shares one hooks directory, so worktrees pinned to different devkit
# versions report each other's copies as stale.
#
# A hook devkit did not write (no stamp line) is never overwritten.

set -euo pipefail

cd "$PROJECT_ROOT"

hooks="pre-commit pre-push post-checkout post-merge post-rewrite"
stamp="# devkit:managed-hook"
side=.devkit            # beside a foreign hook, which calls it
migrated=".legacy .old" # where hook managers move the hook they replace

# parts HOOK: the scripts/hooks/ files HOOK is built from.
parts() {
    case $1 in
        pre-commit) echo pre-commit.sh ;;
        pre-push) echo pre-push.sh ;;
        post-checkout) echo pin-notice.sh stale-base-notice.sh ;;
        post-merge | post-rewrite) echo pin-notice.sh ;;
    esac
}

# render HOOK: the hook built from $DEVKIT's parts; fails on a missing part.
# Each part runs in a subshell with HOOK prepended to git's arguments, so its
# `exit` ends only that part. A gate's status is the hook's; a notice's never
# is (post-checkout's status becomes the checkout's).
render() {
    local part text tail=' || true'
    [[ $1 != pre-commit && $1 != pre-push ]] || tail=' || exit $?'
    # shellcheck disable=SC2016 # the hook expands these, not this script
    printf '%s\n' '#!/bin/bash' "$stamp" \
        "# Self-contained copy written by 'make hooks'; 'make check' says when it is stale." \
        'root="$(git rev-parse --show-toplevel 2> /dev/null)" || exit 0' \
        '[[ -f "$root/devkit.toml" && -f "$root/Makefile" ]] || exit 0'
    for part in $(parts "$1"); do
        text=$(sed '1{/^#!/d;}' "$DEVKIT/scripts/hooks/$part") || return 1
        # shellcheck disable=SC2016 # "$@" is the hook's
        printf '( set -- %s "$@"\n%s\n)%s\n' "$1" "$text" "$tail"
    done
    echo 'exit 0'
}

# ours PATH: PATH is a file devkit wrote, so install may replace it. A symlink
# to such a file counts, so that install replaces the link with a regular
# file; it is never "already installed" nor clean in `status`.
ours() { [[ -f $1 ]] && grep -qxF "$stamp" "$1" 2>/dev/null; }
present() { [[ -e $1 || -L $1 ]]; } # a dangling symlink too

# physical PATH: PATH absolute and physical (`pwd -P`), so a symlink cannot
# make one directory look like another. PATH need not exist: its nearest
# existing ancestor is resolved and the rest appended; fails when that rest
# holds a `.` or `..`, which only the kernel could place (x/../.. leaves the
# directory it seems to be under). No `realpath -m` (macOS) and no
# `--path-format=absolute` for git (needs git 2.31): git answers relative to
# the current directory.
physical() {
    local path=$1 rest=""
    [[ $path == /* ]] || path=$PWD/$path
    while [[ ! -d $path ]]; do
        case ${path##*/} in . | ..) return 1 ;; esac
        rest=/${path##*/}$rest
        path=$(dirname "$path")
    done
    path=$(cd "$path" && pwd -P) || return 1
    printf '%s\n' "${path%/}$rest"
}

# locate: sets top (the work tree's top level), common_dir (the clone's
# common git directory), hooks_dir (wherever core.hooksPath, any scope, `~`
# expanded by git, sends the hooks) and private (yes when hooks_dir lies
# inside common_dir), all physical; cds to top, where git resolves a relative
# core.hooksPath. Only the clone's own git directory is private: in a work
# tree a branch's tracked files would supply the hooks, and a directory
# shared with other clones would run them in repositories that merely look
# like a devkit project.
locate() {
    local raw
    top=$(git rev-parse --show-toplevel) && top=$(cd "$top" && pwd -P) && cd "$top" &&
        common_dir=$(physical "$(git rev-parse --git-common-dir)") &&
        raw=$(git rev-parse --git-path hooks) || return 1
    private=no
    if hooks_dir=$(physical "$raw"); then
        [[ $hooks_dir/ != "$common_dir"/* ]] || private=yes
    else
        hooks_dir=$raw
    fi
}

# write_copy PATH CONTENT LABEL: install CONTENT at PATH unless it is already
# that. Atomic: a temporary file beside PATH, made executable, renamed over
# it, so a hook running in another worktree reads the old copy or the new one,
# never a half-written file; the rename replaces a symlink at PATH rather than
# writing through it.
write_copy() {
    local tmp
    if [[ -f $1 && ! -L $1 && -x $1 && "$(cat "$1")" == "$2" ]]; then
        echo "$3 already installed."
        return
    fi
    if [[ -d $1 ]]; then # mv would move into it, a symlink's target included
        echo "ERROR: $1 is a directory; move it away and re-run 'make hooks'." >&2
        exit 1
    fi
    if present "$1"; then echo "Updated $3 (the installed copy was stale)."; else echo "Installed $3."; fi
    tmp=$(mktemp "$1.XXXXXX")
    if ! { printf '%s\n' "$2" >"$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$1"; }; then
        rm -f "$tmp"
        echo "ERROR: cannot write $1." >&2
        exit 1
    fi
}

# advise HOOK SIDE: the line(s) that make a foreign HOOK run devkit's SIDE copy.
advise() {
    echo "WARNING: $hooks_dir/$1 is not devkit's; leaving it alone."
    echo "         devkit's $1 hook is installed beside it as $2."
    # shellcheck disable=SC2016 # printed for the hook, which expands them
    if [[ $1 == pre-push ]]; then
        # git sends pre-push its refs on one stdin: these lines read it once,
        # pass it to devkit's copy, then hand the rest of the hook the same
        # lines. POSIX sh, since that hook may be #!/bin/sh.
        echo "         To run it, add these lines at the top of your hook, before"
        echo "         anything that reads stdin or runs 'exec' or 'exit':"
        echo '           dk_refs=$(mktemp) || exit $?'
        echo '           cat >"$dk_refs" && "$(dirname "$0")/'"$1$side"'" "$@" <"$dk_refs" || { dk_rc=$?; rm -f "$dk_refs"; exit "$dk_rc"; }'
        echo '           exec <"$dk_refs"; rm -f "$dk_refs"'
    else
        echo "         To run it, add this line near the top of your hook, before"
        echo "         any line that runs 'exec' or 'exit':"
        echo '           "$(dirname "$0")/'"$1$side"'" "$@" || exit $?'
    fi
}

# remove_orphan SIDE HOOK: remove devkit's SIDE copy, which no hook calls now.
remove_orphan() {
    if [[ -f $1 && ! -L $1 ]] && ours "$1"; then
        rm -f "$1"
        echo "Removed the orphaned ${1##*/} (no $2 hook calls it)."
    fi
}

install_hooks() {
    local hook content target suffix moved project failed=0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
        { echo "ERROR: $PROJECT_ROOT is not a git work tree; no hooks installed." >&2; exit 1; }
    project=$(pwd -P)
    locate || { echo "ERROR: cannot locate this clone's hooks directory." >&2; exit 1; }
    if [[ $project != "$top" ]]; then
        echo "ERROR: make hooks needs the project at the git top level ($top); hooks there would do nothing." >&2
        exit 1
    fi
    if [[ $private != yes ]]; then
        echo "ERROR: core.hooksPath sends this clone's hooks to $hooks_dir, outside its" >&2
        echo "       git directory $common_dir, where a branch could supply them or other" >&2
        echo "       repositories would run them. No hooks were installed. Point this" >&2
        echo "       clone at its own hooks directory instead:" >&2
        echo "         git config core.hooksPath \"$common_dir/hooks\"" >&2
        echo "       That overrides a global core.hooksPath for this clone: hooks kept" >&2
        echo "       there stop running here unless the hooks in that directory call them." >&2
        exit 1
    fi
    mkdir -p "$hooks_dir"
    for hook in $hooks; do
        content=$(render "$hook") ||
            { echo "ERROR: cannot build the $hook hook from $DEVKIT/scripts/hooks/." >&2; exit 1; }
        target=$hooks_dir/$hook
        # A copy of ours that a hook manager moved aside still runs from its
        # hook: refresh it where it is.
        moved=""
        for suffix in $migrated; do
            if ours "$target$suffix"; then
                write_copy "$target$suffix" "$content" "the $hook copy your hook manager runs as $hook$suffix"
                moved=$target$suffix
            fi
        done
        if present "$target" && ! ours "$target"; then
            if [[ -n $moved ]]; then
                echo "Hook $hook is not devkit's, but it runs devkit's copy $moved."
                remove_orphan "$target$side" "$hook"
            elif present "$target$side" && ! ours "$target$side"; then
                echo "ERROR: $target$side is not devkit's copy; move it away and re-run 'make hooks'." >&2
                failed=1
            else
                write_copy "$target$side" "$content" "the $hook copy beside your own $hook"
                if grep -qF "/$hook$side\"" "$target" 2>/dev/null; then
                    echo "Hook $hook is not devkit's but already calls $hook$side; leaving it alone."
                else
                    advise "$hook" "$target$side"
                fi
            fi
            continue
        fi
        write_copy "$target" "$content" "$hook hook"
        remove_orphan "$target$side" "$hook"
    done
    return "$failed"
}

# Advisory only, so it never fails: missing hooks are a NOTE, stale (a
# symlinked copy included) or non-executable copies of ours a WARNING, foreign
# hooks nothing (install said so once; repeating it on every `make check`
# would nag about a choice). A layout install refuses gets one NOTE instead.
report_hooks() {
    local hook installed copy suffix expected missing="" stale="" noexec="" copies project
    [[ ${CI:-} != true ]] || return 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    project=$(pwd -P)
    locate || return 0
    if [[ $project != "$top" ]]; then
        echo "NOTE: this project is below the git top level ($top), where devkit's git hooks would do nothing, so they are not installed."
        return 0
    fi
    if [[ $private != yes ]]; then
        echo "NOTE: core.hooksPath sends this clone's hooks to $hooks_dir, outside its git directory, so devkit's git hooks are not installed; 'make hooks' says what to do."
        return 0
    fi
    for hook in $hooks; do
        installed=$hooks_dir/$hook
        if ! present "$installed"; then
            missing="$missing $hook"
            continue
        fi
        copies=()
        if ours "$installed"; then
            copies=("$installed")
        else
            for suffix in $side $migrated; do
                ! ours "$installed$suffix" || copies+=("$installed$suffix")
            done
        fi
        [[ ${#copies[@]} -gt 0 ]] || continue
        expected=$(render "$hook" 2>/dev/null) || continue
        for copy in "${copies[@]}"; do
            if [[ -L $copy || "$(cat "$copy" 2>/dev/null)" != "$expected" ]]; then
                stale="$stale ${copy##*/}"
            elif [[ ! -x $copy ]]; then
                noexec="$noexec ${copy##*/}"
            fi
        done
    done
    [[ -z $missing ]] ||
        echo "NOTE: the git hooks$missing are not installed in this clone; run 'make hooks' to gate commits and pushes locally."
    [[ -z $stale ]] ||
        echo "WARNING: the installed git hooks$stale differ from what the pinned devkit installs; run 'make hooks' to refresh them (worktrees pinned to other devkit versions share them and report them stale too)."
    [[ -z $noexec ]] ||
        echo "WARNING: the installed git hooks$noexec are not executable, so git skips them; run 'make hooks' to restore them."
}

case ${1-} in
    install) install_hooks ;;
    status) report_hooks || true ;;
    *)
        echo "usage: scripts/hooks.sh install|status" >&2
        exit 2
        ;;
esac
