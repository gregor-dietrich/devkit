#!/bin/bash

# Sourced by scripts that verify a download against a pinned hash.

# sha256_of FILE...: print the sha256 hex of FILE...'s bytes, concatenated in
# order, with sha256sum (GNU) or shasum (macOS); fail when neither exists.
sha256_of() {
  local sum out
  if command -v sha256sum >/dev/null; then
    sum=(sha256sum)
  elif command -v shasum >/dev/null; then
    sum=(shasum -a 256)
  else
    echo "ERROR: neither sha256sum nor shasum is installed" >&2
    return 1
  fi
  out=$(cat -- "$@" | "${sum[@]}") || return 1
  printf '%s\n' "${out%% *}"
}
