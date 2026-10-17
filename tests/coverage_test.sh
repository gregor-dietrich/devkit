#!/usr/bin/env bash
# Tests for scripts/java/coverage.py, run as scripts/java/coverage.sh runs it
# (python3 -I, from the project root, the report path first, then one JaCoCo CSV
# path per selected module): per case, small CSV fixtures made in a temp dir, a
# monolith (module ".") and a multi-module build, and the whole report
# compared with the expected one. No Maven, no network. Prints PASS/FAIL per
# case.
set -euo pipefail

script=$(cd "$(dirname "$0")/.." && pwd)/scripts/java/coverage.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
csv=target/site/jacoco/jacoco.csv
header=GROUP,PACKAGE,CLASS,INSTRUCTION_MISSED,INSTRUCTION_COVERED,BRANCH_MISSED,BRANCH_COVERED,LINE_MISSED,LINE_COVERED,COMPLEXITY_MISSED,COMPLEXITY_COVERED,METHOD_MISSED,METHOD_COVERED

# module DIR ROW...: DIR/target/site/jacoco/jacoco.csv, holding the header and ROWs
module() {
  mkdir -p "$work/$1/${csv%/*}"
  printf '%s\n' "$header" "${@:2}" >"$work/$1/$csv"
}

# expect LABEL WANT-STATUS WANT-TEXT MODULE...: coverage.py over the CSV of each MODULE ("." for a
# monolith), with no report beforehand, must exit WANT-STATUS with WANT-TEXT in its output
expect() {
  local label=$1 status=$2 text=$3 module paths=() rc=0 out
  shift 3
  for module in "$@"; do paths+=("$module/$csv"); done
  rm -f "$work/.coverage.md"
  out=$(cd "$work" && python3 -I "$script" .coverage.md "${paths[@]}" 2>&1) || rc=$?
  if [[ $rc == "$status" && $out == *"$text"* && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $status and '$text' in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

# report_is LABEL: the report the last expect wrote is exactly stdin
report_is() {
  local want
  want=$(cat)
  if [[ -f $work/.coverage.md && $(<"$work/.coverage.md") == "$want" ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: got"
    cat "$work/.coverage.md" 2>/dev/null || echo "(no report)"
    fails=$((fails + 1))
  fi
}

# no_report LABEL: the last expect wrote no report
no_report() {
  if [[ ! -e $work/.coverage.md ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: a report was written"
    fails=$((fails + 1))
  fi
}

module . 'p,com.a,Foo,4,16,1,3,2,8,1,3,0,2' 'p,com.a,Bar,0,20,0,0,0,10,0,2,0,2' 'p,com.b,Baz,10,10,2,2,5,5,2,2,1,1' \
  'p,com.c,Qux,2,6,1,1,0,3,1,1,0,1' 'p,com.c,Quux,2,2,0,0,1,1,0,1,0,1'
expect "a monolith" 0 "Overall: 77.1% lines, 60.0% branches" .
report_is "a monolith: one table per package and per file, a fully covered class omitted, a class with only a missed line or only a missed branch kept, no module table" <<'REPORT'
# Coverage Report

## By Package (sorted by line coverage)

| Package   | Lines Missed | Lines Covered |    Line % |  Branch % |
| :-------- | -----------: | ------------: | --------: | --------: |
| com.b     |            5 |             5 |     50.0% |     50.0% |
| com.c     |            1 |             4 |     80.0% |     50.0% |
| com.a     |            2 |            18 |     90.0% |     75.0% |
| **Total** |        **8** |        **27** | **77.1%** | **60.0%** |

## By File (sorted by line coverage)

> **Note:** Files with full line _and_ branch coverage have been omitted.

| Package | Class | Lines Missed | Lines Covered | Line % | Branch % |
| :------ | :---- | -----------: | ------------: | -----: | -------: |
| com.b   | Baz   |            5 |             5 |  50.0% |    50.0% |
| com.c   | Quux  |            1 |             1 |  50.0% |   100.0% |
| com.a   | Foo   |            2 |             8 |  80.0% |    75.0% |
| com.c   | Qux   |            0 |             3 | 100.0% |    50.0% |
REPORT

module core 'p,com.core,Util,0,10,0,0,0,10,0,1,0,1' 'p,com.shared,Fmt,2,8,1,3,2,8,1,3,0,2'
module app 'p,com.app,Main,10,10,2,2,5,5,2,2,1,1' 'p,com.shared,Fmt,0,4,0,2,0,4,0,2,0,1'
expect "two modules and one without a CSV" 0 "Warning: CSV file not found: web/$csv" core app web
report_is "two modules: a module table with the weighted total, a package present in both summed" <<'REPORT'
# Coverage Report

## Summary by Module

| Module    |    Line % |  Branch % |
| :-------- | --------: | --------: |
| app       |     64.3% |     66.7% |
| core      |     90.0% |     75.0% |
| **Total** | **79.4%** | **70.0%** |

## By Package (sorted by line coverage)

| Package    | Lines Missed | Lines Covered |    Line % |  Branch % |
| :--------- | -----------: | ------------: | --------: | --------: |
| com.app    |            5 |             5 |     50.0% |     50.0% |
| com.shared |            2 |            12 |     85.7% |     83.3% |
| com.core   |            0 |            10 |    100.0% |    100.0% |
| **Total**  |        **7** |        **27** | **79.4%** | **70.0%** |

## By File (sorted by line coverage)

> **Note:** Files with full line _and_ branch coverage have been omitted.

| Package    | Class | Lines Missed | Lines Covered | Line % | Branch % |
| :--------- | :---- | -----------: | ------------: | -----: | -------: |
| com.app    | Main  |            5 |             5 |  50.0% |    50.0% |
| com.shared | Fmt   |            2 |             8 |  80.0% |    75.0% |
REPORT
expect "two modules: the overall line on stdout is the weighted total" 0 "Overall: 79.4% lines, 70.0% branches" core app

module none 'p,com.n,Nothing,0,0,0,0,0,0,0,0,0,0'
expect "a CSV with no line or branch counts as 100%" 0 "Overall: 100.0% lines, 100.0% branches (no data)" none
module empty
expect "a header-only CSV fails, saying there is no data" 1 "Error: No coverage data found." empty
no_report "a header-only CSV writes no report"
expect "no CSV at all fails the same way" 1 "Error: No coverage data found." missing
no_report "no CSV at all writes no report"
rc=0
out=$(cd "$work" && python3 -I "$script" .coverage.md 2>&1) || rc=$?
if [[ $rc == 1 && $out == "Usage: coverage.py"* ]]; then
  echo "PASS a missing CSV argument is a usage error"
else
  echo "FAIL a missing CSV argument is a usage error: exit $rc, got: $out"
  fails=$((fails + 1))
fi

[[ $fails == 0 ]]
