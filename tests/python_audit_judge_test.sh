#!/usr/bin/env bash
# Hermetic tests for scripts/python/audit.py: a temp project whose devkit.toml holds the accepted
# advisories under test, and pip-audit reports (the shape of pip-audit 2.10.1's `-f json
# --aliases on --desc off`, trimmed) written inline. No pip-audit, no network. Prints PASS/FAIL
# per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
fails=0

# vuln ID FIX ALIAS...: one row of a dependency's vulns
vuln() {
  local id=$1 fix=$2 aliases=
  shift 2
  for alias; do aliases+=${aliases:+, }\"$alias\"; done
  printf '{"id": "%s", "fix_versions": ["%s"], "aliases": [%s]}' "$id" "$fix" "$aliases"
}
# dep NAME VERSION [VULN...]: a dependency; pip-audit repeats a row it finds twice, so does a caller
dep() {
  local name=$1 version=$2 IFS=,
  shift 2
  printf '{"name": "%s", "version": "%s", "vulns": [%s]}' "$name" "$version" "$*"
}
# report DEP...: a report of the dependencies given
report() {
  local IFS=,
  printf '{"dependencies": [%s], "fixes": []}' "$*"
}

JINJA=$(vuln PYSEC-2026-1472 3.1.5 CVE-2024-56201 GHSA-gmj6-6f8f-6699)
JINJA_GHSA=$(vuln GHSA-gmj6-6f8f-6699 3.1.5 CVE-2024-56201 PYSEC-2026-1472)
MAKO=$(vuln PYSEC-2026-4243 1.4.2 GHSA-5639-2j2p-m4mx CVE-2026-102991)
printf '%s' "$(report "$(dep jinja2 3.1.4 "$JINJA" "$JINJA")" "$(dep mako 1.4.1)")" >"$work/pypi.json"
printf '%s' "$(report "$(dep jinja2 3.1.4 "$JINJA" "$JINJA")" "$(dep mako 1.4.1 "$MAKO" "$MAKO")")" >"$work/osv.json"
printf '%s' "$(report "$(dep jinja2 3.1.4 "$JINJA_GHSA")" "$(dep mako 1.4.1 "$MAKO")")" >"$work/osv_ghsa.json"
printf '%s' "$(report "$(dep jinja2 3.1.4)" "$(dep mako 1.4.1)")" >"$work/clean.json"
printf '%s' "$(report "$(dep jinja2 3.1.4 "$JINJA")")" >"$work/jinja.json"
printf '%s' '{"dependencies": [{"name": "left-pad", "skip_reason": "Dependency not found on PyPI"}]}' >"$work/skipped.json"
printf '%s' '{"dependencies": []}' >"$work/empty.json"
printf '%s' '{"dependencies": {"name": "jinja2"}}' >"$work/notlist.json"
printf '%s' '{"dependencies": [{"name": "jinja2", "version": "3.1.4"}]}' >"$work/novulns.json"
printf '%s' '{"dependencies": [{"name": "jinja2", "vulns": []}]}' >"$work/noversion.json"
printf '%s' '{"dependencies": [{"name": "jinja2", "version": "3.1.4", "vulns": [{"id": "PYSEC-1", "fix_versions": []}]}]}' >"$work/noaliases.json"
printf '%s' '{"dependencies": [{"name": "jinja2", "version": "3.1.4", "vulns": [{"id": "PYSEC-1", "aliases": []}]}]}' >"$work/nofixes.json"
printf '%s' "$(report "$(dep zope-interface 6.0 "$(vuln PYSEC-1 7.0)")")" >"$work/zope.json"
printf '%s' "$(report "$(dep Zope_Interface 6.0 "$(vuln PYSEC-1 7.0)")")" >"$work/zope_under.json"
printf '%s' "$(report "$(dep jinja2 3.1.4 "$(vuln GHSA-aaaa-bbbb-cccc 1.0 CVE-2026-1)")")" >"$work/merge_a.json"
printf '%s' "$(report "$(dep Jinja2 3.1.4 "$(vuln ghsa-AAAA-bbbb-cccc 2.0 CVE-2026-2)")")" >"$work/merge_b.json"
printf '%s' '{"dependencies": [{"name": "jinja2", "version": "3.1.4", "vulns": [{"id": "PYSEC-1", "aliases": "CVE-1", "fix_versions": []}]}]}' >"$work/badaliases.json"
printf '%s' '{"dependencies": [{"version": "3.1.4", "vulns": []}]}' >"$work/noname.json"
printf '%s' 'WARNING: not json' >"$work/garbage.json"

# entry PACKAGE ID [REASON]: a [[python.audit.accepted]] entry
entry() { printf '[[python.audit.accepted]]\npackage = "%s"\nid = "%s"\nreason = "%s"\n' "$1" "$2" "${3-why not}"; }

# expect LABEL WANT-RC TOML -- ARG... -- WANT-TEXT...: audit.py ARG... in a project whose
# devkit.toml holds TOML; the output (both streams) must hold every WANT-TEXT (one starting with !
# must not be in it), and no traceback.
expect() {
  local label=$1 want=$2 toml=$3 args=() out rc=0 text ok=true
  shift 4
  while [[ $1 != -- ]]; do args+=("$1") && shift; done
  shift
  printf '[python.duplication]\npaths = ["src"]\n%s\n' "$toml" >"$work/devkit.toml"
  out=$(cd "$work" && PROJECT_ROOT=$work python3 -I "$root/scripts/python/audit.py" "${args[@]}" 2>&1) || rc=$?
  for text in "$@"; do
    if [[ $text == '!'* ]]; then [[ $out != *"${text:1}"* ]] || ok=false; else [[ $out == *"$text"* ]] || ok=false; fi
  done
  if [[ $rc == "$want" && $ok == true && $out != *Traceback* ]]; then
    echo "PASS $label"
  else
    echo "FAIL $label: exit $rc, want $want and each of [$*] in:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}

both=(judge pypi 1 "$work/pypi.json" osv 1 "$work/osv.json")
J=$(entry jinja2 PYSEC-2026-1472 "jinja is sandboxed here") M=$(entry mako GHSA-5639-2j2p-m4mx "mako renders no user input")
J_ALIAS=$(entry jinja2 CVE-2024-56201)

expect "an alias of the PYSEC row (both services) accepts it, and mako (osv only) by its alias" 0 "$J
$M" -- "${both[@]}" -- \
  "jinja2 3.1.4: PYSEC-2026-1472 (aliases CVE-2024-56201, GHSA-gmj6-6f8f-6699; fixed in 3.1.5): jinja is sandboxed here" \
  "mako 1.4.1: PYSEC-2026-4243" "mako renders no user input" "no advisory beyond the 2 accepted"
expect "one entry accepts a PYSEC row from pypi and the GHSA row of osv" 0 "$J
$M" -- judge pypi 1 "$work/pypi.json" osv 1 "$work/osv_ghsa.json" -- "GHSA-gmj6-6f8f-6699 (aliases CVE-2024-56201, PYSEC-2026-1472;" \
  "PYSEC-2026-1472 (aliases"
expect "an entry by a CVE alias accepts" 0 "$J_ALIAS
$M" -- "${both[@]}" -- "no advisory beyond the 2 accepted"
expect "a finding of a service that exited 0 no entry accepts fails" 1 "" -- judge pypi 0 "$work/jinja.json" -- \
  "ERROR: jinja2 3.1.4: PYSEC-2026-1472" "not accepted in devkit.toml"
expect "the same row from two services is one row with the union of aliases and fixes" 0 "$(entry jinja2 CVE-2026-2)" -- \
  judge pypi 1 "$work/merge_a.json" osv 1 "$work/merge_b.json" -- "(aliases CVE-2026-1, CVE-2026-2; fixed in 1.0, 2.0)"
expect "an advisory id is matched case-insensitively" 0 "$(entry jinja2 ghsa-gmj6-6f8f-6699)" -- judge pypi 1 "$work/jinja.json" -- \
  "no advisory beyond the 1 accepted"
expect "a finding two entries accept fails, naming them and the remedy" 1 "$J
$J_ALIAS" -- judge pypi 1 "$work/jinja.json" -- "is accepted by 2 entries (PYSEC-2026-1472, CVE-2024-56201); keep one" \
  "To fix: keep one [[python.audit.accepted]] entry per finding."
expect "a finding no entry accepts fails, naming the service, package, version, id, aliases and fix" 1 "$M" -- "${both[@]}" -- \
  "ERROR: jinja2 3.1.4: PYSEC-2026-1472 (aliases CVE-2024-56201, GHSA-gmj6-6f8f-6699; fixed in 3.1.5) reported by osv and pypi, not accepted in devkit.toml" \
  "To fix: upgrade the package, or accept the advisory with an [[python.audit.accepted]] entry"
expect "an advisory only osv reports fails, naming osv alone" 1 "$J" -- "${both[@]}" -- \
  "ERROR: mako 1.4.1: PYSEC-2026-4243 (aliases GHSA-5639-2j2p-m4mx, CVE-2026-102991; fixed in 1.4.2) reported by osv, not accepted"
expect "an entry nothing reports is stale" 1 "$J
$M
$(entry jinja2 GHSA-0000-0000-0000)" -- "${both[@]}" -- \
  "ERROR: stale [[python.audit.accepted]] entry, no pypi or osv report holds it: GHSA-0000-0000-0000 on jinja2" \
  "To fix: remove the stale entries from devkit.toml."
expect "an entry only osv reports is not stale" 0 "$J
$M" -- "${both[@]}" -- "mako 1.4.1"
expect "an entry on another package fails the finding and is stale" 1 "$(entry jinja2 GHSA-5639-2j2p-m4mx)
$J" -- "${both[@]}" -- \
  "ERROR: mako 1.4.1: PYSEC-2026-4243" "ERROR: stale [[python.audit.accepted]] entry, no pypi or osv report holds it: GHSA-5639-2j2p-m4mx on jinja2"
expect "the package name is matched normalized" 0 "$(entry Jinja2 PYSEC-2026-1472)
$(entry MAKO GHSA-5639-2j2p-m4mx)" -- "${both[@]}" -- "no advisory beyond"
expect "the package name is matched with separators collapsed: a dot accepts a hyphen, a hyphen an underscore" 0 "$(entry zope.interface PYSEC-1)" -- \
  judge pypi 1 "$work/zope.json" osv 1 "$work/zope_under.json" -- "no advisory beyond the 1 accepted"
expect "clean reports pass with no entry" 0 "" -- judge pypi 0 "$work/clean.json" osv 0 "$work/clean.json" -- \
  "no advisory beyond the 0 accepted"
expect "clean reports with an entry: the entry is stale" 1 "$J" -- judge pypi 0 "$work/clean.json" osv 0 "$work/clean.json" -- \
  "stale [[python.audit.accepted]] entry"

expect "a missing report fails, saying staleness was not judged, yet the other report's findings print" 1 "$M" -- judge pypi 1 "$work/pypi.json" osv 1 "$work/none.json" -- \
  "ERROR: pip-audit against osv (exit 1) left no readable report" "ERROR: staleness not judged: a pip-audit report could not be read." "reported by pypi, not accepted"
expect "a report that is not JSON fails" 1 "$J" -- judge pypi 1 "$work/garbage.json" osv 0 "$work/clean.json" -- \
  "ERROR: pip-audit against pypi (exit 1) left no readable report" \
  "ERROR: staleness not judged: a pip-audit report could not be read." "To fix: rerun make audit"
expect "exit status 2 fails even with a report, and the remedy points at upgrading pip-audit" 1 "$J" -- judge pypi 2 "$work/clean.json" osv 0 "$work/clean.json" -- \
  "ERROR: pip-audit against pypi failed (exit 2); see its output above." "ERROR: staleness not judged" "uv lock --upgrade-package pip-audit"
expect "an entry only the unreadable service would report is not called stale" 1 "$J
$M" -- judge pypi 1 "$work/pypi.json" osv 2 "$work/osv.json" -- \
  "ERROR: staleness not judged" "!stale [[python.audit.accepted]]"
expect "no entries: nothing to judge for staleness, so no staleness line" 1 "" -- judge pypi 1 "$work/pypi.json" osv 1 "$work/none.json" -- \
  "left no readable report" "!staleness not judged"
expect "exit status 1 with no finding fails" 1 "" -- judge pypi 1 "$work/clean.json" osv 0 "$work/clean.json" -- \
  "ERROR: pip-audit against pypi failed (exit 1) but reported no advisory"
expect "a skipped dependency fails" 1 "" -- judge pypi 1 "$work/skipped.json" osv 0 "$work/clean.json" -- \
  "ERROR: pip-audit against pypi could not audit left-pad: Dependency not found on PyPI"
expect "an empty dependency list fails, blaming the markers, with a remedy that is no rerun" 1 "" -- judge pypi 0 "$work/empty.json" -- \
  "audited no dependency: it drops every requirement whose environment marker is false" \
  "cannot pass here; it can on a machine where one of the markers holds" "!rerun"
expect "dependencies that are not a list fail" 1 "" -- judge pypi 0 "$work/notlist.json" -- "reported no list of dependencies; its format changed"
expect "a malformed advisory fails" 1 "" -- judge pypi 0 "$work/badaliases.json" -- "reported a malformed advisory for jinja2 3.1.4"
expect "a dependency without a version fails" 1 "" -- judge pypi 0 "$work/noversion.json" -- "reported no version for jinja2"
expect "an advisory without aliases fails" 1 "" -- judge pypi 0 "$work/noaliases.json" -- "reported a malformed advisory for jinja2 3.1.4"
expect "an advisory without fix_versions fails" 1 "" -- judge pypi 0 "$work/nofixes.json" -- "reported a malformed advisory for jinja2 3.1.4"
expect "a dependency without a name fails" 1 "" -- judge pypi 0 "$work/noname.json" -- "reported a dependency without a name"
expect "a dependency without vulns fails" 1 "" -- judge pypi 0 "$work/novulns.json" -- "reported no vulns list for jinja2 3.1.4"

expect "no reports and no entries pass, claiming no pip-audit run" 0 "" -- judge -- "No third-party runtime dependencies" "!pip-audit"
expect "no reports and an entry: the entry is stale, naming no service" 1 "$J" -- judge -- \
  "ERROR: stale [[python.audit.accepted]] entry, the project has no third-party runtime dependency: PYSEC-2026-1472 on jinja2" "!pypi" "!osv"
expect "an incomplete report triple is a usage error" 2 "" -- judge pypi 0 -- "usage: audit.py"

expect "check-config passes with no table" 0 "" -- check-config -- "[python.audit]: 0 accepted advisories."
expect "check-config counts entries" 0 "$J
$M" -- check-config -- "[python.audit]: 2 accepted advisories."
expect "check-config rejects the same package and id twice, spelled differently" 1 "$J
$(entry Jinja2 PYSEC-2026-1472)" -- check-config -- "accepts PYSEC-2026-1472 on Jinja2 twice (entries 1 and 2)"
expect "check-config rejects the same id twice, differing in case" 1 "$(entry jinja2 GHSA-x)
$(entry jinja2 ghsa-x)" -- check-config -- "accepts ghsa-x on jinja2 twice (entries 1 and 2)"
expect "check-config accepts one id on two packages" 0 "$(entry jinja2 CVE-2026-1)
$(entry mako CVE-2026-1)" -- check-config -- "2 accepted"
expect "check-config rejects a blank reason" 1 "$(entry jinja2 CVE-2026-1 '  ')" -- check-config -- "needs a reason"
expect "check-config rejects a missing reason" 1 '[[python.audit.accepted]]
package = "jinja2"
id = "CVE-2026-1"' -- check-config -- "sets no reason"
expect "check-config rejects an unknown entry key" 1 '[[python.audit.accepted]]
package = "jinja2"
id = "CVE-2026-1"
reason = "r"
until = "2027-01-01"' -- check-config -- "unknown key(s) until"
expect "check-config rejects an unknown table key" 1 '[python.audit]
ignore = []' -- check-config -- "[python.audit] in devkit.toml sets unknown key(s) ignore"
expect "check-config rejects an audit that is not a table" 1 '[python]
audit = 1' -- check-config -- "must be a table holding an accepted array"
expect "check-config rejects an accepted that is not an array of tables" 1 '[python.audit]
accepted = "jinja2"' -- check-config -- "must be an array of tables"
expect "check-config rejects a malformed id" 1 "$(entry jinja2 'not an id')" -- check-config -- "id must be an advisory id"
expect "check-config rejects a malformed package" 1 "$(entry '-jinja2' CVE-2026-1)" -- check-config -- "package must be a Python package name"
expect "judge validates the config before reading reports" 1 "$(entry jinja2 CVE-2026-1 '')" -- "${both[@]}" -- "needs a reason"
expect "an unknown command is a usage error" 2 "" -- nope -- "usage: audit.py"

[[ $fails == 0 ]]
