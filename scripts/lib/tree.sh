#!/bin/bash

# Sourced by devkit's own scripts and tests (tests/run.sh, scripts/maven_checksums.sh); no consumer
# target uses it.

# listed SRC DEST: copy to DEST what git lists in SRC, tracked or untracked but not ignored
listed() {
  mkdir "$2"
  git -C "$1" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' f; do
      [[ ! -e $1/$f ]] || printf '%s\0' "$f" # skip deleted tracked files
    done | tar -C "$1" --null -T - -cf - | tar -C "$2" -xf -
}

# parent_version ROOT: the literal <version> of the parent POM of the devkit tree at ROOT
parent_version() {
  python3 -I -c 'import sys, xml.etree.ElementTree as ET
version = ET.parse(sys.argv[1]).getroot().findtext("{http://maven.apache.org/POM/4.0.0}version")
sys.exit("java/parent/pom.xml declares no <version>") if not version else print(version.strip())' \
    "$1/java/parent/pom.xml"
}

# frontend_plugins ROOT: the plugins check_frontend_deps.py of the devkit tree at ROOT runs through
# MVN_CMD (HELP_EVALUATE, DEPENDENCY_GET), as groupId:artifactId:version, one per line
frontend_plugins() {
  sed -nE 's/^(HELP_EVALUATE|DEPENDENCY_GET) = "([^:"]*:[^:"]*:[^:"]*):[^:"]*"$/\2/p' \
    "$1/scripts/java/check_frontend_deps.py"
}

# maven_version ROOT: the Maven version scripts/lib/pinned_maven.sh of the devkit tree at ROOT pins
maven_version() { sed -n 's/^version=//p' "$1/scripts/lib/pinned_maven.sh"; }

# maven_pin ROOT: the line of java/checksums/checksums.sha256 for the Maven distribution that
# scripts/lib/pinned_maven.sh of the devkit tree at ROOT pins; fails if it pins none
maven_pin() {
  local v s
  v=$(maven_version "$1") s=$(sed -n 's/^sha256=//p' "$1/scripts/lib/pinned_maven.sh")
  [[ -n $v && -n $s ]] || return 1
  echo "$s  org/apache/maven/apache-maven/$v/apache-maven-$v-bin.tar.gz"
}

# clean_env: unset what the caller's environment could use to steer a build, a git call or the JVM
# (MAVEN_SKIP_RC, which leaves out ~/.mavenrc and /etc/mavenrc, is for the caller to export)
clean_env() {
  # shellcheck disable=SC2046 # one argument per variable name
  unset $(git rev-parse --local-env-vars) ONLY PROJECT_ROOT REVISION JUNIT_DIR COVERAGE_FLOOR MODULES SSH_AUTH_SOCK \
    MAVEN_ARGS MAVEN_OPTS MAVEN_DEBUG_OPTS MAVEN_BASEDIR MAVEN_CONFIG JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS \
    OPENJ9_JAVA_OPTIONS IBM_JAVA_OPTIONS PYTEST_ADDOPTS PYTEST_PLUGINS COVERAGE_RCFILE COVERAGE_FORCE_CONFIG PYTHONOPTIMIZE
}
