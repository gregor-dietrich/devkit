#!/bin/bash
# Say, never fail, when a checkout, merge or rewrite moved the devkit pin away
# from what .devkit links to. scripts/hooks.sh renders this file into the
# post-checkout, post-merge and post-rewrite hooks as a self-contained copy
# and runs it with the hook's name prepended to git's arguments.
#
# It runs on a mere checkout, so it executes nothing the work tree supplies:
# devkit.toml is read as data with devkitw's own reader, and only when it is a
# regular file, not a symlink. `make check` (devkitw) does the relinking.
# It must never exit non-zero: post-checkout's status becomes the checkout's.

hook="${1:-unknown}"
shift || true
# post-checkout's third argument is 0 for a file checkout (`git checkout --
# path`), which this skips.
[[ "$hook" != "post-checkout" || "${3:-1}" != "0" ]] || exit 0

root="$(git rev-parse --show-toplevel 2> /dev/null)" || exit 0
cd "$root" || exit 0
[[ -f devkit.toml && ! -L devkit.toml ]] || exit 0

# key NAME: the double-quoted value of NAME in the [devkit] table, else empty.
key() {
  s='[[:space:]]*'
  sed -n -e "/^$s\[devkit\]/,/^$s\[/!d" \
    -e "s/^$s$1$s=$s\"\([^\"]*\)\".*/\1/p" devkit.toml | head -n 1
}
commit="$(key commit)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || exit 0
version="$(key version | tr -d '[:cntrl:]')"
linked="$(readlink .devkit 2> /dev/null)" || linked=""
linked="${linked%/}"
linked="${linked##*/}"
[[ "$linked" != "$commit" ]] || exit 0
other="$(printf '%s' "${linked:0:12}" | tr -d '[:cntrl:]')"

echo "NOTE: devkit.toml now pins devkit $version (${commit:0:12}), but .devkit points at ${other:-nothing}; run 'make check' to fetch and relink it before an IDE re-imports the pom."
exit 0
