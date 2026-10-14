#!/bin/bash

set -euo pipefail

# Check environment at the project root
cd "$PROJECT_ROOT"

if [[ ! -f checkstyle-project.xml ]]; then
    echo "ERROR: checkstyle-project.xml not found at the project root. Exiting."
    echo "Please add checkstyle-project.xml with the project's own Checkstyle rules (an empty <module name=\"Checker\"/> for a project without rules of its own), which devkit's parent POM runs as checkstyle execution 'project'; see .devkit/docs/contract.md, and .devkit/README.md when upgrading from v0.1.x."
    exit 12
fi

# select_modules.sh selects the frontend by this name, so a FRONTEND_DIR that
# is neither a listed module nor a monolith's root would silently drop out.
FRONTEND_ERROR=
if [[ -n "${FRONTEND_DIR:-}" ]]; then
    if [[ $FRONTEND_DIR == *[[:space:]]* ]]; then
        FRONTEND_ERROR="names several directories; it is one directory"
    elif [[ " ${MODULES:-.} " != *" $FRONTEND_DIR "* ]]; then
        FRONTEND_ERROR="is neither one of MODULES (${MODULES:-empty}) nor . in a monolith"
    fi
fi
if [[ -n "$FRONTEND_ERROR" ]]; then
    echo "ERROR: FRONTEND_DIR := $FRONTEND_DIR in the project Makefile $FRONTEND_ERROR. Exiting."
    echo "Set it to the frontend module's directory as MODULES lists it, to . when the monolith's root is the frontend, or empty; see .devkit/docs/contract.md."
    exit 16
fi

echo "Running environment checks..."

echo "Checking version of $(command -v python3)..."
# shellcheck source=SCRIPTDIR/../lib/python.sh
. "$DEVKIT/scripts/lib/python.sh"
python3_floor || { echo "Please install Python 3.11 or higher and make it python3 on PATH."; exit 13; }
echo "Python version check passed. (>= 3.11)"

# shellcheck source=SCRIPTDIR/../lib/get_maven.sh
. "$DEVKIT/scripts/lib/get_maven.sh"

REVISION=${REVISION:-1.0.0-SNAPSHOT}

# The parent's enforcer execution: the JDK Maven runs on (JAVA_HOME's, else java on PATH) must be
# JAVA_VERSION's and Maven inside devkit.maven.range. mvn_checked.sh passes the JDK range.
echo "Checking the JDK and Maven versions..."
"${MVN_CMD}" -B -q -N org.apache.maven.plugins:maven-enforcer-plugin:enforce@environment -Drevision="${REVISION}" || {
    echo "Maven ran on: $("${JAVA_HOME:+$JAVA_HOME/bin/}java" -version 2>&1 | head -n 1)"
    exit 11
}
echo "JDK and Maven version checks passed. (JDK == ${JAVA_VERSION})"

echo "Environment checks completed."

echo "Checking dependency version pins..."

python3 "$DEVKIT/scripts/java/version_check.py"

echo "Dependency version pin checks completed."
