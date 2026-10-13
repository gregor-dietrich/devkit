#!/bin/bash

# The Maven every devkit target runs (MVN_CMD, set by get_maven.sh): the launcher get_maven.sh
# picked (MVN_LAUNCHER) with Maven resolver's trusted checksums on, so that a plugin, plugin
# dependency or annotation processor listed in java/checksums/checksums.sha256 fails the build
# when the bytes differ. The keys sit on the command line, which beats MAVEN_ARGS and
# .mvn/maven.config; failIfMissing=false lets what the file does not list (the project's own
# artifacts) through. record=false keeps a record=true of MAVEN_ARGS or .mvn/maven.config from
# writing what the build resolves instead of verifying it. originAware=false keys the file by
# path, not by repository id, so a mirror cannot bypass it. The basedir is absolute: a relative
# one resolves against the local repository. A missing or empty file fails the build, which it
# would otherwise verify nothing against. scripts/maven_checksums.sh records the file with the
# same keys plus record=true.
set -euo pipefail

source=${BASH_SOURCE[0]}
dir=$(cd "$(dirname "$source")/../../java/checksums" && pwd)
[[ -s $dir/checksums.sha256 ]] || {
    echo "ERROR: $dir/checksums.sha256 is missing or empty; builds would verify nothing." >&2
    exit 1
}
exec "${MVN_LAUNCHER:?run through get_maven.sh}" \
    -Daether.trustedChecksumsSource.summaryFile=true \
    -Daether.trustedChecksumsSource.summaryFile.basedir="$dir" \
    -Daether.trustedChecksumsSource.summaryFile.originAware=false \
    -Daether.artifactResolver.postProcessor.trustedChecksums=true \
    -Daether.artifactResolver.postProcessor.trustedChecksums.checksumAlgorithms=SHA-256 \
    -Daether.artifactResolver.postProcessor.trustedChecksums.failIfMissing=false \
    -Daether.artifactResolver.postProcessor.trustedChecksums.record=false \
    "$@"
