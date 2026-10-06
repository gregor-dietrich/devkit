#!/usr/bin/env bash
# Tests for scripts/python/coverage_floor.py: per case, a synthetic JSON
# report shaped as pytest-cov writes it (meta.branch_coverage,
# totals.percent_covered) checked against a floor. No pytest. Prints
# PASS/FAIL per case.
set -euo pipefail

script=$(cd "$(dirname "$0")/.." && pwd)/scripts/python/coverage_floor.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
json=$work/core.json
fails=0

# report PERCENT [BRANCH]: the JSON report; BRANCH defaults to true
report() {
  printf '{"meta": {"branch_coverage": %s}, "totals": {"percent_covered": %s}}\n' "${2:-true}" "$1" >"$json"
}

# expect LABEL WANT-STATUS WANT-TEXT FLOOR: the output must contain WANT-TEXT;
# a failure must be one line
expect() {
  local out rc=0
  out=$(python3 "$script" "$json" "$4" packages/core 2>&1) || rc=$?
  if [[ $rc == "$2" && $out == *"$3"* && $out != *$'\n'* && $out != *Traceback* ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: exit $rc, want $2 and '$3' in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

report 100.0
expect "100% meets a floor of 100" 0 "packages/core: coverage 100.00% meets COVERAGE_FLOOR 100%" 100
report 99.995
expect "99.995% misses a floor of 100, shown truncated" 1 \
  "ERROR: packages/core: coverage 99.99% is below COVERAGE_FLOOR 100%" 100
report 90
expect "an integral percent meets an equal fractional floor" 0 "coverage 90.00% meets COVERAGE_FLOOR 90.0%" 90.0
report 0.0
expect "0% meets a floor of 0" 0 "meets COVERAGE_FLOOR 0%" 0
report 100.0 false
expect "a report without branch coverage fails" 1 "packages/core: the coverage report measured no branches" 100
echo '{"meta": {"branch_coverage": true}, "totals": {}}' >"$json"
expect "a report without totals.percent_covered fails" 1 "has no totals.percent_covered" 100
echo '{"meta": ' >"$json"
expect "a malformed report fails" 1 "cannot read the coverage report" 100
rm "$json"
expect "a missing report names the cause" 1 \
  "ERROR: packages/core: the pytest session wrote no coverage report; activate coverage in its pytest configuration" 100
report 100.0
for floor in 101 100.5 -1 abc 1e2 '' 050; do
  expect "floor '$floor' is refused" 2 "ERROR: COVERAGE_FLOOR '$floor' is not a percent from 0 to 100" "$floor"
done
rc=0
out=$(python3 "$script" "$json" 100 2>&1) || rc=$?
if [[ $rc == 2 && $out == "usage: coverage_floor.py"* ]]; then
  echo "PASS a missing argument is a usage error"
else
  echo "FAIL a missing argument is a usage error: exit $rc, got: $out"
  fails=$((fails + 1))
fi

[[ $fails == 0 ]]
