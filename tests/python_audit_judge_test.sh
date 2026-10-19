#!/usr/bin/env bash
# Hermetic tests for scripts/python/audit.py: a temp project whose devkit.toml holds the accepted
# advisories under test, pylock.toml files (the export of the packages uv.lock pins, trimmed) the
# reports are judged against, and pip-audit reports (the shape of pip-audit 2.10.1's `--locked -f
# json --aliases on --desc off`, trimmed) written inline. No pip-audit, no network. Prints
# PASS/FAIL per case.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
fails=0

# lock FILE NAME==VERSION...: a pylock.toml pinning those packages (a name twice is a fork; none, an empty array)
lock() {
  local file=$1 spec
  shift
  printf 'lock-version = "1.0"\n' >"$file"
  (($#)) || printf 'packages = []\n' >>"$file"
  for spec; do printf '\n[[packages]]\nname = "%s"\nversion = "%s"\n' "${spec%%==*}" "${spec#*==}" >>"$file"; done
}
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

L2=$work/two.toml LJ=$work/jinja.toml LZ=$work/zope.toml LNONE=$work/none.toml LFORK=$work/fork.toml
lock "$L2" jinja2==3.1.4 mako==1.4.1
lock "$LJ" jinja2==3.1.4
lock "$LZ" Zope.Interface==6.0
lock "$LNONE"
lock "$LFORK" six==1.16.0 six==1.17.0
printf 'lock-version = "1.0"\n[[packages]]\nname = "jinja2"\nversion = "3.1.4"\n\n[[packages]]\nname = "tool"\n' >"$work/noversion.toml"
printf 'lock-version = "1.0"\n[[packages]]\nversion = "1.0"\n' >"$work/noname.toml"
printf 'lock-version = "1.0"\npackages = ["jinja2"]\n' >"$work/notables.toml"
printf 'not = toml = at all\n' >"$work/garbage.toml"
printf 'lock-version = "1.0"\n\n[[packages]]\nname = "x"\nversion = "1.0"\nvcs = { type = "git", url = "https://example.invalid/x", commit-id = "0" }\n' >"$work/git.toml"
printf 'lock-version = "1.0"\n\n[[packages]]\nname = "x"\nversion = "1.0"\narchive = { url = "https://example.invalid/x.tar.gz" }\n' >"$work/archive.toml"
printf 'lock-version = "1.0"\n\n[[packages]]\nname = "x"\narchive = { path = "../x.tar.gz" }\n' >"$work/archive_path.toml"
printf 'lock-version = "1.0"\n' >"$work/nopackages.toml"
printf 'lock-version = "1.0"\n\n[[packages]]\nname = "x"\ndirectory = { path = "../x" }\n' >"$work/directory.toml"
printf 'lock-version = "2.0"\npackages = []\n' >"$work/v2.toml"
printf 'packages = []\n' >"$work/nover.toml"
printf 'lock-version = "1.0"\ncreated-by = "uv"\nrequires-python = ">=3.11"\npackages = []\n' >"$work/emptyuv.toml"
lock "$work/jinja315.toml" jinja2==3.1.5
printf '%s' "$(report "$(dep jinja2 3.1.5)")" >"$work/jinja315.json"
printf '%s' "$(report "$(dep six 1.16.0)")" >"$work/six16.json"
printf '%s' "$(report "$(dep six 1.16.0)" "$(dep six 1.17.0)")" >"$work/six_both.json"
printf '%s' "$(report "$(dep jinja2 3.1.4 "$JINJA" "$JINJA")")" >"$work/jinja_twice.json"
printf '%s' "$(report "$(dep jinja2 3.1.4)")" >"$work/jinja_clean.json"

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

both=(judge "$L2" pypi 1 "$work/pypi.json" osv 1 "$work/osv.json")
J=$(entry jinja2 PYSEC-2026-1472 "jinja is sandboxed here") M=$(entry mako GHSA-5639-2j2p-m4mx "mako renders no user input")
J_ALIAS=$(entry jinja2 CVE-2024-56201)

expect "an alias of the PYSEC row (both services) accepts it, and mako (osv only) by its alias" 0 "$J
$M" -- "${both[@]}" -- \
  "jinja2 3.1.4: PYSEC-2026-1472 (aliases CVE-2024-56201, GHSA-gmj6-6f8f-6699; fixed in 3.1.5): jinja is sandboxed here" \
  "mako 1.4.1: PYSEC-2026-4243" "mako renders no user input" "no advisory beyond the 2 accepted"
expect "one entry accepts a PYSEC row from pypi and the GHSA row of osv" 0 "$J
$M" -- judge "$L2" pypi 1 "$work/pypi.json" osv 1 "$work/osv_ghsa.json" -- "GHSA-gmj6-6f8f-6699 (aliases CVE-2024-56201, PYSEC-2026-1472;" \
  "PYSEC-2026-1472 (aliases"
expect "an entry by a CVE alias accepts" 0 "$J_ALIAS
$M" -- "${both[@]}" -- "no advisory beyond the 2 accepted"
expect "a finding of a service that exited 0 no entry accepts fails" 1 "" -- judge "$LJ" pypi 0 "$work/jinja.json" -- \
  "ERROR: jinja2 3.1.4: PYSEC-2026-1472" "not accepted in devkit.toml"
expect "the same row from two services is one row with the union of aliases and fixes" 0 "$(entry jinja2 CVE-2026-2)" -- \
  judge "$LJ" pypi 1 "$work/merge_a.json" osv 1 "$work/merge_b.json" -- "(aliases CVE-2026-1, CVE-2026-2; fixed in 1.0, 2.0)"
expect "an advisory id is matched case-insensitively" 0 "$(entry jinja2 ghsa-gmj6-6f8f-6699)" -- judge "$LJ" pypi 1 "$work/jinja.json" -- \
  "no advisory beyond the 1 accepted"
expect "a finding two entries accept fails, naming them and the remedy" 1 "$J
$J_ALIAS" -- judge "$LJ" pypi 1 "$work/jinja.json" -- "is accepted by 2 entries (PYSEC-2026-1472, CVE-2024-56201); keep one" \
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
  judge "$LZ" pypi 1 "$work/zope.json" osv 1 "$work/zope_under.json" -- "no advisory beyond the 1 accepted"
expect "clean reports pass with no entry" 0 "" -- judge "$L2" pypi 0 "$work/clean.json" osv 0 "$work/clean.json" -- \
  "no advisory beyond the 0 accepted"
expect "clean reports with an entry: the entry is stale" 1 "$J" -- judge "$L2" pypi 0 "$work/clean.json" osv 0 "$work/clean.json" -- \
  "stale [[python.audit.accepted]] entry"

expect "a missing report fails, saying staleness was not judged, yet the other report's findings print" 1 "$M" -- judge "$L2" pypi 1 "$work/pypi.json" osv 1 "$work/none.json" -- \
  "ERROR: pip-audit against osv (exit 1) left no readable report" "ERROR: staleness not judged: a pip-audit report could not be read." "reported by pypi, not accepted"
expect "a report that is not JSON fails" 1 "$J" -- judge "$L2" pypi 1 "$work/garbage.json" osv 0 "$work/clean.json" -- \
  "ERROR: pip-audit against pypi (exit 1) left no readable report" \
  "ERROR: staleness not judged: a pip-audit report could not be read." "To fix: rerun make audit"
expect "exit status 2 fails even with a report, and the remedy points at upgrading pip-audit" 1 "$J" -- judge "$L2" pypi 2 "$work/clean.json" osv 0 "$work/clean.json" -- \
  "ERROR: pip-audit against pypi failed (exit 2); see its output above." "ERROR: staleness not judged" "uv lock --upgrade-package pip-audit"
expect "an entry only the unreadable service would report is not called stale" 1 "$J
$M" -- judge "$L2" pypi 1 "$work/pypi.json" osv 2 "$work/osv.json" -- \
  "ERROR: staleness not judged" "!stale [[python.audit.accepted]]"
expect "no entries: nothing to judge for staleness, so no staleness line" 1 "" -- judge "$L2" pypi 1 "$work/pypi.json" osv 1 "$work/none.json" -- \
  "left no readable report" "!staleness not judged"
expect "exit status 1 with no finding fails" 1 "" -- judge "$L2" pypi 1 "$work/clean.json" osv 0 "$work/clean.json" -- \
  "ERROR: pip-audit against pypi failed (exit 1) but reported no advisory"
expect "a skipped dependency fails" 1 "" -- judge "$L2" pypi 1 "$work/skipped.json" osv 0 "$work/clean.json" -- \
  "ERROR: pip-audit against pypi could not audit left-pad: Dependency not found on PyPI"
expect "an empty report against a non-empty lock fails, naming every package; staleness is not judged" 1 "$J" -- judge "$L2" pypi 0 "$work/empty.json" -- \
  "ERROR: pip-audit against pypi left out jinja2 3.1.4, mako 1.4.1 of the packages uv.lock pins." "ERROR: staleness not judged" "!stale [[python.audit.accepted]]" \
  "ERROR: staleness not judged: a pip-audit report left out a package uv.lock pins." \
  "To fix: pin a pip-audit that audits every package of a pylock.toml, such as 2.10.1, the one devkit's fixtures pin: uv add --dev pip-audit==2.10.1, then make install." "!rerun" "!could not be read"
expect "a report missing a locked package fails, naming it alone" 1 "" -- judge "$L2" pypi 0 "$work/jinja_clean.json" osv 0 "$work/clean.json" -- \
  "ERROR: pip-audit against pypi left out mako 1.4.1 of the packages uv.lock pins." "!against osv" "!jinja2 3.1.4 of"
expect "the other report's findings still print when one leaves a package out" 1 "" -- judge "$L2" pypi 0 "$work/jinja_clean.json" osv 1 "$work/osv.json" -- \
  "left out mako 1.4.1" "ERROR: jinja2 3.1.4: PYSEC-2026-1472" "ERROR: mako 1.4.1: PYSEC-2026-4243"
expect "a name the lock forks into two versions fails with one version reported" 1 "" -- judge "$LFORK" pypi 0 "$work/six16.json" -- \
  "ERROR: pip-audit against pypi left out six 1.17.0 of the packages uv.lock pins." "!six 1.16.0 of"
expect "a name the lock forks passes with both versions reported" 0 "" -- judge "$LFORK" pypi 0 "$work/six_both.json" osv 0 "$work/six_both.json" -- \
  "no advisory beyond the 0 accepted"
expect "the lock and the report are compared by normalized name" 0 "$(entry zope.interface PYSEC-1)" -- judge "$LZ" pypi 1 "$work/zope.json" -- \
  "no advisory beyond the 1 accepted"
expect "a report of another package does not cover a locked one" 1 "" -- judge "$LJ" pypi 0 "$work/six16.json" -- \
  "ERROR: pip-audit against pypi left out jinja2 3.1.4 of the packages uv.lock pins."
expect "accepted behaviour of the count comparison: a report of jinja2 3.1.5 covers a lock of jinja2 3.1.4" 0 "" -- judge "$LJ" pypi 0 "$work/jinja315.json" -- \
  "no advisory beyond the 0 accepted"
expect "an advisory pip-audit lists twice for one dependency counts once" 0 "$J" -- judge "$LJ" pypi 1 "$work/jinja_twice.json" -- \
  "no advisory beyond the 1 accepted" "!accepted by 2 entries"
expect "a lock that cannot be read fails with one error and no report is judged" 1 "" -- judge "$work/missing.toml" pypi 0 "$work/clean.json" -- \
  "ERROR: devkit cannot read the pylock.toml export of uv.lock" "!To fix" "!pip-audit against"
expect "a lock that is not TOML fails" 1 "" -- judge "$work/garbage.toml" pypi 0 "$work/clean.json" -- "ERROR: devkit cannot read the pylock.toml export of uv.lock"
expect "a lock whose packages are not tables fails" 1 "" -- judge "$work/notables.toml" pypi 0 "$work/clean.json" -- "not an array of tables"
expect "a lock entry without a name fails" 1 "" -- judge "$work/noname.toml" pypi 0 "$work/clean.json" -- "pins a package without a name"
expect "a lock entry without a version fails" 1 "" -- judge "$work/noversion.toml" pypi 0 "$work/clean.json" -- \
  "pins tool with no version, which pip-audit cannot audit."
expect "a lock entry from a git source fails, naming it" 1 "" -- judge "$work/git.toml" pypi 0 "$work/clean.json" -- \
  "pins x from a git source, which pip-audit would audit as the PyPI release of that name and version; make audit cannot audit it." "!pip-audit against"
expect "a lock entry from a URL source fails, naming it" 1 "" -- judge "$work/archive.toml" pypi 0 "$work/clean.json" -- "pins x from a URL source, which pip-audit would audit as the PyPI release"
expect "a lock entry from a local file fails, naming it" 1 "" -- judge "$work/archive_path.toml" pypi 0 "$work/clean.json" -- \
  "pins x from a local file source, which pip-audit cannot audit against an index; make audit cannot audit it."
expect "a lock entry from a local directory fails, naming it" 1 "" -- judge "$work/directory.toml" pypi 0 "$work/clean.json" -- \
  "pins x from a local directory source, which pip-audit cannot audit against an index; make audit cannot audit it."
expect "a lock of another major version fails" 1 "" -- judge "$work/v2.toml" pypi 0 "$work/clean.json" -- \
  "has lock-version '2.0', not 1.x; its format changed under devkit."
expect "a lock with no packages array fails" 1 "" -- judge "$work/nopackages.toml" pypi 0 "$work/clean.json" -- \
  "ERROR: the pylock.toml export of uv.lock has no packages array; its format changed under devkit."
expect "check-lock fails a lock with no packages array" 1 "" -- check-lock "$work/nopackages.toml" -- \
  "ERROR: the pylock.toml export of uv.lock has no packages array; its format changed under devkit."
expect "a lock with no lock-version fails" 1 "" -- judge "$work/nover.toml" pypi 0 "$work/clean.json" -- "has lock-version None, not 1.x"
expect "uv's empty lock and no reports pass" 0 "" -- judge "$work/emptyuv.toml" -- "No third-party runtime dependencies"
# count LABEL LOCK WANT: check-lock LOCK prints exactly WANT
count() {
  local out
  out=$(cd "$work" && PROJECT_ROOT=$work python3 -I "$root/scripts/python/audit.py" check-lock "$2" 2>&1) || out="exit $?: $out"
  if [[ $out == "$3" ]]; then
    echo "PASS $1"
  else
    echo "FAIL $1: want exactly '$3', got:"
    printf '%s\n' "$out"
    fails=$((fails + 1))
  fi
}
count "check-lock prints the pin count of a two-package lock" "$L2" 2
count "check-lock counts a fork per version" "$LFORK" 2
count "check-lock prints 0 for an empty lock" "$work/emptyuv.toml" 0
expect "check-lock fails with one error for a git source" 1 "" -- check-lock "$work/git.toml" -- "ERROR: the pylock.toml export of uv.lock pins x from a git source" "!To fix"
expect "dependencies that are not a list fail" 1 "" -- judge "$L2" pypi 0 "$work/notlist.json" -- "reported no list of dependencies; its format changed"
expect "a malformed advisory fails" 1 "" -- judge "$L2" pypi 0 "$work/badaliases.json" -- "reported a malformed advisory for jinja2 3.1.4"
expect "a dependency without a version fails" 1 "" -- judge "$L2" pypi 0 "$work/noversion.json" -- "reported no version for jinja2"
expect "an advisory without aliases fails" 1 "" -- judge "$L2" pypi 0 "$work/noaliases.json" -- "reported a malformed advisory for jinja2 3.1.4"
expect "an advisory without fix_versions fails" 1 "" -- judge "$L2" pypi 0 "$work/nofixes.json" -- "reported a malformed advisory for jinja2 3.1.4"
expect "a dependency without a name fails" 1 "" -- judge "$L2" pypi 0 "$work/noname.json" -- "reported a dependency without a name"
expect "a dependency without vulns fails" 1 "" -- judge "$L2" pypi 0 "$work/novulns.json" -- "reported no vulns list for jinja2 3.1.4"

expect "no reports and an empty lock pass, claiming no pip-audit run" 0 "" -- judge "$LNONE" -- "No third-party runtime dependencies" "!pip-audit"
expect "no reports and an entry: the entry is stale, naming no service" 1 "$J" -- judge "$LNONE" -- \
  "ERROR: stale [[python.audit.accepted]] entry, the project has no third-party runtime dependency: PYSEC-2026-1472 on jinja2" "!pypi" "!osv"
expect "no reports against a non-empty lock fail" 1 "" -- judge "$L2" -- "ERROR: devkit ran no pip-audit over the 2 packages uv.lock pins."
expect "no reports against a one-pin lock fail, in the singular" 1 "" -- judge "$LJ" -- "over the 1 package uv.lock pins."
expect "judge without a lock is a usage error" 2 "" -- judge -- "usage: audit.py {check-config|check-lock LOCK|judge LOCK [SERVICE RC REPORT]...}"
expect "an incomplete report triple is a usage error" 2 "" -- judge "$L2" pypi 0 -- "usage: audit.py"

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
