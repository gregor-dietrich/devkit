#!/bin/bash

# Prints the path of the Maven launcher every devkit Java target runs, installing it first when the
# tools cache lacks it. Neither mvn on PATH nor ./mvnw is used: a distribution-packaged Maven that
# reports the same version is not the same bits, and the resolver that enforces java/checksums is
# part of it. The distribution is downloaded once into the tools cache, and its tarball is checked
# against the sha256 below before anything unpacks it. DEVKIT_MAVEN_MIRROR (an https:// URL)
# replaces Maven Central as the source; the pin and the cache path stay.
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
# The URL is printed (below and in fetch_sealed's errors), so no secret belongs anywhere in it: an @
# anywhere is refused, as is anything but https://HOST[/PATH] without a query, fragment or whitespace.
# Checked on every call, so a bad value is caught while the cache is warm too; empty means Central.
if [[ -n ${DEVKIT_MAVEN_MIRROR-} ]]; then
  [[ $DEVKIT_MAVEN_MIRROR != *@* ]] || die "DEVKIT_MAVEN_MIRROR names a user or password (user@ or user:password@), which devkit would print; use a mirror that needs none"
  [[ $DEVKIT_MAVEN_MIRROR =~ ^https://[^/@?#[:space:]]+(/[^?#[:space:]]*)?$ ]] ||
    die "DEVKIT_MAVEN_MIRROR must be an https:// base URL with a host and no query, fragment or whitespace"
fi
if [[ ! -e $launcher ]]; then
  [[ ! -e $dir && ! -L $dir ]] || die "$dir has no Maven launcher; remove it (chmod -R u+w '$dir'; rm -rf '$dir') and retry"
  base=https://repo.maven.apache.org/maven2
  [[ -z ${DEVKIT_MAVEN_MIRROR-} ]] || base=${DEVKIT_MAVEN_MIRROR%/}
  url=$base/org/apache/maven/apache-maven/$version/apache-maven-$version-bin.tar.gz
  echo "Downloading Maven $version from $url ..." >&2
  fetch_sealed "pinned Maven" "$url" "$sha256" "$dir" "apache-maven-$version" || exit 1
fi
echo "$launcher"
