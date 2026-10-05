#!/bin/bash
# The commit gate: `make lint-repo`. scripts/hooks.sh renders this file into
# the pre-commit hook as a self-contained copy and runs it with the hook's
# name prepended to git's arguments. Skip it once with
# `git commit --no-verify`; CI stays the backstop.
#
# It checks the work tree, not the staged index, so an unstaged fix can let a
# commit through whose staged content would fail, and the reverse.
# bash 3.2 (macOS): no mapfile.

root="$(git rev-parse --show-toplevel)" || exit 1
# git hands its hooks repository pointers (GIT_DIR, GIT_INDEX_FILE, ...); the
# gate must see the repository as a plain shell at the top level would. A
# `git -c key=value commit` override is one of them, and does not reach it.
while IFS= read -r var; do
    unset "$var"
done < <(git rev-parse --local-env-vars)
cd "$root" || exit 1

echo "pre-commit: make lint-repo (skip once with 'git commit --no-verify')"
exec make --no-print-directory lint-repo < /dev/null
