#!/bin/bash

# Sourced by scripts that install a pinned release tarball into the tools cache.

# Relative to this file, not $DEVKIT: maven_checksums.sh and the tests run it without DEVKIT.
# shellcheck source=SCRIPTDIR/sha256.sh
. "$(dirname "${BASH_SOURCE[0]}")/sha256.sh"
# shellcheck source=SCRIPTDIR/sealed_dir.sh
. "$(dirname "${BASH_SOURCE[0]}")/sealed_dir.sh"

# fetch_sealed LABEL URLS SHA256 DIR [MEMBER...]: download the first of URLS (one or more https URLs
# separated by spaces) that serves into a stage beside DIR, which is absolute and must not exist yet;
# unpack only MEMBER... from it, and only when its sha256 is SHA256 (a mismatch is final: no further
# URL is tried); seal the stage and move it to DIR (sealed_place). A URL that fails while another
# follows gets, after curl's own message, one devkit line on stderr (no ERROR), and the call goes on
# to the next URL. Prints nothing else on success; else one devkit line "ERROR: LABEL: ..." on
# stderr, after whatever the failing tool printed itself, and returns 1. A subshell, so its traps
# stay its own.
fetch_sealed() {
  (
    label=$1 pin=$3 place=$4
    read -ra urls <<<"$2"
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
    # --max-filesize: a source may serve anything; the hash still decides. --retry: a fresh CI job
    # downloads every tool, so a transient failure is retried rather than failing the job: with
    # curl 7.71 or later every failure (--retry-all-errors: a dropped connection too, and with -f a
    # 404, which only delays the error), before it a timeout, a refused connect or what that curl
    # counts as a transient HTTP error. Only the last URL is retried: an earlier URL's retry is the
    # next URL. No retry starts after 300 s (each attempt has its own --max-time), and each one
    # rewrites the file whose sha256 is checked below.
    retry=--retry-connrefused
    [[ $(curl --help all 2> /dev/null) != *--retry-all-errors* ]] || retry=--retry-all-errors
    last=$((${#urls[@]} - 1))
    for i in "${!urls[@]}"; do
      url=${urls[i]}
      rm -f "$tmp/asset.tar.gz"
      curl -fsSL --globoff --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 \
        --max-filesize 100M --retry $((i == last ? 3 : 0)) "$retry" --retry-max-time 300 \
        -o "$tmp/asset.tar.gz" "$url" && break
      ((i < last)) || fail "cannot download $url"
      echo "$label: cannot download $url; trying ${urls[i + 1]}" >&2
    done
    got=$(sha256_of "$tmp/asset.tar.gz") || fail "cannot hash the download of $url"
    [[ $got == "$pin" ]] ||
      fail "sha256 mismatch for $url: got $got, devkit pins $pin; nothing was unpacked"
    tar -xzf "$tmp/asset.tar.gz" -C "$tmp" "$@" || fail "cannot unpack $url"
    rm "$tmp/asset.tar.gz" || fail "cannot remove the download of $url"
    # Read-only, directories too, like the devkit checkout.
    sealed_place "$tmp" "$place" || fail "cannot move the downloaded ${*:-archive} into $place"
  )
}
