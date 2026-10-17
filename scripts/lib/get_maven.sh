#!/bin/bash

# Sourced by the scripts/java/*.sh after they cd to $PROJECT_ROOT. Exports MVN_CMD, the command every
# build runs, and MVN_LAUNCHER, the Maven it wraps: the one scripts/lib/pinned_maven.sh pins and
# installs, never mvn on PATH or ./mvnw.

# Suppress sun.misc.Unsafe deprecation warnings on Java 23+ (e.g. Guava inside Maven itself). The
# probe is the JVM bin/mvn runs: $JAVA_HOME/bin/java when JAVA_HOME is set, else java on PATH.
JAVA_BIN=${JAVA_HOME:+$JAVA_HOME/bin/}java
if command -v "$JAVA_BIN" &> /dev/null; then
  JAVA_MAJOR=$("$JAVA_BIN" -version 2>&1 | awk -F '"' '/version/ {split($2,a,"."); print (a[1]=="1"?a[2]:a[1])}') || true
  if [ "${JAVA_MAJOR:-0}" -ge 23 ] 2>/dev/null; then
    export MAVEN_OPTS="--sun-misc-unsafe-memory-access=allow ${MAVEN_OPTS:-}"
  fi
fi

# shellcheck source=SCRIPTDIR/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor || exit 13

# Maven reads devkit's parent POM only through the .devkit link; fail before any build whose pom
# would make it look the parent up remotely. Its ERROR lines reach stderr.
python3 -I "$DEVKIT/scripts/java/parent_check.py" > /dev/null || exit

# Both checks above come first, so a bad python3 or parent fails offline, before the download.
MVN_LAUNCHER=$("$DEVKIT/scripts/lib/pinned_maven.sh") || exit

# Every build below runs through mvn_checked.sh, which adds the trusted-checksum keys to the pinned
# launcher (MVN_LAUNCHER, the pinned Maven). check_frontend_deps.py asks the same Maven for its
# values and resolves the Vaadin dev bundle with it (the build resolves the core jar). A wrapper
# script, not an argument variable: MVN_CMD is one word in the environment.
MVN_CMD="$DEVKIT/scripts/lib/mvn_checked.sh"
export MVN_CMD MVN_LAUNCHER
