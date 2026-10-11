#!/bin/bash

# Sourced by scripts that install a cache entry: a tree staged beside its place, then made
# read-only, directories included, before it becomes visible. devkitw inlines this logic (it
# cannot source anything): keep the two in step.

# sealed_place STAGE DIR: make STAGE read-only throughout and move it to DIR, which must not
# exist yet. Succeeds when DIR is a directory afterwards, ours or an existing one, whose copy
# wins and ours is removed; fails, STAGE left in place for the caller's trap, otherwise.
sealed_place() {
  local stage=$1 dir=$2
  chmod -R a-w "$stage" || return 1
  if mv "$stage" "$dir" 2>/dev/null; then
    # mv succeeded, yet ours landed inside a DIR that was there already: only root gets this,
    # a read-only stage does not stop it; the existing DIR, sealed or writable, wins.
    if [[ -e $dir/${stage##*/} || -L $dir/${stage##*/} ]]; then
      sealed_remove "${dir:?}/${stage##*/}"
    fi
    return 0
  fi
  # mv failed on a DIR that was there already, as a non-root run meets it: a concurrent run's
  # sealed copy or an older devkit's writable one. Its copy is used.
  [[ -d $dir ]] || return 1
  sealed_remove "$stage"
  return 0
}

# sealed_remove PATH...: remove each PATH, sealed or not; a missing one is no error. For EXIT
# traps.
sealed_remove() {
  local path
  for path in "$@"; do
    if [[ -e $path || -L $path ]]; then
      [[ -L $path ]] || chmod -R u+w "$path" 2>/dev/null || :
      rm -rf "$path"
    fi
  done
}
