#!/bin/bash
# The push gate: `make lint-repo test`. scripts/hooks.sh renders this file
# into the pre-push hook as a self-contained copy and runs it with the hook's
# name prepended to git's arguments. Skip it once with `git push --no-verify`;
# CI stays the backstop.
#
# It gates the work tree at HEAD, not the commits git names on stdin: it says
# so when a pushed commit is not HEAD, or when the tree is dirty.
#
# git sends the ref lines on one stdin, which an up-to-date push leaves empty.
# Installed as `pre-push` itself, zero lines therefore means nothing to push.
# Under any other name (pre-push.devkit called from someone else's hook, or
# pre-push.legacy/.old run by a hook manager) that hook may have read stdin
# first, so zero lines runs the gate. bash 3.2 (macOS): no mapfile.

root="$(git rev-parse --show-toplevel)" || exit 1
# See pre-commit.sh: the gate sees the repository as a plain shell would.
while IFS= read -r var; do
    unset "$var"
done < <(git rev-parse --local-env-vars)
cd "$root" || exit 1

head="$(git rev-parse --verify --quiet HEAD)"
# One "<local ref> <local sha> <remote ref> <remote sha>" line per ref; an
# all-zero local sha is a deletion, which carries no commit to gate. A tag is
# peeled to the commit it names.
lines=0
pushed=0
not_head=""
while read -r local_ref local_sha _ _; do
    [[ -n "$local_sha" ]] || continue
    lines=$((lines + 1))
    [[ ! "$local_sha" =~ ^0+$ ]] || continue
    pushed=1
    commit="$(git rev-parse --verify --quiet "$local_sha^{commit}")" || commit="$local_sha"
    [[ "$commit" == "$head" ]] || not_head="$not_head $local_ref"
done

if [[ "$lines" -eq 0 ]]; then
    [[ "${0##*/}" != "pre-push" ]] || exit 0
    echo "pre-push: git sent no refs (another hook may have read them); gating HEAD"
elif [[ "$pushed" -eq 0 ]]; then
    echo "pre-push: nothing but deletions, no commit to gate"
    exit 0
fi

if [[ -n "$not_head" ]]; then
    echo "WARNING: pushing$not_head, which is not HEAD. The gate below checks the"
    echo "         work tree at HEAD, so its verdict is not about what you push."
fi
if [[ -n "$(git status --porcelain 2> /dev/null)" ]]; then
    echo "WARNING: the work tree is dirty, so the gate below checks your"
    echo "         uncommitted edits too, not just the commits being pushed."
fi

echo "pre-push: make lint-repo test (skip once with 'git push --no-verify')"
# stdin carried git's ref lines, read above; /dev/null keeps a child that
# reads stdin from waiting on the terminal.
exec make --no-print-directory lint-repo test < /dev/null
