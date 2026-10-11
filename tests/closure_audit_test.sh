#!/usr/bin/env bash
# Hermetic tests for scripts/closure_audit.sh and closure_audit.py: closure
# directories in a temp dir, and a PATH of the system tools the script needs plus
# a stub npm that prints a canned report. No network. Prints PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
export STUBS=$work/stubs LOG=$work/log REPORTS=$work/reports
mkdir -p "$STUBS" "$REPORTS" "$work/sys" "$work/nonpm"
fails=0

# The tools the script runs, linked into a PATH of their own: the case without
# npm must not find one installed on the machine.
for tool in basename cat cp dirname mkdir mktemp python3 rm; do
  ln -s "$(command -v "$tool")" "$work/sys/$tool"
done
# fake NAME BODY: an executable bash script NAME in $STUBS
fake() { printf '#!/bin/bash\n%s\n' "$2" >"$STUBS/$1" && chmod +x "$STUBS/$1"; }
# The stub logs its arguments, one line per call, and a line to $LOG.npmrc when the .npmrc of
# the closure is beside it; it prints $REPORTS/<the closure's name>.json.
# shellcheck disable=SC2016 # the body expands its variables when it runs
fake npm 'printf " %q" "$@" >>"$LOG"; echo >>"$LOG"
[[ ! -e .npmrc ]] || echo "$PWD" >>"$LOG.npmrc"
cat "$REPORTS/$(basename "$PWD").json"
exit "${FAKE_NPM_RC-1}"'

# The reports are the shape of npm 11.19.1's `npm audit --json`, trimmed.
CLEAN='{"auditReportVersion": 2, "vulnerabilities": {}, "metadata": {"vulnerabilities": {"total": 0}}}'
# A direct package with only string `via`, and two transitive advisories: GHSA-r3ph-w7gj-g6xm
# (js-yaml, moderate) and GHSA-238p-pmpm-9mq7 (katex, low).
VULNERABLE='{
  "auditReportVersion": 2,
  "vulnerabilities": {
    "js-yaml": {
      "name": "js-yaml", "severity": "moderate", "isDirect": false,
      "via": [{
        "source": 1239991, "name": "js-yaml", "dependency": "js-yaml",
        "title": "js-yaml: maxTotalMergeKeys does not limit CPU use for empty merge sources",
        "url": "https://github.com/advisories/GHSA-r3ph-w7gj-g6xm", "severity": "moderate",
        "cwe": ["CWE-400"], "cvss": {"score": 5.3, "vectorString": "CVSS:3.1/AV:N"}, "range": ">=5.0.0 <=5.4.0"
      }],
      "effects": ["markdownlint-cli"], "range": "5.0.0 - 5.4.0", "nodes": ["node_modules/js-yaml"],
      "fixAvailable": {"name": "markdownlint-cli", "version": "0.49.0", "isSemVerMajor": true}
    },
    "katex": {
      "name": "katex", "severity": "low", "isDirect": false,
      "via": [{
        "source": 1241206, "name": "katex", "dependency": "katex",
        "title": "KaTeX: Existing prototype pollution can bypass trust restrictions",
        "url": "https://github.com/advisories/GHSA-238p-pmpm-9mq7", "severity": "low",
        "cwe": ["CWE-807"], "cvss": {"score": 0, "vectorString": null}, "range": ">=0.11.0 <0.18.2"
      }],
      "effects": ["micromark-extension-math"], "range": "0.11.0 - 0.18.1", "nodes": ["node_modules/katex"],
      "fixAvailable": {"name": "markdownlint-cli", "version": "0.49.0", "isSemVerMajor": true}
    },
    "markdownlint-cli": {
      "name": "markdownlint-cli", "severity": "moderate", "isDirect": true,
      "via": ["js-yaml", "katex"], "effects": [], "range": ">=0.41.0", "nodes": ["node_modules/markdownlint-cli"],
      "fixAvailable": {"name": "markdownlint-cli", "version": "0.49.0", "isSemVerMajor": true}
    }
  },
  "metadata": {"vulnerabilities": {"total": 3}}
}'
NO_GHSA=${VULNERABLE//https:\/\/github.com\/advisories\/GHSA-238p-pmpm-9mq7/https:\/\/example.invalid\/other\/1241206}
OFFLINE='{
  "message": "request to http://127.0.0.1:9/-/npm/v1/security/advisories/bulk failed, reason: connect ECONNREFUSED 127.0.0.1:9",
  "error": {"summary": "", "detail": ""}
}'
OLD=${CLEAN/2/1}
# adv PACKAGE ID: an advisory of PACKAGE, as npm lists it in `via`
adv() {
  printf '{"source": 1, "name": "%s", "title": "title of %s", "url": "https://github.com/advisories/%s", "severity": "high"}' \
    "$1" "$2" "$2"
}
# report ENTRY...: a v2 report holding the "name": {...} ENTRYs given
report() {
  local IFS=,
  printf '{"auditReportVersion": 2, "vulnerabilities": {%s}}' "$*"
}
# entry NAME VIA...: a `vulnerabilities` entry of NAME with the given `via` items (JSON)
entry() {
  local name=$1 IFS=,
  shift
  printf '"%s": {"name": "%s", "via": [%s]}' "$name" "$name" "$*"
}

# closure NAME REPORT [IGNORE-LINE...]: $work/NAME, a closure (the package.json and package-lock.json
# the script copies) with REPORT as npm's output, and an audit-ignore of the IGNORE-LINEs when
# there are any
closure() {
  local name=$1
  mkdir -p "$work/$name"
  echo '{}' >"$work/$name/package.json"
  echo '{}' >"$work/$name/package-lock.json"
  printf '%s\n' "$2" >"$REPORTS/$name.json"
  rm -rf "$work/$name/audit-ignore" "$work/$name/.npmrc"
  if [[ $# -gt 2 ]]; then printf '%s\n' "${@:3}" >"$work/$name/audit-ignore"; fi
}

# expect LABEL WANT-STATUS [DIR...] -- WANT-TEXT...: run the script over the closures under $work
# (DIR names, or a first and a second when none) with the stub on PATH unless NO_NPM is set; the
# output must contain every WANT-TEXT and no Python traceback.
expect() {
  local label=$1 want=$2 dirs=() out rc=0 text ok=true path=$STUBS:$work/sys
  shift 2
  while [[ $1 != -- ]]; do dirs+=("$work/$1") && shift; done
  shift
  [[ -n ${NO_NPM-} ]] && path=$work/nonpm:$work/sys
  rm -f "$LOG" "$LOG.npmrc"
  out=$(cd "$work" && env PATH="$path" "$root/scripts/closure_audit.sh" ${dirs[@]+"${dirs[@]}"} 2>&1) || rc=$?
  for text in "$@"; do [[ $out == *"$text"* ]] || ok=false; done
  if [[ $rc == "$want" && $ok == true && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and each of [$*] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

# holds LABEL COMMAND...: COMMAND must succeed
holds() {
  local label=$1
  shift
  if "$@"; then
    echo "PASS $label"
  else
    echo "FAIL $label"
    fails=$((fails + 1))
  fi
}

ID1=GHSA-r3ph-w7gj-g6xm ID2=GHSA-238p-pmpm-9mq7 A=GHSA-aaaa-aaaa-aaaa B=GHSA-bbbb-bbbb-bbbb
closure one "$CLEAN"
closure two "$CLEAN"
expect "clean reports pass, one line per closure" 0 one two -- \
  "one: npm audit clean (0 advisories ignored)" "two: npm audit clean (0 advisories ignored)"
holds "npm gets exactly the audit arguments, twice, and never ci" \
  [ "$(<"$LOG")" = " audit --json --package-lock-only --offline=false --registry=https://registry.npmjs.org/ --include=optional --include=peer --loglevel=error
 audit --json --package-lock-only --offline=false --registry=https://registry.npmjs.org/ --include=optional --include=peer --loglevel=error" ]
closure one "$CLEAN"
echo 'offline=true' >"$work/one/.npmrc"
expect "npm's config beside the lockfile does not reach npm" 0 one -- "one: npm audit clean"
holds "npm ran in a copy without the closure's .npmrc" [ ! -e "$LOG.npmrc" ]
closure one "$CLEAN"

FAKE_NPM_RC=0 expect "an npm that exits 0 on a clean report passes" 0 one -- "one: npm audit clean"

closure one "$VULNERABLE"
expect "findings fail, naming closure, package, id and severity" 1 one -- \
  "ERROR: one: js-yaml: $ID1 (moderate) js-yaml: maxTotalMergeKeys" \
  "ERROR: one: katex: $ID2 (low) KaTeX: Existing prototype pollution"

closure one "$VULNERABLE" "# why each is accepted" "" "$ID1 js-yaml reachable only through the linter's config" \
  "  $ID2 katex a prototype pollution a lint run never reaches"
expect "ignored findings pass, counted" 0 one -- "one: npm audit clean (2 advisories ignored)"
closure one "$VULNERABLE" "$ID1 js-yaml reachable only through the linter's config"
expect "one finding ignored, the other fails" 1 one -- "ERROR: one: katex: $ID2"
closure one "$VULNERABLE" "$ID1 js-yaml ok" "$ID2 katex"
expect "an entry without justification fails, naming file and line" 1 one -- \
  "ERROR: one: $work/one/audit-ignore:2: $ID2 on katex has no justification"
closure one "$VULNERABLE" "$ID1 js-yaml ok" "$ID2 katex ok" "GHSA-aaaa-bbbb-cccc js-yaml stale entry"
expect "a stale entry fails, naming file and line" 1 one -- \
  "ERROR: one: $work/one/audit-ignore:3: GHSA-aaaa-bbbb-cccc on js-yaml is ignored but the report has no such advisory"
closure one "$VULNERABLE" "$ID1 js-yaml ok" "$ID2 katex ok" "GHSA-nope why"
expect "a malformed id fails" 1 one -- "audit-ignore:3: 'GHSA-nope' is not a GHSA id"
closure one "$VULNERABLE" "$ID1 js-yaml ok" "$ID2 katex ok" "$ID1 js-yaml again"
expect "a duplicate id fails" 1 one -- "audit-ignore:3: $ID1 on js-yaml is already ignored on line 1"
closure one "$CLEAN" "$ID1 js-yaml fixed by a bump"
expect "an ignore entry on a clean report is stale" 1 one -- "audit-ignore:1: $ID1 on js-yaml is ignored but"

closure one "$VULNERABLE" "$ID1 js-yaml ok" "$ID2 katex ok" "$ID1 katex wrong package"
expect "an entry for the right id on the wrong package is stale" 1 one -- \
  "audit-ignore:3: $ID1 on katex is ignored but the report has no such advisory"
closure one "$VULNERABLE" "$ID1 js-yaml ok" "$ID2"
expect "an entry with no package fails, naming file and line" 1 one -- \
  "ERROR: one: $work/one/audit-ignore:2: $ID2 has no package after the id" "katex: $ID2 (low)"
closure one "$VULNERABLE" "$ID1 js-yaml ok" "$ID2 katex"
expect "an entry with no justification still counts as ignoring" 1 one -- "audit-ignore:2: $ID2 on katex has no justification"
closure one "$VULNERABLE" "$(printf '%s\tjs-yaml\tok' "$ID1")" "$(printf '%s \t katex \t ok too' "$ID2")"
expect "tabs and runs of whitespace separate the fields" 0 one -- "one: npm audit clean (2 advisories ignored)"

TWO_ONE=$(report "$(entry foo "$(adv foo $A)" "$(adv foo $B)")")
closure one "$TWO_ONE" "$A foo ok"
expect "two advisories on one package, one ignored: the other fails" 1 one -- "ERROR: one: foo: $B (high) title of $B"
closure one "$TWO_ONE" "$A foo ok" "$B foo ok"
expect "both ignored pass" 0 one -- "one: npm audit clean (2 advisories ignored)"
SAME_ID=$(report "$(entry foo "$(adv foo $A)")" "$(entry bar "$(adv bar $A)")")
closure one "$SAME_ID" "$A foo ok"
expect "one id on two packages, ignored for one: the other fails" 1 one -- "ERROR: one: bar: $A (high)"
closure one "$(report "$(entry foo "$(adv foo $A)")")" "$A foo ok"
expect "one ignored advisory is counted in the singular" 0 one -- "one: npm audit clean (1 advisory ignored)"

closure one "$(report)"
expect "a report with no vulnerabilities passes with none ignored" 0 one -- "one: npm audit clean (0 advisories ignored)"
closure one '{"auditReportVersion": 2}'
expect "a v2 report with no vulnerabilities object fails" 1 one -- "ERROR: one: npm audit report holds no vulnerabilities object"
closure one "$(report '"foo": 7')"
expect "a vulnerabilities entry that is not an object fails" 1 one -- "ERROR: one: foo: the vulnerabilities entry is not an object"
closure one "$(report '"foo": {"via": "bar"}')"
expect "a via that is not a list fails" 1 one -- "ERROR: one: foo: the vulnerabilities entry's via is not a list"
closure one "$(report "$(entry foo '"ghost"')")"
expect "a string via naming no entry fails" 1 one -- "ERROR: one: foo: via names 'ghost', which is no vulnerabilities entry"
closure one "$(report "$(entry foo '"foo"')")"
expect "vulnerabilities that yield no advisory fail" 1 one -- "ERROR: one: the vulnerabilities hold no advisory"
closure one "$(report "$(entry foo '3')")"
expect "a via item that is neither an advisory nor a name fails" 1 one -- "ERROR: one: foo: via holds 3"

closure one "$NO_GHSA" "$ID1 js-yaml ok"
expect "an advisory with no GHSA id fails, naming its source" 1 one -- \
  "ERROR: one: katex: advisory 1241206 has no GHSA id in its url"
closure one "$OFFLINE"
expect "npm's offline error fails closed, naming its message" 1 one -- \
  "ERROR: one: npm audit failed: request to http://127.0.0.1:9/-/npm/v1/security/advisories/bulk failed, reason: connect ECONNREFUSED"
FAKE_NPM_RC=0 expect "an offline error fails whatever npm's exit status" 1 one -- "npm audit failed:"
closure one '{"error": {"summary": "", "code": "ENOAUDIT"}}'
expect "an error object without a message falls back to its code" 1 one -- "ERROR: one: npm audit failed: ENOAUDIT"
closure one '{"error": {"summary": "audit endpoint down", "code": "ENOAUDIT"}}'
expect "an error object without a message prefers its summary" 1 one -- "ERROR: one: npm audit failed: audit endpoint down"
closure one "$CLEAN"
mkdir "$work/one/audit-ignore"
expect "an unreadable ignore file fails, naming it" 1 one -- "ERROR: one: cannot read $work/one/audit-ignore:"
closure one "$OLD"
expect "auditReportVersion 1 fails, naming it" 1 one -- "ERROR: one: npm audit report version 1, want 2"
closure one "npm ERR! nonsense"
expect "output that is not JSON fails" 1 one -- "ERROR: one: npm audit printed no JSON"
closure one '[]'
expect "JSON that is not an object fails" 1 one -- "ERROR: one: npm audit printed JSON that is not an object"
expect "no closure directory is a usage error" 2 -- "usage: closure_audit.sh DIR..."
NO_NPM=1 expect "npm missing fails with one ERROR line" 1 one -- "ERROR: npm not found; the closure audit needs npm on PATH."

closure one "$VULNERABLE"
closure two "$VULNERABLE" "$ID1 js-yaml ok" "$ID2 katex ok"
expect "a failing first closure does not hide a second one" 1 one two -- \
  "ERROR: one: js-yaml: $ID1" "two: npm audit clean (2 advisories ignored)"
closure one "$CLEAN"
closure two "$VULNERABLE"
expect "a finding in the second closure fails the run" 1 one two -- \
  "one: npm audit clean" "ERROR: two: js-yaml: $ID1"
expect "a closure npm never ran in is not judged by the previous one's report" 1 one missing -- \
  "one: npm audit clean" "ERROR: missing: npm audit printed no JSON"

# Every closure devkit pins, a top-level directory holding a package-lock.json, is in make
# audit's list, and the list names nothing else: a new closure cannot ship unaudited.
audited=$(sed -n 's/^\t@scripts\/closure_audit\.sh //p' "$root/Makefile" | tr ' ' '\n' | sort)
pinned=$(cd "$root" && find . -mindepth 2 -maxdepth 2 -name package-lock.json | sed 's|^\./||; s|/.*||' | sort)
listed_all() { [[ -n $pinned && $audited == "$pinned" ]]; }
holds "make audit lists every closure: ${pinned//$'\n'/, }" listed_all

[[ $fails == 0 ]]
