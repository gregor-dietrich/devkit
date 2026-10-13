#!/bin/bash

# Sourced by the scripts/java/*.sh after they cd to $PROJECT_ROOT, where ./mvnw lives.

REQUIRED_MAVEN_VERSION="3.9.9"

# Suppress sun.misc.Unsafe deprecation warnings on Java 23+ (e.g. Guava inside Maven itself)
if command -v java &> /dev/null; then
  JAVA_MAJOR=$(java -version 2>&1 | awk -F '"' '/version/ {split($2,a,"."); print (a[1]=="1"?a[2]:a[1])}') || true
  if [ "${JAVA_MAJOR:-0}" -ge 23 ] 2>/dev/null; then
    export MAVEN_OPTS="--sun-misc-unsafe-memory-access=allow ${MAVEN_OPTS:-}"
  fi
fi

# mvn's launcher reads MAVEN_ARGS; a ./mvnw that launches a maven-wrapper jar (any distributionType
# but only-script) drops it, so a profile there would silently not apply. An only-script ./mvnw execs
# mvn's. Refused even where mvn is picked or MAVEN_ARGS is unset, so every machine fails at the bump.
if [[ -f ./mvnw ]] && grep -q MavenWrapperMain ./mvnw; then
    echo "ERROR: ./mvnw launches a maven-wrapper jar, which ignores MAVEN_ARGS. Exiting."
    echo "Regenerate it script-only with its own Maven (maven-wrapper.jar and MavenWrapperDownloader.java go):"
    echo "  ./mvnw -N org.apache.maven.plugins:maven-wrapper-plugin:3.3.4:wrapper -Dtype=only-script"
    echo "then restore a distributionSha256Sum line in .mvn/wrapper/maven-wrapper.properties if the old one had it, and commit the result; see .devkit/README.md when upgrading from v0.5.x."
    exit 15
fi

if ! command -v mvn &> /dev/null; then
    MVN_CMD="./mvnw"
else
    MVN_CMD="mvn"
fi

if ! command -v "${MVN_CMD}" &> /dev/null; then
    echo "ERROR: Maven not found. Exiting."
    echo "Please install Maven version ${REQUIRED_MAVEN_VERSION} or higher and add it to PATH."
    exit 1
fi
# -B (batch mode) turns off the ANSI colour some builds put around the version.
MAVEN_VERSION=$("${MVN_CMD}" -B -version | head -n 1 | awk '{print $3}') || true
if [[ -z "$MAVEN_VERSION" ]]; then
    echo "ERROR: Could not determine Maven version. Exiting."
    exit 2
fi

printf -v versions '%s\n%s' "$REQUIRED_MAVEN_VERSION" "$MAVEN_VERSION"
if [[ $versions != "$(sort -V <<< "$versions")" ]]; then
    if [[ "${MVN_CMD}" != "./mvnw" && -x "./mvnw" ]]; then
        MVN_CMD="./mvnw"
        MAVEN_VERSION=$("${MVN_CMD}" -B -version 2>/dev/null | head -n 1 | awk '{print $3}') || true
        if [[ -z "$MAVEN_VERSION" ]]; then
            echo "ERROR: Could not determine Maven version using ${MVN_CMD}. Exiting."
            exit 3
        fi
        printf -v versions '%s\n%s' "$REQUIRED_MAVEN_VERSION" "$MAVEN_VERSION"
        if [[ $versions != "$(sort -V <<< "$versions")" ]]; then
            echo "ERROR: Maven version ${MAVEN_VERSION} (from ${MVN_CMD}) is below required ${REQUIRED_MAVEN_VERSION}. Exiting."
            echo "Please upgrade Maven to version ${REQUIRED_MAVEN_VERSION} or update the project wrapper './mvnw'."
            exit 4
        fi
    else
        echo "ERROR: Maven version ${MAVEN_VERSION} is below the required version ${REQUIRED_MAVEN_VERSION}. Exiting."
        echo "Please upgrade Maven to version ${REQUIRED_MAVEN_VERSION} or higher and add it to PATH."
        exit 5
    fi
fi
# Every build below runs through mvn_checked.sh, which adds the trusted-checksum keys to the launcher
# picked above (MVN_LAUNCHER, the one version and error messages name). check_frontend_deps.py asks
# the same Maven for its values and resolves the Vaadin dev bundle with it (the build resolves the
# core jar). A wrapper script, not an argument variable: MVN_CMD is one word in the environment.
MVN_LAUNCHER=$MVN_CMD
MVN_CMD="$DEVKIT/scripts/lib/mvn_checked.sh"
export MVN_CMD MVN_LAUNCHER

# shellcheck source=SCRIPTDIR/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor || exit 13

# Maven reads devkit's parent POM only through the .devkit link; fail before any build whose pom
# would make it look the parent up remotely. Its ERROR lines reach stderr.
python3 "$DEVKIT/scripts/java/parent_check.py" > /dev/null || exit
