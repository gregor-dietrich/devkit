#!/usr/bin/env bash
# Hermetic tests for scripts/lib/mvn_checked.sh's JAVA_VERSION handling and logger keys: a
# stub MVN_LAUNCHER logs its arguments. No Maven, no network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
script=$root/scripts/lib/mvn_checked.sh
# shellcheck disable=SC2016 # the stub expands its own variables
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"$LOG"\n' >"$work/mvn"
chmod +x "$work/mvn"
export LOG=$work/log MVN_LAUNCHER=$work/mvn

run() { # run JAVA_VERSION [CMD...]: the script (or CMD) with that JAVA_VERSION; sets rc, err; LOG holds the launcher's arguments
  local jv=$1
  shift
  : >"$LOG"
  rc=0
  JAVA_VERSION=$jv "${@:-$script}" 2>"$work/err" || rc=$?
  err=$(<"$work/err")
}
fails=0
t() { # t NAME COMMAND...: report whether COMMAND succeeds
  local name=$1
  shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name (rc=$rc, stderr: $err, launcher got: $(<"$LOG"))"
    fails=$((fails + 1))
  fi
}
passes_range() { run 25 && grep -qxF -- '-Ddevkit.jdk.range=[25,26)' "$LOG"; }
rejects() { # rejects VALUE: exit 1, the message quoting VALUE, the launcher never run
  run "$1"
  [[ $rc == 1 && $err == *"got '$1'"* && ! -s $LOG ]]
}
# A project Makefile's profile line with a trailing comment must reach the script as 25.
strips_comment() {
  # shellcheck disable=SC2016 # make expands $(DEVKIT)
  printf 'JAVA_VERSION := 25   # LTS\nPROJECT := t\nDEVKIT := %s\ninclude $(DEVKIT)/make/common.mk\ninclude $(DEVKIT)/make/java-maven.mk\nprobe:\n\t@%s x\n' "$root" "$script" >"$work/Makefile"
  run '' make -s -C "$work" probe && grep -qxF -- '-Ddevkit.jdk.range=[25,26)' "$LOG"
}

t "1 JAVA_VERSION=25 passes -Ddevkit.jdk.range=[25,26)" passes_range
t "2 an empty JAVA_VERSION fails, launcher not run" rejects ''
t "3 25.0 fails, launcher not run" rejects '25.0'
t "4 025 fails, launcher not run" rejects '025'
t "5 an unstripped '25 ' fails, quoted in the message" rejects '25 '
t "6 a trailing comment on the Makefile's JAVA_VERSION line reaches the script as 25" strips_comment

# logger_call EXPECT MAVEN_ARGS ARG...: with MAVEN_ARGS set for the call, the launcher gets exactly
# the resolver keys and the JDK range in their order, then the logger keys (yes) or none (no), then
# ARG..., which the call's own arguments may thus override.
logger_call() {
  local expect=$1 margs=$2 expected
  shift 2
  expected=(
    -Daether.trustedChecksumsSource.summaryFile=true
    "-Daether.trustedChecksumsSource.summaryFile.basedir=$root/java/checksums"
    -Daether.trustedChecksumsSource.summaryFile.originAware=false
    -Daether.artifactResolver.postProcessor.trustedChecksums=true
    -Daether.artifactResolver.postProcessor.trustedChecksums.checksumAlgorithms=SHA-256
    -Daether.artifactResolver.postProcessor.trustedChecksums.failIfMissing=false
    -Daether.artifactResolver.postProcessor.trustedChecksums.record=false
    -Daether.artifactResolver.postProcessor.trustedChecksums.scope=all
    '-Ddevkit.jdk.range=[25,26)'
  )
  [[ $expect == no ]] || expected+=(
    -Dorg.slf4j.simpleLogger.log.org.apache.maven.plugin.compiler=warn
    -Dorg.slf4j.simpleLogger.log.org.apache.maven.plugins.pmd=warn
  )
  MAVEN_ARGS=$margs run 25 "$script" "$@"
  [[ $rc == 0 ]] && diff <(printf '%s\n' "${expected[@]}" "$@") "$LOG"
}
t "7 a plain call passes the resolver keys, the JDK range, both logger keys and its arguments, in that order" logger_call yes '' compile
t "8 -X in the arguments passes neither logger key" logger_call no '' -X compile
t "9 --debug in the arguments passes neither logger key" logger_call no '' --debug compile
t "10 MAVEN_ARGS='-B -X' passes neither logger key" logger_call no '-B -X' compile
t "11 -Xmx1g in MAVEN_ARGS is not -X: both logger keys passed" logger_call yes '-Xmx1g' compile
t "12 -XX and -Xfoo arguments are not -X: both logger keys passed" logger_call yes '' -XX -Xfoo compile

[[ $fails == 0 ]] || {
  echo "$fails case(s) failed"
  exit 1
}
