#!/bin/bash
# Warn, never fail, when a branch checkout lands on a stale base: a stale base
# carries stale build and gate configuration (the devkit pin included), not
# just stale code. scripts/hooks.sh renders this file into the post-checkout
# hook as a self-contained copy and runs it with the hook's name prepended to
# git's arguments. Two independent warnings, both offline (a hook must not
# touch the network):
#
#   1. HEAD does not contain the last-known tip of the base, origin/HEAD's
#      target (origin/main when origin/HEAD is not set).
#   2. That knowledge is itself old: no sign of a fetch in the last 60
#      minutes, so a clean check 1 proves little.
#
# Check 2 takes every file a fetch or clone leaves behind and calls the
# knowledge fresh if any is recent. FETCH_HEAD is per worktree while the
# remote refs are shared, so a fetch from any worktree counts: this
# worktree's FETCH_HEAD, the common one, and each sibling's. A fresh clone
# writes no FETCH_HEAD but does write origin/HEAD's reflog, and a fetch that
# moves the base writes the base's; both count, and can prove a fetch recent
# but never old. It errs towards silence: any fetch, of any remote or ref,
# counts, and under the reftable ref backend (no reflog files) a fresh clone
# reads as never fetched until its first fetch.
#
# Silent on a file checkout (third argument 0), on a detached HEAD (bisect,
# rebase, looking at an old commit) and without a base ref. It must never
# exit non-zero nor change anything: post-checkout's status becomes the
# checkout's, and a stale base is sometimes deliberate. bash 3.2 (macOS).

hook="${1:-unknown}"
shift || true
[[ "${3:-}" == "1" ]] || exit 0
git symbolic-ref --quiet HEAD > /dev/null 2>&1 || exit 0

base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null)" || base=""
base="${base:-origin/main}"
stale_minutes=60

tip="$(git rev-parse --verify --quiet "refs/remotes/$base^{commit}")" || exit 0
[[ -n "$tip" ]] || exit 0

if ! git merge-base --is-ancestor "$tip" HEAD 2> /dev/null; then
    branch="$(git symbolic-ref --quiet --short HEAD 2> /dev/null)"
    echo ""
    echo "WARNING: ${branch:-HEAD} does not contain $base (${tip:0:12}), so it is based"
    echo "         on an older ${base#origin/} than this clone has already fetched, with"
    echo "         stale build and gate configuration, not just stale code."
    # The default branch itself is brought up to date, never rebased.
    if [[ "$branch" == "${base#origin/}" ]]; then
        echo "         Bring it up to date: git pull --ff-only (or git merge"
        echo "         --ff-only $base). Noticed by the $hook hook."
    else
        echo "         If that is not deliberate, rebase it: git rebase $base."
        echo "         Noticed by the $hook hook."
    fi
fi

# A candidate is fresh when it exists and `find -mmin +N` does not select it;
# `find` rather than `stat`, whose flags differ between GNU and BSD.
common="$(git rev-parse --git-common-dir 2> /dev/null)"
fresh=0
seen=0
shopt -s nullglob
for evidence in \
    "$(git rev-parse --git-path FETCH_HEAD 2> /dev/null)" \
    "$common/FETCH_HEAD" \
    "$common"/worktrees/*/FETCH_HEAD \
    "$common/logs/refs/remotes/$base" \
    "$common/logs/refs/remotes/origin/HEAD"; do
    [[ -f "$evidence" ]] || continue
    seen=1
    if [[ -z "$(find "$evidence" -prune -mmin +"$stale_minutes" 2> /dev/null)" ]]; then
        fresh=1
    fi
done
shopt -u nullglob

if [[ "$fresh" -eq 0 ]]; then
    if [[ "$seen" -eq 0 ]]; then
        age="has never been fetched here (no FETCH_HEAD or origin reflog)"
    else
        age="was last fetched more than $stale_minutes minutes ago"
    fi
    echo ""
    echo "WARNING: $base $age,"
    echo "         so this clone's idea of its newest ${base#origin/} may itself be stale."
    echo "         Run 'git fetch origin' and re-check. Noticed by the $hook hook."
fi
exit 0
