#!/bin/bash

# Sourced by scripts that install a pinned release tarball into the tools cache.

# Relative to this file, not $DEVKIT: maven_checksums.sh and the tests run it without DEVKIT.
# shellcheck source=SCRIPTDIR/sha256.sh
. "$(dirname "${BASH_SOURCE[0]}")/sha256.sh"
# shellcheck source=SCRIPTDIR/sealed_dir.sh
. "$(dirname "${BASH_SOURCE[0]}")/sealed_dir.sh"

# fetch_sealed LABEL URL SHA256 DIR [MEMBER...]: download URL (https only) into a stage beside
# DIR, which is absolute and must not exist yet; unpack only MEMBER... from it, and only when its
# sha256 is SHA256; seal the stage and move it to DIR (sealed_place). Prints nothing on success;
# else one devkit line "ERROR: LABEL: ..." on stderr, after whatever the failing tool printed itself,
# and returns 1. A subshell, so its traps stay its own.
fetch_sealed() {
  (
    label=$1 url=$2 pin=$3 place=$4
    shift 4
    fail() {
      echo "ERROR: $label: $*" >&2
      exit 1
    }
    # No `set -e` here: the caller's `||` would switch it off anyway.
    mkdir -p "${place%/*}" || fail "cannot create ${place%/*}"
    tmp=$(mktemp -d "${place%/*}/.tmp.XXXXXX") || fail "cannot create a stage beside $place"
    trap 'sealed_remove "$tmp"' EXIT
    trap 'exit 1' HUP INT TERM
    # --max-filesize: a mirror is operator-chosen; the hash still decides.
    curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 --max-filesize 100M \
      -o "$tmp/asset.tar.gz" "$url" || fail "cannot download $url"
    got=$(sha256_of "$tmp/asset.tar.gz") || fail "cannot hash the download of $url"
    [[ $got == "$pin" ]] ||
      fail "sha256 mismatch for $url: got $got, devkit pins $pin; nothing was unpacked"
    tar -xzf "$tmp/asset.tar.gz" -C "$tmp" "$@" || fail "cannot unpack $url"
    rm "$tmp/asset.tar.gz" || fail "cannot remove the download of $url"
    # Read-only, directories too, like the devkit checkout.
    sealed_place "$tmp" "$place" || fail "cannot move the downloaded ${*:-archive} into $place"
  )
}
