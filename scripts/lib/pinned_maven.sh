#!/bin/bash

# Prints the path of the Maven launcher every devkit Java target runs, installing it first when the
# tools cache lacks it. Neither mvn on PATH nor ./mvnw is used: a distribution-packaged Maven that
# reports the same version is not the same bits, and the resolver that enforces java/checksums is
# part of it. The distribution is downloaded once into the tools cache, and its tarball is checked
# against the sha256 below before anything unpacks it. DEVKIT_MAVEN_MIRROR (a list of https:// URLs)
# replaces the default list as the sources, tried in turn; the pin and the cache path stay.
#
# Bumping: download apache-maven-<version>-bin.tar.gz with its .sha512 and .asc from Maven
# Central; verify the .asc against https://downloads.apache.org/maven/KEYS and the .sha512; record
# the tarball's sha256 here; run `make maven-checksums`, as the default lifecycle plugins a Maven
# binds change with it; review the variables its bin/mvn reads, and the Java-side facts
# launcher_inputs' harmless list and comment rest on (MAVEN_CONFIG, env.MAVEN_REPO_CENTRAL), then
# raise `reviewed=` in tests/run.sh's launcher_inputs.
set -euo pipefail

version=3.10.0
sha256=a46cc51bc74fa23fd267c7a0b9132b146dcf526da60d31aa5174e565632e9e0e

# Relative to this file, not $DEVKIT: maven_checksums.sh and the tests run it without DEVKIT.
# shellcheck source=SCRIPTDIR/fetch.sh
. "$(dirname "${BASH_SOURCE[0]}")/fetch.sh"

die() {
  echo "ERROR: pinned Maven: $*" >&2
  exit 1
}

tools=${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools
case $tools in /*) ;; *) die "tools cache $tools is not an absolute path" ;; esac
dir=$tools/maven-$version launcher=$dir/apache-maven-$version/bin/mvn
# The list DEVKIT_MAVEN_MIRROR defaults to (docs/contract.md, Parent POM). DEFAULT_MIRRORS in
# scripts/java/version_check.py holds the same list, which tests/version_check_test.sh checks by
# reading this line, so it stays on one line.
default_mirrors=(https://maven.vptr.de/central https://maven-central.storage-download.googleapis.com/maven2 https://repo.maven.apache.org/maven2)
# The URLs are printed (below and in fetch_sealed's errors), so no secret belongs anywhere in them:
# an @ anywhere is refused, as is any entry but https://HOST[/PATH] without a query, fragment,
# whitespace or control character. Checked on every call, so a bad value is caught while the cache
# is warm too; empty or blank means the default list.
[[ ${DEVKIT_MAVEN_MIRROR-} != *@* ]] || die "DEVKIT_MAVEN_MIRROR names a user or password (user@ or user:password@), which devkit would print; use a mirror that needs none"
read -rd '' -a mirrors <<<"${DEVKIT_MAVEN_MIRROR-}" || :
((${#mirrors[@]})) || mirrors=("${default_mirrors[@]}")
for mirror in "${mirrors[@]}"; do
  [[ $mirror =~ ^https://[^/@?#[:space:][:cntrl:]]+(/[^?#[:space:][:cntrl:]]*)?$ ]] ||
    die "each entry of DEVKIT_MAVEN_MIRROR must be an https:// base URL with a host and no query, fragment, whitespace or control character"
done
if [[ ! -e $launcher ]]; then
  [[ ! -e $dir && ! -L $dir ]] || die "$dir has no Maven launcher; remove it (chmod -R u+w '$dir'; rm -rf '$dir') and retry"
  urls=()
  for mirror in "${mirrors[@]}"; do
    urls+=("${mirror%/}/org/apache/maven/apache-maven/$version/apache-maven-$version-bin.tar.gz")
  done
  echo "Downloading Maven $version from ${urls[0]} ..." >&2
  fetch_sealed "pinned Maven" "${urls[*]}" "$sha256" "$dir" "apache-maven-$version" || exit 1
fi
echo "$launcher"
